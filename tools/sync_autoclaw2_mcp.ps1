#Requires -Version 5.1
<#
.SYNOPSIS
  Applies the device-level MCP (connected sources) definitions to AutoClaw2
  (zwork) profiles - Primary (opt-in) and clones c1..c5.

.DESCRIPTION
  Spec: docs/AUTOCLAW2_SYNC_SPEC.md (decisions D1-D13). The SQL lives in
  src/python/ghost/autoclaw2.py and runs via src/python/ghost_cli.py
  (base64 JSON payload in, JSON verdict out) - this script only
  orchestrates: preflight, verdict rendering, audit JSONL, exit codes.

  Sources of definitions:
    -From Master   tools/autoclaw2-mcp.master.json (default; the central
                   template the developer edits)
    -From Primary  the Primary profile's own GUI-configured connected
                   sources, mapped to each clone by workspace root_path

  Merge invariant (D6): clone-local 'enabled' toggles and tool permissions
  survive; clone-only sources are never deleted; the source wins only on
  name/locator/source_permission. Written rows carry status='pending' and
  tools_json='[]' - the app tests the source and fills the tool catalog
  itself (D5). Credentials never travel (D4).

  Timing (D7): every target must be CLOSED (lockfile probe); running or
  never-signed-in profiles are SKIP + WARN, never written. Use the watcher
  (tools/watch_autoclaw2_mcp_sync.ps1) or the launcher's pre-launch step
  for convergence - a closed profile converges on its next launch either way.

  Never silent success: the Python core re-reads and deep-compares every
  write; a mismatch is a FAILED verdict with the column diff. A clean
  single-file backup (sqlite backup API, WAL-safe) is taken before each
  profile's first write of a run: <ProfileDir>\.autoclaw2-sync-backups\<ts>\.

  Audit: one JSONL line per target profile per run appended to
  <ProfileDir>\.autoclaw2-sync-audit.jsonl (paths + slugs + counts; never
  credential values).

  Rollback: -RestoreBackup restores the newest backup for the target
  profile (app must be closed). The merge never deletes, so restore is the
  whole undo story.

.PARAMETER Target
  Clone(s) to converge. Default: all five clones.

.PARAMETER From
  'Master' (repo manifest) or 'Primary' (Primary profile rows).

.PARAMETER IncludePrimary
  Also converge the Primary profile (explicit opt-in; Primary is read-only
  by default).

.PARAMETER AllWorkspaces
  Apply to EVERY active workspace of each profile instead of the default
  workspace + root_path matches (D3).

.PARAMETER DryRun
  Plan and print, write nothing (DB left byte-identical; asserted by the
  core and re-checked here by hash).

.PARAMETER Quiet
  Print verdict lines only (launcher/one-shot callers).

.PARAMETER RestoreBackup
  Restore the newest .autoclaw2-sync-backups entry for each target instead
  of syncing. Requires the app closed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_mcp.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_mcp.ps1 -Target c1 -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_autoclaw2_mcp.ps1 -From Primary -Target All
#>
[CmdletBinding()]
param(
    # Comma-tolerant single string: both native PowerShell callers
    # (-Target c1,c3) and -File callers (GHOST.bat passes "All" or one id)
    # land here; split + validated below.
    [string]$Target = 'All',

    [ValidateSet('Master', 'Primary')]
    [string]$From = 'Master',

    # Account disambiguation for profiles carrying more than one account dir
    # (the Primary ships a dormant + a live account): exact 64-hex dir name or
    # a unique prefix. Without it the Python core picks the account whose
    # runtime.sqlite was written most recently (the live one), loudly.
    [string]$Account = '',

    [switch]$IncludePrimary,

    [switch]$AllWorkspaces,

    [switch]$DryRun,

    # Seconds per live MCP discover (stdio spawn / http fetch) before a
    # source is written as failed/connection_failed. Cold npx/uvx installs
    # can be slow - raise this if a package must download first.
    [int]$DiscoverTimeoutSeconds = 60,

    [switch]$Quiet,

    [switch]$RestoreBackup
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$script:Failed = $false

# Agent/CI shells can run with empty %LOCALAPPDATA% / %APPDATA% (the env
# lesson from ensure_autoclaw2_git_identity.ps1): backfill from the shell
# API before anything uses them - identity_utils' per-user Python probe
# (Join-Path $env:LOCALAPPDATA) and the audit path resolution both need it.
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
    Write-Host '[FAILED] Python 3 not found - the AutoClaw2 sync core needs it (functional probe failed).' -ForegroundColor Red
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
    $record.script = 'sync_autoclaw2_mcp'
    $record.target = $name
    $line = $record | ConvertTo-Json -Depth 4 -Compress
    $auditPath = Join-Path $dir '.autoclaw2-sync-audit.jsonl'
    Add-Content -LiteralPath $auditPath -Value $line -Encoding UTF8
}

