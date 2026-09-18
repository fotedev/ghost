# ZCode / Qoder Identity Reset v1.4
#
# v1.4 adds multi-instance targeting (Primary / Secondary / Both) on top of v1.3:
#   - -Target Primary   -> %APPDATA%\ZCode + %USERPROFILE%\.zcode only
#   - -Target Secondary -> %APPDATA%\ZCode-Second + %USERPROFILE%\ZCodeSecondHome\.zcode only
#   - -Target Both      -> orchestrates two independent child runs (Secondary first,
#                          then Primary incl. Qoder), each with its OWN fresh ID set.
#     Dual-identity rule: Both mode NEVER duplicates IDs across instances.
#   - Single-target mode uses selective PID-tree killing (CommandLine
#     --user-data-dir inspection) so the survivor instance keeps running.
#     v1.3 killed every ZCode* process unconditionally.
#   - Backups (ID_Backups), watchdog probes and final validation are scoped
#     strictly per-target. v1.3 is kept intact for rollback.
#   - -SkipQoder is internal (used by the Both orchestrator so Qoder steps run
#     exactly once, in the Primary child).
#
# v1.3 adds telemetry.macMachineId to $storageUpdates (was 3 keys, now 4 --
# Cursor/Windsurf/Trae/Qoder all rotate 4; the missing key was a cross-IDE
# correlation remnant).
# v1.2 adds step [6b/27]: strip ALL provider apiKey values from
# .zcode\v2\config.json (the model-account link lives there, not in
# credentials.json -- without this, Unlink loops: Checking -> Unlink ->
# Checking because the app re-reads the keys on every re-check).
#
# Fresh build combining reset_zcode_windows-v1.0.ps1 targets with the
# robustness features of reset_qoder_windows-v0.3.ps1:
#   - Self-elevation to Administrator (auto re-launch, no manual "run as admin")
#   - Aggressive multi-process kill (ZCode/Qoder + extension helpers, 2 clean checks)
#   - Watchdog re-verify (slow-shutdown helpers can recreate files post-wipe)
#   - Missing-target coverage (SharedStorage, CORS_Profile, embedded-browser extras)
#   - Old ID_Backups purge (keep current run only)
#   - Reparse-point-safe .qoder subdir cleanup (never follow symlinks)
#   - Account unlink (config.json provider apiKeys blanked; originals in backup)
#
# PRESERVATION GUARANTEES (chat history + workspaces are never wiped):
#   - .zcode\v2\tasks-index.sqlite* (+ shm/wal), checkpoints\, cli\artifacts\,
#     cli\rollout\, cli\log\ are never touched.
#   - ZCode session IndexedDB\file__0.indexeddb.leveldb (chat webview data) preserved.
#   - Local Storage\leveldb preserved in every profile (UI state, no server signal).
#   - .zcode\v2\config.json structure and all non-key settings are preserved;
#     only provider.*.options.apiKey VALUES are blanked (restorable from backup,
#     re-entered on next login). No key value is ever written to the audit log
#     or console -- only cleared/remaining COUNTS.
#   - Qoder User\workspaceStorage\**: serviceMachineId is UPSERTED (avoids a
#     correlation remnant) but tables/files are NEVER deleted; stale workspace
#     .backup files are left alone per policy and audited as preserved.
#   - Qoder Backups\, .qoder\settings.json, .qoder\mcp.json, .qoder\memories\,
#     .qoder\canvas\, .qoder\knowledges\ are never touched.
#
# SCOPE ISOLATION: no MAC / hostname / registry-source steps here. Those belong
# strictly to change_device_id.ps1.
#
# ENCODING: every file write in this script uses
# [System.IO.File]::WriteAllText(..., UTF8Encoding($false)) -- no BOM.
# Set-Content -Encoding UTF8 emits a BOM under PowerShell 5.1 and corrupts
# Chromium/Electron JSON(C) parsers.
#
# PS 5.1 COMPAT: no [CmdletBinding()] (keeps `*>` log redirect working),
# no ternary, no $Input variable, RandomNumberGenerator via .GetBytes() only.
#
# Usage (Windows 10, PowerShell 5.1 or 7 -- just double-click or run):
#   powershell -ExecutionPolicy Bypass -File reset_zcode_windows-v1.4.ps1 [-Target Primary|Secondary|Both]
# Prerequisite: the TARGET instance is force-killed by the script; the survivor
# instance (in Single mode) is intentionally left running.
# Requirement: Python (python or python3) for SQLite writes; steps that need it
# FAIL honestly when it is missing.
# NOTE: change_device_id.ps1 is machine-wide (MAC/hostname/registry) and affects
# BOTH ZCode instances + Qoder by design. This script is app-data-only.

param(
    [ValidateSet('Primary', 'Secondary', 'Both')][string]$Target = 'Both',
    [switch]$SkipQoder
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
# Re-launch elevated with the same script path when not already admin.
# Forwards -Target / -SkipQoder so child runs keep their scope after UAC.
$zcodeIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $zcodeIsAdmin) {
    $zcodeLogOut = "$env:TEMP\zcode_v1.4_result.log"
    $zcodeScript = $MyInvocation.MyCommand.Path
    $zcodeFwd = " -Target $Target"
    if ($SkipQoder) { $zcodeFwd += " -SkipQoder" }
    $zcodeArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$zcodeScript`"$zcodeFwd *> `"$zcodeLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $zcodeArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath $zcodeLogOut) {
        Get-Content -LiteralPath $zcodeLogOut
    }
    if (Test-Path -LiteralPath "$env:TEMP\zcode_v1.3_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\zcode_v1.3_done.txt"
    }
    exit
}

Write-GhostBanner -Target "ZCode/Qoder Identity Reset [$Target]" -Version "1.4"

# === Local helpers (mirroring the Cursor reference pattern) ===================

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

