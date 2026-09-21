# Windsurf/Devin Identity Reset v0.3
# (Windsurf rebranded to Devin Desktop on 2026-06-02 -- same IDE, over-the-air)
#
# Multi-root rebuild of reset_windsurf_windows-v0.2.ps1 for the rebrand:
#   - The OTA update renamed the product: Windows process is now
#     Devin.exe / Devin Helper*, windsurf.com redirects to devin.ai, and
#     post-update installs can carry BOTH data roots side by side:
#     %APPDATA%\devin (new) and %APPDATA%\Windsurf (legacy).
#   - v0.3 auto-detects every existing root under %APPDATA% (Devin, Windsurf)
#     and runs the full identity sequence against EACH one in a single pass.
#   - New targets over v0.2 (verified live on 2026-09-21 against
#     %APPDATA%\devin): credentials.toml (windsurf_api_key auth) deletion,
#     config.json devin.org_id blanking, cli\installation_id regeneration,
#     .devin\argv.json crash-reporter-id scrub, extended state.vscdb secret
#     patterns (%cachedPlanInfoData:user-% + devin-named candidates), and an
#     extended cache sweep (CachedData, CachedProfilesData, CachedExtensionVSIXs,
#     CachedConfigurations, DawnGraphiteCache, DawnWebGPUCache, Shared Dictionary).
#   - Verified NON-targets (never touched): %USERPROFILE%\.devin-shared
#     (sharedStorage state.vscdb holds UI markers only),
#     %LOCALAPPDATA%\devin (CLI binaries + is_zdr flag, no identity),
#     WebStorage + IndexedDB (unknown contents, possible chat data).
#
# PRESERVATION (chat history + workspaces are never wiped):
#   - chat.ChatSessionStore.index + all Cascade/chat keys: never touched.
#   - Local Storage\leveldb (UI state) + Backups\ (editor backups): preserved.
#   - User\workspaceStorage\**: serviceMachineId UPSERT only; tables/files and
#     stale .backup sidecars are never deleted.
#   - Third-party secrets (mcp_token_github, other extensions' secret://
#     entries, github-authentication): never touched.
#   - .devin\.windsurf extensions/plans/worktrees + mcp_config.json: untouched.
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
# Requirement: Python (python or python3) for SQLite writes.

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
$devinIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $devinIsAdmin) {
    $devinLogOut = "$env:TEMP\devin_v0.3_result.log"
    $devinScript = $MyInvocation.MyCommand.Path
    $devinArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$devinScript`" *> `"$devinLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $devinArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath $devinLogOut) {
        Get-Content -LiteralPath $devinLogOut
    }
    if (Test-Path -LiteralPath "$env:TEMP\devin_v0.3_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\devin_v0.3_done.txt"
    }
    exit
}

Write-GhostBanner -Target "Windsurf/Devin Identity Reset" -Version "0.3"

# === Local helpers (Windsurf pattern, no-BOM throughout) ======================

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

