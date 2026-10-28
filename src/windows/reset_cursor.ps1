#Requires -Version 5.1
# Cursor Identity Reset v0.3 — thin manifest over the Python core
#
# Phase 3 pilot per docs/PYTHON_HYBRID_ROADMAP.md: the 15 steps and their
# order, audit keys, restore-script actions and summary are IDENTICAL to
# v0.2 (archived at archive/reset_cursor_windows-v0.2.ps1); every store
# mutation now runs through src\python\ghost_cli.py (base64 payload in,
# JSON report out) via ONE invocation helper. What was deleted from v0.2:
# the inline temp-.py heredoc (step 4 now uses the shared delete-secrets
# subcommand - the exact de-duplication the repo conventions mandate), and
# ~400 lines of one-off local mutation helpers replaced by the tested
# ghost.filesweep / ghost.winstore / ghost.backup modules.
#
# PRESERVATION (chat history + workspaces are never wiped):
#   - composerHeaders table + all chat/composer keys: never touched.
#   - Local Storage\leveldb (UI state) + Backups\ (editor backups): preserved.
#   - User\workspaceStorage\**: serviceMachineId UPSERT only; tables/files and
#     stale .backup sidecars are never deleted.
#   - Third-party secrets (mcpOAuth.*, vscode.git git-ipc tokens, other
#     extensions' secret:// entries): never touched.
#
# SCOPE ISOLATION: no MAC / hostname / registry-source steps here. Those belong
# strictly to change_device_id.ps1.
#
# PS 5.1 COMPAT: no [CmdletBinding()], no ternary, no $Input variable,
# RandomNumberGenerator via .GetBytes() only.
#
# Usage (Windows 10, PowerShell 5.1 or 7 -- just double-click or run):
#   powershell -ExecutionPolicy Bypass -File reset_cursor.ps1
# Prerequisite: close Cursor first (the script also force-kills it).
# Requirement: Python (python or python3) for EVERY store mutation now
# (v0.2 needed it only for SQLite writes). The functional probe in
# identity_utils.ps1 detects it; without Python the run fails fast.
# Note: the device_id_salt is now lowercase hex (Python secrets.token_hex);
# v0.2 generated uppercase. The value is an opaque random salt - case is
# not significant to the app.

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
$cursorIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $cursorIsAdmin) {
    $cursorScript = $MyInvocation.MyCommand.Path
    # -File passes only declared switches; a redirect operator after -File is
    # just swallowed as an undeclared argument. The *_done.txt marker file
    # (not a log) is the persisted result channel - the elevated console shows
    # the full live output while the run progresses.
    $cursorArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$cursorScript`""
    # A stale done-marker from a PREVIOUS run must never be shown as this
    # run's result: the elevated child writes the marker only at the end of
    # its FULL main path, so delete it before launching (an early child exit
    # then surfaces as no result, never as the old Pass/Fail lines).
    Remove-Item -LiteralPath "$env:TEMP\cursor_v0.3_done.txt" -Force -ErrorAction SilentlyContinue
    Start-Process powershell -Verb RunAs -ArgumentList $cursorArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\cursor_v0.3_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\cursor_v0.3_done.txt" -Encoding UTF8
    }
    exit
}

Write-GhostBanner -Target "Cursor Identity Reset" -Version "0.3"

# === Local helpers ============================================================
# Orchestration only. Every store mutation delegates to the Python core.

function Add-ActionEntry {
    param(
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][string]$OriginalPath,
        [string]$BackupPath,
        [ValidateSet("copy", "rename", "delete")][string]$Action = "copy",
        [string]$RenamedPath
    )

    if ($null -eq $Actions.Value) {
        $Actions.Value = @()
    }

    $Actions.Value += [ordered]@{
        action       = $Action
        originalPath = $OriginalPath
        backupPath   = $BackupPath
        renamedPath  = $RenamedPath
    }
}

function Get-AppRelativeBackupLabel {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    if ($TargetPath.StartsWith($RootPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $TargetPath.Substring($RootPath.Length).TrimStart("\")
    }

    return Get-PathBackupLabel -Path $TargetPath
}

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
    # the subcommand failed (exit code non-zero). Same recipe Set-SqliteKeys
    # uses: functional python probe + UTF-8 console + exit-code check.
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)

    $cli = Get-GhostPythonCli
    if (-not $cli) {
        Write-Host "[FAILED] GHOST Python core not found (src\python\ghost_cli.py)." -ForegroundColor Red
        return $null
    }
    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Write-Host "[FAILED] no functional Python 3 found - every Cursor reset step needs it." -ForegroundColor Red
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

function Backup-ViaCore {
    # Backup-FileToTimestampDir via the core, plus the restore-manifest
    # action. A locked/failed backup is reported but NOT fatal - the v0.2
    # contract verbatim (a file whose copy could not be read may still be
    # deletable, and the caller proceeds).
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    $report = Invoke-GhostCore @("backup", $Source, $BackupRoot, $Label)
    if ($null -eq $report) {
        # Core-invoke failure (core exit 1: locked/verify/io) discards the
        # report JSON - surface the failure instead of returning silently
        # (v0.2 warned on failed backups; "proceed anyway" contract kept).
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

# Aggressive tree-kill for Cursor plus extension helpers that hold file
# handles. Requires 2 consecutive clean checks; hard-fails when unkillable.
function Stop-CursorProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all Cursor + extension-helper processes (aggressive tree-kill)..." -ForegroundColor Cyan

    $processesToKill = @(
        "Cursor",
        "Cursor Helper",
        "Cursor Helper (GPU)",
        "Cursor Helper (Renderer)",
        "kilo",
        "roo",
        "cline",
        "cline-host",
        "blackbox"
    )

    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        foreach ($processName in $processesToKill) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                $null = & taskkill /F /T /IM "$processName.exe" 2>&1
            }
        }

        Start-Sleep -Milliseconds $DelayMs

        $cursorRemaining = @(Get-Process -Name "Cursor*" -ErrorAction SilentlyContinue)
        $helperRemaining = 0
        foreach ($helperName in @("kilo", "cline", "cline-host", "roo", "blackbox")) {
            $helperRemaining += @(Get-Process -Name $helperName -ErrorAction SilentlyContinue).Count
        }
        $count = $cursorRemaining.Count + $helperRemaining
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all Cursor + extension-helper processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($p in @(Get-Process -Name "Cursor*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    Cursor PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($helperName in @("kilo", "cline", "cline-host", "roo", "blackbox")) {
        foreach ($p in @(Get-Process -Name $helperName -ErrorAction SilentlyContinue)) {
            Write-Host ("    $helperName PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
        }
    }
    return $false
}

# Post-reset watchdog probe: a slow-shutdown helper can recreate core identity
# files within seconds of deletion. Re-delete with a WARN audit entry (the
# v0.2 logic verbatim; the deletion itself stays PS - pure process/file op).
# Returns $true when nothing was recreated or every re-delete verified gone,
# $false when any re-delete failed - the caller turns this into pass/fail.
function Test-WatchdogRecreation {
    param(
        [Parameter(Mandatory = $true)][string[]]$CoreFiles,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    Write-Host "[*] Verifying no watchdog recreated core identity files..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    $recreated = @()
    foreach ($path in $CoreFiles) {
        if (Test-Path -LiteralPath $path) {
            $recreated += $path
        }
    }

    if ($recreated.Count -eq 0) {
        Write-Host "[OK] no identity files were recreated by a watchdog" -ForegroundColor Green
        Add-AuditEntry -Audit $Audit -File "watchdog-probe" -Key "recreation-check" -Before "none" -After "none" -Ok $true
        return $true
    }

    $allReDeleted = $true
    foreach ($path in $recreated) {
        Write-Host "    [WARN] watchdog recreated file, re-deleting: $path" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        $afterValue = if (Test-Path -LiteralPath $path) { "re-delete-failed" } else { "re-deleted" }
        if ($afterValue -eq "re-delete-failed") {
            Write-Host "    [FAILED] could not re-delete (file locked?): $path" -ForegroundColor Red
            $allReDeleted = $false
        }
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After $afterValue -Ok ($afterValue -eq "re-deleted")
    }
    return $allReDeleted
}

# Purge every ID_Backups run EXCEPT the current one (each run re-backs-up
# everything it touches, so old runs only preserve OLD fingerprints).
# Returns $true when every targeted dir is verifiably gone after deletion,
# $false when any survived (locked dir) - the caller turns this into pass/fail.
function Invoke-OldIdBackupsPurge {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$IdBackupsRoot,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    $currentTimestamp = Split-Path -Leaf $BackupRoot
    if (-not (Test-Path -LiteralPath $IdBackupsRoot)) {
        Add-AuditEntry -Audit $Audit -File $IdBackupsRoot -Key "id-backups-purge" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    no ID_Backups directory to purge" -ForegroundColor DarkGray
        return $true
    }

    $allBackups = @(Get-ChildItem -LiteralPath $IdBackupsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $toDelete = @($allBackups | Where-Object { $_.Name -ne $currentTimestamp })

    if ($toDelete.Count -eq 0) {
        Add-AuditEntry -Audit $Audit -File $IdBackupsRoot -Key "id-backups-purge" -Before "none" -After "none" -Ok $true
        Write-Host "    no older ID_Backups to purge (only current run present)" -ForegroundColor DarkGray
        return $true
    }

    $purgeAllDeleted = $true
    foreach ($dir in $toDelete) {
        Write-Host "    [PURGE] $($dir.Name) (preserved old fingerprint; deleting)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        # "Removed" is not "gone": re-check the deletion and audit the truth -
        # a locked old backup dir must fail the step, not pass as deleted.
        $deletedOk = -not (Test-Path -LiteralPath $dir.FullName)
        $afterValue = "deleted"
        if (-not $deletedOk) {
            $afterValue = "delete-failed"
            $purgeAllDeleted = $false
            Write-Host "    [FAILED] old backup dir still present (locked?): $($dir.FullName)" -ForegroundColor Red
        }
        Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After $afterValue -Ok $deletedOk
    }
    return $purgeAllDeleted
}

# Audit entries added since $StartIndex that pertain to $Path (or children)
# with ok=$false mean the step partially failed.
function Get-StepAuditStatus {
    param(
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][int]$StartIndex,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $newEntries = @($Audit.Value | Select-Object -Skip $StartIndex)
    $pathEntries = @($newEntries | Where-Object {
        $_.file -eq $Path -or $_.file.StartsWith($Path + "\")
    })

    if ($pathEntries.Count -eq 0) {
        return @{ Success = $true; FailedEntries = @() }
    }

    $failed = @($pathEntries | Where-Object { -not $_.ok })
    return @{ Success = ($failed.Count -eq 0); FailedEntries = $failed }
}

function Confirm-JsonValues {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Expected
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($key in $Expected.Keys) {
        $actualValue = if ($null -ne $content.PSObject.Properties[$key]) { $content.$key } else { $null }
        if ($actualValue -ne $Expected[$key]) {
            return $false
        }
    }

    return $true
}

# === Main =====================================================================

Assert-Administrator

$app = "Cursor"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$root = Join-Path $env:APPDATA $app
$backupRoot = Join-Path $root ("ID_Backups\" + $timestamp)
$idBackupsRoot = Join-Path $root "ID_Backups"
$machineIdPath = Join-Path $root "machineid"
$storagePath = Join-Path $root "User\globalStorage\storage.json"
$sqlitePath = Join-Path $root "User\globalStorage\state.vscdb"
$workspaceStorageRoot = Join-Path $root "User\workspaceStorage"
$audit = @()
$actions = @()
$ids = New-IdentitySet

if (-not (Test-Path -LiteralPath $root)) {
    Write-Host "Cursor installation not found at: $root" -ForegroundColor Red
    exit 1
}

# The core must be present and a functional Python 3 with it - fail fast
# BEFORE touching anything (v0.2 could run JSON-only steps without Python;
# v0.3 cannot run any step without it).
if ((-not (Get-GhostPythonCli)) -or (-not (Get-PythonCommandInfo))) {
    Write-Host "[FAILED] GHOST Python core (src\python\ghost_cli.py) missing or no functional Python 3 found - every Cursor reset step needs it (winget install Python.Python.3.12)." -ForegroundColor Red
    exit 1
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Cursor Identity Reset v0.3 ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: chat history + workspaces preserved; no MAC/hostname/registry steps" -ForegroundColor Gray

# Pre-step: aggressive tree-kill. Hard-fails the run if unkillable.
if (-not (Stop-CursorProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$storageUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}

# --- [1/15] machineid (core: machineid-file) ---
Write-Host "`n[1/15] Updating machineid..." -ForegroundColor Cyan
$machReport = Invoke-GhostCore @("machineid-file", $machineIdPath, $backupRoot,
    (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $machineIdPath),
    (_B64Payload @{ value = $ids.devDeviceId }))
if ($null -ne $machReport -and $machReport.ok) {
    Add-AuditEntry -Audit ([ref]$audit) -File $machineIdPath -Key "machineid" -Before $machReport.before -After $machReport.after -Ok $true
    if ($machReport.backed_up_to) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $machineIdPath -BackupPath $machReport.backed_up_to
    }
    Write-Host "[OK] machineid verified" -ForegroundColor Green
    $passCount++
}
else {
    $beforeValue = $null
    if (Test-Path -LiteralPath $machineIdPath) {
        # Best-effort evidence read: this branch runs AFTER step [1] already
        # failed, so a locked/0-byte file must not abort the run (EAP = Stop)
        # before the audit log and restore script exist.
        try {
            $beforeValue = (Get-Content -LiteralPath $machineIdPath -Raw -Encoding UTF8).Trim()
        }
        catch {
            $beforeValue = $null
        }
    }
    Add-AuditEntry -Audit ([ref]$audit) -File $machineIdPath -Key "machineid" -Before $beforeValue -After "verify-failed" -Ok $false
    Write-Host "[FAILED] machineid verification failed" -ForegroundColor Red
    $failCount++
}

