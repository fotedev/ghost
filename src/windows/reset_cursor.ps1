#Requires -Version 5.1
# Cursor Identity Reset v0.2
#
# Hardened rebuild of reset_cursor_windows-v0.1.ps1 on the v1.1 template:
#   - Self-elevation to Administrator (auto re-launch, no manual "run as admin")
#   - Aggressive multi-process kill (Cursor + helpers, 2 consecutive clean checks)
#   - No-BOM UTF-8 on EVERY write (v0.1 used Set-Content -Encoding UTF8, which
#     emits a BOM under PowerShell 5.1 and can corrupt Chromium/Electron parsers)
#   - Delete (not rename) for binary stores: renames left *.backup files with
#     the OLD fingerprint on disk. Backups live in ID_Backups for restore.
#   - NEW targets over v0.1: state.vscdb auth-secrets scrub (key list verified
#     live on 2026-09-12), os_crypt rotation, Preferences device_id_salt,
#     SharedStorage, Trust Tokens, Crashpad, logs, stale .backup deletion,
#     old ID_Backups purge, watchdog re-verify.
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
# Requirement: Python (python or python3) for SQLite writes.

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
$cursorIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $cursorIsAdmin) {
    $cursorLogOut = "$env:TEMP\cursor_v0.2_result.log"
    $cursorScript = $MyInvocation.MyCommand.Path
    $cursorArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$cursorScript`" *> `"$cursorLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $cursorArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath $cursorLogOut) {
        Get-Content -LiteralPath $cursorLogOut
    }
    if (Test-Path -LiteralPath "$env:TEMP\cursor_v0.2_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\cursor_v0.2_done.txt"
    }
    exit
}

Write-GhostBanner -Target "Cursor Identity Reset" -Version "0.2"

# === Local helpers (Cursor reference pattern, no-BOM throughout) ==============

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

