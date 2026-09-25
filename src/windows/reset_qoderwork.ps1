#Requires -Version 5.1
param(
    # v0.1: opt-out switches for the new system-level steps.
    # Default = ON (i.e., do them). Use -SkipMac / -SkipHostname to suppress.
    # Note: NO [CmdletBinding()] -- the v0.3 Qoder launch pattern uses
    # `cmd /c powershell -File <script> *> <log>`, and [CmdletBinding()] makes
    # the `*` in `*>` bind as a positional argument (the script rejects it).
    [switch]$SkipMac,
    [switch]$SkipHostname,
    # Dry-run prints every action it WOULD take without writing or deleting.
    # Useful when you just want to see what would change.
    [switch]$DryRun
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# Self-elevate if not already admin. Re-launch with the same switches so the
# elevated copy sees the user's opt-out choices + dry-run flag.
$qoderWorkIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $qoderWorkIsAdmin) {
    $qoderWorkLogOut = "$env:TEMP\qoderwork_v0.1_result.log"
    $qoderWorkScript = $MyInvocation.MyCommand.Path
    $qoderWorkSwitchList = @()
    if ($SkipMac)      { $qoderWorkSwitchList += "-SkipMac" }
    if ($SkipHostname) { $qoderWorkSwitchList += "-SkipHostname" }
    if ($DryRun)       { $qoderWorkSwitchList += "-DryRun" }
    $qoderWorkSwitchString = if ($qoderWorkSwitchList.Count -gt 0) { " " + ($qoderWorkSwitchList -join " ") } else { "" }
    # Single-string argument list, same proven pattern as v0.3 Qoder.
    $qoderWorkArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$qoderWorkScript`"$qoderWorkSwitchString *> `"$qoderWorkLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $qoderWorkArgs -WindowStyle Normal -Wait
    if (Test-Path $qoderWorkLogOut) {
        Get-Content $qoderWorkLogOut
    }
    if (Test-Path "$env:TEMP\qoderwork_v0.1_done.txt") {
        Get-Content "$env:TEMP\qoderwork_v0.1_done.txt"
    }
    exit
}

Write-GhostBanner -Target "QoderWork Identity Reset" -Version "0.1"

# QoderWork v0.1 -- identity reset + system-level defenses.
#
# Targets a much smaller surface than Qoder. QoderWork's local stores are:
#   %USERPROFILE%\.qoderwork\           machine-id, installation_id, .status.json, .cache, cache, logs
#   %APPDATA%\QoderWork\                rum-electron-store (ARMS RUM = cross-product ID)
#                                       Partitions\main\   (Chromium profile: Network/Local Storage/Preferences/Local State)
#                                       data\agents.db    (Drizzle ORM: oauth tokens, app_settings;
#                                                        chats/sub_chats/messages/projects PRESERVED)
#                                       data\dns-cache\   (Qoder endpoint IP cache)
#                                       SharedStorage\    (Electron SharedStorage 4096 bytes)
#                                       Local State        (Chromium os_crypt encrypted key)
#
# v0.1.1: added auth.dat/auth-v2.dat deletion + HKLM MachineGuid rotation + OTel
#          host.id fix. Renumbered to 26 steps.
# v0.1.2: agents.db no longer DELETEs chats/sub_chats/messages/projects
#          (chat preservation, same policy as all other IDE scripts).
#          Fixed step numbering (all [n/26]) + hostname audit variable.
#
# The script covers N file-level steps + 5 system-level steps, mirroring the
# AGENTS.md "Cursor pattern":
#   - verify-after every write
#   - audit log to <root>\ID_Backups\<ts>\audit_<ts>.json
#   - file-level restore_QoderWork_<ts>.ps1 generated from New-RestoreScript
#   - system-level restore_system_QoderWork_<ts>.ps1 + system_manifest.json
#   - opt-out switches -SkipMac / -SkipHostname, same as v0.3 Qoder
#   - new -DryRun switch prints every action without writing
#
# Out of scope (cannot be fixed locally): server-side ARMS UID re-issuance, the
# WMI hardware fingerprint (soft signals max 0.19 < 0.306 threshold; see
# IMPLEMENTATION_GUIDE section 5), and QoderWork's runtime telemetry that
# forwards hardware signals to api{1,2,3}.qoder.sh / openapi.qoder.sh on every
# extension event. Mitigated only by changing IP / OAuth identity / hardware --
# see the "What this script cannot fix" section at the bottom of this header.

# ----------------------------------------------------------------------------
# Local helpers (specific to QoderWork; identity_utils.ps1 is shared, unchanged)
# ----------------------------------------------------------------------------

# Action manifest entry. Used by all the file-level helpers (Set-VerifiedFlatUuidFile,
# Reset-QoderWorkStatusJson, etc.) to record each backup / rename / delete so the
# generated restore_QoderWork_<ts>.ps1 can rehydrate them. Mirrors the Cursor
# canonical definition (reset_cursor_windows-v0.1.ps1) -- intentionally local rather
# than moved into identity_utils.ps1 to keep the shared lib small.
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

# QoderWork's user-level dir is .qoderwork (not .qoder), and is OUTSIDE %APPDATA%.
# Label backups under USERPROFILE\ so the restore script rehydrates correctly.
function Get-UserProfileBackupLabel {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    if ($TargetPath.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Join-Path "USERPROFILE" ($TargetPath.Substring($env:USERPROFILE.Length).TrimStart("\"))
    }

    return Get-PathBackupLabel -Path $TargetPath
}

# QoderWork's %APPDATA% root may not be the path that gets backed up under a
# shared root. Label under the app root so restore can rehydrate.
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

# A QoderWork flat UUID file: machine-id, installation_id. These are plain text
# UUIDs with no surrounding JSON. Read, set, re-read, verify.
function Set-VerifiedFlatUuidFile {
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
        if (-not $DryRun) {
            $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
            if ($backupPath) {
                Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
            }
        }
    }

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would write '$Value' to $Path (was '$beforeValue')" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "uuid" -Before $beforeValue -After $Value -Ok $true
        return $true
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:63). Set-Content
    # with -Encoding UTF8 emits a BOM under PowerShell 5.1, which corrupts the
    # JSON parsers in QoderWork and falls back to the old UUID.
    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding $false))
    $afterValue = (Get-Content -LiteralPath $Path -Raw).Trim()
    $ok = $afterValue -eq $Value
    Add-AuditEntry -Audit $Audit -File $Path -Key "uuid" -Before $beforeValue -After $afterValue -Ok $ok
    return $ok
}

# QoderWork stores %USERPROFILE%\.qoderwork\.status.json with a tiny schema:
# { logged_in, version, schema_version, product, snapshot_at, writer }
# Reset to a fresh, never-logged-in state without changing version/product.
function Reset-QoderWorkStatusJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "status" -Before "missing" -After "skipped" -Ok $true
        return $true
    }

    if (-not $DryRun) {
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
        if ($backupPath) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
        }
    }

    $before = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    $newObj = [ordered]@{
        logged_in      = $false
        version        = if ($before.PSObject.Properties['version']) { $before.version } else { "" }
        schema_version = if ($before.PSObject.Properties['schema_version']) { $before.schema_version } else { 1 }
        product        = if ($before.PSObject.Properties['product']) { $before.product } else { "qoderwork" }
        snapshot_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        writer         = "main"
    }

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would reset $Path to logged_in=false, fresh snapshot_at" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "logged_in" -Before ($before.logged_in) -After "false" -Ok $true
        return $true
    }

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:384). Set-Content
    # with -Encoding UTF8 emits a BOM under PS 5.1, which Chromium's JSON parser
    # rejects and falls back to the old value.
    [System.IO.File]::WriteAllText($Path, ($newObj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "status" -Before $null -After "parse-failed-after-write" -Ok $false
        return $false
    }

    $ok = ($verified.logged_in -eq $false)
    Add-AuditEntry -Audit $Audit -File $Path -Key "logged_in" -Before ($before.logged_in) -After $verified.logged_in -Ok $ok
    return $ok
}

