#Requires -Version 5.1
<#
.SYNOPSIS
  AutoClaw2 (zwork) chat inventory / guarded one-way history import (Track C,
  docs/AUTOCLAW2_SYNC_SPEC.md decisions D8-D12).

.DESCRIPTION
  All SQL lives in src/python/ghost/autoclaw2.py and runs via
  src/python/ghost_cli.py (base64 JSON payload in, JSON verdict out) - this
  script only orchestrates (same bridge as tools/sync_autoclaw2_mcp.ps1).

  Modes:
    -Mode Inventory (default)  read-only cross-profile report: per-profile
                               session rows plus a Primary->target diff
                               (missing / already-imported / refused-im).
                               Writes nothing but the report JSON at
                               %LOCALAPPDATA%\autoclaw2-sync\.
    -Mode Import               copy ONE source session into each target as a
                               NEW local session ([import] title prefix,
                               provenance sidecar, fresh UUIDv4 ids). Without
                               -Apply this is the dry-run plan only. Hard
                               gates (D10): closed target, matching schema,
                               clean sqlite-backup-API backup first, the
                               entries' immutability triggers stay active,
                               idempotency via the sidecar content hash.
    -Revert -ImportId <id>     tombstone + delete exactly the rows one import
                               created (the sidecar is the source of truth).

  IM-bound (Telegram) sessions are never copied (D12 - one credential one
  instance). Nothing existing in a target is updated or deleted by an import
  (D8); reverting uses the import id, not a search.

  Exit codes: 0 ok, 1 failed (verify mismatch), 2 refused by a gate.

.PARAMETER Target
  Clone(s): c1..c5, All (default) or Primary (import INTO Primary is allowed
  but pointless - the source default).

.PARAMETER Mode
  'Inventory' (default, zero-risk) or 'Import'.

.PARAMETER Source
  Source profile for Import and for the Inventory diff. Default: Primary.

.PARAMETER SessionId
  Source session id to copy (Import mode; required).

.PARAMETER ImportId
  Import id from the sidecar (Revert; required).

.PARAMETER Apply
  Perform the Import write. Without it, Import mode is a dry-run plan.

.PARAMETER DryRun
  Alias semantics for Inventory/Import planning - nothing is ever written.

.PARAMETER TitleTag
  Import title prefix. Default '[import] '; pass '' to disable (D11).

.PARAMETER MaxUnresolvedPct
  Abort when more than this percentage of entries cannot be copied
  (missing artifact/revision). Default 5 (F5).

.PARAMETER Quiet
  Verdict lines only.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_chats.ps1 -Mode Inventory
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_chats.ps1 -Mode Import -SessionId <uuid> -Target c1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_chats.ps1 -Mode Import -SessionId <uuid> -Target c1 -Apply
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_chats.ps1 -Revert -ImportId <uuid> -Target c1
#>
[CmdletBinding()]
param(
    [string]$Target = 'All',
    [ValidateSet('Inventory', 'Import')]
    [string]$Mode = 'Inventory',
    [string]$Source = 'Primary',
    [string]$SessionId,
    [string]$ImportId,
    [switch]$Apply,
    [switch]$DryRun,
    [string]$TitleTag,
    [double]$MaxUnresolvedPct = 5,
    [switch]$Quiet,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:Failed = $false

# Agent/CI shells can run with empty %LOCALAPPDATA% / %APPDATA% (G12): backfill
# from the shell API before anything uses them.
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = [Environment]::GetFolderPath('LocalApplicationData') }
if (-not $env:APPDATA)     { $env:APPDATA     = [Environment]::GetFolderPath('ApplicationData') }

function Write-Tag([string]$tag, [string]$message, [string]$color = 'Gray') {
    if ($Quiet) { return }
    Write-Host ("[{0}] {1}" -f $tag, $message) -ForegroundColor $color
}

# --- Python core ------------------------------------------------------------
. (Join-Path $repoRoot 'src\windows\identity_utils.ps1')

$python = Get-PythonCommandInfo
if (-not $python) {
    Write-Host '[FAILED] Python 3 not found - the AutoClaw2 chat core needs it (functional probe failed).' -ForegroundColor Red
    exit 1
}
$cli = Get-GhostPythonCli
if (-not $cli) { $cli = Join-Path $repoRoot 'src\python\ghost_cli.py' }
if (-not (Test-Path -LiteralPath $cli)) {
    Write-Host "[FAILED] Python core bootstrap missing: $cli" -ForegroundColor Red
    exit 1
}
Set-GhostConsoleUtf8

