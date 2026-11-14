#requires -Version 5.1
<#
SYNOPSIS
  watch_zcode_deeplink_forward.ps1 - deep-link callback forwarder for the ZCode
  clone suite (GHOST).

WHY
  The desktop OAuth login callback arrives through ONE machine-wide URL scheme
  (HKCU\Software\Classes\zcode\shell\open\command). Every instance re-registers
  that command to its own exe at boot (last launch wins), and the OS spawn
  carries NO clone environment - so the callback always boots the PRIMARY
  profile (a bare ZCode*.exe = default profile), never the clone that is
  waiting for it. Verified 2026-11-11: the browser redirect spawned
  ZCode-Yellow.exe bare, which opened the Primary profile and rejected the
  clone's OAuth state ("OAuth state mismatch or expired"), while the clone's
  own poll died at the business-token exchange.

WHAT THIS DOES
  Polls the ZCode process family for fresh env-less callback spawns, extracts
  the callback URL from the spawn's command line, re-delivers it into every
  RUNNING instance WITH its own environment (the single-instance lock forwards
  the argv to the live instance; the OAuth state match decides which one
  completes - mismatched receivers reject harmlessly, verified in the logs),
  then kills the stray Primary-profile spawn window.

NOTES
  - Read-only on the registry; writes nothing on disk.
  - Leave running while signing a clone in via browser. Stop by killing the
    PowerShell process (or Ctrl+C in its console).
  - The callback only helps while the requesting instance still holds the
    pending OAuth state (~5 minutes from "Login with Browser").

PARAMS
  -IntervalMs   poll interval in milliseconds (default 600).
  -NoKillSpawn  leave the stray Primary-profile spawn window open (default:
                kill it after a successful forward).
#>
[CmdletBinding()]
param(
    [int]$IntervalMs = 600,
    [switch]$NoKillSpawn,
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart
)

$ErrorActionPreference = 'Continue'

$UserProfile  = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$AppData      = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($AppData)) { $AppData = Join-Path $UserProfile 'AppData\Roaming' }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

$ZCodeExe = Join-Path $LocalAppData 'Programs\ZCode\ZCode.exe'
if (-not (Test-Path -LiteralPath $ZCodeExe)) {
    $ZCodeExe = 'C:\Program Files\ZCode\ZCode.exe'
}
if (-not (Test-Path -LiteralPath $ZCodeExe)) {
    Write-Host '[deeplink-forward] ZCode.exe not found - exiting.' -ForegroundColor Red
    exit 1
}

# Single instance via a machine-global named mutex.
$script:WatcherMutex = New-Object System.Threading.Mutex($false, 'Global\ZcodeDeeplinkForwardWatcherMutex')
$mutexHeld = $false
try { $mutexHeld = $script:WatcherMutex.WaitOne(0) } catch { $mutexHeld = $true }  # abandoned mutex = ownership granted
if (-not $mutexHeld) {
    Write-Host '[deeplink-forward] another watcher instance holds the mutex - exiting.' -ForegroundColor Yellow
    exit 0
}

# Startup autostart (the routing fix must survive reboots).
$StartupDir = [Environment]::GetFolderPath('Startup')
if ([string]::IsNullOrWhiteSpace($StartupDir)) {
    $StartupDir = Join-Path $UserProfile 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
}
$StartupLnk = Join-Path $StartupDir 'ZCode Deeplink Forward.lnk'
if ($InstallAutostart -or $RemoveAutostart) {
    if ($RemoveAutostart -and (Test-Path -LiteralPath $StartupLnk)) {
        Remove-Item -LiteralPath $StartupLnk -Force
        Write-Host ('[deeplink-forward] autostart removed: ' + $StartupLnk) -ForegroundColor Yellow
    }
    if ($InstallAutostart) {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($StartupLnk)
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.Description = 'GHOST - ZCode deep-link callback forwarder (clone login fix)'
        $lnk.Save()
        Write-Host ('[deeplink-forward] autostart installed: ' + $StartupLnk) -ForegroundColor Green
    }
    if (-not $InstallAutostart) { return }
}

