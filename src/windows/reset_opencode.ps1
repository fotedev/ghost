#Requires -Version 5.1
# OpenCode Identity Reset v0.1 — thin manifest over the Python core
#
# Reset target: the Primary (%APPDATA%\ai.opencode.desktop + the stock XDG
# data home ~\.local\share\opencode) and/or the five clones
# (%USERPROFILE%\OpenCodeClonesHome\c1..c5). The clone-home asar patch pins
# userData = <cN>\desktop, sessionData = <cN>\session and the four XDG_*
# dirs per clone — so one target has TWO profile surfaces (spec §3/§4).
#
# Phase 1 discovery provenance (2026-11-14, this host, read-only probes +
# docs/OPENCODE_CLONES_SPEC.md §3.4/§7):
#   - auth.json + mcp-auth.json in the XDG data home (Primary:
#     ~\.local\share\opencode — verified present; clones:
#     <cN>\data\opencode — absent on never-signed-in clones) = the CLI
#     OAuth stores -> DELETED [skipped under -KeepLogin].
#   - gh\device-id (Primary: userData\gh\device-id — verified; clones:
#     <cN>\data\gh\device-id per the spec's per-clone identity list) ->
#     DELETED (regenerated fresh).
#   - desktop\.updaterId (clones — verified; Primary carries an
#     opencode.updater dir instead, left as-is) -> DELETED (distinct
#     updater identity per profile, reset_minimax precedent).
#   - session profile (clone: <cN>\session — the full Chromium profile
#     incl. Local State/Network/Cache where the WEB LOGIN lives; Primary:
#     the userData root itself) -> Local State deleted (OSCrypt key),
#     Network session stores deleted, caches swept [ALL skipped under
#     -KeepLogin].
#   - userData surfaces: Crashpad/logs/compile-cache swept (both targets).
#   - PRESERVED by design: opencode.db (+wal/shm) = sessions/chats,
#     repos, shell, snapshot, tool-output (XDG data), drafts.sqlite,
#     opencode.settings, window-state, cli cache (userData),
#     config\opencode\*.json (MCP config — definitions only).
#
# TARGETS: -Target Primary|c1..c5|All. All = clones first, Primary last.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File reset_opencode.ps1 [-Target c1]
#              [-KeepLogin] [-DryRun]
# Self-elevates (UAC) and reports through a %TEMP% done-marker.
#
# PS 5.1 COMPAT: no ternary, no $Input, RandomNumberGenerator via .GetBytes().

param(
    [ValidateSet('Primary', 'c1', 'c2', 'c3', 'c4', 'c5', 'All')][string]$Target = 'Primary',
    [switch]$KeepLogin,
    [switch]$DryRun
)

. "$PSScriptRoot\identity_utils.ps1"

# --- Pure helpers (Pester-tested; see tests\reset_opencode.Tests.ps1) =========

$script:OpenCodeCloneKeys = @('c1', 'c2', 'c3', 'c4', 'c5')

function Get-OpenCodeTargetRoots {
    # Two surfaces per target. Desktop = the Electron userData root; session =
    # the Chromium sessionData root (the WEB LOGIN profile); xdg = the opencode
    # CLI data home (auth.json + opencode.db).
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'Primary') {
        $desktop = Join-Path $env:APPDATA 'ai.opencode.desktop'
        return @{
            Desktop = $desktop
            Session = $desktop   # the Primary uses the userData root as its session profile
            Xdg     = Join-Path $env:USERPROFILE '.local\share\opencode'
        }
    }
    $cloneHome = Join-Path (Join-Path $env:USERPROFILE 'OpenCodeClonesHome') $Label
    return @{
        Desktop = (Join-Path $cloneHome 'desktop')
        Session = (Join-Path $cloneHome 'session')
        Xdg     = (Join-Path $cloneHome 'data\opencode')
    }
}

function Get-OpenCodeTargetOrder {
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'All') {
        return @('c1', 'c2', 'c3', 'c4', 'c5', 'Primary')
    }
    return @($Label)
}