# --- [2/15] storage.json (4 telemetry keys; verified live: no auth keys here) ---
Write-Host "`n[2/15] Updating storage.json..." -ForegroundColor Cyan
$storageLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storagePath
$null = Backup-ViaCore -Source $storagePath -BackupRoot $backupRoot -Label $storageLabel -Actions ([ref]$actions)
$storageReport = Invoke-GhostCore @("json-patch", $storagePath, (_B64Payload $storageUpdates))
if ($null -ne $storageReport -and $storageReport.ok) {
    foreach ($key in $storageUpdates.Keys) {
        Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key $key -Before $storageReport.before.$key -After $storageReport.after.$key -Ok $true
    }
    Write-Host "[OK] storage.json verified" -ForegroundColor Green
    $passCount++
}
else {
    foreach ($key in $storageUpdates.Keys) {
        Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key $key -Before $null -After $storageUpdates[$key] -Ok $false
    }
    Write-Host "[FAILED] storage.json verification failed" -ForegroundColor Red
    $failCount++
}

# --- [3/15] state.vscdb serviceMachineId (core: sqlite-update) ---
Write-Host "`n[3/15] Updating global state.vscdb (serviceMachineId)..." -ForegroundColor Cyan
$sqliteLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath
if (-not (Test-Path -LiteralPath $sqlitePath)) {
    # sqlite-update would CREATE a missing DB (sqlite3.connect + CREATE TABLE
    # IF NOT EXISTS); Set-SqliteKeys' contract fails loudly instead - match it
    # rather than silently minting a fresh 1-row DB on a broken profile.
    Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "storage.serviceMachineId" -Before "missing" -After "not-found" -Ok $false
    Write-Host "[FAILED] state.vscdb not found: $sqlitePath" -ForegroundColor Red
    $failCount++
}
else {
    $null = Backup-ViaCore -Source $sqlitePath -BackupRoot $backupRoot -Label $sqliteLabel -Actions ([ref]$actions)
    $sqliteReport = Invoke-GhostCore @("sqlite-update", $sqlitePath, (_B64Payload @{ "storage.serviceMachineId" = $ids.devDeviceId }))
    # [OK] only when the core's verify-after re-read returned the exact value
    # we asked for - a non-null report alone is not verification.
    if ($null -ne $sqliteReport -and $null -ne $sqliteReport.after -and ($sqliteReport.after."storage.serviceMachineId" -eq $ids.devDeviceId)) {
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "storage.serviceMachineId" -Before $sqliteReport.before."storage.serviceMachineId" -After $sqliteReport.after."storage.serviceMachineId" -Ok $true
        Write-Host "[OK] global state.vscdb verified" -ForegroundColor Green
        $passCount++
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "storage.serviceMachineId" -Before $null -After $ids.devDeviceId -Ok $false
        Write-Host "[FAILED] global state.vscdb verification failed" -ForegroundColor Red
        $failCount++
    }
}