# Same instance map as launch_zcode_second_instance.ps1 (Second row FROZEN).
$InstanceMap = [ordered]@{
    'Second' = @{ Home = 'ZCodeSecondHome';  UserData = 'ZCode-Second';  AumidSuffix = '2'; AccentHex = '#066BCB'; DisplayName = 'Blue';   ExeName = 'ZCode-Blue.exe' }
    'Third'  = @{ Home = 'ZCodeThirdHome';   UserData = 'ZCode-Third';   AumidSuffix = '3'; AccentHex = '#D4AA10'; DisplayName = 'Yellow'; ExeName = 'ZCode-Yellow.exe' }
    'Fourth' = @{ Home = 'ZCodeFourthHome';  UserData = 'ZCode-Fourth';  AumidSuffix = '4'; AccentHex = '#13826A'; DisplayName = 'Green';  ExeName = 'ZCode-Green.exe' }
    'Fifth'  = @{ Home = 'ZCodeFifthHome';   UserData = 'ZCode-Fifth';   AumidSuffix = '5'; AccentHex = '#CA0607'; DisplayName = 'Red';    ExeName = 'ZCode-Red.exe' }
    'Sixth'  = @{ Home = 'ZCodeSixthHome';   UserData = 'ZCode-Sixth';   AumidSuffix = '6'; AccentHex = '#CB5D06'; DisplayName = 'Orange'; ExeName = 'ZCode-Orange.exe' }
}

$script:SeenPids  = @{}
$script:SeenCodes = @{}

function Write-Log {
    param([string]$Message, [switch]$Warn)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Message
    if ($Warn) { Write-Host $line -ForegroundColor Yellow } else { Write-Host $line }
}

function Get-CloneLevers {
    # Mirrors launch_zcode_second_instance.ps1's env block exactly (no
    # USERPROFILE redirect - the desktop launcher does not set one).
    param($Cfg)
    $cloneHome     = Join-Path $UserProfile $Cfg.Home
    $cloneUserData = Join-Path $AppData    $Cfg.UserData
    $levers = @{
        'ZCODE_DATA_BASE_DIR'            = $cloneHome
        'ZCODE_DESKTOP_USER_DATA_DIR'    = $cloneUserData
        'ZCODE_DESKTOP_SESSION_DATA_DIR' = (Join-Path $cloneUserData 'session')
        'ZCODE_DESKTOP_HOME_DIR'         = $cloneHome
        'HOME'                           = $cloneHome
        'ZCODE_AUMID_SUFFIX'             = $Cfg.AumidSuffix
        'ZCODE_ACCENT_HEX'               = $Cfg.AccentHex
        'ZCODE_INSTANCE_NAME'            = ('ZCode ' + $Cfg.DisplayName)
    }
    $iconDir = Join-Path $cloneHome 'branding'
    if ((Test-Path -LiteralPath (Join-Path $iconDir 'icon_windows.png')) -and
        (Test-Path -LiteralPath (Join-Path $iconDir 'tray_icon.ico'))) {
        $levers['ZCODE_ICON_DIR'] = $iconDir
    }
    return $levers
}

function Clear-CloneLevers {
    # Restore default-profile env for a Primary-forward spawn.
    foreach ($name in @('ZCODE_DATA_BASE_DIR', 'ZCODE_DESKTOP_USER_DATA_DIR', 'ZCODE_DESKTOP_SESSION_DATA_DIR',
                        'ZCODE_DESKTOP_HOME_DIR', 'ZCODE_AUMID_SUFFIX', 'ZCODE_ACCENT_HEX',
                        'ZCODE_INSTANCE_NAME', 'ZCODE_ICON_DIR')) {
        Remove-Item -Path ('env:' + $name) -ErrorAction SilentlyContinue
    }
    $env:HOME = $UserProfile
}

function Invoke-Forward {
    param([string]$ExePath, [hashtable]$Levers, [string]$Url, [string]$TargetLabel)
    foreach ($k in $Levers.Keys) { Set-Item -Path ('env:' + $k) -Value ([string]$Levers[$k]) }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = $ExePath
    $psi.Arguments       = '-- "' + $Url + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $false
    try {
        [void][System.Diagnostics.Process]::Start($psi)
        Write-Log ('forwarded callback -> {0} ({1})' -f $TargetLabel, $ExePath)
        return $true
    } catch {
        Write-Log ('forward spawn failed for {0}: {1}' -f $TargetLabel, $_.Exception.Message) -Warn
        return $false
    }
}

Write-Log ('watcher started (pid {0}, interval {1} ms) - exe: {2}' -f $PID, $IntervalMs, $ZCodeExe)