# QoderWork's external-commands\registry.json records installed external commands
# keyed by id. Reset by overwriting with an empty registry -- next launch will
# re-register what's actually installed.
function Reset-QoderWorkExternalCommandsRegistry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "missing" -After "skipped" -Ok $true
        return $true
    }

    if (-not $DryRun) {
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
        if ($backupPath) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
        }
    }

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would reset $Path to {commands: []}" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "present" -After "empty" -Ok $true
        return $true
    }

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:384). Set-Content
    # with -Encoding UTF8 emits a BOM under PS 5.1, which Chromium's JSON parser
    # rejects and falls back to the old commands list.
    [System.IO.File]::WriteAllText($Path, (@{ commands = @() } | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $ok = ($null -eq $verified.commands) -or ($verified.commands.Count -eq 0)
        Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "present" -After "empty" -Ok $ok
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "present" -After "parse-failed" -Ok $false
        return $false
    }
}

# QoderWork's Preferences is a Chromium-style JSON. The telemetry-sensitive key is
# electron.media.device_id_salt (matches what the Qoder v0.3 script does).
# QoderWork may also use top-level keys like profile.last_active_time or
# telemetry.* -- we set device_id_salt unconditionally and leave the rest.
function Update-QoderWorkPreferences {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewDeviceIdSalt,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before "missing" -After "skipped" -Ok $true
        return $true
    }

    if (-not $DryRun) {
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
        if ($backupPath) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
        }
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $null -After "parse-failed" -Ok $false
        return $false
    }

    $beforeValue = $null
    if ($null -ne $content.PSObject.Properties['electron'] -and
        $null -ne $content.electron.PSObject.Properties['media'] -and
        $null -ne $content.electron.media.PSObject.Properties['device_id_salt']) {
        $beforeValue = $content.electron.media.device_id_salt
    }

    if ($null -eq $content.PSObject.Properties['electron']) {
        $mediaObj = [ordered]@{ device_id_salt = $NewDeviceIdSalt }
        $electronObj = [ordered]@{ media = $mediaObj }
        Add-Member -InputObject $content -NotePropertyName 'electron' -NotePropertyValue $electronObj
    }
    elseif ($null -eq $content.electron.PSObject.Properties['media']) {
        $mediaObj = [ordered]@{ device_id_salt = $NewDeviceIdSalt }
        Add-Member -InputObject $content.electron -NotePropertyName 'media' -NotePropertyValue $mediaObj
    }
    elseif ($null -eq $content.electron.media.PSObject.Properties['device_id_salt']) {
        Add-Member -InputObject $content.electron.media -NotePropertyName 'device_id_salt' -NotePropertyValue $NewDeviceIdSalt
    }
    else {
        $content.electron.media.device_id_salt = $NewDeviceIdSalt
    }

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would write electron.media.device_id_salt='$NewDeviceIdSalt' to $Path (was '$beforeValue')" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $beforeValue -After $NewDeviceIdSalt -Ok $true
        return $true
    }

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:384). Set-Content
    # with -Encoding UTF8 emits a BOM under PS 5.1, which Chromium's Preferences
    # parser rejects and falls back to the old device_id_salt.
    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $beforeValue -After "parse-failed-after-write" -Ok $false
        return $false
    }

    $afterValue = $null
    if ($null -ne $verified.PSObject.Properties['electron'] -and
        $null -ne $verified.electron.PSObject.Properties['media'] -and
        $null -ne $verified.electron.media.PSObject.Properties['device_id_salt']) {
        $afterValue = $verified.electron.media.device_id_salt
    }

    $ok = $afterValue -eq $NewDeviceIdSalt
    Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $beforeValue -After $afterValue -Ok $ok
    return $ok
}

