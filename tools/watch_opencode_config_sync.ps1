#Requires -Version 5.1
<#
.SYNOPSIS
  Resident watcher: whenever the Primary OpenCode config changes
  (~\.config\opencode\opencode.jsonc), merge its MCP + provider DEFINITIONS
  into every clone's own config via tools\sync_opencode_config.ps1.

.WHY THIS EXISTS (CS-1 v2, 2026-11-17)
  CS-1 (PR #85) shipped the one-shot sync + the launcher pre-launch step, but
  a config edit made while no clone is launching never reaches the clones:
  they only re-read definitions when the pre-launch step (or this watcher)
  runs. This watcher closes that gap on the ZCode MCP-sync-watcher pattern
  (tools\watch_zcode_mcp_sync.ps1): stat-guard the Primary config, debounce
  ~1s, spawn the sync child on every real change, deep re-verify ~5 min.

.HOW
  The watcher writes NOTHING itself: every change triggers
  tools\sync_opencode_config.ps1 -Target All (per-clone lockfile skip +
  backup + verify-after + JSONL audit live there), invoked as a child
  process. The Primary config is only ever READ (stat + JSONC parse-guard;
  a torn/invalid file skips the pass, never syncs).

  Deliberately NOT here (differs from the ZCode watcher): no -ApplyLive
  flag, because the live behavior is now the CHILD'S DEFAULT - the CS-7
  Phase-0 probe (LIVE-VERIFIED 2026-11-22, controlled test on clone c1
  running its own v2.3.2 service with the config directory watcher armed)
  proved an externally edited opencode config fires `config.updated` in
  the clone's service log within ~2s, for BOTH the in-place and the atomic
  temp+Replace write styles. A running desktop clone therefore picks the
  definitions sync up LIVE; the child syncs lockfile-held clones by
  default (with the reload-probe verify-after) and only skips them under
  its own -SkipRunning opt-out. Config-less first-run clones are always
  skipped by the child (the suite's anonymous-first-run design).

.Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_opencode_config_sync.ps1
        [-RunOnce] [-DryRun] [-IntervalSeconds 5]
        [-InstallAutostart | -RemoveAutostart]

  GHOST.bat OpenCode submenu [21] (one-shot sync row, gid 110) and [22]
  (resident watcher, gid 111). The OpenCode clone launcher step 2c ensures
  this watcher is running + autostarted, mirroring the ZCode launcher 2e.
  Log: %LOCALAPPDATA%\watch-opencode-config-sync\config-sync.log

.Notes
  - Single instance: named mutex OpencodeConfigSyncWatcher + a startup
    process scan that catches stale pre-mutex copies (same pattern as the
    ZCode MCP sync watcher). -RunOnce one-shots bypass the guard by design.
  - Per-clone enabled toggles and clone-only entries stay clone-local (the
    merge invariant in tools\opencode_config_merge.ps1); Primary definitions
    win; secrets NEVER cross (the child's D2 scrub).
  - No admin needed. Never elevated on purpose.
#>
[CmdletBinding()]
param(
    [switch]$RunOnce,
    [switch]$DryRun,
    [int]$IntervalSeconds = 5,
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'watch-opencode-config-sync\config-sync.log'),
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart
)

$ErrorActionPreference = 'Stop'

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
# Same resolution as the sync child: .jsonc preferred, .json fallback.
$PrimaryConfig = Join-Path $UserProfile '.config\opencode\opencode.jsonc'
if (-not (Test-Path -LiteralPath $PrimaryConfig)) {
    $jsonAlt = Join-Path $UserProfile '.config\opencode\opencode.json'
    if (Test-Path -LiteralPath $jsonAlt) { $PrimaryConfig = $jsonAlt }
}
$SyncScript = Join-Path $PSScriptRoot 'sync_opencode_config.ps1'
$MergeCore  = Join-Path $PSScriptRoot 'opencode_config_merge.ps1'
$PsExe      = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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
    # Console is milestone-gated: the file always gets everything.
    if ($Level -eq 'FAIL') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'SYNC') { Write-Host $line -ForegroundColor Cyan }
    elseif ($Level -eq 'CHILD') { } # child detail: file only, unless FAIL
    else { Write-Host $line }
}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# --- sync child (the ONLY writer: sync_opencode_config.ps1 -Target All) -------
# Returns 'changed' | 'insync' | 'failed'.
function Invoke-SyncChild {
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        Write-WatchLog "sync script missing: $SyncScript" 'FAIL'
        return 'failed'
    }
    $argStr = '-NoProfile -ExecutionPolicy Bypass -File "' + $SyncScript + '" -Target All'
    if ($DryRun) { $argStr += ' -DryRun' }
    # Console-less child spawn (CreateNoWindow) + 600s cap: a watcher running
    # without a console would otherwise give this child a brand-new VISIBLE
    # cmd window on every 5-minute deep-verify, and a wedged child would
    # block the watch loop forever (the ZCode watcher's 2026-11-11 lesson).
    $code = 1
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
    if (($code -ne 0) -or ($out -match '\[FAILED\]')) {
        Write-WatchLog ("sync child FAILED (exit {0}) - see child| lines in {1}" -f $code, $LogFile) 'FAIL'
        return 'failed'
    }
    if ($out -match 'wrote \+ verified') {
        Write-WatchLog 'sync child OK - definitions merged + verified' 'SYNC'
        return 'changed'
    }
    Write-WatchLog 'sync child OK - all clones already in sync (or nothing to sync yet)'
    return 'insync'
}

