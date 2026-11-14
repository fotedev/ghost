#Requires -Version 5.1
# Cline Identity Reset v0.1 — thin manifest over the Python core
#
# Reset target: the Primary (~\.cline) and/or the five clones
# (%USERPROFILE%\ClineClonesHome\c1..c5). Each clone = the whole CLINE_DIR
# state tree (data\{db,locks,logs,sessions,settings,cache}) + its own
# webview\ Chromium profile (WEBVIEW2_USER_DATA_FOLDER).
#
# Overrides the Cline spec's earlier "no reset script by design" decision
# (2026-11-14): the suite gets the MANDATORY playbook identity reset like
# every other suite; clone homes stay individually disposable.
#
# Phase 1 discovery provenance (2026-11-14, this host, read-only probes +
# docs/CLINE_CLONES_SPEC.md §3.3):
#   - data\secrets.json = clineAccountId + userInfo id/refresh tokens (auth)
#     -> DELETED (a fresh CLINE_DIR starts with NO secrets — spec §3.3).
#   - data\settings\providers.json = provider OAuth tokens -> DELETED.
#   - webview\EBWebView = the accounts.cline.app WEB LOGIN session (cookies)
#     -> swept (skip under -KeepLogin). The Primary's webview profile lives
#     at %LOCALAPPDATA%\bot.cline.app (stock WEBVIEW2 default) -> EBWebView
#     swept for the Primary target only.
#   - Machine identity = HKLM MachineGuid read via reg.exe by the app
#     (spec §3.3) — SYSTEM-level, NOT touched here (scope isolation; it
#     belongs to change_device_id.ps1 and is shared by every IDE).
#   - data\db\*.db (sessions/tasks/hub/teams/connectors/session-search),
#     data\sessions\, data\settings\global-settings.json, globalState.json,
#     tasks\, cron\ = chats/tasks/UI state -> PRESERVED (the GHOST reset
#     contract). data\globalState.json carries no identity keys (verified:
#     version/announcement/telemetry-toggle keys only).
#   - data\locks\ = hub lock files -> swept while stopped (stale locks would
#     otherwise read as "running" to the launcher's exclusive-open probe).
#
# TARGETS: -Target Primary|c1..c5|All. All = clones first, Primary last;
# nothing is copied between targets.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File reset_cline.ps1 [-Target c1]
#              [-KeepLogin] [-DryRun]
# Self-elevates (UAC) and reports through a %TEMP% done-marker (same channel
# as reset_cursor.ps1).
#
# PS 5.1 COMPAT: no ternary, no $Input, RandomNumberGenerator via .GetBytes().

param(
    [ValidateSet('Primary', 'c1', 'c2', 'c3', 'c4', 'c5', 'All')][string]$Target = 'Primary',
    [switch]$KeepLogin,
    [switch]$DryRun
)

. "$PSScriptRoot\identity_utils.ps1"

# --- Pure helpers (Pester-tested; see tests\reset_cline.Tests.ps1) ============

$script:ClineCloneKeys = @('c1', 'c2', 'c3', 'c4', 'c5')
# Fixed per-clone port plan (launch_cline_clone.ps1 $PortPlan; primary hub
# port is probed 25463..25466 by the stock app, so the Primary is handled by
# markers only).
$script:ClinePortPlan = @{
    'c1' = @(25471, 3131)
    'c2' = @(25472, 3132)
    'c3' = @(25473, 3133)
    'c4' = @(25474, 3134)
    'c5' = @(25475, 3135)
}

function Get-ClineTargetRoot {
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'Primary') {
        return Join-Path $env:USERPROFILE '.cline'
    }
    return Join-Path (Join-Path $env:USERPROFILE 'ClineClonesHome') $Label
}

function Get-ClineWebviewRoot {
    # The web-login Chromium profile root for a target.
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'Primary') {
        return Join-Path $env:LOCALAPPDATA 'bot.cline.app'
    }
    return Join-Path (Get-ClineTargetRoot -Label $Label) 'webview'
}

function Get-ClineTargetOrder {
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'All') {
        return @('c1', 'c2', 'c3', 'c4', 'c5', 'Primary')
    }
    return @($Label)
}

function Get-ClineTargetDisplay {
    param([Parameter(Mandatory = $true)][string]$Label)
    switch ($Label) {
        'c1' { 'Blue (c1)' }
        'c2' { 'Yellow (c2)' }
        'c3' { 'Green (c3)' }
        'c4' { 'Red (c4)' }
        'c5' { 'Orange (c5)' }
        default { 'Primary' }
    }
}

