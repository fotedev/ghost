#Requires -Version 5.1
# AutoClaw2 Identity Reset v0.1 — thin manifest over the Python core
#
# Reset target: Primary (%APPDATA%\AutoClaw-oversea-official) and/or the
# five clones (%USERPROFILE%\AutoClaw2ClonesHome\c1..c5). The profile dir IS
# the whole Electron userData (ZWORK_USER_DATA), so one root per target.
#
# Phase 1 discovery provenance (2026-11-14, this host, read-only probes):
#   - device\device-id.json = {"schemaVersion":1,"deviceId":"<uuid4>"} —
#     generated fresh per profile on first run (spec §3); the reset ROTATES
#     it in place (json-patch) instead of deleting, so the verify-after can
#     assert old != new. A missing file is fine too (the app generates one).
#   - device\active-product-account.json = {"schemaVersion":1,"accountKey":
#     "<sha>"} — the signed-in account pointer. Deleted = signed out.
#   - accounts\<sha>\account-credentials.enc (AES-256-GCM custody under the
#     DPAPI'd OSCrypt key from Local State) + account-profile.json (account
#     identity: accountId/displayName/email) = auth stores. Deleted.
#   - accounts\<sha>\runtime\ = work/chat data: runtime.sqlite (+wal/shm),
#     artifacts, desktop-attachments, projects, desktop-preferences.json,
#     telegram-connection.json, traces, model-catalog. PRESERVED — a reset
#     must never wipe chats/work (same contract as every GHOST reset).
#     runtime\owner-secrets.enc + runtime\model-connection-command-claims.enc
#     ARE secrets -> deleted (chat rows referencing the old credential
#     version stay; the next sign-in writes a fresh credentials.enc).
#   - Local State = ONLY os_crypt (audit_enabled + encrypted_key) +
#     uninstall_metrics -> deleted whole (the app regenerates; this also
#     renders any surviving encrypted blob unreadable). SKIPPED under
#     -KeepLogin (deleting the OSCrypt key would break the KEPT credentials).
#   - Network\ = Cookies(+journal), Trust Tokens(+journal), Network
#     Persistent State -> deleted (login session). TransportSecurity kept.
#   - Telemetry: apmplus\ (tree), log_sdk_v2.db, startup-analytics-marker.json,
#     diagnostics\, logs\ -> swept (backup first).
#   - Caches/privacy: Cache, Code Cache, GPUCache, DawnGraphiteCache,
#     DawnWebGPUCache, blob_storage, compile-cache, DIPS, SharedStorage,
#     Shared Dictionary, Local Storage, Partitions\zwork-account-* +
#     zwork-native-browser-* -> swept. Partitions hold the per-account web
#     sessions (incl. the login webview) -> skipped under -KeepLogin.
#   - Never touched: channel.json, launch.json, toolchain\, office-plugin\,
#     updates\, window-state.json, ID_Backups\.
#
# TARGETS: -Target Primary|c1..c5|All. All = clones first, Primary last;
# every target gets an INDEPENDENT fresh device id.
#
# SCOPE ISOLATION: no MAC / hostname / registry steps here — those belong
# strictly to change_device_id.ps1. AutoClaw2 device identity is app-local.
#
# USAGE:
#   powershell -ExecutionPolicy Bypass -File reset_autoclaw2.ps1 [-Target c1]
#              [-KeepLogin] [-DryRun]
# The script self-elevates (UAC) and reports Pass/Fail through a done-marker
# in %TEMP% (same channel as reset_cursor.ps1).
#
# PS 5.1 COMPAT: no ternary, no $Input, RandomNumberGenerator via .GetBytes().

param(
    [ValidateSet('Primary', 'c1', 'c2', 'c3', 'c4', 'c5', 'All')][string]$Target = 'Primary',
    [switch]$KeepLogin,
    [switch]$DryRun
)

. "$PSScriptRoot\identity_utils.ps1"

# --- Pure helpers (Pester-tested; see tests\reset_autoclaw2.Tests.ps1) =======

$script:Ac2CloneKeys = @('c1', 'c2', 'c3', 'c4', 'c5')