# --- Primary signature + debounced sync pass ---------------------------------
$script:LastSig      = $null
$script:PendingSig   = $null
$script:PendingSince = $null
$script:PassCount    = 0

function Test-PrimaryConfigParses {
    # JSONC-aware parse-guard: dot-source the pure merge core (the same
    # library the sync child uses) and reuse its stripper - a naive
    # ConvertFrom-Json would false-fail on a healthy commented config.
    if (-not (Test-Path -LiteralPath $MergeCore)) { return $false }
    . $MergeCore
    try {
        $raw = Get-Content -LiteralPath $PrimaryConfig -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
        $null = ConvertFrom-JsoncText -Text $raw
        return $true
    } catch { return $false }
}

function Get-PrimarySignature {
    $fi = Get-Item -LiteralPath $PrimaryConfig -ErrorAction Stop
    return @{ Sig = ('{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length); ParseOk = (Test-PrimaryConfigParses) }
}

function Invoke-SyncPass([switch]$Force) {
    # Returns 'changed' | 'insync' | 'failed' | 'skipped'.
    if (-not (Test-Path -LiteralPath $PrimaryConfig)) {
        Write-WatchLog "Primary config missing: $PrimaryConfig (the suite's anonymous-first-run design) - nothing to sync from." 'WARN'
        return 'skipped'
    }
    $sig = Get-PrimarySignature
    if (-not $sig.ParseOk) {
        # Never sync FROM a torn/invalid file: skip and wait for it to settle.
        Write-WatchLog 'Primary config failed to parse - skipping this pass (no sync from an invalid file).' 'WARN'
        return 'skipped'
    }
    if (-not $Force) {
        if ($sig.Sig -eq $script:LastSig) {
            if ($script:PendingSig) { $script:PendingSig = $null; $script:PendingSince = $null } # change reverted
            return 'insync'
        }
        if ($script:PendingSig -ne $sig.Sig) {
            $script:PendingSig = $sig.Sig
            $script:PendingSince = Get-Date
            return 'skipped'
        }
        if (((Get-Date) - $script:PendingSince).TotalMilliseconds -lt 800) { return 'skipped' }
    }
    if (-not $DryRun) { Write-WatchLog 'Primary config changed (or startup converge) - syncing clones...' 'SYNC' }
    $res = Invoke-SyncChild
    $script:LastSig = $sig.Sig
    $script:PendingSig = $null
    $script:PendingSince = $null
    return $res
}

function Invoke-WatchPass {
    $script:PassCount++
    $first = ($script:PassCount -eq 1)                    # startup converge
    $deep  = (($script:PassCount % 60) -eq 0)             # deep re-verify ~5 min
    try {
        return Invoke-SyncPass -Force:($first -or $deep)
    } catch {
        Write-WatchLog ("watch pass FAILED: {0}" -f $_.Exception.Message) 'FAIL'
        return 'failed'
    }
}

# ---- Autostart management (Startup-folder shortcut, no registry) ------------
if ($InstallAutostart -or $RemoveAutostart) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'OpenCode config sync watcher.lnk'
    if ($RemoveAutostart) {
        if (Test-Path -LiteralPath $lnkPath) {
            Remove-Item -LiteralPath $lnkPath -Force
            if (Test-Path -LiteralPath $lnkPath) { Write-WatchLog "autostart REMOVE FAILED - $lnkPath still exists" 'FAIL' }
            else { Write-WatchLog "autostart removed: $lnkPath" }
        } else {
            Write-WatchLog "autostart already absent: $lnkPath" 'WARN'
        }
        exit 0
    }
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = $PsExe
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    $sc.WorkingDirectory = Split-Path -Parent $PSCommandPath
    $sc.Description = 'Syncs MCP + provider definitions from the Primary OpenCode config to every clone on change'
    $sc.Save()
    # verify-after re-read (never silent-success)
    $chk = $shell.CreateShortcut($lnkPath)
    if ($chk.TargetPath -eq $sc.TargetPath -and $chk.Arguments -eq $sc.Arguments) {
        Write-WatchLog "autostart installed: $lnkPath"
    } else {
        Write-WatchLog "autostart INSTALL FAILED - read-back mismatch on $lnkPath" 'FAIL'
    }
    exit 0
}

# ---- One-shot / resident ----------------------------------------------------
if ($RunOnce) {
    Write-WatchLog ("one-shot pass starting (DryRun {0})" -f [bool]$DryRun)
    $status = Invoke-WatchPass
    Write-WatchLog ("single pass complete (-RunOnce, status {0})" -f $status)
    exit 0
}

# Resident console title: self-identifying no matter how it was launched.
try { $Host.UI.RawUI.WindowTitle = 'OpenCode Config Sync Watcher (pid {0})' -f $PID } catch { }

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
$mutex = New-Object System.Threading.Mutex($true, 'OpencodeConfigSyncWatcher', [ref]$created)
if (-not $created) {
    $holder = Get-OtherWatcherPids
    $who = ''
    if ($holder.Count -gt 0) { $who = ' by pid ' + ($holder -join ', ') }
    Write-WatchLog ('watcher already running (mutex held{0}) - exiting. Check the log or Task Manager.' -f $who) 'WARN'
    $mutex.Close()
    exit 0
}
Write-WatchLog ('watcher started (pid {0}, interval {1}s, script {2})' -f $PID, $IntervalSeconds, $PSCommandPath)
try {
    while ($true) {
        $status = Invoke-WatchPass
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Close()
    Write-WatchLog 'watcher stopped'
}