# %USERPROFILE%-level files (.zcode / .qoder) sit outside %APPDATA%. Label them
# under a USERPROFILE\ subtree so the restore script rehydrates correctly.
function Get-UserProfileBackupLabel {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    if ($TargetPath.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path "USERPROFILE" ($TargetPath.Substring($env:USERPROFILE.Length).TrimStart("\"))
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

    # No-BOM UTF-8. Set-Content -Encoding UTF8 emits a BOM on PS 5.1.
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

# DELETE auth-secret keys from state.vscdb ItemTable and verify survivors are
# zero via read-only reopen. Parameterized ? placeholders only. Temp .py goes
# to $env:TEMP (never next to the DB) and is written without BOM.
function Clear-SecretsFromSqlite {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] secrets DB not found: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After "python-not-found" -Ok $false
        Write-Host "    [FAILED] Python not found -- secrets deletion SKIPPED: $Path" -ForegroundColor Red
        return $false
    }

    $tempScriptPath = Join-Path $env:TEMP ("sqlite_delete_secrets_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @'
import sqlite3
import json
import sys

db_path = sys.argv[1]
deleted = []

patterns = ("secret://aicoding.auth.%", "secret://blackbox.%")
target_keys = ("gituser",)

conn = sqlite3.connect(db_path)
try:
    cursor = conn.cursor()
    for pattern in patterns:
        cursor.execute("SELECT key FROM ItemTable WHERE key LIKE ?", (pattern,))
        for row in cursor.fetchall():
            key = row[0]
            cursor.execute("DELETE FROM ItemTable WHERE key = ?", (key,))
            deleted.append(key)
    for key in target_keys:
        cursor.execute("DELETE FROM ItemTable WHERE key = ?", (key,))
        deleted.append(key)
    conn.commit()
finally:
    conn.close()

verify_conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
try:
    verify_cursor = verify_conn.cursor()
    survivors = []
    for pattern in patterns:
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?", (pattern,))
        survivors.append(verify_cursor.fetchone()[0])
    for key in target_keys:
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key = ?", (key,))
        survivors.append(verify_cursor.fetchone()[0])
finally:
    verify_conn.close()

print(json.dumps({"deleted": deleted, "survivors": survivors}))
'@

    try {
        [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, (New-Object System.Text.UTF8Encoding $false))
        $commandOutput = & $pythonCommand.Source $tempScriptPath $Path
        if ($LASTEXITCODE -ne 0) {
            Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After "failed" -Ok $false
            Write-Host "    [FAILED] secrets deletion command failed: $Path" -ForegroundColor Red
            return $false
        }

        $result = ($commandOutput -join "`n") | ConvertFrom-Json
        $survivorTotal = ($result.survivors | Measure-Object -Sum).Sum
        $ok = ($survivorTotal -eq 0)
        $deletedCount = $result.deleted.Count
        if ($ok) {
            Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After ("deleted " + $deletedCount) -Ok $true
            Write-Host "    [OK] secrets deleted: $deletedCount keys from $Path" -ForegroundColor Green
        }
        else {
            Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After ("survivors=" + $survivorTotal) -Ok $false
            Write-Host "    [FAILED] secrets survivors remain: $survivorTotal in $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After "exception" -Ok $false
        Write-Host "    [FAILED] secrets deletion threw exception: $Path" -ForegroundColor Red
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Delete every file under $Path individually with retry, then prune empty dirs.
# A whole-tree Remove-Item fails FAST on the first locked file and leaves the
# rest intact; per-file delete means one stuck file cannot block the others.
# Appends a single restorable delete action (whole-tree backup) to $Actions.
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

# Delete a stale file WITHOUT backing it up (used for *.backup sidecars and
# similar regenerable files). Verifies the path is gone afterwards.
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

# Reparse-point-safe removal for user-level dirs (.qoder\extensions may be a
# symlink/junction to VS Code extensions on older installs). Removes the link
# itself without following it; real Qoder-owned dirs go through the restorable
# delete path. Never touches the link target.
function Remove-AppPathSafely {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "user-subdir" -Before "missing" -After "skipped" -Ok $true
        return "missing"
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $isReparsePoint = $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    if ($isReparsePoint) {
        $linkType = if ($item.LinkType) { $item.LinkType } else { "ReparsePoint" }
        $target = if ($item.Target) { $item.Target } else { "<unknown>" }
        Write-Host "    [LINK] $Path ($linkType -> $target) -- removing link only" -ForegroundColor DarkGray
        $item.Delete()
        Add-AuditEntry -Audit $Audit -File $Path -Key "user-subdir" -Before ("$linkType->$target") -After "link-removed" -Ok $true
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -Action "delete"
        return "link-removed"
    }

    $binaryActions = Clear-BinaryIdentityStore -Paths @($Path) -Action "delete" -BackupRoot $BackupRoot -Audit $Audit -RootPath $env:USERPROFILE
    $Actions.Value += @($binaryActions)
    return "deleted"
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

function Set-RumElectronStore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewUid,
        [Parameter(Mandatory = $true)][string]$NewSession,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "rum-electron-store" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] rum-electron-store not found: $Path" -ForegroundColor Yellow
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
        Add-AuditEntry -Audit $Audit -File $Path -Key "rum-electron-store" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse rum-electron-store: $Path" -ForegroundColor Red
        return $false
    }

    $beforeUid = if ($null -ne $content.PSObject.Properties['_arms_uid']) { $content._arms_uid } else { $null }
    $beforeSession = if ($null -ne $content.PSObject.Properties['_arms_session']) { $content._arms_session } else { $null }

    if ($null -eq $content.PSObject.Properties['_arms_uid']) {
        Add-Member -InputObject $content -NotePropertyName '_arms_uid' -NotePropertyValue $NewUid
    }
    else {
        $content._arms_uid = $NewUid
    }

    if ($null -eq $content.PSObject.Properties['_arms_session']) {
        Add-Member -InputObject $content -NotePropertyName '_arms_session' -NotePropertyValue $NewSession
    }
    else {
        $content._arms_session = $NewSession
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $uidOk = $verified._arms_uid -eq $NewUid
        $sessionOk = $verified._arms_session -eq $NewSession
        Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_uid" -Before $beforeUid -After $verified._arms_uid -Ok $uidOk
        Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_session" -Before $beforeSession -After $verified._arms_session -Ok $sessionOk
        if ($uidOk -and $sessionOk) {
            Write-Host "    [OK] RUM telemetry updated: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] RUM telemetry verification failed: $Path" -ForegroundColor Red
        }
        return ($uidOk -and $sessionOk)
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_uid" -Before $beforeUid -After "verify-failed" -Ok $false
        Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_session" -Before $beforeSession -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read rum-electron-store after write: $Path" -ForegroundColor Red
        return $false
    }
}

function Set-WebRemoteControlDeviceSid {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewSid,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "webRemoteControlExternalRelayDevice.deviceSid" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] setting.json not found: $Path" -ForegroundColor Yellow
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
        Add-AuditEntry -Audit $Audit -File $Path -Key "webRemoteControlExternalRelayDevice.deviceSid" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse setting.json: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValue = $null
    $deviceProp = $null
    if ($null -ne $content.PSObject.Properties['webRemoteControlExternalRelayDevice']) {
        $deviceProp = $content.webRemoteControlExternalRelayDevice
        if ($null -ne $deviceProp.PSObject.Properties['deviceSid']) {
            $beforeValue = $deviceProp.deviceSid
            $content.webRemoteControlExternalRelayDevice.deviceSid = $NewSid
        }
        else {
            Add-Member -InputObject $deviceProp -NotePropertyName 'deviceSid' -NotePropertyValue $NewSid
        }
    }
    else {
        Add-Member -InputObject $content -NotePropertyName 'webRemoteControlExternalRelayDevice' -NotePropertyValue @{ deviceSid = $NewSid }
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $actualValue = $verified.webRemoteControlExternalRelayDevice.deviceSid
        $ok = $actualValue -eq $NewSid
        Add-AuditEntry -Audit $Audit -File $Path -Key "webRemoteControlExternalRelayDevice.deviceSid" -Before $beforeValue -After $actualValue -Ok $ok
        if ($ok) {
            Write-Host "    [OK] deviceSid updated: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] deviceSid verification failed: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "webRemoteControlExternalRelayDevice.deviceSid" -Before $beforeValue -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read setting.json after write: $Path" -ForegroundColor Red
        return $false
    }
}

function Clear-ZcodeOAuthCredentials {
    param(
        [Parameter(Mandatory = $true)][string]$CredentialsPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $CredentialsPath)) {
        Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] credentials.json not present: $CredentialsPath" -ForegroundColor Yellow
        return $true
    }

    $backupLabel = Get-PathBackupLabel -Path $CredentialsPath
    $backupPath = Backup-FileToTimestampDir -Source $CredentialsPath -BackupRoot $BackupRoot -Label $backupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $CredentialsPath -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse credentials.json: $CredentialsPath" -ForegroundColor Red
        return $false
    }

    if ($null -eq $content) {
        Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "null" -After "skipped" -Ok $true
        Write-Host "    [SKIP] credentials.json is null: $CredentialsPath" -ForegroundColor Yellow
        return $true
    }

    # Delete any key starting with 'oauth:' (covers oauth:zai:*, oauth:bigmodel:*,
    # oauth:active_provider, oauth:login_attribution, etc.) plus the long-lived
    # zcodejwttoken. Preserve unrelated keys such as zcodefeedbackclientid and
    # web-remote-control:external-relay:pass_hash.
    $keysToDelete = @()
    foreach ($prop in $content.PSObject.Properties) {
        if ($prop.Name.StartsWith("oauth:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $keysToDelete += $prop.Name
        }
        elseif ($prop.Name -ieq "zcodejwttoken") {
            $keysToDelete += $prop.Name
        }
    }
    $keysToDelete = $keysToDelete | Select-Object -Unique

    foreach ($key in $keysToDelete) {
        $null = $content.PSObject.Properties.Remove($key)
    }

    try {
        $oauthJson = $content | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($CredentialsPath, $oauthJson, (New-Object System.Text.UTF8Encoding $false))
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "present" -After "write-failed" -Ok $false
        Write-Host "    [FAILED] could not write credentials.json: $CredentialsPath" -ForegroundColor Red
        return $false
    }

    try {
        $verified = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "present" -After "verify-parse-failed" -Ok $false
        Write-Host "    [FAILED] could not re-parse credentials.json after write: $CredentialsPath" -ForegroundColor Red
        return $false
    }

    $remainingBanned = @()
    if ($null -ne $verified) {
        foreach ($prop in $verified.PSObject.Properties) {
            if ($prop.Name.StartsWith("oauth:", [System.StringComparison]::OrdinalIgnoreCase)) {
                $remainingBanned += $prop.Name
            }
            elseif ($prop.Name -ieq "zcodejwttoken") {
                $remainingBanned += $prop.Name
            }
        }
    }

    $ok = ($remainingBanned.Count -eq 0)
    $afterSummary = if ($ok) {
        "deleted $($keysToDelete.Count) oauth keys"
    }
    else {
        "remaining-banned: $($remainingBanned -join ',')"
    }
    Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "present" -After $afterSummary -Ok $ok

    if ($ok) {
        Write-Host "    [OK] credentials.json OAuth tokens cleared: $($keysToDelete.Count) keys removed" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] credentials.json still has banned keys: $afterSummary" -ForegroundColor Red
    }
    return $ok
}

# Blank every provider.*.options.apiKey value in .zcode\v2\config.json.
# The model-account link lives HERE (server-issued keys), not in
# credentials.json: clearing OAuth alone leaves the app re-reading these keys
# on every plan re-check, which is the Unlink -> Checking -> Unlink loop.
# Structure and all non-key settings are preserved; only apiKey VALUES are
# blanked. Audit/console record COUNTS only -- key values are never logged.
# No-BOM write. PS 5.1 compatible (no ternary, no $Input variable).
function Clear-ZcodeProviderApiKeys {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] config.json not present: $ConfigPath" -ForegroundColor Yellow
        return $true
    }

    $backupLabel = Get-UserProfileBackupLabel -TargetPath $ConfigPath
    $backupPath = Backup-FileToTimestampDir -Source $ConfigPath -BackupRoot $BackupRoot -Label $backupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $ConfigPath -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse config.json: $ConfigPath" -ForegroundColor Red
        return $false
    }

    if (($null -eq $content) -or ($null -eq $content.PSObject.Properties['provider'])) {
        Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "no-providers" -After "skipped" -Ok $true
        Write-Host "    [SKIP] no providers section in: $ConfigPath" -ForegroundColor Yellow
        return $true
    }

    $clearedCount = 0
    foreach ($prop in $content.provider.PSObject.Properties) {
        if (($null -ne $prop.Value) -and ($null -ne $prop.Value.PSObject.Properties['options']) -and
            ($null -ne $prop.Value.options.PSObject.Properties['apiKey'])) {
            if ($prop.Value.options.apiKey -ne '') {
                $clearedCount++
            }
            $prop.Value.options.apiKey = ''
        }
    }

    try {
        [System.IO.File]::WriteAllText($ConfigPath, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "present" -After "write-failed" -Ok $false
        Write-Host "    [FAILED] could not write config.json: $ConfigPath" -ForegroundColor Red
        return $false
    }

    try {
        $verified = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "present" -After "verify-parse-failed" -Ok $false
        Write-Host "    [FAILED] could not re-parse config.json after write: $ConfigPath" -ForegroundColor Red
        return $false
    }

    $remainingCount = 0
    if (($null -ne $verified) -and ($null -ne $verified.provider)) {
        foreach ($prop in $verified.provider.PSObject.Properties) {
            if (($null -ne $prop.Value) -and ($null -ne $prop.Value.PSObject.Properties['options']) -and
                ($null -ne $prop.Value.options.PSObject.Properties['apiKey']) -and
                ($prop.Value.options.apiKey -ne '')) {
                $remainingCount++
            }
        }
    }

    $ok = ($remainingCount -eq 0)
    $afterSummary = if ($ok) {
        "cleared $clearedCount keys"
    }
    else {
        "remaining-nonempty: $remainingCount"
    }
    Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "present" -After $afterSummary -Ok $ok

    if ($ok) {
        Write-Host "    [OK] config.json provider apiKeys cleared: $clearedCount keys blanked" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] config.json still has non-empty apiKeys: $afterSummary" -ForegroundColor Red
    }
    return $ok
}

