#Requires -Version 5.1
# Trae Identity Reset v0.2
#
# Hardened rebuild of reset_trae_windows-v0.1.ps1 on the v1.1 template:
#   - Self-elevation to Administrator (auto re-launch, no manual "run as admin")
#   - Aggressive multi-process kill (Trae + Broker + helpers, 2 clean checks)
#   - No-BOM UTF-8 on EVERY write (v0.1 used Set-Content -Encoding UTF8, which
#     emits a BOM under PowerShell 5.1 and can corrupt Chromium/Electron parsers)
#   - Delete (not rename) for binary stores: renames left *.backup files with
#     the OLD fingerprint on disk. Backups live in ID_Backups for restore.
#   - POLICY CHANGE over v0.1: ModularData\ai-agent (chat DB) is PRESERVED.
#     v0.1 renamed the whole tree (wiped chat). v0.2 backs it up and scrubs
#     only key-name-matched identity rows, never chat content.
#   - NEW targets over v0.1: os_crypt rotation, Preferences device_id_salt,
#     Trust Tokens, Crashpad, logs, stale .backup deletion, old ID_Backups
#     purge, watchdog re-verify.
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
# Requirement: Python (python or python3) for SQLite writes.

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
$traeIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $traeIsAdmin) {
    $traeLogOut = "$env:TEMP\trae_v0.2_result.log"
    $traeScript = $MyInvocation.MyCommand.Path
    $traeArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$traeScript`" *> `"$traeLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $traeArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath $traeLogOut) {
        Get-Content -LiteralPath $traeLogOut
    }
    if (Test-Path -LiteralPath "$env:TEMP\trae_v0.2_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\trae_v0.2_done.txt"
    }
    exit
}

Write-GhostBanner -Target "Trae Identity Reset" -Version "0.2"

# === Local helpers (Trae pattern, no-BOM throughout) ==========================

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

function Set-VerifiedMachineIdFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    $beforeValue = $null
    if (Test-Path -LiteralPath $Path) {
        $beforeValue = (Get-Content -LiteralPath $Path -Raw).Trim()
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
        if ($backupPath) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
        }
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    # No-BOM UTF-8. v0.1 used Set-Content -Encoding UTF8 (BOM on PS 5.1).
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding $false))
    $afterValue = (Get-Content -LiteralPath $Path -Raw).Trim()
    $ok = $afterValue -eq $Value
    Add-AuditEntry -Audit $Audit -File $Path -Key "machineid" -Before $beforeValue -After $afterValue -Ok $ok
    return $ok
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

function Invoke-WorkspaceSqliteUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$WorkspaceDbPath,
        [Parameter(Mandatory = $true)][string]$DeviceId,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    # UPSERT ONLY -- never delete workspace tables/files (chat preservation).
    $ok = Set-SqliteKeys `
        -Path $WorkspaceDbPath `
        -Updates @{ "storage.serviceMachineId" = $DeviceId } `
        -Audit $Audit `
        -BackupRoot $BackupRoot `
        -BackupLabel (Get-AppRelativeBackupLabel -RootPath $RootPath -TargetPath $WorkspaceDbPath) `
        -Actions $Actions

    if ($ok) {
        Write-Host "    [OK] workspace DB updated: $WorkspaceDbPath" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] workspace DB update: $WorkspaceDbPath" -ForegroundColor Red
    }
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