# --- [4/15] state.vscdb auth secrets DELETE (core: delete-secrets; v0.2's
#     inline temp-.py heredoc replaced by the shared subcommand) ---
# NO second backup here: step [3] already backed state.vscdb up pre-mutation
# under this label; a second call with the same label would replace that
# pre-run copy with post-[3] content and the manifest would then "restore"
# the mutated DB. One pre-run backup, one manifest entry.
Write-Host "`n[4/15] Clearing global state.vscdb auth secrets..." -ForegroundColor Cyan
$secretsReport = Invoke-GhostCore @("delete-secrets", $sqlitePath)
$secretsOk = $false
if ($null -eq $secretsReport -or $null -eq $secretsReport.survivors) {
    Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "secrets-delete" -Before "present" -After "core-invoke-failed" -Ok $false
    Write-Host "    [FAILED] delete-secrets core invocation failed" -ForegroundColor Red
}
else {
    # survivors is a LIST (one COUNT per pattern/key): PS array -eq 0
    # FILTERS elements instead of answering "all zero" - test explicitly.
    $nonZeroSurvivors = @($secretsReport.survivors | Where-Object { $_ -ne 0 })
    $secretsOk = ($nonZeroSurvivors.Count -eq 0)
    $deletedCount = @($secretsReport.deleted).Count
    if ($secretsOk) {
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "secrets-delete" -Before "present" -After ("deleted " + $deletedCount) -Ok $true
        Write-Host "    [OK] secrets deleted: $deletedCount keys from $sqlitePath" -ForegroundColor Green
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "secrets-delete" -Before "present" -After ("survivors=" + $secretsReport.survivors) -Ok $false
        Write-Host "    [FAILED] secret survivors remain: $($secretsReport.survivors)" -ForegroundColor Red
    }
}
if ($secretsOk) { $passCount++ } else { $failCount++ }

