#Requires -Version 5.1
<#
.SYNOPSIS
  Resident watcher: whenever the central AutoClaw2 MCP master manifest
  (tools\autoclaw2-mcp.master.json) changes, re-apply it to the suite's
  profiles via tools\sync_autoclaw2_mcp.ps1.

.WHY THIS EXISTS (gid 74, reserved since 2026-11-04)
  The AutoClaw2 MCP sync's source of truth is the dev-edited master manifest
  in the REPO - unlike ZCode, where the watcher stat-guards the live Primary
  config. Editing the manifest outside a launcher pass left every clone
  stale until the next manual [8] run. The watcher closes that gap: every
  manifest save converges the suite within seconds, so a clone launched
  later always starts from the freshest definitions (the launcher's
  pre-launch step 2b remains the primary path; this watcher is
  install-and-forget between passes).

.HOW
  The watcher writes NOTHING itself: every change triggers
  tools\sync_autoclaw2_mcp.ps1 -Target <target> as a CHILD process
  (console-less spawn + a 600s kill cap - a wedged child must never block
  the loop). The master manifest is only ever READ (stat mtime+size +
  parse-guard; a torn/invalid JSON skips the pass, never syncs).

  - Sync pass: the first pass on start converges the drift; afterwards only
    on manifest signature change (mtime+size, debounced ~1s); a deep
    re-verify runs every 60 passes (~5 min at the default interval).
  - NO -ApplyLive: the AutoClaw2 sync targets CLOSED profiles only (D7 -
    the connected-sources SQLite gate refuses running ones). A synced
    definition lands on each profile's next launch (launcher pre-launch
    step 2b), so there is nothing to recycle.

.Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_autoclaw2_mcp_sync.ps1
        [-RunOnce] [-DryRun] [-IntervalSeconds 5]
        [-Target All|c1,c3|c1] [-LogFile <path>]
        [-InstallAutostart | -RemoveAutostart]

  GHOST.bat AutoClaw2 submenu [11] (resident, detached). Log:
  %LOCALAPPDATA%\watch-autoclaw2-mcp-sync\ac2-mcp-sync.log

.Notes
  - Single instance: named mutex Autoclaw2McpSyncWatcher + a startup process
    scan that catches stale pre-mutex copies (the ZCode watcher pattern).
    -RunOnce one-shots bypass the guard by design.
  - The sync child carries its own merge invariants (clone-local enabled
    toggles survive, clone-only servers kept, definitions-only writes,
    closed-profile gate, backup + verify-after + JSONL audit live THERE).
  - No admin needed. Never elevated on purpose.
#>
[CmdletBinding()]
param(
    [switch]$RunOnce,
    [switch]$DryRun,
    [int]$IntervalSeconds = 5,
    # Comma-tolerant single string, forwarded to the sync child verbatim
    # (it splits + validates: 'All', one id, or 'c1,c3').
    [string]$Target = 'All',
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'watch-autoclaw2-mcp-sync\ac2-mcp-sync.log'),
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$MasterJson  = Join-Path $PSScriptRoot 'autoclaw2-mcp.master.json'
$SyncScript  = Join-Path $PSScriptRoot 'sync_autoclaw2_mcp.ps1'
$PsExe       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-WatchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length -gt 5MB)) {
            $bak = "$LogFile.1"
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
            Move-Item -LiteralPath $LogFile -Destination $bak -Force
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        # Log writes must never unwind the resident loop.
        Write-Host "[LOG-FAIL] $line" -ForegroundColor Yellow
    }
    if ($Level -eq 'FAIL') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'SYNC') { Write-Host $line -ForegroundColor Cyan }
    elseif ($Level -eq 'CHILD') { } # child detail: file only, unless FAIL
    else { Write-Host $line }
}

# --- manifest signature (stat + parse guard) ---------------------------------
$script:LastSignature = $null

function Get-ManifestSignature {
    # Returns @{ ok; signature; error }. A torn/invalid manifest skips the
    # pass (error string) instead of ever syncing from a bad read.
    if (-not (Test-Path -LiteralPath $MasterJson)) {
        return @{ ok = $false; signature = $null; error = 'master manifest missing' }
    }
    $item = Get-Item -LiteralPath $MasterJson -ErrorAction SilentlyContinue
    if ($null -eq $item) { return @{ ok = $false; signature = $null; error = 'stat failed' } }
    $sig = '{0}:{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length
    # parse guard: only treat the read as good when the JSON parses
    try {
        $null = Get-Content -LiteralPath $MasterJson -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return @{ ok = $false; signature = $sig; error = ('manifest JSON invalid: ' + $_.Exception.Message) }
    }
    return @{ ok = $true; signature = $sig; error = $null }
}