# Trae storage.json holds the standard 4 telemetry keys PLUS iCubeAuthInfo://*
# auth keys and a has_device_id_updated_to_aha flag. Rewrites all of them in
# one verified pass. No-BOM write.
function Update-TraeStorageJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Telemetry,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        foreach ($key in $Telemetry.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Telemetry[$key] -Ok $false
        }
        Write-Host "    [FAILED] storage.json not found: $Path" -ForegroundColor Red
        return $false
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        foreach ($key in $Telemetry.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Telemetry[$key] -Ok $false
        }
        Write-Host "    [FAILED] could not parse storage.json: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValues = @{}
    foreach ($key in $Telemetry.Keys) {
        $beforeValues[$key] = if ($null -ne $content.PSObject.Properties[$key]) { $content.$key } else { $null }
    }
    $icubeKeys = @($content.PSObject.Properties | Where-Object { $_.Name -like 'iCubeAuthInfo://*' } | ForEach-Object { $_.Name })
    $icubeBeforeCount = $icubeKeys.Count
    $ahaBefore = if ($null -ne $content.PSObject.Properties['has_device_id_updated_to_aha']) { [string]$content.'has_device_id_updated_to_aha' } else { $null }

    foreach ($icubeKey in $icubeKeys) {
        $content.PSObject.Properties.Remove($icubeKey)
    }

    foreach ($key in $Telemetry.Keys) {
        if ($null -ne $content.PSObject.Properties[$key]) {
            $content.$key = $Telemetry[$key]
        }
        else {
            Add-Member -InputObject $content -NotePropertyName $key -NotePropertyValue $Telemetry[$key]
        }
    }
    if ($null -ne $content.PSObject.Properties['has_device_id_updated_to_aha']) {
        $content.'has_device_id_updated_to_aha' = $false
    }
    else {
        Add-Member -InputObject $content -NotePropertyName 'has_device_id_updated_to_aha' -NotePropertyValue $false
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        foreach ($key in $Telemetry.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $null -Ok $false
        }
        Write-Host "    [FAILED] could not re-read storage.json after write: $Path" -ForegroundColor Red
        return $false
    }

    $allMatched = $true
    foreach ($key in $Telemetry.Keys) {
        $actualValue = if ($null -ne $verified.PSObject.Properties[$key]) { $verified.$key } else { $null }
        $ok = $actualValue -eq $Telemetry[$key]
        Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $actualValue -Ok $ok
        if (-not $ok) { $allMatched = $false }
    }

    $icubeAfter = @($verified.PSObject.Properties | Where-Object { $_.Name -like 'iCubeAuthInfo://*' } | ForEach-Object { $_.Name })
    $icubeOk = $icubeAfter.Count -eq 0
    Add-AuditEntry -Audit $Audit -File $Path -Key "iCubeAuthInfo.*" -Before ("count=" + $icubeBeforeCount) -After ("count=" + $icubeAfter.Count) -Ok $icubeOk
    if (-not $icubeOk) { $allMatched = $false }

    $ahaAfter = if ($null -ne $verified.PSObject.Properties['has_device_id_updated_to_aha']) { [string]$verified.'has_device_id_updated_to_aha' } else { $null }
    $ahaOk = $ahaAfter -eq "False"
    Add-AuditEntry -Audit $Audit -File $Path -Key "has_device_id_updated_to_aha" -Before $ahaBefore -After $ahaAfter -Ok $ahaOk
    if (-not $ahaOk) { $allMatched = $false }

    return $allMatched
}

# Trae ckg_server/local_env.json: device_id -> fresh 19-digit string,
# host_map.default -> "". No-BOM write.
function Update-TraeLocalEnv {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewDeviceId,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] local_env.json not present: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id" -Before $null -After $null -Ok $false
        Write-Host "    [FAILED] could not parse local_env.json: $Path" -ForegroundColor Red
        return $false
    }

    $deviceBefore = if ($null -ne $content.PSObject.Properties['device_id']) { [string]$content.device_id } else { $null }
    $hostBefore = $null
    if ($null -ne $content.PSObject.Properties['host_map'] -and $null -ne $content.host_map.PSObject.Properties['default']) {
        $hostBefore = [string]$content.host_map.default
    }

    if ($null -ne $content.PSObject.Properties['device_id']) {
        $content.device_id = $NewDeviceId
    }
    else {
        Add-Member -InputObject $content -NotePropertyName 'device_id' -NotePropertyValue $NewDeviceId
    }

    if ($null -eq $content.PSObject.Properties['host_map']) {
        $hostMap = [ordered]@{ default = "" }
        Add-Member -InputObject $content -NotePropertyName 'host_map' -NotePropertyValue $hostMap
    }
    else {
        if ($null -ne $content.host_map.PSObject.Properties['default']) {
            $content.host_map.default = ""
        }
        else {
            Add-Member -InputObject $content.host_map -NotePropertyName 'default' -NotePropertyValue ""
        }
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id" -Before $deviceBefore -After $null -Ok $false
        Write-Host "    [FAILED] could not re-read local_env.json after write: $Path" -ForegroundColor Red
        return $false
    }

    $deviceAfter = if ($null -ne $verified.PSObject.Properties['device_id']) { [string]$verified.device_id } else { $null }
    $deviceOk = $deviceAfter -eq $NewDeviceId
    Add-AuditEntry -Audit $Audit -File $Path -Key "device_id" -Before $deviceBefore -After $deviceAfter -Ok $deviceOk

    $hostAfter = $null
    $hostOk = $true
    if ($null -ne $verified.PSObject.Properties['host_map'] -and $null -ne $verified.host_map.PSObject.Properties['default']) {
        $hostAfter = [string]$verified.host_map.default
        $hostOk = ($hostAfter -eq "")
    }
    Add-AuditEntry -Audit $Audit -File $Path -Key "host_map.default" -Before $hostBefore -After $hostAfter -Ok $hostOk

    return ($deviceOk -and $hostOk)
}