while ($true) {
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction SilentlyContinue)

        # Fresh callback spawns: main cmdlines that carry the OAuth callback
        # URL. Share-import deep links (zcode://share/...) are NOT touched.
        $spawnCandidates = @($procs | Where-Object {
                ($_.CommandLine) -and
                ($_.CommandLine -match 'zcode://oauth/callback|zcode://zai-auth/callback') -and
                (-not $script:SeenPids.ContainsKey([int]$_.ProcessId))
            })

        foreach ($spawn in $spawnCandidates) {
            $spawnPid = [int]$spawn.ProcessId
            $script:SeenPids[$spawnPid] = $true

            $m = [regex]::Match([string]$spawn.CommandLine, 'zcode://(?:oauth|zai-auth)/callback[^\s"]*')
            if (-not $m.Success) { continue }
            $url = $m.Value

            # Same URL => same delivery; never re-forward this watcher's own
            # forwards (the forwarded process carries the URL in its cmdline
            # for a few seconds too).
            # Dedupe by the OAuth code (NOT the full URL): the interstitial can
            # re-fire the SAME code with varying attribution params, and a
            # replayed consumed code only produces a confusing "authorization
            # code is invalid or expired" failure inside the clone (observed
            # 2026-11-11 15:58:32).
            $codeMatch = [regex]::Match($url, '[?&]code=([^&"\s]+)')
            if ($codeMatch.Success) { $codeKey = $codeMatch.Groups[1].Value } else { $codeKey = $url }
            if ($script:SeenCodes.ContainsKey($codeKey)) { continue }
            $script:SeenCodes[$codeKey] = $true

            Write-Log ('caught callback spawn pid={0}: {1}' -f $spawnPid, $url)

            # Skip spawns already running inside a clone's context (this
            # watcher's own forwards, or a clone cold-start carrying a URL):
            # their child processes carry a clone user-data dir.
            $cloneChild = @($procs | Where-Object {
                    ($_.ParentProcessId -eq $spawnPid) -and
                    ($_.CommandLine) -and
                    ($_.CommandLine -match 'ZCode-(Second|Third|Fourth|Fifth|Sixth)|ZCode(Second|Third|Fourth|Fifth|Sixth)Home')
                })
            if ($cloneChild.Count -gt 0) {
                Write-Log ('spawn pid={0} already carries a clone env - skipping.' -f $spawnPid)
                continue
            }

            # Receivers: every RUNNING clone (its processes carry its roaming/
            # home markers) plus the Primary when it is actually running.
            $forwarded = $false
            foreach ($name in $InstanceMap.Keys) {
                $cfg = $InstanceMap[$name]
                $running = @($procs | Where-Object {
                        ($_.CommandLine) -and
                        (($_.CommandLine -like ('*' + $cfg.UserData + '*')) -or ($_.CommandLine -like ('*' + $cfg.Home + '*')))
                    })
                if ($running.Count -eq 0) { continue }
                $levers = Get-CloneLevers -Cfg $cfg
                $exe = Join-Path (Split-Path -Parent $ZCodeExe) $cfg.ExeName
                if (-not (Test-Path -LiteralPath $exe)) { $exe = $ZCodeExe }
                if (Invoke-Forward -ExePath $exe -Levers $levers -Url $url -TargetLabel $cfg.DisplayName) { $forwarded = $true }
            }

            # Primary detection must EXCLUDE the stray spawn's own tree: its
            # children carry the default Roaming\ZCode user-data-dir, which
            # made the watcher "forward to the Primary" into a phantom
            # cold-start Primary-profile instance (observed 2026-11-11 15:25:
            # the forward created exactly the white window this tool exists to
            # prevent, and the user had to quit it from the tray).
            $primaryRunning = @($procs | Where-Object {
                    ($_.ProcessId -ne $spawnPid) -and
                    ($_.ParentProcessId -ne $spawnPid) -and
                    ($_.CommandLine) -and ($_.CommandLine -match 'user-data-dir=[^"]*Roaming\\ZCode(?=["\s]|$)')
                })
            if ($primaryRunning.Count -gt 0) {
                Clear-CloneLevers
                if (Invoke-Forward -ExePath $ZCodeExe -Levers @{} -Url $url -TargetLabel 'Primary') { $forwarded = $true }
            }

            if ($forwarded) {
                if (-not $NoKillSpawn) {
                    Stop-Process -Id $spawnPid -Force -ErrorAction SilentlyContinue
                    Write-Log ('killed stray Primary-profile spawn pid={0}.' -f $spawnPid)
                }
            } else {
                Write-Log 'no running instance to receive the callback - leaving the spawn untouched.' -Warn
            }
        }

        # Keep the dedupe sets bounded on long sessions.
        if ($script:SeenPids.Count -gt 500)  { $script:SeenPids.Clear() }
        if ($script:SeenCodes.Count -gt 200) { $script:SeenCodes.Clear() }
    } catch {
        Write-Log ('watch loop error: {0}' -f $_.Exception.Message) -Warn
    }
    Start-Sleep -Milliseconds $IntervalMs
}
