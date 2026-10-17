#Requires -Version 5.1
# Windsurf/Devin Identity Reset v0.4 — thin manifest over the Python core
# (Windsurf rebranded to Devin Desktop on 2026-06-02 -- same IDE, over-the-air)
#
# Phase 3 continuation per docs/PYTHON_HYBRID_ROADMAP.md: the 17 steps (14
# per data root + 3 global), their order, audit keys, restore-script actions
# and summary are IDENTICAL to v0.3 (archived locally at
# archive/reset_devin_windows-v0.3.ps1); every store mutation now runs
# through src\python\ghost_cli.py via ONE invocation helper. What was
# deleted from v0.3: the last inline temp-.py heredoc in the repo
# (Clear-WindsurfSecrets -> the generalized delete-secrets subcommand with
# ESCAPE'd LIKE patterns), and the one-off mutation helpers replaced by the
# tested ghost.filesweep / ghost.winstore / ghost.backup modules.
#
# Multi-root: %APPDATA%\Devin and %APPDATA%\Windsurf are auto-detected and
# the full per-root sequence runs against EACH in a single pass; each root
# gets its own ID_Backups\<ts> (self-contained restore). The primary root's
# backup dir holds the combined audit + restore script.
#
# PRESERVATION (chat history + workspaces are never wiped):
#   - chat.ChatSessionStore.index + all Cascade/chat keys: never touched.
#   - Local Storage\leveldb (UI state) + Backups\ (editor backups): preserved.
#   - User\workspaceStorage\**: serviceMachineId UPSERT only; tables/files and
#     stale .backup sidecars are never deleted.
#   - Third-party secrets (mcp_token_github, other extensions' secret://
#     entries, github-authentication): never touched.
#   - .devin\.windsurf extensions/plans/worktrees + mcp_config.json: untouched.
#   - WebStorage + IndexedDB deliberately NOT touched (possible chat data).
#   - %USERPROFILE%\.devin-shared, %LOCALAPPDATA%\devin (CLI + is_zdr),
#     %LOCALAPPDATA%\Programs\<App>: never touched.
#
# SCOPE ISOLATION: no MAC / hostname / registry-source steps here. Those belong
# strictly to change_device_id.ps1.
#
# PS 5.1 COMPAT: no [CmdletBinding()], no ternary, no $Input variable,
# RandomNumberGenerator via .GetBytes() only.
#
# Usage (Windows 10, PowerShell 5.1 or 7 -- just double-click or run):
#   powershell -ExecutionPolicy Bypass -File reset_devin.ps1
# Prerequisite: close Windsurf / Devin Desktop first (the script force-kills both).
# Requirement: Python (python or python3) for EVERY store mutation now
# (v0.3 needed it only for SQLite writes) - the run fails fast without it.

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
$devinIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $devinIsAdmin) {
    $devinScript = $MyInvocation.MyCommand.Path
    # -File passes only declared switches; a redirect operator after -File is
    # just swallowed as an undeclared argument. The *_done.txt marker file
    # (not a log) is the persisted result channel - the elevated console shows
    # the full live output while the run progresses.
    $devinArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$devinScript`""
    Start-Process powershell -Verb RunAs -ArgumentList $devinArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\devin_v0.4_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\devin_v0.4_done.txt"
    }
    exit
}

Write-GhostBanner -Target "Windsurf/Devin Identity Reset" -Version "0.4"

# === Local helpers (orchestration only; mutations delegate to the core) =======

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

function Get-UserProfileBackupLabel {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    if ($TargetPath.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path "USERPROFILE" ($TargetPath.Substring($env:USERPROFILE.Length).TrimStart("\"))
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
        Write-Host "[FAILED] no functional Python 3 found - every Devin/Windsurf reset step needs it." -ForegroundColor Red
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
    # action. A locked/failed backup is reported but NOT fatal - the v0.3
    # contract verbatim (a file whose copy could not be read may still be
    # deletable, and the caller proceeds).
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    $report = Invoke-GhostCore @("backup", $Source, $BackupRoot, $Label)
    if ($null -eq $report) { return $false }
    if ($report.skipped) { return $false }
    if ($report.ok -and $report.destination) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Source -BackupPath $report.destination
        return $true
    }
    Write-Host "    [WARN] backup did not complete ($($report.error)) - proceeding" -ForegroundColor Yellow
    return $false
}

# Aggressive tree-kill for Devin + Windsurf + Codeium + extension helpers
# that hold file handles. Requires 2 consecutive clean checks.
function Stop-AppFamilyProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all Devin/Windsurf + extension-helper processes (aggressive tree-kill)..." -ForegroundColor Cyan

    $processesToKill = @(
        "Devin",
        "Devin Helper",
        "Devin Helper (GPU)",
        "Devin Helper (Renderer)",
        "Windsurf",
        "Windsurf Helper",
        "Windsurf Helper (GPU)",
        "Windsurf Helper (Renderer)",
        "codeium",
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

        $appRemaining = @(Get-Process -Name "Devin*", "Windsurf*", "codeium" -ErrorAction SilentlyContinue)
        $helperRemaining = 0
        foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
            $helperRemaining += @(Get-Process -Name $helperName -ErrorAction SilentlyContinue).Count
        }
        $count = $appRemaining.Count + $helperRemaining
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all Devin/Windsurf + extension-helper processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($p in @(Get-Process -Name "Devin*", "Windsurf*", "codeium" -ErrorAction SilentlyContinue)) {
        Write-Host ("    App PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    return $false
}

# Post-reset watchdog probe (v0.3 logic verbatim; pure PS file ops).
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
        return
    }

    foreach ($path in $recreated) {
        Write-Host "    [WARN] watchdog recreated file, re-deleting: $path" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        $afterValue = if (Test-Path -LiteralPath $path) { "re-delete-failed" } else { "re-deleted" }
        if ($afterValue -eq "re-delete-failed") {
            Write-Host "    [FAILED] could not re-delete (file locked?): $path" -ForegroundColor Red
        }
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After $afterValue -Ok ($afterValue -eq "re-deleted")
    }
}

# Purge every ID_Backups run EXCEPT the current one (v0.3 logic verbatim).
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
        Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "deleted" -Ok $true
    }
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
    $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($key in $Expected.Keys) {
        $actualValue = if ($null -ne $content.PSObject.Properties[$key]) { $content.$key } else { $null }
        if ($actualValue -ne $Expected[$key]) {
            return $false
        }
    }

    return $true
}

# === Per-root sequence (steps 1-14) ============================================

function Invoke-RootReset {
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][hashtable]$Ids,
        [Parameter(Mandatory = $true)][hashtable]$StorageUpdates,
        [Parameter(Mandatory = $true)][string]$NewCrashReporterId,
        [Parameter(Mandatory = $true)][string]$Timestamp,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][ref]$PassCount,
        [Parameter(Mandatory = $true)][ref]$FailCount
    )

    $root = $RootPath
    $machineIdPath = Join-Path $root "machineid"
    $storagePath = Join-Path $root "User\globalStorage\storage.json"
    $sqlitePath = Join-Path $root "User\globalStorage\state.vscdb"
    $workspaceStorageRoot = Join-Path $root "User\workspaceStorage"
    $rootBackupRoot = Join-Path $root ("ID_Backups\" + $Timestamp)
    New-Item -Path $rootBackupRoot -ItemType Directory -Force | Out-Null

    Write-Host "`n########## Root: $AppName ($root) ##########" -ForegroundColor Magenta
    Write-Host "Root backup: $rootBackupRoot" -ForegroundColor Gray

    # --- [1/17] machineid (core: machineid-file) ---
    Write-Host "[1/17] [$AppName] Updating machineid..." -ForegroundColor Cyan
    $machReport = Invoke-GhostCore @("machineid-file", $machineIdPath, $rootBackupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $machineIdPath),
        (_B64Payload @{ value = $Ids.devDeviceId }))
    if ($null -ne $machReport -and $machReport.ok) {
        Add-AuditEntry -Audit $Audit -File $machineIdPath -Key "machineid" -Before $machReport.before -After $machReport.after -Ok $true
        if ($machReport.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $machineIdPath -BackupPath $machReport.backed_up_to
        }
        Write-Host "[OK] machineid verified" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        $beforeValue = $null
        if (Test-Path -LiteralPath $machineIdPath) {
            $beforeValue = (Get-Content -LiteralPath $machineIdPath -Raw).Trim()
        }
        Add-AuditEntry -Audit $Audit -File $machineIdPath -Key "machineid" -Before $beforeValue -After "verify-failed" -Ok $false
        Write-Host "[FAILED] machineid verification failed" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [2/17] storage.json (core: json-patch) ---
    Write-Host "[2/17] [$AppName] Updating storage.json..." -ForegroundColor Cyan
    $storageLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storagePath
    $null = Backup-ViaCore -Source $storagePath -BackupRoot $rootBackupRoot -Label $storageLabel -Actions $Actions
    $storageReport = Invoke-GhostCore @("json-patch", $storagePath, (_B64Payload $StorageUpdates))
    if ($null -ne $storageReport -and $storageReport.ok) {
        foreach ($key in $StorageUpdates.Keys) {
            Add-AuditEntry -Audit $Audit -File $storagePath -Key $key -Before $storageReport.before.$key -After $storageReport.after.$key -Ok $true
        }
        Write-Host "[OK] storage.json verified" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        foreach ($key in $StorageUpdates.Keys) {
            Add-AuditEntry -Audit $Audit -File $storagePath -Key $key -Before $null -After $StorageUpdates[$key] -Ok $false
        }
        Write-Host "[FAILED] storage.json verification failed" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [3/17] state.vscdb serviceMachineId (core: sqlite-update) ---
    Write-Host "[3/17] [$AppName] Updating global state.vscdb (serviceMachineId)..." -ForegroundColor Cyan
    $sqliteLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath
    $null = Backup-ViaCore -Source $sqlitePath -BackupRoot $rootBackupRoot -Label $sqliteLabel -Actions $Actions
    $sqliteReport = Invoke-GhostCore @("sqlite-update", $sqlitePath, (_B64Payload @{ "storage.serviceMachineId" = $Ids.devDeviceId }))
    if ($null -ne $sqliteReport -and $null -ne $sqliteReport.after) {
        Add-AuditEntry -Audit $Audit -File $sqlitePath -Key "storage.serviceMachineId" -Before $sqliteReport.before."storage.serviceMachineId" -After $sqliteReport.after."storage.serviceMachineId" -Ok $true
        Write-Host "[OK] global state.vscdb verified" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Add-AuditEntry -Audit $Audit -File $sqlitePath -Key "storage.serviceMachineId" -Before $null -After $Ids.devDeviceId -Ok $false
        Write-Host "[FAILED] global state.vscdb verification failed" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [4/17] state.vscdb auth secrets DELETE (core: delete-secrets with the
    #     generalized ESCAPE'd patterns - the v0.3 temp-.py heredoc is gone) ---
    Write-Host "[4/17] [$AppName] Clearing global state.vscdb auth secrets..." -ForegroundColor Cyan
    $null = Backup-ViaCore -Source $sqlitePath -BackupRoot $rootBackupRoot -Label $sqliteLabel -Actions $Actions
    $secretsConfig = _B64Payload @{
        exact_keys    = @("codeium.windsurf-windsurf_auth", "windsurfAuthStatus",
            "windsurf.settings.cachedPlanInfo", "devinAuthStatus",
            "devin.settings.cachedPlanInfo")
        like_patterns = @("windsurf\_auth-%", "%windsurf\_auth%",
            "%cachedPlanInfoData:user-%", "devin\_auth-%", "%devin\_auth%")
        escape        = "\"
    }
    $secretsReport = Invoke-GhostCore @("delete-secrets", $sqlitePath, $secretsConfig)
    $secretsOk = $false
    if ($null -ne $secretsReport -and $null -ne $secretsReport.survivors) {
        # survivors is a LIST (one COUNT per pattern/key): PS array -eq 0
        # FILTERS elements instead of answering "all zero" - test explicitly.
        $nonZeroSurvivors = @($secretsReport.survivors | Where-Object { $_ -ne 0 })
        $secretsOk = ($nonZeroSurvivors.Count -eq 0)
        $deletedCount = @($secretsReport.deleted).Count
        if ($secretsOk) {
            Add-AuditEntry -Audit $Audit -File $sqlitePath -Key "secrets-delete" -Before "present" -After ("deleted " + $deletedCount) -Ok $true
            Write-Host "    [OK] secrets deleted: $deletedCount keys from $sqlitePath" -ForegroundColor Green
        }
        else {
            Add-AuditEntry -Audit $Audit -File $sqlitePath -Key "secrets-delete" -Before "present" -After ("survivors=" + $secretsReport.survivors) -Ok $false
            Write-Host "    [FAILED] secret survivors remain: $($secretsReport.survivors) in $sqlitePath" -ForegroundColor Red
        }
    }
    else {
        Add-AuditEntry -Audit $Audit -File $sqlitePath -Key "secrets-delete" -Before "present" -After "failed" -Ok $false
    }
    if ($secretsOk) { $PassCount.Value++ } else { $FailCount.Value++ }

    # --- [5/17] stale state.vscdb.backup deletion (core: sweep-file) ---
    Write-Host "[5/17] [$AppName] Deleting stale state.vscdb.backup..." -ForegroundColor Cyan
    $staleBackup = Join-Path $root "User\globalStorage\state.vscdb.backup"
    $staleReport = Invoke-GhostCore @("sweep-file", $staleBackup)
    if ($null -ne $staleReport -and $staleReport.ok) {
        Add-AuditEntry -Audit $Audit -File $staleBackup -Key "state.vscdb.backup" -Before $staleReport.before -After $staleReport.after -Ok $true
        $PassCount.Value++
    }
    else {
        Add-AuditEntry -Audit $Audit -File $staleBackup -Key "state.vscdb.backup" -Before "present" -After "delete-failed" -Ok $false
        Write-Host "    [FAILED] could not delete: $staleBackup" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [6/17] Preferences salt + Local State os_crypt + username scrub ---
    # Username scrub runs LAST via raw text so the absence check covers the
    # final file content after the JSON mutations above.
    Write-Host "[6/17] [$AppName] Updating Preferences/Local State (salt + os_crypt + username scrub)..." -ForegroundColor Cyan
    $stepFailed = $false
    $prefsPath = Join-Path $root "Preferences"
    $saltReport = Invoke-GhostCore @("salt-rotate", $prefsPath, $rootBackupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $prefsPath))
    if ($null -ne $saltReport -and $saltReport.ok) {
        Add-AuditEntry -Audit $Audit -File $prefsPath -Key "electron.media.device_id_salt" -Before $saltReport.before -After $saltReport.after -Ok $true
        if ($saltReport.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $prefsPath -BackupPath $saltReport.backed_up_to
        }
    }
    elseif ($null -ne $saltReport -and $saltReport.skipped) {
        Add-AuditEntry -Audit $Audit -File $prefsPath -Key "electron.media.device_id_salt" -Before "missing" -After "skipped" -Ok $true
    }
    else {
        Add-AuditEntry -Audit $Audit -File $prefsPath -Key "electron.media.device_id_salt" -Before "present" -After "verify-failed" -Ok $false
        $stepFailed = $true
    }

    $localStatePath = Join-Path $root "Local State"
    $osCryptReport = Invoke-GhostCore @("json-remove", $localStatePath, $rootBackupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $localStatePath),
        (_B64Payload @{ keys = @("os_crypt.encrypted_key") }))
    if ($null -ne $osCryptReport -and $osCryptReport.ok) {
        $osBefore = $osCryptReport.before."os_crypt.encrypted_key"
        $osAfter = if ($osBefore -eq "missing") { "skipped" } else { "removed" }
        Add-AuditEntry -Audit $Audit -File $localStatePath -Key "os_crypt.encrypted_key" -Before $osBefore -After $osAfter -Ok $true
        if ($osCryptReport.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $localStatePath -BackupPath $osCryptReport.backed_up_to
        }
    }
    else {
        Add-AuditEntry -Audit $Audit -File $localStatePath -Key "os_crypt.encrypted_key" -Before "present" -After "verify-failed" -Ok $false
        $stepFailed = $true
    }

    foreach ($scrubPath in @($prefsPath, $localStatePath)) {
        $scrubReport = Invoke-GhostCore @("replace-text", $scrubPath, $rootBackupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $scrubPath),
            (_B64Payload @{ find = $env:USERNAME; replacement = "RESET" }))
        if ($null -ne $scrubReport -and $scrubReport.ok) {
            Add-AuditEntry -Audit $Audit -File $scrubPath -Key "username-scrub" -Before $scrubReport.before -After $scrubReport.after -Ok $true
        }
        else {
            Add-AuditEntry -Audit $Audit -File $scrubPath -Key "username-scrub" -Before "present" -After "still-leaked" -Ok $false
            $stepFailed = $true
        }
    }
    if ($stepFailed) {
        Write-Host "[FAILED] Preferences/Local State step had failures" -ForegroundColor Red
        $FailCount.Value++
    }
    else {
        $PassCount.Value++
    }

    # --- [7/17] Cookies + transport state (core: store-delete, delete mode) ---
    Write-Host "[7/17] [$AppName] Clearing Cookies + transport state..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($storePath in @(
            (Join-Path $root "Network\Cookies"),
            (Join-Path $root "Network\Cookies-journal"),
            (Join-Path $root "Network\Network Persistent State"),
            (Join-Path $root "Network\TransportSecurity"))) {
        $storeReport = Invoke-GhostCore @("store-delete", $storePath, $rootBackupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storePath),
            "--action", "delete", "--root-path", $root)
        if ($null -ne $storeReport) {
            Add-AuditEntry -Audit $Audit -File $storePath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
            if ($storeReport.ok -and $storeReport.backed_up_to) {
                Add-ActionEntry -Actions $Actions -OriginalPath $storePath -BackupPath $storeReport.backed_up_to -Action "delete"
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $storePath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        }
    }
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] Cookies + transport state cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] Cookies + transport state had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [8/17] DIPS stores (core: store-delete, delete mode) ---
    Write-Host "[8/17] [$AppName] Clearing DIPS stores..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($storePath in @((Join-Path $root "DIPS"), (Join-Path $root "DIPS-wal"))) {
        $storeReport = Invoke-GhostCore @("store-delete", $storePath, $rootBackupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storePath),
            "--action", "delete", "--root-path", $root)
        if ($null -ne $storeReport) {
            Add-AuditEntry -Audit $Audit -File $storePath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
            if ($storeReport.ok -and $storeReport.backed_up_to) {
                Add-ActionEntry -Actions $Actions -OriginalPath $storePath -BackupPath $storeReport.backed_up_to -Action "delete"
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $storePath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        }
    }
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] DIPS stores cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] DIPS stores had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [9/17] SharedStorage + Trust Tokens (core: store-delete, delete mode) ---
    Write-Host "[9/17] [$AppName] Clearing SharedStorage + Trust Tokens..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($storePath in @(
            (Join-Path $root "SharedStorage"),
            (Join-Path $root "SharedStorage-wal"),
            (Join-Path $root "Network\Trust Tokens"),
            (Join-Path $root "Network\Trust Tokens-journal"))) {
        $storeReport = Invoke-GhostCore @("store-delete", $storePath, $rootBackupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storePath),
            "--action", "delete", "--root-path", $root)
        if ($null -ne $storeReport) {
            Add-AuditEntry -Audit $Audit -File $storePath -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
            if ($storeReport.ok -and $storeReport.backed_up_to) {
                Add-ActionEntry -Actions $Actions -OriginalPath $storePath -BackupPath $storeReport.backed_up_to -Action "delete"
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $storePath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        }
    }
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] SharedStorage + Trust Tokens cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] SharedStorage + Trust Tokens had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [10/17] cache dirs + Session Storage (core: sweep-tree; chat stores
    #     preserved; WebStorage + IndexedDB deliberately NOT touched) ---
    # v0.3 extends the sweep with the rebrand-era cache dirs verified live on
    # 2026-09-21 (CachedData / CachedProfilesData / CachedExtensionVSIXs /
    # CachedConfigurations / DawnGraphiteCache / DawnWebGPUCache / Shared
    # Dictionary).
    Write-Host "[10/17] [$AppName] Clearing cache directories + Session Storage..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($relative in @(
            "Cache\Cache_Data", "Code Cache", "GPUCache", "blob_storage", "Service Worker", "Session Storage",
            "CachedData", "CachedProfilesData", "CachedExtensionVSIXs", "CachedConfigurations",
            "DawnGraphiteCache", "DawnWebGPUCache", "Shared Dictionary"
        )) {
        $fullPath = Join-Path $root $relative
        if (Test-Path -LiteralPath $fullPath) {
            $sweepReport = Invoke-GhostCore @("sweep-tree", $fullPath, $rootBackupRoot,
                (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $fullPath))
            if ($null -ne $sweepReport) {
                $summary = "deleted={0} failed={1}" -f $sweepReport.deleted, $sweepReport.failed
                Add-AuditEntry -Audit $Audit -File $fullPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0)
                foreach ($failedPath in @($sweepReport.failed_paths)) {
                    Add-AuditEntry -Audit $Audit -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
                }
                if ($sweepReport.backed_up_to) {
                    Add-ActionEntry -Actions $Actions -OriginalPath $fullPath -BackupPath $sweepReport.backed_up_to -Action "delete"
                }
            }
            else {
                Add-AuditEntry -Audit $Audit -File $fullPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
    foreach ($preservedRelative in @("Local Storage\leveldb", "Backups")) {
        $preservedPath = Join-Path $root $preservedRelative
        if (Test-Path -LiteralPath $preservedPath) {
            Write-Host "[INFO] Preserving $preservedRelative" -ForegroundColor Cyan
            Add-AuditEntry -Audit $Audit -File $preservedPath -Key "chat-store" -Before "present" -After "preserved-for-chat" -Ok $true
        }
        else {
            Add-AuditEntry -Audit $Audit -File $preservedPath -Key "chat-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] cache directories cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] cache directories had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [11/17] Crashpad + logs (core: sweep-tree) ---
    Write-Host "[11/17] [$AppName] Clearing Crashpad + logs..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($relative in @("Crashpad", "logs")) {
        $fullPath = Join-Path $root $relative
        if (Test-Path -LiteralPath $fullPath) {
            $sweepReport = Invoke-GhostCore @("sweep-tree", $fullPath, $rootBackupRoot, $relative)
            if ($null -ne $sweepReport) {
                $summary = "deleted={0} failed={1}" -f $sweepReport.deleted, $sweepReport.failed
                Add-AuditEntry -Audit $Audit -File $fullPath -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0)
                foreach ($failedPath in @($sweepReport.failed_paths)) {
                    Add-AuditEntry -Audit $Audit -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
                }
                if ($sweepReport.backed_up_to) {
                    Add-ActionEntry -Actions $Actions -OriginalPath $fullPath -BackupPath $sweepReport.backed_up_to -Action "delete"
                }
            }
            else {
                Add-AuditEntry -Audit $Audit -File $fullPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] Crashpad + logs cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] Crashpad + logs had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [12/17] workspace UPSERT-only (core: sqlite-update per db; never
    #     delete workspace files) ---
    Write-Host "[12/17] [$AppName] Updating workspace state.vscdb files (UPSERT only)..." -ForegroundColor Cyan
    $workspaceDbPaths = @()
    if (Test-Path -LiteralPath $workspaceStorageRoot) {
        $workspaceDbPaths = Get-ChildItem -LiteralPath $workspaceStorageRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "state.vscdb" } |
            Where-Object { Test-Path -LiteralPath $_ }
    }

    if ($workspaceDbPaths.Count -eq 0) {
        Write-Host "[SKIP] no workspace state.vscdb files found" -ForegroundColor Yellow
        Add-AuditEntry -Audit $Audit -File $workspaceStorageRoot -Key "workspaceStorage" -Before "none" -After "skipped" -Ok $true
        $PassCount.Value++
    }
    else {
        $workspaceFailures = 0
        foreach ($workspaceDbPath in $workspaceDbPaths) {
            $wsLabel = Get-AppRelativeBackupLabel -RootPath $root -TargetPath $workspaceDbPath
            $null = Backup-ViaCore -Source $workspaceDbPath -BackupRoot $rootBackupRoot -Label $wsLabel -Actions $Actions
            $wsReport = Invoke-GhostCore @("sqlite-update", $workspaceDbPath, (_B64Payload @{ "storage.serviceMachineId" = $Ids.devDeviceId }))
            if ($null -ne $wsReport -and $null -ne $wsReport.after) {
                Add-AuditEntry -Audit $Audit -File $workspaceDbPath -Key "storage.serviceMachineId" -Before $wsReport.before."storage.serviceMachineId" -After $wsReport.after."storage.serviceMachineId" -Ok $true
                Write-Host "    [OK] workspace DB updated: $workspaceDbPath" -ForegroundColor Green
            }
            else {
                Add-AuditEntry -Audit $Audit -File $workspaceDbPath -Key "storage.serviceMachineId" -Before $null -After $Ids.devDeviceId -Ok $false
                Write-Host "    [FAILED] workspace DB update: $workspaceDbPath" -ForegroundColor Red
                $workspaceFailures++
            }
        }
        $workspaceBackupCount = @(Get-ChildItem -LiteralPath $workspaceStorageRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "state.vscdb.backup" } |
            Where-Object { Test-Path -LiteralPath $_ }).Count
        Add-AuditEntry -Audit $Audit -File $workspaceStorageRoot -Key "workspace-backups-preserved" -Before ("present=" + $workspaceBackupCount) -After "preserved-per-policy" -Ok $true

        if ($workspaceFailures -eq 0) {
            Write-Host "[OK] workspace UPSERT complete (no workspace files deleted)" -ForegroundColor Green
            $PassCount.Value++
        }
        else {
            Write-Host "[FAILED] workspace UPSERT had failures" -ForegroundColor Red
            $FailCount.Value++
        }
    }

    # --- [13/17] app-specific files (core: machineid-file / store-delete /
    #     json-set; NEW in v0.3, migrated in v0.4) ---
    # cli\installation_id: the Devin CLI keeps its own install GUID under the
    #   data root (verified live 2026-09-21). Regenerated only when present.
    # credentials.toml: holds windsurf_api_key (the shared auth token). Backed
    #   up, then deleted, so no old-bound credential survives the reset.
    # config.json: devin.org_id blanked (file kept; absent-or-empty = SKIP).
    Write-Host "[13/17] [$AppName] Resetting app-specific files (cli installation_id / credentials.toml / config.json)..." -ForegroundColor Cyan
    $stepFailed = $false

    $cliInstallationIdPath = Join-Path $root "cli\installation_id"
    if (Test-Path -LiteralPath $cliInstallationIdPath) {
        $newCliInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
        $cliReport = Invoke-GhostCore @("machineid-file", $cliInstallationIdPath, $rootBackupRoot,
            (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $cliInstallationIdPath),
            (_B64Payload @{ value = $newCliInstallationId }))
        if ($null -ne $cliReport -and $cliReport.ok) {
            Add-AuditEntry -Audit $Audit -File $cliInstallationIdPath -Key "installation_id" -Before $cliReport.before -After $cliReport.after -Ok $true
            if ($cliReport.backed_up_to) {
                Add-ActionEntry -Actions $Actions -OriginalPath $cliInstallationIdPath -BackupPath $cliReport.backed_up_to
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $cliInstallationIdPath -Key "installation_id" -Before "present" -After "verify-failed" -Ok $false
            $stepFailed = $true
        }
    }
    else {
        Write-Host "    [SKIP] cli\installation_id not present: $cliInstallationIdPath" -ForegroundColor Yellow
        Add-AuditEntry -Audit $Audit -File $cliInstallationIdPath -Key "installation_id" -Before "missing" -After "skipped" -Ok $true
    }

    $credentialsPath = Join-Path $root "credentials.toml"
    $auditStart = $Audit.Value.Count
    $credReport = Invoke-GhostCore @("store-delete", $credentialsPath, $rootBackupRoot,
        (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $credentialsPath),
        "--action", "delete", "--root-path", $root)
    if ($null -ne $credReport) {
        Add-AuditEntry -Audit $Audit -File $credentialsPath -Key "binary-store" -Before $credReport.before -After $credReport.after -Ok $credReport.ok
        if ($credReport.ok -and $credReport.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $credentialsPath -BackupPath $credReport.backed_up_to -Action "delete"
        }
    }
    else {
        Add-AuditEntry -Audit $Audit -File $credentialsPath -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
    }
    $credStatus = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if (-not $credStatus.Success) {
        $stepFailed = $true
    }

    $configPath = Join-Path $root "config.json"
    $orgReport = Invoke-GhostCore @("json-set", $configPath, $rootBackupRoot, "config.json",
        (_B64Payload @{ key = "devin.org_id"; value = ""; skip_if_empty = $true }))
    if ($null -ne $orgReport -and $orgReport.ok) {
        Add-AuditEntry -Audit $Audit -File $configPath -Key "devin.org_id" -Before $orgReport.before -After $orgReport.after -Ok $true
        if ($orgReport.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $configPath -BackupPath $orgReport.backed_up_to
        }
    }
    else {
        Add-AuditEntry -Audit $Audit -File $configPath -Key "devin.org_id" -Before "present" -After "verify-failed" -Ok $false
        $stepFailed = $true
    }

    if ($stepFailed) {
        Write-Host "[FAILED] app-specific files step had failures" -ForegroundColor Red
        $FailCount.Value++
    }
    else {
        $PassCount.Value++
    }

    # --- [14/17] Old ID_Backups purge + watchdog re-verify (this root; PS) ---
    Write-Host "[14/17] [$AppName] Purging old ID_Backups + watchdog re-verify..." -ForegroundColor Cyan
    Invoke-OldIdBackupsPurge -BackupRoot $rootBackupRoot -IdBackupsRoot (Join-Path $root "ID_Backups") -Audit $Audit
    $watchdogCoreFiles = @(
        (Join-Path $root "Network\Cookies"),
        (Join-Path $root "DIPS"),
        (Join-Path $root "SharedStorage")
    )
    Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit $Audit
    $PassCount.Value++
}

# === Main =====================================================================

Assert-Administrator

# Windsurf rebranded to Devin Desktop (2026-06-02, over-the-air). The data
# root under %APPDATA% may exist under either (or both) names; NTFS is
# case-insensitive so a lowercase "devin" on disk matches the "Devin" probe,
# and Get-Item resolves the on-disk casing for accurate audit paths.
$appNames = @("Devin", "Windsurf")
$roots = @()
foreach ($appName in $appNames) {
    $candidateRoot = Join-Path $env:APPDATA $appName
    if (Test-Path -LiteralPath $candidateRoot) {
        $resolvedRoot = Get-Item -LiteralPath $candidateRoot
        $roots += [pscustomobject]@{ Name = $resolvedRoot.Name; Path = $resolvedRoot.FullName }
    }
}

if ($roots.Count -eq 0) {
    Write-Host "Windsurf / Devin Desktop installation not found. Checked:" -ForegroundColor Red
    foreach ($appName in $appNames) {
        Write-Host "    $(Join-Path $env:APPDATA $appName)" -ForegroundColor Red
    }
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$primaryRoot = $roots[0].Path
$backupRoot = Join-Path $primaryRoot ("ID_Backups\" + $timestamp)
$windsurfHome = Join-Path $env:USERPROFILE ".windsurf"
$devinHome = Join-Path $env:USERPROFILE ".devin"
$codeiumHome = Join-Path $env:USERPROFILE ".codeium"
$windsurfArgvPath = Join-Path $windsurfHome "argv.json"
$devinArgvPath = Join-Path $devinHome "argv.json"
$installationIdPath = Join-Path $windsurfHome "installation_id"
$codeiumConfigPath = Join-Path $codeiumHome "config.json"
$audit = @()
$actions = @()
$ids = New-IdentitySet

# The core must be present and a functional Python 3 with it - fail fast
# BEFORE touching anything (v0.4 needs Python for every store mutation).
if ((Get-GhostPythonCli) -and (-not (Get-PythonCommandInfo))) {
    Write-Host "[FAILED] Python core present but no functional Python 3 - install it (winget install Python.Python.3.12)." -ForegroundColor Red
    exit 1
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Windsurf/Devin Identity Reset v0.4 ===" -ForegroundColor Cyan
foreach ($rootEntry in $roots) {
    Write-Host "Root [$($rootEntry.Name)]: $($rootEntry.Path)" -ForegroundColor Gray
}
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: chat history + workspaces preserved; no MAC/hostname/registry steps" -ForegroundColor Gray

if (-not (Stop-AppFamilyProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$newCrashReporterId = Get-NewCrashReporterId
$storageUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}

foreach ($rootEntry in $roots) {
    Invoke-RootReset -AppName $rootEntry.Name -RootPath $rootEntry.Path -Ids $ids -StorageUpdates $storageUpdates -NewCrashReporterId $newCrashReporterId -Timestamp $timestamp -Audit ([ref]$audit) -Actions ([ref]$actions) -PassCount ([ref]$passCount) -FailCount ([ref]$failCount)
}

# --- [15/17] home dirs: argv.json (core: patch-argv) + .windsurf
#     installation_id (core: machineid-file) + Codeium device_id
#     (core: json-patch) ---
Write-Host "`n[15/17] Updating home dirs (argv.json / installation_id / Codeium device_id)..." -ForegroundColor Cyan
$homeStepFailed = $false
# Both argv.json variants carry crash-reporter-id post-rebrand (verified live
# 2026-09-21 in .devin); the core handler SKIPs cleanly when a file is absent.
foreach ($argvPath in @($windsurfArgvPath, $devinArgvPath)) {
    $argvReport = Invoke-GhostCore @("patch-argv", $argvPath, $backupRoot,
        (Get-UserProfileBackupLabel -TargetPath $argvPath),
        (_B64Payload @{ new_id = $newCrashReporterId; username = $env:USERNAME }))
    if ($null -ne $argvReport -and $argvReport.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $argvPath -Key "crash-reporter-id" -Before $argvReport.before -After $argvReport.after -Ok $true
        Add-AuditEntry -Audit ([ref]$audit) -File $argvPath -Key ("user-data-dir:scrubbed:" + $argvReport.user_dir_scrubbed.ToString().ToLowerInvariant()) -Before "n/a" -After "n/a" -Ok $true
        if ($argvReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $argvPath -BackupPath $argvReport.backed_up_to
        }
    }
    elseif ($null -ne $argvReport -and $argvReport.skipped) {
        Add-AuditEntry -Audit ([ref]$audit) -File $argvPath -Key "crash-reporter-id" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] argv.json not present: $argvPath" -ForegroundColor Yellow
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $argvPath -Key "crash-reporter-id" -Before "present" -After "verify-failed" -Ok $false
        $homeStepFailed = $true
    }
}

if (Test-Path -LiteralPath $installationIdPath) {
    $newInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
    $instReport = Invoke-GhostCore @("machineid-file", $installationIdPath, $backupRoot,
        (Get-UserProfileBackupLabel -TargetPath $installationIdPath),
        (_B64Payload @{ value = $newInstallationId }))
    if ($null -ne $instReport -and $instReport.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "installation_id" -Before $instReport.before -After $instReport.after -Ok $true
        if ($instReport.backed_up_to) {
            Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $installationIdPath -BackupPath $instReport.backed_up_to
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "installation_id" -Before "present" -After "verify-failed" -Ok $false
        $homeStepFailed = $true
    }
}
else {
    Write-Host "    [SKIP] installation_id not present: $installationIdPath" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "installation_id" -Before "missing" -After "skipped" -Ok $true
}

if (Test-Path -LiteralPath $codeiumConfigPath) {
    $codeiumLabel = Get-UserProfileBackupLabel -TargetPath $codeiumConfigPath
    $null = Backup-ViaCore -Source $codeiumConfigPath -BackupRoot $backupRoot -Label $codeiumLabel -Actions ([ref]$actions)
    $codeiumReport = Invoke-GhostCore @("json-patch", $codeiumConfigPath, (_B64Payload @{ "device_id" = $ids.devDeviceId }))
    if ($null -ne $codeiumReport -and $codeiumReport.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $codeiumConfigPath -Key "device_id" -Before $codeiumReport.before."device_id" -After $codeiumReport.after."device_id" -Ok $true
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $codeiumConfigPath -Key "device_id" -Before $null -After $ids.devDeviceId -Ok $false
        $homeStepFailed = $true
    }
}
else {
    Write-Host "    [SKIP] Codeium config.json not present: $codeiumConfigPath" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $codeiumConfigPath -Key "device_id" -Before "missing" -After "skipped" -Ok $true
}

if ($homeStepFailed) {
    Write-Host "[FAILED] home-dir step had failures" -ForegroundColor Red
    $failCount++
}
else {
    Write-Host "[OK] home dirs updated" -ForegroundColor Green
    $passCount++
}

# --- [16/17] %LOCALAPPDATA% updater sweep (core: sweep-tree) ---
# ONLY the updater cache dirs are deleted. %LOCALAPPDATA%\Programs\<App> is
# the install dir and %LOCALAPPDATA%\devin holds CLI binaries + a non-identity
# telemetry flag (is_zdr) -- both are never touched.
Write-Host "`n[16/17] Sweeping %LOCALAPPDATA% updater dirs (Devin/Windsurf)..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($updaterDir in @((Join-Path $env:LOCALAPPDATA "Devin-updater"), (Join-Path $env:LOCALAPPDATA "Windsurf-updater"))) {
    if (Test-Path -LiteralPath $updaterDir) {
        $sweepReport = Invoke-GhostCore @("sweep-tree", $updaterDir, $backupRoot,
            (Get-PathBackupLabel -Path $updaterDir))
        if ($null -ne $sweepReport) {
            $summary = "deleted={0} failed={1}" -f $sweepReport.deleted, $sweepReport.failed
            Add-AuditEntry -Audit ([ref]$audit) -File $updaterDir -Key "binary-store" -Before "present" -After $summary -Ok ($sweepReport.failed -eq 0)
            foreach ($failedPath in @($sweepReport.failed_paths)) {
                Add-AuditEntry -Audit ([ref]$audit) -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
            }
            if ($sweepReport.backed_up_to) {
                Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $updaterDir -BackupPath $sweepReport.backed_up_to -Action "delete"
            }
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $updaterDir -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $updaterDir -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    }
}
$updaterStatus = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $env:LOCALAPPDATA
if ($updaterStatus.Success) {
    Write-Host "[OK] updater sweep complete" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] updater sweep had failures" -ForegroundColor Red
    $failCount++
}

# --- [17/17] Final probes + combined audit + restore script -------------------
Write-Host "`n[17/17] Final verification + audit + restore script..." -ForegroundColor Cyan
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
Write-AuditLog -Audit $audit -Path $auditPath
$restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App "Devin-Windsurf" -Actions $actions

foreach ($rootEntry in $roots) {
    $rootStoragePath = Join-Path $rootEntry.Path "User\globalStorage\storage.json"
    $rootSqlitePath = Join-Path $rootEntry.Path "User\globalStorage\state.vscdb"

    $finalJsonOk = $false
    if (Test-Path -LiteralPath $rootStoragePath) {
        $finalJsonOk = Confirm-JsonValues -Path $rootStoragePath -Expected $storageUpdates
    }

    $finalSqliteAuditEntries = @($audit | Where-Object { $_.file -eq $rootSqlitePath -and $_.key -eq "storage.serviceMachineId" })
    $finalSqliteOk = ($finalSqliteAuditEntries.Count -gt 0) -and ($finalSqliteAuditEntries[-1].ok -eq $true)

    if ($finalJsonOk) {
        Write-Host "[OK] final storage.json probe passed [$($rootEntry.Name)]" -ForegroundColor Green
    }
    else {
        Write-Host "[FAILED] final storage.json probe failed [$($rootEntry.Name)]" -ForegroundColor Red
        $failCount++
    }

    if ($finalSqliteOk) {
        Write-Host "[OK] final state.vscdb probe passed [$($rootEntry.Name)]" -ForegroundColor Green
    }
    else {
        Write-Host "[FAILED] final state.vscdb probe failed [$($rootEntry.Name)]" -ForegroundColor Red
        $failCount++
    }
}

if (-not (Test-Path -LiteralPath $restoreScriptPath) -or ((Get-Item -LiteralPath $restoreScriptPath).Length -le 0)) {
    Write-Host "[FAILED] restore script missing or empty" -ForegroundColor Red
    $failCount++
}
else {
    $passCount++
}

$rootNamesProcessed = ($roots | ForEach-Object { $_.Name }) -join ", "
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Roots processed: $rootNamesProcessed" -ForegroundColor Gray
Write-Host "Pass: $passCount" -ForegroundColor Green
Write-Host "Fail: $failCount" -ForegroundColor Red
Write-Host "Audit log: $auditPath" -ForegroundColor Gray
Write-Host "Restore script: $restoreScriptPath" -ForegroundColor Gray
Write-Host "NOTE: workspace .backup sidecars were preserved per policy (they still embed the old device ID)." -ForegroundColor Yellow
Write-Host "NOTE: change_device_id.ps1 remains the separate, optional system-level step." -ForegroundColor Yellow

[System.IO.File]::WriteAllText("$env:TEMP\devin_v0.4_done.txt", ("Roots: {0} Pass: {1} Fail: {2} Audit: {3}" -f $rootNamesProcessed, $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "Windsurf/Devin reset v0.4 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "Windsurf/Devin reset v0.4 completed successfully." -ForegroundColor Green