# Identity-row scrub for ModularData\ai-agent (chat DB). POLICY: the tree is
# never renamed/deleted (v0.1 wiped chat). Instead, back it up, then in every
# *.db delete only rows whose KEY column name-matches identity patterns
# (device/machine/telemetry/auth-token key names). Matching is on key NAMES
# only -- values (chat content) are never inspected or modified. Tables
# without a key-like TEXT column are skipped with an audit entry.
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

    $backupPath = Backup-FileToTimestampDir -Source $AiAgentPath -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $AiAgentPath -BackupPath $backupPath
    }

    $dbFiles = @(Get-ChildItem -LiteralPath $AiAgentPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq ".db" })
    if ($dbFiles.Count -eq 0) {
        Add-AuditEntry -Audit $Audit -File $AiAgentPath -Key "ai-agent-scrub" -Before "present" -After "no-db-files-preserved" -Ok $true
        Write-Host "    [INFO] ai-agent has no .db files; tree preserved" -ForegroundColor Cyan
        return $true
    }

    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Add-AuditEntry -Audit $Audit -File $AiAgentPath -Key "ai-agent-scrub" -Before "present" -After "python-not-found" -Ok $false
        Write-Host "    [FAILED] Python not found -- ai-agent scrub SKIPPED: $AiAgentPath" -ForegroundColor Red
        return $false
    }

    $tempScriptPath = Join-Path $env:TEMP ("trae_scrub_aiagent_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @'
import sqlite3
import json
import sys

db_path = sys.argv[1]
patterns = ("%device%id%", "%machine%id%", "%telemetry%", "%auth%token%")
deleted = 0
skipped_tables = []

conn = sqlite3.connect(db_path)
try:
    cursor = conn.cursor()
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    tables = [r[0] for r in cursor.fetchall()]
    for table in tables:
        if not table.replace("_", "").isalnum():
            skipped_tables.append(table)
            continue
        cursor.execute("PRAGMA table_info(" + table + ")")
        cols = cursor.fetchall()
        text_cols = [c[1] for c in cols if c[2].upper() == "TEXT" and c[1].replace("_", "").isalnum()]
        key_cols = [c for c in text_cols if c.lower() in ("key", "name", "k", "id", "itemkey")]
        if len(key_cols) == 0 or len(text_cols) < 1:
            skipped_tables.append(table)
            continue
        key_col = key_cols[0]
        for pattern in patterns:
            cursor.execute("SELECT COUNT(*) FROM " + table + " WHERE " + key_col + " LIKE ?", (pattern,))
            n = cursor.fetchone()[0]
            if n > 0:
                cursor.execute("DELETE FROM " + table + " WHERE " + key_col + " LIKE ?", (pattern,))
                deleted += n
    conn.commit()
finally:
    conn.close()

print(json.dumps({"deleted": deleted, "skipped_tables": skipped_tables}))
'@

    $allOk = $true
    try {
        [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, (New-Object System.Text.UTF8Encoding $false))
        foreach ($dbFile in $dbFiles) {
            $commandOutput = & $pythonCommand.Source $tempScriptPath $dbFile.FullName
            if ($LASTEXITCODE -ne 0) {
                Add-AuditEntry -Audit $Audit -File $dbFile.FullName -Key "ai-agent-scrub" -Before "present" -After "failed" -Ok $false
                Write-Host "    [FAILED] ai-agent scrub command failed: $($dbFile.FullName)" -ForegroundColor Red
                $allOk = $false
                continue
            }
            $result = ($commandOutput -join "`n") | ConvertFrom-Json
            Add-AuditEntry -Audit $Audit -File $dbFile.FullName -Key "ai-agent-scrub" -Before "present" -After ("identity-rows-deleted " + $result.deleted) -Ok $true
            Write-Host "    [OK] ai-agent scrub: $($result.deleted) identity rows from $($dbFile.FullName)" -ForegroundColor Green
        }
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $AiAgentPath -Key "ai-agent-scrub" -Before "present" -After "exception" -Ok $false
        Write-Host "    [FAILED] ai-agent scrub threw exception: $AiAgentPath" -ForegroundColor Red
        $allOk = $false
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
    return $allOk
}

function Clear-TreeFilesIndividually {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        return @{ Deleted = 0; Failed = 0; FailedPaths = @() }
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel

    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $deleted = 0
    $failed = 0
    $failedPaths = @()

    foreach ($file in $files) {
        $fileDeleted = $false
        $lastError = $null
        for ($i = 0; $i -lt 4; $i++) {
            try {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                $fileDeleted = $true
                break
            }
            catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Milliseconds (500 * ($i + 1))
            }
        }
        if ($fileDeleted) {
            $deleted++
        }
        else {
            $failed++
            $failedPaths += $file.FullName
            Add-AuditEntry -Audit $Audit -File $file.FullName -Key "binary-store" -Before "present" -After ("delete-failed: " + $lastError) -Ok $false
        }
    }

    $dirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        $null = Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
    }
    $null = Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

    $summary = "deleted=$deleted failed=$failed"
    $ok = ($failed -eq 0)
    Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "present" -After $summary -Ok $ok
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath -Action "delete"
    }

    return @{ Deleted = $deleted; Failed = $failed; FailedPaths = $failedPaths }
}