# DELETE account secrets from state.vscdb ItemTable and verify survivors are
# zero via read-only reopen. Key list verified live on 2026-09-12 against
# %APPDATA%\Windsurf and on 2026-09-21 against %APPDATA%\devin: even inside
# the rebranded root the app still writes WINDSURF-named auth keys
# (codeium.windsurf-windsurf_auth, windsurf_auth-<user>, windsurfAuthStatus),
# so the windsurf patterns stay primary; the devin-named entries are defensive
# candidates (delete-if-exists is a no-op when absent). The v0.3 addition
# %cachedPlanInfoData:user-% covers windsurf.reactSettings.cachedPlanInfoData
# keyed by a per-user account hex. chat.ChatSessionStore.index and third-party
# extension secrets are never touched. Underscore in LIKE patterns is escaped
# (it is a wildcard).
function Clear-WindsurfSecrets {
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

    $tempScriptPath = Join-Path $env:TEMP ("windsurf_scrub_secrets_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @'
import sqlite3
import json
import sys

db_path = sys.argv[1]

exact_keys = [
    "codeium.windsurf-windsurf_auth",
    "windsurfAuthStatus",
    "windsurf.settings.cachedPlanInfo",
    "devinAuthStatus",
    "devin.settings.cachedPlanInfo",
]
like_patterns = [
    "windsurf\\_auth-%",
    "%windsurf\\_auth%",
    "%cachedPlanInfoData:user-%",
    "devin\\_auth-%",
    "%devin\\_auth%",
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
        cursor.execute("SELECT key FROM ItemTable WHERE key LIKE ? ESCAPE '\\'", (pattern,))
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
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key LIKE ? ESCAPE '\\'", (pattern,))
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

# NEW in v0.3: %APPDATA%\devin\config.json carries a devin.org_id binding
# (verified live 2026-09-21). Blank it (never delete the file -- it also holds
# theme/shell prefs) so the next launch re-resolves the org against the new
# identity. No-BOM write.
function Clear-AppOrgBinding {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "devin.org_id" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] config.json not present: $Path" -ForegroundColor Yellow
        return $true
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "devin.org_id" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse config.json: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValue = $null
    if ((Test-ObjectProperty -Object $content -Name "devin") -and (Test-ObjectProperty -Object $content.devin -Name "org_id")) {
        $beforeValue = $content.devin.org_id
    }

    if ([string]::IsNullOrEmpty("$beforeValue")) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "devin.org_id" -Before "absent-or-empty" -After "skipped" -Ok $true
        Write-Host "    [SKIP] no org binding present: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $content.devin.org_id = ""
    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $afterValue = $verified.devin.org_id
        $ok = [string]::IsNullOrEmpty("$afterValue")
        Add-AuditEntry -Audit $Audit -File $Path -Key "devin.org_id" -Before $beforeValue -After $afterValue -Ok $ok
        if ($ok) {
            Write-Host "    [OK] devin.org_id blanked: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] devin.org_id still present: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "devin.org_id" -Before $beforeValue -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read config.json after write: $Path" -ForegroundColor Red
        return $false
    }
}

# argv.json is JSONC (comments allowed). Regex-replace just the
# crash-reporter-id value and the leaked username in user-data-dir, preserving
# every comment and other field verbatim. No-BOM write.
# v0.3: used for both %USERPROFILE%\.windsurf\argv.json and
# %USERPROFILE%\.devin\argv.json (both carry crash-reporter-id post-rebrand).
function Update-ArgvJsonIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewCrashReporterId,
        [Parameter(Mandatory = $true)][string]$Username,
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
            $inner = $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd()
            if ($inner.EndsWith("{")) {
                $newRaw = $inner + "`n  " + $replacement + "`n}"
            }
            else {
                $newRaw = $inner.TrimEnd(",") + ",`n  " + $replacement + "`n}"
            }
        }
        else {
            Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $before -After "unparseable" -Ok $false
            Write-Host "    [FAILED] argv.json has no JSON object to extend: $Path" -ForegroundColor Red
            return $false
        }
    }

    $userDirScrubbed = $false
    if ($newRaw.Contains($Username)) {
        $newRaw = $newRaw.Replace($Username, "RESET")
        $userDirScrubbed = $true
    }

    [System.IO.File]::WriteAllText($Path, $newRaw, (New-Object System.Text.UTF8Encoding $false))

    $verifyRaw = Get-Content -LiteralPath $Path -Raw
    $verifyMatch = [regex]::Match($verifyRaw, '"crash-reporter-id"\s*:\s*"([^"]+)"')
    $verified = if ($verifyMatch.Success) { $verifyMatch.Groups[1].Value } else { $null }

    $ok = ($verified -eq $NewCrashReporterId)
    Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $before -After $verified -Ok $ok
    $userDirLabel = "user-data-dir:scrubbed:" + $userDirScrubbed.ToString().ToLowerInvariant()
    Add-AuditEntry -Audit $Audit -File $Path -Key $userDirLabel -Before "n/a" -After "n/a" -Ok $true
    if ($ok) {
        $note = if ($userDirScrubbed) { " + user-data-dir scrubbed" } else { "" }
        Write-Host "    [OK] argv.json crash-reporter-id updated$note" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] argv.json crash-reporter-id verification failed" -ForegroundColor Red
    }
    return $ok
}

