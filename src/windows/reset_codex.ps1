#Requires -Version 5.1
# Codex Identity Reset v0.1 - thin manifest over the Python core (the SECOND
# Terminal-Agents resetter, 2026-11-21).
#
# Target: ONE Codex CLI home - the Primary (~\.codex by default) or a
# Terminal-Agents clone home (CodexClonesHome\cN via -Instance). The whole
# store is evidence-mapped (Phase-0 probes, 2026-11-21, CLI 0.166.0,
# docs/TERMINAL_AGENTS_SPEC.md): auth.json (the credential - API key or
# ChatGPT tokens), installation_id (36 B UUID, PROVEN to regenerate on the
# next run), cap_sid (session-token-like), the runtime SQLite stores
# (state_*/logs_*/goals_*/queue_* + -wal/-shm - all PROVEN to regenerate),
# version.json (update-check cache), .sandbox_migration, .sandbox\ logs,
# .tmp\ plugin clones. UNLIKE claude-code there is NO layout asymmetry: the
# Primary and every clone consolidate everything INSIDE the home (CODEX_HOME
# only moves where "inside" is).
#
# SCOPE (NO Electron, NO admin): every file is user-scope; this script never
# self-elevates and never touches the registry. NO process kill - a RUNNING
# codex CLI holds open SQLite handles and rewrites state on exit, so a loud
# WARN asks the user to close sessions for the target home first.
#
# PRESERVATION (chat/config/memory are never wiped - the standing GHOST
# policy):
#   - config.toml: NEVER touched (user model settings, mcp_servers, plugins,
#     marketplaces, projects trust, hooks - nothing identity/telemetry lives
#     there).
#   - AGENTS.md (user instructions), .codex-global-state.json (+ .bak, the
#     desktop app's UI state): NEVER touched.
#   - history.jsonl, session_index.jsonl, transcription-history.jsonl:
#     NEVER touched.
#   - sessions\ (chat rollout transcripts), memories_*.sqlite and
#     thread_history_*.sqlite (+ -wal/-shm): chat/memory state, NEVER touched.
#   - MCP_Backups\, plugins\, skills\, vendor_imports\, visualizations\,
#     computer-use\, sqlite\, dictation-history\, pets\: NEVER touched.
#   - USER-MADE *.bak-<name> files: never touched.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File reset_codex.ps1              # reset the Primary (~\.codex)
#   powershell -ExecutionPolicy Bypass -File reset_codex.ps1 -Instance c1 # reset clone home c1
#   powershell -ExecutionPolicy Bypass -File reset_codex.ps1 -CodexDir "C:\path" -DryRun
#   powershell -ExecutionPolicy Bypass -File reset_codex.ps1 -DryRun      # plan only - writes nothing
#
# Requirement: Python (functional probe) - every store mutation runs through
# src\python\ghost_cli.py (base64 payload in, JSON report out).
# After a reset: re-login with `codex login` (one credential = one instance)
# or -Login on the light-worker launcher for a clone home.