# --- [5/15] stale state.vscdb.backup deletion (core: sweep-file) ---
Write-Host "`n[5/15] Deleting stale state.vscdb.backup..." -ForegroundColor Cyan
$staleBackup = Join-Path $root "User\globalStorage\state.vscdb.backup"
$staleReport = Invoke-GhostCore @("sweep-file", $staleBackup)
if ($null -ne $staleReport -and $staleReport.ok) {
    Add-AuditEntry -Audit ([ref]$audit) -File $staleBackup -Key "state.vscdb.backup" -Before $staleReport.before -After $staleReport.after -Ok $true
    $passCount++
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $staleBackup -Key "state.vscdb.backup" -Before "present" -After "delete-failed" -Ok $false
    Write-Host "    [FAILED] could not delete: $staleBackup" -ForegroundColor Red
    $failCount++
}

# --- [6/15] Preferences device_id_salt (core: salt-rotate; salt generated in
#     the core - lowercase hex, opaque random value) ---
Write-Host "`n[6/15] Updating Preferences (device_id_salt)..." -ForegroundColor Cyan
$saltReport = Invoke-GhostCore @("salt-rotate", (Join-Path $root "Preferences"), $backupRoot, "Preferences")
if ($null -ne $saltReport -and $saltReport.ok) {
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "Preferences") -Key "electron.media.device_id_salt" -Before $saltReport.before -After $saltReport.after -Ok $true
    if ($saltReport.backed_up_to) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath (Join-Path $root "Preferences") -BackupPath $saltReport.backed_up_to
    }
    Write-Host "    [OK] device_id_salt updated" -ForegroundColor Green
    $passCount++
}
elseif ($null -ne $saltReport -and $saltReport.skipped) {
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "Preferences") -Key "electron.media.device_id_salt" -Before "missing" -After "skipped" -Ok $true
    Write-Host "    [SKIP] Preferences not found" -ForegroundColor Yellow
    $passCount++
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "Preferences") -Key "electron.media.device_id_salt" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] device_id_salt verification failed" -ForegroundColor Red
    $failCount++
}