# --- Resolve targets --------------------------------------------------------
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
if ($IncludePrimary) { $targets = @('Primary') + $targets }
# @() is load-bearing: a single-element pipeline result unwraps to a bare
# string in PS 5.1, and the Python core would then iterate the STRING's
# characters as profile names ('c', '1', ... -> unknown-profile refusals).
$targets = @($targets | Select-Object -Unique)

# --- Restore path -----------------------------------------------------------
if ($RestoreBackup) {
    foreach ($name in $targets) {
        $dir = Get-ProfileDir $name
        $backupRoot = Join-Path $dir '.autoclaw2-sync-backups'
        if (-not (Test-Path -LiteralPath $backupRoot)) {
            Write-Tag 'SKIP' "$name - no backups to restore" 'Yellow'
            continue
        }
        $latest = Get-ChildItem -LiteralPath $backupRoot -Directory |
            Sort-Object Name -Descending | Select-Object -First 1
        $backupDb = Join-Path $latest.FullName 'runtime.sqlite'
        if (-not (Test-Path -LiteralPath $backupDb)) {
            Write-Tag 'FAILED' "$name - newest backup is incomplete: $($latest.Name)" 'Red'
            $script:Failed = $true
            continue
        }
        $lockfile = Join-Path $dir 'lockfile'
        if (Test-Path -LiteralPath $lockfile) {
            try {
                $fs = [System.IO.File]::Open($lockfile, 'Open', 'Read', 'None')
                $fs.Close()
            } catch {
                Write-Tag 'SKIP' "$name - running (lockfile held); close it and re-run" 'Yellow'
                continue
            }
        }
        $db = Join-Path (Get-ProfileDir $name) 'accounts'
        $accounts = Get-ChildItem -LiteralPath $db -Directory -ErrorAction SilentlyContinue
        if (@($accounts).Count -ne 1) {
            Write-Tag 'SKIP' "$name - account layout changed; refusing blind restore" 'Yellow'
            continue
        }
        $live = Join-Path $accounts[0].FullName 'runtime\runtime.sqlite'
        Copy-Item -LiteralPath $backupDb -Destination $live -Force
        $hash = (Get-FileHash $live -Algorithm SHA256).Hash
        $backupHash = (Get-FileHash $backupDb -Algorithm SHA256).Hash
        if ($hash -ne $backupHash) {
            Write-Tag 'FAILED' "$name - restore hash mismatch" 'Red'
            $script:Failed = $true
            continue
        }
        Write-Tag 'ok' "$name - restored $($latest.Name) (hash verified)"
        Write-AuditLine $name @{ action = 'restore-backup'; backup = $latest.Name }
    }
    if ($script:Failed) { exit 1 }
    exit 0
}

# --- Preflight: manifest / primary ------------------------------------------
$payload = @{
    targets = $targets
    from    = $From.ToLower()
    policy  = if ($AllWorkspaces) { 'all' } else { 'default' }
    dry_run = [bool]$DryRun
    discover_timeout = $DiscoverTimeoutSeconds
}
if ($Account) { $payload.account_hint = $Account }
if ($From -eq 'Master') {
    $manifest = Join-Path $repoRoot 'tools\autoclaw2-mcp.master.json'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Write-Host "[FAILED] manifest missing: $manifest" -ForegroundColor Red
        exit 1
    }
    $payload.manifest_path = $manifest
}

$command = if ($DryRun) { 'ac2-mcp-plan' } else { 'ac2-mcp-apply' }
$call = Invoke-Ac2 $command $payload
if ($call.exit -eq 2) {
    Write-Host ("[REFUSED] {0}: {1}" -f $call.verdict.refused, $call.verdict.message) -ForegroundColor Red
    exit 2
}