# QoderWork's data\agents.db is a Drizzle ORM SQLite. Key tables to scrub:
#   - app_settings:        {asyncMigrationStatus, windowBounds, channel:*, msConnectorEnabled, proxy}
#                          reset windowBounds/asyncMigrationStatus; preserve proxy/migration_status if sensible
#   - mcp_oauth_tokens:    encrypted MCP server auth blobs
#   - mcp_oauth_tokens_by_user
#   - google_oauth_tokens:  Google OAuth encrypted_payload
#   - ms365_auth_states:    Microsoft 365 OAuth encrypted_payload
#   - byok_custom_models:   encrypted_parameters
#   - rc_session_mappings:  remote control session mappings
#   - channel_pairings*     (Slack, Teams, etc.)
#
# Strategy: DELETE rows from all of these. Verify by SELECT COUNT(*) = 0 read-only.
# This is a subset of what `Clear-QoderSecrets` does for state.vscdb in the Qoder
# v0.3 script -- ported for QoderWork's different schema.
function Clear-QoderWorkAgentsDb {
    param(
        [Parameter(Mandatory = $true)][string]$DbPath,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    $exactKeys = @()  # agents.db has no key/value store; it has typed tables.
    # CHAT PRESERVATION: chats/sub_chats/messages/projects are NEVER deleted.
    # They hold conversation content with no server-side identity signal
    # (same policy as Cursor/Windsurf/Trae/Qoder/ZCode/MiniMax scripts).
    $exactTables = @(
        "mcp_oauth_tokens",
        "mcp_oauth_tokens_by_user",
        "google_oauth_tokens",
        "ms365_auth_states",
        "byok_custom_models",
        "rc_session_mappings",
        "channel_pairings",
        "channel_pairings_v2",
        "knowledge_bases",
        "voice_input_hotwords",
        "voice_input_history",
        "scheduled_tasks",
        "task_run_logs",
        "nudge_logs",
        "skill_evolution_suggestions"
    )
    # app_settings: selectively reset -- only the identity-bearing keys (windowBounds
    # leaks screen geometry; asyncMigrationStatus records the cross-product migration
    # ran). Preserve "proxy" so the user's network config survives.
    $appSettingsResetKeys = @(
        "asyncMigrationStatus",
        "asyncMigrationProgress",
        "windowBounds",
        "channel:xiaoq",
        "channel:msteams",
        "channel:slack",
        "channel:line",
        "channel:figma",
        "channel:google-calendar",
        "channel:google-maps",
        "msConnectorEnabled",
        "ms365AuthFileMigrationV1"
    )

    if (-not (Test-Path -LiteralPath $DbPath)) {
        foreach ($key in ($exactTables + $appSettingsResetKeys)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before "missing" -After "skipped" -Ok $true
        }
        return $true
    }

    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        foreach ($key in ($exactTables + $appSettingsResetKeys)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "python-missing" -Ok $false
        }
        Write-Host "    [FAILED] Python not found - cannot scrub agents.db" -ForegroundColor Red
        return $false
    }

    $exactTablesPy = "[" + (($exactTables | ForEach-Object { "'$_'" }) -join ", ") + "]"
    $appSettingsResetKeysPy = "[" + (($appSettingsResetKeys | ForEach-Object { "'$_'" }) -join ", ") + "]"

    $tempScriptPath = Join-Path $env:TEMP ("qoderwork_scrub_agents_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @"
import json
import sqlite3
import sys

db_path = sys.argv[1]
exact_tables = $exactTablesPy
app_settings_reset_keys = $appSettingsResetKeysPy

result = {"before": {}, "after": {}}
conn = sqlite3.connect(db_path)
try:
    cursor = conn.cursor()
    # Discover which exact_tables actually exist (schema may evolve).
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table'")
    existing = {row[0] for row in cursor.fetchall()}

    for table in exact_tables:
        if table not in existing:
            result["before"][table] = "schema-missing"
            result["after"][table] = "schema-missing"
            continue
        cursor.execute("SELECT COUNT(*) FROM " + table)
        result["before"][table] = cursor.fetchone()[0]
        cursor.execute("DELETE FROM " + table)
        result["after"][table] = 0

    for key in app_settings_reset_keys:
        cursor.execute("SELECT COUNT(*) FROM app_settings WHERE key = ?", (key,))
        result["before"][key] = cursor.fetchone()[0]
        cursor.execute("DELETE FROM app_settings WHERE key = ?", (key,))
        cursor.execute("SELECT COUNT(*) FROM app_settings WHERE key = ?", (key,))
        result["after"][key] = cursor.fetchone()[0]

    conn.commit()
finally:
    conn.close()

print(json.dumps(result))
"@

    try {
        # No-BOM UTF-8 write for the temp .py (mirrors reset_zcode_windows-v1.0.ps1:176).
        # A BOM at the start of the temp file trips CPython's parser before the
        # shebang line is read.
        [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, (New-Object System.Text.UTF8Encoding $false))
        if ($DryRun) {
            Write-Host "    [DRY-RUN] would scrub agents.db tables ($($exactTables.Count)) + app_settings keys ($($appSettingsResetKeys.Count))" -ForegroundColor DarkGray
            foreach ($table in $exactTables) {
                Add-AuditEntry -Audit $Audit -File $DbPath -Key $table -Before "dry-run" -After "would-delete-all" -Ok $true
            }
            foreach ($key in $appSettingsResetKeys) {
                Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before "dry-run" -After "would-delete" -Ok $true
            }
            return $true
        }

        $commandOutput = & $pythonCommand.Source $tempScriptPath $DbPath
        if ($LASTEXITCODE -ne 0) {
            foreach ($key in ($exactTables + $appSettingsResetKeys)) {
                Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "command-failed" -Ok $false
            }
            Write-Host "    [FAILED] agents.db scrub command failed: $DbPath" -ForegroundColor Red
            return $false
        }

        $result = ($commandOutput -join "`n") | ConvertFrom-Json
        $allOk = $true

        foreach ($table in $exactTables) {
            $before = $result.before.$table
            $after = $result.after.$table
            $ok = ($before -is [int]) -and ($after -eq 0)
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $table -Before ("count=" + $before) -After ("count=" + $after) -Ok $ok
            if (-not $ok) { $allOk = $false }
        }

        foreach ($key in $appSettingsResetKeys) {
            $before = $result.before.$key
            $after = $result.after.$key
            $ok = ($before -is [int]) -and ($after -eq 0)
            Add-AuditEntry -Audit $Audit -File $DbPath -Key ("app_settings:" + $key) -Before ("count=" + $before) -After ("count=" + $after) -Ok $ok
            if (-not $ok) { $allOk = $false }
        }

        return $allOk
    }
    catch {
        foreach ($key in ($exactTables + $appSettingsResetKeys)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "exception" -Ok $false
        }
        Write-Host "    [FAILED] agents.db scrub threw: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Wrap Clear-BinaryIdentityStore with DryRun handling. The shared helper in
# identity_utils.ps1 always deletes; it doesn't know about this script's
# DryRun switch. Audit + restore actions get the same values either way so
# -DryRun and a real run produce identical audit JSON, but -DryRun never
# touches the filesystem.
function Invoke-ClearBinaryIdentityStore {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [ValidateSet("rename", "delete")][string]$Action = "delete",
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$RootPath
    )

    $results = @()
    foreach ($path in $Paths) {
        if ($DryRun) {
            $label = if (Test-Path -LiteralPath $path) { "present" } else { "missing" }
            Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before $label -After "would-${Action}" -Ok $true
            Write-Host "    [DRY-RUN] would ${Action}: $path (currently $label)" -ForegroundColor DarkGray
            $results += [ordered]@{
                action       = $Action
                originalPath = $path
                backupPath   = $null
                renamedPath  = $null
            }
        }
        else {
            $stepResults = Clear-BinaryIdentityStore -Paths @($path) -Action $Action -BackupRoot $BackupRoot -Audit $Audit -RootPath $RootPath
            if ($null -ne $stepResults) { $results += @($stepResults) }
        }
    }
    return $results
}

# Post-reset watchdog probe: if a slow-shutdown helper recreated the rum store
# or agents.db core rows within 2s, re-delete. Same pattern as v0.3 Qoder.
function Test-QoderWorkWatchdogRecreation {
    param(
        [Parameter(Mandatory = $true)][string[]]$CorePaths,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    Write-Host "[*] Verifying no watchdog recreated core identity files..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    $recreated = @()
    foreach ($path in $CorePaths) {
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
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After "re-deleted" -Ok $true
    }
}

# Old ID_Backups directories (from previous reset runs) preserve complete snapshots
# of every identity file with the OLD ID still embedded. Keep newest only.
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
        if ($DryRun) {
            Write-Host "    [DRY-RUN] would purge older backup: $($dir.Name)" -ForegroundColor DarkGray
            continue
        }
        Write-Host "    [PURGE] $($dir.Name) (preserved old fingerprint; deleting)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "deleted" -Ok $true
    }
}

# Set and verify a REG_SZ value. Used for the source IDs that live outside the
# application data files: HKCU\...\DeveloperTools\deviceid and
# HKLM\...\SQMClient\MachineId. Returns enough metadata for system_manifest.json.
function Set-VerifiedRegistryStringValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    if ($DryRun) {
        $current = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        Write-Host "    [DRY-RUN] would write registry ${Path}\${Name} = '$Value' (was '$current')" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key $Name -Before $current -After $Value -Ok $true
        return @{ Success = $true; Path = $Path; Name = $Name; PathExisted = $true; ValueExisted = ($null -ne $current); Before = $current; After = $Value }
    }

    $pathExisted = Test-Path -LiteralPath $Path
    $valueExisted = $false
    $beforeValue = $null

    if (-not $pathExisted) {
        try {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Add-AuditEntry -Audit $Audit -File $Path -Key $Name -Before "path-missing" -After ("key-create-failed: " + $_.Exception.Message) -Ok $false
            Write-Host "    [FAILED] could not create registry key: $Path" -ForegroundColor Red
            return @{ Success = $false; Path = $Path; Name = $Name; PathExisted = $pathExisted; ValueExisted = $valueExisted; Before = $beforeValue; After = $null }
        }
    }

    $beforeProps = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($beforeProps -and $null -ne $beforeProps.PSObject.Properties[$Name]) {
        $valueExisted = $true
        $beforeValue = $beforeProps.$Name
    }

    try {
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType String -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key $Name -Before $beforeValue -After ("write-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] registry write failed: $Path\$Name" -ForegroundColor Red
        return @{ Success = $false; Path = $Path; Name = $Name; PathExisted = $pathExisted; ValueExisted = $valueExisted; Before = $beforeValue; After = $null }
    }

    $afterProps = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    $afterValue = $null
    if ($afterProps -and $null -ne $afterProps.PSObject.Properties[$Name]) {
        $afterValue = $afterProps.$Name
    }

    $ok = ($afterValue -eq $Value)
    Add-AuditEntry -Audit $Audit -File $Path -Key $Name -Before $beforeValue -After $afterValue -Ok $ok
    if ($ok) {
        Write-Host "    [OK] ${Path}\${Name}: $beforeValue -> $afterValue" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] registry verify failed: $Path\$Name (got=$afterValue expected=$Value)" -ForegroundColor Red
    }

    return @{ Success = $ok; Path = $Path; Name = $Name; PathExisted = $pathExisted; ValueExisted = $valueExisted; Before = $beforeValue; After = $afterValue }
}

