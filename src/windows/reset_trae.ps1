#Requires -Version 5.1
# Trae Identity Reset v0.3 — thin manifest over the Python core
#
# Phase 3 continuation per docs/PYTHON_HYBRID_ROADMAP.md (cursor v0.3 pilot,
# devin v0.4; this is the third migration). The 16 steps and their order,
# audit keys, restore-script actions and summary are IDENTICAL to v0.2
# (archived at archive/reset_trae_windows-v0.2.ps1); every store mutation now
# runs through src\python\ghost_cli.py (base64 payload in, JSON report out)
# via ONE invocation helper. What was deleted from v0.2: the inline temp-.py
# heredoc (step 8 now uses the shared scrub-rows subcommand - the exact
# de-duplication the repo conventions mandate), and ~450 lines of one-off
# local mutation helpers replaced by the tested ghost.filesweep /
# ghost.winstore / ghost.backup / ghost.sqlite_keys modules.
#
#   v0.2 helper                       -> v0.3 core verb
#   Set-VerifiedMachineIdFile         -> machineid-file
#   Update-TraeStorageJson            -> json-remove (iCube prefixes) +
#                                        json-patch (telemetry + aha flag)
#   Clear-TraeAiAgentIdentity heredoc -> scrub-rows (key NAMES only; values
#                                        i.e. chat content never inspected)
#   Set-DeviceIdSalt                  -> salt-rotate
#   Remove-OsCryptEncryptedKey        -> json-remove
#   Clear-TreeFilesIndividually       -> sweep-tree
#   Remove-VerifiedFileNoBackup       -> sweep-file
#   Clear-BinaryIdentityStore         -> store-delete --action delete
#   Invoke-WorkspaceSqliteUpdate      -> backup + sqlite-update per DB
#
# BUG FIXED from v0.2: $traeDoneMarker was NEVER ASSIGNED there (8 bare
# references: the self-elevation relay, the trap and every final write), so
# every elevated run crashed at the final marker write and non-admin
# self-elevation broke before it could relaunch. v0.3 uses the fixed
# cursor-style marker path (like reset_cursor v0.3).
#
# PRESERVATION (chat history + workspaces are never wiped):
#   - ModularData\ai-agent: identity-row scrub only (see above).
#   - Local Storage\leveldb (UI state) + Backups\: preserved.
#   - User\workspaceStorage\**: serviceMachineId UPSERT only; tables/files and
#     stale .backup sidecars are never deleted.
#
# SCOPE ISOLATION: no MAC / hostname / registry-source steps here. Those belong
# strictly to change_device_id.ps1.
#
# PS 5.1 COMPAT: no [CmdletBinding()], no ternary, no $Input variable,
# RandomNumberGenerator via .GetBytes() only.
#
# Usage (Windows 10, PowerShell 5.1 or 7 -- just double-click or run):
#   powershell -ExecutionPolicy Bypass -File reset_trae.ps1
# Prerequisite: close Trae first (the script also force-kills it).
# Requirement: Python (python or python3) for EVERY store mutation now
# (v0.2 needed it only for the SQLite steps). The functional probe in
# identity_utils.ps1 detects it; without Python the run fails fast.
# Notes: the ckg_server 19-digit device_id is still generated in PowerShell
# (value generation stays PS, like New-IdentitySet); the Preferences salt is
# generated in the core (32 lowercase hex - same shape v0.2 produced).

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
$traeIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $traeIsAdmin) {
    $traeScript = $MyInvocation.MyCommand.Path
    # -File passes only declared switches; a redirect operator after -File is
    # just swallowed as an undeclared argument. The *_done.txt marker file
    # (not a log) is the persisted result channel - the elevated console shows
    # the full live output while the run progresses.
    $traeArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$traeScript`""
    # A stale done-marker from a PREVIOUS run must never be shown as this
    # run's result: the elevated child writes the marker only at the end of
    # its FULL main path, so delete it before launching (an early child exit
    # then surfaces as no result, never as the old Pass/Fail lines).
    Remove-Item -LiteralPath "$env:TEMP\trae_v0.3_done.txt" -Force -ErrorAction SilentlyContinue
    # -PassThru + .ExitCode: relay the elevated child's exit code (the bug
    # sweep's remaining half of the self-elevation finding - a bare -Wait
    # always exited 0, so a failing reset looked green to callers that check
    # $LASTEXITCODE). The child exits 1 when failCount > 0.
    $traeChild = Start-Process powershell -Verb RunAs -ArgumentList $traeArgs -WindowStyle Normal -Wait -PassThru
    if (Test-Path -LiteralPath "$env:TEMP\trae_v0.3_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\trae_v0.3_done.txt" -Encoding UTF8
    }
    $traeChildCode = $traeChild.ExitCode
    if ($null -eq $traeChildCode) { $traeChildCode = 1 }
    exit $traeChildCode
}

Write-GhostBanner -Target "Trae Identity Reset" -Version "0.3"

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
        Write-Host "[FAILED] no functional Python 3 found - every Trae reset step needs it." -ForegroundColor Red
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

# Generate a fresh 19-digit numeric device_id matching the format Trae's
# ckg_server stores (e.g. "7647529847245473300"). First digit is non-zero.
function New-RandomDeviceId19 {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 9
        $rng.GetBytes($bytes)
        $firstDigit = ($bytes[0] % 9) + 1
        $chars = @([string]$firstDigit)
        for ($i = 1; $i -lt 19; $i++) {
            $chars += [string]($bytes[$i % 9] % 10)
        }
        return ($chars -join '')
    }
    finally {
        if ($rng) { $rng.Dispose() }
    }
}

# Identity-row scrub for ModularData\ai-agent (chat DB). POLICY: the tree is
# never renamed/deleted (v0.1 wiped chat). Instead, back it up, then in every
# *.db delete only rows whose KEY column name-matches the identity patterns
# (core: scrub-rows). Matching is on key NAMES only -- values (chat content)
# are never inspected or modified; tables without a key-like column are
# skipped with an audit entry.
function Clear-TraeAiAgentIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$AiAgentPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $AiAgentPath)) {
        Add-AuditEntry -Audit $Audit -File $AiAgentPath -Key "ai-agent-scrub" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] ai-agent not present: $AiAgentPath" -ForegroundColor Yellow
        return $true
    }

    $null = Backup-ViaCore -Source $AiAgentPath -BackupRoot $BackupRoot -Label $BackupLabel -Actions $Actions

    $dbFiles = @(Get-ChildItem -LiteralPath $AiAgentPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq ".db" })
    if ($dbFiles.Count -eq 0) {
        Add-AuditEntry -Audit $Audit -File $AiAgentPath -Key "ai-agent-scrub" -Before "present" -After "no-db-files-preserved" -Ok $true
        Write-Host "    [INFO] ai-agent has no .db files; tree preserved" -ForegroundColor Cyan
        return $true
    }

    $allOk = $true
    foreach ($dbFile in $dbFiles) {
        $scrubReport = Invoke-GhostCore @("scrub-rows", $dbFile.FullName)
        if ($null -eq $scrubReport -or $null -eq $scrubReport.survivors) {
            Add-AuditEntry -Audit $Audit -File $dbFile.FullName -Key "ai-agent-scrub" -Before "present" -After "core-invoke-failed" -Ok $false
            Write-Host "    [FAILED] ai-agent scrub core invocation failed: $($dbFile.FullName)" -ForegroundColor Red
            $allOk = $false
            continue
        }
        $skippedNames = @($scrubReport.skipped_tables) -join ","
        $scrubOk = ([int]$scrubReport.survivors -eq 0)
        $scrubAfter = ("identity-rows-deleted {0}; survivors={1}; skipped-tables={2}" -f $scrubReport.deleted, $scrubReport.survivors, $skippedNames)
        Add-AuditEntry -Audit $Audit -File $dbFile.FullName -Key "ai-agent-scrub" -Before "present" -After $scrubAfter -Ok $scrubOk
        if ($scrubOk) {
            Write-Host "    [OK] ai-agent scrub: $($scrubReport.deleted) identity rows from $($dbFile.FullName) (survivors=0)" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] ai-agent scrub: $($scrubReport.survivors) identity rows survived in $($dbFile.FullName)" -ForegroundColor Red
            $allOk = $false
        }
    }
    return $allOk
}

# Aggressive tree-kill for Trae + Broker + extension helpers.
# Requires 2 consecutive clean checks; hard-fails the run when unkillable.
function Stop-TraeProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all Trae + extension-helper processes (aggressive tree-kill)..." -ForegroundColor Cyan

    $processesToKill = @(
        "Trae",
        "Trae Broker",
        "Trae Helper",
        "Trae Helper (GPU)",
        "Trae Helper (Renderer)",
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

        $traeRemaining = @(Get-Process -Name "Trae*" -ErrorAction SilentlyContinue)
        $helperRemaining = 0
        foreach ($helperName in @("kilo", "cline", "cline-host", "roo", "blackbox")) {
            $helperRemaining += @(Get-Process -Name $helperName -ErrorAction SilentlyContinue).Count
        }
        $count = $traeRemaining.Count + $helperRemaining
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all Trae + extension-helper processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($p in @(Get-Process -Name "Trae*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    Trae PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($helperName in @("kilo", "cline", "cline-host", "roo", "blackbox")) {
        foreach ($p in @(Get-Process -Name $helperName -ErrorAction SilentlyContinue)) {
            Write-Host ("    $helperName PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
        }
    }
    return $false
}

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

    $allOk = $true
    foreach ($path in $recreated) {
        Write-Host "    [WARN] watchdog recreated file, re-deleting: $path" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        $afterValue = if (Test-Path -LiteralPath $path) { "re-delete-failed" } else { "re-deleted" }
        if ($afterValue -eq "re-delete-failed") {
            Write-Host "    [FAILED] could not re-delete (file locked?): $path" -ForegroundColor Red
            $allOk = $false
        }
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After $afterValue -Ok ($afterValue -eq "re-deleted")
    }
    return $allOk
}

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
        return
    }

    $allBackups = @(Get-ChildItem -LiteralPath $IdBackupsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $toDelete = @($allBackups | Where-Object { $_.Name -ne $currentTimestamp })

    if ($toDelete.Count -eq 0) {
        Add-AuditEntry -Audit $Audit -File $IdBackupsRoot -Key "id-backups-purge" -Before "none" -After "none" -Ok $true
        Write-Host "    no older ID_Backups to purge (only current run present)" -ForegroundColor DarkGray
        return
    }

    foreach ($dir in $toDelete) {
        Write-Host "    [PURGE] $($dir.Name) (preserved old fingerprint; deleting)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dir.FullName) {
            Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "delete-failed" -Ok $false
            Write-Host "    [FAILED] old backup survived the purge: $($dir.FullName)" -ForegroundColor Red
        }
        else {
            Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "deleted" -Ok $true
        }
    }
}

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

# === Main =====================================================================

Assert-Administrator

$app = "Trae"
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
    Write-Host "Trae installation not found at: $root" -ForegroundColor Red
    exit 1
}

# The core must be present and a functional Python 3 with it - fail fast
# BEFORE touching anything (v0.2 could run JSON-only steps without Python;
# v0.3 cannot run any step without it).
if ((-not (Get-GhostPythonCli)) -or (-not (Get-PythonCommandInfo))) {
    Write-Host "[FAILED] GHOST Python core (src\python\ghost_cli.py) missing or no functional Python 3 found - every Trae reset step needs it (winget install Python.Python.3.12)." -ForegroundColor Red
    exit 1
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Trae Identity Reset v0.3 ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: chat history + workspaces preserved; no MAC/hostname/registry steps" -ForegroundColor Gray

# Pre-step: aggressive tree-kill. Hard-fails the run if unkillable.
if (-not (Stop-TraeProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$telemetryUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}

# --- [1/16] machineid (core: machineid-file) ---
Write-Host "`n[1/16] Updating machineid..." -ForegroundColor Cyan
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

# --- [2/16] storage.json (telemetry + iCubeAuthInfo://* removal + aha flag) ---
Write-Host "`n[2/16] Updating storage.json (telemetry + iCubeAuthInfo removal + aha flag)..." -ForegroundColor Cyan
$storageLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storagePath
$storageStepOk = $false
$icubeBeforeCount = 0
$icubeOk = $false
if (-not (Test-Path -LiteralPath $storagePath)) {
    foreach ($key in $telemetryUpdates.Keys) {
        Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key $key -Before $null -After $telemetryUpdates[$key] -Ok $false
    }
    Write-Host "[FAILED] storage.json not found: $storagePath" -ForegroundColor Red
}
else {
    # Core order: json-remove FIRST (its internal backup is the pre-run
    # restore point) then json-patch, which takes no backup of its own. The
    # iCubeAuthInfo keys embed URLs in their NAMES ("iCubeAuthInfo://
    # auth.trae.ai?token=...") so they are addressed by top-level PREFIX,
    # not by dotted-path walking.
    $icubeReport = Invoke-GhostCore @("json-remove", $storagePath, $backupRoot, $storageLabel,
        (_B64Payload @{ keys = @(); prefixes = @("iCubeAuthInfo://") }))
    if ($null -ne $icubeReport -and $icubeReport.ok) {
        foreach ($prop in $icubeReport.removed_prefixes.PSObject.Properties) {
            $icubeBeforeCount += [int]$prop.Value
        }
        # Removing an already-absent family is a verified no-op (count=0),
        # never a failure.
        $icubeOk = $true
        if ($icubeReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $storagePath -BackupPath $icubeReport.backed_up_to
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key "iCubeAuthInfo.*" -Before "present" -After "core-invoke-failed" -Ok $false
        Write-Host "    [FAILED] iCubeAuthInfo removal core invocation failed" -ForegroundColor Red
    }

    if ($icubeOk) {
        $patchUpdates = $telemetryUpdates.Clone()
        $patchUpdates["has_device_id_updated_to_aha"] = $false
        $patchReport = Invoke-GhostCore @("json-patch", $storagePath, (_B64Payload $patchUpdates))
        if ($null -ne $patchReport -and $patchReport.ok) {
            foreach ($key in $telemetryUpdates.Keys) {
                Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key $key -Before $patchReport.before.$key -After $patchReport.after.$key -Ok $true
            }
            $ahaAfter = $patchReport.after.'has_device_id_updated_to_aha'
            Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key "has_device_id_updated_to_aha" -Before $patchReport.before.'has_device_id_updated_to_aha' -After $ahaAfter -Ok ($ahaAfter -eq $false)
        }
        else {
            foreach ($key in $telemetryUpdates.Keys) {
                Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key $key -Before $null -After $telemetryUpdates[$key] -Ok $false
            }
            Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key "has_device_id_updated_to_aha" -Before $null -After "verify-failed" -Ok $false
            Write-Host "    [FAILED] telemetry patch verification failed" -ForegroundColor Red
        }
    }

    Add-AuditEntry -Audit ([ref]$audit) -File $storagePath -Key "iCubeAuthInfo.*" -Before ("count=" + $icubeBeforeCount) -After "count=0" -Ok $icubeOk

    if ($icubeOk -and ($null -ne $patchReport) -and $patchReport.ok) {
        $storageStepOk = $true
    }
}
if ($storageStepOk) {
    Write-Host "[OK] storage.json verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] storage.json verification failed" -ForegroundColor Red
    $failCount++
}

# --- [3/16] state.vscdb (serviceMachineId + aha flag; core: sqlite-update) ---
Write-Host "`n[3/16] Updating global state.vscdb (serviceMachineId + aha flag)..." -ForegroundColor Cyan
$stateSqliteUpdates = @{
    "storage.serviceMachineId"     = $ids.devDeviceId
    "has_device_id_updated_to_aha" = "false"
}
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
    $sqliteReport = Invoke-GhostCore @("sqlite-update", $sqlitePath, (_B64Payload $stateSqliteUpdates))
    # [OK] only when the core's verify-after re-read returned the exact values
    # we asked for - a non-null report alone is not verification.
    $sqliteOk = $false
    if ($null -ne $sqliteReport -and $null -ne $sqliteReport.after) {
        $sqliteOk = (($sqliteReport.after."storage.serviceMachineId" -eq $ids.devDeviceId) -and
            ($sqliteReport.after."has_device_id_updated_to_aha" -eq "false"))
    }
    if ($sqliteOk) {
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "storage.serviceMachineId" -Before $sqliteReport.before."storage.serviceMachineId" -After $sqliteReport.after."storage.serviceMachineId" -Ok $true
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "has_device_id_updated_to_aha" -Before $sqliteReport.before."has_device_id_updated_to_aha" -After $sqliteReport.after."has_device_id_updated_to_aha" -Ok $true
        Write-Host "[OK] global state.vscdb verified" -ForegroundColor Green
        $passCount++
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "storage.serviceMachineId" -Before $null -After $ids.devDeviceId -Ok $false
        Add-AuditEntry -Audit ([ref]$audit) -File $sqlitePath -Key "has_device_id_updated_to_aha" -Before $null -After "verify-failed" -Ok $false
        Write-Host "[FAILED] global state.vscdb verification failed" -ForegroundColor Red
        $failCount++
    }
}

# --- [4/16] stale state.vscdb.backup deletion (core: sweep-file) ---
Write-Host "`n[4/16] Deleting stale state.vscdb.backup..." -ForegroundColor Cyan
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

# --- [5/16] aha tree (delete; v0.1 renamed, leaving encrypted device blobs) ---
Write-Host "`n[5/16] Clearing aha tree (encrypted TinyStorage device blobs)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$ahaPath = Join-Path $root "aha"
if (Test-Path -LiteralPath $ahaPath) {
    $sweepReport = Invoke-GhostCore @("sweep-tree", $ahaPath, $backupRoot, "aha")
    if ($null -ne $sweepReport) {
        $summary = "deleted={0} failed={1} remaining={2}" -f $sweepReport.deleted, $sweepReport.failed, $sweepReport.remaining
        Add-AuditEntry -Audit ([ref]$audit) -File $ahaPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0 -and $sweepReport.remaining -eq 0)
        foreach ($failedPath in @($sweepReport.failed_paths)) {
            Add-AuditEntry -Audit ([ref]$audit) -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
        }
        if ($sweepReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $ahaPath -BackupPath $sweepReport.backed_up_to -Action "delete"
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $ahaPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $ahaPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $ahaPath
if ($status.Success) {
    Write-Host "[OK] aha tree cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] aha tree had failures" -ForegroundColor Red
    $failCount++
}

# --- [6/16] ckg_server local_env.json (device_id + host_map) ---
Write-Host "`n[6/16] Updating ModularData\ckg_server\local_env.json (device_id + host_map)..." -ForegroundColor Cyan
$localEnvPath = Join-Path $root "ModularData\ckg_server\local_env.json"
$localEnvOk = $false
if (-not (Test-Path -LiteralPath $localEnvPath)) {
    Add-AuditEntry -Audit ([ref]$audit) -File $localEnvPath -Key "device_id" -Before "missing" -After "skipped" -Ok $true
    Write-Host "    [SKIP] local_env.json not present: $localEnvPath" -ForegroundColor Yellow
    $localEnvOk = $true
}
else {
    # Core order: json-set FIRST (host_map.default; its internal backup is
    # the pre-run restore point) then json-patch, which takes no backup of
    # its own. json-set creates the host_map object when missing (the v0.2
    # Add-Member behavior); json-patch creates device_id when missing.
    $localEnvLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $localEnvPath
    $hostReport = Invoke-GhostCore @("json-set", $localEnvPath, $backupRoot, $localEnvLabel,
        (_B64Payload @{ key = "host_map.default"; value = "" }))
    $hostOk = $false
    $hostBefore = $null
    $hostAfter = $null
    if ($null -ne $hostReport -and $hostReport.ok) {
        $hostBefore = $hostReport.before
        $hostAfter = $hostReport.after
        $hostOk = $true
        if ($hostReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $localEnvPath -BackupPath $hostReport.backed_up_to
        }
    }
    else {
        Write-Host "    [FAILED] host_map.default core invocation failed" -ForegroundColor Red
    }

    $deviceReport = $null
    if ($hostOk) {
        $deviceReport = Invoke-GhostCore @("json-patch", $localEnvPath, (_B64Payload @{ device_id = (New-RandomDeviceId19) }))
        if ($null -ne $deviceReport -and $deviceReport.ok) {
            if ($deviceReport.backed_up_to) {
                Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $localEnvPath -BackupPath $deviceReport.backed_up_to
            }
        }
    }
    $deviceOk = ($null -ne $deviceReport -and $deviceReport.ok)

    Add-AuditEntry -Audit ([ref]$audit) -File $localEnvPath -Key "device_id" -Before $deviceReport.before.device_id -After $deviceReport.after.device_id -Ok $deviceOk
    Add-AuditEntry -Audit ([ref]$audit) -File $localEnvPath -Key "host_map.default" -Before $hostBefore -After $hostAfter -Ok $hostOk
    $localEnvOk = ($deviceOk -and $hostOk)
    if ($localEnvOk) {
        Write-Host "    [OK] local_env.json verified" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] local_env.json verification failed" -ForegroundColor Red
    }
}
if ($localEnvOk) {
    $passCount++
}
else {
    $failCount++
}

# --- [7/16] env_codekg.db (delete; v0.1 renamed) ---
Write-Host "`n[7/16] Clearing ckg_server\env_codekg.db..." -ForegroundColor Cyan
$auditStart = $audit.Count
$envCodekgPath = Join-Path $root "ModularData\ckg_server\env_codekg.db"
$storeReport = Invoke-GhostCore @("store-delete", $envCodekgPath, $backupRoot,
    (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $envCodekgPath),
    "--action", "delete", "--root-path", $root)
if ($null -ne $storeReport) {
    if ($storeReport.skipped) {
        Write-Host "    [SKIP] env_codekg.db not present" -ForegroundColor Yellow
    }
    Add-AuditEntry -Audit ([ref]$audit) -File $envCodekgPath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
    if ($storeReport.ok -and $storeReport.backed_up_to) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $envCodekgPath -BackupPath $storeReport.backed_up_to -Action "delete"
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $envCodekgPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $envCodekgPath
if ($status.Success) {
    Write-Host "[OK] env_codekg.db cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] env_codekg.db had failures" -ForegroundColor Red
    $failCount++
}

# --- [8/16] ai-agent identity scrub (PRESERVE chat -- policy change from v0.1) ---
Write-Host "`n[8/16] Scrubbing ModularData\ai-agent identity rows (chat preserved)..." -ForegroundColor Cyan
$aiAgentPath = Join-Path $root "ModularData\ai-agent"
if (Clear-TraeAiAgentIdentity -AiAgentPath $aiAgentPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $aiAgentPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [9/16] Preferences salt + Local State os_crypt ---
Write-Host "`n[9/16] Updating Preferences/Local State (salt + os_crypt)..." -ForegroundColor Cyan
$stepFailed = $false

# [9a] device_id_salt (core: salt-rotate; salt generated in the core).
$prefPath = Join-Path $root "Preferences"
$saltReport = Invoke-GhostCore @("salt-rotate", $prefPath, $backupRoot, "Preferences")
if ($null -ne $saltReport -and $saltReport.ok) {
    Add-AuditEntry -Audit ([ref]$audit) -File $prefPath -Key "electron.media.device_id_salt" -Before $saltReport.before -After $saltReport.after -Ok $true
    if ($saltReport.backed_up_to) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $prefPath -BackupPath $saltReport.backed_up_to
    }
    Write-Host "    [OK] device_id_salt updated" -ForegroundColor Green
}
elseif ($null -ne $saltReport -and $saltReport.skipped) {
    Add-AuditEntry -Audit ([ref]$audit) -File $prefPath -Key "electron.media.device_id_salt" -Before "missing" -After "skipped" -Ok $true
    Write-Host "    [SKIP] Preferences not found" -ForegroundColor Yellow
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $prefPath -Key "electron.media.device_id_salt" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] device_id_salt verification failed" -ForegroundColor Red
    $stepFailed = $true
}

# [9b] os_crypt.encrypted_key removal (core: json-remove).
$localStatePath = Join-Path $root "Local State"
$osCryptReport = Invoke-GhostCore @("json-remove", $localStatePath, $backupRoot, "Local State",
    (_B64Payload @{ keys = @("os_crypt.encrypted_key") }))
if ($null -ne $osCryptReport -and $osCryptReport.ok) {
    $osBefore = $osCryptReport.before."os_crypt.encrypted_key"
    # Whole file absent -> core reports skipped=True - audit the no-op as
    # "skipped", never as "removed" (the v0.2 SKIP contract).
    $osAfter = if ($osCryptReport.skipped -or $osBefore -eq "missing") { "skipped" } else { "removed" }
    Add-AuditEntry -Audit ([ref]$audit) -File $localStatePath -Key "os_crypt.encrypted_key" -Before $osBefore -After $osAfter -Ok $true
    if ($osCryptReport.backed_up_to) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $localStatePath -BackupPath $osCryptReport.backed_up_to
    }
    Write-Host "    [OK] os_crypt.encrypted_key removed" -ForegroundColor Green
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $localStatePath -Key "os_crypt.encrypted_key" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] os_crypt.encrypted_key verification failed" -ForegroundColor Red
    $stepFailed = $true
}