# argv.json is JSONC (comments allowed) -- ConvertFrom-Json cannot parse it, so
# regex-replace just the crash-reporter-id value and preserve every comment and
# other field verbatim. No-BOM write. If the key is absent, insert it before
# the final closing brace.
function Update-ArgvJsonCrashReporterId {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewCrashReporterId,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] argv.json not present: $Path" -ForegroundColor Yellow
        return $true
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    $before = $null
    $beforeMatch = [regex]::Match($raw, '"crash-reporter-id"\s*:\s*"([^"]+)"')
    if ($beforeMatch.Success) {
        $before = $beforeMatch.Groups[1].Value
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $pattern = '"crash-reporter-id"\s*:\s*"[^"]+"'
    $replacement = '"crash-reporter-id": "' + $NewCrashReporterId + '"'
    if ([regex]::IsMatch($raw, $pattern)) {
        $newRaw = [regex]::Replace($raw, $pattern, $replacement)
    }
    else {
        $trimmed = $raw.TrimEnd()
        if ($trimmed.EndsWith("}")) {
            $newRaw = $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd()
            if ($newRaw.EndsWith("{")) {
                $newRaw = $newRaw + "`n  " + $replacement + "`n}"
            }
            else {
                $newRaw = $newRaw.TrimEnd(",") + ",`n  " + $replacement + "`n}"
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $before -After "unparseable" -Ok $false
            Write-Host "    [FAILED] argv.json has no JSON object to extend: $Path" -ForegroundColor Red
            return $false
        }
    }

    [System.IO.File]::WriteAllText($Path, $newRaw, (New-Object System.Text.UTF8Encoding $false))

    $verifyRaw = Get-Content -LiteralPath $Path -Raw
    $verifyMatch = [regex]::Match($verifyRaw, '"crash-reporter-id"\s*:\s*"([^"]+)"')
    $verified = if ($verifyMatch.Success) { $verifyMatch.Groups[1].Value } else { $null }

    $ok = ($verified -eq $NewCrashReporterId)
    Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $before -After $verified -Ok $ok
    if ($ok) {
        Write-Host "    [OK] argv.json crash-reporter-id updated" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] argv.json crash-reporter-id verification failed" -ForegroundColor Red
    }
    return $ok
}

# === v1.1 robustness helpers (ported from reset_qoder_windows-v0.3.ps1, kept in v1.2/v1.3) ========

# Aggressive tree-kill for ZCode/Qoder plus known extension helpers that hold
# file handles (verified: kilo.exe kept a log file locked as an orphan process).
# Requires 2 consecutive clean checks; hard-fails the run when unkillable.
function Stop-ZcodeQoderProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all ZCode/Qoder + extension-helper processes (aggressive tree-kill)..." -ForegroundColor Cyan

    $processesToKill = @(
        "ZCode",
        "ZCode Helper",
        "Qoder",
        "Qoder Helper",
        "Qoder Helper (GPU)",
        "Qoder Helper (Renderer)",
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

        $zcodeRemaining = @(Get-Process -Name "ZCode*" -ErrorAction SilentlyContinue)
        $qoderRemaining = @(Get-Process -Name "Qoder*" -ErrorAction SilentlyContinue)
        $helperRemaining = 0
        foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
            $helperRemaining += @(Get-Process -Name $helperName -ErrorAction SilentlyContinue).Count
        }
        $count = $zcodeRemaining.Count + $qoderRemaining.Count + $helperRemaining
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all ZCode/Qoder + extension-helper processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($p in @(Get-Process -Name "ZCode*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    ZCode PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($p in @(Get-Process -Name "Qoder*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    Qoder PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
        foreach ($p in @(Get-Process -Name $helperName -ErrorAction SilentlyContinue)) {
            Write-Host ("    $helperName PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
        }
    }
    return $false
}

# Qoder keeps a second Chromium-style profile under <root>\CORS_Profile\.
# Resetting only the main profile leaves it fully intact with its own machineid,
# telemetry IDs, Cookies and state.vscdb secrets. Returns @(<root>[, CORS]).
function Get-QoderProfileRoots {
    param([Parameter(Mandatory = $true)][string]$MainRoot)

    $roots = @($MainRoot)
    $corsRoot = Join-Path $MainRoot "CORS_Profile"
    if (Test-Path -LiteralPath $corsRoot) {
        $roots += $corsRoot
    }
    return $roots
}

function Get-ProfileLabel {
    param(
        [Parameter(Mandatory = $true)][string]$MainRoot,
        [Parameter(Mandatory = $true)][string]$ProfileRoot
    )

    if ($ProfileRoot.Equals($MainRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "main"
    }
    return Split-Path -Leaf $ProfileRoot
}

# Post-reset watchdog probe: a slow-shutdown helper can recreate core identity
# files within seconds of deletion. Re-delete with a WARN audit entry (the
# reset itself already succeeded, so this never FAILs the run).
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

# Old ID_Backups directories preserve complete snapshots of every identity file
# with the OLD IDs still embedded. Keep the current run only; delete the rest.
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

# === v1.4 multi-instance helpers (selective targeting) ==========================

# Resolve the roaming + userprofile roots for a ZCode instance label.
function Get-ZcodeTargetRoots {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Primary', 'Secondary')][string]$Label
    )

    if ($Label -eq 'Secondary') {
        return @{
            Label       = 'Secondary'
            Roaming     = Join-Path $env:APPDATA 'ZCode-Second'
            UserProfile = Join-Path $env:USERPROFILE 'ZCodeSecondHome\.zcode'
        }
    }
    return @{
        Label       = 'Primary'
        Roaming     = Join-Path $env:APPDATA 'ZCode'
        UserProfile = Join-Path $env:USERPROFILE '.zcode'
    }
}

# Classify ZCode MAIN PIDs by instance using descendant CommandLines.
# A main is ONLY a bare-exe process (CommandLine == just "...ZCode.exe", no
# args). Helpers (glm app-server, plugin-host, cua-helper --socket, --type=*)
# all carry extra args and must NOT be treated as mains -- v1.4 pre-release
# dry-run caught this (--type filter alone misclassified 12 helpers as mains).
# A main whose subtree contains 'ZCode-Second' or 'ZCodeSecondHome' is Secondary;
# any other ZCode main is Primary. Returns @{ Primary = @(pids); Secondary = @(pids) }.
function Get-ZcodeTargetMains {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ZCode.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @{ Primary = @(); Secondary = @() } }

    $byParent = @{}
    foreach ($p in $procs) {
        $ppid = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $p
    }

    $mains = @($procs | Where-Object {
        $cmd = ([string]$_.CommandLine).Trim()
        # Empty CommandLine is a known WMI race on fresh mains: keep them as
        # candidates (subtree walk below still classifies them correctly).
        ([string]::IsNullOrWhiteSpace($cmd)) -or
        ($cmd -match '^"[^"]*ZCode\.exe"$') -or ($cmd -match '^[A-Za-z]:\\[^\s"]*ZCode\.exe$')
    })
    $primary = @()
    $secondary = @()
    foreach ($m in $mains) {
        $seen = @{}
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([int]$m.ProcessId) | Out-Null
        $isSecondary = $false
        while ($queue.Count -gt 0) {
            $pid = $queue.Dequeue()
            if ($seen.ContainsKey($pid)) { continue }
            $seen[$pid] = $true
            if ($byParent.ContainsKey($pid)) {
                foreach ($c in $byParent[$pid]) {
                    $cmd = [string]$c.CommandLine
                    if (($cmd -like '*ZCode-Second*') -or ($cmd -like '*ZCodeSecondHome*')) { $isSecondary = $true; break }
                    $queue.Enqueue([int]$c.ProcessId) | Out-Null
                }
            }
            if ($isSecondary) { break }
        }
        if ($isSecondary) { $secondary += [int]$m.ProcessId } else { $primary += [int]$m.ProcessId }
    }
    return @{ Primary = $primary; Secondary = $secondary }
}