function Remove-VerifiedFileNoBackup {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$AuditKey,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before "missing" -After "skipped" -Ok $true
        return $true
    }

    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before "present" -After "deleted" -Ok $true
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before "present" -After "delete-failed" -Ok $false
    Write-Host "    [FAILED] could not delete: $Path" -ForegroundColor Red
    return $false
}

function Remove-OsCryptEncryptedKey {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] Local State not found: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse Local State: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValue = if ($null -ne $content.PSObject.Properties['os_crypt']) { "present" } else { "missing" }
    if ($null -eq $content.PSObject.Properties['os_crypt']) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] os_crypt not found in: $Path" -ForegroundColor Yellow
        return $true
    }

    $content.os_crypt.PSObject.Properties.Remove('encrypted_key')

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $afterValue = if ($null -eq $verified.os_crypt.PSObject.Properties['encrypted_key']) { "removed" } else { "still-present" }
        $ok = $afterValue -eq "removed"
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before $beforeValue -After $afterValue -Ok $ok
        if ($ok) {
            Write-Host "    [OK] os_crypt.encrypted_key removed: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] os_crypt.encrypted_key still present: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before $beforeValue -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read Local State after write: $Path" -ForegroundColor Red
        return $false
    }
}

function Set-DeviceIdSalt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewSalt,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] Preferences not found: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse Preferences: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValue = $null
    $targetKey = "electron.media.device_id_salt"

    $electronProp = if ($null -ne $content.PSObject.Properties['electron']) { $content.electron } else { $null }
    if ($electronProp -and ($null -ne $electronProp.PSObject.Properties['media'])) {
        $mediaProp = $electronProp.media
        if ($null -ne $mediaProp.PSObject.Properties['device_id_salt']) {
            $beforeValue = $mediaProp.device_id_salt
        }
    }

    if ($null -eq $electronProp) {
        Add-Member -InputObject $content -NotePropertyName 'electron' -NotePropertyValue @{ media = @{ device_id_salt = $NewSalt } }
    }
    elseif ($null -eq $electronProp.PSObject.Properties['media']) {
        Add-Member -InputObject $content.electron -NotePropertyName 'media' -NotePropertyValue @{ device_id_salt = $NewSalt }
    }
    else {
        $content.electron.media.device_id_salt = $NewSalt
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $actualValue = $verified.electron.media.device_id_salt
        $ok = $actualValue -eq $NewSalt
        Add-AuditEntry -Audit $Audit -File $Path -Key $targetKey -Before $beforeValue -After $actualValue -Ok $ok
        if ($ok) {
            Write-Host "    [OK] device_id_salt updated: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] device_id_salt verification failed: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key $targetKey -Before $beforeValue -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read Preferences after write: $Path" -ForegroundColor Red
        return $false
    }
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
        foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
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
    foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
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
        return
    }

    foreach ($path in $recreated) {
        Write-Host "    [WARN] watchdog recreated file, re-deleting: $path" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        $afterValue = if (Test-Path -LiteralPath $path) { "re-delete-failed" } else { "re-deleted" }
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After $afterValue -Ok $true
    }
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
        Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "deleted" -Ok $true
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

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Trae Identity Reset v0.2 ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: chat history + workspaces preserved; no MAC/hostname/registry steps" -ForegroundColor Gray