# Subtree markers per clone: the clone's own state-tree dir name inside ANY
# process cmdline (Cline.exe mains carry no marker — the launcher isolates by
# env — but the WebView2 children carry --user-data-dir=<clone>\webview and
# the hub/sidecar children carry data paths). Primary marker = the stock
# state-tree path; its webview root is matched separately.
$script:ClineCloneMarkers = @{
    'c1' = @('*ClineClonesHome\c1*')
    'c2' = @('*ClineClonesHome\c2*')
    'c3' = @('*ClineClonesHome\c3*')
    'c4' = @('*ClineClonesHome\c4*')
    'c5' = @('*ClineClonesHome\c5*')
}
$script:ClinePrimaryMarkers = @('*\.cline*')

# --- Dot-source guard: everything below runs ONLY on direct execution ========
if ($MyInvocation.InvocationName -eq '.') { return }

# --- Self-elevation -----------------------------------------------------------
$clIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $clIsAdmin) {
    $clScript = $MyInvocation.MyCommand.Path
    $clArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$clScript`" -Target $Target"
    if ($KeepLogin) { $clArgs += ' -KeepLogin' }
    if ($DryRun) { $clArgs += ' -DryRun' }
    Remove-Item -LiteralPath "$env:TEMP\cline_reset_done.txt" -Force -ErrorAction SilentlyContinue
    Start-Process powershell -Verb RunAs -ArgumentList $clArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\cline_reset_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\cline_reset_done.txt" -Encoding UTF8
    }
    exit
}

Write-GhostBanner -Target "Cline Identity Reset" -Version "0.1"

# --- Local helpers ============================================================

function _B64Payload {
    param([Parameter(Mandatory = $true)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Invoke-GhostCore {
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)
    $cli = Get-GhostPythonCli
    if (-not $cli) {
        Write-Host "[FAILED] GHOST Python core not found (src\python\ghost_cli.py)." -ForegroundColor Red
        return $null
    }
    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Write-Host "[FAILED] no functional Python 3 found - every Cline reset step needs it." -ForegroundColor Red
        return $null
    }
    Set-GhostConsoleUtf8
    $output = & $pythonCommand $cli @CliArgs
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    try {
        return ($output -join "`n") | ConvertFrom-Json
    }
    catch {
        Write-Host "[FAILED] unparseable core output: $($output -join ' ')" -ForegroundColor Red
        return $null
    }
}

function Add-AuditEntry {
    param(
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Before = '',
        [string]$After = '',
        [bool]$Ok = $true
    )
    if ($null -eq $Audit.Value) { $Audit.Value = @() }
    $Audit.Value += [ordered]@{ file = $File; key = $Key; before = $Before; after = $After; ok = $Ok }
}

function Add-RestoreAction {
    param(
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [string]$BackupPath
    )
    if ($null -eq $Actions.Value) { $Actions.Value = @() }
    $Actions.Value += [ordered]@{
        action       = 'copy'
        originalPath = $OriginalPath
        backupPath   = $BackupPath
    }
}

function Backup-ClinePath {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][ref]$Audit
    )
    if (-not (Test-Path -LiteralPath $Source)) { return $true }
    $report = Invoke-GhostCore @('backup', $Source, $BackupRoot, (Get-PathBackupLabel -Path $Source))
    if ($null -eq $report) {
        Write-Host "    [WARN] backup FAILED - proceeding WITHOUT backup: $Source" -ForegroundColor Yellow
        Add-AuditEntry -Audit $Audit -File $Source -Key 'backup' -Before 'present' -After 'backup-failed' -Ok $false
        return $false
    }
    if ($report.skipped) { return $true }
    if ($report.ok -and $report.destination) {
        Add-RestoreAction -Actions $Actions -OriginalPath $Source -BackupPath $report.destination
        return $true
    }
    Write-Host "    [WARN] backup did not complete ($($report.error)) - proceeding" -ForegroundColor Yellow
    return $false
}

function Remove-ClineFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Deleted,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "    [OK] not present (nothing to scrub): $Path" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key 'delete' -Before 'absent' -After 'absent' -Ok $true
        return $true
    }
    if ($IsDryRun) {
        Write-Host "    [DRY] would delete: $Path" -ForegroundColor Cyan
        return $true
    }
    $report = Invoke-GhostCore @('store-delete', $Path, $BackupRoot,
        (Get-PathBackupLabel -Path $Path), '--action', 'delete')
    $gone = -not (Test-Path -LiteralPath $Path)
    if ($null -ne $report -and $report.ok -and $gone) {
        Write-Host "    [OK] deleted + verified: $Path" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File $Path -Key 'delete' -Before 'present' -After 'deleted' -Ok $true
        if ($null -eq $Deleted.Value) { $Deleted.Value = @() }
        $Deleted.Value += $Path
        return $true
    }
    Write-Host "    [FAILED] delete/verify: $Path" -ForegroundColor Red
    Add-AuditEntry -Audit $Audit -File $Path -Key 'delete' -Before 'present' -After 'still-present' -Ok $false
    return $false
}

