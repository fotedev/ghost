#Requires -Version 5.1
# Claude Code Identity Reset v0.1 - thin manifest over the Python core
# (the FIRST Terminal-Agents resetter, 2026-11-21).
#
# Target: ONE Claude Code config dir - the Primary (~\.claude by default) or
# a Terminal-Agents clone home (ClaudeCodeClonesHome\cN via -Instance). The
# whole store is evidence-mapped (Phase-0 probes, 2026-11-21, CLI 2.1.314,
# docs/TERMINAL_AGENTS_SPEC.md): .claude.json (identity + telemetry keys),
# .credentials.json (OAuth token), backups\.claude.json.backup.* (old
# machineID copies), state\, mcp-needs-auth-cache.json, cache\, statsig\.
#
# SCOPE (NO Electron, NO admin): every file is user-scope; this script never
# self-elevates and never touches the registry. NO process kill - claude-code
# has no lockfiles, but a RUNNING claude CLI rewrites .claude.json on exit,
# so a loud WARN asks the user to close sessions for the target dir first.
#
# PRESERVATION (chat/config are never wiped - the standing GHOST policy):
#   - projects\ (transcripts), sessions\, session-env\, history.jsonl: NEVER
#     touched (audited).
#   - settings.json, skills\, plugins\, daemon\: config/runtime, NEVER touched.
#   - .claude.json mcpServers + projects keys + hasCompletedOnboarding +
#     migration flags: preserved (only the named identity/telemetry keys go).
#   - ~\.claude.json.bak-<name> USER-MADE backups (e.g. .bak-obsidian): never
#     touched. Only claude-code's own backups\.claude.json.backup.* remnants go.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File reset_claude_code.ps1              # reset the Primary (~\.claude)
#   powershell -ExecutionPolicy Bypass -File reset_claude_code.ps1 -Instance c1 # reset clone home c1
#   powershell -ExecutionPolicy Bypass -File reset_claude_code.ps1 -ConfigDir "C:\path" -DryRun
#   powershell -ExecutionPolicy Bypass -File reset_claude_code.ps1 -DryRun      # plan only - writes nothing
#
# Requirement: Python (functional probe) - every store mutation runs through
# src\python\ghost_cli.py (base64 payload in, JSON report out).
# After a reset: re-login with `claude auth login` (one credential = one
# instance) or -Login on the light-worker launcher for a clone home.

param(
    [switch]$DryRun,
    [string]$ConfigDir = '',
    [ValidateSet('c1', 'c2', 'c3', 'c4', 'c5')]
    [string]$Instance = ''
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"
Set-GhostConsoleUtf8

# --- Store paths (hoisted above the DryRun planner; no side effects) ----------
$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }

