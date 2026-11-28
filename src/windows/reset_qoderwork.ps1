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
    $qoderWorkScript = $MyInvocation.MyCommand.Path
    $qoderWorkSwitchList = @()
    if ($SkipMac)      { $qoderWorkSwitchList += "-SkipMac" }
    if ($SkipHostname) { $qoderWorkSwitchList += "-SkipHostname" }
    if ($DryRun)       { $qoderWorkSwitchList += "-DryRun" }
    $qoderWorkSwitchString = if ($qoderWorkSwitchList.Count -gt 0) { " " + ($qoderWorkSwitchList -join " ") } else { "" }
    # Single-string argument list, same proven pattern as v0.3 Qoder. -File
    # passes only declared switches; a redirect operator here would be
    # swallowed as an undeclared argument (the *_done.txt marker file is the
    # persisted result).
    $qoderWorkArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$qoderWorkScript`"$qoderWorkSwitchString"
    # Remove any done-marker from a previous run BEFORE launching: the elevated
    # child writes the marker only at the very end, so an early exit (e.g. the
    # tree-kill give-up) would otherwise leave the PREVIOUS run's summary here
    # to be printed as this run's result.
    Remove-Item "$env:TEMP\qoderwork_v0.2_done.txt" -ErrorAction SilentlyContinue
    Start-Process powershell -Verb RunAs -ArgumentList $qoderWorkArgs -WindowStyle Normal -Wait
    if (Test-Path "$env:TEMP\qoderwork_v0.2_done.txt") {
        Get-Content "$env:TEMP\qoderwork_v0.2_done.txt"
    }
    else {
        Write-Host "no result marker produced this run -- the elevated reset window may have exited early" -ForegroundColor Yellow
    }
    exit
}

Write-GhostBanner -Target "QoderWork Identity Reset" -Version "0.2"

# QoderWork v0.2 -- identity reset + system-level defenses. THIN MANIFEST
# over the Python core (Phase 3 migration #4 per docs/PYTHON_HYBRID_ROADMAP.md:
# cursor v0.3 pilot, devin v0.4, trae v0.3). The 26 steps, their order, audit
# keys, restore actions and summary are IDENTICAL to v0.1 (archived at
# archive/reset_qoderwork_windows-v0.1.ps1, local-only); every file-level
# store mutation now runs through src\python\ghost_cli.py (base64 payload in,
# JSON report out) via ONE invocation helper. What was deleted from v0.1: the
# inline temp-.py heredoc (step 19 now uses the shared purge-tables
# subcommand) and the local mutation helpers, replaced by the tested
# ghost.filesweep / ghost.winstore / ghost.backup / ghost.sqlite_keys modules.
#
#   v0.1 helper                          -> v0.2 core verb
#   Set-VerifiedFlatUuidFile             -> machineid-file
#   Reset-QoderWorkStatusJson            -> json-patch (logged_in/snapshot_at/
#                                           writer; version/schema_version/
#                                           product preserved from the file)
#   Reset-QoderWorkExternalCommandsRegistry -> json-patch (commands emptied;
#                                           v0.1 rewrote the whole file, v0.2
#                                           keeps unknown top-level keys --
#                                           strictly safer for schema evolution)
#   Update-QoderWorkPreferences          -> salt-rotate (salt now generated in
#                                           the core: 32 lowercase hex; v0.1
#                                           used an uppercase GUID-N -- same
#                                           length/format class, case is not
#                                           significant to the app)
#   Clear-QoderWorkAgentsDb heredoc      -> purge-tables (exact tables + keyed
#                                           app_settings deletions, schema-
#                                           missing tolerated, read-only reopen
#                                           verify: after[] IS the verification)
#   Invoke-ClearBinaryIdentityStore      -> store-delete --action delete
#
# FIXED over v0.1: the agents.db heredoc crashed when the app_settings table
# was absent (no existing-check) while the PS side already carried a
# schema-missing branch for it -- the core tolerates a missing keyed table
# per key, so that branch is finally reachable.
#
# The system-level steps [22]-[26] (auth binaries, HKLM MachineGuid, HKCU
# deviceid, HKLM SQM, NIC MAC, hostname) stay PowerShell -- they are registry/
# network/OS operations, not application-store mutations (same split as
# reset_cursor v0.3's step table). New-SystemRestoreScript stays a PS
# generator for the same reason (it is the system-level twin of the PS
# New-RestoreScript, not a store mutation).
#
# QoderWork's local stores are:
#   %USERPROFILE%\.qoderwork\           machine-id, installation_id, .status.json, .cache, cache, logs
#   %APPDATA%\QoderWork\                rum-electron-store (ARMS RUM = cross-product ID)
#                                       Partitions\main\   (Chromium profile: Network/Local Storage/Preferences/Local State)
#                                       data\agents.db    (Drizzle ORM: oauth tokens, app_settings;
#                                                        chats/sub_chats/messages/projects PRESERVED)
#                                       data\dns-cache\   (Qoder endpoint IP cache)
#                                       SharedStorage\    (Electron SharedStorage 4096 bytes)
#                                       Local State        (Chromium os_crypt encrypted key)
#
# The script covers 21 file-level steps + 5 system-level steps, mirroring the
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

# Action manifest entry. Used by the file-level steps to record each backup /
# rename / delete so the generated restore_QoderWork_<ts>.ps1 can rehydrate
# them. Mirrors the reset_cursor v0.3 definition.
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

function _B64Payload {
    # Compact JSON -> base64: the core bridge's payload contract (sidesteps
    # PS 5.1 native-argument quoting entirely).
    param([Parameter(Mandatory = $true)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Invoke-GhostCore {
    # The one PS -> Python invocation point for every file-level store
    # mutation. Returns the parsed JSON report, or $null when the core is
    # missing or the subcommand failed (exit code non-zero). Same recipe
    # Set-SqliteKeys uses: functional python probe + UTF-8 console + exit-
    # code check.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]]$CliArgs)

    $cli = Get-GhostPythonCli
    if (-not $cli) {
        Write-Host "[FAILED] GHOST Python core not found (src\python\ghost_cli.py)." -ForegroundColor Red
        return $null
    }
    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Write-Host "[FAILED] no functional Python 3 found - every QoderWork file-level reset step needs it." -ForegroundColor Red
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
    # action. A locked/failed backup is reported but NOT fatal - the v0.1
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

# A QoderWork flat UUID file: machine-id, installation_id. These are plain text
# UUIDs with no surrounding JSON. Set + re-read verify via the core's
# machineid-file verb (backup if present, BOM-less UTF-8 write, re-read).
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
        try {
            $beforeValue = (Get-Content -LiteralPath $Path -Raw).Trim()
        }
        catch {
            $beforeValue = $null
        }
    }

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would write '$Value' to $Path (was '$beforeValue')" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "uuid" -Before $beforeValue -After $Value -Ok $true
        return $true
    }

    $report = Invoke-GhostCore @("machineid-file", $Path, $BackupRoot, $BackupLabel,
        (_B64Payload @{ value = $Value }))
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "uuid" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "uuid" -Before $beforeValue -After "verify-failed" -Ok $false
    return $false
}

# QoderWork stores %USERPROFILE%\.qoderwork\.status.json with a tiny schema:
# { logged_in, version, schema_version, product, snapshot_at, writer }
# Reset to a fresh, never-logged-in state without changing version/product
# (core: json-patch -- it only overwrites the keys listed, so any key a newer
# QoderWork version adds survives the reset, same contract as v0.1's
# field-targeted rewrite).
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

    if ($DryRun) {
        $beforeLoggedIn = $null
        try {
            $beforeLoggedIn = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).logged_in
        }
        catch {
            $beforeLoggedIn = $null
        }
        Write-Host "    [DRY-RUN] would reset $Path to logged_in=false, fresh snapshot_at" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "logged_in" -Before $beforeLoggedIn -After "false" -Ok $true
        return $true
    }

    $null = Backup-ViaCore -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel -Actions $Actions

    $version = ""
    $schemaVersion = 1
    $product = "qoderwork"
    try {
        $currentStatus = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -ne $currentStatus.PSObject.Properties['version']) { $version = $currentStatus.version }
        if ($null -ne $currentStatus.PSObject.Properties['schema_version']) { $schemaVersion = $currentStatus.schema_version }
        if ($null -ne $currentStatus.PSObject.Properties['product']) { $product = $currentStatus.product }
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "logged_in" -Before $null -After "parse-failed" -Ok $false
        return $false
    }

    $patch = @{
        logged_in      = $false
        version        = $version
        schema_version = $schemaVersion
        product        = $product
        snapshot_at    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        writer         = "main"
    }
    $report = Invoke-GhostCore @("json-patch", $Path, (_B64Payload $patch))
    if ($null -ne $report -and $report.ok) {
        $ok = ($report.after.logged_in -eq $false)
        Add-AuditEntry -Audit $Audit -File $Path -Key "logged_in" -Before $report.before.logged_in -After $report.after.logged_in -Ok $ok
        return $ok
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "status" -Before $null -After "core-invoke-failed" -Ok $false
    Write-Host "    [FAILED] .status.json core invocation failed" -ForegroundColor Red
    return $false
}

# QoderWork's external-commands\registry.json records installed external commands
# keyed by id. Reset by emptying the commands list -- next launch will
# re-register what's actually installed. v0.1 rewrote the whole file with
# {commands: []}; v0.2 empties just the commands key via json-patch, so any
# unknown top-level key a newer version adds survives (strictly safer).
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

    if ($DryRun) {
        Write-Host "    [DRY-RUN] would reset $Path to {commands: []}" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "present" -After "empty" -Ok $true
        return $true
    }

    $null = Backup-ViaCore -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel -Actions $Actions

    $report = Invoke-GhostCore @("json-patch", $Path, (_B64Payload @{ commands = @() }))
    if ($null -ne $report -and $report.ok) {
        $commandsAfter = $report.after.commands
        $ok = ($null -eq $commandsAfter) -or (@($commandsAfter).Count -eq 0)
        Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "present" -After "empty" -Ok $ok
        return $ok
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "external-commands-registry" -Before "present" -After "core-invoke-failed" -Ok $false
    Write-Host "    [FAILED] external-commands registry core invocation failed" -ForegroundColor Red
    return $false
}

# QoderWork's Partitions\main\Preferences device_id_salt (matches what the
# Qoder v0.3 script does). The salt is generated in the core (32 lowercase
# hex; v0.1 used an uppercase GUID-N -- same length/format class, case is
# not significant to the app).
function Update-QoderWorkPreferences {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before "missing" -After "skipped" -Ok $true
        return $true
    }

    if ($DryRun) {
        $beforeValue = $null
        try {
            $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if ($null -ne $content.PSObject.Properties['electron'] -and
                $null -ne $content.electron.PSObject.Properties['media'] -and
                $null -ne $content.electron.media.PSObject.Properties['device_id_salt']) {
                $beforeValue = $content.electron.media.device_id_salt
            }
        }
        catch {
            $beforeValue = $null
        }
        Write-Host "    [DRY-RUN] would rotate electron.media.device_id_salt on $Path (was '$beforeValue')" -ForegroundColor DarkGray
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $beforeValue -After "rotated" -Ok $true
        return $true
    }

    $report = Invoke-GhostCore @("salt-rotate", $Path, $BackupRoot, $BackupLabel)
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] Preferences device_id_salt verification failed" -ForegroundColor Red
    return $false
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
# Strategy: DELETE rows from all of these via the core's purge-tables verb
# (exact tables + keyed app_settings deletions; schema evolution tolerated
# per table; verify-after = read-only reopen recount, so after[] IS the
# verification). This is a subset of what `Clear-QoderSecrets` does for
# state.vscdb in the Qoder v0.3 script -- ported for QoderWork's schema.
function Clear-QoderWorkAgentsDb {
    param(
        [Parameter(Mandatory = $true)][string]$DbPath,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

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

    $purgeConfig = @{
        tables    = $exactTables
        key_table = "app_settings"
        keys      = $appSettingsResetKeys
    }
    $result = Invoke-GhostCore @("purge-tables", $DbPath, (_B64Payload $purgeConfig))
    if ($null -eq $result -or $null -eq $result.after) {
        foreach ($key in ($exactTables + $appSettingsResetKeys)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "core-invoke-failed" -Ok $false
        }
        Write-Host "    [FAILED] agents.db scrub core invocation failed: $DbPath" -ForegroundColor Red
        return $false
    }

    $allOk = $true

    foreach ($table in $exactTables) {
        $before = $result.before.$table
        $after = $result.after.$table
        if ($after -eq "schema-missing") {
            # Schema evolution: the table no longer exists in agents.db, so
            # there is nothing to scrub. Benign -- must not fail the run.
            # Audit with a WARN flavor so the JSON shows why it was skipped.
            Write-Host "    [WARN] table absent from current schema, nothing to scrub: $table" -ForegroundColor Yellow
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $table -Before "schema-missing" -After "schema-missing (warn: absent from current schema)" -Ok $true
            continue
        }
        $ok = ($before -is [int]) -and ($after -eq 0)
        Add-AuditEntry -Audit $Audit -File $DbPath -Key $table -Before ("count=" + $before) -After ("count=" + $after) -Ok $ok
        if (-not $ok) { $allOk = $false }
    }

    foreach ($key in $appSettingsResetKeys) {
        $before = $result.before.$key
        $after = $result.after.$key
        if ($after -eq "schema-missing") {
            # Same schema-evolution contract as the tables loop above. The
            # core tolerates a missing app_settings table per key (v0.1's
            # heredoc crashed on it while this branch already existed).
            Write-Host "    [WARN] app_settings absent from current schema, nothing to scrub: $key" -ForegroundColor Yellow
            Add-AuditEntry -Audit $Audit -File $DbPath -Key ("app_settings:" + $key) -Before "schema-missing" -After "schema-missing (warn: absent from current schema)" -Ok $true
            continue
        }
        $ok = ($before -is [int]) -and ($after -eq 0)
        Add-AuditEntry -Audit $Audit -File $DbPath -Key ("app_settings:" + $key) -Before ("count=" + $before) -After ("count=" + $after) -Ok $ok
        if (-not $ok) { $allOk = $false }
    }

    return $allOk
}

# Wrap the core's store-delete with DryRun handling. The core always deletes;
# it doesn't know about this script's DryRun switch. Audit + restore actions
# get the same values either way so -DryRun and a real run produce identical
# audit JSON, but -DryRun never touches the filesystem.
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
            # Empty label -> the core derives the relative label from
            # --root-path (same contract as v0.1's -RootPath).
            $storeReport = Invoke-GhostCore @("store-delete", $path, $BackupRoot,
                "--action", $Action, "--root-path", $RootPath)
            if ($null -ne $storeReport) {
                Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before $storeReport.before -After $storeReport.after -Ok $storeReport.ok
                if ($storeReport.ok -and $storeReport.backed_up_to) {
                    $results += [ordered]@{
                        action       = $Action
                        originalPath = $path
                        backupPath   = $storeReport.backed_up_to
                        renamedPath  = $storeReport.renamed_to
                    }
                }
            }
            else {
                Add-AuditEntry -Audit $Audit -File $path -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
            }
        }
    }
    return $results
}

# Derive a step's pass/fail from the audit entries it appended (from index
# $BeforeCount to the end). The core's store-delete records failed deletes
# ONLY as ok=$false audit entries -- its returned action rows carry no ok flag
# and are emitted for successful paths only -- so the caller must inspect the
# audit delta to know whether a binary-store step actually succeeded.
function Test-StepAuditOk {
    param(
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][int]$BeforeCount
    )

    if ($null -eq $Audit.Value) { return $true }
    $entries = @($Audit.Value)
    for ($i = $BeforeCount; $i -lt $entries.Count; $i++) {
        if (-not $entries[$i].ok) { return $false }
    }
    return $true
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
        return $true
    }

    $recreatedOk = $true
    foreach ($path in $recreated) {
        Write-Host "    [WARN] watchdog recreated file, re-deleting: $path" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        $afterValue = if (Test-Path -LiteralPath $path) { "re-delete-failed" } else { "re-deleted" }
        if ($afterValue -eq "re-delete-failed") {
            Write-Host "    [FAILED] could not re-delete (file locked?): $path" -ForegroundColor Red
            $recreatedOk = $false
        }
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After $afterValue -Ok ($afterValue -eq "re-deleted")
    }
    return $recreatedOk
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

    $purgeOk = $true
    foreach ($dir in $toDelete) {
        if ($DryRun) {
            Write-Host "    [DRY-RUN] would purge older backup: $($dir.Name)" -ForegroundColor DarkGray
            Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "would-purge" -Ok $true
            continue
        }
        Write-Host "    [PURGE] $($dir.Name) (preserved old fingerprint; deleting)" -ForegroundColor DarkGray
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $dir.FullName) {
            # Never silent-success: a locked directory (open in Explorer or an
            # editor is the ordinary case) survives the purge. Audit the real
            # result and fail the step so the summary/exit code cannot claim a
            # clean run while old-ID backups are still on disk.
            Write-Host "    [FAILED] could not purge older backup (locked?): $($dir.Name)" -ForegroundColor Red
            Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "delete-failed" -Ok $false
            $purgeOk = $false
        }
        else {
            Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After "deleted" -Ok $true
        }
    }
    return $purgeOk
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
# NIC MAC + hostname. Same logic as v0.3 Qoder. Stays PowerShell: this is the
# system-level twin of the PS New-RestoreScript, not an application-store
# mutation.
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
# Restore script for system-level changes made by reset_qoderwork_windows-v0.2.ps1
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

# The core must be present and a functional Python 3 with it - fail fast
# BEFORE touching anything (v0.1 needed Python only for the agents.db scrub;
# v0.2 routes every file-level store mutation through it). A -DryRun never
# writes, so it still runs without Python.
if (-not $DryRun) {
    if ((-not (Get-GhostPythonCli)) -or (-not (Get-PythonCommandInfo))) {
        Write-Host "[FAILED] GHOST Python core (src\python\ghost_cli.py) missing or no functional Python 3 found - every QoderWork file-level reset step needs it (winget install Python.Python.3.12)." -ForegroundColor Red
        exit 1
    }
}

if ($DryRun) {
    Write-Host "=== QoderWork Identity Reset (v0.2) -- DRY RUN ===" -ForegroundColor Magenta
} else {
    New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
    Write-Host "=== QoderWork Identity Reset (v0.2) ===" -ForegroundColor Cyan
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
# (The Preferences salt is now generated in the core's salt-rotate verb.)
$newMachineId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()

# --- [1/26] machine-id (user-level; core: machineid-file) ---
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

# --- [2/26] installation_id (user-level; core: machineid-file) ---
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

# --- [3/26] .status.json reset (core: json-patch) ---
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

# --- [4/26] external-commands\registry.json reset (core: json-patch) ---
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

# --- [5/26] ~\.qoderwork\.cache\ deletion (core: store-delete) ---
Write-Host "`n[5/26] Deleting ~\.qoderwork\.cache\..." -ForegroundColor Cyan
$dotCachePath = Join-Path $userQoderWorkRoot ".cache"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($dotCachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] .cache" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] .cache (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [6/26] ~\.qoderwork\cache\ deletion (MCP market cache; core: store-delete) ---
Write-Host "`n[6/26] Deleting ~\.qoderwork\cache\..." -ForegroundColor Cyan
$cachePath = Join-Path $userQoderWorkRoot "cache"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($cachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] cache" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] cache (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [7/26] ~\.qoderwork\logs\ deletion (core: store-delete) ---
Write-Host "`n[7/26] Deleting ~\.qoderwork\logs\..." -ForegroundColor Cyan
$logsPath = Join-Path $userQoderWorkRoot "logs"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($logsPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] logs" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] logs (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [8/26] rum-electron-store\ deletion (CROSS-PRODUCT RUM ID; core: store-delete) ---
# This is the single most important file in the script. The Alibaba ARMS
# _arms_uid persisted here is what the ARMS backend uses to correlate this
# QoderWork install with the previously-banned Qoder install.
Write-Host "`n[8/26] Deleting Roaming\QoderWork\rum-electron-store\ (cross-product RUM)..." -ForegroundColor Cyan
$rumStorePath = Join-Path $root "rum-electron-store"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($rumStorePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] rum-electron-store (ARMS _arms_uid wiped)" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] rum-electron-store (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [9/26] Local State (Chromium os_crypt encrypted key; core: store-delete) ---
Write-Host "`n[9/26] Deleting Roaming\QoderWork\Local State (Chromium os_crypt key)..." -ForegroundColor Cyan
$localStatePath = Join-Path $root "Local State"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($localStatePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] Local State" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Local State (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [10/26] Partitions\main\Preferences device_id_salt (core: salt-rotate) ---
Write-Host "`n[10/26] Updating Partitions\main\Preferences electron.media.device_id_salt..." -ForegroundColor Cyan
$prefsPath = Join-Path $profileRoot "Preferences"
$prefsLabel = Get-AppRelativeBackupLabel -RootPath $profileRoot -TargetPath $prefsPath
if (Update-QoderWorkPreferences -Path $prefsPath -BackupRoot $backupRoot -BackupLabel $prefsLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] Preferences device_id_salt verified" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Preferences device_id_salt verification failed" -ForegroundColor Red
    $failCount++
}

