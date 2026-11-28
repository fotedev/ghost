#Requires -Version 5.1
<#
.SYNOPSIS
  Local all-to-all AutoClaw2 chat sync. Open profiles are queued, not stopped.
.DESCRIPTION
  -RunOnce -DryRun previews. -RunOnce applies one verified pass (optionally pin
  -PlanId). With no mode switch the watcher repeats on runtime changes. The
  Startup shortcut is opt-in; removing it stops its resident watcher on the
  next pass. -Target limits destinations only, never the source inventory.
  -RequireConverged is a one-target launch gate: 0 only if the closed target
  is verified current, 2 to retry a defer, and 1 on failure/skip.
#>
[CmdletBinding()]
param(
    [switch]$RunOnce,
    [switch]$DryRun,
    [string]$Target = 'All',
    [string]$PlanId,
    [ValidateRange(15,900)][int]$IntervalSeconds = 45,
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart,
    [switch]$RequireAutostart,
    [switch]$RequireConverged,
    [ValidateRange(5, 300)][int]$WorkerTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
$profiles = @('Primary','c1','c2','c3','c4','c5')
$targets = if ($Target -ieq 'All') { $profiles } else { @($Target -split '\s*,\s*') }
$targets = @(foreach ($name in $targets) {
    $canonical = @($profiles | Where-Object { $_ -ieq $name })
    if (-not $canonical) { throw "Unknown AutoClaw2 profile: $name" }
    $canonical[0]
})
if ($InstallAutostart -and $RemoveAutostart) { throw 'Choose install or remove, not both.' }
if ($PlanId -and -not $RunOnce) { throw '-PlanId applies only to a one-shot pass.' }
if ($RequireConverged -and (-not $RunOnce -or $DryRun -or $targets.Count -ne 1 -or $InstallAutostart -or $RemoveAutostart -or $RequireAutostart)) {
    throw '-RequireConverged needs -RunOnce, one explicit -Target and no other mode switch.'
}
$repo = Split-Path -Parent $PSScriptRoot
$startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoClaw2 chat sync watcher.lnk'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$autostartArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -RequireAutostart' -f $PSCommandPath
$localAppData = $env:LOCALAPPDATA
if (-not $localAppData) { $localAppData = [Environment]::GetFolderPath('LocalApplicationData') }
$log = Join-Path $localAppData 'watch-autoclaw2-chat-sync\chat-sync.log'

if ($InstallAutostart -or $RemoveAutostart) {
    $wsh = New-Object -ComObject WScript.Shell
    if (Test-Path -LiteralPath $startup) {
        $old = $wsh.CreateShortcut($startup)
        if ($old.TargetPath -ine $psExe -or -not $old.Arguments.Contains('watch_autoclaw2_chat_sync.ps1')) {
            throw "Refusing to modify a foreign shortcut: $startup"
        }
    }
    if ($RemoveAutostart) {
        if (Test-Path -LiteralPath $startup) { Remove-Item -LiteralPath $startup -Force }
        if (Test-Path -LiteralPath $startup) { throw 'Autostart removal did not verify.' }
        Write-Host 'AutoClaw2 chat sync autostart is off. Its startup-managed watcher exits at the next interval.'
    } else {
        $link = $wsh.CreateShortcut($startup)
        $link.TargetPath = $psExe
        $link.Arguments = $autostartArgs
        $link.WorkingDirectory = $repo
        $link.Description = 'GHOST AutoClaw2 local chat sync (offline target writes only)'
        $link.Save()
        $check = $wsh.CreateShortcut($startup)
        if ($check.TargetPath -ine $psExe -or $check.Arguments -cne $autostartArgs) {
            throw 'Autostart shortcut did not verify.'
        }
        Write-Host "AutoClaw2 chat sync autostart verified: $startup"
    }
    exit 0
}

if ($RequireAutostart -and -not (Test-Path -LiteralPath $startup)) { exit 0 }
. (Join-Path $repo 'src\windows\identity_utils.ps1')
$python = Get-PythonCommandInfo
$cli = Get-GhostPythonCli
if (-not $python -or -not $cli) { throw 'AutoClaw2 chat sync requires working Python 3 and the GHOST core.' }

function Invoke-ChatMesh {
    $payload = @{ targets = @($targets); apply = (-not $DryRun) }
    if ($PlanId) { $payload.plan_id = $PlanId }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress)))
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $python
    $psi.Arguments = '-B "{0}" ac2-chat-mesh {1}' -f $cli, $b64
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $child = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit($WorkerTimeoutSeconds * 1000)) {
            $child.Kill()
            $child.WaitForExit()
            return @{ code = 1; diagnostic = "chat mesh worker exceeded its ${WorkerTimeoutSeconds}s limit"; report = $null }
        }
        $text = $stdout.Result.Trim()
        return @{ code = $child.ExitCode; diagnostic = $stderr.Result.Trim(); report = $(if ($text) { $text | ConvertFrom-Json }) }
    } finally { $child.Dispose() }
}