# 6 random bytes with bit 0 = 0 (unicast) and bit 1 = 1 (locally-administered)
# per IEEE 802. Returned as 12 uppercase hex chars, no separators -- the format
# Windows stores in NetworkAddress (REG_SZ). Ported from v0.3 Qoder script.
function New-RandomMacAddress {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 6
        $rng.GetBytes($bytes)
        $bytes[0] = ($bytes[0] -band 0xFC) -bor 0x02
        return (($bytes | ForEach-Object { $_.ToString("X2") }) -join "")
    }
    finally {
        if ($rng) { $rng.Dispose() }
    }
}

# Local New-RandomHostname removed (v0.1.2): use Get-NewHostname from
# identity_utils.ps1 -- DESKTOP-XXXXXXX factory-default pattern instead of
# the recognizable WIN-XXXXXXXX reset-tool signature.
function New-RandomHostname {
    return Get-NewHostname
}

# Match a Get-NetAdapter.InterfaceGuid to its class registry key.
$NicClassRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
function Find-AdapterClassKey {
    param([Parameter(Mandatory = $true)][string]$InterfaceGuid)

    if (-not (Test-Path -LiteralPath $NicClassRoot)) {
        return $null
    }

    $normalized = $InterfaceGuid.Trim().ToLower()
    foreach ($item in @(Get-ChildItem -LiteralPath $NicClassRoot -ErrorAction SilentlyContinue)) {
        $netCfgId = (Get-ItemProperty -LiteralPath $item.PSPath -Name "NetCfgInstanceId" -ErrorAction SilentlyContinue).NetCfgInstanceId
        if ($netCfgId -and $netCfgId.Trim().ToLower() -eq $normalized) {
            return $item
        }
    }
    return $null
}

# Write NetworkAddress to the adapter's class key, then disable+enable.
function Set-AdapterMacAddress {
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][string]$NewMac,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    $name = $Adapter.Name
    $interfaceGuid = $Adapter.InterfaceGuid
    $oldMac = $Adapter.MacAddress

    $auditFile = "NetAdapter::$name"
    $auditKey  = "NetworkAddress"

    $classKey = Find-AdapterClassKey -InterfaceGuid $interfaceGuid
    if (-not $classKey) {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After $NewMac -Ok $false
        Write-Host "    [FAILED] no class key found for adapter $name (guid=$interfaceGuid)" -ForegroundColor Red
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac }
    }

    $previousValue = (Get-ItemProperty -LiteralPath $classKey.PSPath -Name "NetworkAddress" -ErrorAction SilentlyContinue).NetworkAddress

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would write NetworkAddress='$NewMac' to $name (was '$oldMac')" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After $NewMac -Ok $true
        return @{ Success = $true; OldMac = $oldMac; NewMac = $NewMac; PreviousRegistryValue = $previousValue }
    }

    try {
        Set-ItemProperty -LiteralPath $classKey.PSPath -Name "NetworkAddress" -Value $NewMac -Type String -Force -ErrorAction Stop
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("registry-write-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] could not write NetworkAddress for $name" -ForegroundColor Red
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac }
    }

    try {
        Disable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("disable-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [WARN] registry written but disable failed for $name -- reboot may be required" -ForegroundColor Yellow
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac; PreviousRegistryValue = $previousValue }
    }

    Start-Sleep -Seconds 3

    try {
        Enable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("enable-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] enable failed for $name -- network may be down, manual intervention required" -ForegroundColor Red
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac; PreviousRegistryValue = $previousValue }
    }

    Start-Sleep -Seconds 5

    $verified = $null
    try {
        $verified = (Get-NetAdapter -Name $name -ErrorAction Stop).MacAddress
    }
    catch {
        Start-Sleep -Seconds 5
        try {
            $verified = (Get-NetAdapter -Name $name -ErrorAction Stop).MacAddress
        }
        catch {
            $verified = $null
        }
    }

    $normalizedVerified = ($verified -replace '-', '').ToUpper()
    $expected = $NewMac.ToUpper()
    $ok = ($normalizedVerified -eq $expected)

    if ($ok) {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After $verified -Ok $true
        Write-Host "    [OK] $name MAC: $oldMac -> $verified" -ForegroundColor Green
    }
    else {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("expected $expected got $normalizedVerified") -Ok $false
        Write-Host "    [FAILED] $name MAC verify failed: got $verified, expected $expected" -ForegroundColor Red
    }

    return @{ Success = $ok; OldMac = $oldMac; NewMac = $NewMac; PreviousRegistryValue = $previousValue }
}

function Set-SystemHostname {
    param(
        [Parameter(Mandatory = $true)][string]$NewHostname,
        [Parameter(Mandatory = $true)][string]$OldHostname,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would rename computer $OldHostname -> $NewHostname" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName" -Key "ComputerName" -Before $OldHostname -After $NewHostname -Ok $true
        return $true
    }

    $auditFile = "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName"
    $auditKey  = "ComputerName"

    if ($NewHostname.Length -gt 15) {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $OldHostname -After ("too-long: " + $NewHostname) -Ok $false
        Write-Host "    [FAILED] hostname exceeds 15 chars (NetBIOS limit): $NewHostname" -ForegroundColor Red
        return $false
    }

    try {
        Rename-Computer -NewName $NewHostname -Force -ErrorAction Stop
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $OldHostname -After ("rename-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] Rename-Computer failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    # Verified against this box (2026-07-09, Windows 11):
    #   HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName  <-- the truly live key
    #     Rename-Computer updates this synchronously; Win32 APIs (GetComputerName, $env:COMPUTERNAME
    #     in fresh processes) read from here immediately.
    #   HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Hostname
    #     NOT updated by Rename-Computer without -Restart. Stays old until the next boot.
    #   HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName
    #     Also stays old until reboot (kernel swaps it with ComputerName\ComputerName at boot).
    #   HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\NV Hostname
    #     Updated by Rename-Computer; the kernel swaps it with Tcpip\Parameters\Hostname at boot.
    # So the only synchronous signal we can rely on is ComputerName\ComputerName. Checking the
    # other three here produces a false-fail every time the script runs without -Restart.
    $activeComputerName = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue).ComputerName
    $tcpipHost          = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Hostname" -ErrorAction SilentlyContinue).Hostname
    $nextBootActive     = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue).ComputerName
    $nextBootNv         = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Hostname" -ErrorAction SilentlyContinue)."NV Hostname"

    $liveOk = ($activeComputerName -eq $NewHostname)
    $nextBootPending = ($nextBootActive -ne $NewHostname) -or ($nextBootNv -ne $NewHostname) -or ($tcpipHost -ne $NewHostname)

    $after = "active=$activeComputerName/$tcpipHost; nextBoot=$nextBootActive/$nextBootNv"
    if ($liveOk) {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $OldHostname -After $NewHostname -Ok $true
        if ($nextBootPending) {
            Write-Host "    [OK] hostname registry updated: $OldHostname -> $NewHostname (ActiveComputerName + NV Hostname sync at next boot)" -ForegroundColor Green
        }
        else {
            Write-Host "    [OK] hostname registry fully updated: $OldHostname -> $NewHostname" -ForegroundColor Green
        }
    }
    else {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $OldHostname -After $after -Ok $false
        Write-Host "    [FAILED] live hostname keys do not match: $after" -ForegroundColor Red
    }

    return $liveOk
}

