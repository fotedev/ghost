#Requires -Version 5.1
<#
.SYNOPSIS
  Wait for Primary to quit normally, sync its latest settled chats, then open it.
.DESCRIPTION
  This launcher never closes or restarts a running AutoClaw2 app. If Primary
  stays in its tray, quit it there. The separate Desktop shortcut is installed
  by -InstallShortcut; stock and clone shortcuts are not modified.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 900)][int]$WaitTimeoutSeconds = 180,
    [switch]$InstallShortcut,
    [switch]$RemoveShortcut,
    [switch]$InteractiveShortcut
)
$ErrorActionPreference = 'Stop'
$localAppData = $env:LOCALAPPDATA
if (-not $localAppData) { $localAppData = [Environment]::GetFolderPath('LocalApplicationData') }
$exe = Join-Path $localAppData 'Programs\AutoClaw2\AutoClaw2.exe'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$desktop = [Environment]::GetFolderPath('DesktopDirectory')
$linkPath = Join-Path $desktop 'AutoClaw2 Sync & Open Primary.lnk'
$linkArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InteractiveShortcut' -f $PSCommandPath
$worker = Join-Path $PSScriptRoot 'watch_autoclaw2_chat_sync.ps1'
$probe = Join-Path $PSScriptRoot 'inspect_autoclaw2_chat_runtime.ps1'

if ($InstallShortcut -and $RemoveShortcut) { throw 'Choose either install or remove.' }
if ($InstallShortcut -or $RemoveShortcut) {
    $wsh = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $linkPath) {
        $current = $wsh.CreateShortcut($linkPath)
        if ($current.TargetPath -ine $psExe -or $current.Arguments -ine $linkArgs) {
            throw "Refusing to change an unrelated shortcut: $linkPath"
        }
    }
    if ($RemoveShortcut) {
        if (Test-Path -LiteralPath $linkPath) { Remove-Item -LiteralPath $linkPath }
        if (Test-Path -LiteralPath $linkPath) { throw 'Shortcut removal did not verify.' }
        Write-Host 'Sync & Open Primary shortcut removed.'
        exit 0
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Stock AutoClaw2 executable is missing: $exe" }
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $psExe
    $link.Arguments = $linkArgs
    $link.WorkingDirectory = $PSScriptRoot
    $link.IconLocation = "$exe,0"
    $link.Description = 'Wait for Primary to quit, apply its queued chat updates, and open AutoClaw2'
    $link.Save()
    $check = $wsh.CreateShortcut($linkPath)
    if ($check.TargetPath -ine $psExe -or $check.Arguments -cne $linkArgs -or
        ($check.IconLocation -replace ',\s*0$', ',0') -ine "$exe,0") {
        throw 'Primary sync shortcut did not verify.'
    }
    Write-Host "Sync & Open Primary shortcut installed: $linkPath"
    exit 0
}

function Stop-PrimaryHandoff([string]$Message, [int]$Code) {
    Write-Warning $Message
    if ($InteractiveShortcut) { [void](Read-Host 'Press Enter to close this window') }
    exit $Code
}

function Test-PrimaryBusy {
    $out = & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $probe
    if ($LASTEXITCODE -ne 0 -or -not $out) { throw 'Could not verify whether Primary is closed.' }
    $json = $out -join "`n"
    if ($json -notmatch '^\s*\[[\s\S]*\]\s*$') { throw 'Unexpected AutoClaw2 runtime probe result.' }
    $busy = ConvertFrom-Json -InputObject $json
    if ($null -ne $busy -and @($busy | Where-Object { $_ -notin @('Primary','c1','c2','c3','c4','c5') }).Count) {
        throw 'Unexpected AutoClaw2 runtime probe result.'
    }
    return ('Primary' -in $busy)
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
try {
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-PrimaryHandoff 'Run this shortcut without elevation. Primary was not opened.' 1
    }
} finally { $identity.Dispose() }
if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or -not (Test-Path -LiteralPath $worker -PathType Leaf) -or
    -not (Test-Path -LiteralPath $probe -PathType Leaf)) {
    Stop-PrimaryHandoff 'The stock app or sync tools are missing. Primary was not opened.' 1
}

Write-Host 'Sync & Open Primary. If Primary is open, quit it from the system tray. Leave this window open.'
Write-Host 'Other AutoClaw2 profiles are not closed. Press Ctrl+C to cancel.'
$timer = [Diagnostics.Stopwatch]::StartNew()
$ready = $false
$waitingInfo = $false
try {
    while ($timer.Elapsed.TotalSeconds -lt $WaitTimeoutSeconds) {
        if (Test-PrimaryBusy) {
            if (-not $waitingInfo) {
                Write-Host 'Waiting for Primary to quit; clicking X may only hide it in the tray.' -ForegroundColor Yellow
                $waitingInfo = $true
            }
            Start-Sleep -Seconds 2
            continue
        }
        $left = $WaitTimeoutSeconds - [int][Math]::Ceiling($timer.Elapsed.TotalSeconds)
        if ($left -lt 5) { break }
        & $psExe -NoProfile -ExecutionPolicy Bypass -File $worker -RunOnce -Target Primary `
            -RequireConverged -WorkerTimeoutSeconds ([Math]::Min($left, 120))
        $code = $LASTEXITCODE
        if ($code -eq 0) { $ready = $true; break }
        if ($code -ne 2) {
            Stop-PrimaryHandoff 'Sync could not be verified. Primary was not opened. If signed out, open the regular shortcut and sign in first.' 1
        }
        Write-Host 'Sync is deferred; retrying while Primary stays closed.' -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
    if (-not $ready) { Stop-PrimaryHandoff 'Timed out waiting for a verified Primary sync. No app was closed or opened.' 2 }
    if (Test-PrimaryBusy) {
        Stop-PrimaryHandoff 'Primary was opened separately after sync. No second instance was launched.' 2
    }

    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $exe
    $start.WorkingDirectory = Split-Path -Parent $exe
    $start.UseShellExecute = $false
    foreach ($name in @('ZWORK_USER_DATA','AUTOCLAW_PROFILE_ROOT','ZWORK_AUMID','ZWORK_CLONE_ICON',
                        'ZWORK_RELAUNCH_NAME','ZWORK_RELAUNCH_COMMAND')) {
        $start.EnvironmentVariables.Remove($name)
    }
    $opened = [Diagnostics.Process]::Start($start)
    if (-not $opened) { throw 'Primary process did not start.' }
    try {
        $deadline = (Get-Date).AddSeconds(20)
        do {
            $opened.Refresh()
            if (-not $opened.HasExited -and $opened.MainWindowHandle -ne 0) {
                Write-Host ('Primary opened after verified sync (PID {0}).' -f $opened.Id) -ForegroundColor Green
                exit 0
            }
            if ($opened.HasExited) { break }
            Start-Sleep -Milliseconds 400
        } until ((Get-Date) -ge $deadline)
        Stop-PrimaryHandoff 'Sync verified, but the launched Primary window was not confirmed. Check the tray or Start menu.' 1
    } finally { $opened.Dispose() }
} catch {
    Stop-PrimaryHandoff $_.Exception.Message 1
}