if ($stepFailed) {
    Write-Host "[FAILED] Preferences/Local State step had failures" -ForegroundColor Red
    $failCount++
}
else {
    $passCount++
}

# --- [10/16] Cookies + transport state (core: store-delete, delete mode) ---
Write-Host "`n[10/16] Clearing Cookies + transport state..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($storePath in @(
        (Join-Path $root "Network\Cookies"),
        (Join-Path $root "Network\Cookies-journal"),
        (Join-Path $root "Network\Network Persistent State"),
        (Join-Path $root "Network\TransportSecurity"))) {
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

# --- [11/16] DIPS stores (core: store-delete, delete mode) ---
Write-Host "`n[11/16] Clearing DIPS stores..." -ForegroundColor Cyan
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

# --- [12/16] SharedStorage + Trust Tokens (core: store-delete, delete mode) ---
Write-Host "`n[12/16] Clearing SharedStorage + Trust Tokens..." -ForegroundColor Cyan
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

# --- [13/16] trae-webview partition + caches + Session Storage (core: sweep-tree;
#     chat stores preserved) ---
Write-Host "`n[13/16] Clearing trae-webview partition + caches..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($relative in @("Partitions\trae-webview", "Cache\Cache_Data", "Code Cache", "GPUCache", "blob_storage", "Service Worker", "Session Storage", "WebStorage", "Shared Dictionary")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $sweepReport = Invoke-GhostCore @("sweep-tree", $fullPath, $backupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $fullPath))
        if ($null -ne $sweepReport) {
            $summary = "deleted={0} failed={1} remaining={2}" -f $sweepReport.deleted, $sweepReport.failed, $sweepReport.remaining
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0 -and $sweepReport.remaining -eq 0)
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
    Write-Host "[OK] trae-webview partition + caches cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] trae-webview partition + caches had failures" -ForegroundColor Red
    $failCount++
}