# Generate restore_system_QoderWork_<ts>.ps1 to roll back registry source IDs +
# NIC MAC + hostname. Same logic as v0.3 Qoder.
function New-SystemRestoreScript {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$App,
        [Parameter(Mandatory = $true)][hashtable]$Manifest,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $manifestJson = $Manifest | ConvertTo-Json -Depth 10
    $restorePath = Join-Path $BackupRoot ("restore_system_{0}_{1}.ps1" -f $App, $Timestamp)
    $scriptContent = @"
# Restore script for system-level changes made by reset_qoderwork_windows-v0.1.ps1
# Generated: $Timestamp
#
# Run from an elevated PowerShell prompt. Idempotent. Does NOT touch QoderWork
# application data; that is handled by the file-level restore_`$App`_`$Timestamp.ps1
# in the same directory.

`$ErrorActionPreference = "Stop"

`$manifestJson = @'
$manifestJson
'@

`$manifest = `$manifestJson | ConvertFrom-Json

if (`$manifest.registry) {
    foreach (`$entry in `$manifest.registry) {
        Write-Host "[RESTORE] registry `$(`$entry.path)\`$(`$entry.name)" -ForegroundColor Cyan
        try {
            if (`$entry.valueExisted) {
                if (-not (Test-Path -LiteralPath `$entry.path)) {
                    New-Item -Path `$entry.path -Force -ErrorAction Stop | Out-Null
                }
                New-ItemProperty -LiteralPath `$entry.path -Name `$entry.name -Value `$entry.old -PropertyType String -Force -ErrorAction Stop | Out-Null
                Write-Host "    [OK] restored" -ForegroundColor Green
            } else {
                if (Test-Path -LiteralPath `$entry.path) {
                    Remove-ItemProperty -LiteralPath `$entry.path -Name `$entry.name -Force -ErrorAction SilentlyContinue
                    if (-not `$entry.pathExisted) {
                        Remove-Item -LiteralPath `$entry.path -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                Write-Host "    [OK] removed value that was created by reset" -ForegroundColor Green
            }
        } catch {
            Write-Host "    [FAILED] registry restore failed: `$(`$_.Exception.Message)" -ForegroundColor Red
        }
    }
}

if (`$manifest.hostname.old -and (`$manifest.hostname.old -ne `$env:COMPUTERNAME)) {
    Write-Host "[RESTORE] hostname: `$env:COMPUTERNAME -> `$(`$manifest.hostname.old)" -ForegroundColor Cyan
    try {
        Rename-Computer -NewName `$manifest.hostname.old -Force -ErrorAction Stop
        Write-Host "    [OK] hostname registry updated. Restart Windows for live processes to see the new name." -ForegroundColor Green
    } catch {
        Write-Host "    [FAILED] Rename-Computer failed: `$(`$_.Exception.Message)" -ForegroundColor Red
    }
}

`$classRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"
`$interfaceGuidMap = @{}
if (Test-Path -LiteralPath `$classRoot) {
    foreach (`$item in @(Get-ChildItem -LiteralPath `$classRoot -ErrorAction SilentlyContinue)) {
        `$netCfgId = (Get-ItemProperty -LiteralPath `$item.PSPath -Name "NetCfgInstanceId" -ErrorAction SilentlyContinue).NetCfgInstanceId
        if (`$netCfgId) {
            `$interfaceGuidMap[`$netCfgId.Trim().ToLower()] = `$item.PSPath
        }
    }
}

foreach (`$adapter in `$manifest.adapters) {
    Write-Host "[RESTORE] NIC `$(`$adapter.name): -> `$(`$adapter.oldMac)" -ForegroundColor Cyan
    `$psPath = `$interfaceGuidMap[`$adapter.interfaceGuid.ToLower()]
    if (-not `$psPath) { continue }
    `$oldMacNoSep = (`$adapter.oldMac -replace '-', '').ToUpper()
    try {
        Set-ItemProperty -LiteralPath `$psPath -Name "NetworkAddress" -Value `$oldMacNoSep -Type String -Force -ErrorAction Stop
        Disable-NetAdapter -Name `$adapter.name -Confirm:`$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 3
        Enable-NetAdapter -Name `$adapter.name -Confirm:`$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 5
        Write-Host "    [OK] `$(`$adapter.name) MAC restored" -ForegroundColor Green
    } catch {
        Write-Host "    [WARN] adapter cycle failed: `$(`$_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "System restore complete. Restart Windows for the hostname change to apply to live processes." -ForegroundColor Green
"@

    # No-BOM UTF-8 write for the generated restore script (mirrors
    # reset_zcode_windows-v1.0.ps1). The restore script is itself PowerShell; a
    # BOM at byte 0 is harmless to the parser but inconsistent with the rest of
    # the no-BOM pipeline.
    [System.IO.File]::WriteAllText($restorePath, $scriptContent, (New-Object System.Text.UTF8Encoding $false))
    return $restorePath
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

Assert-Administrator

$app = "QoderWork"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$root = Join-Path $env:APPDATA $app
$backupRoot = Join-Path $root ("ID_Backups\" + $timestamp)
$idBackupsRoot = Join-Path $root "ID_Backups"
$userQoderWorkRoot = Join-Path $env:USERPROFILE ".qoderwork"

# Partitions\main is QoderWork's Chromium profile root. We don't have a CORS_Profile
# in QoderWork (that's Qoder-specific), so single profile.
$profileRoot = Join-Path $root "Partitions\main"

if (-not (Test-Path -LiteralPath $root)) {
    Write-Host "QoderWork installation not found at: $root" -ForegroundColor Red
    exit 1
}

if ($DryRun) {
    Write-Host "=== QoderWork Identity Reset (v0.1) -- DRY RUN ===" -ForegroundColor Magenta
} else {
    New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
    Write-Host "=== QoderWork Identity Reset (v0.1) ===" -ForegroundColor Cyan
}

Write-Host "Root: $root" -ForegroundColor Gray
Write-Host "Profile: $profileRoot" -ForegroundColor Gray
Write-Host "User-level: $userQoderWorkRoot" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray

# Pre-step: aggressive tree-kill. QoderWork has fewer helper processes than Qoder,
# but we still want to nuke any orphan holders.
Write-Host "`n[*] Terminating QoderWork processes..." -ForegroundColor Cyan
$stopped = $false
for ($attempt = 1; $attempt -le 8; $attempt++) {
    $running = @(Get-Process -Name "QoderWork*" -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        $stopped = $true
        Write-Host "[OK] no QoderWork processes running" -ForegroundColor Green
        break
    }
    foreach ($p in $running) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    Start-Sleep -Seconds 2
}
if (-not $stopped) {
    Write-Host "[FAILED] QoderWork processes still running after 8 attempts" -ForegroundColor Red
    $still = @(Get-Process -Name "QoderWork*" -ErrorAction SilentlyContinue)
    foreach ($p in $still) {
        Write-Host ("    PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    exit 1
}

$passCount = 0
$failCount = 0

$audit = @()
$actions = @()
$ids = New-IdentitySet

# QoderWork-specific identity values, distinct from VS Code telemetry IDs.
$deviceIdSalt = ([guid]::NewGuid().ToString("N")).ToUpperInvariant()
$newMachineId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()

# --- [1/26] machine-id (user-level) ---
Write-Host "`n[1/26] Updating ~\.qoderwork\machine-id..." -ForegroundColor Cyan
$machineIdPath = Join-Path $userQoderWorkRoot "machine-id"
$machineIdLabel = Get-UserProfileBackupLabel -TargetPath $machineIdPath
if (Set-VerifiedFlatUuidFile -Path $machineIdPath -Value $newMachineId -BackupRoot $backupRoot -BackupLabel $machineIdLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] machine-id verified" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] machine-id verification failed" -ForegroundColor Red
    $failCount++
}

# --- [2/26] installation_id (user-level) ---
Write-Host "`n[2/26] Updating ~\.qoderwork\installation_id..." -ForegroundColor Cyan
$installIdPath = Join-Path $userQoderWorkRoot "installation_id"
$installIdLabel = Get-UserProfileBackupLabel -TargetPath $installIdPath
if (Set-VerifiedFlatUuidFile -Path $installIdPath -Value $newInstallationId -BackupRoot $backupRoot -BackupLabel $installIdLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] installation_id verified" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] installation_id verification failed" -ForegroundColor Red
    $failCount++
}

# --- [3/26] .status.json reset ---
Write-Host "`n[3/26] Resetting ~\.qoderwork\.status.json (logged_in=false, fresh snapshot)..." -ForegroundColor Cyan
$statusPath = Join-Path $userQoderWorkRoot ".status.json"
$statusLabel = Get-UserProfileBackupLabel -TargetPath $statusPath
if (Reset-QoderWorkStatusJson -Path $statusPath -BackupRoot $backupRoot -BackupLabel $statusLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] .status.json reset" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] .status.json reset failed" -ForegroundColor Red
    $failCount++
}

# --- [4/26] external-commands\registry.json reset ---
Write-Host "`n[4/26] Resetting ~\.qoderwork\external-commands\registry.json..." -ForegroundColor Cyan
$extRegPath = Join-Path $userQoderWorkRoot "external-commands\registry.json"
$extRegLabel = Get-UserProfileBackupLabel -TargetPath $extRegPath
if (Reset-QoderWorkExternalCommandsRegistry -Path $extRegPath -BackupRoot $backupRoot -BackupLabel $extRegLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] external-commands registry reset" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] external-commands registry reset failed" -ForegroundColor Red
    $failCount++
}

# --- [5/26] ~\.qoderwork\.cache\ deletion ---
Write-Host "`n[5/26] Deleting ~\.qoderwork\.cache\..." -ForegroundColor Cyan
$dotCachePath = Join-Path $userQoderWorkRoot ".cache"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($dotCachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] .cache" -ForegroundColor Green
$passCount++

# --- [6/26] ~\.qoderwork\cache\ deletion (MCP market cache) ---
Write-Host "`n[6/26] Deleting ~\.qoderwork\cache\..." -ForegroundColor Cyan
$cachePath = Join-Path $userQoderWorkRoot "cache"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($cachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] cache" -ForegroundColor Green
$passCount++

# --- [7/26] ~\.qoderwork\logs\ deletion ---
Write-Host "`n[7/26] Deleting ~\.qoderwork\logs\..." -ForegroundColor Cyan
$logsPath = Join-Path $userQoderWorkRoot "logs"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($logsPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] logs" -ForegroundColor Green
$passCount++

# --- [8/26] rum-electron-store\ deletion (CROSS-PRODUCT RUM ID) ---
# This is the single most important file in the script. The Alibaba ARMS
# _arms_uid persisted here is what the ARMS backend uses to correlate this
# QoderWork install with the previously-banned Qoder install.
Write-Host "`n[8/26] Deleting Roaming\QoderWork\rum-electron-store\ (cross-product RUM)..." -ForegroundColor Cyan
$rumStorePath = Join-Path $root "rum-electron-store"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($rumStorePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] rum-electron-store (ARMS _arms_uid wiped)" -ForegroundColor Green
$passCount++

# --- [9/26] Local State (Chromium os_crypt encrypted key) ---
Write-Host "`n[9/26] Deleting Roaming\QoderWork\Local State (Chromium os_crypt key)..." -ForegroundColor Cyan
$localStatePath = Join-Path $root "Local State"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($localStatePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] Local State" -ForegroundColor Green
$passCount++

# --- [10/26] Partitions\main\Preferences device_id_salt ---
Write-Host "`n[10/26] Updating Partitions\main\Preferences electron.media.device_id_salt..." -ForegroundColor Cyan
$prefsPath = Join-Path $profileRoot "Preferences"
$prefsLabel = Get-AppRelativeBackupLabel -RootPath $profileRoot -TargetPath $prefsPath
if (Update-QoderWorkPreferences -Path $prefsPath -NewDeviceIdSalt $deviceIdSalt -BackupRoot $backupRoot -BackupLabel $prefsLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] Preferences device_id_salt verified" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Preferences device_id_salt verification failed" -ForegroundColor Red
    $failCount++
}

# --- [11/26] Partitions\main\Network\Cookies + Network Persistent State ---
Write-Host "`n[11/26] Deleting Partitions\main\Network\Cookies + Network Persistent State..." -ForegroundColor Cyan
$netPaths = @(
    (Join-Path $profileRoot "Network\Cookies"),
    (Join-Path $profileRoot "Network\Cookies-journal"),
    (Join-Path $profileRoot "Network\Network Persistent State"),
    (Join-Path $profileRoot "Network\TransportSecurity"),
    (Join-Path $profileRoot "Network\Trust Tokens"),
    (Join-Path $profileRoot "Network\Trust Tokens-journal"),
    (Join-Path $profileRoot "Network\NetworkDataMigrated")
)
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths $netPaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] Network stores" -ForegroundColor Green
$passCount++

# --- [12/26] Partitions\main\Local Storage\ (LevelDB) ---
Write-Host "`n[12/26] Deleting Partitions\main\Local Storage\ (LevelDB identity keys)..." -ForegroundColor Cyan
$localStoragePath = Join-Path $profileRoot "Local Storage"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($localStoragePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] Local Storage" -ForegroundColor Green
$passCount++

# --- [13/26] Partitions\main\Session Storage\ ---
Write-Host "`n[13/26] Deleting Partitions\main\Session Storage\..." -ForegroundColor Cyan
$sessionStoragePath = Join-Path $profileRoot "Session Storage"
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($sessionStoragePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] Session Storage" -ForegroundColor Green
$passCount++

# --- [14/26] Partitions\main\Shared Dictionary\ ---
Write-Host "`n[14/26] Deleting Partitions\main\Shared Dictionary\..." -ForegroundColor Cyan
$sharedDictPath = Join-Path $profileRoot "Shared Dictionary"
$binaryActions = Clear-BinaryIdentityStore -Paths @($sharedDictPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] Shared Dictionary" -ForegroundColor Green
$passCount++

# --- [15/26] Partitions\main\Cache\ + Code Cache\ + GPUCache\ + Dawn*Cache\ ---
Write-Host "`n[15/26] Deleting Partitions\main\Cache\ + Code Cache\ + GPUCache\ + Dawn*Cache\..." -ForegroundColor Cyan
$cachePaths = @(
    (Join-Path $profileRoot "Cache"),
    (Join-Path $profileRoot "Code Cache"),
    (Join-Path $profileRoot "GPUCache"),
    (Join-Path $profileRoot "DawnGraphiteCache"),
    (Join-Path $profileRoot "DawnWebGPUCache"),
    (Join-Path $profileRoot "blob_storage")
)
$binaryActions = Clear-BinaryIdentityStore -Paths $cachePaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] cache trees" -ForegroundColor Green
$passCount++

# --- [16/26] Roaming\QoderWork\SharedStorage\ (Electron SharedStorage 4KB file) ---
Write-Host "`n[16/26] Deleting Roaming\QoderWork\SharedStorage\..." -ForegroundColor Cyan
$sharedStoragePath = Join-Path $root "SharedStorage"
$binaryActions = Clear-BinaryIdentityStore -Paths @($sharedStoragePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] SharedStorage" -ForegroundColor Green
$passCount++

# --- [17/26] data\dns-cache\ deletion (Qoder endpoint IP cache) ---
Write-Host "`n[17/26] Deleting data\dns-cache\ (Qoder endpoint IP cache)..." -ForegroundColor Cyan
$dnsCachePath = Join-Path $root "data\dns-cache"
$binaryActions = Clear-BinaryIdentityStore -Paths @($dnsCachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
Write-Host "    [OK] data\dns-cache" -ForegroundColor Green
$passCount++

# --- [18/26] data\dynamic-text\qoder-work.json: KEEP (UI strings, not identity) ---
# Note: This file contains error.114 (the cross-product ban message). We do NOT
# delete it because it's just localized UI strings -- deleting it would force a
# download on next launch and isn't related to identity. Just recorded.
Write-Host "`n[18/26] Preserving data\dynamic-text\qoder-work.json (UI strings only, not identity)..." -ForegroundColor Cyan
Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "data\dynamic-text\qoder-work.json") -Key "preserved" -Before "present" -After "preserved" -Ok $true
Write-Host "    [SKIP] dynamic-text is non-identity resource bundle" -ForegroundColor DarkGray
$passCount++

# --- [19/26] data\agents.db scrub (oauth tokens + app_settings; chats preserved) ---
Write-Host "`n[19/26] Scrubbing data\agents.db (oauth/app_settings tables; chats preserved)..." -ForegroundColor Cyan
$agentsDbPath = Join-Path $root "data\agents.db"
if (-not $DryRun) {
    $backupAgentsDb = Backup-FileToTimestampDir -Source $agentsDbPath -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $agentsDbPath)
    if ($backupAgentsDb) {
        Add-ActionEntry -Actions ([ref]$actions) -OriginalPath $agentsDbPath -BackupPath $backupAgentsDb
    }
}
if (Clear-QoderWorkAgentsDb -DbPath $agentsDbPath -Audit ([ref]$audit)) {
    Write-Host "    [OK] agents.db scrubbed" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] agents.db scrub failed" -ForegroundColor Red
    $failCount++
}