# Preferences / Local State may embed $env:USERNAME. Scrub it via raw text so
# a single leaked reference cannot survive a partial parse. No-BOM write.
function Set-UsernameScrubbedFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Replacement,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "username-scrub" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] not present: $Path" -ForegroundColor Yellow
        return $true
    }

    $before = Get-Content -LiteralPath $Path -Raw
    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $hadLeak = $before.Contains($Username)
    if ($hadLeak) {
        $after = $before.Replace($Username, $Replacement)
        [System.IO.File]::WriteAllText($Path, $after, (New-Object System.Text.UTF8Encoding $false))
    }

    $reRead = Get-Content -LiteralPath $Path -Raw
    $ok = -not $reRead.Contains($Username)
    $scrubBefore = if ($hadLeak) { "leaked" } else { "clean" }
    $scrubAfter = if ($ok) { "clean" } else { "still-leaked" }
    Add-AuditEntry -Audit $Audit -File $Path -Key "username-scrub" -Before $scrubBefore -After $scrubAfter -Ok $ok

    if ($ok) {
        Write-Host "    [OK] username scrub verified: $Path" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] username still present after scrub: $Path" -ForegroundColor Red
    }
    return $ok
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

# Aggressive tree-kill for Devin Desktop + Windsurf + Codeium backend +
# extension helpers. Requires 2 consecutive clean checks; hard-fails the run
# when unkillable. Both brand names are killed because post-rebrand installs
# may still run legacy Windsurf processes (or both generations side by side).
function Stop-AppFamilyProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all Devin/Windsurf/Codeium + extension-helper processes (aggressive tree-kill)..." -ForegroundColor Cyan

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

        $devinRemaining = @(Get-Process -Name "Devin*" -ErrorAction SilentlyContinue)
        $windsurfRemaining = @(Get-Process -Name "Windsurf*" -ErrorAction SilentlyContinue)
        $codeiumRemaining = @(Get-Process -Name "codeium*" -ErrorAction SilentlyContinue)
        $helperRemaining = 0
        foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
            $helperRemaining += @(Get-Process -Name $helperName -ErrorAction SilentlyContinue).Count
        }
        $count = $devinRemaining.Count + $windsurfRemaining.Count + $codeiumRemaining.Count + $helperRemaining
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all Devin/Windsurf/Codeium + extension-helper processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($p in @(Get-Process -Name "Devin*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    Devin PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($p in @(Get-Process -Name "Windsurf*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    Windsurf PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($p in @(Get-Process -Name "codeium*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    codeium PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
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

# === Per-root reset (steps [1/17]..[14/17] run against EACH detected root) ====

# Runs the full root-local identity sequence against one %APPDATA% data root.
# Each root gets its OWN ID_Backups\<ts> dir (self-contained restore, no
# label collisions between roots). Counters/audit/actions flow back through
# refs. All step bodies are carried over from v0.2 unchanged except where
# noted (step renumbering, extended cache list, new step 13).
function Invoke-RootReset {
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][hashtable]$Ids,
        [Parameter(Mandatory = $true)][hashtable]$StorageUpdates,
        [Parameter(Mandatory = $true)][string]$NewSalt,
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

    # --- [1/17] machineid ---
    Write-Host "[1/17] [$AppName] Updating machineid..." -ForegroundColor Cyan
    if (Set-VerifiedMachineIdFile -Path $machineIdPath -Value $Ids.devDeviceId -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $machineIdPath) -Audit $Audit -Actions $Actions) {
        Write-Host "[OK] machineid verified" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] machineid verification failed" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [2/17] storage.json ---
    Write-Host "[2/17] [$AppName] Updating storage.json..." -ForegroundColor Cyan
    if (Set-JsonIdentity -Path $storagePath -Updates $StorageUpdates -Audit $Audit -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $storagePath) -Actions $Actions) {
        Write-Host "[OK] storage.json verified" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] storage.json verification failed" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [3/17] state.vscdb serviceMachineId ---
    Write-Host "[3/17] [$AppName] Updating global state.vscdb (serviceMachineId)..." -ForegroundColor Cyan
    if (Set-SqliteKeys -Path $sqlitePath -Updates @{ "storage.serviceMachineId" = $Ids.devDeviceId } -Audit $Audit -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath) -Actions $Actions) {
        Write-Host "[OK] global state.vscdb verified" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] global state.vscdb verification failed" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [4/17] state.vscdb auth secrets DELETE ---
    Write-Host "[4/17] [$AppName] Clearing global state.vscdb auth secrets..." -ForegroundColor Cyan
    if (Clear-WindsurfSecrets -Path $sqlitePath -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $sqlitePath) -Audit $Audit -Actions $Actions) {
        $PassCount.Value++
    }
    else {
        $FailCount.Value++
    }

    # --- [5/17] stale state.vscdb.backup deletion ---
    Write-Host "[5/17] [$AppName] Deleting stale state.vscdb.backup..." -ForegroundColor Cyan
    if (Remove-VerifiedFileNoBackup -Path (Join-Path $root "User\globalStorage\state.vscdb.backup") -AuditKey "state.vscdb.backup" -Audit $Audit) {
        $PassCount.Value++
    }
    else {
        $FailCount.Value++
    }

    # --- [6/17] Preferences salt + Local State os_crypt + username scrub ---
    # Username scrub runs LAST via raw text so the absence check covers the
    # final file content after the JSON mutations above.
    Write-Host "[6/17] [$AppName] Updating Preferences/Local State (salt + os_crypt + username scrub)..." -ForegroundColor Cyan
    $stepFailed = $false
    if (-not (Set-DeviceIdSalt -Path (Join-Path $root "Preferences") -NewSalt $NewSalt -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath (Join-Path $root "Preferences")) -Audit $Audit -Actions $Actions)) {
        $stepFailed = $true
    }
    if (-not (Remove-OsCryptEncryptedKey -Path (Join-Path $root "Local State") -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath (Join-Path $root "Local State")) -Audit $Audit -Actions $Actions)) {
        $stepFailed = $true
    }
    foreach ($scrubPath in @((Join-Path $root "Preferences"), (Join-Path $root "Local State"))) {
        if (-not (Set-UsernameScrubbedFile -Path $scrubPath -Username $env:USERNAME -Replacement "RESET" -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $scrubPath) -Audit $Audit -Actions $Actions)) {
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

    # --- [7/17] Cookies + transport state (delete) ---
    Write-Host "[7/17] [$AppName] Clearing Cookies + transport state..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    $cookieActions = Clear-BinaryIdentityStore -Paths @(
        (Join-Path $root "Network\Cookies"),
        (Join-Path $root "Network\Cookies-journal"),
        (Join-Path $root "Network\Network Persistent State"),
        (Join-Path $root "Network\TransportSecurity")
    ) -Action "delete" -BackupRoot $rootBackupRoot -Audit $Audit -RootPath $root
    $Actions.Value += @($cookieActions)
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] Cookies + transport state cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] Cookies + transport state had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [8/17] DIPS stores (delete) ---
    Write-Host "[8/17] [$AppName] Clearing DIPS stores..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    $dipsActions = Clear-BinaryIdentityStore -Paths @((Join-Path $root "DIPS"), (Join-Path $root "DIPS-wal")) -Action "delete" -BackupRoot $rootBackupRoot -Audit $Audit -RootPath $root
    $Actions.Value += @($dipsActions)
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] DIPS stores cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] DIPS stores had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [9/17] SharedStorage + Trust Tokens ---
    Write-Host "[9/17] [$AppName] Clearing SharedStorage + Trust Tokens..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    $sharedActions = Clear-BinaryIdentityStore -Paths @(
        (Join-Path $root "SharedStorage"),
        (Join-Path $root "SharedStorage-wal"),
        (Join-Path $root "Network\Trust Tokens"),
        (Join-Path $root "Network\Trust Tokens-journal")
    ) -Action "delete" -BackupRoot $rootBackupRoot -Audit $Audit -RootPath $root
    $Actions.Value += @($sharedActions)
    $status = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if ($status.Success) {
        Write-Host "[OK] SharedStorage + Trust Tokens cleared" -ForegroundColor Green
        $PassCount.Value++
    }
    else {
        Write-Host "[FAILED] SharedStorage + Trust Tokens had failures" -ForegroundColor Red
        $FailCount.Value++
    }

    # --- [10/17] cache dirs + Session Storage (per-file; chat stores preserved) ---
    # v0.3 extends the sweep with the rebrand-era cache dirs verified live on
    # 2026-09-21 (CachedData / CachedProfilesData / CachedExtensionVSIXs /
    # CachedConfigurations / DawnGraphiteCache / DawnWebGPUCache / Shared
    # Dictionary). WebStorage + IndexedDB are deliberately NOT touched
    # (unknown contents, possible chat data).
    Write-Host "[10/17] [$AppName] Clearing cache directories + Session Storage..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($relative in @(
            "Cache\Cache_Data", "Code Cache", "GPUCache", "blob_storage", "Service Worker", "Session Storage",
            "CachedData", "CachedProfilesData", "CachedExtensionVSIXs", "CachedConfigurations",
            "DawnGraphiteCache", "DawnWebGPUCache", "Shared Dictionary"
        )) {
        $fullPath = Join-Path $root $relative
        if (Test-Path -LiteralPath $fullPath) {
            $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $fullPath) -Audit $Audit -Actions $Actions
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

    # --- [11/17] Crashpad + logs ---
    Write-Host "[11/17] [$AppName] Clearing Crashpad + logs..." -ForegroundColor Cyan
    $auditStart = $Audit.Value.Count
    foreach ($relative in @("Crashpad", "logs")) {
        $fullPath = Join-Path $root $relative
        if (Test-Path -LiteralPath $fullPath) {
            $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $rootBackupRoot -BackupLabel $relative -Audit $Audit -Actions $Actions
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

    # --- [12/17] workspace UPSERT-only (never delete workspace files) ---
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
            Invoke-WorkspaceSqliteUpdate -WorkspaceDbPath $workspaceDbPath -DeviceId $Ids.devDeviceId -RootPath $root -BackupRoot $rootBackupRoot -Audit $Audit -Actions $Actions
            if ($Audit.Value.Count -gt 0) {
                $lastAuditEntry = $Audit.Value[-1]
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

    # --- [13/17] app-specific files (NEW in v0.3) ---
    # cli\installation_id: the Devin CLI keeps its own install GUID under the
    #   data root (verified live 2026-09-21). Regenerated only when present.
    # credentials.toml: holds windsurf_api_key (the shared auth token). Backed
    #   up, then deleted, so no old-bound credential survives the reset.
    # config.json: devin.org_id blanked via Clear-AppOrgBinding (file kept).
    Write-Host "[13/17] [$AppName] Resetting app-specific files (cli installation_id / credentials.toml / config.json)..." -ForegroundColor Cyan
    $stepFailed = $false

    $cliInstallationIdPath = Join-Path $root "cli\installation_id"
    if (Test-Path -LiteralPath $cliInstallationIdPath) {
        $newCliInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
        if (-not (Set-VerifiedMachineIdFile -Path $cliInstallationIdPath -Value $newCliInstallationId -BackupRoot $rootBackupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $cliInstallationIdPath) -Audit $Audit -Actions $Actions)) {
            $stepFailed = $true
        }
    }
    else {
        Write-Host "    [SKIP] cli\installation_id not present: $cliInstallationIdPath" -ForegroundColor Yellow
        Add-AuditEntry -Audit $Audit -File $cliInstallationIdPath -Key "installation_id" -Before "missing" -After "skipped" -Ok $true
    }

    $credentialsPath = Join-Path $root "credentials.toml"
    $auditStart = $Audit.Value.Count
    $credActions = Clear-BinaryIdentityStore -Paths @($credentialsPath) -Action "delete" -BackupRoot $rootBackupRoot -Audit $Audit -RootPath $root
    $Actions.Value += @($credActions)
    $credStatus = Get-StepAuditStatus -Audit $Audit -StartIndex $auditStart -Path $root
    if (-not $credStatus.Success) {
        $stepFailed = $true
    }

    if (-not (Clear-AppOrgBinding -Path (Join-Path $root "config.json") -BackupRoot $rootBackupRoot -BackupLabel "config.json" -Audit $Audit -Actions $Actions)) {
        $stepFailed = $true
    }

    if ($stepFailed) {
        Write-Host "[FAILED] app-specific files step had failures" -ForegroundColor Red
        $FailCount.Value++
    }
    else {
        $PassCount.Value++
    }

    # --- [14/17] Old ID_Backups purge + watchdog re-verify (this root) ---
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

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Windsurf/Devin Identity Reset v0.3 ===" -ForegroundColor Cyan
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

$newSalt = ([guid]::NewGuid().ToString("N")).ToUpperInvariant()
$newCrashReporterId = Get-NewCrashReporterId
$storageUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}

foreach ($rootEntry in $roots) {
    Invoke-RootReset -AppName $rootEntry.Name -RootPath $rootEntry.Path -Ids $ids -StorageUpdates $storageUpdates -NewSalt $newSalt -NewCrashReporterId $newCrashReporterId -Timestamp $timestamp -Audit ([ref]$audit) -Actions ([ref]$actions) -PassCount ([ref]$passCount) -FailCount ([ref]$failCount)
}

# --- [15/17] home dirs: argv.json + .windsurf installation_id + Codeium -------
Write-Host "`n[15/17] Updating home dirs (argv.json / installation_id / Codeium device_id)..." -ForegroundColor Cyan
$homeStepFailed = $false
# Both argv.json variants carry crash-reporter-id post-rebrand (verified live
# 2026-09-21 in .devin); the handler SKIPs cleanly when a file is absent.
foreach ($argvPath in @($windsurfArgvPath, $devinArgvPath)) {
    if (-not (Update-ArgvJsonIdentity -Path $argvPath -NewCrashReporterId $newCrashReporterId -Username $env:USERNAME -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $argvPath) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
        $homeStepFailed = $true
    }
}

if (Test-Path -LiteralPath $installationIdPath) {
    $newInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
    if (-not (Set-VerifiedMachineIdFile -Path $installationIdPath -Value $newInstallationId -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $installationIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
        $homeStepFailed = $true
    }
}
else {
    Write-Host "    [SKIP] installation_id not present: $installationIdPath" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $installationIdPath -Key "installation_id" -Before "missing" -After "skipped" -Ok $true
}

if (Test-Path -LiteralPath $codeiumConfigPath) {
    if (-not (Set-JsonIdentity -Path $codeiumConfigPath -Updates @{ "device_id" = $ids.devDeviceId } -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $codeiumConfigPath) -Actions ([ref]$actions))) {
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

# --- [16/17] %LOCALAPPDATA% updater sweep (NEW in v0.3) ---
# ONLY the updater cache dirs are deleted. %LOCALAPPDATA%\Programs\<App> is
# the install dir and %LOCALAPPDATA%\devin holds CLI binaries + a non-identity
# telemetry flag (is_zdr) -- both are never touched.
Write-Host "`n[16/17] Sweeping %LOCALAPPDATA% updater dirs (Devin/Windsurf)..." -ForegroundColor Cyan
$auditStart = $audit.Count
foreach ($updaterDir in @((Join-Path $env:LOCALAPPDATA "Devin-updater"), (Join-Path $env:LOCALAPPDATA "Windsurf-updater"))) {
    if (Test-Path -LiteralPath $updaterDir) {
        $null = Clear-TreeFilesIndividually -Path $updaterDir -BackupRoot $backupRoot -BackupLabel (Get-PathBackupLabel -Path $updaterDir) -Audit ([ref]$audit) -Actions ([ref]$actions)
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

[System.IO.File]::WriteAllText("$env:TEMP\devin_v0.3_done.txt", ("Roots: {0} Pass: {1} Fail: {2} Audit: {3}" -f $rootNamesProcessed, $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "Windsurf/Devin reset v0.3 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "Windsurf/Devin reset v0.3 completed successfully." -ForegroundColor Green