# --- [7/15] Local State os_crypt rotation (core: json-remove) ---
Write-Host "`n[7/15] Rotating os_crypt.encrypted_key..." -ForegroundColor Cyan
$osCryptPath = Join-Path $root "Local State"
$osCryptReport = Invoke-GhostCore @("json-remove", $osCryptPath, $backupRoot, "Local State",
    (_B64Payload @{ keys = @("os_crypt.encrypted_key") }))
if ($null -ne $osCryptReport -and $osCryptReport.ok) {
    $osBefore = $osCryptReport.before."os_crypt.encrypted_key"
    # Whole file absent -> core reports skipped=True with before={} - audit
    # the no-op as "skipped", never as "removed".
    $osAfter = if ($osCryptReport.skipped -or $osBefore -eq "missing") { "skipped" } else { "removed" }
    Add-AuditEntry -Audit ([ref]$audit) -File $osCryptPath -Key "os_crypt.encrypted_key" -Before $osBefore -After $osAfter -Ok $true
    if ($osCryptReport.backed_up_to) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $osCryptPath -BackupPath $osCryptReport.backed_up_to
    }
    Write-Host "    [OK] os_crypt.encrypted_key removed" -ForegroundColor Green
    $passCount++
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $osCryptPath -Key "os_crypt.encrypted_key" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] os_crypt.encrypted_key verification failed" -ForegroundColor Red
    $failCount++
}