if (-not [string]::IsNullOrWhiteSpace($Instance)) {
    $targetDir = Join-Path $UserProfile ("ClaudeCodeClonesHome\" + $Instance)
}
elseif (-not [string]::IsNullOrWhiteSpace($ConfigDir)) {
    $targetDir = $ConfigDir
}
else {
    $targetDir = Join-Path $UserProfile ".claude"
}

# .claude.json placement is LAYOUT-ASYMMETRIC (Phase-0 evidence, 2026-11-21):
#   - Primary (no CLAUDE_CONFIG_DIR): the JSON store stays at the PROFILE ROOT
#     (~\.claude.json) while the dir tree lives in ~\.claude\ (observed live).
#   - Clone/-ConfigDir (CLAUDE_CONFIG_DIR=X): everything consolidates INSIDE
#     X - a fresh probe created X\.claude.json + X\backups\ there.
if (-not [string]::IsNullOrWhiteSpace($Instance) -or -not [string]::IsNullOrWhiteSpace($ConfigDir)) {
    $claudeJsonPath = Join-Path $targetDir ".claude.json"
}
else {
    $claudeJsonPath = Join-Path $UserProfile ".claude.json"
}
$credentialsPath = Join-Path $targetDir ".credentials.json"
$backupsDir = Join-Path $targetDir "backups"
$stateDir = Join-Path $targetDir "state"
$mcpNeedsAuthPath = Join-Path $targetDir "mcp-needs-auth-cache.json"
$cacheDir = Join-Path $targetDir "cache"
$statsigDir = Join-Path $targetDir "statsig"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $targetDir ("ID_Backups\" + $timestamp)

# Identity + telemetry keys in .claude.json (Phase-0 evidence, 2026-11-21).
# Everything else in the file - mcpServers, projects, settings-shaped flags,
# hasCompletedOnboarding, migration flags - is PRESERVED. Removing an
# already-absent key is a verified no-op (the core reports count=0).
$script:ClaudeIdentityKeys = @(
    "machineID",                  # device identity (regenerates fresh on next run)
    "userID",                     # anonymous analytics id
    "firstStartTime",             # usage telemetry
    "numStartups",                # usage telemetry
    "tipsHistory",                # engagement telemetry
    "tipLifetimeShownCounts",     # engagement telemetry
    "seenNotifications",          # engagement telemetry
    "lastReleaseNotesSeen",       # engagement telemetry
    "changelogLastFetched",       # engagement telemetry
    "closedIssuesLastChecked",    # engagement telemetry
    "skillUsage",                 # usage telemetry
    "pluginUsage",                # usage telemetry
    "lastPlanModeUse"             # usage telemetry
)

# --- W1-9-style report-only planner -------------------------------------------
# Prints the resolved target + step plan with presence, then exits BEFORE any
# write or kill. Zero side effects by construction; the step list mirrors the
# "--- [N/6]" headings below (tests cross-check the two).
if ($DryRun) {
    Write-Host "=== DRY-RUN PLAN - Claude Code Identity Reset v0.1 ===" -ForegroundColor Cyan
    Write-Host ("Target config dir : {0} ({1})" -f $targetDir, $(if (Test-Path -LiteralPath $targetDir) { "present" } else { "NOT FOUND - the real run would abort here" }))
    foreach ($planPath in @(
        @{ label = ".claude.json              "; path = $claudeJsonPath },
        @{ label = ".credentials.json         "; path = $credentialsPath },
        @{ label = "backups\.claude.json.bak* "; path = $backupsDir },
        @{ label = "state\                    "; path = $stateDir },
        @{ label = "mcp-needs-auth-cache.json "; path = $mcpNeedsAuthPath },
        @{ label = "cache\                    "; path = $cacheDir },
        @{ label = "statsig\                  "; path = $statsigDir }
    )) {
        Write-Host ("{0}: {1} ({2})" -f $planPath.label, $planPath.path, $(if (Test-Path -LiteralPath $planPath.path) { "present" } else { "missing (skips)" }))
    }
    $planCoreOk = [bool](Get-GhostPythonCli)
    if (-not $planCoreOk) {
        Write-Host "Python core       : MISSING - the real run would fail fast here (every step needs it)." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Running claude sessions: NOT killed (no lockfiles) - a live CLI may rewrite .claude.json"
    Write-Host "on exit and undo the scrub. Close claude sessions using this config dir first."
    Write-Host ""
    Write-Host "Step plan:"
    foreach ($planStep in @(
        "[1/6] .claude.json identity/telemetry keys remove (json-remove; mcpServers+projects PRESERVED)",
        "[2/6] .credentials.json delete (backup-first; forces re-login)",
        "[3/6] backups\.claude.json.backup.* sweep (old machineID copies)",
        "[4/6] state\ + mcp-needs-auth-cache.json sweep",
        "[5/6] cache\ sweep (sweep-tree; regenerates)",
        "[6/6] statsig\ sweep (absence-tolerant, newer installs) + verify-after"
    )) {
        Write-Host ("  {0}" -f $planStep)
    }
    Write-Host ""
    Write-Host "Preserved per policy: projects\ transcripts, sessions\, session-env\, history.jsonl,"
    Write-Host "settings.json, skills\, plugins\, daemon\, .claude.json mcpServers/projects/flags,"
    Write-Host "and USER-MADE ~\.claude.json.bak-<name> backups."
    Write-Host ""
    Write-Host "DRY-RUN complete - nothing was written or killed." -ForegroundColor Green
    exit 0
}

# --- Preflight -----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $targetDir)) {
    Write-Host "[ABORT] target config dir not found: $targetDir" -ForegroundColor Red
    Write-Host "        (a Claude Code clone home is created by its first launch - Terminal Agents [1])"
    exit 1
}
if (-not (Test-Path -LiteralPath $claudeJsonPath)) {
    Write-Host "[ABORT] .claude.json not found: $claudeJsonPath" -ForegroundColor Red
    Write-Host "        (fresh/never-run home - nothing to reset)"
    exit 1
}
if (-not (Get-GhostPythonCli)) {
    Write-Host "[FAILED] GHOST Python core not found (src\python\ghost_cli.py)." -ForegroundColor Red
    exit 1
}
$pythonCommand = Get-PythonCommandInfo
if (-not $pythonCommand) {
    Write-Host "[FAILED] no functional Python 3 found - every reset step needs it." -ForegroundColor Red
    exit 1
}

Write-GhostBanner -Target "Claude Code Identity Reset" -Version "0.1"

$runningWarn = @(Get-Process -Name "claude*" -ErrorAction SilentlyContinue)
if ($runningWarn.Count -gt 0) {
    Write-Host "[WARN] claude process(es) running - a live CLI may rewrite .claude.json on exit and" -ForegroundColor Yellow
    Write-Host "[WARN] undo this scrub. Close claude sessions using this config dir first if unsure." -ForegroundColor Yellow
}

# === Local helpers =============================================================

function _B64Payload {
    # Compact JSON -> base64: the core bridge's payload contract (sidesteps
    # PS 5.1 native-argument quoting entirely).
    param([Parameter(Mandatory = $true)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Invoke-GhostCore {
    # The one PS -> Python invocation point for every store mutation.
    # Returns the parsed JSON report, or $null when the core is missing or
    # the subcommand failed (exit code non-zero).
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)
    $cli = Get-GhostPythonCli
    if (-not $cli) { return $null }
    $output = & $pythonCommand $cli @CliArgs
    if ($LASTEXITCODE -ne 0) { return $null }
    try {
        return ($output -join "`n") | ConvertFrom-Json
    }
    catch {
        Write-Host "[FAILED] unparseable core output: $($output -join ' ')" -ForegroundColor Red
        return $null
    }
}

function Backup-ViaCore {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][ref]$Actions
    )
    $report = Invoke-GhostCore @("backup", $Source, $backupRoot, $Label)
    if ($null -eq $report) {
        Write-Host "    [WARN] backup FAILED - proceeding WITHOUT backup: $Source" -ForegroundColor Yellow
        return $false
    }
    if ($report.skipped) { return $false }
    if ($report.ok -and $report.destination) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Source -BackupPath $report.destination
        return $true
    }
    Write-Host "    [WARN] backup did not complete ($($report.error)) - proceeding" -ForegroundColor Yellow
    return $false
}

function Add-ActionEntry {
    # The per-script restore-manifest action accumulator (same shape as the
    # other thin-manifest resetters - this helper is local by convention).
    param(
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [string]$BackupPath,
        [string]$RenamedPath
    )
    $Actions.Value += [ordered]@{
        action       = "copy"
        originalPath = $OriginalPath
        backupPath   = $BackupPath
        renamedPath  = $RenamedPath
    }
}

$audit = @()
$actions = @()
$failCount = 0
$passCount = 0

# --- [1/6] .claude.json identity/telemetry key removal -------------------------
Write-Host "--- [1/6] .claude.json identity keys remove ---"
try {
    $report = Invoke-GhostCore @("json-remove", $claudeJsonPath, $backupRoot, ".claude.json",
        (_B64Payload @{ keys = $script:ClaudeIdentityKeys; prefixes = @() }))
    if ($null -ne $report -and $report.ok) {
        # the core's report field is `removed` - a LIST of the dotted keys it
        # actually deleted (absent keys report "missing" and stay unlisted)
        $removed = @($report.removed).Count
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $claudeJsonPath -BackupPath $report.backed_up_to
        }
        Add-AuditEntry -Audit ([ref]$audit) -File $claudeJsonPath -Key "identity keys" -Before "$($script:ClaudeIdentityKeys.Count) targeted" -After "$removed removed" -Ok $true
        $passCount++
        Write-Host ("    removed {0}/{1} identity/telemetry key(s) (absent keys = verified no-op)" -f $removed, $script:ClaudeIdentityKeys.Count)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $claudeJsonPath -Key "identity keys" -Before "present" -After "core-invoke-failed" -Ok $false
        Write-Host "    [FAILED] json-remove core invocation failed" -ForegroundColor Red
        $failCount++
    }
}
catch {
    Write-Host ("    [FAILED] {0}" -f $_.Exception.Message) -ForegroundColor Red
    $failCount++
}