# Selective tree-kill for ONE ZCode instance. Kills only target mains (+ whole
# subtree via /T, covering glm/cua-helper/plugin-host children that carry no
# user-data-dir flag themselves). Shared Qoder helpers are never touched here.
# Returns $true when the target is gone across 2 consecutive checks AND (when
# requested) the survivor mains still exist.
function Stop-ZcodeTargetTree {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Primary', 'Secondary')][string]$Label,
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500,
        [switch]$RequireSurvivor
    )

    Write-Host "[*] Terminating ZCode $Label instance tree only (survivor preserved)..." -ForegroundColor Cyan
    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $map = Get-ZcodeTargetMains
        $targets = @($map[$Label])
        foreach ($pid in $targets) {
            $null = & taskkill /F /T /PID $pid 2>&1
        }
        Start-Sleep -Milliseconds $DelayMs
        $map = Get-ZcodeTargetMains
        $remaining = @($map[$Label]).Count
        $survivors = @($map[$(if ($Label -eq 'Primary') { 'Secondary' } else { 'Primary' })]).Count
        Write-Host ("    attempt {0}/{1} - target remaining: {2}, survivor mains: {3}" -f $attempt, $MaxAttempts, $remaining, $survivors) -ForegroundColor DarkGray
        if ($remaining -eq 0) {
            if ($RequireSurvivor -and ($survivors -eq 0)) {
                Write-Host "[WARN] target is gone but the survivor instance is also gone!" -ForegroundColor Yellow
                $consecutiveClean = 0
            }
            else {
                $consecutiveClean++
                if ($consecutiveClean -ge 2) {
                    Write-Host "[OK] ZCode $Label tree terminated (2 clean checks); survivor mains: $survivors" -ForegroundColor Green
                    return $true
                }
            }
        }
        else { $consecutiveClean = 0 }
    }
    Write-Host "[FAILED] ZCode $Label tree still running after $MaxAttempts attempts. Aborting." -ForegroundColor Red
    return $false
}

# === Main =====================================================================

Assert-Administrator

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$qoderRoaming = Join-Path $env:APPDATA "Qoder"
$qoderUserProfile = Join-Path $env:USERPROFILE ".qoder"
$qoderIdBackupsRoot = Join-Path $qoderRoaming "ID_Backups"

# --- v1.4 target resolution ---------------------------------------------------
# Both mode orchestrates two INDEPENDENT child runs (Secondary first with
# -SkipQoder so Qoder steps execute exactly once, in the Primary child).
# Each child generates its OWN fresh ID set -> dual-identity rule holds.
if ($Target -eq 'Both') {
    $v14Script = $MyInvocation.MyCommand.Path
    Write-Host "=== ZCode Identity Reset v1.4 (Both: independent IDs per instance) ===" -ForegroundColor Cyan
    Write-Host "[Both 1/2] Resetting Secondary instance (Qoder steps skipped)..." -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File $v14Script -Target Secondary -SkipQoder
    $secondaryCode = $LASTEXITCODE
    Write-Host "[Both 2/2] Resetting Primary instance (incl. Qoder)..." -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File $v14Script -Target Primary
    $primaryCode = $LASTEXITCODE
    Write-Host "`n=== Both-mode summary ===" -ForegroundColor Cyan
    Write-Host ("Secondary exit: {0}" -f $secondaryCode) -ForegroundColor Gray
    Write-Host ("Primary exit:   {0}" -f $primaryCode) -ForegroundColor Gray
    Write-Host "NOTE: IDs were generated independently per instance (never duplicated)." -ForegroundColor Yellow
    Write-Host "NOTE: change_device_id.ps1 is machine-wide and affects BOTH instances + Qoder." -ForegroundColor Yellow
    if (($secondaryCode -ne 0) -or ($primaryCode -ne 0)) { exit 1 }
    exit 0
}