function Get-ChatHandoffExitCode($Result, [string]$Name) {
    $retry = @('target-running', 'mesh-busy', 'runtime-state-unknown', 'source-changed',
               'source-in-progress', 'active-account-changed', 'target-changed', 'active-source-unreadable')
    if (-not $Result.report) { return 1 }
    if ($Result.report.refused) {
        if ($Result.report.refused -in $retry) { return 2 }
        return 1
    }
    $property = $Result.report.targets.PSObject.Properties[$Name]
    if (-not $property) { return 1 }
    $verdict = $property.Value
    if ($Result.code -ne 0 -or $verdict.status -in @('failed','skipped')) { return 1 }
    if ($verdict.ready -eq $true -and $verdict.open -eq $false -and $verdict.status -in @('applied','up-to-date')) {
        return 0
    }
    if ($verdict.open -eq $true -or $verdict.reason -in $retry) { return 2 }
    return 1
}

function Format-ChatMeshResult($result) {
    if ($result.diagnostic) { $result.diagnostic }
    if (-not $result.report) { return }
    if ($result.report.refused) {
        '[REFUSED] {0}: {1}' -f $result.report.refused, $result.report.message
        return
    }
    'AutoClaw2: {0} lineages; {1} IM excluded; {2} unsettled or invalid source snapshots.' -f `
        $result.report.lineages, $result.report.im_excluded, $result.report.unsettled_or_invalid_sources
    foreach ($prop in $result.report.targets.PSObject.Properties) {
        $verdict = $prop.Value
        $counts = if ($verdict.actions) {
            @($verdict.actions.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join ', '
        } else { '' }
        $detail = switch ($verdict.reason) {
            'target-running' { 'waiting for the app to quit (X may leave it running in the tray)'; break }
            'source-in-progress' { 'waiting for a source run to finish'; break }
            'active-source-unreadable' { 'waiting for a readable active source account'; break }
            'active-account-changed' { 'account switched during the pass; retry pending'; break }
            default { $verdict.reason }
        }
        if (-not $detail -and $verdict.open) { $detail = 'app open' }
        "[$($verdict.status)] $($prop.Name) $($verdict.account) $counts $detail".TrimEnd()
        if ($verdict.backup) { "  backup: $($verdict.backup); incompatible artifacts not copied: $($verdict.artifacts_skipped)" }
        if ($verdict.protected) { "  preserved local drafts, archives or deletions: $($verdict.protected)" }
        if ($verdict.retention_warnings) { "  backup retention warnings: $($verdict.retention_warnings)" }
    }
    foreach ($db in $result.report.unreadable_databases) { "[WARN] $($db.profile) database: $($db.reason)" }
    if ($DryRun) { "PlanId $($result.report.plan_id)" }
}

if ($RunOnce) {
    $result = Invoke-ChatMesh
    Format-ChatMeshResult $result
    if ($RequireConverged) { exit (Get-ChatHandoffExitCode $result $targets[0]) }
    exit $result.code
}

function Get-ChatMeshSignature {
    $appData = $env:APPDATA
    if (-not $appData) { $appData = [Environment]::GetFolderPath('ApplicationData') }
    $homes = @((Join-Path $appData 'AutoClaw-oversea-official'))
    $homes += @(1..5 | ForEach-Object { Join-Path $env:USERPROFILE "AutoClaw2ClonesHome\c$_" })
    $parts = @(Get-Process -Name 'AutoClaw2*' -ErrorAction SilentlyContinue | Sort-Object Id | ForEach-Object { "pid:$($_.Id)" })
    foreach ($profileDir in $homes) {
        $paths = @((Join-Path $profileDir 'device\active-product-account.json'), (Join-Path $profileDir '.autoclaw2-chat-imports.json'))
        $paths += @(Get-ChildItem -Path (Join-Path $profileDir 'accounts\*\runtime\runtime.sqlite*') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('runtime.sqlite','runtime.sqlite-wal') } | Sort-Object FullName | ForEach-Object FullName)
        foreach ($path in $paths) {
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item) { $parts += "$path`:$($item.Length):$($item.LastWriteTimeUtc.Ticks)" }
        }
    }
    return ($parts -join '|')
}

$mutex = New-Object Threading.Mutex($false, 'Local\GhostAutoClaw2ChatWatcher')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { exit 0 }
    $last = $null
    $lastSweep = [DateTime]::MinValue
    while (-not $RequireAutostart -or (Test-Path -LiteralPath $startup)) {
        try {
            $signature = Get-ChatMeshSignature
            if ($signature -cne $last -or ([DateTime]::UtcNow - $lastSweep).TotalMinutes -ge 10) {
                $result = Invoke-ChatMesh
                $lines = @(Format-ChatMeshResult $result)
                $lines | Write-Host
                if (-not $DryRun) {
                    $dir = Split-Path -Parent $log
                    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 2MB) {
                        Move-Item -LiteralPath $log -Destination "$log.1" -Force
                    }
                    Add-Content -LiteralPath $log -Encoding UTF8 -Value (@("$(Get-Date -Format 's') exit=$($result.code)") + $lines)
                }
                $last = $signature
                $lastSweep = [DateTime]::UtcNow
            }
        } catch {
            Write-Warning ('AutoClaw2 watcher pass failed: ' + $_.Exception.Message)
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