# --- [11/26] Partitions\main\Network\Cookies + Network Persistent State (core: store-delete) ---
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
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths $netPaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] Network stores" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Network stores (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [12/26] Partitions\main\Local Storage\ (LevelDB; core: store-delete) ---
Write-Host "`n[12/26] Deleting Partitions\main\Local Storage\ (LevelDB identity keys)..." -ForegroundColor Cyan
$localStoragePath = Join-Path $profileRoot "Local Storage"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($localStoragePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] Local Storage" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Local Storage (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [13/26] Partitions\main\Session Storage\ (core: store-delete) ---
Write-Host "`n[13/26] Deleting Partitions\main\Session Storage\..." -ForegroundColor Cyan
$sessionStoragePath = Join-Path $profileRoot "Session Storage"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($sessionStoragePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] Session Storage" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Session Storage (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [14/26] Partitions\main\Shared Dictionary\ (core: store-delete) ---
Write-Host "`n[14/26] Deleting Partitions\main\Shared Dictionary\..." -ForegroundColor Cyan
$sharedDictPath = Join-Path $profileRoot "Shared Dictionary"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($sharedDictPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] Shared Dictionary" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] Shared Dictionary (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [15/26] Partitions\main\Cache\ + Code Cache\ + GPUCache\ + Dawn*Cache\ (core: store-delete) ---
Write-Host "`n[15/26] Deleting Partitions\main\Cache\ + Code Cache\ + GPUCache\ + Dawn*Cache\..." -ForegroundColor Cyan
$cachePaths = @(
    (Join-Path $profileRoot "Cache"),
    (Join-Path $profileRoot "Code Cache"),
    (Join-Path $profileRoot "GPUCache"),
    (Join-Path $profileRoot "DawnGraphiteCache"),
    (Join-Path $profileRoot "DawnWebGPUCache"),
    (Join-Path $profileRoot "blob_storage")
)
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths $cachePaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $profileRoot
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] cache trees" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] cache trees (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [16/26] Roaming\QoderWork\SharedStorage\ (Electron SharedStorage 4KB file; core: store-delete) ---
Write-Host "`n[16/26] Deleting Roaming\QoderWork\SharedStorage\..." -ForegroundColor Cyan
$sharedStoragePath = Join-Path $root "SharedStorage"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($sharedStoragePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] SharedStorage" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] SharedStorage (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [17/26] data\dns-cache\ deletion (Qoder endpoint IP cache; core: store-delete) ---
Write-Host "`n[17/26] Deleting data\dns-cache\ (Qoder endpoint IP cache)..." -ForegroundColor Cyan
$dnsCachePath = Join-Path $root "data\dns-cache"
$stepAuditCount = $audit.Count
$binaryActions = Invoke-ClearBinaryIdentityStore -Paths @($dnsCachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
if (-not $DryRun) { $actions += @($binaryActions) }
if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
    Write-Host "    [OK] data\dns-cache" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] data\dns-cache (one or more deletes failed -- see audit log)" -ForegroundColor Red
    $failCount++
}