$targetRoots = Get-ZcodeTargetRoots -Label $Target
$zcodeRoaming = $targetRoots.Roaming
$zcodeUserProfile = $targetRoots.UserProfile
$backupRoot = Join-Path $zcodeRoaming ("ID_Backups\" + $timestamp)
$zcodeIdBackupsRoot = Join-Path $zcodeRoaming "ID_Backups"
$audit = @()
$actions = @()
$ids = New-IdentitySet

if (-not (Test-Path -LiteralPath $zcodeRoaming)) {
    Write-Host "ZCode $Target instance not found at: $zcodeRoaming" -ForegroundColor Red
    Write-Host "Hint: launch it once via Launch-ZCode-Second.bat (Secondary) or ZCode.exe (Primary)." -ForegroundColor Yellow
    exit 1
}

$qoderPresent = Test-Path -LiteralPath $qoderRoaming
$qoderProfiles = @()
if ($qoderPresent) {
    $qoderProfiles = @(Get-QoderProfileRoots -MainRoot $qoderRoaming)
}
if ($SkipQoder) {
    # Secondary child in Both mode: Qoder belongs to the Primary run only.
    $qoderPresent = $false
    $qoderProfiles = @()
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== ZCode / Qoder Identity Reset v1.4 (Target: $Target) ===" -ForegroundColor Cyan
Write-Host "ZCode ${Target}: $zcodeRoaming" -ForegroundColor Gray
Write-Host "ZCode data: $zcodeUserProfile" -ForegroundColor Gray
if ($qoderPresent) {
    Write-Host ("Qoder profiles: " + (($qoderProfiles | ForEach-Object { Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $_ }) -join ", ")) -ForegroundColor Gray
}
else {
    if ($SkipQoder) { Write-Host "Qoder: skipped for this target (handled by Primary run)" -ForegroundColor Yellow }
    else { Write-Host "Qoder: not installed (Qoder steps will SKIP)" -ForegroundColor Yellow }
}
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: chat history + workspaces preserved; no MAC/hostname/registry steps" -ForegroundColor Gray
Write-Host "NOTE: change_device_id.ps1 is machine-wide and affects BOTH instances + Qoder." -ForegroundColor Yellow

# Pre-step: scoped tree-kill. Single-target mode kills ONLY the target ZCode
# tree (survivor keeps running). Qoder + shared helpers are killed only when
# the Primary target needs its Qoder steps; Secondary never touches them.
if ($Target -eq 'Secondary') {
    if (-not (Stop-ZcodeTargetTree -Label Secondary -RequireSurvivor)) {
        exit 1
    }
}
else {
    if (-not (Stop-ZcodeQoderProcessesAggressive)) {
        exit 1
    }
}

$passCount = 0
$failCount = 0

$newDeviceMid = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newUpdaterId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newSalt = -join ((1..32) | ForEach-Object { "{0:X}" -f (Get-Random -Maximum 16) })
$newDeviceIdSaltQoder = ([guid]::NewGuid().ToString("N")).ToUpperInvariant()
$newCrashReporterId = Get-NewCrashReporterId
$newArmsUid = "uid_" + (-join ((1..12) | ForEach-Object { "abcdefghijklmnopqrstuvwxyz0123456789"[(Get-Random -Maximum 36)] }))
$newArmsSession = "{0}-1-{1}-{1}" -f $newArmsUid.Substring(4), ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
$newDeviceSid = "d_" + (-join ((1..14) | ForEach-Object { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[(Get-Random -Maximum 62)] }))

$storageUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
    "telemetry.macMachineId" = $ids.macMachineId
}

# --- [1/27] Qoder storage.json telemetry IDs (per profile: main + CORS_Profile) ---
Write-Host "`n[1/27] Updating Qoder storage.json telemetry IDs (per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "telemetry.*" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "User\globalStorage\storage.json"
        if (Test-Path -LiteralPath $p) {
            if (Set-JsonIdentity -Path $p -Updates $storageUpdates -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Actions ([ref]$actions)) {
                Write-Host "    [$label] [OK] storage.json verified" -ForegroundColor Green
            }
            else {
                Write-Host "    [$label] [FAILED] storage.json verification failed" -ForegroundColor Red
                $stepFailed = $true
            }
        }
        else {
            Write-Host "    [$label] [SKIP] storage.json not present" -ForegroundColor Yellow
            Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "telemetry.*" -Before "missing" -After "skipped" -Ok $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [2/27] Qoder machineid (per profile) ---
Write-Host "`n[2/27] Updating Qoder machineid (per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "machineid" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "machineid"
        if (Test-Path -LiteralPath $p) {
            if (Set-VerifiedMachineIdFile -Path $p -Value $ids.devDeviceId -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
                Write-Host "    [$label] [OK] machineid verified" -ForegroundColor Green
            }
            else {
                Write-Host "    [$label] [FAILED] machineid verification failed" -ForegroundColor Red
                $stepFailed = $true
            }
        }
        else {
            Write-Host "    [$label] [SKIP] machineid not present" -ForegroundColor Yellow
            Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "machineid" -Before "missing" -After "skipped" -Ok $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [3/27] ZCode .updaterId ---
$zcodeUpdaterIdPath = Join-Path $zcodeRoaming ".updaterId"
Write-Host "`n[3/27] Updating ZCode .updaterId..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $zcodeUpdaterIdPath) {
    if (Set-VerifiedMachineIdFile -Path $zcodeUpdaterIdPath -Value $newUpdaterId -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $zcodeUpdaterIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
        Write-Host "[OK] .updaterId verified" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] .updaterId verification failed" -ForegroundColor Red
        $failCount++
    }
}
else {
    Write-Host "[SKIP] .updaterId not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeUpdaterIdPath -Key "updaterId" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}

# --- [4/27] ZCode telemetry-state.json deviceMid ---
$zcodeTelemetryStatePath = Join-Path $zcodeUserProfile "v2\telemetry-state.json"
Write-Host "`n[4/27] Updating ZCode telemetry-state.json (deviceMid)..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $zcodeTelemetryStatePath) {
    if (Set-JsonIdentity -Path $zcodeTelemetryStatePath -Updates @{ "deviceMid" = $newDeviceMid } -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $zcodeTelemetryStatePath) -Actions ([ref]$actions)) {
        Write-Host "[OK] telemetry-state.json verified" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] telemetry-state.json verification failed" -ForegroundColor Red
        $failCount++
    }
}
else {
    Write-Host "[SKIP] telemetry-state.json not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeTelemetryStatePath -Key "deviceMid" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}

# --- [5/27] ZCode credentials.json OAuth clear ---
$zcodeCredentialsPath = Join-Path $zcodeUserProfile "v2\credentials.json"
Write-Host "`n[5/27] Clearing ZCode OAuth credentials (oauth:* + zcodejwttoken)..." -ForegroundColor Cyan
if (Clear-ZcodeOAuthCredentials -CredentialsPath $zcodeCredentialsPath -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [6/27] ZCode coding-plan-cache.json invalidation ---
$zcodeCodingPlanCachePath = Join-Path $zcodeUserProfile "v2\coding-plan-cache.json"
Write-Host "`n[6/27] Invalidating ZCode coding-plan-cache.json..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $zcodeCodingPlanCachePath) {
    $cacheActions = Clear-BinaryIdentityStore -Paths @($zcodeCodingPlanCachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
    $actions += @($cacheActions)
    $status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex ($audit.Count - $cacheActions.Count) -Path $zcodeCodingPlanCachePath
    if ($status.Success) {
        Write-Host "[OK] coding-plan-cache.json invalidated" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] could not delete coding-plan-cache.json" -ForegroundColor Red
        $failCount++
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCodingPlanCachePath -Key "coding-plan-cache" -Before "missing" -After "skipped" -Ok $true
    Write-Host "[SKIP] coding-plan-cache.json not present" -ForegroundColor Yellow
    $passCount++
}

# --- [6b/27] ZCode config.json provider apiKeys strip (NEW in v1.2) ---
# Without this, the model-account link survives in config.json and the UI
# loops Unlink -> Checking -> Unlink. All providers are blanked (custom keys
# must be re-entered after reset); originals are in the backup.
$zcodeConfigPath = Join-Path $zcodeUserProfile "v2\config.json"
Write-Host "`n[6b/27] Stripping ZCode config.json provider apiKeys..." -ForegroundColor Cyan
if (Clear-ZcodeProviderApiKeys -ConfigPath $zcodeConfigPath -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [7/27] Qoder argv.json crash-reporter-id (JSONC, comments preserved) ---
$qoderArgvPath = Join-Path $qoderUserProfile "argv.json"
Write-Host "`n[7/27] Updating Qoder argv.json (crash-reporter-id)..." -ForegroundColor Cyan
if (Update-ArgvJsonCrashReporterId -Path $qoderArgvPath -NewCrashReporterId $newCrashReporterId -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $qoderArgvPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [8/27] Qoder state.vscdb serviceMachineId (per profile) ---
Write-Host "`n[8/27] Updating Qoder state.vscdb (serviceMachineId, per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "storage.serviceMachineId" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "User\globalStorage\state.vscdb"
        if (Test-Path -LiteralPath $p) {
            if (Set-SqliteKeys -Path $p -Updates @{ "storage.serviceMachineId" = $ids.devDeviceId } -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Actions ([ref]$actions)) {
                Write-Host "    [$label] [OK] state.vscdb verified" -ForegroundColor Green
            }
            else {
                Write-Host "    [$label] [FAILED] state.vscdb verification failed" -ForegroundColor Red
                $stepFailed = $true
            }
        }
        else {
            Write-Host "    [$label] [SKIP] state.vscdb not present" -ForegroundColor Yellow
            Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "storage.serviceMachineId" -Before "missing" -After "skipped" -Ok $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [9/27] Qoder state.vscdb auth secrets DELETE (per profile) ---
Write-Host "`n[9/27] Clearing Qoder state.vscdb auth secrets (per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "secrets-delete" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "User\globalStorage\state.vscdb"
        Write-Host "    [$label] scrubbing secrets..." -ForegroundColor DarkGray
        if (-not (Clear-SecretsFromSqlite -Path $p -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
            $stepFailed = $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [10/27] Qoder stale state.vscdb.backup deletion (per profile, no backup of backup) ---
Write-Host "`n[10/27] Deleting Qoder stale state.vscdb.backup files (per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "state.vscdb.backup" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "User\globalStorage\state.vscdb.backup"
        Write-Host "    [$label] stale backup..." -ForegroundColor DarkGray
        if (-not (Remove-VerifiedFileNoBackup -Path $p -AuditKey "state.vscdb.backup" -Audit ([ref]$audit))) {
            $stepFailed = $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [11/27] ZCode session Preferences device_id_salt ---
$zcodePreferencesPath = Join-Path $zcodeRoaming "session\Preferences"
Write-Host "`n[11/27] Updating ZCode session Preferences (device_id_salt)..." -ForegroundColor Cyan
if (Set-DeviceIdSalt -Path $zcodePreferencesPath -NewSalt $newSalt -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $zcodePreferencesPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [12/27] Qoder Preferences device_id_salt (per profile) ---
Write-Host "`n[12/27] Updating Qoder Preferences (device_id_salt, per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "electron.media.device_id_salt" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "Preferences"
        Write-Host "    [$label] device_id_salt..." -ForegroundColor DarkGray
        if (-not (Set-DeviceIdSalt -Path $p -NewSalt $newDeviceIdSaltQoder -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
            $stepFailed = $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [13/27] ZCode session Local State os_crypt rotation ---
$zcodeLocalStatePath = Join-Path $zcodeRoaming "session\Local State"
Write-Host "`n[13/27] Rotating ZCode session os_crypt.encrypted_key..." -ForegroundColor Cyan
if (Remove-OsCryptEncryptedKey -Path $zcodeLocalStatePath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $zcodeLocalStatePath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [14/27] Qoder Local State os_crypt rotation (per profile) ---
Write-Host "`n[14/27] Rotating Qoder os_crypt.encrypted_key (per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "os_crypt.encrypted_key" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $p = Join-Path $pr "Local State"
        Write-Host "    [$label] os_crypt..." -ForegroundColor DarkGray
        if (-not (Remove-OsCryptEncryptedKey -Path $p -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
            $stepFailed = $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [15/27] ZCode RUM electron store ---
$zcodeRumStorePath = Join-Path $zcodeRoaming "rum-electron-store\ZGVmYXVsdA.json"
Write-Host "`n[15/27] Updating ZCode RUM telemetry store..." -ForegroundColor Cyan
if (Set-RumElectronStore -Path $zcodeRumStorePath -NewUid $newArmsUid -NewSession $newArmsSession -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $zcodeRumStorePath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [16/27] ZCode setting.json deviceSid ---
$zcodeSettingJsonPath = Join-Path $zcodeUserProfile "v2\setting.json"
Write-Host "`n[16/27] Updating ZCode setting.json (deviceSid)..." -ForegroundColor Cyan
if (Set-WebRemoteControlDeviceSid -Path $zcodeSettingJsonPath -NewSid $newDeviceSid -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $zcodeSettingJsonPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [17/27] ZCode session SharedStorage (NEW in v1.1) ---
$zcodeSession = Join-Path $zcodeRoaming "session"
Write-Host "`n[17/27] Clearing ZCode session SharedStorage..." -ForegroundColor Cyan
$auditStart = $audit.Count
$sharedFiles = @(
    (Join-Path $zcodeSession "SharedStorage"),
    (Join-Path $zcodeSession "SharedStorage-wal"),
    (Join-Path $zcodeSession "SharedStorage-journal")
)
$sharedActions = Clear-BinaryIdentityStore -Paths $sharedFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
$actions += @($sharedActions)
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeSession
if ($status.Success) {
    Write-Host "[OK] ZCode session SharedStorage cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] ZCode session SharedStorage had failures" -ForegroundColor Red
    $failCount++
}

# --- [18/27] ZCode session cache directories (per-file delete) ---
Write-Host "`n[18/27] Clearing ZCode session cache directories..." -ForegroundColor Cyan
$auditStart = $audit.Count
$zcodeCacheRelPaths = @(
    "Cache\Cache_Data",
    "Code Cache",
    "GPUCache",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "blob_storage",
    "Service Worker"
)
foreach ($relative in $zcodeCacheRelPaths) {
    $fullPath = Join-Path $zcodeSession $relative
    if (Test-Path -LiteralPath $fullPath) {
        $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeSession
if ($status.Success) {
    Write-Host "[OK] ZCode session cache directories cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] ZCode session cache directories had failures" -ForegroundColor Red
    $failCount++
}

# --- [19/27] ZCode session LevelDB (Session Storage only; chat state preserved) ---
Write-Host "`n[19/27] Clearing ZCode session LevelDB (Session Storage only)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$zcodeSessionStorage = Join-Path $zcodeSession "Session Storage"
if (Test-Path -LiteralPath $zcodeSessionStorage) {
    $null = Clear-TreeFilesIndividually -Path $zcodeSessionStorage -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $zcodeSessionStorage) -Audit ([ref]$audit) -Actions ([ref]$actions)
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeSessionStorage -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
}
# Preserve chat-bearing stores: main-session IndexedDB leveldb holds webview
# extension data (chat panels, prompts cache, in-flight responses) and
# Local Storage\leveldb holds persistent UI state. Neither carries a
# server-side identity signal, so both stay on disk by policy.
$zcodeSessionIndexedDb = Join-Path $zcodeSession "IndexedDB\file__0.indexeddb.leveldb"
if (Test-Path -LiteralPath $zcodeSessionIndexedDb) {
    Write-Host "[INFO] Preserving IndexedDB\file__0.indexeddb.leveldb (chat webview data)" -ForegroundColor Cyan
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeSessionIndexedDb -Key "indexeddb-leveldb" -Before "present" -After "preserved-for-chat" -Ok $true
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeSessionIndexedDb -Key "indexeddb-leveldb" -Before "missing" -After "skipped" -Ok $true
}
$zcodeSessionLocalStorage = Join-Path $zcodeSession "Local Storage\leveldb"
if (Test-Path -LiteralPath $zcodeSessionLocalStorage) {
    Write-Host "[INFO] Preserving Local Storage\leveldb (persistent UI state)" -ForegroundColor Cyan
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeSessionLocalStorage -Key "local-storage-leveldb" -Before "present" -After "preserved-for-chat" -Ok $true
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeSessionLocalStorage -Key "local-storage-leveldb" -Before "missing" -After "skipped" -Ok $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeSessionStorage
if ($status.Success) {
    $passCount++
}
else {
    Write-Host "[FAILED] ZCode session LevelDB had failures" -ForegroundColor Red
    $failCount++
}

# --- [20/27] ZCode session browser SQLite files ---
Write-Host "`n[20/27] Clearing ZCode session browser SQLite files..." -ForegroundColor Cyan
$auditStart = $audit.Count
$zcodeSqliteRelPaths = @(
    "DIPS",
    "DIPS-wal",
    "Network\Cookies",
    "Network\Cookies-journal",
    "Network\Trust Tokens",
    "Network\Trust Tokens-journal"
)
$zcodeSqliteFullPaths = @($zcodeSqliteRelPaths | ForEach-Object { Join-Path $zcodeSession $_ })
$sqliteActions = Clear-BinaryIdentityStore -Paths $zcodeSqliteFullPaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
$actions += @($sqliteActions)
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeSession
if ($status.Success) {
    Write-Host "[OK] ZCode session browser SQLite files cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] ZCode session browser SQLite files had failures" -ForegroundColor Red
    $failCount++
}

# --- [21/27] ZCode session Chromium extras (NEW in v1.1) ---
Write-Host "`n[21/27] Clearing ZCode session Chromium extras (WebStorage, Shared Dictionary, transport state)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$zcodeExtraFileRelPaths = @(
    "Network\Network Persistent State",
    "Network\TransportSecurity",
    "Network\NetworkDataMigrated"
)
$zcodeExtraFiles = @($zcodeExtraFileRelPaths | ForEach-Object { Join-Path $zcodeSession $_ })
$extraActions = Clear-BinaryIdentityStore -Paths $zcodeExtraFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
$actions += @($extraActions)
$zcodeExtraDirRelPaths = @(
    "WebStorage",
    "Shared Dictionary"
)
foreach ($relative in $zcodeExtraDirRelPaths) {
    $fullPath = Join-Path $zcodeSession $relative
    if (Test-Path -LiteralPath $fullPath) {
        $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeSession
if ($status.Success) {
    Write-Host "[OK] ZCode session Chromium extras cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] ZCode session Chromium extras had failures" -ForegroundColor Red
    $failCount++
}

# --- [22/27] ZCode embedded browser partition (zcode-embedded-browser) ---
# The embedded OAuth browser is auth-relevant, so unlike the main session its
# Local Storage leveldb IS cleared here. Main-session chat stores stay intact.
Write-Host "`n[22/27] Clearing ZCode embedded browser partition..." -ForegroundColor Cyan
$auditStart = $audit.Count
$zcodeEmbedded = Join-Path $zcodeSession "Partitions\zcode-embedded-browser"
if (-not (Test-Path -LiteralPath $zcodeEmbedded)) {
    Write-Host "[SKIP] embedded browser partition not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeEmbedded -Key "embedded-browser" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $embeddedStepFailed = $false
    $embeddedPrefPath = Join-Path $zcodeEmbedded "Preferences"
    if (-not (Set-DeviceIdSalt -Path $embeddedPrefPath -NewSalt $newSalt -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $embeddedPrefPath) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
        $embeddedStepFailed = $true
    }
    $embeddedFileRelPaths = @(
        "DIPS",
        "DIPS-wal",
        "SharedStorage",
        "SharedStorage-wal",
        "SharedStorage-journal",
        "Network\Cookies",
        "Network\Cookies-journal",
        "Network\Trust Tokens",
        "Network\Trust Tokens-journal",
        "Network\Network Persistent State",
        "Network\TransportSecurity",
        "Network\NetworkDataMigrated"
    )
    $embeddedFiles = @($embeddedFileRelPaths | ForEach-Object { Join-Path $zcodeEmbedded $_ })
    $embeddedActions = Clear-BinaryIdentityStore -Paths $embeddedFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
    $actions += @($embeddedActions)
    $embeddedDirRelPaths = @(
        "Cache\Cache_Data",
        "Code Cache",
        "GPUCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
        "blob_storage",
        "Service Worker",
        "Session Storage",
        "Local Storage\leveldb",
        "WebStorage",
        "Shared Dictionary"
    )
    foreach ($relative in $embeddedDirRelPaths) {
        $fullPath = Join-Path $zcodeEmbedded $relative
        if (Test-Path -LiteralPath $fullPath) {
            $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
    $status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeEmbedded
    if ($status.Success -and (-not $embeddedStepFailed)) {
        Write-Host "[OK] embedded browser partition cleared" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] embedded browser partition had failures" -ForegroundColor Red
        $failCount++
    }
}

# --- [23/27] Qoder profile browser clears (per profile, incl. CORS_Profile) ---
Write-Host "`n[23/27] Clearing Qoder browser data (per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "browser-data" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $stepFailed = $false
    $qoderCacheRelPaths = @(
        "Cache\Cache_Data",
        "Code Cache",
        "GPUCache",
        "DawnGraphiteCache",
        "DawnWebGPUCache",
        "blob_storage",
        "Service Worker"
    )
    $qoderFileRelPaths = @(
        "DIPS",
        "DIPS-wal",
        "SharedStorage",
        "SharedStorage-wal",
        "SharedStorage-journal",
        "Network\Cookies",
        "Network\Cookies-journal",
        "Network\Trust Tokens",
        "Network\Trust Tokens-journal",
        "Network\Network Persistent State",
        "Network\TransportSecurity",
        "Network\NetworkDataMigrated",
        "DevToolsActivePort"
    )
    $qoderDirRelPaths = @(
        "Session Storage",
        "WebStorage",
        "Shared Dictionary"
    )
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $stepStart = $audit.Count
        Write-Host "    [$label] browser data..." -ForegroundColor DarkGray
        $profileFiles = @($qoderFileRelPaths | ForEach-Object { Join-Path $pr $_ })
        $profileActions = Clear-BinaryIdentityStore -Paths $profileFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
        $actions += @($profileActions)
        foreach ($relative in ($qoderCacheRelPaths + $qoderDirRelPaths)) {
            $fullPath = Join-Path $pr $relative
            if (Test-Path -LiteralPath $fullPath) {
                $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
            }
            else {
                Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
            }
        }
        # Preserve Qoder Local Storage\leveldb (UI state, no server signal) and
        # the Backups\ tree (untitled/editor backups are user content).
        $qoderLocalStorage = Join-Path $pr "Local Storage\leveldb"
        if (Test-Path -LiteralPath $qoderLocalStorage) {
            Add-AuditEntry -Audit ([ref]$audit) -File $qoderLocalStorage -Key "local-storage-leveldb" -Before "present" -After "preserved-for-chat" -Ok $true
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $qoderLocalStorage -Key "local-storage-leveldb" -Before "missing" -After "skipped" -Ok $true
        }
        $qoderBackups = Join-Path $pr "Backups"
        if (Test-Path -LiteralPath $qoderBackups) {
            Add-AuditEntry -Audit ([ref]$audit) -File $qoderBackups -Key "editor-backups" -Before "present" -After "preserved-for-chat" -Ok $true
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $qoderBackups -Key "editor-backups" -Before "missing" -After "skipped" -Ok $true
        }
        $status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $stepStart -Path $pr
        if ($status.Success) {
            Write-Host "    [$label] [OK] browser data cleared" -ForegroundColor Green
        }
        else {
            Write-Host "    [$label] [FAILED] browser data had failures" -ForegroundColor Red
            $stepFailed = $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [24/27] Qoder additional dirs + .qoder subdir cleanup ---
Write-Host "`n[24/27] Clearing Qoder additional dirs + .qoder cache subdirs..." -ForegroundColor Cyan
$auditStart = $audit.Count
$stepFailed = $false
if ($qoderPresent) {
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        foreach ($relative in @("Crashpad", "SharedClientCache")) {
            $fullPath = Join-Path $pr $relative
            if (Test-Path -LiteralPath $fullPath) {
                $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
            }
            else {
                Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
            }
        }
        # logs/ embeds update-check URLs with machineId=...&umid=... verbatim,
        # so it is identity-bearing. Per-file delete survives locked log files.
        $logsPath = Join-Path $pr "logs"
        if (Test-Path -LiteralPath $logsPath) {
            Write-Host "    [$label] logs/ (per-file delete)..." -ForegroundColor DarkGray
            $null = Clear-TreeFilesIndividually -Path $logsPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $logsPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $logsPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
}
# .qoder cache subdirs: clean regenerable AI caches only. memories/, canvas/
# and knowledges/ hold per-project AI context adjacent to chat history and are
# preserved by policy; settings.json and mcp.json are never touched.
foreach ($subdir in @("cache", "session-env", "plugins")) {
    $p = Join-Path $qoderUserProfile $subdir
    $result = Remove-AppPathSafely -Path $p -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
    if ($result -eq "missing") {
        Write-Host "    [SKIP] .qoder\$subdir (not present)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "    [OK] .qoder\$subdir" -ForegroundColor Green
    }
}
$extPath = Join-Path $qoderUserProfile "extensions"
$extResult = Remove-AppPathSafely -Path $extPath -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
if ($extResult -eq "missing") {
    Write-Host "    [SKIP] .qoder\extensions (not present)" -ForegroundColor DarkGray
}
elseif ($extResult -eq "link-removed") {
    Write-Host "    [OK] .qoder\extensions (symlink removed; target untouched)" -ForegroundColor Green
}
else {
    Write-Host "    [OK] .qoder\extensions" -ForegroundColor Green
}
foreach ($preserved in @("memories", "canvas", "knowledges")) {
    $p = Join-Path $qoderUserProfile $preserved
    if (Test-Path -LiteralPath $p) {
        Write-Host "    [INFO] Preserving .qoder\$preserved (AI context adjacent to chat)" -ForegroundColor Cyan
        Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "user-subdir" -Before "present" -After "preserved-for-chat" -Ok $true
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "user-subdir" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $qoderUserProfile
if ($qoderPresent) {
    $mainStatus = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $qoderRoaming
    if (-not $mainStatus.Success) {
        $stepFailed = $true
    }
}
if ($status.Success -and (-not $stepFailed)) {
    Write-Host "[OK] Qoder additional dirs + .qoder cache subdirs cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] Qoder additional dirs had failures" -ForegroundColor Red
    $failCount++
}

# --- [25/27] Qoder workspace UPSERT (per profile; NEVER delete workspace files) ---
# Approved policy: update storage.serviceMachineId inside each workspace
# state.vscdb via SQLite UPSERT so no stale device ID lingers, but never
# delete tables, files, or stale .backup sidecars under workspaceStorage.
Write-Host "`n[25/27] Updating Qoder workspace state.vscdb files (UPSERT only, per profile)..." -ForegroundColor Cyan
if (-not $qoderPresent) {
    Write-Host "    [SKIP] Qoder not installed" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $qoderRoaming -Key "workspaceStorage" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}
else {
    $workspaceFailed = $false
    foreach ($pr in $qoderProfiles) {
        $label = Get-ProfileLabel -MainRoot $qoderRoaming -ProfileRoot $pr
        $workspaceStorageRoot = Join-Path $pr "User\workspaceStorage"
        $workspaceDbPaths = @()
        if (Test-Path -LiteralPath $workspaceStorageRoot) {
            $workspaceDbPaths = Get-ChildItem -LiteralPath $workspaceStorageRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName "state.vscdb" } |
                Where-Object { Test-Path -LiteralPath $_ }
        }
        if ($workspaceDbPaths.Count -eq 0) {
            Write-Host "    [$label] [SKIP] no workspace state.vscdb files found" -ForegroundColor Yellow
            Add-AuditEntry -Audit ([ref]$audit) -File $workspaceStorageRoot -Key "workspaceStorage" -Before "none" -After "skipped" -Ok $true
            continue
        }
        foreach ($workspaceDbPath in $workspaceDbPaths) {
            Invoke-WorkspaceSqliteUpdate -WorkspaceDbPath $workspaceDbPath -DeviceId $ids.devDeviceId -RootPath $pr -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
            if ($audit.Count -gt 0) {
                $lastAuditEntry = $audit[-1]
                if (-not $lastAuditEntry.ok) {
                    $workspaceFailed = $true
                }
            }
            else {
                $workspaceFailed = $true
            }
        }
        # Stale workspace .backup sidecars retain the OLD device ID, but they
        # are workspace files and stay on disk per the preservation policy.
        $workspaceBackupCount = 0
        if (Test-Path -LiteralPath $workspaceStorageRoot) {
            $workspaceBackupCount = @(Get-ChildItem -LiteralPath $workspaceStorageRoot -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName "state.vscdb.backup" } |
                Where-Object { Test-Path -LiteralPath $_ }).Count
        }
        Add-AuditEntry -Audit ([ref]$audit) -File $workspaceStorageRoot -Key "workspace-backups-preserved" -Before ("present=" + $workspaceBackupCount) -After "preserved-per-policy" -Ok $true
    }
    if ($workspaceFailed) {
        Write-Host "[FAILED] workspace UPSERT had failures" -ForegroundColor Red
        $failCount++
    }
    else {
        Write-Host "[OK] workspace UPSERT complete (no workspace files deleted)" -ForegroundColor Green
        $passCount++
    }
}

# --- [26/27] ZCode CLI db.sqlite telemetry scrub + preservation audit ---
$zcodeCliDbPath = Join-Path $zcodeUserProfile "cli\db\db.sqlite"
Write-Host "`n[26/27] Scrubbing ZCode CLI db.sqlite telemetry keys..." -ForegroundColor Cyan
# Preservation audit for chat-bearing CLI stores: tasks index, checkpoints,
# artifacts and rollouts are never touched (only telemetry-like keys in
# db.sqlite are DELETEd below; no chat tables are modified).
foreach ($preservedRelPath in @("v2\tasks-index.sqlite", "v2\checkpoints", "cli\artifacts", "cli\rollout", "cli\log", "v2\logs")) {
    $preservedPath = Join-Path $zcodeUserProfile $preservedRelPath
    if (Test-Path -LiteralPath $preservedPath) {
        Add-AuditEntry -Audit ([ref]$audit) -File $preservedPath -Key "chat-store" -Before "present" -After "preserved-for-chat" -Ok $true
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $preservedPath -Key "chat-store" -Before "missing" -After "skipped" -Ok $true
    }
}
if (Test-Path -LiteralPath $zcodeCliDbPath) {
    $cliBackupLabel = Get-UserProfileBackupLabel -TargetPath $zcodeCliDbPath
    $cliBackupPath = Backup-FileToTimestampDir -Source $zcodeCliDbPath -BackupRoot $backupRoot -Label $cliBackupLabel
    if ($cliBackupPath) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $zcodeCliDbPath -BackupPath $cliBackupPath
    }

    $pythonCommand = Get-PythonCommandInfo
    if ($pythonCommand) {
        $tempScriptPath = Join-Path $env:TEMP ("sqlite_clear_cli_telemetry_{0}.py" -f ([guid]::NewGuid().ToString("N")))
        $pythonScript = @'
import sqlite3
import json
import sys

db_path = sys.argv[1]
deleted = 0

patterns = ("%telemetry%", "%machineId%", "%deviceId%")

try:
    conn = sqlite3.connect(db_path)
except sqlite3.Error as exc:
    print(json.dumps({"deleted": 0, "error": str(exc)}))
    sys.exit(0)

try:
    cursor = conn.cursor()
    for pattern in patterns:
        try:
            cursor.execute("SELECT key FROM ItemTable WHERE key LIKE ?", (pattern,))
        except sqlite3.OperationalError:
            continue
        for row in cursor.fetchall():
            cursor.execute("DELETE FROM ItemTable WHERE key = ?", (row[0],))
            deleted += 1
    conn.commit()
finally:
    conn.close()

print(json.dumps({"deleted": deleted}))
'@
        try {
            [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, (New-Object System.Text.UTF8Encoding $false))
            $commandOutput = & $pythonCommand.Source $tempScriptPath $zcodeCliDbPath
            if ($LASTEXITCODE -eq 0) {
                $result = ($commandOutput -join "`n") | ConvertFrom-Json
                Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After ("deleted " + $result.deleted) -Ok $true
                Write-Host "[OK] CLI db telemetry cleared: $($result.deleted) keys" -ForegroundColor Green
                $passCount++
            }
            else {
                Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After "failed" -Ok $false
                Write-Host "[FAILED] CLI db telemetry clear command failed" -ForegroundColor Red
                $failCount++
            }
        }
        catch {
            Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After "exception" -Ok $false
            Write-Host "[FAILED] CLI db telemetry clear threw exception" -ForegroundColor Red
            $failCount++
        }
        finally {
            if (Test-Path -LiteralPath $tempScriptPath) {
                Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After "python-not-found" -Ok $false
        Write-Host "[FAILED] Python not found -- CLI db telemetry NOT cleared" -ForegroundColor Red
        $failCount++
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "missing" -After "skipped" -Ok $true
    Write-Host "[SKIP] CLI db.sqlite not found" -ForegroundColor Yellow
    $passCount++
}

# --- [27/27] Old ID_Backups purge + watchdog re-verify ---
Write-Host "`n[27/27] Purging old ID_Backups + watchdog re-verify..." -ForegroundColor Cyan
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $zcodeIdBackupsRoot -Audit ([ref]$audit)
if ($qoderPresent) {
    Invoke-OldIdBackupsPurge -BackupRoot (Join-Path $qoderIdBackupsRoot $timestamp) -IdBackupsRoot $qoderIdBackupsRoot -Audit ([ref]$audit)
}
$watchdogCoreFiles = @(
    (Join-Path $zcodeSession "SharedStorage"),
    (Join-Path $zcodeSession "Network\Cookies"),
    (Join-Path $zcodeSession "DIPS"),
    $zcodeCodingPlanCachePath
)
Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit ([ref]$audit)
$passCount++

# --- Audit + Restore ---
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
Write-AuditLog -Audit $audit -Path $auditPath
$restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App "ZCode" -Actions $actions

$finalStorageOk = $true
$qoderMainStoragePath = Join-Path $qoderRoaming "User\globalStorage\storage.json"
if ($qoderPresent -and (Test-Path -LiteralPath $qoderMainStoragePath)) {
    $finalStorageOk = Confirm-JsonValues -Path $qoderMainStoragePath -Expected $storageUpdates
}

$finalTelemetryOk = $true
if (Test-Path -LiteralPath $zcodeTelemetryStatePath) {
    $finalTelemetryOk = Confirm-JsonValues -Path $zcodeTelemetryStatePath -Expected @{ "deviceMid" = $newDeviceMid }
}

$qoderMainSqlitePath = Join-Path $qoderRoaming "User\globalStorage\state.vscdb"
$finalSqliteOk = $true
if ($qoderPresent -and (Test-Path -LiteralPath $qoderMainSqlitePath)) {
    $finalSqliteAuditEntries = @($audit | Where-Object { $_.file -eq $qoderMainSqlitePath -and $_.key -eq "storage.serviceMachineId" })
    $finalSqliteOk = ($finalSqliteAuditEntries.Count -gt 0) -and ($finalSqliteAuditEntries[-1].ok -eq $true)
}

if ($finalStorageOk) {
    Write-Host "[OK] final storage.json probe passed" -ForegroundColor Green
}
else {
    Write-Host "[FAILED] final storage.json probe failed" -ForegroundColor Red
    $failCount++
}

if ($finalTelemetryOk) {
    Write-Host "[OK] final telemetry-state.json probe passed" -ForegroundColor Green
}
else {
    Write-Host "[FAILED] final telemetry-state.json probe failed" -ForegroundColor Red
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
Write-Host "NOTE: change_device_id.ps1 is machine-wide and affects BOTH ZCode instances + Qoder." -ForegroundColor Yellow

[System.IO.File]::WriteAllText("$env:TEMP\zcode_v1.3_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "ZCode/Qoder reset v1.4 [$Target] completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "ZCode/Qoder reset v1.4 [$Target] completed successfully." -ForegroundColor Green