# --- sync child (console-less spawn + 600s cap; the 2026-11-11 lesson) --------
function Invoke-SyncChild {
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        Write-WatchLog "sync script missing: $SyncScript" 'FAIL'
        return 'failed'
    }
    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "' + $SyncScript + '" -Target ' + $Target
    if ($DryRun) { $argStr += ' -DryRun' }
    $out = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $PsExe
        $psi.Arguments = $argStr
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $soTask = $proc.StandardOutput.ReadToEndAsync()
        $seTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(600000)) {
            try { $proc.Kill() } catch { }
            Write-WatchLog 'sync child timed out after 600s - killed' 'FAIL'
        }
        $out = $soTask.Result + $seTask.Result
        try { $code = $proc.ExitCode } catch { $code = 1 }
    } catch {
        Write-WatchLog ("sync child threw: {0}" -f $_.Exception.Message) 'FAIL'
        return 'failed'
    }
    foreach ($line in ($out -split "`r?`n")) {
        $t = $line.Trim()
        if ($t) { Write-WatchLog ('child| ' + $t) 'CHILD' }
    }
    # The child's EXIT CODE is the verdict contract (0 ok / 1 failed / 2
    # refused). Its OUTPUT legitimately contains 'FAILED' inside honest
    # per-source live-test WARN lines (e.g. 'resend: live test FAILED
    # (authentication_failed)') - never pattern-match those.
    if ($code -ne 0) {
        Write-WatchLog ("sync child FAILED (exit {0}) - see child| lines in {1}" -f $code, $LogFile) 'FAIL'
        return 'failed'
    }
    if ($out -match 'targets converged|row\(s\) written') {
        Write-WatchLog 'sync child OK - definitions merged + verified' 'SYNC'
        return 'changed'
    }
    Write-WatchLog 'sync child OK - profiles already in sync'
    return 'insync'
}

function Invoke-WatchPass {
    param([bool]$ForceVerify = $false)
    $sig = Get-ManifestSignature
    if (-not $sig.ok) {
        Write-WatchLog ('manifest read skipped: {0}' -f $sig.error) 'WARN'
        return 'skipped'
    }
    if (-not $ForceVerify -and $sig.signature -eq $script:LastSignature) {
        return 'unchanged'
    }
    $changed = if ($null -eq $script:LastSignature) { 'first pass' } elseif ($ForceVerify) { 'deep verify' } else { 'manifest changed' }
    Write-WatchLog ("manifest {0} - invoking sync child (target {1})" -f $changed, $Target) 'INFO'
    $script:LastSignature = $sig.signature
    return Invoke-SyncChild
}

# --- Autostart management (Startup-folder shortcut, no registry) --------------
if ($InstallAutostart -or $RemoveAutostart) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'AutoClaw2 MCP sync watcher.lnk'
    if ($RemoveAutostart) {
        if (Test-Path -LiteralPath $lnkPath) {
            Remove-Item -LiteralPath $lnkPath -Force
            Write-WatchLog "autostart removed: $lnkPath" 'INFO'
        } else {
            Write-WatchLog "autostart not present: $lnkPath" 'INFO'
        }
    } else {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = $PsExe
        $lnk.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath)
        $lnk.WorkingDirectory = $RepoRoot
        $lnk.Description = 'GHOST AutoClaw2 MCP sync watcher - converges clone MCP definitions on every master-manifest change'
        $lnk.Save()
        Write-WatchLog "autostart installed: $lnkPath" 'INFO'
    }
    exit 0
}

# --- One-shot / resident -------------------------------------------------------
if ($RunOnce) {
    Write-WatchLog ("one-shot pass starting (target {0}, DryRun {1})" -f $Target, [bool]$DryRun)
    $status = Invoke-WatchPass
    Write-WatchLog ("single pass complete (-RunOnce, status {0})" -f $status)
    exit 0
}

# Resident console title: self-identifying no matter how it was launched.
try { $Host.UI.RawUI.WindowTitle = 'AutoClaw2 MCP Sync Watcher (pid {0})' -f $PID } catch { }

# Process scan on top of the mutex: the mutex only serializes copies of THIS
# script version - a stale older copy would co-run silently. Matched by
# script leaf name so relative and absolute -File paths both hit; own pid and
# -RunOnce one-shots excluded.
function Get-OtherWatcherPids {
    $leaf = (Split-Path -Leaf $PSCommandPath).ToLowerInvariant()
    $found = @()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        $cl = ""
        if ($p.CommandLine) { $cl = $p.CommandLine.ToLowerInvariant() }
        if (-not $cl.Contains($leaf)) { continue }
        if ($cl.Contains("-runonce")) { continue }
        $found += [int]$p.ProcessId
    }
    return $found
}

if (-not (Test-Path -LiteralPath $MasterJson)) {
    Write-WatchLog "master manifest missing: $MasterJson - nothing to watch; exiting." 'FAIL'
    exit 1
}
if (-not (Test-Path -LiteralPath $SyncScript)) {
    Write-WatchLog "sync script missing: $SyncScript - nothing to invoke; exiting." 'FAIL'
    exit 1
}

$others = Get-OtherWatcherPids
if ($others.Count -gt 0) {
    Write-WatchLog ('watcher already running (pid {0}) - exiting. Close that console or stop the pid first.' -f ($others -join ', ')) 'WARN'
    exit 0
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Autoclaw2McpSyncWatcher', [ref]$created)
if (-not $created) {
    $holder = Get-OtherWatcherPids
    $who = ''
    if ($holder.Count -gt 0) { $who = ' by pid ' + ($holder -join ', ') }
    Write-WatchLog ('watcher already running (mutex held{0}) - exiting. Check the log or Task Manager.' -f $who) 'WARN'
    $mutex.Close()
    exit 0
}

Write-WatchLog ("AutoClaw2 MCP sync watcher started (pid {0}, target {1}, interval {2}s, log {3})" -f $PID, $Target, $IntervalSeconds, $LogFile) 'INFO'
try {
    $pass = 0
    while ($true) {
        $pass++
        $status = Invoke-WatchPass -ForceVerify ($pass % 60 -eq 0)
        if ($status -eq 'failed') { Start-Sleep -Seconds ([Math]::Max($IntervalSeconds, 15)) }
        else { Start-Sleep -Seconds $IntervalSeconds }
    }
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Close()
    Write-WatchLog 'watcher stopped' 'INFO'
}
