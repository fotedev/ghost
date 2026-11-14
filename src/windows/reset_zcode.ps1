#Requires -Version 5.1
# ZCode / Qoder Identity Reset v1.5
#
# v1.5 -- THIN MANIFEST over the Python core (Phase 3 migration #7 per
# docs/PYTHON_HYBRID_ROADMAP.md: cursor v0.3 pilot, devin v0.4, trae v0.3,
# qoderwork v0.2, minimax v1.4, qoder v0.5). The 27 steps, their order, audit
# keys, restore actions and summary are IDENTICAL to v1.4 (archived at
# archive/reset_zcode_windows-v1.4.ps1, local-only); every store mutation now
# runs through src\python\ghost_cli.py (base64 payload in, JSON report out)
# via ONE invocation helper. What was deleted from v1.4: the local mutation
# helpers, replaced by the tested ghost.filesweep / ghost.winstore /
# ghost.backup / ghost.sqlite_keys modules.
#
#   v1.4 helper / mechanism         -> v1.5 core verb
#   Set-VerifiedMachineIdFile       -> machineid-file
#   Set-JsonIdentity (storage.json/ -> backup + json-patch
#     telemetry-state.json)
#   Set-SqliteKeys (state.vscdb +   -> backup + sqlite-update (missing-DB
#     workspace UPSERT)               loud guard added per the reset_cursor
#                                     v0.3 pattern)
#   Clear-SecretsFromSqlite         -> backup + delete-secrets via the ONE
#                                     Invoke-GhostCore helper
#   Clear-TreeFilesIndividually     -> sweep-tree
#   Remove-VerifiedFileNoBackup     -> sweep-file
#   Remove-OsCryptEncryptedKey      -> json-remove
#   Set-DeviceIdSalt                -> salt-rotate (the fresh salt is now
#                                     generated in the core: CSPRNG 32
#                                     lowercase hex PER PROFILE -- v1.4
#                                     generated ONE Get-Random (time-seeded
#                                     PRNG, NOT a CSPRNG) uppercase-hex salt
#                                     shared across every profile the run
#                                     touches; per-profile CSPRNG salts are
#                                     strictly better isolation)
#   Set-RumElectronStore            -> json-patch (_arms_uid + _arms_session)
#   Set-WebRemoteControlDeviceSid   -> json-set (dotted path, created when
#                                     missing -- the v1.4 Add-Member behavior)
#   Clear-ZcodeOAuthCredentials     -> backup + json-remove (oauth: PREFIX +
#                                     the zcodejwttoken exact key -- the M1
#                                     prefix mode; unrelated keys preserved)
#   Clear-ZcodeProviderApiKeys      -> backup + per-provider json-set gated on
#                                     an EXISTING apiKey (the v1.4 conditional
#                                     blanking preserved; structure never
#                                     gains keys it did not have)
#   Update-ArgvJsonCrashReporterId  -> patch-argv (JSONC regex twin)
#   Clear-BinaryIdentityStore       -> store-delete --action delete
#   clear-cli-telemetry raw call    -> the ONE Invoke-GhostCore helper (the
#                                     error-dict contract is kept)
#
# RNG FIX (repo convention "RandomNumberGenerator via .GetBytes() only"):
# v1.4 generated $newArmsUid / $newDeviceSid with Get-Random (time-seeded
# PRNG, not a CSPRNG) -- both generators now use RandomNumberGenerator.
# GetBytes(). The salt weakness is fixed outright by the core migration.
#
# The fail-fast Python preflight (one of the v1.5 items recorded PENDING in
# the CHANGELOG) lands with this migration; the remaining recorded v1.5
# items (shared-db scrub [26b], strict backups, abort checkpoint, -DryRun,
# purge salvage) stay PENDING -- separate debt, not part of the migration.
#
# v1.4 adds multi-instance targeting (Primary / Secondary / Third / Fourth /
# Both / All) on top of v1.3:
#   - -Target Primary   -> %APPDATA%\ZCode + %USERPROFILE%\.zcode only
#   - -Target Secondary -> %APPDATA%\ZCode-Second + %USERPROFILE%\ZCodeSecondHome\.zcode only
#   - -Target Third     -> %APPDATA%\ZCode-Third + %USERPROFILE%\ZCodeThirdHome\.zcode only
#   - -Target Fourth    -> %APPDATA%\ZCode-Fourth + %USERPROFILE%\ZCodeFourthHome\.zcode only
#   - -Target Both      -> orchestrates Secondary then Primary (back-compat)
#   - -Target All       -> orchestrates Third + Fourth + Fifth + Sixth + Secondary, then Primary
#                          (incl. Qoder), each child with its OWN fresh ID set.
#     Per-instance identity rule: orchestrator modes NEVER duplicate IDs
#     across instances.
#   - Single-target mode uses selective PID-tree killing (target mains via
#     taskkill /T /PID, classified by descendant CommandLine markers) so the
#     surviving instances keep running. Primary additionally uses a Qoder-only
#     kill that never touches ZCode (shared helpers spared when they descend
#     from ANY clone's tree). v1.3 killed every ZCode* process
#     unconditionally (that path survives as Stop-ZcodeQoderProcessesAggressive
#     but is NOT used by single-target modes).
#   - Backups (ID_Backups), watchdog probes and final validation are scoped
#     strictly per-target. v1.3 is kept intact for rollback.
#   - -SkipQoder is internal (used by the Both/All orchestrators so Qoder steps
#     run exactly once, in the Primary child).
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
#   powershell -ExecutionPolicy Bypass -File reset_zcode.ps1 [-Target Primary|Secondary|Both]
# Prerequisite: the TARGET instance is force-killed by the script; the survivor
# instance (in Single mode) is intentionally left running.
# Requirement: Python (python or python3) for EVERY store mutation now
# (v1.4 needed it only for the SQLite steps) -- fail-fast preflight.
# NOTE: change_device_id.ps1 is machine-wide (MAC/hostname/registry) and affects
# ALL ZCode instances + Qoder by design. This script is app-data-only.