# --- [20/26] Old ID_Backups purge (keep newest only) ---
Write-Host "`n[20/26] Purging old ID_Backups directories (keep current run only)..." -ForegroundColor Cyan
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit)
$passCount++

# --- [21/26] Post-write watchdog re-verify ---
Write-Host "`n[21/26] Post-write watchdog re-verify..." -ForegroundColor Cyan
$watchdogCorePaths = @($rumStorePath, $localStatePath)
if (-not $DryRun) {
    Test-QoderWorkWatchdogRecreation -CorePaths $watchdogCorePaths -Audit ([ref]$audit)
}
$passCount++

# === SYSTEM-LEVEL STEPS (mirrors v0.3 Qoder; opt-out via -SkipMac / -SkipHostname) ===

$systemManifest = @{
    hostname = @{ old = $env:COMPUTERNAME; new = $null }
    adapters = @()
    registry = @()
}

# --- [22/26] auth.dat + auth-v2.dat deletion (encrypted auth tokens) ---
$authBinaries = @((Join-Path $root "auth.dat"), (Join-Path $root "auth-v2.dat"))
$existingAuthFiles = @($authBinaries | Where-Object { Test-Path -LiteralPath $_ })
if ($existingAuthFiles.Count -eq 0) {
    Write-Host "`n[22/26] Deleting auth.dat/auth-v2.dat..." -ForegroundColor Cyan
    Write-Host "    [SKIP] not present" -ForegroundColor DarkGray
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "auth.dat") -Key "auth-binary" -Before "missing" -After "skipped" -Ok $true
    $passCount++
} else {
    Write-Host "`n[22/26] Deleting auth.dat/auth-v2.dat (encrypted auth tokens)..." -ForegroundColor Cyan
    $authActions = Clear-BinaryIdentityStore -Paths $existingAuthFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
    if (-not $DryRun) { $actions += @($authActions) }
    Write-Host "    [OK] auth binaries" -ForegroundColor Green
    $passCount++
}