# --- [8/15] Cookies + transport state (core: store-delete, delete mode) ---
Write-Host "`n[8/15] Clearing Cookies + transport state..." -ForegroundColor Cyan
$auditStart = $audit.Count
$cookiePaths = @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "Network\Cookies-journal"),
    (Join-Path $root "Network\Network Persistent State"),
    (Join-Path $root "Network\TransportSecurity"),
    (Join-Path $root "Network\NetworkDataMigrated")
)
foreach ($storePath in $cookiePaths) {
    $storeReport = Invoke-GhostCore @("store-delete", $storePath, $backupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storePath),
        "--action", "delete", "--root-path", $root)
    if ($null -ne $storeReport) {
        Add-AuditEntry -Audit ([ref]$audit) -File $storePath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
        if ($storeReport.ok -and $storeReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $storePath -BackupPath $storeReport.backed_up_to -Action "delete"
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $storePath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] Cookies + transport state cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] Cookies + transport state had failures" -ForegroundColor Red
    $failCount++
}

# --- [9/15] DIPS stores (core: store-delete, delete mode) ---
Write-Host "`n[9/15] Clearing DIPS stores..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($storePath in @((Join-Path $root "DIPS"), (Join-Path $root "DIPS-wal"))) {
    $storeReport = Invoke-GhostCore @("store-delete", $storePath, $backupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storePath),
        "--action", "delete", "--root-path", $root)
    if ($null -ne $storeReport) {
        Add-AuditEntry -Audit ([ref]$audit) -File $storePath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
        if ($storeReport.ok -and $storeReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $storePath -BackupPath $storeReport.backed_up_to -Action "delete"
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $storePath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] DIPS stores cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] DIPS stores had failures" -ForegroundColor Red
    $failCount++
}

# --- [10/15] SharedStorage + Trust Tokens (core: store-delete, delete mode) ---
Write-Host "`n[10/15] Clearing SharedStorage + Trust Tokens..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($storePath in @(
        (Join-Path $root "SharedStorage"),
        (Join-Path $root "SharedStorage-wal"),
        (Join-Path $root "Network\Trust Tokens"),
        (Join-Path $root "Network\Trust Tokens-journal"))) {
    $storeReport = Invoke-GhostCore @("store-delete", $storePath, $backupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storePath),
        "--action", "delete", "--root-path", $root)
    if ($null -ne $storeReport) {
        Add-AuditEntry -Audit ([ref]$audit) -File $storePath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
        if ($storeReport.ok -and $storeReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $storePath -BackupPath $storeReport.backed_up_to -Action "delete"
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $storePath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] SharedStorage + Trust Tokens cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] SharedStorage + Trust Tokens had failures" -ForegroundColor Red
    $failCount++
}