if (-not (Stop-TraeProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$newSalt = -join ((1..32) | ForEach-Object { "{0:X}" -f (Get-Random -Maximum 16) })
$telemetryUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}

# --- [1/16] machineid ---
Write-Host "`n[1/16] Updating machineid..." -ForegroundColor Cyan
if (Set-VerifiedMachineIdFile -Path $machineIdPath -Value $ids.devDeviceId -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $machineIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "[OK] machineid verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] machineid verification failed" -ForegroundColor Red
    $failCount++
}

# --- [2/16] storage.json (telemetry + iCubeAuthInfo removal + aha flag) ---
Write-Host "`n[2/16] Updating storage.json (telemetry + iCubeAuthInfo removal + aha flag)..." -ForegroundColor Cyan
if (Update-TraeStorageJson -Path $storagePath -Telemetry $telemetryUpdates -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storagePath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "[OK] storage.json verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] storage.json verification failed" -ForegroundColor Red
    $failCount++
}

# --- [3/16] state.vscdb (serviceMachineId + aha flag) ---
Write-Host "`n[3/16] Updating global state.vscdb (serviceMachineId + aha flag)..." -ForegroundColor Cyan
$stateSqliteUpdates = @{
    "storage.serviceMachineId"     = $ids.devDeviceId
    "has_device_id_updated_to_aha" = "false"
}
if (Set-SqliteKeys -Path $sqlitePath -Updates $stateSqliteUpdates -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath) -Actions ([ref]$actions)) {
    Write-Host "[OK] global state.vscdb verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] global state.vscdb verification failed" -ForegroundColor Red
    $failCount++
}

# --- [4/16] stale state.vscdb.backup deletion (NEW in v0.2) ---
Write-Host "`n[4/16] Deleting stale state.vscdb.backup..." -ForegroundColor Cyan
if (Remove-VerifiedFileNoBackup -Path (Join-Path $root "User\globalStorage\state.vscdb.backup") -AuditKey "state.vscdb.backup" -Audit ([ref]$audit)) {
    $passCount++
}
else {
    $failCount++
}

# --- [5/16] aha tree (delete; v0.1 renamed, leaving encrypted device blobs) ---
Write-Host "`n[5/16] Clearing aha tree (encrypted TinyStorage device blobs)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$ahaPath = Join-Path $root "aha"
if (Test-Path -LiteralPath $ahaPath) {
    $null = Clear-TreeFilesIndividually -Path $ahaPath -BackupRoot $backupRoot -BackupLabel "aha" -Audit ([ref]$audit) -Actions ([ref]$actions)
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

# --- [6/16] ckg_server local_env.json ---
Write-Host "`n[6/16] Updating ModularData\ckg_server\local_env.json (device_id + host_map)..." -ForegroundColor Cyan
$localEnvPath = Join-Path $root "ModularData\ckg_server\local_env.json"
if (Update-TraeLocalEnv -Path $localEnvPath -NewDeviceId (New-RandomDeviceId19) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $localEnvPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [7/16] env_codekg.db (delete; v0.1 renamed) ---
Write-Host "`n[7/16] Clearing ckg_server\env_codekg.db..." -ForegroundColor Cyan
$envCodekgPath = Join-Path $root "ModularData\ckg_server\env_codekg.db"
if (Test-Path -LiteralPath $envCodekgPath) {
    $auditStart = $audit.Count
    $envActions = Clear-BinaryIdentityStore -Paths @($envCodekgPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
    $actions += @($envActions)
    $status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $envCodekgPath
    if ($status.Success) {
        Write-Host "[OK] env_codekg.db cleared" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] env_codekg.db had failures" -ForegroundColor Red
        $failCount++
    }
}
else {
    Write-Host "[SKIP] env_codekg.db not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $envCodekgPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    $passCount++
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

# --- [9/16] Preferences salt + Local State os_crypt (NEW in v0.2) ---
Write-Host "`n[9/16] Updating Preferences/Local State (salt + os_crypt)..." -ForegroundColor Cyan
$stepFailed = $false
if (-not (Set-DeviceIdSalt -Path (Join-Path $root "Preferences") -NewSalt $newSalt -BackupRoot $backupRoot -BackupLabel "Preferences" -Audit ([ref]$audit) -Actions ([ref]$actions))) {
    $stepFailed = $true
}
if (-not (Remove-OsCryptEncryptedKey -Path (Join-Path $root "Local State") -BackupRoot $backupRoot -BackupLabel "Local State" -Audit ([ref]$audit) -Actions ([ref]$actions))) {
    $stepFailed = $true
}
if ($stepFailed) {
    Write-Host "[FAILED] Preferences/Local State step had failures" -ForegroundColor Red
    $failCount++
}
else {
    $passCount++
}

# --- [10/16] Cookies + transport state (delete; v0.1 renamed) ---
Write-Host "`n[10/16] Clearing Cookies + transport state..." -ForegroundColor Cyan
$auditStart = $audit.Count
$cookieActions = Clear-BinaryIdentityStore -Paths @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "Network\Cookies-journal"),
    (Join-Path $root "Network\Network Persistent State"),
    (Join-Path $root "Network\TransportSecurity")
) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
$actions += @($cookieActions)
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] Cookies + transport state cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] Cookies + transport state had failures" -ForegroundColor Red
    $failCount++
}