function Invoke-Ac2([string]$command, [hashtable]$payload) {
    $json = $payload | ConvertTo-Json -Depth 6 -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    # Get-PythonCommandInfo returns the interpreter PATH (string), not an object
    $out = & $python $cli $command $b64
    if ($LASTEXITCODE -notin 0, 2) {
        throw "$command failed (exit $LASTEXITCODE): $($out -join ' ')"
    }
    $verdict = ($out | Select-Object -First 1) | ConvertFrom-Json
    return @{ exit = $LASTEXITCODE; verdict = $verdict }
}

function Get-ProfileDir([string]$name) {
    if ($name -eq 'Primary') {
        return Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AutoClaw-oversea-official'
    }
    return Join-Path $env:USERPROFILE ("AutoClaw2ClonesHome\" + $name)
}

function Write-AuditLine([string]$name, [hashtable]$record) {
    $dir = Get-ProfileDir $name
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $record.ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $record.script = 'sync_autoclaw2_chats'
    $record.target = $name
    $line = $record | ConvertTo-Json -Depth 4 -Compress
    $auditPath = Join-Path $dir '.autoclaw2-sync-audit.jsonl'
    Add-Content -LiteralPath $auditPath -Value $line -Encoding UTF8
}

# --- Resolve targets ----------------------------------------------------------
$allowed = @('c1', 'c2', 'c3', 'c4', 'c5', 'All', 'Primary')
$targets = @()
foreach ($raw in ($Target -split '\s*,\s*') | Where-Object { $_ }) {
    if ($allowed -notcontains $raw) {
        Write-Host ("[FAILED] unknown target '{0}' (expected c1..c5, All or Primary)" -f $raw) -ForegroundColor Red
        exit 1
    }
    if ($raw -eq 'All') { $targets += @('c1', 'c2', 'c3', 'c4', 'c5') }
    else { $targets += $raw }
}
$targets = @($targets | Select-Object -Unique)

# --- Revert path ---------------------------------------------------------------
if ($Revert) {
    if (-not $ImportId) {
        Write-Host '[FAILED] -Revert needs -ImportId <id from the sidecar report>' -ForegroundColor Red
        exit 1
    }
    $tname = if ($targets.Count -eq 1) { $targets[0] } else { $targets[0] }
    $call = Invoke-Ac2 'ac2-chat-revert' @{ target = $tname; import_id = $ImportId }
    if ($call.exit -eq 2) {
        Write-Host ("[REFUSED] {0}: {1}" -f $call.verdict.refused, $call.verdict.message) -ForegroundColor Red
        exit 2
    }
    if ($call.verdict.status -eq 'ok') {
        Write-Tag 'ok' ("{0} - import {1} reverted (rows_left {2}); backup {3}" -f
            $tname, $ImportId, $call.verdict.rows_left, (Split-Path $call.verdict.backup -Leaf)) 'Green'
        Write-AuditLine $tname @{ status = 'reverted'; import_id = $ImportId
                                  backup = $call.verdict.backup }
        exit 0
    }
    Write-Tag 'FAILED' ("{0} - revert left {1} row(s) behind" -f $tname, $call.verdict.rows_left) 'Red'
    Write-AuditLine $tname @{ status = 'revert-failed'; import_id = $ImportId
                              rows_left = $call.verdict.rows_left }
    exit 1
}

# --- Inventory mode -------------------------------------------------------------
if ($Mode -eq 'Inventory') {
    $report = @{ generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                 source = $Source; profiles = @(); diff = @() }
    $inv = @{}

    $names = @($Source) + @($targets | Where-Object { $_ -ne $Source })
    foreach ($name in $names) {
        $call = Invoke-Ac2 'ac2-chat-inventory' @{ profile = $name }
        if ($call.exit -eq 2) {
            Write-Tag 'REFUSED' ("{0}: {1}" -f $name, $call.verdict.message) 'Red'
            $inv[$name] = $null
            continue
        }
        $inv[$name] = $call.verdict
        if ($call.verdict.status -eq 'skipped') {
            Write-Tag 'SKIP' ("{0} - {1}" -f $name, $call.verdict.reason) 'Yellow'
        }
        else {
            Write-Tag 'ok' ("{0} - {1} session(s), {2} imported" -f
                $name, $call.verdict.session_count, $call.verdict.imported_count) 'Green'
            Write-AuditLine $name @{ status = 'inventory'
                                     session_count = $call.verdict.session_count }
        }
        $report.profiles += $call.verdict
    }

    # cross-profile diff (AC2S-040): what would Import copy, per target?
    $srcInv = $inv[$Source]
    if ($null -ne $srcInv -and $srcInv.status -eq 'ok') {
        $srcSessions = @($srcInv.sessions)
        foreach ($tname in $targets) {
            if ($tname -eq $Source) { continue }
            $tInv = $inv[$tname]
            if ($null -eq $tInv) { continue }
            $seen = @{}
            if ($tInv.status -eq 'ok') {
                foreach ($r in $tInv.source_imports) { $seen[$r.source_session_id] = $true }
            }
            $missing = @(); $already = 0; $imRefused = 0
            foreach ($s in $srcSessions) {
                if ($s.external_provider) { $imRefused++; continue }
                if ($seen.ContainsKey($s.session_id)) { $already++ }
                else { $missing += $s }
            }
            $report.diff += @{
                target = $tname; missing = $missing.Count
                already_imported = $already; refused_im = $imRefused
                missing_sessions = @($missing | ForEach-Object {
                    @{ session_id = $_.session_id; title = $_.title
                       workspace_root = $_.workspace_root
                       entries = $_.entries } })
            }
            Write-Tag 'DIFF' ("{0}: {1} missing / {2} already-imported / {3} IM-refused" -f
                $tname, $missing.Count, $already, $imRefused) 'Cyan'
        }
    }

    $reportDir = Join-Path $env:LOCALAPPDATA 'autoclaw2-sync'
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    $reportPath = Join-Path $reportDir 'chat-inventory-report.json'
    $json = $report | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($reportPath, $json,
        (New-Object System.Text.UTF8Encoding($false)))
    if (-not $Quiet) {
        Write-Host ("Report: {0}" -f $reportPath) -ForegroundColor Gray
    }
    exit 0
}

# --- Import mode ----------------------------------------------------------------
if (-not $SessionId) {
    Write-Host '[FAILED] -Mode Import needs -SessionId <source session id>' -ForegroundColor Red
    exit 1
}
$attempted = 0; $refused = 0
foreach ($tname in $targets) {
    $payload = @{
        source    = $Source
        target    = $tname
        session_id = $SessionId
        dry_run   = (-not $Apply)
        max_unresolved_pct = $MaxUnresolvedPct
    }
    if ($TitleTag -ne '') { $payload.title_tag = $TitleTag }
    $attempted++
    $call = Invoke-Ac2 'ac2-chat-import' $payload
    if ($call.exit -eq 2) {
        $refused++
        Write-Tag 'REFUSED' ("{0}: {1}" -f $tname, $call.verdict.message) 'Yellow'
        Write-AuditLine $tname @{ status = 'refused'; refused = $call.verdict.refused
                                  session_id = $SessionId }
        continue
    }
    $v = $call.verdict
    if ($v.status -eq 'skipped') {
        Write-Tag 'SKIP' ("{0} - already-imported ({1})" -f $tname, $v.import_id) 'Yellow'
        Write-AuditLine $tname @{ status = 'skipped'; reason = 'already-imported'
                                  session_id = $SessionId }
        continue
    }
    if ($v.status -eq 'dry-run') {
        Write-Tag 'DRY' ("{0} - {1} entries, {2} events, {3} runs, {4} artifacts -> {5} as '{6}'" -f
            $tname, $v.entries, $v.events, $v.runs, $v.artifacts,
            $v.target_workspace, $v.title) 'Cyan'
        if ($v.dropped -gt 0) {
            Write-Tag 'WARN' ("  {0} entr(ies) would be dropped (unresolved refs)" -f $v.dropped) 'Yellow'
        }
        Write-AuditLine $tname @{ status = 'dry-run'; session_id = $SessionId }
        continue
    }
    if ($v.status -eq 'ok') {
        Write-Tag 'ok' ("{0} - imported as {1}; verify {2}; backup {3}" -f
            $tname, $v.new_session_id, ($v.verify | ConvertTo-Json -Compress),
            (Split-Path $v.backup -Leaf)) 'Green'
        Write-AuditLine $tname @{ status = 'ok'; import_id = $v.import_id
                                  new_session_id = $v.new_session_id
                                  session_id = $SessionId
                                  backup = $v.backup }
        continue
    }
    Write-Tag 'FAILED' ("{0} - verify-after mismatch: {1} vs expected {2}" -f
        $tname, ($v.verify | ConvertTo-Json -Compress),
        ($v.expected | ConvertTo-Json -Compress)) 'Red'
    Write-AuditLine $tname @{ status = 'failed'; session_id = $SessionId
                              verify = $v.verify; expected = $v.expected }
    $script:Failed = $true
}

if (-not $Apply) {
    if (-not $Quiet) { Write-Host 'Dry run only - nothing was written (pass -Apply to copy).' -ForegroundColor Gray }
}
if ($script:Failed) { exit 1 }
if ($attempted -gt 0 -and $refused -eq $attempted) { exit 2 }
exit 0