# --- [11/15] sentry tree (core: sweep-tree; scope_v3.json holds email + fingerprint) ---
Write-Host "`n[11/15] Clearing sentry tree..." -ForegroundColor Cyan
$auditStart = $audit.Count
$sentryPath = Join-Path $root "sentry"
if (Test-Path -LiteralPath $sentryPath) {
    $sentryReport = Invoke-GhostCore @("sweep-tree", $sentryPath, $backupRoot, "sentry")
    if ($null -ne $sentryReport) {
        $summary = "deleted={0} failed={1}" -f $sentryReport.deleted, $sentryReport.failed
        Add-AuditEntry -Audit ([ref]$audit) -File $sentryPath -Key "binary-store" -Before "present" -After $summary -Ok ($sentryReport.failed -eq 0)
        foreach ($failedPath in @($sentryReport.failed_paths)) {
            Add-AuditEntry -Audit ([ref]$audit) -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
        }
        if ($sentryReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $sentryPath -BackupPath $sentryReport.backed_up_to -Action "delete"
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $sentryPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $sentryPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $sentryPath
if ($status.Success) {
    Write-Host "[OK] sentry tree cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] sentry tree had failures" -ForegroundColor Red
    $failCount++
}

# --- [12/15] cache dirs + Session Storage (core: sweep-tree; chat stores preserved) ---
Write-Host "`n[12/15] Clearing cache directories + Session Storage..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($relative in @("Cache\Cache_Data", "Code Cache", "GPUCache", "blob_storage", "Service Worker", "Session Storage")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $sweepReport = Invoke-GhostCore @("sweep-tree", $fullPath, $backupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $fullPath))
        if ($null -ne $sweepReport) {
            $summary = "deleted={0} failed={1}" -f $sweepReport.deleted, $sweepReport.failed
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0)
            foreach ($failedPath in @($sweepReport.failed_paths)) {
                Add-AuditEntry -Audit ([ref]$audit) -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
            }
            if ($sweepReport.backed_up_to) {
                Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $fullPath -BackupPath $sweepReport.backed_up_to -Action "delete"
            }
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    }
}
# Preserve Local Storage\leveldb (persistent UI state, no server-side identity
# signal) and Backups\ (untitled/editor backups are user content).
foreach ($preservedRelative in @("Local Storage\leveldb", "Backups")) {
    $preservedPath = Join-Path $root $preservedRelative
    if (Test-Path -LiteralPath $preservedPath) {
        Write-Host "[INFO] Preserving $preservedRelative" -ForegroundColor Cyan
        Add-AuditEntry -Audit ([ref]$audit) -File $preservedPath -Key "chat-store" -Before "present" -After "preserved-for-chat" -Ok $true
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $preservedPath -Key "chat-store" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] cache directories cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] cache directories had failures" -ForegroundColor Red
    $failCount++
}

# --- [13/15] Crashpad + logs (core: sweep-tree; crash dumps embed device IDs) ---
Write-Host "`n[13/15] Clearing Crashpad + logs..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($relative in @("Crashpad", "logs")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $sweepReport = Invoke-GhostCore @("sweep-tree", $fullPath, $backupRoot, $relative)
        if ($null -ne $sweepReport) {
            $summary = "deleted={0} failed={1}" -f $sweepReport.deleted, $sweepReport.failed
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0)
            foreach ($failedPath in @($sweepReport.failed_paths)) {
                Add-AuditEntry -Audit ([ref]$audit) -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
            }
            if ($sweepReport.backed_up_to) {
                Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $fullPath -BackupPath $sweepReport.backed_up_to -Action "delete"
            }
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] Crashpad + logs cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] Crashpad + logs had failures" -ForegroundColor Red
    $failCount++
}

# --- [14/15] workspace UPSERT-only (core: sqlite-update per db; never delete
#     workspace files) ---
Write-Host "`n[14/15] Updating workspace state.vscdb files (UPSERT only)..." -ForegroundColor Cyan
$workspaceDbPaths = @()
if (Test-Path -LiteralPath $workspaceStorageRoot) {
    $workspaceDbPaths = Get-ChildItem -LiteralPath $workspaceStorageRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "state.vscdb" } |
        Where-Object { Test-Path -LiteralPath $_ }
}