# --- [18/26] data\dynamic-text\qoder-work.json: KEEP (UI strings, not identity) ---
# Note: This file contains error.114 (the cross-product ban message). We do NOT
# delete it because it's just localized UI strings -- deleting it would force a
# download on next launch and isn't related to identity. Just recorded.
Write-Host "`n[18/26] Preserving data\dynamic-text\qoder-work.json (UI strings only, not identity)..." -ForegroundColor Cyan
Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "data\dynamic-text\qoder-work.json") -Key "preserved" -Before "present" -After "preserved" -Ok $true
Write-Host "    [SKIP] dynamic-text is non-identity resource bundle" -ForegroundColor DarkGray
$passCount++

# --- [19/26] data\agents.db scrub (oauth tokens + app_settings; chats preserved; core: purge-tables) ---
Write-Host "`n[19/26] Scrubbing data\agents.db (oauth/app_settings tables; chats preserved)..." -ForegroundColor Cyan
$agentsDbPath = Join-Path $root "data\agents.db"
if (-not $DryRun) {
    $null = Backup-ViaCore -Source $agentsDbPath -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $agentsDbPath) -Actions ([ref]$actions)
    # SQLite sidecars: the pre-step force-kill can leave a hot -journal or a
    # committed-but-uncheckpointed -wal/-shm next to agents.db. A .db-only
    # backup restores stale or torn chat data, so back each sidecar up
    # alongside the database (sidecar-aware like reset_qoder.ps1) and record
    # it for the restore script -- restoring the .db together with its
    # sidecars replays exactly the state that was on disk.
    foreach ($agentsDbSidecarSuffix in @("-wal", "-shm", "-journal")) {
        $agentsDbSidecarPath = $agentsDbPath + $agentsDbSidecarSuffix
        if (Test-Path -LiteralPath $agentsDbSidecarPath) {
            $null = Backup-ViaCore -Source $agentsDbSidecarPath -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $agentsDbSidecarPath) -Actions ([ref]$actions)
        }
    }
}
if (Clear-QoderWorkAgentsDb -DbPath $agentsDbPath -Audit ([ref]$audit)) {
    Write-Host "    [OK] agents.db scrubbed" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] agents.db scrub failed" -ForegroundColor Red
    $failCount++
}