param(
    [switch]$DryRun,
    [string]$CodexDir = '',
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
    $targetDir = Join-Path $UserProfile ("CodexClonesHome\" + $Instance)
}
elseif (-not [string]::IsNullOrWhiteSpace($CodexDir)) {
    $targetDir = $CodexDir
}
else {
    $targetDir = Join-Path $UserProfile ".codex"
}

$authPath = Join-Path $targetDir "auth.json"
$installationIdPath = Join-Path $targetDir "installation_id"
$capSidPath = Join-Path $targetDir "cap_sid"
$versionJsonPath = Join-Path $targetDir "version.json"
$sandboxMigrationPath = Join-Path $targetDir ".sandbox_migration"
$sandboxDir = Join-Path $targetDir ".sandbox"
$tmpDir = Join-Path $targetDir ".tmp"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $targetDir ("ID_Backups\" + $timestamp)

# Runtime SQLite stores (Phase-0 evidence, 2026-11-21): the CLI auto-generates
# state_5/logs_2/goals_1/queue_1 (+ -wal/-shm) on every real run. The numbered
# names carry schema versions, so the sweep targets the four PREFIXES with
# their wal/shm siblings - memories_*.sqlite and thread_history_*.sqlite are
# deliberately NOT in the pattern (memory + chat threads = preserved).
$script:CodexRuntimeSqliteFilters = @("state_*.sqlite*", "logs_*.sqlite*", "goals_*.sqlite*", "queue_*.sqlite*")

# --- W1-9-style report-only planner -------------------------------------------
# Prints the resolved target + step plan with presence, then exits BEFORE any
# write or kill. Zero side effects by construction; the step list mirrors the
# "--- [N/6]" headings below (tests cross-check the two).
if ($DryRun) {
    Write-Host "=== DRY-RUN PLAN - Codex Identity Reset v0.1 ===" -ForegroundColor Cyan
    Write-Host ("Target codex home  : {0} ({1})" -f $targetDir, $(if (Test-Path -LiteralPath $targetDir) { "present" } else { "NOT FOUND - the real run would abort here" }))
    foreach ($planPath in @(
        @{ label = "auth.json              "; path = $authPath },
        @{ label = "installation_id        "; path = $installationIdPath },
        @{ label = "cap_sid                "; path = $capSidPath },
        @{ label = "version.json           "; path = $versionJsonPath },
        @{ label = ".sandbox_migration     "; path = $sandboxMigrationPath },
        @{ label = ".sandbox\              "; path = $sandboxDir },
        @{ label = ".tmp\                  "; path = $tmpDir }
    )) {
        Write-Host ("{0}: {1} ({2})" -f $planPath.label, $planPath.path, $(if (Test-Path -LiteralPath $planPath.path) { "present" } else { "missing (skips)" }))
    }
    $sqliteHits = 0
    foreach ($flt in $script:CodexRuntimeSqliteFilters) {
        $hits = @(Get-ChildItem -LiteralPath $targetDir -File -Filter $flt -ErrorAction SilentlyContinue)
        Write-Host ("{0}: {1} file(s) ({2})" -f ("sqlite " + $flt).PadRight(15), $hits.Count, $flt)
        $sqliteHits += $hits.Count
    }
    $planCoreOk = [bool](Get-GhostPythonCli)
    if (-not $planCoreOk) {
        Write-Host "Python core        : MISSING - the real run would fail fast here (every step needs it)." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Running codex sessions: NOT killed - a live CLI holds SQLite handles and rewrites"
    Write-Host "state on exit. Close codex sessions using this home first."
    Write-Host ""
    Write-Host "Step plan:"
    foreach ($planStep in @(
        "[1/6] auth.json delete (backup-first; forces re-login)",
        "[2/6] installation_id delete (backup-first; PROVEN regenerated fresh on next run)",
        "[3/6] cap_sid sweep (session-token-like; absent on fresh homes)",
        "[4/6] runtime SQLite sweep: state_*/logs_*/goals_*/queue_* + wal/shm (memories/thread_history PRESERVED)",
        "[5/6] version.json + .sandbox_migration + .sandbox\ + .tmp\ sweeps",
        "[6/6] verify-after"
    )) {
        Write-Host ("  {0}" -f $planStep)
    }
    Write-Host ""
    Write-Host "Preserved per policy: config.toml, AGENTS.md, .codex-global-state.json, history.jsonl,"
    Write-Host "session_index.jsonl, sessions\, memories_*.sqlite, thread_history_*.sqlite, MCP_Backups\,"
    Write-Host "plugins\, skills\, vendor_imports\, visualizations\, computer-use\, sqlite\, and USER-MADE backups."
    Write-Host ""
    Write-Host "DRY-RUN complete - nothing was written or killed." -ForegroundColor Green
    exit 0
}

# --- Preflight -----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $targetDir)) {
    Write-Host "[ABORT] target codex home not found: $targetDir" -ForegroundColor Red
    Write-Host "        (a Codex clone home is created by its first launch - Terminal Agents [6])"
    exit 1
}
# Fresh/never-run guard: BOTH identity anchors absent = a fresh home (a run
# attempt generates installation_id immediately - live-verified 2026-11-21).
if ((-not (Test-Path -LiteralPath $authPath)) -and (-not (Test-Path -LiteralPath $installationIdPath))) {
    Write-Host "[ABORT] fresh/never-run home - no auth.json and no installation_id: $targetDir" -ForegroundColor Red
    Write-Host "        (nothing to reset)"
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

Write-GhostBanner -Target "Codex Identity Reset" -Version "0.1"

$runningWarn = @(Get-Process -Name "codex*" -ErrorAction SilentlyContinue)
if ($runningWarn.Count -gt 0) {
    Write-Host "[WARN] codex process(es) running - a live CLI holds SQLite handles and may rewrite" -ForegroundColor Yellow
    Write-Host "[WARN] state on exit and undo this scrub. Close codex sessions using this home first." -ForegroundColor Yellow
}

# === Local helpers =============================================================

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

# --- [1/6] auth.json delete (forces re-login) -----------------------------------
Write-Host "--- [1/6] auth.json delete ---"
if (Test-Path -LiteralPath $authPath) {
    try {
        Backup-ViaCore -Source $authPath -Label "auth.json" -Actions ([ref]$actions) | Out-Null
        $authReport = Invoke-GhostCore @("sweep-file", $authPath)
        if ($null -ne $authReport -and $authReport.ok) {
            Add-AuditEntry -Audit ([ref]$audit) -File $authPath -Key "credential" -Before "present" -After "deleted" -Ok $true
            $passCount++
            Write-Host "    deleted (backup kept) - re-login required (codex login)."
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $authPath -Key "credential" -Before "present" -After "sweep-failed" -Ok $false
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
    Add-AuditEntry -Audit ([ref]$audit) -File $authPath -Key "credential" -Before "absent" -After "absent (already logged out)" -Ok $true
    Write-Host "    absent - already logged out (verified no-op)."
}

# --- [2/6] installation_id delete (regenerates fresh) ----------------------------
Write-Host "--- [2/6] installation_id delete ---"
if (Test-Path -LiteralPath $installationIdPath) {
    try {
        Backup-ViaCore -Source $installationIdPath -Label "installation_id" -Actions ([ref]$actions) | Out-Null
        $idReport = Invoke-GhostCore @("sweep-file", $installationIdPath)
        if ($null -ne $idReport -and $idReport.ok) {
            Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "install id" -Before "present" -After "deleted" -Ok $true
            $passCount++
            Write-Host "    deleted (backup kept) - next run generates a FRESH install id (live-verified)."
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "install id" -Before "present" -After "sweep-failed" -Ok $false
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
    Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "install id" -Before "absent" -After "absent" -Ok $true
    Write-Host "    absent - skip (absence-tolerant)."
}

# --- [3/6] cap_sid sweep (session-token-like) -------------------------------------
Write-Host "--- [3/6] cap_sid sweep ---"
if (Test-Path -LiteralPath $capSidPath) {
    try {
        Backup-ViaCore -Source $capSidPath -Label "cap_sid" -Actions ([ref]$actions) | Out-Null
        $capReport = Invoke-GhostCore @("sweep-file", $capSidPath)
        if ($null -ne $capReport -and $capReport.ok) {
            Add-AuditEntry -Audit ([ref]$audit) -File $capSidPath -Key "cap_sid" -Before "present" -After "swept" -Ok $true
            $passCount++
            Write-Host "    swept (backup kept)."
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $capSidPath -Key "cap_sid" -Before "present" -After "sweep-failed" -Ok $false
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
    Add-AuditEntry -Audit ([ref]$audit) -File $capSidPath -Key "cap_sid" -Before "absent" -After "absent" -Ok $true
    Write-Host "    absent - skip (absence-tolerant; fresh homes don't have one)."
}

# --- [4/6] runtime SQLite stores sweep ---------------------------------------------
Write-Host "--- [4/6] runtime SQLite sweep (state/logs/goals/queue) ---"
$sqliteFiles = @()
foreach ($flt in $script:CodexRuntimeSqliteFilters) {
    $sqliteFiles += @(Get-ChildItem -LiteralPath $targetDir -File -Filter $flt -ErrorAction SilentlyContinue)
}
if ($sqliteFiles.Count -eq 0) {
    Add-AuditEntry -Audit ([ref]$audit) -File $targetDir -Key "runtime sqlite" -Before "0 files" -After "0 files (nothing to sweep)" -Ok $true
    Write-Host "    no runtime store files (verified no-op)."
}
else {
    $sweepFail = 0
    foreach ($sq in $sqliteFiles) {
        $rep = Invoke-GhostCore @("sweep-file", $sq.FullName)
        if ($null -ne $rep -and $rep.ok) { $passCount++ } else { $sweepFail++ }
    }
    if ($sweepFail -eq 0) {
        Add-AuditEntry -Audit ([ref]$audit) -File $targetDir -Key "runtime sqlite" -Before "$($sqliteFiles.Count) files" -After "swept" -Ok $true
        Write-Host ("    swept {0} runtime store file(s) (regenerate on next run)." -f $sqliteFiles.Count)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $targetDir -Key "runtime sqlite" -Before "$($sqliteFiles.Count) files" -After "$sweepFail failed" -Ok $false
        Write-Host "    [FAILED] $sweepFail runtime store file(s) could not be swept" -ForegroundColor Red
        $failCount++
    }
}

# --- [5/6] version.json + .sandbox_migration + .sandbox\ + .tmp\ sweeps ------------
Write-Host "--- [5/6] version.json + sandbox + tmp sweeps ---"
foreach ($target in @(
    @{ kind = "file"; path = $versionJsonPath; label = "version.json (update-check cache)" },
    @{ kind = "file"; path = $sandboxMigrationPath; label = ".sandbox_migration" },
    @{ kind = "tree"; path = $sandboxDir; label = ".sandbox (logs)" },
    @{ kind = "tree"; path = $tmpDir; label = ".tmp (plugin clones)" }
)) {
    if (-not (Test-Path -LiteralPath $target.path)) {
        Add-AuditEntry -Audit ([ref]$audit) -File $target.path -Key $target.label -Before "absent" -After "absent" -Ok $true
        Write-Host ("    {0}: absent - skip (absence-tolerant)." -f $target.label)
        continue
    }
    $rep = if ($target.kind -eq "tree") { Invoke-GhostCore @("sweep-tree", $target.path, $backupRoot, $target.label) }
           else { Invoke-GhostCore @("sweep-file", $target.path) }
    if ($null -ne $rep -and $rep.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $target.path -Key $target.label -Before "present" -After "swept" -Ok $true
        $passCount++
        Write-Host ("    {0}: swept." -f $target.label)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $target.path -Key $target.label -Before "present" -After "sweep-failed" -Ok $false
        Write-Host ("    [FAILED] {0} sweep failed" -f $target.label) -ForegroundColor Red
        $failCount++
    }
}

# --- [6/6] verify-after --------------------------------------------------------------
Write-Host "--- [6/6] verify-after ---"
$verifyOk = $true
if (Test-Path -LiteralPath $authPath) {
    Write-Host "    [FAILED] auth.json still present" -ForegroundColor Red
    $verifyOk = $false
}
if (Test-Path -LiteralPath $installationIdPath) {
    Write-Host "    [FAILED] installation_id still present" -ForegroundColor Red
    $verifyOk = $false
}
$leftoverSqlite = @()
foreach ($flt in $script:CodexRuntimeSqliteFilters) {
    $leftoverSqlite += @(Get-ChildItem -LiteralPath $targetDir -File -Filter $flt -ErrorAction SilentlyContinue)
}
if ($leftoverSqlite.Count -gt 0) {
    Write-Host ("    [FAILED] {0} runtime SQLite file(s) still present" -f $leftoverSqlite.Count) -ForegroundColor Red
    $verifyOk = $false
}
if ($verifyOk) {
    Add-AuditEntry -Audit ([ref]$audit) -File $targetDir -Key "verify-after" -Before "-" -After "auth absent + install id absent + runtime sqlite absent" -Ok $true
    $passCount++
    Write-Host "    OK - credential gone, install id gone, runtime stores gone. Next run generates a FRESH identity."
}

# --- restore script + audit + summary ---------------------------------------------
$restorePath = New-RestoreScript -BackupRoot $backupRoot -App "CodexIdentityReset" -Actions $actions
Write-AuditLog -Audit $audit -Path (Join-Path $backupRoot "codex_reset_audit.jsonl")

Write-Host ""
Write-Host "=== Codex reset complete: $passCount ok, $failCount failed ==="  -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ("Backups: {0}" -f $backupRoot)
if ($restorePath) { Write-Host ("Restore script: {0}" -f $restorePath) }
Write-Host ""
Write-Host "Re-login recipe (one credential = one instance):"
if (-not [string]::IsNullOrWhiteSpace($Instance)) {
    Write-Host ("  Terminal Agents [7]  (the -Login flow for {0}, sets CODEX_HOME itself)" -f $Instance)
}
else {
    Write-Host "  codex login"
}
if ($failCount -gt 0) { exit 1 }
exit 0
