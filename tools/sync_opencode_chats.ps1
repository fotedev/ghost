#Requires -Version 5.1
<#
.SYNOPSIS
  OpenCode cross-instance chat sync (Primary -> clones, guarded one-way
  import). The store contract was mined 2026-11-19 from the live
  ~\.local\share\opencode\opencode.db (58 sessions / 2772 messages):
  sessions live IN the db (session_v2 -> session_message JSON payload +
  session_part + blob/blob_ref + instruction_* rows); project ids are
  stable per worktree path across instances, so a project row is reused
  by path or copied verbatim; auth never lives in the db (account/
  credential/control_account are NEVER touched). All SQL runs in the
  Python core (src/python/ghost/opencode.py via ghost_cli.py; base64 JSON
  payload in, JSON verdict out) - this script is orchestration only:
  lockfile running-clone gate (CS-1 probe), source/target resolution,
  diff planning, audit JSONL (ids + counts only - never message bodies).

.DESCRIPTION
  Modes:
    default            - inventory + diff report (source vs each target).
    -SessionIds <ids>  - plan/import those sessions (the core expands each
                         selection to ancestors + descendants).
    -AllMissing        - plan/import EVERY source session the target lacks.
    -Apply             - execute the planned import (without it the core
                         runs its zero-write dry-run).
    -Revert -ImportId  - delete exactly one import (manifest-driven; FK
                         cascades wipe messages/parts/instruction rows).

  Session ids are the identity and are PRESERVED (PK idempotence:
  re-import of a present id is a reported skip; a reverted import becomes
  plannable again). Imported titles get an "[import] " tag (D11
  convention). Every real import/revert takes a WAL-safe db backup first
  and is verify-after counted before the manifest record lands at
  <CloneHome>\chat-sync-manifest.json; audit at
  <CloneHome>\chat-sync-audit.jsonl.

  Running clone (desktop lockfile held) = SKIP + WARN; a clone with no
  data\opencode\opencode.db yet = SKIP (never used). The SOURCE is opened
  read-only (WAL readers coexist with a live Primary) and is never
  written.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_chats.ps1 -Target All
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_chats.ps1 -Instance c1 -AllMissing -Apply
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_chats.ps1 -Instance c1 -AllMissing -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_chats.ps1 -Instance c1 -Revert -ImportId <id>
#>
param(
    [ValidatePattern('^c[1-5]$')]
    [string]$Instance,

    [ValidateSet('All')]
    [string]$Target,

    # Source instance for the import ('Primary' default, or a clone home).
    [ValidatePattern('^(?i:Primary|c[1-5])$')]
    [string]$From = 'Primary',

    [string[]]$SessionIds,

    [switch]$AllMissing,

    # execute the planned import (without it: core zero-write dry-run)
    [switch]$Apply,

    [switch]$DryRun,

    [switch]$Revert,
    [string]$ImportId,

    # Fixture-testing overrides (the probe suite points these at %TEMP%).
    [string]$PrimaryDataRoot,
    [string]$ClonesRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:Failed = $false

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { [void]$_ }

# Agent/CI shells can run with empty %LOCALAPPDATA% / %APPDATA% (G12).
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData') }
if (-not $env:APPDATA)     { $env:APPDATA     = [Environment]::GetFolderPath('ApplicationData') }

# --- Python core (same bridge the AutoClaw2 chat sync uses) -------------------
. (Join-Path $repoRoot 'src\windows\identity_utils.ps1')

$python = Get-PythonCommandInfo
if (-not $python) {
    Write-Host '[FAILED] Python 3 not found - the OpenCode chat core needs it (functional probe failed).' -ForegroundColor Red
    exit 1
}
$cli = Get-GhostPythonCli
if (-not $cli) { $cli = Join-Path $repoRoot 'src\python\ghost_cli.py' }
if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "[FAILED] Python core bootstrap missing: $cli" -ForegroundColor Red
    exit 1
}
Set-GhostConsoleUtf8