# --- [20/26] Old ID_Backups purge (keep newest only; PS: pure file ops) ---
Write-Host "`n[20/26] Purging old ID_Backups directories (keep current run only)..." -ForegroundColor Cyan
if (Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit)) {
    $passCount++
} else {
    Write-Host "    [FAILED] one or more older ID_Backups directories could not be purged" -ForegroundColor Red
    $failCount++
}

# --- [21/26] Post-write watchdog re-verify (PS: pure file ops) ---
Write-Host "`n[21/26] Post-write watchdog re-verify..." -ForegroundColor Cyan
$watchdogCorePaths = @($rumStorePath, $localStatePath)
$watchdogOk = $true
if (-not $DryRun) {
    $watchdogOk = Test-QoderWorkWatchdogRecreation -CorePaths $watchdogCorePaths -Audit ([ref]$audit)
}
if ($watchdogOk) {
    $passCount++
} else {
    $failCount++
}

# === SYSTEM-LEVEL STEPS (mirrors v0.3 Qoder; opt-out via -SkipMac / -SkipHostname) ===

$systemManifest = @{
    hostname = @{ old = $env:COMPUTERNAME; new = $null }
    adapters = @()
    registry = @()
}

# --- [22/26] auth.dat + auth-v2.dat deletion (encrypted auth tokens; core: store-delete) ---
$authBinaries = @((Join-Path $root "auth.dat"), (Join-Path $root "auth-v2.dat"))
$existingAuthFiles = @($authBinaries | Where-Object { Test-Path -LiteralPath $_ })
if ($existingAuthFiles.Count -eq 0) {
    Write-Host "`n[22/26] Deleting auth.dat/auth-v2.dat..." -ForegroundColor Cyan
    Write-Host "    [SKIP] not present" -ForegroundColor DarkGray
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $root "auth.dat") -Key "auth-binary" -Before "missing" -After "skipped" -Ok $true
    $passCount++
} else {
    Write-Host "`n[22/26] Deleting auth.dat/auth-v2.dat (encrypted auth tokens)..." -ForegroundColor Cyan
    $stepAuditCount = $audit.Count
    $authActions = Invoke-ClearBinaryIdentityStore -Paths $existingAuthFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
    if (-not $DryRun) { $actions += @($authActions) }
    if (Test-StepAuditOk -Audit ([ref]$audit) -BeforeCount $stepAuditCount) {
        Write-Host "    [OK] auth binaries" -ForegroundColor Green
        $passCount++
    } else {
        Write-Host "    [FAILED] auth binaries (one or more deletes failed -- see audit log)" -ForegroundColor Red
        $failCount++
    }
}