function Get-Ac2TargetRoots {
    # One root per target: the profile dir IS the Electron userData.
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'Primary') {
        return Join-Path $env:APPDATA 'AutoClaw-oversea-official'
    }
    return Join-Path (Join-Path $env:USERPROFILE 'AutoClaw2ClonesHome') $Label
}

function Get-Ac2TargetOrder {
    # All = clones first (c1..c5), Primary last. Single target = itself.
    param([Parameter(Mandatory = $true)][string]$Label)
    if ($Label -eq 'All') {
        return @('c1', 'c2', 'c3', 'c4', 'c5', 'Primary')
    }
    return @($Label)
}

function Get-Ac2TargetDisplay {
    # Color-led display vocabulary (the frozen cN keys survive in parens).
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

# Subtree markers per clone: the clone's own profile dir name inside a
# descendant's --user-data-dir cmdline (the launcher pins userData via
# ZWORK_USER_DATA env, so MAIN cmdlines are bare-exe and carry NO marker —
# children carry --user-data-dir=<pinned dir>, same shape the ZCode watcher
# classifies by). Primary marker = its default profile dir.
$script:Ac2CloneMarkers = @{
    'c1' = @('*AutoClaw2ClonesHome\c1*')
    'c2' = @('*AutoClaw2ClonesHome\c2*')
    'c3' = @('*AutoClaw2ClonesHome\c3*')
    'c4' = @('*AutoClaw2ClonesHome\c4*')
    'c5' = @('*AutoClaw2ClonesHome\c5*')
}
$script:Ac2PrimaryMarkers = @('*AutoClaw-oversea-official*')

function Test-DeviceIdShape {
    # device\device-id.json contract (provenance: header). $true only for the
    # exact shape {"schemaVersion":1,"deviceId":"<non-empty string>"}.
    param([AllowNull()]$Json)
    if ($null -eq $Json) { return $false }
    if (-not ($Json.PSObject.Properties.Name -contains 'schemaVersion')) { return $false }
    if (-not ($Json.PSObject.Properties.Name -contains 'deviceId')) { return $false }
    if ($Json.schemaVersion -ne 1) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Json.deviceId)) { return $false }
    return $true
}

function Join-Ac2DeletedList {
    param([ref]$List, [Parameter(Mandatory = $true)][string]$Path)
    if ($null -eq $List.Value) { $List.Value = @() }
    $List.Value += $Path
}

# --- Dot-source guard: everything below runs ONLY on direct execution ========
if ($MyInvocation.InvocationName -eq '.') { return }