# --- [14/16] Crashpad + logs (core: sweep-tree; crash dumps embed device IDs) ---
Write-Host "`n[14/16] Clearing Crashpad + logs..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($relative in @("Crashpad", "logs")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $sweepReport = Invoke-GhostCore @("sweep-tree", $fullPath, $backupRoot, $relative)
        if ($null -ne $sweepReport) {
            $summary = "deleted={0} failed={1} remaining={2}" -f $sweepReport.deleted, $sweepReport.failed, $sweepReport.remaining
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0 -and $sweepReport.remaining -eq 0)
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

# --- [15/16] workspace UPSERT-only (core: sqlite-update per db; never delete
#     workspace files) ---
Write-Host "`n[15/16] Updating workspace state.vscdb files (UPSERT only)..." -ForegroundColor Cyan
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

# --- [16/16] Old ID_Backups purge + watchdog re-verify (PS: pure file ops) ---
Write-Host "`n[16/16] Purging old ID_Backups + watchdog re-verify..." -ForegroundColor Cyan
$auditStart = $audit.Count
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit)
$watchdogCoreFiles = @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "DIPS"),
    (Join-Path $root "SharedStorage"),
    (Join-Path $root "aha"),
    (Join-Path $root "ModularData\ckg_server\env_codekg.db"),
    (Join-Path $root "User\globalStorage\state.vscdb.backup")
)
$watchdogOk = Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit ([ref]$audit)
$purgeFailures = @($audit | Select-Object -Skip $auditStart | Where-Object { ($_.key -eq "id-backups-purge") -and (-not $_.ok) }).Count
if ($watchdogOk -and ($purgeFailures -eq 0)) {
    Write-Host "[OK] purge verified + no watchdog recreation" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] purge or watchdog re-verify had failures" -ForegroundColor Red
    $failCount++
}

# --- Audit + Restore ---
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
Write-AuditLog -Audit $audit -Path $auditPath
$restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App $app -Actions $actions

$finalJsonOk = $false
if (Test-Path -LiteralPath $storagePath) {
    $finalJsonOk = Confirm-JsonValues -Path $storagePath -Expected $telemetryUpdates
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
Write-Host "NOTE: ai-agent chat DB was scrubbed for identity rows only (chat preserved)." -ForegroundColor Gray
Write-Host "NOTE: workspace .backup sidecars were preserved per policy (they still embed the old device ID)." -ForegroundColor Yellow
Write-Host "NOTE: change_device_id.ps1 remains the separate, optional system-level step." -ForegroundColor Yellow

[System.IO.File]::WriteAllText("$env:TEMP\trae_v0.3_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "Trae reset v0.3 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "Trae reset v0.3 completed successfully."