function Sweep-ClineTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "    [OK] not present (nothing to sweep): $Path" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'absent' -After 'absent' -Ok $true
        return $true
    }
    if ($IsDryRun) {
        Write-Host "    [DRY] would sweep tree: $Path" -ForegroundColor Cyan
        return $true
    }
    $report = Invoke-GhostCore @('sweep-tree', $Path, $BackupRoot, (Get-PathBackupLabel -Path $Path))
    $leftovers = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    if ($null -ne $report -and $report.ok -and $leftovers.Count -eq 0) {
        Write-Host "    [OK] swept + verified: $Path" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'present' -After 'swept' -Ok $true
        return $true
    }
    if ($null -ne $report -and $report.ok) {
        Write-Host "    [OK] swept (empty dirs may remain): $Path" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'present' -After 'swept' -Ok $true
        return $true
    }
    Write-Host "    [FAILED] sweep/verify: $Path" -ForegroundColor Red
    Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'present' -After 'failed' -Ok $false
    return $false
}

# Marker-classified stop for the target's Cline processes. The Tauri main
# carries no marker (env isolation), so the walk is: any process whose
# cmdline matches the target's markers -> climb to the root ancestor ->
# kill that root's whole subtree. Clones additionally kill the fixed-port
# owners (the per-clone hub/sidecar table). WebView2 children of the Primary
# carry the stock bot.cline.app profile dir.
function Get-ClineTargetPids {
    param([Parameter(Mandatory = $true)][string]$Label)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return @() }

    $byPid = @{}
    $byParent = @{}
    foreach ($p in $all) {
        if ($null -eq $p.ProcessId) { continue }
        $byPid[[int]$p.ProcessId] = $p
        if (-not $byParent.ContainsKey([int]$p.ParentProcessId)) { $byParent[[int]$p.ParentProcessId] = @() }
        $byParent[[int]$p.ParentProcessId] += $p
    }

    function Test-Markers($Proc, [string[]]$Markers) {
        $cmd = [string]$Proc.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
        foreach ($m in $Markers) { if ($cmd -like $m) { return $true } }
        return $false
    }

    # 1) directly marker-matched processes
    $markers = if ($Label -eq 'Primary') { $script:ClinePrimaryMarkers } else { $script:ClineCloneMarkers[$Label] }
    $matched = @($all | Where-Object { Test-Markers $_ $markers })

    # 2) climb from each match to its ROOT ancestor (a process whose parent is
    #    not a marker match itself - the Cline.exe main above the WebView2
    #    children / hub children)
    $matchedIds = @{}
    foreach ($p in $matched) { $matchedIds[[int]$p.ProcessId] = $true }
    $roots = @()
    foreach ($p in $matched) {
        $cur = $p
        $guard = 0
        while ($guard -lt 16) {
            $parentId = [int]$cur.ParentProcessId
            if (-not $byPid.ContainsKey($parentId)) { break }
            if ($matchedIds.ContainsKey($parentId)) { $cur = $byPid[$parentId]; $guard++; continue }
            break
        }
        $roots += $cur
    }

    # 3) clone targets: add the fixed-port owners (belt + braces; the hub
    #    daemon's cmdline may not always carry the state path)
    if ($Label -ne 'Primary') {
        foreach ($port in $script:ClinePortPlan[$Label]) {
            $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
            foreach ($l in $listeners) {
                $owner = $byPid[[int]$l.OwningProcess]
                if ($owner) { $roots += $owner }
            }
        }
    }

    # 4) expand every root to its full subtree. Queue semantics (Dequeue
    #    REMOVES): an array-slice "pop" does NOT shrink a 1-element array in
    #    PowerShell (@('A')[1..0] == @('A')), so a slice-based walk spins
    #    forever on leaf nodes (latent hang, caught 2026-11-14).
    $kill = @{}
    foreach ($r in $roots) {
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($r)
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if ($null -eq $cur -or $kill.ContainsKey([int]$cur.ProcessId)) { continue }
            $kill[[int]$cur.ProcessId] = $true
            $kids = $byParent[[int]$cur.ProcessId]
            if ($kids) {
                foreach ($k in $kids) { $queue.Enqueue($k) }
            }
        }
    }
    return @($kill.Keys)
}