if ($workspaceDbPaths.Count -eq 0) {
    Write-Host "[SKIP] no workspace state.vscdb files found" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $workspaceStorageRoot -Key "workspaceStorage" -Before "none" -After "skipped" -Ok $true
    $passCount++
}
else {
    $workspaceFailures = 0
    foreach ($workspaceDbPath in $workspaceDbPaths) {
        $wsLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $workspaceDbPath
        $null = Backup-ViaCore -Source $workspaceDbPath -BackupRoot $backupRoot -Label $wsLabel -Actions ([ref]$actions)
        $wsReport = Invoke-GhostCore @("sqlite-update", $workspaceDbPath, (_B64Payload @{ "storage.serviceMachineId" = $ids.devDeviceId }))
        # [OK] only when the core's verify-after re-read returned the exact
        # value we asked for (same gate as step [3]).
        if ($null -ne $wsReport -and $null -ne $wsReport.after -and ($wsReport.after."storage.serviceMachineId" -eq $ids.devDeviceId)) {
            Add-AuditEntry -Audit ([ref]$audit) -File $workspaceDbPath -Key "storage.serviceMachineId" -Before $wsReport.before."storage.serviceMachineId" -After $wsReport.after."storage.serviceMachineId" -Ok $true
            Write-Host "    [OK] workspace DB updated: $workspaceDbPath" -ForegroundColor Green
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $workspaceDbPath -Key "storage.serviceMachineId" -Before $null -After $ids.devDeviceId -Ok $false
            Write-Host "    [FAILED] workspace DB update: $workspaceDbPath" -ForegroundColor Red
            $workspaceFailures++
        }
    }
    # Stale workspace .backup sidecars retain the OLD device ID but stay on
    # disk per the preservation policy.
    $workspaceBackupCount = @(Get-ChildItem -LiteralPath $workspaceStorageRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "state.vscdb.backup" } |
        Where-Object { Test-Path -LiteralPath $_ }).Count
    Add-AuditEntry -Audit ([ref]$audit) -File $workspaceStorageRoot -Key "workspace-backups-preserved" -Before ("present=" + $workspaceBackupCount) -After "preserved-per-policy" -Ok $true

    if ($workspaceFailures -eq 0) {
        Write-Host "[OK] workspace UPSERT complete (no workspace files deleted)" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] workspace UPSERT had failures" -ForegroundColor Red
        $failCount++
    }
}

# --- [15/15] Old ID_Backups purge + watchdog re-verify (PS: pure file ops) ---
Write-Host "`n[15/15] Purging old ID_Backups + watchdog re-verify..." -ForegroundColor Cyan
$purgeOk = Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit)
$watchdogCoreFiles = @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "DIPS"),
    (Join-Path $root "SharedStorage")
)
# Step [15] passes only when BOTH sub-checks verified: every old backup dir
# actually deleted AND every recreated identity file actually re-deleted -
# never an unconditional pass.
$watchdogOk = Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit ([ref]$audit)
if ($purgeOk -and $watchdogOk) {
    $passCount++
}
else {
    $failCount++
}

# --- Audit + Restore ---
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
Write-AuditLog -Audit $audit -Path $auditPath
$restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App $app -Actions $actions

$finalJsonOk = $false
if (Test-Path -LiteralPath $storagePath) {
    $finalJsonOk = Confirm-JsonValues -Path $storagePath -Expected $storageUpdates
}
$finalSqliteAuditEntries = @($audit | Where-Object { $_.file -eq $sqlitePath -and $_.key -eq "storage.serviceMachineId" })
$finalSqliteOk = ($finalSqliteAuditEntries.Count -gt 0) -and ($finalSqliteAuditEntries[-1].ok -eq $true)

if ($finalJsonOk) {
    Write-Host "[OK] final storage.json probe passed" -ForegroundColor Green
}
else {
    Write-Host "[FAILED] final storage.json probe failed" -ForegroundColor Red
    $failCount++
}

if ($finalSqliteOk) {
    Write-Host "[OK] final state.vscdb probe passed" -ForegroundColor Green
}
else {
    Write-Host "[FAILED] final state.vscdb probe failed" -ForegroundColor Red
    $failCount++
}

if (-not (Test-Path -LiteralPath $restoreScriptPath) -or ((Get-Item -LiteralPath $restoreScriptPath).Length -le 0)) {
    Write-Host "[FAILED] restore script missing or empty" -ForegroundColor Red
    $failCount++
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Pass: $passCount" -ForegroundColor Green
Write-Host "Fail: $failCount" -ForegroundColor Red
Write-Host "Audit log: $auditPath" -ForegroundColor Gray
Write-Host "Restore script: $restoreScriptPath" -ForegroundColor Gray
Write-Host "NOTE: workspace .backup sidecars were preserved per policy (they still embed the old device ID)." -ForegroundColor Yellow
Write-Host "NOTE: change_device_id.ps1 remains the separate, optional system-level step." -ForegroundColor Yellow

[System.IO.File]::WriteAllText("$env:TEMP\cursor_v0.3_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "Cursor reset v0.3 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "Cursor reset v0.3 completed successfully."