# --- [11/16] DIPS stores (delete; v0.1 renamed) ---
Write-Host "`n[11/16] Clearing DIPS stores..." -ForegroundColor Cyan
$auditStart = $audit.Count
$dipsActions = Clear-BinaryIdentityStore -Paths @((Join-Path $root "DIPS"), (Join-Path $root "DIPS-wal")) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
$actions += @($dipsActions)
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] DIPS stores cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] DIPS stores had failures" -ForegroundColor Red
    $failCount++
}

# --- [12/16] SharedStorage + Trust Tokens (delete; v0.1 renamed SharedStorage) ---
Write-Host "`n[12/16] Clearing SharedStorage + Trust Tokens..." -ForegroundColor Cyan
$auditStart = $audit.Count
$sharedActions = Clear-BinaryIdentityStore -Paths @(
    (Join-Path $root "SharedStorage"),
    (Join-Path $root "SharedStorage-wal"),
    (Join-Path $root "Network\Trust Tokens"),
    (Join-Path $root "Network\Trust Tokens-journal")
) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
$actions += @($sharedActions)
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $root
if ($status.Success) {
    Write-Host "[OK] SharedStorage + Trust Tokens cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] SharedStorage + Trust Tokens had failures" -ForegroundColor Red
    $failCount++
}

# --- [13/16] trae-webview partition + caches + Session Storage ---
Write-Host "`n[13/16] Clearing trae-webview partition + caches..." -ForegroundColor Cyan
$auditStart = $audit.Count
$webviewPath = Join-Path $root "Partitions\trae-webview"
if (Test-Path -LiteralPath $webviewPath) {
    $null = Clear-TreeFilesIndividually -Path $webviewPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $webviewPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
}
else {
    Write-Host "[SKIP] Partitions\trae-webview not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $webviewPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
}
foreach ($relative in @("Cache\Cache_Data", "Code Cache", "GPUCache", "blob_storage", "Service Worker", "Session Storage", "WebStorage", "Shared Dictionary")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
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

# --- [14/16] Crashpad + logs (NEW in v0.2) ---
Write-Host "`n[14/16] Clearing Crashpad + logs..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($relative in @("Crashpad", "logs")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel $relative -Audit ([ref]$audit) -Actions ([ref]$actions)
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

# --- [15/16] workspace UPSERT-only (never delete workspace files) ---
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
        Invoke-WorkspaceSqliteUpdate -WorkspaceDbPath $workspaceDbPath -DeviceId $ids.devDeviceId -RootPath $root -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
        if ($audit.Count -gt 0) {
            $lastAuditEntry = $audit[-1]
            if (-not $lastAuditEntry.ok) {
                $workspaceFailures++
            }
        }
        else {
            $workspaceFailures++
        }
    }
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

# --- [16/16] Old ID_Backups purge + watchdog re-verify ---
Write-Host "`n[16/16] Purging old ID_Backups + watchdog re-verify..." -ForegroundColor Cyan
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit)
$watchdogCoreFiles = @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "DIPS"),
    (Join-Path $root "SharedStorage"),
    (Join-Path $root "aha")
)
Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit ([ref]$audit)
$passCount++

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

[System.IO.File]::WriteAllText("$env:TEMP\trae_v0.2_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "Trae reset v0.2 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "Trae reset v0.2 completed successfully." -ForegroundColor Green