function Stop-ClineTargetProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )
    if ($IsDryRun) {
        $pids = @(Get-ClineTargetPids -Label $Label)
        Write-Host ("[DRY] would tree-kill {0} process(es) of {1}." -f $pids.Count, (Get-ClineTargetDisplay $Label)) -ForegroundColor Cyan
        return $true
    }
    $maxAttempts = 10
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $pids = @(Get-ClineTargetPids -Label $Label)
        if ($pids.Count -eq 0) { break }
        foreach ($pid2 in $pids) {
            try { Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 1500
        $attempt++
    }
    $remaining = @(Get-ClineTargetPids -Label $Label)
    if ($remaining.Count -gt 0) {
        Write-Host ("[FAILED] {0} Cline process(es) of {1} survived {2} kill attempts." -f $remaining.Count, (Get-ClineTargetDisplay $Label), $maxAttempts) -ForegroundColor Red
        return $false
    }
    return $true
}

# --- Main ======================================================================

if ($DryRun) {
    Write-Host "=== DRY RUN - no store will be touched ===" -ForegroundColor Magenta
}

$targets = Get-ClineTargetOrder -Label $Target
$globalPass = 0
$globalFail = 0

foreach ($label in $targets) {
    $root = Get-ClineTargetRoot -Label $label
    Write-Host "`n=== Target: $(Get-ClineTargetDisplay $label) ===" -ForegroundColor Cyan
    Write-Host "State tree: $root"

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-Host "[SKIP] state tree not found - nothing to reset (the launcher owns first-run creation)." -ForegroundColor Yellow
        continue
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $root 'ID_Backups'
    $backupRoot = Join-Path $backupRoot $timestamp
    $audit = @()
    $actions = @()
    $deleted = @()
    $passCount = 0
    $failCount = 0

    # --- [1/11] Stop the target's processes -------------------------------------
    Write-Host "`n[1/11] Stopping $(Get-ClineTargetDisplay $label) processes..." -ForegroundColor Cyan
    if (Stop-ClineTargetProcesses -Label $label -IsDryRun $DryRun) {
        Write-Host "[OK] no matching Cline processes running (or killed)." -ForegroundColor Green
        $passCount++
    } else { $failCount++ }

    # --- [2/11] Backup the identity set ------------------------------------------
    Write-Host "[2/11] Backing up identity stores to ID_Backups\$timestamp..." -ForegroundColor Cyan
    $backupOk = $true
    foreach ($src in @(
        (Join-Path $root 'data\secrets.json'),
        (Join-Path $root 'data\settings\providers.json'),
        (Join-Path $root 'data\locks')
    )) {
        if (-not (Backup-ClinePath -Source $src -BackupRoot $backupRoot -Actions ([ref]$actions) -Audit ([ref]$audit))) { $backupOk = $false }
    }
    if ($DryRun) { Write-Host "    [DRY] backup step skipped in dry-run." -ForegroundColor Cyan }
    elseif ($backupOk) { Write-Host "[OK] identity set backed up (missing paths skipped)." -ForegroundColor Green; $passCount++ }
    else { $failCount++ }

    # --- [3/11] Account secrets ----------------------------------------------------
    if ($KeepLogin) {
        Write-Host "[3/11] Account secrets SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[3/11] Deleting data\secrets.json (clineAccountId + tokens)..." -ForegroundColor Cyan
        if (Remove-ClineFile -Path (Join-Path $root 'data\secrets.json') -BackupRoot $backupRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun) { $passCount++ } else { $failCount++ }
    }

    # --- [4/11] Provider OAuth tokens ------------------------------------------------
    if ($KeepLogin) {
        Write-Host "[4/11] Provider tokens SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[4/11] Deleting data\settings\providers.json (provider OAuth tokens)..." -ForegroundColor Cyan
        if (Remove-ClineFile -Path (Join-Path $root 'data\settings\providers.json') -BackupRoot $backupRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun) { $passCount++ } else { $failCount++ }
    }

    # --- [5/11] Stale locks ------------------------------------------------------------
    Write-Host "[5/11] Sweeping stale hub locks..." -ForegroundColor Cyan
    if (Sweep-ClineTree -Path (Join-Path $root 'data\locks') -BackupRoot $backupRoot -Audit ([ref]$audit) -IsDryRun $DryRun) { $passCount++ } else { $failCount++ }

    # --- [6/11] Web-login session --------------------------------------------------------
    if ($KeepLogin) {
        Write-Host "[6/11] Web-login session SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[6/11] Sweeping the web-login Chromium profile (EBWebView)..." -ForegroundColor Cyan
        $wv = Join-Path (Get-ClineWebviewRoot -Label $label) 'EBWebView'
        if (Sweep-ClineTree -Path $wv -BackupRoot $backupRoot -Audit ([ref]$audit) -IsDryRun $DryRun) { $passCount++ } else { $failCount++ }
    }

    # --- [7/11] Logs sweep -----------------------------------------------------------------
    Write-Host "[7/11] Sweeping logs..." -ForegroundColor Cyan
    if (Sweep-ClineTree -Path (Join-Path $root 'data\logs') -BackupRoot $backupRoot -Audit ([ref]$audit) -IsDryRun $DryRun) { $passCount++ } else { $failCount++ }

    # --- [8/11] Cache sweep -------------------------------------------------------------------
    Write-Host "[8/11] Sweeping cache..." -ForegroundColor Cyan
    if (Sweep-ClineTree -Path (Join-Path $root 'data\cache') -BackupRoot $backupRoot -Audit ([ref]$audit) -IsDryRun $DryRun) { $passCount++ } else { $failCount++ }

    # --- [9/11] Final verify probe --------------------------------------------------------------
    Write-Host "[9/11] Final verify probe..." -ForegroundColor Cyan
    $verifyOk = $true
    if (-not $DryRun -and -not $KeepLogin) {
        foreach ($p in @((Join-Path $root 'data\secrets.json'), (Join-Path $root 'data\settings\providers.json'))) {
            if (Test-Path -LiteralPath $p) {
                Write-Host "    [FAILED] expected-deleted path still present: $p" -ForegroundColor Red
                $verifyOk = $false
            }
        }
    }
    if (-not $DryRun) {
        foreach ($p in $deleted) {
            if (Test-Path -LiteralPath $p) {
                Write-Host "    [FAILED] expected-deleted path still present: $p" -ForegroundColor Red
                $verifyOk = $false
            }
        }
    }
    if ($verifyOk) { $passCount++ } else { $failCount++ }

    # --- [10/11] Audit + restore script ------------------------------------------------------------
    Write-Host "[10/11] Writing audit + restore script..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "    [DRY] audit + restore skipped in dry-run." -ForegroundColor Cyan
        $passCount++
    }
    else {
        $auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
        Write-AuditLog -Audit $audit -Path $auditPath
        $restorePath = New-RestoreScript -BackupRoot $backupRoot -App 'Cline' -Actions $actions
        if ((Test-Path -LiteralPath $auditPath) -and (Test-Path -LiteralPath $restorePath)) {
            Write-Host "    [OK] audit: $auditPath" -ForegroundColor Green
            Write-Host "    [OK] restore: $restorePath" -ForegroundColor Green
            $passCount++
        }
        else {
            Write-Host "    [FAILED] audit/restore script missing." -ForegroundColor Red
            $failCount++
        }
    }

    # --- [11/11] Summary ------------------------------------------------------------------------------
    Write-Host "[11/11] Summary." -ForegroundColor Cyan
    Write-Host "`n--- $(Get-ClineTargetDisplay $label) summary ---" -ForegroundColor Cyan
    Write-Host "Pass: $passCount  Fail: $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
    $globalPass += $passCount
    $globalFail += $failCount
}

Write-Host "`n=== Cline reset summary ===" -ForegroundColor Cyan
Write-Host "Targets: $($targets -join ', ')  Pass: $globalPass  Fail: $globalFail" -ForegroundColor $(if ($globalFail -gt 0) { 'Red' } else { 'Green' })
Write-Host "NOTE: chats, tasks, teams, cron and global settings are preserved by design." -ForegroundColor Yellow
Write-Host "NOTE: relaunch via the Cline Blue/Yellow/Green/Red/Orange shortcuts or the launcher - the Primary is the stock Cline.exe launch." -ForegroundColor Yellow
Write-Host "NOTE: every target signs in again after this reset (unless -KeepLogin was used)." -ForegroundColor Yellow

if (-not $DryRun) {
    [System.IO.File]::WriteAllText("$env:TEMP\cline_reset_done.txt",
        ("Pass: {0} Fail: {1}" -f $globalPass, $globalFail),
        (New-Object System.Text.UTF8Encoding $false))
}

if ($globalFail -gt 0) {
    Write-Host "Cline reset completed with failures. Review the audit JSON in each ID_Backups\<ts> dir." -ForegroundColor Red
    exit 1
}

Write-Host "Cline reset completed successfully."