# --- Self-elevation (same channel as reset_cursor.ps1) ------------------------
$ac2IsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $ac2IsAdmin) {
    $ac2Script = $MyInvocation.MyCommand.Path
    $ac2Args = "-ExecutionPolicy Bypass -NoProfile -File `"$ac2Script`" -Target $Target"
    if ($KeepLogin) { $ac2Args += ' -KeepLogin' }
    if ($DryRun) { $ac2Args += ' -DryRun' }
    Remove-Item -LiteralPath "$env:TEMP\autoclaw2_reset_done.txt" -Force -ErrorAction SilentlyContinue
    Start-Process powershell -Verb RunAs -ArgumentList $ac2Args -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\autoclaw2_reset_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\autoclaw2_reset_done.txt" -Encoding UTF8
    }
    exit
}

Write-GhostBanner -Target "AutoClaw2 Identity Reset" -Version "0.1"

# --- Local helpers =============================================================
# Orchestration only. Every store mutation delegates to the Python core.

function _B64Payload {
    param([Parameter(Mandatory = $true)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Invoke-GhostCore {
    # The ONE PS -> Python invocation point for every store mutation.
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)
    $cli = Get-GhostPythonCli
    if (-not $cli) {
        Write-Host "[FAILED] GHOST Python core not found (src\python\ghost_cli.py)." -ForegroundColor Red
        return $null
    }
    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Write-Host "[FAILED] no functional Python 3 found - every AutoClaw2 reset step needs it." -ForegroundColor Red
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

function Backup-Ac2File {
    # Backs one file up via the core and records the restore action. A failed
    # backup is reported but NOT fatal (the deletion may still succeed; the
    # reset_cusor v0.2 contract verbatim).
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][ref]$Audit
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $true }
    $report = Invoke-GhostCore @('backup', $Source, $BackupRoot,
        (Get-PathBackupLabel -Path $Source))
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

function Remove-Ac2File {
    # store-delete (backup already taken by the caller) with a PS-side
    # verify-after re-read; missing = clean no-op, never silent success.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Deleted,
        [Parameter(Mandatory = $true)][bool]$IsDryRun,
        [Parameter(Mandatory = $true)][bool]$Required
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
        (Get-PathBackupLabel -Path $Path), '--action', 'delete',
        '--root-path', $ProfileRoot)
    $gone = -not (Test-Path -LiteralPath $Path)
    if ($null -ne $report -and $report.ok -and $gone) {
        Write-Host "    [OK] deleted + verified: $Path" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File $Path -Key 'delete' -Before 'present' -After 'deleted' -Ok $true
        Join-Ac2DeletedList -List $Deleted -Path $Path
        return $true
    }
    Write-Host "    [FAILED] delete/verify: $Path" -ForegroundColor Red
    Add-AuditEntry -Audit $Audit -File $Path -Key 'delete' -Before 'present' -After 'still-present' -Ok $false
    return $false
}

function Sweep-Ac2Tree {
    # sweep-tree (core backs up then deletes every file inside) + verify-after.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$ProfileRoot,
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
    $report = Invoke-GhostCore @('sweep-tree', $Path, $BackupRoot,
        (Get-PathBackupLabel -Path $Path))
    $leftovers = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue)
    if ($null -ne $report -and $report.ok -and $leftovers.Count -eq 0) {
        Write-Host "    [OK] swept + verified: $Path" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'present' -After 'swept' -Ok $true
        return $true
    }
    if ($null -ne $report -and $report.ok) {
        # Empty dirs remaining are acceptable (the core deletes files, not dirs)
        Write-Host "    [OK] swept (empty dirs may remain): $Path" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'present' -After 'swept' -Ok $true
        return $true
    }
    Write-Host "    [FAILED] sweep/verify: $Path" -ForegroundColor Red
    Add-AuditEntry -Audit $Audit -File $Path -Key 'sweep' -Before 'present' -After 'failed' -Ok $false
    return $false
}

# Aggressive tree-kill for the target's AutoClaw2 processes (marker-classified
# subtree walk). Requires 2 consecutive clean checks; hard-fails when
# unkillable. Family filter covers the whole exe family (no per-color copies
# exist yet, but 'AutoClaw2%' is future-proof for a Task-Manager identity suite).
function Get-Ac2TargetMains {
    param([Parameter(Mandatory = $true)][string]$Label)
    $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoClaw2%'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    $byParent = @{}
    foreach ($p in $procs) {
        if ($null -eq $p.ProcessId) { continue }
        if (-not $byParent.ContainsKey([int]$p.ParentProcessId)) { $byParent[[int]$p.ParentProcessId] = @() }
        $byParent[[int]$p.ParentProcessId] += $p
    }

    # A main is ONLY a bare-exe process (CommandLine == the exe path, quoted or
    # not, no args). Helpers (--type=*, gateway, toolchain spawns) carry extra
    # args and must NOT be treated as mains (EC-K01: the --type filter alone
    # misclassified helpers as helpers on the ZCode side; the bare-exe rule
    # catches both).
    function Test-BareExeMain([string]$Cmd, [string]$Name) {
        if ([string]::IsNullOrWhiteSpace($Cmd)) { return $false }
        if ($Cmd -match '--type=') { return $false }
        $bare = '^\s*"?[^"]*\\' + [regex]::Escape($Name) + '"?\s*$'
        return ($Cmd -match $bare)
    }

    function Test-SubtreeMarkers($Proc, [string[]]$Markers) {
        # Walk the subtree; any descendant (or the process itself) whose
        # CommandLine matches a marker decides.
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
            if (Test-SubtreeMarkers $m $script:Ac2PrimaryMarkers) { $matched += $m; continue }
            # Unmatched mains are Primary: a bare AutoClaw2.exe launch carries
            # no marker and resolves to the default profile dir.
            if (-not (Test-SubtreeMarkers $m (@($script:Ac2CloneMarkers.Values | ForEach-Object { $_ }) ))) {
                $matched += $m
            }
        }
        else {
            if (Test-SubtreeMarkers $m $script:Ac2CloneMarkers[$Label]) { $matched += $m }
        }
    }
    return $matched
}

function Stop-Ac2TargetProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][bool]$IsDryRun
    )
    if ($IsDryRun) {
        $dryMains = @(Get-Ac2TargetMains -Label $Label)
        Write-Host ("[DRY] would tree-kill {0} main process(es) of {1}." -f $dryMains.Count, (Get-Ac2TargetDisplay $Label)) -ForegroundColor Cyan
        return $true
    }
    $maxAttempts = 10
    $attempt = 0
    while ($attempt -lt $maxAttempts) {
        $mains = @(Get-Ac2TargetMains -Label $Label)
        if ($mains.Count -eq 0) { break }
        foreach ($m in $mains) {
            try { Stop-Process -Id $m.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 1500
        $attempt++
    }
    $remaining = @(Get-Ac2TargetMains -Label $Label)
    if ($remaining.Count -gt 0) {
        Write-Host ("[FAILED] {0} AutoClaw2 process(es) of {1} survived {2} kill attempts." -f $remaining.Count, (Get-Ac2TargetDisplay $Label), $maxAttempts) -ForegroundColor Red
        return $false
    }
    return $true
}

# --- Main ======================================================================

if ($DryRun) {
    Write-Host "=== DRY RUN - no store will be touched ===" -ForegroundColor Magenta
}

$targets = Get-Ac2TargetOrder -Label $Target
$globalPass = 0
$globalFail = 0

foreach ($label in $targets) {
    $profileRoot = Get-Ac2TargetRoots -Label $label
    Write-Host "`n=== Target: $(Get-Ac2TargetDisplay $label) ===" -ForegroundColor Cyan
    Write-Host "Profile: $profileRoot"

    if (-not (Test-Path -LiteralPath $profileRoot -PathType Container)) {
        Write-Host "[SKIP] profile dir not found - nothing to reset (never seed it here; the launcher owns first-run seeding)." -ForegroundColor Yellow
        continue
    }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupRoot = Join-Path $profileRoot 'ID_Backups'
    $backupRoot = Join-Path $backupRoot $timestamp
    $audit = @()
    $actions = @()
    $deleted = @()
    $passCount = 0
    $failCount = 0
    $oldDeviceId = $null
    $newDeviceId = $null

    # --- [1/12] Stop the target's processes ------------------------------------
    Write-Host "`n[1/12] Stopping $(Get-Ac2TargetDisplay $label) processes..." -ForegroundColor Cyan
    if (Stop-Ac2TargetProcesses -Label $label -IsDryRun $DryRun) {
        Write-Host "[OK] no matching AutoClaw2 processes running (or killed)." -ForegroundColor Green
        $passCount++
    } else { $failCount++ }

    # --- [2/12] Backup the identity set -----------------------------------------
    Write-Host "[2/12] Backing up identity stores to ID_Backups\$timestamp..." -ForegroundColor Cyan
    $backupTargets = @(
        (Join-Path $profileRoot 'device\device-id.json'),
        (Join-Path $profileRoot 'device\active-product-account.json'),
        (Join-Path $profileRoot 'Local State'),
        (Join-Path $profileRoot 'Network\Cookies'),
        (Join-Path $profileRoot 'Network\Trust Tokens'),
        (Join-Path $profileRoot 'Network\Network Persistent State')
    )
    foreach ($acctDir in @(Get-ChildItem -LiteralPath (Join-Path $profileRoot 'accounts') -Directory -ErrorAction SilentlyContinue)) {
        $backupTargets += (Join-Path $acctDir.FullName 'account-credentials.enc')
        $backupTargets += (Join-Path $acctDir.FullName 'account-profile.json')
        $backupTargets += (Join-Path $acctDir.FullName 'runtime\owner-secrets.enc')
        $backupTargets += (Join-Path $acctDir.FullName 'runtime\model-connection-command-claims.enc')
    }
    $backupOk = $true
    foreach ($src in $backupTargets) {
        if (-not (Backup-Ac2File -Source $src -BackupRoot $backupRoot -ProfileRoot $profileRoot -Actions ([ref]$actions) -Audit ([ref]$audit))) {
            $backupOk = $false
        }
    }
    if ($DryRun) { Write-Host "    [DRY] backup step skipped in dry-run." -ForegroundColor Cyan }
    elseif ($backupOk) { Write-Host "[OK] identity set backed up (missing files skipped)." -ForegroundColor Green; $passCount++ }
    else { $failCount++ }

    # --- [3/12] Rotate device\device-id.json ------------------------------------
    Write-Host "[3/12] Rotating device-id..." -ForegroundColor Cyan
    $deviceFile = Join-Path $profileRoot 'device\device-id.json'
    if (-not (Test-Path -LiteralPath $deviceFile -PathType Leaf)) {
        Write-Host "    [OK] device-id.json absent - the app generates a fresh one on next launch." -ForegroundColor Green
        Add-AuditEntry -Audit ([ref]$audit) -File $deviceFile -Key 'device-id' -Before 'absent' -After 'absent-will-regenerate' -Ok $true
        $passCount++
    }
    else {
        try { $oldJson = Get-Content -LiteralPath $deviceFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $oldJson = $null }
        if (Test-DeviceIdShape $oldJson) { $oldDeviceId = [string]$oldJson.deviceId }
        $newDeviceId = [Guid]::NewGuid().ToString()
        if ($DryRun) {
            Write-Host "    [DRY] would rotate device-id (old=$(if ($oldDeviceId) { $oldDeviceId.Substring(0,8) } else { '<unreadable>' })...)." -ForegroundColor Cyan
        }
        else {
            $rep = Invoke-GhostCore @('json-patch', $deviceFile, (_B64Payload @{ deviceId = $newDeviceId }))
            $verify = $null
            try { $verify = Get-Content -LiteralPath $deviceFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $verify = $null }
            if ($null -ne $rep -and $rep.ok -and (Test-DeviceIdShape $verify) -and ([string]$verify.deviceId -eq $newDeviceId) -and ([string]$verify.deviceId -ne $oldDeviceId)) {
                Write-Host "    [OK] device-id rotated + re-read verified (old != new)." -ForegroundColor Green
                Add-AuditEntry -Audit ([ref]$audit) -File $deviceFile -Key 'device-id' -Before $oldDeviceId -After $newDeviceId -Ok $true
                $passCount++
            }
            else {
                Write-Host "    [FAILED] device-id rotation verify-after." -ForegroundColor Red
                Add-AuditEntry -Audit ([ref]$audit) -File $deviceFile -Key 'device-id' -Before $oldDeviceId -After 'verify-failed' -Ok $false
                $failCount++
            }
        }
    }

    # --- [4/12] Signed-out marker (skip under -KeepLogin) ------------------------
    if ($KeepLogin) {
        Write-Host "[4/12] Signed-out marker SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[4/12] Clearing the active-product-account pointer..." -ForegroundColor Cyan
        if (Remove-Ac2File -Path (Join-Path $profileRoot 'device\active-product-account.json') -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun -Required $false) { $passCount++ } else { $failCount++ }
    }

    # --- [5/12] Per-account auth scrub -------------------------------------------
    if ($KeepLogin) {
        Write-Host "[5/12] Account auth scrub SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[5/12] Scrubbing account credentials + profile per account dir..." -ForegroundColor Cyan
        $acctAllOk = $true
        $acctDirs = @(Get-ChildItem -LiteralPath (Join-Path $profileRoot 'accounts') -Directory -ErrorAction SilentlyContinue)
        if ($acctDirs.Count -eq 0) { Write-Host "    [OK] no account dirs present." -ForegroundColor DarkGray }
        foreach ($acctDir in $acctDirs) {
            foreach ($rel in @('account-credentials.enc', 'account-profile.json')) {
                if (-not (Remove-Ac2File -Path (Join-Path $acctDir.FullName $rel) -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun -Required $false)) { $acctAllOk = $false }
            }
        }
        if ($acctAllOk) { $passCount++ } else { $failCount++ }
    }

    # --- [6/12] Per-account runtime secrets ---------------------------------------
    if ($KeepLogin) {
        Write-Host "[6/12] Runtime secrets scrub SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[6/12] Scrubbing runtime secrets (owner-secrets + connection claims)..." -ForegroundColor Cyan
        $secAllOk = $true
        foreach ($acctDir in @(Get-ChildItem -LiteralPath (Join-Path $profileRoot 'accounts') -Directory -ErrorAction SilentlyContinue)) {
            foreach ($rel in @('runtime\owner-secrets.enc', 'runtime\model-connection-command-claims.enc')) {
                if (-not (Remove-Ac2File -Path (Join-Path $acctDir.FullName $rel) -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun -Required $false)) { $secAllOk = $false }
            }
        }
        if ($secAllOk) { $passCount++ } else { $failCount++ }
    }

    # --- [7/12] Network session scrub ----------------------------------------------
    if ($KeepLogin) {
        Write-Host "[7/12] Network session scrub SKIPPED (-KeepLogin)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[7/12] Scrubbing network session stores..." -ForegroundColor Cyan
        $netAllOk = $true
        foreach ($rel in @('Network\Cookies', 'Network\Cookies-journal', 'Network\Trust Tokens', 'Network\Trust Tokens-journal', 'Network\Network Persistent State')) {
            if (-not (Remove-Ac2File -Path (Join-Path $profileRoot $rel) -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun -Required $false)) { $netAllOk = $false }
        }
        if ($netAllOk) { $passCount++ } else { $failCount++ }
    }

    # --- [8/12] Local State (os_crypt + uninstall_metrics) -------------------------
    if ($KeepLogin) {
        Write-Host "[8/12] Local State SKIPPED (-KeepLogin: deleting the OSCrypt key would break the kept credentials)." -ForegroundColor Yellow
    }
    else {
        Write-Host "[8/12] Deleting Local State (os_crypt key + uninstall_metrics)..." -ForegroundColor Cyan
        if (Remove-Ac2File -Path (Join-Path $profileRoot 'Local State') -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun -Required $false) { $passCount++ } else { $failCount++ }
    }

    # --- [9/12] Telemetry sweep ------------------------------------------------------
    Write-Host "[9/12] Sweeping telemetry stores..." -ForegroundColor Cyan
    $telAllOk = $true
    foreach ($rel in @('apmplus', 'log_sdk_v2.db', 'startup-analytics-marker.json', 'diagnostics', 'logs')) {
        $p = Join-Path $profileRoot $rel
        if (Test-Path -LiteralPath $p -PathType Container) {
            if (-not (Sweep-Ac2Tree -Path $p -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -IsDryRun $DryRun)) { $telAllOk = $false }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            if ($DryRun) { Write-Host "    [DRY] would delete file: $p" -ForegroundColor Cyan }
            elseif (-not (Remove-Ac2File -Path $p -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -Deleted ([ref]$deleted) -IsDryRun $DryRun -Required $false)) { $telAllOk = $false }
        }
    }
    if ($telAllOk) { $passCount++ } else { $failCount++ }

    # --- [10/12] Cache + privacy sweep -------------------------------------------------
    Write-Host "[10/12] Sweeping caches + privacy stores..." -ForegroundColor Cyan
    $cacheAllOk = $true
    foreach ($rel in @('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'blob_storage', 'compile-cache', 'DIPS', 'SharedStorage', 'Shared Dictionary', 'Local Storage')) {
        $p = Join-Path $profileRoot $rel
        if (Test-Path -LiteralPath $p -PathType Container) {
            if (-not (Sweep-Ac2Tree -Path $p -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -IsDryRun $DryRun)) { $cacheAllOk = $false }
        }
    }
    if ($KeepLogin) {
        Write-Host "    Partitions SKIPPED (-KeepLogin: they hold the per-account web sessions)." -ForegroundColor Yellow
    }
    else {
        $partsRoot = Join-Path $profileRoot 'Partitions'
        if (Test-Path -LiteralPath $partsRoot -PathType Container) {
            foreach ($part in @(Get-ChildItem -LiteralPath $partsRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'zwork-account-*' -or $_.Name -like 'zwork-native-browser-*' })) {
                if (-not (Sweep-Ac2Tree -Path $part.FullName -BackupRoot $backupRoot -ProfileRoot $profileRoot -Audit ([ref]$audit) -IsDryRun $DryRun)) { $cacheAllOk = $false }
            }
        }
    }
    if ($cacheAllOk) { $passCount++ } else { $failCount++ }

    # --- [11/12] Final verify probe ---------------------------------------------------
    Write-Host "[11/12] Final verify probe..." -ForegroundColor Cyan
    $verifyOk = $true
    if (-not $DryRun) {
        if ($null -ne $oldDeviceId) {
            $nowJson = $null
            try { $nowJson = Get-Content -LiteralPath (Join-Path $profileRoot 'device\device-id.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $nowJson = $null }
            if ((Test-DeviceIdShape $nowJson) -and ([string]$nowJson.deviceId -ne $oldDeviceId)) {
                Write-Host "    [OK] device-id differs from the pre-reset value." -ForegroundColor Green
            }
            else {
                Write-Host "    [FAILED] device-id did not change (or unreadable)." -ForegroundColor Red
                $verifyOk = $false
            }
        }
        foreach ($p in $deleted) {
            if (Test-Path -LiteralPath $p) {
                Write-Host "    [FAILED] expected-deleted path still present: $p" -ForegroundColor Red
                $verifyOk = $false
            }
        }
    }
    if ($verifyOk) { $passCount++ } else { $failCount++ }

    # --- [12/12] Audit + restore script -------------------------------------------------
    Write-Host "[12/12] Writing audit + restore script..." -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "    [DRY] audit + restore skipped in dry-run." -ForegroundColor Cyan
        $passCount++
    }
    else {
        $auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
        Write-AuditLog -Audit $audit -Path $auditPath
        $restorePath = New-RestoreScript -BackupRoot $backupRoot -App 'AutoClaw2' -Actions $actions
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

    Write-Host "`n--- $(Get-Ac2TargetDisplay $label) summary ---" -ForegroundColor Cyan
    Write-Host "Pass: $passCount  Fail: $failCount" -ForegroundColor $(if ($failCount -gt 0) { 'Red' } else { 'Green' })
    $globalPass += $passCount
    $globalFail += $failCount
}

Write-Host "`n=== AutoClaw2 reset summary ===" -ForegroundColor Cyan
Write-Host "Targets: $($targets -join ', ')  Pass: $globalPass  Fail: $globalFail" -ForegroundColor $(if ($globalFail -gt 0) { 'Red' } else { 'Green' })
Write-Host "NOTE: chats, work runs, projects, MCP connections and Telegram routing are preserved by design." -ForegroundColor Yellow
Write-Host "NOTE: relaunch profiles via their AutoClaw2 Blue..Orange shortcuts or the launcher - a bare AutoClaw2.exe opens the PRIMARY profile." -ForegroundColor Yellow
Write-Host "NOTE: every profile signs in again after this reset (unless -KeepLogin was used)." -ForegroundColor Yellow

if (-not $DryRun) {
    [System.IO.File]::WriteAllText("$env:TEMP\autoclaw2_reset_done.txt",
        ("Pass: {0} Fail: {1}" -f $globalPass, $globalFail),
        (New-Object System.Text.UTF8Encoding $false))
}

if ($globalFail -gt 0) {
    Write-Host "AutoClaw2 reset completed with failures. Review the audit JSON in each ID_Backups\<ts> dir." -ForegroundColor Red
    exit 1
}

Write-Host "AutoClaw2 reset completed successfully."