# DELETE Cursor account secrets from state.vscdb ItemTable and verify survivors
# are zero via read-only reopen. Key list verified live on 2026-09-12 against
# %APPDATA%\Cursor\User\globalStorage\state.vscdb. composerHeaders (chat),
# cursorDiskKV, MCP/third-party secrets and git-ipc tokens are never touched.
function Clear-CursorSecrets {
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

    $tempScriptPath = Join-Path $env:TEMP ("cursor_scrub_secrets_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @'
import sqlite3
import json
import sys

db_path = sys.argv[1]

exact_keys = [
    "cursorAuth/accessToken",
    "cursorAuth/refreshToken",
    "cursorAuth/cachedEmail",
    "cursorAuth/cachedScopedProfile",
    "cursorAuth/cachedSignUpType",
    "cursorAuth/onboardingDate",
    "cursorAuth/stripeMembershipAuthId",
    "cursorAuth/stripeMembershipType",
    "secret://cursorAuth/openAIKey",
    "glass.lastSignedInAuthId",
    "adminSettings.cachedAuthId",
    "cursor.customize.userDisplayNameCache",
]
like_patterns = [
    "cursorAuth/%",
    "%google-oauth2|user%",
]

deleted = []
conn = sqlite3.connect(db_path)
try:
    cursor = conn.cursor()
    for key in exact_keys:
        cursor.execute("SELECT key FROM ItemTable WHERE key = ?", (key,))
        for row in cursor.fetchall():
            cursor.execute("DELETE FROM ItemTable WHERE key = ?", (row[0],))
            deleted.append(row[0])
    for pattern in like_patterns:
        cursor.execute("SELECT key FROM ItemTable WHERE key LIKE ?", (pattern,))
        for row in cursor.fetchall():
            cursor.execute("DELETE FROM ItemTable WHERE key = ?", (row[0],))
            deleted.append(row[0])
    conn.commit()
finally:
    conn.close()

verify_conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
try:
    verify_cursor = verify_conn.cursor()
    survivors = 0
    for key in exact_keys:
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key = ?", (key,))
        survivors += verify_cursor.fetchone()[0]
    for pattern in like_patterns:
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?", (pattern,))
        survivors += verify_cursor.fetchone()[0]
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
        $ok = ($result.survivors -eq 0)
        $deletedCount = $result.deleted.Count
        if ($ok) {
            Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After ("deleted " + $deletedCount) -Ok $true
            Write-Host "    [OK] secrets deleted: $deletedCount keys from $Path" -ForegroundColor Green
        }
        else {
            Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After ("survivors=" + $result.survivors) -Ok $false
            Write-Host "    [FAILED] secrets survivors remain: $($result.survivors) in $Path" -ForegroundColor Red
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
# A whole-tree Remove-Item fails FAST on the first locked file; per-file delete
# means one stuck file cannot block the rest. Appends a restorable delete
# action (whole-tree backup) to $Actions.
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

# Delete a stale file WITHOUT backing it up (regenerable sidecars only).
# Verifies the path is gone afterwards.
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
        foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
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
    foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
        foreach ($p in @(Get-Process -Name $helperName -ErrorAction SilentlyContinue)) {
            Write-Host ("    $helperName PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
        }
    }
    return $false
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

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Cursor Identity Reset v0.2 ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: chat history + workspaces preserved; no MAC/hostname/registry steps" -ForegroundColor Gray

# Pre-step: aggressive tree-kill. Hard-fails the run if unkillable.
if (-not (Stop-CursorProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$newSalt = -join ((1..32) | ForEach-Object { "{0:X}" -f (Get-Random -Maximum 16) })
$storageUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}

# --- [1/15] machineid ---
Write-Host "`n[1/15] Updating machineid..." -ForegroundColor Cyan
if (Set-VerifiedMachineIdFile -Path $machineIdPath -Value $ids.devDeviceId -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $machineIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "[OK] machineid verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] machineid verification failed" -ForegroundColor Red
    $failCount++
}

# --- [2/15] storage.json (4 telemetry keys; verified live: no auth keys here) ---
Write-Host "`n[2/15] Updating storage.json..." -ForegroundColor Cyan
if (Set-JsonIdentity -Path $storagePath -Updates $storageUpdates -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storagePath) -Actions ([ref]$actions)) {
    Write-Host "[OK] storage.json verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] storage.json verification failed" -ForegroundColor Red
    $failCount++
}

# --- [3/15] state.vscdb serviceMachineId ---
Write-Host "`n[3/15] Updating global state.vscdb (serviceMachineId)..." -ForegroundColor Cyan
if (Set-SqliteKeys -Path $sqlitePath -Updates @{ "storage.serviceMachineId" = $ids.devDeviceId } -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath) -Actions ([ref]$actions)) {
    Write-Host "[OK] global state.vscdb verified" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] global state.vscdb verification failed" -ForegroundColor Red
    $failCount++
}

# --- [4/15] state.vscdb auth secrets DELETE (NEW in v0.2) ---
Write-Host "`n[4/15] Clearing global state.vscdb auth secrets..." -ForegroundColor Cyan
if (Clear-CursorSecrets -Path $sqlitePath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [5/15] stale state.vscdb.backup deletion (NEW in v0.2, no backup of backup) ---
Write-Host "`n[5/15] Deleting stale state.vscdb.backup..." -ForegroundColor Cyan
if (Remove-VerifiedFileNoBackup -Path (Join-Path $root "User\globalStorage\state.vscdb.backup") -AuditKey "state.vscdb.backup" -Audit ([ref]$audit)) {
    $passCount++
}
else {
    $failCount++
}

# --- [6/15] Preferences device_id_salt (NEW in v0.2) ---
Write-Host "`n[6/15] Updating Preferences (device_id_salt)..." -ForegroundColor Cyan
if (Set-DeviceIdSalt -Path (Join-Path $root "Preferences") -NewSalt $newSalt -BackupRoot $backupRoot -BackupLabel "Preferences" -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [7/15] Local State os_crypt rotation (NEW in v0.2) ---
Write-Host "`n[7/15] Rotating os_crypt.encrypted_key..." -ForegroundColor Cyan
if (Remove-OsCryptEncryptedKey -Path (Join-Path $root "Local State") -BackupRoot $backupRoot -BackupLabel "Local State" -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [8/15] Cookies + transport state (delete; v0.1 renamed, leaving old IDs) ---
Write-Host "`n[8/15] Clearing Cookies + transport state..." -ForegroundColor Cyan
$auditStart = $audit.Count
$cookiePaths = @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "Network\Cookies-journal"),
    (Join-Path $root "Network\Network Persistent State"),
    (Join-Path $root "Network\TransportSecurity"),
    (Join-Path $root "Network\NetworkDataMigrated")
)
$cookieActions = Clear-BinaryIdentityStore -Paths $cookiePaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
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

# --- [9/15] DIPS stores (delete; v0.1 renamed) ---
Write-Host "`n[9/15] Clearing DIPS stores..." -ForegroundColor Cyan
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

# --- [10/15] SharedStorage + Trust Tokens (NEW in v0.2) ---
Write-Host "`n[10/15] Clearing SharedStorage + Trust Tokens..." -ForegroundColor Cyan
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

# --- [11/15] sentry tree (delete; v0.1 renamed -- scope_v3.json holds email + fingerprint) ---
Write-Host "`n[11/15] Clearing sentry tree..." -ForegroundColor Cyan
$auditStart = $audit.Count
$sentryPath = Join-Path $root "sentry"
if (Test-Path -LiteralPath $sentryPath) {
    $null = Clear-TreeFilesIndividually -Path $sentryPath -BackupRoot $backupRoot -BackupLabel "sentry" -Audit ([ref]$audit) -Actions ([ref]$actions)
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

# --- [12/15] cache dirs + Session Storage (per-file; chat stores preserved) ---
Write-Host "`n[12/15] Clearing cache directories + Session Storage..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($relative in @("Cache\Cache_Data", "Code Cache", "GPUCache", "blob_storage", "Service Worker", "Session Storage")) {
    $fullPath = Join-Path $root $relative
    if (Test-Path -LiteralPath $fullPath) {
        $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
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

# --- [13/15] Crashpad + logs (NEW in v0.2; crash dumps embed device IDs) ---
Write-Host "`n[13/15] Clearing Crashpad + logs..." -ForegroundColor Cyan
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

# --- [14/15] workspace UPSERT-only (never delete workspace files) ---
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

# --- [15/15] Old ID_Backups purge + watchdog re-verify ---
Write-Host "`n[15/15] Purging old ID_Backups + watchdog re-verify..." -ForegroundColor Cyan
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit)
$watchdogCoreFiles = @(
    (Join-Path $root "Network\Cookies"),
    (Join-Path $root "DIPS"),
    (Join-Path $root "SharedStorage")
)
Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit ([ref]$audit)
$passCount++

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

[System.IO.File]::WriteAllText("$env:TEMP\cursor_v0.2_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "Cursor reset v0.2 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "Cursor reset v0.2 completed successfully." -ForegroundColor Green