# --- Render + audit ---------------------------------------------------------
foreach ($profile in $call.verdict.profiles) {
    $name = $profile.profile
    switch ($profile.status) {
        'skipped' {
            Write-Tag 'SKIP' ("{0} - {1}" -f $name, $profile.reason) 'Yellow'
            Write-AuditLine $name @{ status = 'skipped'; reason = $profile.reason }
            continue
        }
        # ac2-mcp-plan labels plannable profiles 'planned' (ac2-mcp-apply's
        # dry-run shape reuses the same fields) - render both identically
        { $_ -in 'dry-run', 'planned' } {
            Write-Tag 'DRY' ("{0} - {1} create(s), {2} update(s), {3} kept-local" -f
                $name, $profile.totals.creates, $profile.totals.updates,
                ($profile.workspaces | Measure-Object kept_local -Sum).Sum) 'Cyan'
            foreach ($ws in $profile.workspaces) {
                foreach ($create in $ws.creates) {
                    Write-Tag 'DRY' ("  + {0} -> {1} [{2}]" -f
                        $create.slug, $ws.root_path, $create.source_permission) 'Cyan'
                    if ($create.requires_credential) {
                        Write-Tag 'WARN' ("  {0} needs a credential - sign in once per clone in the app" -f $create.slug) 'Yellow'
                    }
                }
                foreach ($update in $ws.updates | Where-Object changed) {
                    Write-Tag 'DRY' ("  ~ {0} -> {1} (definition changed)" -f
                        $update.slug, $ws.root_path) 'Cyan'
                }
                if ($ws.manifest_absent) {
                    Write-Tag 'DRY' ("  = kept local: {0}" -f ($ws.manifest_absent -join ', ')) 'Cyan'
                }
                foreach ($mig in ($ws.slug_migrations | ForEach-Object { $_ })) {
                    Write-Tag 'DRY' ("  ~ slug migrate: {0} -> {1}" -f $mig.from, $mig.to) 'Cyan'
                }
            }
            foreach ($warn in @($profile.workspace_warnings)) {
                if ($warn) {
                    Write-Tag 'WARN' ("{0} - {1} ({2})" -f $name, $warn.reason, $warn.root_path) 'Yellow'
                }
            }
            continue
        }
        'unchanged' {
            Write-Tag 'ok' ("{0} - already converged ({1} local source(s) kept)" -f
                $name, $profile.action_count) 'Green'
            Write-AuditLine $name @{ status = 'unchanged' }
            continue
        }
        'ok' {
            Write-Tag 'ok' ("{0} - {1} row(s) written + verified; backup {2}" -f
                $name, $profile.written, (Split-Path $profile.backup -Leaf)) 'Green'
            foreach ($src in ($profile.sources | ForEach-Object { $_ })) {
                if ($src.status -eq 'connected') {
                    Write-Tag 'ok' ("  {0}: connected ({1} tool(s))" -f
                        $src.slug, $src.test.tool_count) 'Green'
                } else {
                    Write-Tag 'WARN' ("  {0}: live test FAILED ({1}) - fix the cause or sign in via the GUI, then Reconnect" -f
                        $src.slug, $src.test.error_code) 'Yellow'
                }
            }
            Write-AuditLine $name @{
                status = 'ok'; written = $profile.written
                backup = $profile.backup
                sources = (($profile.sources | ForEach-Object {
                    "{0}={1}({2})" -f $_.slug, $_.status, $_.test.tool_count
                }) -join ',')
            }
            continue
        }
        'failed' {
            Write-Tag 'FAILED' ("{0} - verify-after mismatch: {1}" -f
                $name, ($profile.mismatches | ConvertTo-Json -Compress)) 'Red'
            Write-AuditLine $name @{ status = 'failed'; mismatches = $profile.mismatches }
            $script:Failed = $true
            continue
        }
        default {
            Write-Tag 'FAILED' "$name - unknown verdict status: $profile.status" 'Red'
            $script:Failed = $true
        }
    }
}

if ($DryRun) {
    if (-not $Quiet) { Write-Host 'Dry run only - nothing was written.' -ForegroundColor Gray }
    exit 0
}
if ($script:Failed) {
    Write-Host 'FAILED - see [FAILED] lines above; backups were kept.' -ForegroundColor Red
    exit 1
}
Write-Host 'All targets converged.' -ForegroundColor Green
exit 0