# --- [23/26] HKLM MachineGuid source rotation (QoderWork OTel reads this via REG.exe) ---
Write-Host "`n[23/26] Rotating HKLM\\SOFTWARE\\Microsoft\\Cryptography\\MachineGuid..." -ForegroundColor Cyan
$machineGuidPath = "HKLM:\SOFTWARE\Microsoft\Cryptography"
$newMachineGuid = [guid]::NewGuid().ToString().ToLower()
$machineGuidResult = Set-VerifiedRegistryStringValue -Path $machineGuidPath -Name "MachineGuid" -Value $newMachineGuid -Audit ([ref]$audit)
$systemManifest.registry += @{
    path         = $machineGuidPath
    name         = "MachineGuid"
    old          = $machineGuidResult.Before
    new          = $newMachineGuid
    pathExisted  = [bool]$machineGuidResult.PathExisted
    valueExisted = [bool]$machineGuidResult.ValueExisted
}
if ($machineGuidResult.Success) { $passCount++ } else { $failCount++ }

# --- [24/26] HKCU DeveloperTools deviceid source ---
Write-Host "`n[24/26] Updating HKCU DeveloperTools deviceid source..." -ForegroundColor Cyan
$developerToolsPath = "HKCU:\SOFTWARE\Microsoft\DeveloperTools"
$developerToolsResult = Set-VerifiedRegistryStringValue -Path $developerToolsPath -Name "deviceid" -Value $ids.devDeviceId -Audit ([ref]$audit)
$systemManifest.registry += @{
    path         = $developerToolsPath
    name         = "deviceid"
    old          = $developerToolsResult.Before
    new          = $ids.devDeviceId
    pathExisted  = [bool]$developerToolsResult.PathExisted
    valueExisted = [bool]$developerToolsResult.ValueExisted
}
if ($developerToolsResult.Success) { $passCount++ } else { $failCount++ }