# --- [2/6] .credentials.json delete (forces re-login) ---------------------------
Write-Host "--- [2/6] .credentials.json delete ---"
if (Test-Path -LiteralPath $credentialsPath) {
    try {
        Backup-ViaCore -Source $credentialsPath -Label ".credentials.json" -Actions ([ref]$actions) | Out-Null
        $credReport = Invoke-GhostCore @("sweep-file", $credentialsPath)
        if ($null -ne $credReport -and $credReport.ok) {
            Add-AuditEntry -Audit ([ref]$audit) -File $credentialsPath -Key "OAuth token" -Before "present" -After "deleted" -Ok $true
            $passCount++
            Write-Host "    deleted (backup kept) - re-login required (claude auth login)."
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $credentialsPath -Key "OAuth token" -Before "present" -After "sweep-failed" -Ok $false
            Write-Host "    [FAILED] sweep-file core invocation failed" -ForegroundColor Red
            $failCount++
        }
    }
    catch {
        Write-Host ("    [FAILED] {0}" -f $_.Exception.Message) -ForegroundColor Red
        $failCount++
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $credentialsPath -Key "OAuth token" -Before "absent" -After "absent (already logged out)" -Ok $true
    Write-Host "    absent - already logged out (verified no-op)."
}

# --- [3/6] backups\.claude.json.backup.* sweep (old machineID copies) ----------
Write-Host "--- [3/6] backups\.claude.json.backup.* sweep ---"
if (Test-Path -LiteralPath $backupsDir) {
    $staleBackups = @(Get-ChildItem -LiteralPath $backupsDir -File -Filter ".claude.json.backup.*" -ErrorAction SilentlyContinue)
    $sweepFail = 0
    foreach ($sb in $staleBackups) {
        $rep = Invoke-GhostCore @("sweep-file", $sb.FullName)
        if ($null -ne $rep -and $rep.ok) { $passCount++ } else { $sweepFail++ }
    }
    if ($staleBackups.Count -eq 0) {
        Add-AuditEntry -Audit ([ref]$audit) -File $backupsDir -Key ".claude.json.backup.*" -Before "0 files" -After "0 files (nothing to sweep)" -Ok $true
        Write-Host "    no backup remnants (verified no-op)."
    }
    elseif ($sweepFail -eq 0) {
        Add-AuditEntry -Audit ([ref]$audit) -File $backupsDir -Key ".claude.json.backup.*" -Before "$($staleBackups.Count) files" -After "swept" -Ok $true
        Write-Host ("    swept {0} identity-backup remnant(s)." -f $staleBackups.Count)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $backupsDir -Key ".claude.json.backup.*" -Before "$($staleBackups.Count) files" -After "$sweepFail failed" -Ok $false
        Write-Host "    [FAILED] $sweepFail backup remnant(s) could not be swept" -ForegroundColor Red
        $failCount++
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $backupsDir -Key ".claude.json.backup.*" -Before "absent" -After "absent" -Ok $true
    Write-Host "    backups\ absent - skip (absence-tolerant)."
}

# --- [4/6] state\ + mcp-needs-auth-cache.json sweep ------------------------------
Write-Host "--- [4/6] state + mcp-needs-auth-cache sweep ---"
foreach ($stateTarget in @(@{ kind = "tree"; path = $stateDir; label = "state" }, @{ kind = "file"; path = $mcpNeedsAuthPath; label = "mcp-needs-auth-cache.json" })) {
    if (-not (Test-Path -LiteralPath $stateTarget.path)) {
        Add-AuditEntry -Audit ([ref]$audit) -File $stateTarget.path -Key $stateTarget.label -Before "absent" -After "absent" -Ok $true
        Write-Host ("    {0}: absent - skip (absence-tolerant)." -f $stateTarget.label)
        continue
    }
    $rep = if ($stateTarget.kind -eq "tree") { Invoke-GhostCore @("sweep-tree", $stateTarget.path, $backupRoot, $stateTarget.label) }
           else { Invoke-GhostCore @("sweep-file", $stateTarget.path) }
    if ($null -ne $rep -and $rep.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $stateTarget.path -Key $stateTarget.label -Before "present" -After "swept" -Ok $true
        $passCount++
        Write-Host ("    {0}: swept." -f $stateTarget.label)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $stateTarget.path -Key $stateTarget.label -Before "present" -After "sweep-failed" -Ok $false
        Write-Host ("    [FAILED] {0} sweep failed" -f $stateTarget.label) -ForegroundColor Red
        $failCount++
    }
}

# --- [5/6] cache\ + statsig\ tree sweeps -----------------------------------------
Write-Host "--- [5/6] cache + statsig sweeps ---"
foreach ($treeTarget in @(@{ path = $cacheDir; label = "cache" }, @{ path = $statsigDir; label = "statsig (telemetry)" })) {
    if (-not (Test-Path -LiteralPath $treeTarget.path)) {
        Add-AuditEntry -Audit ([ref]$audit) -File $treeTarget.path -Key $treeTarget.label -Before "absent" -After "absent" -Ok $true
        Write-Host ("    {0}: absent - skip (absence-tolerant)." -f $treeTarget.label)
        continue
    }
    $rep = Invoke-GhostCore @("sweep-tree", $treeTarget.path, $backupRoot, $treeTarget.label)
    if ($null -ne $rep -and $rep.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $treeTarget.path -Key $treeTarget.label -Before "present" -After "swept" -Ok $true
        $passCount++
        Write-Host ("    {0}: swept (regenerates on next run)." -f $treeTarget.label)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $treeTarget.path -Key $treeTarget.label -Before "present" -After "sweep-failed" -Ok $false
        Write-Host ("    [FAILED] {0} sweep failed" -f $treeTarget.label) -ForegroundColor Red
        $failCount++
    }
}

# --- [6/6] verify-after -----------------------------------------------------------
Write-Host "--- [6/6] verify-after ---"
$verifyOk = $true
try {
    $afterJson = Get-Content -LiteralPath $claudeJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($vk in @("machineID", "userID", "numStartups")) {
        if ($null -ne $afterJson.PSObject.Properties[$vk]) {
            Write-Host ("    [FAILED] {0} still present in .claude.json" -f $vk) -ForegroundColor Red
            $verifyOk = $false
        }
    }
}
catch {
    Write-Host "    [FAILED] .claude.json unreadable after the scrub" -ForegroundColor Red
    $verifyOk = $false
}
if (Test-Path -LiteralPath $credentialsPath) {
    Write-Host "    [FAILED] .credentials.json still present" -ForegroundColor Red
    $verifyOk = $false
}
if ($verifyOk) {
    Add-AuditEntry -Audit ([ref]$audit) -File $claudeJsonPath -Key "verify-after" -Before "-" -After "identity keys absent + credentials absent" -Ok $true
    $passCount++
    Write-Host "    OK - identity keys absent, credentials gone. Next run generates a FRESH machineID."
}

# --- restore script + audit + summary ---------------------------------------------
$restorePath = New-RestoreScript -BackupRoot $backupRoot -App "ClaudeCodeIdentityReset" -Actions $actions
Write-AuditLog -Audit $audit -Path (Join-Path $backupRoot "claude_code_reset_audit.jsonl")

Write-Host ""
Write-Host "=== Claude Code reset complete: $passCount ok, $failCount failed ==="  -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ("Backups: {0}" -f $backupRoot)
if ($restorePath) { Write-Host ("Restore script: {0}" -f $restorePath) }
Write-Host ""
Write-Host "Re-login recipe (one credential = one instance):"
if (-not [string]::IsNullOrWhiteSpace($Instance)) {
    Write-Host ("  Terminal Agents [2]  (the -Login flow for {0}, sets CLAUDE_CONFIG_DIR itself)" -f $Instance)
}
else {
    Write-Host "  claude auth login"
}
if ($failCount -gt 0) { exit 1 }
exit 0