function Invoke-Oc([string]$command, [hashtable]$payload) {
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $out = & $python $cli $command $b64
    if ($LASTEXITCODE -notin 0, 2) {
        throw "$command failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    $verdict = ($out | Select-Object -First 1) | ConvertFrom-Json
    return @{ exit = $LASTEXITCODE; verdict = $verdict }
}

# --- Resolve paths --------------------------------------------------------------
if (-not $ClonesRoot) { $ClonesRoot = Join-Path $env:USERPROFILE 'OpenCodeClonesHome' }
function Get-CloneDataRoot([string]$name) {
    return Join-Path (Join-Path $ClonesRoot $name) 'data\opencode'
}
if ($PrimaryDataRoot) {
    $primaryDataRoot = $PrimaryDataRoot
} else {
    $primaryDataRoot = Join-Path $env:USERPROFILE '.local\share\opencode'
}
function Get-SourceDataRoot([string]$from) {
    if ($from -ieq 'Primary') { return $primaryDataRoot }
    return Get-CloneDataRoot $from
}

$sourceDataRoot = Get-SourceDataRoot $From
$sourceDb = Join-Path $sourceDataRoot 'opencode.db'

$instances = @()
if ($Revert) {
    if (-not $ImportId) {
        Write-Host '[FAILED] -Revert needs -ImportId.' -ForegroundColor Red
        exit 1
    }
}
if ($Instance) { $instances = @($Instance) }
elseif ($Target -eq 'All') {
    $instances = @(Get-ChildItem -LiteralPath $ClonesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^c[1-5]$' } | ForEach-Object { $_.Name } | Sort-Object)
}
else {
    # default: inventory-diff only needs targets; revert too
    Write-Host '[FAILED] give -Instance cN or -Target All.' -ForegroundColor Red
    exit 1
}
if ($instances.Count -eq 0) {
    Write-Host "[skip] no clone homes under $ClonesRoot - nothing to sync."
    exit 0
}
if ($From -ieq 'Primary' -and -not (Test-Path -LiteralPath $sourceDb)) {
    Write-Host "[skip] no Primary chat store at $sourceDb - nothing to sync."
    exit 0
}
if ($From -imatch '^c[1-5]$' -and -not (Test-Path -LiteralPath $sourceDb)) {
    Write-Host "[skip] source clone $From has no chat store at $sourceDb."
    exit 0
}

$exitCode = 0
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

foreach ($inst in $instances) {
    $cloneHome = Join-Path $ClonesRoot $inst
    $cloneDataRoot = Get-CloneDataRoot $inst
    $targetDb = Join-Path $cloneDataRoot 'opencode.db'
    $manifestPath = Join-Path $cloneHome 'chat-sync-manifest.json'
    $auditPath = Join-Path $cloneHome 'chat-sync-audit.jsonl'
    $backupRoot = Join-Path $cloneHome 'chat-sync-backups'
    $lockfile = Join-Path $cloneHome 'desktop\lockfile'

    if (-not (Test-Path -LiteralPath $cloneHome)) { Write-Host "[skip] $inst`: no clone home."; continue }

    # Running clone: the per-clone single-instance lockfile (CS-1 probe
    # shape) - held = RUNNING -> SKIP + WARN.
    if (Test-Path -LiteralPath $lockfile) {
        $lockHeld = $false
        try {
            $fs = [System.IO.File]::Open($lockfile, 'Open', 'Read', 'None')
            $fs.Close()
        } catch { $lockHeld = $true }
        if ($lockHeld) {
            Write-Warning "$inst appears RUNNING (lockfile held) - SKIPPED (close the clone and re-run)."
            continue
        }
    }

    # --- revert ---------------------------------------------------------------
    if ($Revert) {
        $r = Invoke-Oc 'oc-chat-revert' @{
            target_db    = $targetDb
            manifest_path = $manifestPath
            backup_root  = $backupRoot
            import_id    = $ImportId
            dry_run      = [bool]$DryRun
            label        = "oc-chat-revert-$stamp"
        }
        if ($r.exit -eq 2) {
            Write-Host "  [refused] $inst`: $($r.verdict.message)" -ForegroundColor Yellow
            $exitCode = 1
            continue
        }
        if ($DryRun) {
            Write-Host ("  [dry-run] $inst` would delete sessions: {0}" -f (@($r.verdict.session_ids) -join ', '))
            continue
        }
        if ($r.verdict.status -eq 'ok') {
            Write-Host ("  [ok] $inst` reverted import {0}: deleted {1} session(s), backup {2}" -f $ImportId, @($r.verdict.session_ids).Count, $r.verdict.backup)
        } else {
            Write-Host ("  [FAILED] $inst` revert left {0} row(s) - restore from {1}" -f $r.verdict.rows_left, $r.verdict.backup) -ForegroundColor Red
            $exitCode = 1
        }
        continue
    }

    if (-not (Test-Path -LiteralPath $targetDb)) {
        Write-Host "[skip] $inst`: no chat store yet (data\opencode\opencode.db missing - the clone has never run)."
        continue
    }

    # --- inventory diff ---------------------------------------------------------
    $src = Invoke-Oc 'oc-chat-inventory' @{ db_path = $sourceDb }
    $tgt = Invoke-Oc 'oc-chat-inventory' @{ db_path = $targetDb; manifest_path = $manifestPath }
    if ($src.exit -eq 2 -or $tgt.exit -eq 2) {
        $refusalMsg = $src.verdict.message
        if (-not $refusalMsg) { $refusalMsg = $tgt.verdict.message }
        Write-Host ("  [refused] {0}: {1}" -f $inst, $refusalMsg) -ForegroundColor Yellow
        $exitCode = 1
        continue
    }
    $srcIds = @($src.verdict.sessions | ForEach-Object { $_.session_id })
    $tgtIds = @($tgt.verdict.sessions | ForEach-Object { $_.session_id })
    $tgtSet = @{}
    foreach ($id in $tgtIds) { $tgtSet[$id] = $true }
    $missing = @($src.verdict.sessions | Where-Object { -not $tgtSet.ContainsKey($_.session_id) })

    Write-Host ("[{0}] source {1} ({2} sessions, {3} messages) vs target ({4} sessions): {5} missing" -f `
        $inst, $From, @($src.verdict.sessions).Count, `
        (($src.verdict.sessions | Measure-Object -Property messages -Sum).Sum), `
        @($tgt.verdict.sessions).Count, @($missing).Count)

    if (-not $SessionIds -and -not $AllMissing) {
        foreach ($m in $missing) {
            Write-Host ("    missing {0}  [{1} msgs]  {2}" -f $m.session_id, $m.messages, $m.title)
        }
        if (@($missing).Count -eq 0) { Write-Host "    (nothing missing - already in sync)" }
        continue
    }

    # --- plan (dry-run) or apply --------------------------------------------------
    if ($AllMissing) {
        $selection = @($missing | ForEach-Object { $_.session_id })
    } else {
        $wanted = @{}
        foreach ($id in $SessionIds) { $wanted[$id] = $true }
        $unknown = @($wanted.Keys | Where-Object { $srcIds -notcontains $_ })
        if ($unknown.Count -gt 0) {
            Write-Host ("  [FAILED] $inst`: session id(s) not in the source: {0}" -f ($unknown -join ', ')) -ForegroundColor Red
            $exitCode = 1
            continue
        }
        $selection = @($wanted.Keys)
    }
    if ($selection.Count -eq 0) {
        Write-Host "  [ok] $inst`: nothing missing - already in sync."
        continue
    }

    $payload = @{
        source_db     = $sourceDb
        target_db     = $targetDb
        manifest_path = $manifestPath
        backup_root   = $backupRoot
        session_ids   = $selection
        label         = "oc-chat-import-$stamp"
        dry_run       = (-not $Apply) -or [bool]$DryRun
    }
    $r = Invoke-Oc 'oc-chat-import' $payload

    if ($r.exit -eq 2) {
        Write-Host ("  [refused] $inst`: {0}" -f $r.verdict.message) -ForegroundColor Yellow
        $exitCode = 1
        continue
    }

    if (-not $Apply) {
        Write-Host ("  [dry-run] $inst`: would import {0} session(s): {1}" -f `
            @($r.verdict.session_ids).Count, (@($r.verdict.session_ids) -join ', '))
        Write-Host ("    counts: {0}" -f (($r.verdict.counts.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))
        Write-Host "    (plan only - pass -Apply to execute)"
        continue
    }

    if ($r.verdict.status -eq 'skipped') {
        Write-Host "  [ok] $inst`: $($r.verdict.reason)."
        continue
    }
    if ($r.verdict.status -ne 'ok') {
        Write-Host ("  [FAILED] $inst`: import verdict '{0}' - restore the target db from {1}" -f $r.verdict.status, $r.verdict.backup) -ForegroundColor Red
        $exitCode = 1
        continue
    }

    Write-Host ("  [ok] $inst`: imported {0} session(s) (import {1}); messages+{2}; backup {3}" -f `
        @($r.verdict.session_ids).Count, $r.verdict.import_id, `
        $r.verdict.counts.messages, $r.verdict.backup)
    if (@($r.verdict.skipped_existing).Count -gt 0) {
        Write-Host ("    already present (skipped): {0}" -f (@($r.verdict.skipped_existing) -join ', '))
    }

    $audit = [ordered]@{
        ts              = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        script          = 'sync_opencode_chats'
        instance        = $inst
        source          = $From
        import_id       = $r.verdict.import_id
        session_ids     = @($r.verdict.session_ids)        # ids only - never bodies
        skipped_existing= @($r.verdict.skipped_existing)
        project_remap   = $r.verdict.project_remap
        counts          = $r.verdict.counts
        verify          = $r.verdict.verify
        backup          = $r.verdict.backup
        dry_run         = [bool]$DryRun
    }
    [System.IO.File]::AppendAllText($auditPath, (($audit | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
}

if ($exitCode -eq 0) { Write-Host '[done] OpenCode chat sync pass complete.' }
exit $exitCode