# --- [23/26] HKLM MachineGuid source rotation (QoderWork OTel reads this via REG.exe; PS: registry op) ---
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

# --- [24/26] HKCU DeveloperTools deviceid source (PS: registry op) ---
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

# --- [25/26] HKLM SQMClient MachineId source (PS: registry op) ---
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

# --- [26/26] NIC MAC + Hostname (system-level defenses; PS: network/OS ops) ---
if ($SkipMac) {
    Write-Host "`n[26/26] SKIPPED (-SkipMac) -- NIC MAC addresses left unchanged" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File "NetAdapter::all" -Key "NetworkAddress" -Before "skipped" -After "skipped-by-user" -Ok $true
} else {
    Write-Host "`n[26/26] Rotating NIC MAC addresses (physical adapters only)..." -ForegroundColor Cyan
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
    Write-Host "`n[26/26] SKIPPED (-SkipHostname) -- hostname left unchanged" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName" -Key "ComputerName" -Before "skipped" -After "skipped-by-user" -Ok $true
} else {
    Write-Host "`n[26/26] Changing hostname (registry-only, restart required)..." -ForegroundColor Cyan
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

if (-not $DryRun) {
    $systemRestoreScriptPath = New-SystemRestoreScript -BackupRoot $backupRoot -App $app -Manifest $systemManifest -Timestamp $timestamp
} else {
    # New-SystemRestoreScript writes into $backupRoot, which a dry run never
    # creates ([System.IO.File]::WriteAllText does not create directories) --
    # calling it here threw DirectoryNotFoundException and killed every -DryRun
    # run before the summary/marker could be written. Gate it exactly like the
    # audit-log branch below.
    $systemRestoreScriptPath = "<dry-run>"
}
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

# Surface any per-file failures captured in the audit. Diagnostic listing
# only: every failing entry is already counted exactly once by its own step
# (steps [1]-[4], [10], [19], [23]-[26] via their return values; the
# binary-store steps via Test-StepAuditOk; the purge and watchdog via return
# values), so adding them to $failCount here double-counted every failure in
# the summary and the done marker.
$auditFailures = @($audit | Where-Object { -not $_.ok })
if ($auditFailures.Count -gt 0) {
    Write-Host ""
    Write-Host "[WARN] $($auditFailures.Count) audit entries failed (review audit JSON):" -ForegroundColor Yellow
    foreach ($f in $auditFailures) {
        Write-Host ("    {0} | key={1} | {2}" -f $f.file, $f.key, $f.after) -ForegroundColor Yellow
    }
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

$qoderWorkDoneMarker = "$env:TEMP\qoderwork_v0.2_done.txt"
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