function Get-OpenCodeTargetDisplay {
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

# Subtree markers: the clone-home argv (--opencode-clone-home=<dir>) rides the
# MAIN process cmdline for clones (deterministic even mid-splash), and Electron
# children carry --user-data-dir/--sessionData under the same clone home.
# Primary marker = its userData dir (children carry --user-data-dir=<userData>).
$script:OpenCodeCloneMarkers = @{
    'c1' = @('*OpenCodeClonesHome\c1*')
    'c2' = @('*OpenCodeClonesHome\c2*')
    'c3' = @('*OpenCodeClonesHome\c3*')
    'c4' = @('*OpenCodeClonesHome\c4*')
    'c5' = @('*OpenCodeClonesHome\c5*')
}
$script:OpenCodePrimaryMarkers = @('*ai.opencode.desktop*')

# --- Dot-source guard: everything below runs ONLY on direct execution ========
if ($MyInvocation.InvocationName -eq '.') { return }

# --- Self-elevation -----------------------------------------------------------
$ocIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ocIsAdmin) {
    $ocScript = $MyInvocation.MyCommand.Path
    $ocArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$ocScript`" -Target $Target"
    if ($KeepLogin) { $ocArgs += ' -KeepLogin' }
    if ($DryRun) { $ocArgs += ' -DryRun' }
    Remove-Item -LiteralPath "$env:TEMP\opencode_reset_done.txt" -Force -ErrorAction SilentlyContinue
    Start-Process powershell -Verb RunAs -ArgumentList $ocArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\opencode_reset_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\opencode_reset_done.txt" -Encoding UTF8
    }
    exit
}

Write-GhostBanner -Target "OpenCode Identity Reset" -Version "0.1"

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
        Write-Host "[FAILED] no functional Python 3 found - every OpenCode reset step needs it." -ForegroundColor Red
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

function Backup-OcPath {
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

function Remove-OcFile {
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

function Sweep-OcTree {
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

function Get-OpenCodeTargetMains {
    param([Parameter(Mandatory = $true)][string]$Label)
    $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'OpenCode%'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    $byParent = @{}
    foreach ($p in $procs) {
        if ($null -eq $p.ProcessId) { continue }
        if (-not $byParent.ContainsKey([int]$p.ParentProcessId)) { $byParent[[int]$p.ParentProcessId] = @() }
        $byParent[[int]$p.ParentProcessId] += $p
    }

    function Test-BareExeMain([string]$Cmd, [string]$Name) {
        if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
        if ($Cmd -match '--type=') { return $false }
        $bare = '^\s*"?[^"]*\\' + [regex]::Escape($Name) + '"?\s*$'
        return ($Cmd -match $bare)
    }

    function Test-SubtreeMarkers($Proc, [string[]]$Markers) {
        $stack = @($Proc)
        $seen = @{}
        while ($stack.Count -gt 0) {
            $cur = $stack[0]
            $stack = $stack[1..($stack.Count - 1)]
            if ($null -eq $cur -or $seen.ContainsKey([int]$cur.ProcessId)) { continue }
            $seen[[int]$cur.ProcessId] = $true
            $cmd = [string]$cur.CommandLine
            foreach ($m in $Markers) {
                if ($cmd -like $m) { return $true }
            }
            $kids = $byParent[[int]$cur.ProcessId]
            if ($kids) { $stack = @($kids) + $stack }
        }
        return $false
    }

    $mains = @($procs | Where-Object { Test-BareExeMain $_.CommandLine $_.Name })
    $matched = @()
    foreach ($m in $mains) {
        if ($Label -eq 'Primary') {
            if (Test-SubtreeMarkers $m $script:OpenCodePrimaryMarkers) { $matched += $m; continue }
            if (-not (Test-SubtreeMarkers $m (@($script:OpenCodeCloneMarkers.Values | ForEach-Object { $_ }) ))) {
                $matched += $m
            }
        }
        else {
            if (Test-SubtreeMarkers $m $script:OpenCodeCloneMarkers[$Label]) { $matched += $m }
        }
    }
    return $matched
}

function Stop-OpenCodeTargetProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )
    if ($IsDryRun) {
        $dryMains = @(Get-OpenCodeTargetMains -Label $Label)
        Write-Host ("[DRY] would tree-kill {0} main process(es) of {1}." -f $dryMains.Count, (Get-OpenCodeTargetDisplay $Label)) -ForegroundColor Cyan
        return $true
    }
    $maxAttempts = 10
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $mains = @(Get-OpenCodeTargetMains -Label $Label)
        if ($mains.Count -eq 0) { break }
        foreach ($m in $mains) {
            try { Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 1500
        $attempt++
    }
    $remaining = @(Get-OpenCodeTargetMains -Label $Label)
    if ($remaining.Count -gt 0) {
        Write-Host ("[FAILED] {0} OpenCode process(es) of {1} survived {2} kill attempts." -f $remaining.Count, (Get-OpenCodeTargetDisplay $Label), $maxAttempts) -ForegroundColor Red
        return $false
    }
    return $true
}

# --- Main ======================================================================

if ($DryRun) {
    Write-Host "=== DRY RUN - no store will be touched ===" -ForegroundColor Magenta
}

$targets = Get-OpenCodeTargetOrder -Label $Target
$globalPass = 0
$globalFail = 0

foreach ($label in $targets) {
    $roots = Get-OpenCodeTargetRoots -Label $label
    Write-Host "`n=== Target: $(Get-OpenCodeTargetDisplay $label) ===" -ForegroundColor Cyan
    Write-Host "userData: $($roots.Desktop)"
    Write-Host "session : $($roots.Session)"
    Write-Host "xdg data: $($roots.Xdg)"

    if (-not (Test-Path -LiteralPath $roots.Desktop -PathType Container)) {
        Write-Host "[SKIP] userData root not found - nothing to reset (the launcher owns first-run creation)." -ForegroundColor Yellow
        continue
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $roots.Desktop 'ID_Backups'
    $backupRoot = Join-Path $backupRoot $timestamp
    $audit = @()
    $actions = @()
    $deleted = @()
    $passCount = 0
    $failCount = 0

    # --- [1/10] Stop the target's processes -------------------------------------
    Write-Host "`n[1/10] Stopping $(Get-OpenCodeTargetDisplay $label) processes..." -ForegroundColor Cyan
    if (Stop-OpenCodeTargetProcesses -Label $label -IsDryRun $DryRun) {
        Write-Host "[OK] no matching OpenCode processes running (or killed)." -ForegroundColor Green
        $passCount++
    } else { $failCount++ }

    # --- [2/10] Backup the identity set -------------------------------------------
    Write-Host "[2/10] Backing up identity stores to ID_Backups\$timestamp..." -ForegroundColor Cyan
    $backupOk = $true
    foreach ($src in @(
        (Join-Path $roots.Xdg 'auth.json'),
        (Join-Path $roots.Xdg 'mcp-auth.json'),
        (Join-Path $roots.Desktop 'gh\device-id'),
        (Join-Path $roots.Desktop '.updaterId'),
        (Join-Path $roots.Desktop 'data\gh\device-id'),
        (Join-Path $roots.Session 'Local State'),
        (Join-Path $roots.Session 'Network\Cookies')
    )) {
        if (-not (Backup-OcPath -Source $src -BackupRoot $backupRoot -Actions ([ref]$actions) -Audit ([ref]$audit))) { $backupOk = $false }
    }
    if ($DryRun) { Write-Host "    [DRY] backup step skipped in dry-run." -ForegroundColor Cyan }
    elseif ($backupOk) { Write-Host "[OK] identity set backed up (missing paths skipped)." -ForegroundColor Green; $passCount++ }
    else { $failCount++ }

    # --- [3/10] CLI OAuth stores (XDG data home) --------------------------------------
    if ($KeepLogin) {
        Write-Host "[3/10] CLI OAuth stores SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[3/10] Deleting auth.json + mcp-auth.json in the XDG data home..." -ForegroundColor Cyan
        $authOk = $true
        foreach ($rel in @('auth.json', 'mcp-auth.json')) {
            if (-not (Remove-OcFile -Path (Join-Path $roots.Xdg $rel) -BackupRoot $backupRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun)) { $authOk = $false }
        }
        if ($authOk) { $passCount++ } else { $failCount++ }
    }

    # --- [4/10] Device + updater identity ------------------------------------------------
    Write-Host "[4/10] Clearing device-id + updater identity..." -ForegroundColor Cyan
    $devOk = $true
    foreach ($p in @(
        (Join-Path $roots.Desktop 'gh\device-id'),
        (Join-Path $roots.Desktop 'data\gh\device-id'),
        (Join-Path $roots.Desktop '.updaterId')
    )) {
        if (-not (Remove-OcFile -Path $p -BackupRoot $backupRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun)) { $devOk = $false }
    }
    if ($devOk) { $passCount++ } else { $failCount++ }

    # --- [5/10] Session-profile scrub (Local State + network session) ----------------------
    if ($KeepLogin) {
        Write-Host "[5/10] Session-profile scrub SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[5/10] Scrubbing the session profile (Local State + network session)..." -ForegroundColor Cyan
        $sessOk = $true
        if (-not (Remove-OcFile -Path (Join-Path $roots.Session 'Local State') -BackupRoot $backupRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun)) { $sessOk = $false }
        foreach ($rel in @('Network\Cookies', 'Network\Cookies-journal', 'Network\Trust Tokens', 'Network\Trust Tokens-journal', 'Network\Network Persistent State')) {
            if (-not (Remove-OcFile -Path (Join-Path $roots.Session $rel) -BackupRoot $backupRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun)) { $sessOk = $false }
        }
        if ($sessOk) { $passCount++ } else { $failCount++ }
    }

    # --- [6/10] Session-profile caches sweep -----------------------------------------------
    if ($KeepLogin) {
        Write-Host "[6/10] Session-profile caches SKIPPED (-KeepLogin: they live beside the kept login)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[6/10] Sweeping session-profile caches..." -ForegroundColor Cyan
        $cacheOk = $true
        foreach ($rel in @('Cache', 'Code Cache', 'GPUCache', 'GPUPersistentCache', 'GrShaderCache', 'ShaderCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'DIPS', 'SharedStorage', 'Shared Dictionary', 'Local Storage', 'WebStorage', 'blob_storage')) {
            $p = Join-Path $roots.Session $rel
            if (Test-Path -LiteralPath $p -PathType Container) {
                if (-not (Sweep-OcTree -Path $p -BackupRoot $backupRoot -Audit ([ref]$audit) -IsDryRun $DryRun)) { $cacheOk = $false }
            }
        }
        if ($cacheOk) { $passCount++ } else { $failCount++ }
    }

    # --- [7/10] userData sweeps (Crashpad/logs/compile-cache) ---------------------------------
    Write-Host "[7/10] Sweeping userData diagnostics + temp caches..." -ForegroundColor Cyan
    $udOk = $true
    foreach ($rel in @('Crashpad', 'logs', 'compile-cache')) {
        $p = Join-Path $roots.Desktop $rel
        if (Test-Path -LiteralPath $p -PathType Container) {
            if (-not (Sweep-OcTree -Path $p -BackupRoot $backupRoot -Audit ([ref]$audit) -IsDryRun $DryRun)) { $udOk = $false }
        }
    }
    if ($udOk) { $passCount++ } else { $failCount++ }

    # --- [8/10] Final verify probe --------------------------------------------------------------
    Write-Host "[8/10] Final verify probe..." -ForegroundColor Cyan
    $verifyOk = $true
    if (-not $DryRun) {
        foreach ($p in $deleted) {
            if (Test-Path -LiteralPath $p) {
                Write-Host "    [FAILED] expected-deleted path still present: $p" -ForegroundColor Red
                $verifyOk = $false
            }
        }
    }
    if ($verifyOk) { $passCount++ } else { $failCount++ }

    # --- [9/10] Audit + restore script -------------------------------------------------------------
    Write-Host "[9/10] Writing audit + restore script..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "    [DRY] audit + restore skipped in dry-run." -ForegroundColor Cyan
        $passCount++
    }
    else {
        $auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
        Write-AuditLog -Audit $audit -Path $auditPath
        $restorePath = New-RestoreScript -BackupRoot $backupRoot -App 'OpenCode' -Actions $actions
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

    # --- [10/10] Summary ------------------------------------------------------------------------------
    Write-Host "[10/10] Summary." -ForegroundColor Cyan
    Write-Host "`n--- $(Get-OpenCodeTargetDisplay $label) summary ---" -ForegroundColor Cyan
    Write-Host "Pass: $passCount  Fail: $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
    $globalPass += $passCount
    $globalFail += $failCount
}

Write-Host "`n=== OpenCode reset summary ===" -ForegroundColor Cyan
Write-Host "Targets: $($targets -join ', ')  Pass: $globalPass  Fail: $globalFail" -ForegroundColor $(if ($globalFail -gt 0) { 'Red' } else { 'Green' })
Write-Host "NOTE: sessions (opencode.db), repos, snapshots, drafts, MCP config and the CLI cache are preserved by design." -ForegroundColor Yellow
Write-Host "NOTE: relaunch via the OpenCode Blue/Yellow/Green/Red/Orange shortcuts or the launcher - a bare OpenCode.exe opens the PRIMARY profile." -ForegroundColor Yellow
Write-Host "NOTE: every target signs in again after this reset (unless -KeepLogin was used)." -ForegroundColor Yellow

if (-not $DryRun) {
    [System.IO.File]::WriteAllText("$env:TEMP\opencode_reset_done.txt",
        ("Pass: {0} Fail: {1}" -f $globalPass, $globalFail),
        (New-Object System.Text.UTF8Encoding $false))
}

if ($globalFail -gt 0) {
    Write-Host "OpenCode reset completed with failures. Review the audit JSON in each ID_Backups\<ts> dir." -ForegroundColor Red
    exit 1
}

Write-Host "OpenCode reset completed successfully."