# --- [25/26] HKLM SQMClient MachineId source ---
Write-Host "`n[25/26] Updating HKLM SQMClient MachineId source..." -ForegroundColor Cyan
$sqmClientPath = "HKLM:\SOFTWARE\Microsoft\SQMClient"
$sqmClientResult = Set-VerifiedRegistryStringValue -Path $sqmClientPath -Name "MachineId" -Value $ids.sqmId -Audit ([ref]$audit)
$systemManifest.registry += @{
    path         = $sqmClientPath
    name         = "MachineId"
    old          = $sqmClientResult.Before
    new          = $ids.sqmId
    pathExisted  = [bool]$sqmClientResult.PathExisted
    valueExisted = [bool]$sqmClientResult.ValueExisted
}
if ($sqmClientResult.Success) { $passCount++ } else { $failCount++ }

# --- [26/26] NIC MAC + Hostname (system-level defenses) ---
if ($SkipMac) {
    Write-Host "`n[26/26-OPT] SKIPPED (-SkipMac) -- NIC MAC addresses left unchanged" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File "NetAdapter::all" -Key "NetworkAddress" -Before "skipped" -After "skipped-by-user" -Ok $true
} else {
    Write-Host "`n[26/26-OPT] Rotating NIC MAC addresses (physical adapters only)..." -ForegroundColor Cyan
    $physicalAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })

    if ($physicalAdapters.Count -eq 0) {
        Write-Host "    [WARN] no physical, Up adapters found -- nothing to do" -ForegroundColor Yellow
        Add-AuditEntry -Audit ([ref]$audit) -File "NetAdapter::all" -Key "NetworkAddress" -Before "none" -After "no-adapters" -Ok $true
    } else {
        $macFailed = $false
        foreach ($adapter in $physicalAdapters) {
            if ($adapter.Name -match '^Loopback') { continue }
            $newMac = New-RandomMacAddress
            $result = Set-AdapterMacAddress -Adapter $adapter -NewMac $newMac -Audit ([ref]$audit)
            if (-not $result.Success) { $macFailed = $true }
            $systemManifest.adapters += @{
                name          = $adapter.Name
                interfaceGuid = $adapter.InterfaceGuid
                oldMac        = $result.OldMac
                newMac        = $result.NewMac
            }
        }
        if ($macFailed) { $failCount++ } else { $passCount++ }
    }
}

if ($SkipHostname) {
    Write-Host "`n[26/26-OPT] SKIPPED (-SkipHostname) -- hostname left unchanged" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName" -Key "ComputerName" -Before "skipped" -After "skipped-by-user" -Ok $true
} else {
    Write-Host "`n[26/26-OPT] Changing hostname (registry-only, restart required)..." -ForegroundColor Cyan
    $newHostname = New-RandomHostname
    Write-Host "    old: $env:COMPUTERNAME -> new: $newHostname" -ForegroundColor Gray
    if (Set-SystemHostname -NewHostname $newHostname -OldHostname $env:COMPUTERNAME -Audit ([ref]$audit)) {
        $systemManifest.hostname.new = $newHostname
        $passCount++
    } else {
        $systemManifest.hostname.new = $null
        $failCount++
    }
}

# --- Persist system manifest + generate system restore script ---
$systemManifestPath = Join-Path $backupRoot "system_manifest.json"
if (-not $DryRun) {
    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1). system_manifest.json
    # is read back by the restore script; emitting a BOM corrupts ConvertFrom-Json.
    [System.IO.File]::WriteAllText($systemManifestPath, ($systemManifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
}
Add-AuditEntry -Audit ([ref]$audit) -File $systemManifestPath -Key "system-manifest" -Before "none" -After "saved" -Ok $true
Write-Host ""
Write-Host "[*] System manifest saved: $systemManifestPath" -ForegroundColor Gray

$systemRestoreScriptPath = New-SystemRestoreScript -BackupRoot $backupRoot -App $app -Manifest $systemManifest -Timestamp $timestamp
Write-Host "[*] System restore script: $systemRestoreScriptPath" -ForegroundColor Gray

# --- Audit + file-level restore + summary ---
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
if (-not $DryRun) {
    Write-AuditLog -Audit $audit -Path $auditPath
    $restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App $app -Actions $actions
} else {
    $restoreScriptPath = "<dry-run>"
    Write-Host "[DRY-RUN] would write audit log to $auditPath and restore script to <backupRoot>" -ForegroundColor DarkGray
}

# Surface any per-file failures captured in the audit.
$auditFailures = @($audit | Where-Object { -not $_.ok })
if ($auditFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "[WARN] $($auditFailures.Count) audit entries failed (review audit JSON):" -ForegroundColor Yellow
    foreach ($f in $auditFailures) {
        Write-Host ("    {0} | key={1} | {2}" -f $f.file, $f.key, $f.after) -ForegroundColor Yellow
    }
    $failCount += $auditFailures.Count
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Pass: $passCount" -ForegroundColor Green
Write-Host "Fail: $failCount" -ForegroundColor Red
Write-Host "Audit log: $auditPath" -ForegroundColor Gray
Write-Host "Restore script (files): $restoreScriptPath" -ForegroundColor Gray
Write-Host "Restore script (system): $systemRestoreScriptPath" -ForegroundColor Gray
Write-Host "System manifest: $systemManifestPath" -ForegroundColor Gray
if (-not $SkipHostname) {
    Write-Host "" -ForegroundColor Gray
    Write-Host ">>> RESTART WINDOWS for the new hostname to take effect for live processes <<<" -ForegroundColor Magenta
}

$qoderWorkDoneMarker = "$env:TEMP\qoderwork_v0.1_done.txt"
$summaryLines = @(
    "PASS=$passCount",
    "FAIL=$failCount",
    "AUDIT=$auditPath",
    "RESTORE_FILES=$restoreScriptPath",
    "RESTORE_SYSTEM=$systemRestoreScriptPath",
    "SYSTEM_MANIFEST=$systemManifestPath",
    "DRY_RUN=$DryRun",
    "HOSTNAME_PENDING_RESTART=$(if ($SkipHostname) { 'skipped' } else { 'yes' })"
)
# No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1). The done-marker is
# a key=value text file; emitting a BOM trips parsers that expect ASCII at byte 0.
[System.IO.File]::WriteAllText($qoderWorkDoneMarker, ($summaryLines -join "`n"), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "QoderWork reset completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "QoderWork reset completed successfully." -ForegroundColor Green
if (-not $SkipHostname) {
    Write-Host "Remember to RESTART WINDOWS for the new hostname to take effect." -ForegroundColor Yellow
}