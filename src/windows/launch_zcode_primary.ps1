#Requires -Version 5.1
# ZCode Primary Launcher (gid 82, ZCode submenu [9], added 2026-11-10)
# Launches the STOCK Primary instance - the profile every clone is measured
# against. Deliberately minimal next to launch_zcode_second_instance.ps1:
#   - No env levers at all. The four clone branding vars (ZCODE_ICON_DIR /
#     ZCODE_AUMID_SUFFIX / ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME) are NEVER
#     set here - the Primary carries the bare base AUMID and default look.
#   - Spawn goes through explorer.exe, not Start-Process on the exe directly.
#     Two verified reasons:
#       1. Elevation: explorer runs at the shell's medium IL, so the child is
#          non-elevated even when GHOST.bat / GHOST.exe run as admin. A bare
#          exe child would inherit the elevated parent and UIPI would then
#          silently strip drag-drop data into it (verified 2026-09-24).
#       2. Console: ZCode calls AttachConsole(ATTACH_PARENT_PROCESS) and
#          floods the launching console with logs (GHOST.bat rule, 2026-09-25);
#          explorer has no console to hijack and detaches immediately.
#   - Single-instance is the app's own userData-keyed lock: relaunching while
#     the Primary runs just focuses its window. Verify-after accounts for it.
param()
$ErrorActionPreference = 'Stop'

# --- Persistent launch log ---------------------------------------------------
# The :Detached window closes automatically when done, so console output is
# otherwise lost. Same best-effort transcript pattern as the clone launchers.
try {
    $logDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\tools\logs'))
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $script:LaunchLogPath = Join-Path $logDir 'launch_zcode_primary.log'
    Start-Transcript -Path $script:LaunchLogPath -Append -IncludeInvocationHeader | Out-Null
    Write-Host "[log] transcript: $script:LaunchLogPath"
} catch {
    Write-Host "[log] transcript disabled: $($_.Exception.Message)" -ForegroundColor Yellow
}
function Stop-LaunchLog {
    try { Stop-Transcript | Out-Null } catch { }
}

$UserProfile  = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

# Auto-detect ZCode.exe (same candidates as the clone launcher).
$ZCodeExeCandidates = @(
    (Join-Path $LocalAppData 'Programs\ZCode\ZCode.exe'),
    'C:\Program Files\ZCode\ZCode.exe',
    'C:\Program Files (x86)\ZCode\ZCode.exe'
)
$ZCodeExe = $ZCodeExeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ZCodeExe) {
    Stop-LaunchLog
    throw "ZCode.exe not found. Checked: $($ZCodeExeCandidates -join '; ')"
}

# Clone process markers = roaming dir names + clone home dir names + the
# per-color exe copies' names (2026-11-11 Task Manager identity: a clone main
# AND its children carry ZCode-<Color>.exe in their command lines). A ZCode
# main whose subtree matches NONE of these is a Primary.
$CloneMarkers = @(
    'ZCode-Second', 'ZCode-Third', 'ZCode-Fourth', 'ZCode-Fifth', 'ZCode-Sixth',
    'ZCodeSecondHome', 'ZCodeThirdHome', 'ZCodeFourthHome', 'ZCodeFifthHome', 'ZCodeSixthHome',
    'ZCode-Blue.exe', 'ZCode-Yellow.exe', 'ZCode-Green.exe', 'ZCode-Red.exe', 'ZCode-Orange.exe'
)

function Get-ZcodeMains {
    # WMI filter + cmdline regex cover the whole copy family - a bare
    # Name='ZCode.exe' would silently drop clones running from their copies.
    # [^"]* (not [^\s"]*) so spaced install paths match (see launcher note).
    @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction SilentlyContinue | Where-Object {
        $c = ([string]$_.CommandLine).Trim()
        # Empty CommandLine is a known WMI race on fresh mains: keep as candidate.
        ([string]::IsNullOrWhiteSpace($c)) -or ($c -match '^"[^"]*ZCode(?:-[A-Za-z]+)?\.exe"$') -or ($c -match '^[A-Za-z]:\\[^"]*ZCode(?:-[A-Za-z]+)?\.exe$')
    })
}

function Test-SubtreeHasCloneMarker {
    # Walk the main's process subtree; $true when ANY descendant command line
    # carries a clone marker (Chromium children carry --user-data-dir).
    param([int]$MainPid)
    $allProcs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction SilentlyContinue)
    $byParent = @{}
    foreach ($p in $allProcs) {
        $ppid = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $p
    }
    $seen = @{}; $queue = New-Object System.Collections.Queue
    $queue.Enqueue($MainPid) | Out-Null
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        if ($byParent.ContainsKey($id)) {
            foreach ($c in $byParent[$id]) {
                $cmd = [string]$c.CommandLine
                foreach ($mk in $CloneMarkers) {
                    if ($cmd -like "*$mk*") { return $true }
                }
                $queue.Enqueue([int]$c.ProcessId) | Out-Null
            }
        }
    }
    return $false
}

function Get-PrimaryMains {
    # Mains whose subtree carries no clone marker. Empty-CommandLine mains are
    # ambiguous mid-scan (WMI race) - count them as candidates, never as proof.
    @(Get-ZcodeMains | Where-Object {
        $c = ([string]$_.CommandLine).Trim()
        if ([string]::IsNullOrWhiteSpace($c)) { return $false }
        -not (Test-SubtreeHasCloneMarker -MainPid ([int]$_.ProcessId))
    })
}

Write-Host "ZCode Primary launcher"
Write-Host "  exe: $ZCodeExe"
$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($elevated) {
    Write-Host "  GHOST session is elevated - spawning via explorer.exe so the app stays non-elevated (drag-drop works)" -ForegroundColor Yellow
}

$already = @(Get-PrimaryMains)
if ($already.Count -gt 0) {
    foreach ($p in $already) {
        Write-Host ("  Primary already running (pid {0}) - this launch focuses its window" -f $p.ProcessId) -ForegroundColor Cyan
    }
}

# Launch detached through explorer (see header: medium IL + no console hijack).
Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $ZCodeExe) | Out-Null

# Verify-after (never silent-success): a Primary-classified main must exist.
# Covers both paths - a fresh spawn appears as a new main, a relaunch focuses
# the main detected above.
$deadline = (Get-Date).AddSeconds(20)
$primaryPid = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $found = @(Get-PrimaryMains)
    if ($found.Count -gt 0) {
        $primaryPid = $found[0].ProcessId
        break
    }
}

if ($null -eq $primaryPid) {
    Write-Host "FAILED: no Primary ZCode.exe main detected within 20s" -ForegroundColor Red
    Write-Host "Check tools\logs\launch_zcode_primary.log and try launching ZCode.exe directly." -ForegroundColor Red
    Stop-LaunchLog
    exit 1
}

Write-Host ("PASS: Primary running (pid {0}) - stock profile, no clone env vars set" -f $primaryPid) -ForegroundColor Green
Write-Host "Tip: launch clones via their ZCode <Color> shortcuts or the ZCode submenu - a bare clone launch would open THIS profile." -ForegroundColor DarkGray
Stop-LaunchLog
exit 0