param(
    [ValidateSet('Primary', 'Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth', 'Both', 'All')][string]$Target = 'Both',
    [switch]$SkipQoder
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Console hygiene: disable QuickEdit (2026-11-03) ---------------------------
# A click or click-drag inside this console starts a QuickEdit text selection,
# which BLOCKS all console output until a key is pressed - the reset keeps
# running underneath, but its progress appears frozen (observed 2026-11-03
# during a Fifth reset: output stalled at the terminate step until a keypress).
# Drop ENABLE_QUICK_EDIT_MODE (0x40) from this console's mode, keeping every
# other flag; ENABLE_EXTENDED_FLAGS (0x80) must accompany the change. The
# handle opens CONOUT$ (the screen buffer itself) so stdout redirection does
# not matter. Best effort: any failure here must never block the reset. Note
# Ctrl+S display pause is a host feature that cannot be disabled - any key
# resumes it.
try {
    if (-not ('Ghost.ResetConsole' -as [type])) {
        Add-Type -MemberDefinition '
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr CreateFileW(string name, int access, int share, IntPtr sec, int disp, int flags, IntPtr tmpl);
            [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out int mode);
            [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, int mode);
        ' -Name ResetConsole -Namespace Ghost | Out-Null
    }
    # GENERIC_READ|GENERIC_WRITE = 0xC0000000, share 0x3, OPEN_EXISTING = 3.
    $qeHandle = [Ghost.ResetConsole]::CreateFileW('CONOUT$', -1069547520, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $qeMode = 0
    if (($qeHandle -ne [IntPtr](-1)) -and [Ghost.ResetConsole]::GetConsoleMode($qeHandle, [ref]$qeMode)) {
        $qeNew = ($qeMode -band (-bnot 0x0040)) -bor 0x0080
        if ($qeNew -ne $qeMode) {
            [void][Ghost.ResetConsole]::SetConsoleMode($qeHandle, $qeNew)
            Write-Host '[console] QuickEdit selection disabled for this window - a stray click can no longer pause the output.' -ForegroundColor DarkGray
        }
    }
} catch { Write-Host "[console] QuickEdit tweak SKIP ($($_.Exception.Message))" -ForegroundColor DarkGray }

# --- Display vocabulary (2026-11-03) -------------------------------------------
# Colors are the ONLY user-facing clone names; the frozen keys (Secondary..Sixth)
# survive in params, dirs, AUMIDs and identification lines (color + key in
# parens). Mirrors the shortcut naming unified in PR #20.
function Get-ZcodeLabelColor([string]$Key) {
    switch ($Key) {
        'Secondary' { 'Blue' }
        'Third'     { 'Yellow' }
        'Fourth'    { 'Green' }
        'Fifth'     { 'Red' }
        'Sixth'     { 'Orange' }
        default     { $Key }
    }
}
function Get-ZcodeTargetDisplay([string]$Key) {
    switch ($Key) {
        'Primary'   { 'Primary' }
        'Secondary' { 'Blue (Secondary)' }
        'Third'     { 'Yellow (Third)' }
        'Fourth'    { 'Green (Fourth)' }
        'Fifth'     { 'Red (Fifth)' }
        'Sixth'     { 'Orange (Sixth)' }
        'Both'      { 'Both (Blue + Primary)' }
        'All'       { 'All (Blue..Orange)' }
        default     { $Key }
    }
}

# --- Self-elevation -----------------------------------------------------------
# Re-launch elevated with the same script path when not already admin.
# Forwards -Target / -SkipQoder so child runs keep their scope after UAC.
$zcodeIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $zcodeIsAdmin) {
    $zcodeScript = $MyInvocation.MyCommand.Path
    $zcodeFwd = " -Target $Target"
    if ($SkipQoder) { $zcodeFwd += " -SkipQoder" }
    # -File passes only declared switches; a redirect operator after -File is
    # just swallowed as an undeclared argument. The *_done.txt marker file
    # (not a log) is the persisted result channel - the elevated console shows
    # the full live output while the run progresses.
    $zcodeArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$zcodeScript`"$zcodeFwd"
    Start-Process powershell -Verb RunAs -ArgumentList $zcodeArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\zcode_v1.5_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\zcode_v1.5_done.txt"
    }
    exit
}

Write-GhostBanner -Target "ZCode/Qoder Identity Reset [$(Get-ZcodeTargetDisplay $Target)]" -Version "1.5"

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

function _B64Payload {
    # Compact JSON -> base64: the core bridge's payload contract (sidesteps
    # PS 5.1 native-argument quoting entirely).
    param([Parameter(Mandatory = $true)][hashtable]$Payload)
    $json = $Payload | ConvertTo-Json -Depth 6 -Compress
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Invoke-GhostCore {
    # The ONE PS -> Python invocation point for every store mutation / core
    # probe. Returns the parsed JSON report, or $null when the core is
    # missing or the subcommand failed (exit code non-zero). Same recipe
    # Set-SqliteKeys uses: functional python probe + UTF-8 console + exit-
    # code check.
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)

    $cli = Get-GhostPythonCli
    if (-not $cli) {
        Write-Host "[FAILED] GHOST Python core not found (src\python\ghost_cli.py)." -ForegroundColor Red
        return $null
    }
    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        Write-Host "[FAILED] no functional Python 3 found - every ZCode reset step needs it." -ForegroundColor Red
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
    # action. A locked/failed backup is reported but NOT fatal - the v1.4
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

# Clear-BinaryIdentityStore twin over the core's store-delete verb (one path
# per core invocation; the PS side loops). Same interface as the shared
# identity_utils helper so the call sites only swap the function name.
function Invoke-StoreDelete {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [ValidateSet("rename", "delete")][string]$Action = "delete",
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$RootPath
    )

    $results = @()
    foreach ($path in $Paths) {
        # Empty label -> the core derives the relative label from --root-path
        # (same contract as the shared helper's -RootPath).
        $storeReport = Invoke-GhostCore @("store-delete", $path, $BackupRoot, "",
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
    return $results
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
        try {
            $beforeValue = (Get-Content -LiteralPath $Path -Raw).Trim()
        }
        catch {
            $beforeValue = $null
        }
    }

    # Core: machineid-file (backup if present, BOM-less UTF-8 write, re-read
    # verify -- the v1.4 contract verbatim; the core also creates the parent
    # directory when missing).
    $report = Invoke-GhostCore @("machineid-file", $Path, $BackupRoot, $BackupLabel,
        (_B64Payload @{ value = $Value }))
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "machineid" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "machineid" -Before $beforeValue -After "verify-failed" -Ok $false
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
    # Core: backup + sqlite-update (Set-SqliteKeys' contract split across the
    # core verbs; the verify-after re-read carries the [OK]/[FAILED] verdict).
    $null = Backup-ViaCore -Source $WorkspaceDbPath -BackupRoot $BackupRoot -Label (Get-AppRelativeBackupLabel -RootPath $RootPath -TargetPath $WorkspaceDbPath) -Actions $Actions
    $wsReport = Invoke-GhostCore @("sqlite-update", $WorkspaceDbPath, (_B64Payload @{ "storage.serviceMachineId" = $DeviceId }))
    $ok = $false
    if ($null -ne $wsReport -and $null -ne $wsReport.after -and ($wsReport.after."storage.serviceMachineId" -eq $DeviceId)) {
        Add-AuditEntry -Audit $Audit -File $WorkspaceDbPath -Key "storage.serviceMachineId" -Before $wsReport.before."storage.serviceMachineId" -After $wsReport.after."storage.serviceMachineId" -Ok $true
        $ok = $true
    }
    else {
        Add-AuditEntry -Audit $Audit -File $WorkspaceDbPath -Key "storage.serviceMachineId" -Before $null -After $DeviceId -Ok $false
    }

    if ($ok) {
        Write-Host "    [OK] workspace DB updated: $WorkspaceDbPath" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] workspace DB update: $WorkspaceDbPath" -ForegroundColor Red
    }
}

# DELETE auth-secret keys from state.vscdb ItemTable and verify survivors are
# zero via read-only reopen. Parameterized ? placeholders only. Logic lives in
# the shared Python core (src\python\ghost\sqlite_keys.py delete_secrets);
# invoked via ghost_cli.py -- no per-call temp .py.
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

    $null = Backup-ViaCore -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel -Actions $Actions

    # Core: delete-secrets via the ONE invocation helper (the logic has lived
    # in the shared core since the Phase 3 pilot -- v1.4 called it directly;
    # v1.5 unifies the invocation).
    $result = Invoke-GhostCore @("delete-secrets", $Path)
    if ($null -eq $result -or $null -eq $result.survivors) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "secrets-delete" -Before "present" -After "core-invoke-failed" -Ok $false
        Write-Host "    [FAILED] secrets deletion core invocation failed: $Path" -ForegroundColor Red
        return $false
    }

    # survivors is a LIST (one COUNT per pattern/key): PS array -eq 0
    # FILTERS elements instead of answering "all zero" - sum explicitly.
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

    # Core: sweep-tree (the per-file retry curve + bottom-up dir pruning twin;
    # the whole-tree backup is the single restorable delete action).
    $sweepReport = Invoke-GhostCore @("sweep-tree", $Path, $BackupRoot, $BackupLabel)
    if ($null -eq $sweepReport) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        return @{ Deleted = 0; Failed = 0; FailedPaths = @() }
    }

    foreach ($failedPath in @($sweepReport.failed_paths)) {
        Add-AuditEntry -Audit $Audit -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
    }

    $summary = "deleted=" + $sweepReport.deleted + " failed=" + $sweepReport.failed
    $ok = ($sweepReport.failed -eq 0)
    Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "present" -After $summary -Ok $ok
    if ($sweepReport.backed_up_to) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $sweepReport.backed_up_to -Action "delete"
    }

    return @{ Deleted = $sweepReport.deleted; Failed = $sweepReport.failed; FailedPaths = @($sweepReport.failed_paths) }
}

# Delete a stale file WITHOUT backing it up (used for *.backup sidecars and
# similar regenerable files). Verifies the path is gone afterwards. Core:
# sweep-file.
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

    $report = Invoke-GhostCore @("sweep-file", $Path)
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before $report.before -After $report.after -Ok $true
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

    $binaryActions = Invoke-StoreDelete -Paths @($Path) -Action "delete" -BackupRoot $BackupRoot -Audit $Audit -RootPath $env:USERPROFILE
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

    # Core: json-remove (dotted path). The core backs the file up whenever it
    # exists -- the v1.4 backup-when-present contract; the manifest action is
    # recorded whenever the backup landed (v1.4 parity).
    $report = Invoke-GhostCore @("json-remove", $Path, $BackupRoot, $BackupLabel,
        (_B64Payload @{ keys = @("os_crypt.encrypted_key") }))
    if ($null -eq $report -or (-not $report.ok)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "present" -After "core-invoke-failed" -Ok $false
        Write-Host "    [FAILED] os_crypt removal core invocation failed: $Path" -ForegroundColor Red
        return $false
    }

    if ($report.backed_up_to) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
    }

    $osBefore = $report.before."os_crypt.encrypted_key"
    $afterValue = if ($osBefore -eq "missing") { "skipped" } else { "removed" }
    Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before $osBefore -After $afterValue -Ok $true
    if ($afterValue -eq "removed") {
        Write-Host "    [OK] os_crypt.encrypted_key removed: $Path" -ForegroundColor Green
    }
    else {
        Write-Host "    [SKIP] os_crypt not found in: $Path" -ForegroundColor Yellow
    }
    return $true
}

function Set-DeviceIdSalt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
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

    # Core: salt-rotate -- the fresh salt is generated there (CSPRNG 32
    # lowercase hex, PER PROFILE; v1.4 generated ONE Get-Random uppercase-hex
    # salt shared across every profile the run touched -- a cross-profile
    # correlation signal AND a weak PRNG).
    $report = Invoke-GhostCore @("salt-rotate", $Path, $BackupRoot, $BackupLabel)
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        Write-Host "    [OK] device_id_salt updated: $Path" -ForegroundColor Green
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] device_id_salt verification failed: $Path" -ForegroundColor Red
    return $false
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

    # Core: backup + json-patch (both keys in ONE verified write; the create-
    # when-missing behavior matches the v1.4 Add-Member branches).
    $null = Backup-ViaCore -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel -Actions $Actions
    $patchUpdates = @{ "_arms_uid" = $NewUid; "_arms_session" = $NewSession }
    $report = Invoke-GhostCore @("json-patch", $Path, (_B64Payload $patchUpdates))
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_uid" -Before $report.before."_arms_uid" -After $report.after."_arms_uid" -Ok $true
        Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_session" -Before $report.before."_arms_session" -After $report.after."_arms_session" -Ok $true
        Write-Host "    [OK] RUM telemetry updated: $Path" -ForegroundColor Green
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_uid" -Before $null -After $NewUid -Ok $false
    Add-AuditEntry -Audit $Audit -File $Path -Key "_arms_session" -Before $null -After $NewSession -Ok $false
    Write-Host "    [FAILED] RUM telemetry verification failed: $Path" -ForegroundColor Red
    return $false
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

    # Core: json-set (dotted path; intermediate dicts created when missing --
    # exactly the v1.4 Add-Member branches; verify-after re-read walks the
    # same path).
    $report = Invoke-GhostCore @("json-set", $Path, $BackupRoot, $BackupLabel,
        (_B64Payload @{ key = "webRemoteControlExternalRelayDevice.deviceSid"; value = $NewSid }))
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "webRemoteControlExternalRelayDevice.deviceSid" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        Write-Host "    [OK] deviceSid updated: $Path" -ForegroundColor Green
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "webRemoteControlExternalRelayDevice.deviceSid" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] deviceSid verification failed: $Path" -ForegroundColor Red
    return $false
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
    $null = Backup-ViaCore -Source $CredentialsPath -BackupRoot $BackupRoot -Label $backupLabel -Actions $Actions

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
    # Core: json-remove -- the oauth family is addressed by the TOP-LEVEL
    # PREFIX "oauth:" (the M1 prefix mode; the names embed colons so dotted
    # walking cannot address them) plus the zcodejwttoken exact key. The
    # core's verify-after asserts BOTH the prefix family and the exact key
    # are gone on re-read.
    $removalConfig = @{ keys = @("zcodejwttoken"); prefixes = @("oauth:") }
    $report = Invoke-GhostCore @("json-remove", $CredentialsPath, $BackupRoot, $backupLabel,
        (_B64Payload $removalConfig))
    if ($null -eq $report -or (-not $report.ok)) {
        Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "present" -After "core-invoke-failed" -Ok $false
        Write-Host "    [FAILED] oauth wipe core invocation failed: $CredentialsPath" -ForegroundColor Red
        return $false
    }
    if ($report.backed_up_to) {
        Add-ActionEntry -Actions $Actions -OriginalPath $CredentialsPath -BackupPath $report.backed_up_to
    }

    $removedCount = @($report.removed).Count
    foreach ($prop in $report.removed_prefixes.PSObject.Properties) {
        $removedCount += [int]$prop.Value
    }

    $ok = $true
    $afterSummary = "deleted $removedCount oauth keys"
    Add-AuditEntry -Audit $Audit -File $CredentialsPath -Key "oauth-credentials" -Before "present" -After $afterSummary -Ok $ok

    Write-Host "    [OK] credentials.json OAuth tokens cleared: $removedCount keys removed" -ForegroundColor Green
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
    $null = Backup-ViaCore -Source $ConfigPath -BackupRoot $BackupRoot -Label $backupLabel -Actions $Actions

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

    # Core: ONE pre-backup, then per-provider json-set -- only providers whose
    # options.apiKey ALREADY EXISTS get blanked (the v1.4 conditional; json-set
    # would otherwise CREATE options.apiKey on providers that never had one).
    # Each json-set is its own verified dotted-path write; the audit entry is
    # the aggregated v1.4 shape.
    $clearedCount = 0
    $patchFailures = 0
    foreach ($prop in $content.provider.PSObject.Properties) {
        if (($null -ne $prop.Value) -and ($null -ne $prop.Value.PSObject.Properties['options']) -and
            ($null -ne $prop.Value.options.PSObject.Properties['apiKey'])) {
            $dottedKey = "provider." + $prop.Name + ".options.apiKey"
            $keyReport = Invoke-GhostCore @("json-set", $ConfigPath, $BackupRoot, $backupLabel,
                (_B64Payload @{ key = $dottedKey; value = "" }))
            if ($null -ne $keyReport -and $keyReport.ok) {
                if ($prop.Value.options.apiKey -ne '') {
                    $clearedCount++
                }
                if ($keyReport.backed_up_to) {
                    Add-ActionEntry -Actions $Actions -OriginalPath $ConfigPath -BackupPath $keyReport.backed_up_to
                }
            }
            else {
                $patchFailures++
            }
        }
    }

    if ($patchFailures -gt 0) {
        Add-AuditEntry -Audit $Audit -File $ConfigPath -Key "provider-apikeys" -Before "present" -After ("json-set failures: " + $patchFailures) -Ok $false
        Write-Host "    [FAILED] provider apiKey blanking had core invocation failures: $ConfigPath" -ForegroundColor Red
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

    # Core: patch-argv (winstore.patch_argv_json -- the same JSONC regex twin:
    # comments + every other field survive verbatim, the crash-reporter-id
    # value is regex-replaced or inserted before the final brace, verify-after
    # by re-read).
    $report = Invoke-GhostCore @("patch-argv", $Path, $BackupRoot, $BackupLabel,
        (_B64Payload @{ new_id = $NewCrashReporterId }))
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        Write-Host "    [OK] argv.json crash-reporter-id updated" -ForegroundColor Green
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before "present" -After "verify-failed" -Ok $false
    Write-Host "    [FAILED] argv.json crash-reporter-id verification failed" -ForegroundColor Red
    return $false
}

# === v1.1 robustness helpers (ported from reset_qoder_windows-v0.3.ps1, kept in v1.2/v1.3) ========

# Aggressive tree-kill for ZCode/Qoder plus known extension helpers that hold
# file handles (verified: kilo.exe kept a log file locked as an orphan process).
# Requires 2 consecutive clean checks; hard-fails the run when unkillable.
# LEGACY: kills EVERY ZCode* process unconditionally, closing BOTH windows.
# Do NOT call from single-target (Primary/Secondary) paths -- use
# Stop-ZcodeTargetTree (+ Stop-QoderProcessesOnly for Primary). Kept for
# manual full-kill scenarios only.
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
        if ($afterValue -eq "re-delete-failed") {
            Write-Host "    [FAILED] could not re-delete (file locked?): $path" -ForegroundColor Red
        }
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After $afterValue -Ok ($afterValue -eq "re-deleted")
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
# Must stay in sync with the InstanceMap in launch_zcode_second_instance.ps1.
function Get-ZcodeTargetRoots {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Primary', 'Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')][string]$Label
    )

    switch ($Label) {
        'Secondary' {
            return @{
                Label       = 'Secondary'
                Roaming     = Join-Path $env:APPDATA 'ZCode-Second'
                UserProfile = Join-Path $env:USERPROFILE 'ZCodeSecondHome\.zcode'
            }
        }
        'Third' {
            return @{
                Label       = 'Third'
                Roaming     = Join-Path $env:APPDATA 'ZCode-Third'
                UserProfile = Join-Path $env:USERPROFILE 'ZCodeThirdHome\.zcode'
            }
        }
        'Fourth' {
            return @{
                Label       = 'Fourth'
                Roaming     = Join-Path $env:APPDATA 'ZCode-Fourth'
                UserProfile = Join-Path $env:USERPROFILE 'ZCodeFourthHome\.zcode'
            }
        }
        'Fifth' {
            return @{
                Label       = 'Fifth'
                Roaming     = Join-Path $env:APPDATA 'ZCode-Fifth'
                UserProfile = Join-Path $env:USERPROFILE 'ZCodeFifthHome\.zcode'
            }
        }
        'Sixth' {
            return @{
                Label       = 'Sixth'
                Roaming     = Join-Path $env:APPDATA 'ZCode-Sixth'
                UserProfile = Join-Path $env:USERPROFILE 'ZCodeSixthHome\.zcode'
            }
        }
        default {
            return @{
                Label       = 'Primary'
                Roaming     = Join-Path $env:APPDATA 'ZCode'
                UserProfile = Join-Path $env:USERPROFILE '.zcode'
            }
        }
    }
}

# Classify ZCode MAIN PIDs by instance using descendant CommandLines.
# A main is ONLY a bare-exe process (CommandLine == just "...ZCode.exe", no
# args). Helpers (glm app-server, plugin-host, cua-helper --socket, --type=*)
# all carry extra args and must NOT be treated as mains -- v1.4 pre-release
# dry-run caught this (--type filter alone misclassified 12 helpers as mains).
# A main whose subtree carries one clone's marker strings (its roaming dir name
# or clone home dir name) belongs to that clone; any other ZCode main is
# Primary. Clone home dirs are disjoint, so the first marker match is decisive.
# Returns @{ Primary = @(pids); Secondary = @(pids); Third = @(pids); Fourth = @(pids); Fifth = @(pids); Sixth = @(pids) }.
$script:ZcodeCloneMarkers = @{
    Secondary = @('*ZCode-Second*', '*ZCodeSecondHome*')
    Third     = @('*ZCode-Third*', '*ZCodeThirdHome*')
    Fourth    = @('*ZCode-Fourth*', '*ZCodeFourthHome*')
    Fifth     = @('*ZCode-Fifth*', '*ZCodeFifthHome*')
    Sixth     = @('*ZCode-Sixth*', '*ZCodeSixthHome*')
}
# Per-color exe copies (2026-11-11 Task Manager identity): a main running FROM
# ZCode-<Color>.exe is that clone outright - deterministic even mid-splash.
$script:ZcodeCloneExeNames = @{
    Secondary = 'ZCode-Blue.exe'
    Third     = 'ZCode-Yellow.exe'
    Fourth    = 'ZCode-Green.exe'
    Fifth     = 'ZCode-Red.exe'
    Sixth     = 'ZCode-Orange.exe'
}
$script:ZcodeAllLabels = @('Primary', 'Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')

function Get-ZcodeTargetMains {
    $result = @{}
    foreach ($k in $script:ZcodeAllLabels) { $result[$k] = @() }
    # Filter covers the whole copy family - a bare Name='ZCode.exe' silently
    # drops clones running from their per-color exe copies.
    $procs = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return $result }

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
        # [^"]* (not [^\s"]*) so spaced install paths match (see launcher note).
        ([string]::IsNullOrWhiteSpace($cmd)) -or
        ($cmd -match '^"[^"]*ZCode(?:-[A-Za-z]+)?\.exe"$') -or ($cmd -match '^[A-Za-z]:\\[^"]*ZCode(?:-[A-Za-z]+)?\.exe$')
    })
    foreach ($m in $mains) {
        $seen = @{}
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([int]$m.ProcessId) | Out-Null
        $matchedLabel = $null
        # Copy-exe identity first: the main's own command line is decisive even
        # mid-splash, before any child carries the marker strings.
        $rootCmd = ([string]$m.CommandLine).Trim()
        foreach ($label in @('Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
            if ($rootCmd -match ('(?i)' + [regex]::Escape($script:ZcodeCloneExeNames[$label]))) { $matchedLabel = $label; break }
        }
        while (($queue.Count -gt 0) -and (-not $matchedLabel)) {
            $childPid = $queue.Dequeue()
            if ($seen.ContainsKey($childPid)) { continue }
            $seen[$childPid] = $true
            if ($byParent.ContainsKey($childPid)) {
                foreach ($c in $byParent[$childPid]) {
                    $cmd = [string]$c.CommandLine
                    foreach ($label in @('Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
                        foreach ($mk in $script:ZcodeCloneMarkers[$label]) {
                            if ($cmd -like $mk) { $matchedLabel = $label; break }
                        }
                        if ($matchedLabel) { break }
                    }
                    if ($matchedLabel) { break }
                    $queue.Enqueue([int]$c.ProcessId) | Out-Null
                }
            }
        }
        if (-not $matchedLabel) { $matchedLabel = 'Primary' }
        $result[$matchedLabel] += [int]$m.ProcessId
    }
    return $result
}

# Selective tree-kill for ONE ZCode instance. Kills only target mains (+ whole
# subtree via /T, covering glm/cua-helper/plugin-host children that carry no
# user-data-dir flag themselves). Shared Qoder helpers are never touched here.
# Returns $true when the target is gone across 2 consecutive checks AND (when
# requested AND a survivor existed at entry) the survivor mains still exist.
# -RequireSurvivor is conditional: when no survivor main exists at entry
# (target-only running, or Primary child after the clones already exited) the
# run succeeds without a survivor instead of failing.
# Ambiguity guard: when Label=Primary and 2+ mains exist but NONE classify as
# any clone (classifier found no clone marker in any subtree), killing
# "Primary" would kill EVERYTHING including the survivor, so the run aborts
# with a diagnostic dump instead of killing all.
function Stop-ZcodeTargetTree {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Primary', 'Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')][string]$Label,
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500,
        [switch]$RequireSurvivor
    )

    Write-Host "[*] Terminating ZCode $(Get-ZcodeTargetDisplay $Label) instance tree only (survivors preserved)..." -ForegroundColor Cyan
    $entryMap = Get-ZcodeTargetMains
    $entryTotal = 0
    foreach ($k in $script:ZcodeAllLabels) { $entryTotal += @($entryMap[$k]).Count }
    $entryTargets = @($entryMap[$Label]).Count
    $entrySurvivors = $entryTotal - $entryTargets
    $enforceSurvivor = $RequireSurvivor -and ($entrySurvivors -gt 0)
    if ($RequireSurvivor -and (-not $enforceSurvivor)) {
        Write-Host "    [INFO] no survivor instance running at entry -- survivor check disabled" -ForegroundColor DarkGray
    }
    if (($Label -eq 'Primary') -and ($entryTargets -ge 2) -and ($entrySurvivors -eq 0)) {
        Write-Host "[FAILED] ambiguous classification: $($entryTargets) ZCode mains running but none classify as a clone." -ForegroundColor Red
        Write-Host "    Refusing to kill: every main looks like Primary, so a Primary tree-kill would close ALL windows." -ForegroundColor Red
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction SilentlyContinue)) {
            Write-Host ("    PID {0} PPID {1}: {2}" -f $p.ProcessId, $p.ParentProcessId, [string]$p.CommandLine) -ForegroundColor Red
        }
        Write-Host "    Hint: restart the clone via its shortcut / launcher (env-var isolated launch) so its subtree carries the clone home marker, then retry." -ForegroundColor Yellow
        return $false
    }
    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $map = Get-ZcodeTargetMains
        $targets = @($map[$Label])
        foreach ($targetPid in $targets) {
            $null = & taskkill /F /T /PID $targetPid 2>&1
        }
        Start-Sleep -Milliseconds $DelayMs
        $map = Get-ZcodeTargetMains
        $remaining = @($map[$Label]).Count
        $totalNow = 0
        foreach ($k in $script:ZcodeAllLabels) { $totalNow += @($map[$k]).Count }
        $survivors = $totalNow - $remaining
        Write-Host ("    attempt {0}/{1} - target remaining: {2}, survivor mains: {3}" -f $attempt, $MaxAttempts, $remaining, $survivors) -ForegroundColor DarkGray
        if ($remaining -eq 0) {
            if ($enforceSurvivor -and ($survivors -eq 0)) {
                Write-Host "[WARN] target is gone but the survivor instance is also gone!" -ForegroundColor Yellow
                $consecutiveClean = 0
            }
            else {
                $consecutiveClean++
                if ($consecutiveClean -ge 2) {
                    Write-Host "[OK] ZCode $(Get-ZcodeTargetDisplay $Label) tree terminated (2 clean checks); survivor mains: $survivors" -ForegroundColor Green
                    return $true
                }
            }
        }
        else { $consecutiveClean = 0 }
    }
    Write-Host "[FAILED] ZCode $(Get-ZcodeTargetDisplay $Label) tree still running after $MaxAttempts attempts. Aborting." -ForegroundColor Red
    return $false
}

# Qoder-only kill for the Primary path. Kills Qoder* mains (each via /T so its
# own children are reaped) plus orphaned extension helpers that lock Qoder
# files (kilo.exe kept a log locked as an orphan process). NEVER touches any
# ZCode* process: shared helpers (kilo/roo/cline/blackbox) are killed ONLY when
# their ancestor chain does NOT lead to a surviving CLONE ZCode main (any of
# Secondary/Third/Fourth/Fifth/Sixth), so running clone instances keep their helpers.
# Clone targets never call this (Qoder stays running there by design).
function Stop-QoderProcessesOnly {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating Qoder processes only (ZCode survivors untouched)..." -ForegroundColor Cyan
    $qoderImageNames = @("Qoder", "Qoder Helper", "Qoder Helper (GPU)", "Qoder Helper (Renderer)")
    $sharedHelperNames = @("kilo", "roo", "cline", "cline-host", "blackbox")
    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $zmap = Get-ZcodeTargetMains
        $clonePids = @()
        foreach ($cloneLabel in @('Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
            $clonePids += @($zmap[$cloneLabel])
        }

        $allProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $byPid = @{}
        foreach ($p in $allProcs) { $byPid[[int]$p.ProcessId] = $p }

        foreach ($imageName in $qoderImageNames) {
            $matches = @($allProcs | Where-Object { $_.Name -ieq ($imageName + ".exe") })
            foreach ($m in $matches) {
                $null = & taskkill /F /T /PID ([int]$m.ProcessId) 2>&1
            }
        }
        foreach ($helperName in $sharedHelperNames) {
            $matches = @($allProcs | Where-Object { $_.Name -ieq ($helperName + ".exe") })
            foreach ($m in $matches) {
                $helperPid = [int]$m.ProcessId
                # Inline ancestor walk: spare helpers descending from a
                # surviving clone ZCode main (dynamic scoping of nested
                # functions is fragile, so no helper function here).
                $isCloneHelper = $false
                $seenPids = @{}
                $currentPid = $helperPid
                while ($true) {
                    if ($clonePids -contains $currentPid) { $isCloneHelper = $true; break }
                    if ($seenPids.ContainsKey($currentPid)) { break }
                    $seenPids[$currentPid] = $true
                    if (-not $byPid.ContainsKey($currentPid)) { break }
                    $parentPid = [int]$byPid[$currentPid].ParentProcessId
                    if (($parentPid -eq 0) -or ($parentPid -eq $currentPid)) { break }
                    $currentPid = $parentPid
                }
                if ($isCloneHelper) { continue }
                $null = & taskkill /F /T /PID $helperPid 2>&1
            }
        }

        Start-Sleep -Milliseconds $DelayMs

        $qoderRemaining = @(Get-Process -Name "Qoder*" -ErrorAction SilentlyContinue).Count
        $zmapAfter = Get-ZcodeTargetMains
        $cloneSurvivors = 0
        foreach ($cloneLabel in @('Secondary', 'Third', 'Fourth', 'Fifth', 'Sixth')) {
            $cloneSurvivors += @($zmapAfter[$cloneLabel]).Count
        }
        Write-Host ("    attempt {0}/{1} - Qoder remaining: {2}, clone survivors: {3}" -f $attempt, $MaxAttempts, $qoderRemaining, $cloneSurvivors) -ForegroundColor DarkGray
        if ($qoderRemaining -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] Qoder processes terminated (2 clean checks); clone survivors: $cloneSurvivors" -ForegroundColor Green
                return $true
            }
        }
        else { $consecutiveClean = 0 }
    }
    Write-Host "[FAILED] Qoder processes still running after $MaxAttempts attempts. Aborting." -ForegroundColor Red
    return $false
}

# === Main =====================================================================

Assert-Administrator

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$qoderRoaming = Join-Path $env:APPDATA "Qoder"
$qoderUserProfile = Join-Path $env:USERPROFILE ".qoder"
$qoderIdBackupsRoot = Join-Path $qoderRoaming "ID_Backups"

# --- target resolution (v1.4 mechanism, unchanged) ---------------------------------------------------
# Both/All modes orchestrate INDEPENDENT child runs (clones first with -SkipQoder
# so Qoder steps execute exactly once, in the Primary child). Each child
# generates its OWN fresh ID set -> per-instance identity rule holds.
# 'Both' = Secondary + Primary (kept for backward compatibility with menus).
# 'All'  = Third + Fourth + Fifth + Sixth + Secondary + Primary.
if (($Target -eq 'Both') -or ($Target -eq 'All')) {
    $orchestratorScript = $MyInvocation.MyCommand.Path
    if ($Target -eq 'Both') {
        $children = @(
            @{ Label = 'Secondary'; SkipQoder = $true },
            @{ Label = 'Primary';   SkipQoder = $false }
        )
    } else {
        $children = @(
            @{ Label = 'Third';     SkipQoder = $true },
            @{ Label = 'Fourth';    SkipQoder = $true },
            @{ Label = 'Fifth';     SkipQoder = $true },
            @{ Label = 'Sixth';     SkipQoder = $true },
            @{ Label = 'Secondary'; SkipQoder = $true },
            @{ Label = 'Primary';   SkipQoder = $false }
        )
    }
    $childCount = $children.Count
    Write-Host "=== ZCode Identity Reset v1.5 - $(Get-ZcodeTargetDisplay $Target) - independent IDs per instance ===" -ForegroundColor Cyan
    $exitCodes = @()
    for ($ci = 0; $ci -lt $childCount; $ci++) {
        $child = $children[$ci]
        $qoderNote = ''
        if (-not $child.SkipQoder) { $qoderNote = ' (incl. Qoder)' }
        Write-Host ("[{0} {1}/{2}] Resetting {3} instance{4}..." -f (Get-ZcodeTargetDisplay $Target), ($ci + 1), $childCount, (Get-ZcodeTargetDisplay $child.Label), $qoderNote) -ForegroundColor Cyan
        $fwdArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $v14Script, '-Target', $child.Label)
        if ($child.SkipQoder) { $fwdArgs += '-SkipQoder' }
        & powershell @fwdArgs
        $exitCodes += $LASTEXITCODE
    }
    Write-Host "`n=== Summary - $(Get-ZcodeTargetDisplay $Target) mode ===" -ForegroundColor Cyan
    for ($ci = 0; $ci -lt $childCount; $ci++) {
        Write-Host ("{0} exit: {1}" -f (Get-ZcodeTargetDisplay $children[$ci].Label), $exitCodes[$ci]) -ForegroundColor Gray
    }
    Write-Host "NOTE: IDs were generated independently per instance (never duplicated)." -ForegroundColor Yellow
    Write-Host "NOTE: change_device_id.ps1 is machine-wide and affects ALL ZCode instances + Qoder." -ForegroundColor Yellow
    $anyFail = $false
    foreach ($code in $exitCodes) { if ($code -ne 0) { $anyFail = $true } }
    if ($anyFail) { exit 1 }
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
    Write-Host "ZCode $(Get-ZcodeTargetDisplay $Target) instance not found at: $zcodeRoaming" -ForegroundColor Red
    Write-Host "Hint: launch it once via its clone shortcut / launcher (Blue/Yellow/Green/Red/Orange) or ZCode.exe (Primary)." -ForegroundColor Yellow
    exit 1
}

# v1.5: the core must be present and a functional Python 3 with it - fail
# fast BEFORE touching anything (v1.4 needed Python only for the SQLite
# steps; v1.5 routes every store mutation through the core).
if ((-not (Get-GhostPythonCli)) -or (-not (Get-PythonCommandInfo))) {
    Write-Host "[FAILED] GHOST Python core (src\python\ghost_cli.py) missing or no functional Python 3 found - every ZCode reset step needs it (winget install Python.Python.3.12)." -ForegroundColor Red
    exit 1
}

$qoderPresent = Test-Path -LiteralPath $qoderRoaming
$qoderProfiles = @()
if ($qoderPresent) {
    $qoderProfiles = @(Get-QoderProfileRoots -MainRoot $qoderRoaming)
}
if ($SkipQoder) {
    # Clone child in Both/All mode: Qoder belongs to the Primary run only.
    $qoderPresent = $false
    $qoderProfiles = @()
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== ZCode / Qoder Identity Reset v1.5 - Target: $(Get-ZcodeTargetDisplay $Target) ===" -ForegroundColor Cyan
Write-Host "ZCode $(Get-ZcodeTargetDisplay $Target): $zcodeRoaming" -ForegroundColor Gray
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
Write-Host "NOTE: change_device_id.ps1 is machine-wide and affects ALL ZCode instances + Qoder." -ForegroundColor Yellow

# Pre-step: scoped tree-kill. Single-target mode kills ONLY the target ZCode
# tree (survivors keep running). Qoder processes are killed only when the
# Primary target needs its Qoder steps (via Qoder-only kill that never touches
# ZCode); clone targets never touch Qoder. The aggressive kill-all helper is
# intentionally NOT used here (it closes ALL ZCode windows).
if ($Target -eq 'Primary') {
    if (-not (Stop-ZcodeTargetTree -Label Primary -RequireSurvivor)) {
        exit 1
    }
    if ($qoderPresent) {
        if (-not (Stop-QoderProcessesOnly)) {
            exit 1
        }
    }
}
else {
    if (-not (Stop-ZcodeTargetTree -Label $Target -RequireSurvivor)) {
        exit 1
    }
}

$passCount = 0
$failCount = 0

$newDeviceMid = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newUpdaterId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
# (The Preferences salts are no longer PS-generated: the core's salt-rotate
# generates a fresh CSPRNG 32-lowercase-hex salt PER PROFILE -- v1.4 generated
# ONE Get-Random uppercase-hex salt shared across every profile the run
# touched: a weak PRNG AND a cross-profile correlation signal.)
$newCrashReporterId = Get-NewCrashReporterId
# RNG convention fix (repo rule: RandomNumberGenerator via .GetBytes() only --
# v1.4 used the time-seeded Get-Random PRNG for identity material):
$rngBytes = New-Object byte[] 12
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($rngBytes) } finally { $rng.Dispose() }
$newArmsUid = "uid_" + (($rngBytes | ForEach-Object { "abcdefghijklmnopqrstuvwxyz0123456789"[$_ % 36] }) -join "")
$rngBytes2 = New-Object byte[] 14
$rng2 = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng2.GetBytes($rngBytes2) } finally { $rng2.Dispose() }
$newDeviceSid = "d_" + (($rngBytes2 | ForEach-Object { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[$_ % 62] }) -join "")
$newArmsSession = "{0}-1-{1}-{1}" -f $newArmsUid.Substring(4), ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())

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
            # Core: backup + json-patch (Set-JsonIdentity's contract split
            # across the core verbs).
            $null = Backup-ViaCore -Source $p -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Actions ([ref]$actions)
            $stReport = Invoke-GhostCore @("json-patch", $p, (_B64Payload $storageUpdates))
            if ($null -ne $stReport -and $stReport.ok) {
                foreach ($key in $storageUpdates.Keys) {
                    Add-AuditEntry -Audit ([ref]$audit) -File $p -Key $key -Before $stReport.before.$key -After $stReport.after.$key -Ok $true
                }
                Write-Host "    [$(Get-ZcodeLabelColor $label)] [OK] storage.json verified" -ForegroundColor Green
            }
            else {
                foreach ($key in $storageUpdates.Keys) {
                    Add-AuditEntry -Audit ([ref]$audit) -File $p -Key $key -Before $null -After $storageUpdates[$key] -Ok $false
                }
                Write-Host "    [$(Get-ZcodeLabelColor $label)] [FAILED] storage.json verification failed" -ForegroundColor Red
                $stepFailed = $true
            }
        }
        else {
            Write-Host "    [$(Get-ZcodeLabelColor $label)] [SKIP] storage.json not present" -ForegroundColor Yellow
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
                Write-Host "    [$(Get-ZcodeLabelColor $label)] [OK] machineid verified" -ForegroundColor Green
            }
            else {
                Write-Host "    [$(Get-ZcodeLabelColor $label)] [FAILED] machineid verification failed" -ForegroundColor Red
                $stepFailed = $true
            }
        }
        else {
            Write-Host "    [$(Get-ZcodeLabelColor $label)] [SKIP] machineid not present" -ForegroundColor Yellow
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
    # Core: backup + json-patch (Set-JsonIdentity's contract split across the
    # core verbs).
    $null = Backup-ViaCore -Source $zcodeTelemetryStatePath -BackupRoot $backupRoot -Label (Get-UserProfileBackupLabel -TargetPath $zcodeTelemetryStatePath) -Actions ([ref]$actions)
    $midReport = Invoke-GhostCore @("json-patch", $zcodeTelemetryStatePath, (_B64Payload @{ "deviceMid" = $newDeviceMid }))
    if ($null -ne $midReport -and $midReport.ok) {
        Add-AuditEntry -Audit ([ref]$audit) -File $zcodeTelemetryStatePath -Key "deviceMid" -Before $midReport.before."deviceMid" -After $midReport.after."deviceMid" -Ok $true
        Write-Host "[OK] telemetry-state.json verified" -ForegroundColor Green
        $passCount++
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $zcodeTelemetryStatePath -Key "deviceMid" -Before $null -After $newDeviceMid -Ok $false
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
    $auditStart = $audit.Count
    $cacheActions = Invoke-StoreDelete -Paths @($zcodeCodingPlanCachePath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
    $actions += @($cacheActions)
    $status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $zcodeCodingPlanCachePath
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
            # Core: backup + sqlite-update (the verify-after re-read carries
            # the verdict).
            $null = Backup-ViaCore -Source $p -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Actions ([ref]$actions)
            $svReport = Invoke-GhostCore @("sqlite-update", $p, (_B64Payload @{ "storage.serviceMachineId" = $ids.devDeviceId }))
            if ($null -ne $svReport -and $null -ne $svReport.after -and ($svReport.after."storage.serviceMachineId" -eq $ids.devDeviceId)) {
                Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "storage.serviceMachineId" -Before $svReport.before."storage.serviceMachineId" -After $svReport.after."storage.serviceMachineId" -Ok $true
                Write-Host "    [$(Get-ZcodeLabelColor $label)] [OK] state.vscdb verified" -ForegroundColor Green
            }
            else {
                Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "storage.serviceMachineId" -Before $null -After $ids.devDeviceId -Ok $false
                Write-Host "    [$(Get-ZcodeLabelColor $label)] [FAILED] state.vscdb verification failed" -ForegroundColor Red
                $stepFailed = $true
            }
        }
        else {
            Write-Host "    [$(Get-ZcodeLabelColor $label)] [SKIP] state.vscdb not present" -ForegroundColor Yellow
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
        Write-Host "    [$(Get-ZcodeLabelColor $label)] scrubbing secrets..." -ForegroundColor DarkGray
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
        Write-Host "    [$(Get-ZcodeLabelColor $label)] stale backup..." -ForegroundColor DarkGray
        if (-not (Remove-VerifiedFileNoBackup -Path $p -AuditKey "state.vscdb.backup" -Audit ([ref]$audit))) {
            $stepFailed = $true
        }
    }
    if ($stepFailed) { $failCount++ } else { $passCount++ }
}

# --- [11/27] ZCode session Preferences device_id_salt ---
$zcodePreferencesPath = Join-Path $zcodeRoaming "session\Preferences"
Write-Host "`n[11/27] Updating ZCode session Preferences (device_id_salt)..." -ForegroundColor Cyan
if (Set-DeviceIdSalt -Path $zcodePreferencesPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $zcodePreferencesPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
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
        Write-Host "    [$(Get-ZcodeLabelColor $label)] device_id_salt..." -ForegroundColor DarkGray
        if (-not (Set-DeviceIdSalt -Path $p -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $p) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
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
        Write-Host "    [$(Get-ZcodeLabelColor $label)] os_crypt..." -ForegroundColor DarkGray
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
$sharedActions = Invoke-StoreDelete -Paths $sharedFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
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
$sqliteActions = Invoke-StoreDelete -Paths $zcodeSqliteFullPaths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
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
$extraActions = Invoke-StoreDelete -Paths $zcodeExtraFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
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
        if (-not (Set-DeviceIdSalt -Path $embeddedPrefPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $zcodeRoaming -TargetPath $embeddedPrefPath) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
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
    $embeddedActions = Invoke-StoreDelete -Paths $embeddedFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $zcodeRoaming
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
        Write-Host "    [$(Get-ZcodeLabelColor $label)] browser data..." -ForegroundColor DarkGray
        $profileFiles = @($qoderFileRelPaths | ForEach-Object { Join-Path $pr $_ })
        $profileActions = Invoke-StoreDelete -Paths $profileFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
            Write-Host "    [$(Get-ZcodeLabelColor $label)] [OK] browser data cleared" -ForegroundColor Green
        }
        else {
            Write-Host "    [$(Get-ZcodeLabelColor $label)] [FAILED] browser data had failures" -ForegroundColor Red
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
            Write-Host "    [$(Get-ZcodeLabelColor $label)] logs/ (per-file delete)..." -ForegroundColor DarkGray
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
            Write-Host "    [$(Get-ZcodeLabelColor $label)] [SKIP] no workspace state.vscdb files found" -ForegroundColor Yellow
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
    # Core: backup + clear-cli-telemetry via the ONE invocation helper (the
    # error-dict contract is kept: sqlite failure reported in-band -- never
    # silent-success on a locked/unreadable db).
    $null = Backup-ViaCore -Source $zcodeCliDbPath -BackupRoot $backupRoot -Label (Get-UserProfileBackupLabel -TargetPath $zcodeCliDbPath) -Actions ([ref]$actions)
    $result = Invoke-GhostCore @("clear-cli-telemetry", $zcodeCliDbPath)
    if ($null -eq $result) {
        Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After "core-invoke-failed" -Ok $false
        Write-Host "[FAILED] CLI db telemetry clear core invocation failed" -ForegroundColor Red
        $failCount++
    }
    elseif ($result.PSObject.Properties.Name -contains "error") {
        Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After ("error: " + $result.error) -Ok $false
        Write-Host "[FAILED] CLI db telemetry clear failed: $($result.error)" -ForegroundColor Red
        $failCount++
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $zcodeCliDbPath -Key "cli-telemetry" -Before "present" -After ("deleted " + $result.deleted) -Ok $true
        Write-Host "[OK] CLI db telemetry cleared: $($result.deleted) keys" -ForegroundColor Green
        $passCount++
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
Write-Host "NOTE: change_device_id.ps1 is machine-wide and affects ALL ZCode instances + Qoder." -ForegroundColor Yellow

# Marker filename keeps the historical "v1.3" label (docs + user habits read
# it); the script itself is v1.4.
[System.IO.File]::WriteAllText("$env:TEMP\zcode_v1.5_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "ZCode/Qoder reset v1.4 [$(Get-ZcodeTargetDisplay $Target)] completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "ZCode/Qoder reset v1.4 [$(Get-ZcodeTargetDisplay $Target)] completed successfully." -ForegroundColor Green
