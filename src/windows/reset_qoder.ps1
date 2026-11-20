#Requires -Version 5.1
param(
    # v0.5 keeps the v0.3 opt-out switches for the system-level steps.
    # Default = ON (i.e., do them). Use -SkipMac / -SkipHostname to suppress.
    # Note: NO [CmdletBinding()] -- plain param() is deliberate: the
    # self-elevation block invokes this script with -File plus only these
    # declared switches (the *_done.txt marker file, not a log, is the
    # persisted result channel). Switches work without CmdletBinding.
    [switch]$SkipMac,
    [switch]$SkipHostname,
    [switch]$DryRun
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- W1-9-style report-only planner -------------------------------------------
# Prints the profile roots + presence, the would-kill set and the step plan,
# then exits BEFORE self-elevation (a plan never triggers UAC), before any
# kill, before any write. Zero side effects by construction. Step list mirrors
# the "--- [N/31]" headings below; tests/reset_dryrun.Tests.ps1 cross-checks
# the two so the plan cannot silently drift from the steps.
if ($DryRun) {
    Write-Host "=== DRY-RUN PLAN - Qoder Identity Reset v0.5 ===" -ForegroundColor Cyan
    $planRoot = Join-Path $env:APPDATA "Qoder"
    $planUserQoder = Join-Path $env:USERPROFILE ".qoder"
    $planRootPresent = Test-Path -LiteralPath $planRoot
    Write-Host ("Qoder roaming : {0} ({1})" -f $planRoot, $(if ($planRootPresent) { "present" } else { "NOT INSTALLED - the real run would abort here" }))
    Write-Host ("User-level    : {0} ({1})" -f $planUserQoder, $(if (Test-Path -LiteralPath $planUserQoder) { "present" } else { "missing (skips)" }))
    if ($planRootPresent) {
        $planCors = Join-Path $planRoot "CORS_Profile"
        Write-Host ("Profiles      : MAIN" + $(if (Test-Path -LiteralPath $planCors) { " + CORS_Profile" }) + " (per-profile steps run for each)")
    }
    $planCoreOk = (Get-GhostPythonCli) -and (Get-PythonCommandInfo)
    if (-not $planCoreOk) {
        Write-Host "Python core   : MISSING - the real run would fail fast here (every step needs it)." -ForegroundColor Yellow
    }
    $planRunning = @(Get-Process -Name "Qoder*" -ErrorAction SilentlyContinue)
    Write-Host ""
    Write-Host "Would kill (aggressive tree-kill, 2 clean checks required):"
    if ($planRunning.Count -eq 0) {
        Write-Host "  no Qoder processes running"
    }
    else {
        foreach ($planProc in $planRunning) { Write-Host ("  Qoder pid {0}: {1}" -f $planProc.Id, $planProc.Name) }
    }
    Write-Host ""
    Write-Host "Step plan (per-profile steps run for each profile root):"
    foreach ($planStep in @(
        "[1/31]  machineid rotate (per profile)",
        "[2/31]  storage.json telemetry keys (per profile)",
        "[3/31]  state.vscdb serviceMachineId upsert (per profile)",
        "[3b/31] state.vscdb auth secrets scrub (per profile)",
        "[4/31]  SharedClientCache\cache\id (MAIN only)",
        "[5/31]  SharedClientCache auth files (MAIN only)",
        "[6/31]  whole SharedClientCache tree (MAIN only)",
        "[7/31]  Local State delete (per profile)",
        "[8/31]  Cookies + Network PS + Trust Tokens (per profile)",
        "[9/31]  DIPS stores (per profile)",
        "[10/31] SharedStorage (per profile)",
        "[11/31] WebStorage (per profile)",
        "[12/31] Session Storage + Local Storage (per profile)",
        "[13/31] Cache + Code Cache + GPUCache (per profile)",
        "[14/31] Service Worker + blob_storage (per profile)",
        "[15/31] Crashpad + CrashFeedback (per profile)",
        "[16/31] Preferences device_id_salt rotate (per profile)",
        "[17/31] workspace state.vscdb UPSERT only (per profile)",
        "[18/31] logs/ deletion (per profile)",
        "[19/31] argv.json crash-reporter-id (user-level)",
        "[20/31] %USERPROFILE%\.qoder subdir cleanup",
        "[21/31] old ID_Backups purge (24h floor + same-day protection)",
        "[22/31] post-write watchdog re-verify",
        "[23/31] HKCU DeveloperTools deviceid source",
        "[24/31] HKLM SQMClient MachineId source",
        "[25/31] state.vscdb.backup stale auth/session backups",
        "[26/31] NIC MAC address rotation (physical adapters; -SkipMac opts out)",
        "[27/31] hostname change (-SkipHostname opts out)",
        "[28/31] %USERPROFILE%\.qoder device files",
        "[29/31] webview Chromium stores (per profile, if present)",
        "[30/31] .qoder CLI run state (tmp/telemetry + logs)",
        "[31/31] device-flow final probe (read-only, audited)"
    )) {
        Write-Host ("  {0}" -f $planStep)
    }
    Write-Host ""
    Write-Host "Preserved per policy: chat-bearing stores (memories/canvas/knowledges),"
    Write-Host "workspace files + .backup sidecars, the Qoder keep-dir backup policy."
    Write-Host ""
    Write-Host "DRY-RUN complete - nothing was written or killed." -ForegroundColor Green
    exit 0
}

# Self-elevate if not already admin. Re-launch with the same switches so the
# elevated copy sees the user's opt-out choices.
$qoderIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $qoderIsAdmin) {
    $qoderScript = $MyInvocation.MyCommand.Path
    $qoderSwitchList = @()
    if ($SkipMac)      { $qoderSwitchList += "-SkipMac" }
    if ($SkipHostname) { $qoderSwitchList += "-SkipHostname" }
    $qoderSwitchString = if ($qoderSwitchList.Count -gt 0) { " " + ($qoderSwitchList -join " ") } else { "" }
    # Single-string argument list, same proven pattern as v0.2 -- avoids any
    # array-join quoting surprises with paths that contain spaces. -File passes
    # only declared switches; a redirect operator here would be swallowed as an
    # undeclared argument (the *_done.txt marker file is the persisted result).
    $qoderArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$qoderScript`"$qoderSwitchString"
    # A stale done-marker from a PREVIOUS run must never be shown as this
    # run's result: delete it before launching (an early child exit then
    # surfaces as no result, never as the old Pass/Fail lines). -PassThru +
    # .ExitCode relays the elevated child's exit code (the old bare -Wait
    # always exited 0, so a failing reset looked green to callers that check
    # $LASTEXITCODE; the child exits 1 when failCount > 0).
    Remove-Item -LiteralPath "$env:TEMP\qoder_v0.5_done.txt" -Force -ErrorAction SilentlyContinue
    $qoderChild = Start-Process powershell -Verb RunAs -ArgumentList $qoderArgs -WindowStyle Normal -Wait -PassThru
    if (Test-Path "$env:TEMP\qoder_v0.5_done.txt") {
        Get-Content "$env:TEMP\qoder_v0.5_done.txt"
    }
    $qoderChildCode = $qoderChild.ExitCode
    if ($null -eq $qoderChildCode) { $qoderChildCode = 1 }
    exit $qoderChildCode
}

Write-GhostBanner -Target "Qoder Identity Reset" -Version "0.5"

# Qoder v0.5 -- comprehensive identity reset + system-level defenses + device-flow purge.
# THIN MANIFEST over the Python core (Phase 3 migration #6 per
# docs/PYTHON_HYBRID_ROADMAP.md: cursor v0.3 pilot, devin v0.4, trae v0.3,
# qoderwork v0.2, minimax v1.4). The 31 steps, their order, audit keys,
# restore actions and summary are IDENTICAL to v0.4 (archived at
# archive/reset_qoder_windows-v0.4.ps1, local-only); every store mutation now
# runs through src\python\ghost_cli.py (base64 payload in, JSON report out)
# via ONE invocation helper. What was deleted from v0.4: BOTH temp-.py
# heredocs and the local mutation helpers, replaced by the tested
# ghost.filesweep / ghost.winstore / ghost.backup / ghost.sqlite_keys modules.
#
#   v0.4 helper / mechanism         -> v0.5 core verb
#   Set-VerifiedMachineIdFile       -> machineid-file
#   Set-JsonIdentity (storage.json) -> backup + json-patch
#   Set-SqliteKeys (state.vscdb)    -> backup + sqlite-update
#   Clear-QoderSecrets heredoc      -> purge-keys (per-name before/after
#                                      counts, read-only reopen verify; the
#                                      v0.4 exact-key + LIKE-pattern lists and
#                                      the no-re-backup comment are kept)
#   qoder_device_probe heredoc      -> count-keys (READ-ONLY survivor count)
#   Update-QoderPreferences         -> salt-rotate (salt now generated in the
#                                      core: 32 lowercase hex per profile;
#                                      v0.4 used an uppercase GUID-N shared
#                                      across profiles -- same length/format
#                                      class, case not significant to the app)
#   Update-QoderArgvJson            -> patch-argv (JSONC regex twin: comments
#                                      survive, crash-reporter-id replaced,
#                                      verify-after)
#   Clear-BinaryIdentityStore       -> store-delete --action delete
#   Clear-TreeFilesIndividually     -> sweep-tree
#   Remove-VerifiedFileNoBackup     -> sweep-file
#
# The registry/MAC/hostname system steps ([23]-[27]) and the system-restore
# generator stay PowerShell -- OS operations, not application-store mutations
# (same split as reset_cursor v0.3's step table). Python required for every
# file/SQLite step now (fail-fast preflight).
#
# Builds on v0.3 (27 steps) with FOUR new device-flow steps (28-31) driven by
# Builds on v0.3 (27 steps) with FOUR new device-flow steps (28-31) driven by
# forensics on the live box (2026-09-15) plus the OAuth device-login URL
# (qoder.com/device/selectAccounts?challenge=...&challenge_method=S256&
# machine_id=<86-char base64url>&nonce=...&redirect_uri=qoder://.../login-success):
#
#   - state.vscdb holds secret://{"extensionId":"aicoding.aicoding-agent",
#     "key":"secret.local.machine.variables"} (the machine-variables store) and
#     aicoding.auth.loginBroadcast -- neither was scrubbed by v0.3's [3b/31].
#   - %USERPROFILE%\.qoder\installation_id (36B GUID) and
#     %USERPROFILE%\.qoder\.auth\machine_id (36B GUID) were never rotated.
#   - machine_token.json carries token (88 chars, device-token shaped) alongside
#     id/hostname -- already deleted by [5-6/31], kept as-is.
#   - The URL's 86-char machine_id is a 64-byte base64url device secret: it is
#     NOT the GUID telemetry set, so v0.4 deletes its local homes to force
#     regeneration instead of trying to pre-seed the same format.
#
# Builds on v0.2 (22 Qoder-local file steps) with five source/system
# steps (23-27) that defend against identity correlation that v0.2's file reset
# cannot address:
#
#   [23/31] HKCU DeveloperTools deviceid source rotation
#     - Native Qoder addon reads this at startup and can recalculate machineid.
#     - Sets it to the same GUID used for the per-profile machineid files.
#     - Verifies by re-reading the registry value.
#
#   [24/31] HKLM SQMClient MachineId source rotation
#     - Windows source for telemetry.sqmId cache values.
#     - Sets it to the same {UPPERCASE-GUID} used in storage.json.
#     - Verifies by re-reading the registry value.
#
#   [25/31] state.vscdb.backup stale auth/session backup deletion
#     - Deletes state.vscdb.backup (+ sidecars) WITHOUT copying them into
#       ID_Backups, because these files can preserve encrypted auth tokens.
#
#   [26/31] NIC MAC address rotation
#     - Enumerates Get-NetAdapter -Physical (skips virtual / Hyper-V / WSL / disabled)
#     - Writes a new locally-administered unicast MAC to each adapter's registry class
#       key: HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-...}\<NNNN>\NetworkAddress
#     - Disable-NetAdapter -> sleep -> Enable-NetAdapter to apply
#     - Verifies via re-read of Get-NetAdapter.MacAddress
#     - Caveats: each cycle drops the link for ~5-10 seconds. Wi-Fi adapters may
#       need to be reconnected manually if your network hides its SSID.
#
#   [27/31] Hostname change
#     - Backs up $env:COMPUTERNAME to system_manifest.json
#     - Calls Rename-Computer -NewName "DESKTOP-XXXXXXX" -Force (no -Restart, so the script
#       keeps running). Rename-Computer atomically updates FOUR registry locations:
#         HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName
#         HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName
#         HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Hostname
#         HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\NV Hostname
#     - Verifies the live ComputerName + Tcpip Hostname values
#     - Caveat: $env:COMPUTERNAME in the CURRENT process will still show the old name
#       until you restart Windows. This is by design (restarting mid-script would
#       kill the run). Restart manually after the script finishes.
#
# v0.4 device-flow steps (28-31) run AFTER the v0.3 system steps so the
# earlier file verification never sees a mid-cycle adapter. All paths are
# local-only (no network), so running them after the MAC/hostname cycle is safe:
#
#   [28/31] %USERPROFILE%\.qoder device files
#     - Rotates .qoder\installation_id + .qoder\.auth\machine_id to fresh
#       lowercase GUIDs (observed 36B format), verify-after re-read.
#     - Deletes .qoder\.auth\.credential-transaction (0B lock sentinel) and
#       .qoder\.cache\*.json (dns/endpoint caches) with backup-first.
#     - Leaves dynamic-error-codes/texts.json, settings/mcp/argv (argv handled
#       by [19/31]), and user content (projects/memory/skills/bin/app) alone.
#
#   [29/31] Webview Chromium stores (per profile, if-present)
#     - Deletes IndexedDB/, Partitions/, Storage/ trees. Absent on a fresh
#       profile (verified 2026-09-15) but created once the
#       /device/selectAccounts webview runs -- must not survive a reset.
#
#   [30/31] .qoder CLI run state
#     - Per-file delete of .qoder\tmp\telemetry\ + .qoder\logs\ run manifests
#       and qodercli logs (they embed host/run IDs). Uses the per-file retry
#       helper so one locked file cannot block the rest. Chat-bearing stores
#       (local.db tables, memories/, canvas/, knowledges/) are never touched
#       by this step.
#
#   [31/31] Device-flow final probe (read-only, audited)
#     - Re-opens each profile state.vscdb read-only and asserts ZERO survivors
#       for the scrubbed device patterns; asserts machine_token.json is absent
#       and the rotated .qoder IDs differ from their backups. Any survivor is
#       a FAIL (never silent-success).
#
# Opt-out:
#   -SkipMac        skip step 26 (do not change NIC MAC)
#   -SkipHostname   skip step 27 (do not change hostname)
#
# Restore:
#   The standard restore_Qoder_<ts>.ps1 (file-level) is generated by
#   New-RestoreScript from identity_utils.ps1 -- unchanged from v0.2.
#   A NEW restore_system_Qoder_<ts>.ps1 is generated locally by this script to
#   roll back registry source IDs + NIC MAC + hostname using system_manifest.json
#   under <root>\ID_Backups\<ts>\. Run them independently; the system restore
#   does not need any Qoder files to be present.
#   v0.4 device-file rotations ([28/31]) flow through $actions, so the
#   file-level restore script reverses them too.
#
# Out of scope (cannot be fixed locally): server-side account/IP/payment
# correlation, the WMI hardware fingerprint (soft signals max 0.19 < 0.306
# threshold; see IMPLEMENTATION_GUIDE section 5), and the aicoding-integration
# telemetry that forwards vscode.env.machineId to api2.qoder.sh/apm on every
# extension event (runtime behavior, not file-based; mitigated by the new
# Tor login + not reusing the banned account).

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

# User-level .qoder\ sits OUTSIDE the %APPDATA% root. Label backups under a
# USERPROFILE\ subtree so the restore script can rehydrate them to the right place.
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
    # The one PS -> Python invocation point for every store mutation / core
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
        Write-Host "[FAILED] no functional Python 3 found - every Qoder reset step needs it." -ForegroundColor Red
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
    # action. A locked/failed backup is reported but NOT fatal - the v0.4
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
    # verify -- the v0.4 contract verbatim; the core also creates the parent
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

    # Core: backup + sqlite-update (Set-SqliteKeys' backup+UPSERT+verify
    # contract split across the core verbs).
    $null = Backup-ViaCore -Source $WorkspaceDbPath -BackupRoot $BackupRoot -Label (Get-AppRelativeBackupLabel -RootPath $RootPath -TargetPath $WorkspaceDbPath) -Actions $Actions
    $wsReport = Invoke-GhostCore @("sqlite-update", $WorkspaceDbPath, (_B64Payload @{ "storage.serviceMachineId" = $DeviceId }))
    # [OK] only when the core's verify-after re-read returned the exact value
    # we asked for - a non-null report alone is not verification.
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

# Qoder Preferences is a Chromium JSON file with a nested
# electron.media.device_id_salt key. The fresh salt is generated in the core
# (salt-rotate: 32 lowercase hex; v0.4 used an uppercase GUID-N -- same
# length/format class, case not significant to the app) and verified after
# re-read.
function Update-QoderPreferences {
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

    $report = Invoke-GhostCore @("salt-rotate", $Path, $BackupRoot, $BackupLabel)
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before "present" -After "verify-failed" -Ok $false
    return $false
}

# Qoder spawns 14+ processes including a sub-binary at
# resources\app\resources\bin\x86_64_windows\Qoder.exe that auto-restarts and
# recreates machine_token.json / local.db mid-reset. Extensions also spawn their
# own helper binaries (kilo, cline-host, etc.) that can outlive Qoder and hold
# log file handles -- those orphans need killing too or step 18 will fail.
# Tighter taskkill /F /T (tree) loop that keeps killing until two consecutive
# zero-process checks pass. Pre-checks Get-Process first so taskkill doesn't
# surface a red NativeCommandError when nothing is running.
function Stop-QoderProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all Qoder + extension-helper processes (aggressive tree-kill)..." -ForegroundColor Cyan

    # Qoder's own processes + known extension helpers that may hold log file
    # handles. Verified on this box: kilo.exe (from kilocode.kilo-code) was the
    # lock holder for 1-Cline.log -- orphan from a prior session, NOT named
    # Qoder*, missed by v0.1/v0.2 kill loops.
    $processesToKill = @(
        "Qoder",
        "Qoder Helper",
        "Qoder Helper (GPU)",
        "Qoder Helper (Renderer)",
        "kilo",                # kilocode.kilo-code spawns kilo.exe as its CLI
        "roo",                 # rooveterinaryinc.roo-cline (if it spawns a sub-binary)
        "cline",               # cline standalone if installed (vs saoudrizwan.claude-dev)
        "cline-host",          # cline internal
        "blackbox"             # blackboxapp.blackboxagent (if it spawns a sub-binary)
    )

    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        foreach ($processName in $processesToKill) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                # try/catch: under EAP=Stop a native stderr line (the race where
                # the process exits between the check and taskkill) becomes a
                # terminating NativeCommandError that would abort the whole run
                # before audit/restore exist.
                try {
                    $null = & taskkill /F /T /IM "$processName.exe" 2>&1
                } catch {
                    # The losing race (process exited between check and kill):
                    # harmless - the clean-check loop below re-verifies.
                    Write-Host "    taskkill race on ${processName}: $($_.Exception.Message)" -ForegroundColor DarkGray
                }
            }
        }

        Start-Sleep -Milliseconds $DelayMs

        # Confirm Qoder AND helpers are gone. Wildcard check catches any
        # edge-case process names we didn't enumerate.
        $qoderRemaining = @(Get-Process -Name "Qoder*" -ErrorAction SilentlyContinue)
        $helperRemaining = 0
        foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
            $helperRemaining += @(Get-Process -Name $helperName -ErrorAction SilentlyContinue).Count
        }
        $count = $qoderRemaining.Count + $helperRemaining
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all Qoder + extension-helper processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    $stillAlive = @(Get-Process -Name "Qoder*" -ErrorAction SilentlyContinue)
    foreach ($p in $stillAlive) {
        Write-Host ("    Qoder PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    foreach ($helperName in @("kilo", "cline", "roo", "blackbox")) {
        foreach ($p in @(Get-Process -Name $helperName -ErrorAction SilentlyContinue)) {
            Write-Host ("    $helperName PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
        }
    }
    return $false
}

# aicoding.auth.* and Blackbox gituser/secret://blackbox.% rows in state.vscdb
# ItemTable leak the account email. sqlite-update only UPSERTs -- never deletes.
# This DELETEs (core: purge-keys) and verifies the survivors are zero via
# read-only reopen, with parameterized ? placeholders. The caller already
# backed up state.vscdb in step [3/31] (the core's backup verb uniquifies
# same-label re-backups, so no re-backup here either -- one pristine pre-run
# copy, one manifest entry).
#
# v0.4 expansion (forensics 2026-09-15 + device-login URL analysis):
#   - Exact: aicoding.auth.loginBroadcast (36-char broadcast token observed live;
#     same ItemTable, same account-linking risk as the userInfo/Plan/Usage trio).
#   - LIKE secret://aicoding.auth.% (covers any future secret://-prefixed auth
#     rows beyond the three known exact keys -- exact keys are kept too so the
#     audit log still names them individually).
#   - LIKE %secret.local.machine.variables% (the machine-variables store at
#     secret://{"extensionId":"aicoding.aicoding-agent",
#     "key":"secret.local.machine.variables"} -- 217-char JSON value observed
#     live. Matched by LIKE because the full ItemTable key embeds quotes/braces
#     that are brittle to hardcode as an exact key).
# Chat/model keys (aicoding-chat-*.state.hidden, modelConfigs/modelMap caches,
# quest/history snapshots) are deliberately NOT matched -- chat preserved.
function Clear-QoderSecrets {
    param(
        [Parameter(Mandatory = $true)][string]$DbPath,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    $exactKeys = @(
        "secret://aicoding.auth.userInfo",
        "secret://aicoding.auth.userPlan",
        "secret://aicoding.auth.creditUsage",
        "aicoding.auth.loginBroadcast",
        "gituser"
    )
    $likePatterns = @("secret://blackbox.%", "secret://aicoding.auth.%", "%secret.local.machine.variables%")

    if (-not (Test-Path -LiteralPath $DbPath)) {
        foreach ($key in ($exactKeys + $likePatterns)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before "missing" -After "skipped" -Ok $true
        }
        return $true
    }

    # Core: purge-keys (exact keys + LIKE patterns on ItemTable; per-name
    # before/after COUNT reports; read-only reopen verify). The v0.4 comment
    # stands: the caller already backed up state.vscdb in step [3/31] (the
    # core's backup verb uniquifies same-label re-backups, so no re-backup
    # here either -- one pristine pre-run copy, one manifest entry).
    $purgeConfig = @{
        exact_keys    = $exactKeys
        like_patterns = $likePatterns
        table         = "ItemTable"
    }
    $result = Invoke-GhostCore @("purge-keys", $DbPath, (_B64Payload $purgeConfig))
    if ($null -eq $result -or $null -eq $result.after) {
        foreach ($key in ($exactKeys + $likePatterns)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "core-invoke-failed" -Ok $false
        }
        Write-Host "    [FAILED] secret scrub core invocation failed: $DbPath" -ForegroundColor Red
        return $false
    }

    $allMatched = $true
    foreach ($key in ($exactKeys + $likePatterns)) {
        $before = $result.before.$key
        $after = $result.after.$key
        $ok = ($after -eq 0)
        Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before ("count=" + $before) -After ("count=" + $after) -Ok $ok
        if (-not $ok) {
            $allMatched = $false
        }
    }
    return $allMatched
}

# Post-reset watchdog probe: if a slow-shutdown helper recreated core auth files
# within 2s, re-delete. Returns $true only when nothing was recreated or every
# re-delete succeeded; a FAILED re-delete now counts into the step verdict
# (2026-11-15, aligned with the zcode/trae convention - the recreate itself
# stays a WARN, the un-removable store is the failure).
function Test-QoderWatchdogRecreation {
    param(
        [Parameter(Mandatory = $true)][string[]]$CoreFiles,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
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

# Qoder keeps a second Chromium-style profile under <root>\CORS_Profile\. Resetting
# only the main profile leaves it fully intact with its own machineid, telemetry
# IDs, Cookies, state.vscdb secrets, etc., which links the new Tor login straight
# back to the banned fingerprint. Returns @(<root>, CORS_Profile) when CORS exists.
function Get-QoderProfileRoots {
    param([Parameter(Mandatory = $true)][string]$MainRoot)

    $roots = @($MainRoot)
    $corsRoot = Join-Path $MainRoot "CORS_Profile"
    if (Test-Path -LiteralPath $corsRoot) {
        $roots += $corsRoot
    }
    return $roots
}

# Short label for a profile root, used in [OK]/[FAILED] messages.
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

# %USERPROFILE%\.qoder\argv.json is JSONC (comments allowed). Core: patch-argv
# (winstore.patch_argv_json -- the JSONC regex twin: comments + every other
# field survive verbatim, the crash-reporter-id value is regex-replaced or
# inserted, verify-after by re-read).
function Update-QoderArgvJson {
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

    $report = Invoke-GhostCore @("patch-argv", $Path, $BackupRoot, $BackupLabel,
        (_B64Payload @{ new_id = $NewCrashReporterId }))
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $report.before -After $report.after -Ok $true
        if ($report.backed_up_to) {
            Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $report.backed_up_to
        }
        return $true
    }

    Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before "present" -After "verify-failed" -Ok $false
    return $false
}

# Old ID_Backups directories (from previous reset runs) preserve complete snapshots
# of every identity file with the OLD ID still embedded. Purge policy (2026-11-15,
# BS-7 / the #73 zcode policy shape): the CURRENT run's dir is never deleted; only
# dirs OLDER than 24h are purgeable (a same-day dir may be the only undo copy of
# an earlier chained run); before deleting an old dir, its audit_*.json +
# restore_*.ps1 move up to the ID_Backups root so every earlier run's undo
# evidence survives its data purge; every delete is VERIFIED (Remove-Item then
# Test-Path) - "deleted" is never audited for a dir that is still there.
function Invoke-OldIdBackupsPurge {
    param(
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$IdBackupsRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    $currentTimestamp = Split-Path -Leaf $BackupRoot
    if (-not (Test-Path -LiteralPath $IdBackupsRoot)) {
        Add-AuditEntry -Audit $Audit -File $IdBackupsRoot -Key "id-backups-purge" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    no ID_Backups directory to purge" -ForegroundColor DarkGray
        return
    }

    $allBackups = @(Get-ChildItem -LiteralPath $IdBackupsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    $recentFloor = (Get-Date).AddHours(-24)
    $toDelete = @($allBackups | Where-Object { $_.Name -ne $currentTimestamp -and $_.LastWriteTime -lt $recentFloor })

    if ($toDelete.Count -eq 0) {
        Add-AuditEntry -Audit $Audit -File $IdBackupsRoot -Key "id-backups-purge" -Before "none" -After "none" -Ok $true
        Write-Host "    no older ID_Backups to purge (current run kept; same-day runs protected)" -ForegroundColor DarkGray
        return
    }

    foreach ($dir in $toDelete) {
        Write-Host "    [PURGE] $($dir.Name) (older than 24h; deleting)" -ForegroundColor DarkGray
        foreach ($manifest in @(Get-ChildItem -LiteralPath $dir.FullName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'audit_*.json' -or $_.Name -like 'restore_*.ps1' })) {
            Move-Item -LiteralPath $manifest.FullName -Destination (Join-Path $IdBackupsRoot $manifest.Name) -Force -ErrorAction SilentlyContinue
            Add-AuditEntry -Audit $Audit -File $manifest.FullName -Key "restore-manifest-preserved" -Before "present" -After "preserved" -Ok $true
        }
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $gone = -not (Test-Path -LiteralPath $dir.FullName)
        Add-AuditEntry -Audit $Audit -File $dir.FullName -Key "id-backups-purge" -Before "present" -After $(if ($gone) { "deleted" } else { "still-present" }) -Ok $gone
        if (-not $gone) {
            Write-Host "    [FAILED] could not delete (locked?): $($dir.FullName)" -ForegroundColor Red
        }
    }
}

# %USERPROFILE%\.qoder\extensions has changed across Qoder builds: older
# installs may expose it as a SymbolicLink to VS Code extensions, while current
# builds can create a real directory with bundled tooling. Remove-Item -Recurse
# would follow a reparse point and could delete the VS Code extensions folder.
# This helper detects reparse points (junctions AND symbolic links) and deletes
# the link itself, leaving the target untouched. Real directories fall through
# to the normal Clear-BinaryIdentityStore delete path. Returns the action taken:
# 'link-removed', 'missing', or the normal delete result.
function Remove-QoderPathSafely {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "user-qoder-subdir" -Before "missing" -After "skipped" -Ok $true
        return "missing"
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    $isReparsePoint = $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)

    if ($isReparsePoint) {
        # Backup is meaningless for a link (it's just a target string). Delete
        # the link itself without following it to the target's contents.
        $linkType = if ($item.LinkType) { $item.LinkType } else { "ReparsePoint" }
        $target = if ($item.Target) { $item.Target } else { "<unknown>" }
        Write-Host "    [LINK] $Path ($linkType -> $target) -- removing link only" -ForegroundColor DarkGray
        $item.Delete()
        Add-AuditEntry -Audit $Audit -File $Path -Key "user-qoder-subdir" -Before "$linkType->$target" -After "link-removed" -Ok $true
        $Actions.Value += @([ordered]@{
            action       = "delete"
            originalPath = $Path
            backupPath   = $null
            renamedPath  = $null
        })
        return "link-removed"
    }

    $storeAuditStart = $Audit.Value.Count
    $binaryActions = Invoke-StoreDelete -Paths @($Path) -Action "delete" -BackupRoot $BackupRoot -Audit $Audit -RootPath $env:USERPROFILE
    $Actions.Value += @($binaryActions)
    # BS-7: an honest verdict - "deleted" is only claimed when no audit entry
    # for this path failed (a locked store previously still returned
    # "deleted" and step [20] counted a green pass).
    $storeFailures = @($Audit.Value | Select-Object -Skip $storeAuditStart | Where-Object { -not $_.ok }).Count
    if ($storeFailures -gt 0) { return "delete-failed" }
    return "deleted"
}

# Delete every file under $Path individually with retry, then prune empty dirs
# (core: sweep-tree -- the per-file retry curve twin). Why not a whole-tree
# delete: it fails FAST on the first locked file and leaves 99% of the tree
# intact. Verified on this box: 1-Cline.log locked by orphan kilo.exe, 237
# other log files stayed on disk. Per-file delete means 1 stuck file doesn't
# block the rest -- we still delete 237/238 and surface the 1 failure honestly
# in audit.
function Clear-TreeFilesIndividually {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        return @{ Deleted = 0; Failed = 0; FailedPaths = @(); BackedUpTo = $null }
    }

    $sweepReport = Invoke-GhostCore @("sweep-tree", $Path, $BackupRoot, $BackupLabel)
    if ($null -eq $sweepReport) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "present" -After "core-invoke-failed" -Ok $false
        return @{ Deleted = 0; Failed = 0; FailedPaths = @(); BackedUpTo = $null }
    }

    foreach ($failedPath in @($sweepReport.failed_paths)) {
        Add-AuditEntry -Audit $Audit -File $failedPath -Key "binary-store" -Before "present" -After "delete-failed" -Ok $false
    }

    $summary = "deleted=" + $sweepReport.deleted + " failed=" + $sweepReport.failed
    $ok = ($sweepReport.failed -eq 0)
    Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "present" -After $summary -Ok $ok

    return @{ Deleted = $sweepReport.deleted; Failed = $sweepReport.failed; FailedPaths = @($sweepReport.failed_paths); BackedUpTo = $sweepReport.backed_up_to }
}

# Look at audit entries added since $StartIndex. If any of them pertain to
# $Path (or its children) and have ok=$false, the step had a partial failure.
# Returns @{ Success = $true/$false; FailedEntries = @() }.
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

# ===== v0.3 NEW HELPERS: NIC MAC + Hostname =====

# Network adapter class root in the registry. Each physical/virtual NIC has a
# subkey (0000, 0001, ...) with the NetCfgInstanceId we use to match the
# Get-NetAdapter.InterfaceGuid.
$NicClassRoot = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E972-E325-11CE-BFC1-08002BE10318}"

# Match a Get-NetAdapter.InterfaceGuid to its class registry key. Returns the
# RegistryKey object (PSPath is e.g. Microsoft.PowerShell.Core\Registry::HKEY_...)
# or $null if not found.
function Find-AdapterClassKey {
    param(
        [Parameter(Mandatory = $true)][string]$InterfaceGuid
    )

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

# 6 random bytes with bit 0 = 0 (unicast) and bit 1 = 1 (locally-administered)
# per IEEE 802. Returned as 12 uppercase hex chars, no separators -- the format
# Windows stores in NetworkAddress (REG_SZ).
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

# Local New-RandomHostname removed (v0.3.1): use Get-NewHostname from
# identity_utils.ps1 -- DESKTOP-XXXXXXX factory-default pattern instead of
# the recognizable WIN-XXXXXXXX reset-tool signature.
function New-RandomHostname {
    return Get-NewHostname
}

# Set and verify a REG_SZ value. Used for the Qoder source IDs that live outside
# the application data files: HKCU\...\DeveloperTools\deviceid and
# HKLM\...\SQMClient\MachineId. Returns enough metadata for system_manifest.json
# so restore_system_Qoder_<ts>.ps1 can put the previous value back (or remove the
# value again if this run created it).
function Set-VerifiedRegistryStringValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

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

# Delete stale identity/auth backup files WITHOUT copying them into ID_Backups.
# state.vscdb.backup can contain encrypted auth tokens and old IDs; preserving it
# in the current backup would keep the leak alive, so this is intentionally a
# no-restore delete with verify-after.
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

    # v0.4's before-audit detail (byte size / directory) is kept: a read-only
    # item probe, then the core's sweep-file (delete file-or-tree + re-read
    # verify).
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.PSIsContainer) {
        $before = "directory"
    }
    elseif ($item) {
        $before = "present bytes=$($item.Length)"
    }
    else {
        $before = "present"
    }

    $report = Invoke-GhostCore @("sweep-file", $Path)
    if ($null -ne $report -and $report.ok) {
        Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before $before -After "deleted" -Ok $true
        return $true
    }

    $failAfter = "delete-failed"
    if ($null -ne $report -and $report.error) {
        $failAfter = "delete-failed: " + $report.error
    }
    Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before $before -After $failAfter -Ok $false
    Write-Host "    [FAILED] could not delete stale backup: $Path" -ForegroundColor Red
    return $false
}

# Write NetworkAddress to the adapter's class key, then disable+enable the
# adapter so the driver picks up the new value. Reads back via Get-NetAdapter
# to verify. Returns a hashtable the caller can add to the system manifest.
function Set-AdapterMacAddress {
    param(
        [Parameter(Mandatory = $true)]$Adapter,         # Get-NetAdapter output
        [Parameter(Mandatory = $true)][string]$NewMac,   # 12 hex chars, no separators
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    $name = $Adapter.Name
    $interfaceGuid = $Adapter.InterfaceGuid
    $oldMac = $Adapter.MacAddress                       # e.g. "AA-BB-CC-DD-EE-FF"

    $auditFile = "NetAdapter::$name"
    $auditKey  = "NetworkAddress"

    $classKey = Find-AdapterClassKey -InterfaceGuid $interfaceGuid
    if (-not $classKey) {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After $NewMac -Ok $false
        Write-Host "    [FAILED] no class key found for adapter $name (guid=$interfaceGuid)" -ForegroundColor Red
        return @{ Success = $false; WriteOk = $false; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $null; PreviousExisted = $false; IfIndex = $Adapter.ifIndex }
    }

    # Save whatever was there before (could be empty/missing). The restore
    # script needs BOTH the value and whether it existed: inventing an
    # override for an adapter that never had one leaves a pinned MAC shadowing
    # the burned-in address (BS-7).
    $previousValue = (Get-ItemProperty -LiteralPath $classKey.PSPath -Name "NetworkAddress" -ErrorAction SilentlyContinue).NetworkAddress
    $previousExisted = ($null -ne $previousValue)

    try {
        # 1) Write the new MAC into the registry. NetworkAddress expects 12 hex
        #    chars with no separators.
        Set-ItemProperty -LiteralPath $classKey.PSPath -Name "NetworkAddress" -Value $NewMac -Type String -Force -ErrorAction Stop
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("registry-write-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] could not write NetworkAddress to registry for $name" -ForegroundColor Red
        # Nothing was written: there is nothing to restore for this adapter.
        return @{ Success = $false; WriteOk = $false; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $previousValue; PreviousExisted = $previousExisted; IfIndex = $Adapter.ifIndex }
    }

    # 2) Cycle the adapter so the driver re-reads the registry value. Sleep
    #    gives the PnP manager time to actually down/up the link. -InterfaceIndex
    #    addressing: -Name accepts wildcards and could match the wrong adapter.
    try {
        Disable-NetAdapter -InterfaceIndex $Adapter.ifIndex -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        # Some drivers refuse to disable if the adapter is in use. The
        # registry value is already written; flag partial success.
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("registry-written-disable-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [WARN] registry written but disable failed for $name -- reboot may be required" -ForegroundColor Yellow
        return @{ Success = $false; WriteOk = $true; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $previousValue; PreviousExisted = $previousExisted; IfIndex = $Adapter.ifIndex }
    }

    Start-Sleep -Seconds 3

    try {
        Enable-NetAdapter -InterfaceIndex $Adapter.ifIndex -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("enable-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] enable failed for $name -- network may be down, manual intervention required" -ForegroundColor Red
        return @{ Success = $false; WriteOk = $true; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $previousValue; PreviousExisted = $previousExisted; IfIndex = $Adapter.ifIndex }
    }

    Start-Sleep -Seconds 5

    # 3) Verify by re-reading the live MAC.
    $verified = $null
    try {
        $verified = (Get-NetAdapter -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop).MacAddress
    }
    catch {
        # Adapter may be initializing; one more retry.
        Start-Sleep -Seconds 5
        try {
            $verified = (Get-NetAdapter -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop).MacAddress
        }
        catch {
            $verified = $null
        }
    }

    # Normalize: Get-NetAdapter returns "AA-BB-CC-DD-EE-FF" (uppercase), our
    # NetworkAddress value is "AABBCCDDEEFF" (no separators). Compare by
    # stripping separators from both sides.
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

    return @{ Success = $ok; WriteOk = $true; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $previousValue; PreviousExisted = $previousExisted; IfIndex = $Adapter.ifIndex }
}

# Apply a new hostname via Rename-Computer (no -Restart, so the script
# continues). Verify by reading back the active ComputerName registry value
# because $env:COMPUTERNAME won't reflect the change until the next boot.
function Set-SystemHostname {
    param(
        [Parameter(Mandatory = $true)][string]$NewHostname,
        [Parameter(Mandatory = $true)][string]$OldHostname,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

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

    # Re-read the registry locations to confirm. Verified (reset_qoderwork.ps1
    # Set-VerifiedHostname, 2026-07-09, Windows 11): Rename-Computer updates
    #   - HKLM:\...\ComputerName\ComputerName     <-- the ONLY synchronous key
    # in place; the other three stay old until the kernel swaps them at boot:
    #   - HKLM:\...\Tcpip\Parameters\Hostname     <-- next-boot
    #   - HKLM:\...\ComputerName\ActiveComputerName
    #   - HKLM:\...\Tcpip\Parameters\NV Hostname  (updated by Rename-Computer,
    #                                              swapped at boot)
    # Requiring any of the next-boot trio here produced a false-fail on every
    # run without -Restart.
    $activeComputerName = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue).ComputerName
    $activeTcpipHost    = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Hostname" -ErrorAction SilentlyContinue).Hostname
    $nextBootActive     = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue).ComputerName
    $nextBootNv         = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Hostname" -ErrorAction SilentlyContinue)."NV Hostname"

    $liveOk = ($activeComputerName -eq $NewHostname)
    $nextBootPending = ($activeTcpipHost -ne $NewHostname) -or ($nextBootActive -ne $NewHostname) -or ($nextBootNv -ne $NewHostname)

    $after = "active=$activeComputerName/$activeTcpipHost; nextBoot=$nextBootActive/$nextBootNv"
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

# Generate restore_system_Qoder_<ts>.ps1 in the same backup root. Reads
# system_manifest.json and reverses registry source IDs + NIC MAC + hostname changes.
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
# Restore script for system-level changes made by reset_qoder_windows-v0.4.ps1
# Generated: $Timestamp
#
# This script reverses the registry source ID, NIC MAC, and hostname changes
# from the matching reset run. Run it from an elevated PowerShell prompt. It
# does NOT touch any Qoder application data; that is handled by the file-level
# restore_$App`_$Timestamp.ps1 in the same directory.
#
# Idempotent: re-running after a successful restore is a no-op.
#
# Caveat: rolling the hostname back also needs a Windows restart to take
# effect for live processes (Rename-Computer works the same way as the
# forward direction).

`$ErrorActionPreference = "Stop"

`$manifestJson = @'
$manifestJson
'@

`$manifest = `$manifestJson | ConvertFrom-Json

# --- Registry source IDs ---
if (`$manifest.registry) {
    foreach (`$entry in `$manifest.registry) {
        Write-Host "[RESTORE] registry `$(`$entry.path)\`$(`$entry.name)" -ForegroundColor Cyan
        try {
            if (`$entry.valueExisted) {
                if (-not (Test-Path -LiteralPath `$entry.path)) {
                    New-Item -Path `$entry.path -Force -ErrorAction Stop | Out-Null
                }
                New-ItemProperty -LiteralPath `$entry.path -Name `$entry.name -Value `$entry.old -PropertyType String -Force -ErrorAction Stop | Out-Null
                `$verifiedProps = Get-ItemProperty -LiteralPath `$entry.path -Name `$entry.name -ErrorAction SilentlyContinue
                `$verified = `$null
                if (`$verifiedProps -and `$null -ne `$verifiedProps.PSObject.Properties[`$entry.name]) {
                    `$verified = `$verifiedProps.PSObject.Properties[`$entry.name].Value
                }
                if (`$verified -eq `$entry.old) {
                    Write-Host "    [OK] restored to `$verified" -ForegroundColor Green
                } else {
                    Write-Host "    [WARN] verify mismatch after restore (got=`$verified expected=`$(`$entry.old))" -ForegroundColor Yellow
                }
            }
            else {
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

# --- Hostname ---
if (`$manifest.hostname.old -and (`$manifest.hostname.old -ne `$env:COMPUTERNAME)) {
    Write-Host "[RESTORE] hostname: `$env:COMPUTERNAME -> `$(`$manifest.hostname.old)" -ForegroundColor Cyan
    try {
        Rename-Computer -NewName `$manifest.hostname.old -Force -ErrorAction Stop
        Write-Host "    [OK] hostname registry updated. Restart Windows for live processes to see the new name." -ForegroundColor Green
    } catch {
        Write-Host "    [FAILED] Rename-Computer back to `$(`$manifest.hostname.old) failed: `$(`$_.Exception.Message)" -ForegroundColor Red
    }
} elseif (`$manifest.hostname.old) {
    Write-Host "[SKIP] hostname already restored (current=`$env:COMPUTERNAME, target=`$(`$manifest.hostname.old))" -ForegroundColor Yellow
}

# --- NIC MAC addresses ---
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
    Write-Host "[RESTORE] NIC `$(`$adapter.name) (ifIndex `$(`$adapter.ifIndex))" -ForegroundColor Cyan
    if (-not `$adapter.writeOk) {
        Write-Host "    [SKIP] the reset-time write never landed - nothing to undo" -ForegroundColor DarkGray
        continue
    }
    `$psPath = `$interfaceGuidMap[`$adapter.interfaceGuid.ToLower()]
    if (-not `$psPath) {
        Write-Host "    [FAILED] could not find registry class key for `$(`$adapter.name) (interfaceGuid=`$(`$adapter.interfaceGuid))" -ForegroundColor Red
        continue
    }

    # Restore is an INVERSION of what the reset did (BS-7): an adapter that had
    # NO NetworkAddress override gets the invented one REMOVED (leaving it
    # would pin the reset-time MAC over the burned-in address); an adapter
    # that had one gets exactly its previous value back.
    try {
        if (`$adapter.previousExisted) {
            Set-ItemProperty -LiteralPath `$psPath -Name "NetworkAddress" -Value `$adapter.previousValue -Type String -Force -ErrorAction Stop
        } else {
            Remove-ItemProperty -LiteralPath `$psPath -Name "NetworkAddress" -ErrorAction Stop
        }
    } catch {
        Write-Host "    [FAILED] registry restore failed: `$(`$_.Exception.Message)" -ForegroundColor Red
        continue
    }

    try {
        Disable-NetAdapter -InterfaceIndex `$adapter.ifIndex -Confirm:`$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 3
        Enable-NetAdapter -InterfaceIndex `$adapter.ifIndex -Confirm:`$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 5
    } catch {
        Write-Host "    [WARN] adapter cycle failed (registry may still be correct): `$(`$_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        `$verified = (Get-NetAdapter -InterfaceIndex `$adapter.ifIndex -ErrorAction Stop).MacAddress
        `$normalized = (`$verified -replace '-', '').ToUpper()
        if (`$adapter.previousExisted) {
            `$expected = (([string]`$adapter.previousValue) -replace '-', '').ToUpper()
        } else {
            `$expected = (([string]`$adapter.oldMac) -replace '-', '').ToUpper()
        }
        if (`$normalized -eq `$expected) {
            Write-Host "    [OK] `$(`$adapter.name) MAC restore verified: `$verified" -ForegroundColor Green
        } else {
            Write-Host "    [WARN] `$(`$adapter.name) verify mismatch: got=`$verified expected=`$expected (reboot may be required)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    [WARN] could not verify `$(`$adapter.name): `$(`$_.Exception.Message)" -ForegroundColor Yellow
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

# v0.4 NEW: read-only device-flow probe for [31/31]. Re-opens each profile
# state.vscdb read-only and counts survivors of the exact + LIKE device/auth
# patterns cleared by Clear-QoderSecrets; asserts machine_token.json is absent
# and the rotated .qoder IDs on disk match the values written by [28/31].
# Secrets are NEVER written to the audit log -- only survivor counts and
# truncated (prefix + length) shapes. Any survivor is a FAIL.
function Test-QoderDeviceFlowAbsence {
    param(
        [Parameter(Mandatory = $true)][string[]]$ProfileRoots,
        [Parameter(Mandatory = $true)][string]$MachineTokenPath,
        [Parameter(Mandatory = $true)][string]$QoderInstallationIdPath,
        [Parameter(Mandatory = $true)][string]$ExpectedInstallationId,
        [Parameter(Mandatory = $true)][string]$QoderAuthMachineIdPath,
        [Parameter(Mandatory = $true)][string]$ExpectedAuthMachineId,
        [Parameter(Mandatory = $true)][ref]$Audit
    )

    $probeOk = $true

    # The v0.4 read-only survivor probe (qoder_device_probe heredoc) is now
    # the core's count-keys verb: same read-only reopen, {"survivors": N}
    # contract, no temp script, no mutation, no table creation.
    $probeConfig = @{
        exact_keys    = @(
            "secret://aicoding.auth.userInfo",
            "secret://aicoding.auth.userPlan",
            "secret://aicoding.auth.creditUsage",
            "aicoding.auth.loginBroadcast",
            "gituser"
        )
        like_patterns = @(
            "secret://blackbox.%",
            "secret://aicoding.auth.%",
            "%secret.local.machine.variables%"
        )
        table         = "ItemTable"
    }
    $probeConfigB64 = _B64Payload $probeConfig

    foreach ($pr in $ProfileRoots) {
        $dbPath = Join-Path $pr "User\globalStorage\state.vscdb"
        if (-not (Test-Path -LiteralPath $dbPath)) {
            Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before "missing" -After "skipped" -Ok $true
            continue
        }

        $result = Invoke-GhostCore @("count-keys", $dbPath, $probeConfigB64)
        if ($null -eq $result -or $null -eq $result.survivors) {
            Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before $null -After "core-invoke-failed" -Ok $false
            $probeOk = $false
            continue
        }
        $ok = ($result.survivors -eq 0)
        Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before "scrubbed" -After ("survivors=" + $result.survivors) -Ok $ok
        if (-not $ok) {
            $probeOk = $false
        }
    }

    # machine_token.json (token/id/hostname bundle) must be absent -- steps
    # [5-6/31] deleted it and the watchdog re-deletes recreations.
    if (Test-Path -LiteralPath $MachineTokenPath) {
        Add-AuditEntry -Audit $Audit -File $MachineTokenPath -Key "device-flow-probe" -Before "recreated" -After "still-present" -Ok $false
        $probeOk = $false
    }
    else {
        Add-AuditEntry -Audit $Audit -File $MachineTokenPath -Key "device-flow-probe" -Before "deleted" -After "absent" -Ok $true
    }

    # Rotated .qoder IDs on disk must match the fresh values from [28/31].
    # Only prefix + length shapes are audited, never full values.
    $idChecks = @(
        @{ Path = $QoderInstallationIdPath; Expected = $ExpectedInstallationId },
        @{ Path = $QoderAuthMachineIdPath; Expected = $ExpectedAuthMachineId }
    )
    foreach ($check in $idChecks) {
        if (-not (Test-Path -LiteralPath $check.Path)) {
            Add-AuditEntry -Audit $Audit -File $check.Path -Key "device-flow-probe" -Before "rotated" -After "missing" -Ok $false
            $probeOk = $false
            continue
        }
        $onDisk = (Get-Content -LiteralPath $check.Path -Raw).Trim()
        $shape = "len=" + $onDisk.Length
        if ($onDisk -eq $check.Expected) {
            Add-AuditEntry -Audit $Audit -File $check.Path -Key "device-flow-probe" -Before "rotated" -After ("match " + $shape) -Ok $true
        }
        else {
            Add-AuditEntry -Audit $Audit -File $check.Path -Key "device-flow-probe" -Before "rotated" -After ("mismatch " + $shape) -Ok $false
            $probeOk = $false
        }
    }

    return $probeOk
}

Assert-Administrator

$app = "Qoder"
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$root = Join-Path $env:APPDATA $app
$backupRoot = Join-Path $root ("ID_Backups\" + $timestamp)
$idBackupsRoot = Join-Path $root "ID_Backups"
$userQoderRoot = Join-Path $env:USERPROFILE ".qoder"

# Profile roots: main + CORS_Profile (if present)
$profileRoots = @(Get-QoderProfileRoots -MainRoot $root)

if (-not (Test-Path -LiteralPath $root)) {
    Write-Host "Qoder installation not found at: $root" -ForegroundColor Red
    exit 1
}

# v0.5: the core must be present and a functional Python 3 with it - fail
# fast BEFORE touching anything (v0.4 needed Python only for the SQLite
# steps; v0.5 routes every store mutation through the core).
if ((-not (Get-GhostPythonCli)) -or (-not (Get-PythonCommandInfo))) {
    Write-Host "[FAILED] GHOST Python core (src\python\ghost_cli.py) missing or no functional Python 3 found - every Qoder reset step needs it (winget install Python.Python.3.12)." -ForegroundColor Red
    exit 1
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Qoder Identity Reset (v0.5) ===" -ForegroundColor Cyan
Write-Host "Root: $root" -ForegroundColor Gray
Write-Host ("Profiles: " + (($profileRoots | ForEach-Object { Get-ProfileLabel -MainRoot $root -ProfileRoot $_ }) -join ", ")) -ForegroundColor Gray
Write-Host "User-level: $userQoderRoot" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray

# Pre-step: aggressive tree-kill. Hard-fails the run if unkillable.
if (-not (Stop-QoderProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$audit = @()
$actions = @()
$ids = New-IdentitySet

# Qoder-specific client device IDs (distinct from VS Code telemetry IDs).
# (The Preferences salt is no longer PS-generated: the core's salt-rotate
# generates a fresh 32-lowercase-hex salt PER PROFILE -- v0.4 shared one
# uppercase GUID-N salt across profiles.)
$clientDeviceId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newCrashReporterId = ([guid]::NewGuid().ToString()).ToLowerInvariant()

# --- [1/31] machineid (per profile) ---
Write-Host "`n[1/31] Updating machineid (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "machineid"
    if (Set-VerifiedMachineIdFile -Path $path -Value $ids.devDeviceId -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
        Write-Host "    [$label] [OK] machineid verified" -ForegroundColor Green
    } else {
        Write-Host "    [$label] [FAILED] machineid verification failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [2/31] storage.json telemetry keys (per profile) ---
Write-Host "`n[2/31] Updating storage.json telemetry keys (per profile)..." -ForegroundColor Cyan
$storageUpdates = @{
    "telemetry.machineId"    = $ids.machineId
    "telemetry.macMachineId" = $ids.macMachineId
    "telemetry.sqmId"        = $ids.sqmId
    "telemetry.devDeviceId"  = $ids.devDeviceId
}
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "User\globalStorage\storage.json"
    # Core: backup + json-patch (Set-JsonIdentity's backup+patch+verify
    # contract split across the core verbs).
    $null = Backup-ViaCore -Source $path -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Actions ([ref]$actions)
    $storageReport = Invoke-GhostCore @("json-patch", $path, (_B64Payload $storageUpdates))
    if ($null -ne $storageReport -and $storageReport.ok) {
        foreach ($key in $storageUpdates.Keys) {
            Add-AuditEntry -Audit ([ref]$audit) -File $path -Key $key -Before $storageReport.before.$key -After $storageReport.after.$key -Ok $true
        }
        Write-Host "    [$label] [OK] storage.json verified" -ForegroundColor Green
    } else {
        foreach ($key in $storageUpdates.Keys) {
            Add-AuditEntry -Audit ([ref]$audit) -File $path -Key $key -Before $null -After $storageUpdates[$key] -Ok $false
        }
        Write-Host "    [$label] [FAILED] storage.json verification failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [3/31] state.vscdb serviceMachineId (per profile; core: sqlite-update) ---
Write-Host "`n[3/31] Updating global state.vscdb serviceMachineId (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "User\globalStorage\state.vscdb"
    if (-not (Test-Path -LiteralPath $path)) {
        # sqlite-update would CREATE a missing DB (sqlite3.connect + CREATE
        # TABLE IF NOT EXISTS); fail loudly instead of silently minting a
        # fresh 1-row DB on a broken profile (reset_cursor v0.3 guard).
        Add-AuditEntry -Audit ([ref]$audit) -File $path -Key "storage.serviceMachineId" -Before "missing" -After "not-found" -Ok $false
        Write-Host "    [$label] [FAILED] state.vscdb not found: $path" -ForegroundColor Red
        $stepFailed = $true
        continue
    }
    $null = Backup-ViaCore -Source $path -BackupRoot $backupRoot -Label (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Actions ([ref]$actions)
    $svReport = Invoke-GhostCore @("sqlite-update", $path, (_B64Payload @{ "storage.serviceMachineId" = $ids.devDeviceId }))
    if ($null -ne $svReport -and $null -ne $svReport.after -and ($svReport.after."storage.serviceMachineId" -eq $ids.devDeviceId)) {
        Add-AuditEntry -Audit ([ref]$audit) -File $path -Key "storage.serviceMachineId" -Before $svReport.before."storage.serviceMachineId" -After $svReport.after."storage.serviceMachineId" -Ok $true
        Write-Host "    [$label] [OK] state.vscdb serviceMachineId verified" -ForegroundColor Green
    } else {
        Add-AuditEntry -Audit ([ref]$audit) -File $path -Key "storage.serviceMachineId" -Before $null -After $ids.devDeviceId -Ok $false
        Write-Host "    [$label] [FAILED] state.vscdb serviceMachineId failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [3b/31] state.vscdb secrets scrub (per profile) ---
Write-Host "`n[3b/31] Scrubbing state.vscdb auth secrets (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "User\globalStorage\state.vscdb"
    if (Clear-QoderSecrets -DbPath $path -Audit ([ref]$audit)) {
        Write-Host "    [$label] [OK] auth secrets scrubbed" -ForegroundColor Green
    } else {
        Write-Host "    [$label] [FAILED] auth secret scrub failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [4/31] SharedClientCache\cache\id (MAIN ONLY - CORS_Profile has no SharedClientCache) ---
$cacheDir = Join-Path $root "SharedClientCache\cache"
$clientIdPath = Join-Path $cacheDir "id"
Write-Host "`n[4/31] Updating SharedClientCache\cache\id (main only)..." -ForegroundColor Cyan
if (Set-VerifiedMachineIdFile -Path $clientIdPath -Value $clientDeviceId -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $root -TargetPath $clientIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [main] [OK] client device ID verified" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [main] [FAILED] client device ID verification failed" -ForegroundColor Red
    $failCount++
}

# --- [5/31] SharedClientCache\cache auth files (MAIN ONLY) ---
$machineTokenPath = Join-Path $cacheDir "machine_token.json"
$statusPath = Join-Path $cacheDir "status.json"
$quotaPath = Join-Path $cacheDir "quota"
$localDbPath = Join-Path $cacheDir "db\local.db"
$localDbShmPath = Join-Path $cacheDir "db\local.db-shm"
$localDbWalPath = Join-Path $cacheDir "db\local.db-wal"
Write-Host "`n[5/31] Deleting SharedClientCache\cache auth files after backup (machine_token, status, quota, local.db)..." -ForegroundColor Cyan
$step5AuditStart = $audit.Count
$binaryActions = Invoke-StoreDelete -Paths @($machineTokenPath, $statusPath, $quotaPath, $localDbPath, $localDbShmPath, $localDbWalPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
$actions += @($binaryActions)
$step5Status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step5AuditStart -Path (Join-Path $root "SharedClientCache")
if ($step5Status.Success) {
    Write-Host "    [OK] auth files deleted" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [PARTIAL] some auth files remained locked" -ForegroundColor Yellow
    $failCount++
}

# --- [6/31] Whole SharedClientCache tree (MAIN ONLY) ---
Write-Host "`n[6/31] Deleting entire SharedClientCache tree (main only)..." -ForegroundColor Cyan
$step6AuditStart = $audit.Count
$binaryActions = Invoke-StoreDelete -Paths @((Join-Path $root "SharedClientCache")) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
$actions += @($binaryActions)
$step6Status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step6AuditStart -Path (Join-Path $root "SharedClientCache")
if ($step6Status.Success) {
    Write-Host "    [OK] SharedClientCache tree deleted" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [PARTIAL] some SharedClientCache files remained" -ForegroundColor Yellow
    $failCount++
}

# --- [7/31] Local State (per profile) ---
Write-Host "`n[7/31] Deleting Local State (Chromium os_crypt key) (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "Local State"
    $step7AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths @($path) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    if ((Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step7AuditStart -Path $path).Success) {
        Write-Host "    [$label] [OK] Local State" -ForegroundColor Green
    } else {
        Write-Host "    [$label] [PARTIAL] Local State (some entries failed)" -ForegroundColor Yellow
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [8/31] Cookies + Network PS + Trust Tokens (per profile) ---
Write-Host "`n[8/31] Deleting Cookies + Network Persistent State + Trust Tokens (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @(
        (Join-Path $pr "Network\Cookies"),
        (Join-Path $pr "Network\Network Persistent State"),
        (Join-Path $pr "Network\Trust Tokens")
    )
    $step8AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step8AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] Network stores (some entries failed)" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] Network stores" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [9/31] DIPS (+ -wal) (per profile) ---
Write-Host "`n[9/31] Deleting DIPS stores (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "DIPS"), (Join-Path $pr "DIPS-wal"))
    $step9AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step9AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] DIPS" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] DIPS" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [10/31] SharedStorage (+ -wal) (per profile) ---
Write-Host "`n[10/31] Deleting SharedStorage (+ -wal) (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "SharedStorage"), (Join-Path $pr "SharedStorage-wal"))
    $step10AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step10AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] SharedStorage" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] SharedStorage" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [11/31] WebStorage (per profile) ---
Write-Host "`n[11/31] Deleting WebStorage (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "WebStorage"
    $step11AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths @($path) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    if ((Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step11AuditStart -Path $path).Success) {
        Write-Host "    [$label] [OK] WebStorage" -ForegroundColor Green
    } else {
        Write-Host "    [$label] [PARTIAL] WebStorage" -ForegroundColor Yellow
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [12/31] Session Storage + Local Storage (per profile) ---
Write-Host "`n[12/31] Deleting Session Storage + Local Storage (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Session Storage"), (Join-Path $pr "Local Storage"))
    $step12AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step12AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] Session/Local Storage" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] Session/Local Storage" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [13/31] Cache + Code Cache + GPUCache (per profile) ---
Write-Host "`n[13/31] Deleting Cache + Code Cache + GPUCache (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Cache"), (Join-Path $pr "Code Cache"), (Join-Path $pr "GPUCache"))
    $step13AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step13AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] Cache stores" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] Cache stores" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [14/31] Service Worker + blob_storage (per profile) ---
Write-Host "`n[14/31] Deleting Service Worker + blob_storage (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Service Worker"), (Join-Path $pr "blob_storage"))
    $step14AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step14AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] Service Worker/blob_storage" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] Service Worker/blob_storage" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [15/31] Crashpad + CrashFeedback (per profile) ---
Write-Host "`n[15/31] Deleting Crashpad + CrashFeedback (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Crashpad"), (Join-Path $pr "CrashFeedback"))
    $step15AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step15AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] Crashpad/CrashFeedback" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] Crashpad/CrashFeedback" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [16/31] Preferences device_id_salt (per profile) ---
Write-Host "`n[16/31] Updating Preferences device_id_salt (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "Preferences"
    if (Update-QoderPreferences -Path $path -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
        Write-Host "    [$label] [OK] Preferences device_id_salt verified" -ForegroundColor Green
    } else {
        Write-Host "    [$label] [FAILED] Preferences device_id_salt verification failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [17/31] workspace state.vscdb files (per profile) ---
Write-Host "`n[17/31] Updating workspace state.vscdb files (per profile)..." -ForegroundColor Cyan
$workspaceFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
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

    $localWorkspaceFailures = 0
    foreach ($workspaceDbPath in $workspaceDbPaths) {
        Invoke-WorkspaceSqliteUpdate -WorkspaceDbPath $workspaceDbPath -DeviceId $ids.devDeviceId -RootPath $pr -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
        $lastAuditEntry = $audit[-1]
        if (-not $lastAuditEntry.ok) {
            $localWorkspaceFailures++
        }
    }

    if ($localWorkspaceFailures -gt 0) {
        $workspaceFailed = $true
    }
}
if ($workspaceFailed) { $failCount++ } else { $passCount++ }

# --- [18/31] logs/ deletion (per profile) ---
# main.log embeds the update-check URL with machineId=...&umid=<token> verbatim.
# v0.1 never deleted logs/; this step removes the full session history.
Write-Host "`n[18/31] Deleting logs/ (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "logs"
    $step18AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths @($path) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step18AuditStart -Path $path).Success) {
        Write-Host "    [$label] [PARTIAL] logs" -ForegroundColor Yellow
        $stepFailed = $true
    } else {
        Write-Host "    [$label] [OK] logs" -ForegroundColor Green
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [19/31] argv.json crash-reporter-id (user-level) ---
Write-Host "`n[19/31] Updating argv.json crash-reporter-id (user-level)..." -ForegroundColor Cyan
$argvPath = Join-Path $userQoderRoot "argv.json"
$argvBackupLabel = Get-UserProfileBackupLabel -TargetPath $argvPath
if (Update-QoderArgvJson -Path $argvPath -NewCrashReporterId $newCrashReporterId -BackupRoot $backupRoot -BackupLabel $argvBackupLabel -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] argv.json crash-reporter-id verified" -ForegroundColor Green
    $passCount++
} else {
    Write-Host "    [FAILED] argv.json crash-reporter-id verification failed" -ForegroundColor Red
    $failCount++
}

# --- [20/31] %USERPROFILE%\.qoder\ subdir cleanup ---
# memories/ embeds per-project filesystem paths (e.g. "c-programming-Python-Projects-first_heart")
# plus per-user AI context (user_info, user_behavior, user_hobby, history_task_reference_files).
# canvas/, knowledges/, cache/, session-env/, plugins/ hold AI state.
# extensions/ may be a reparse point on older installs or a real bundled
# extensions directory on current builds. Remove-QoderPathSafely removes only
# the link when it is a reparse point, and deletes the real Qoder-owned directory
# otherwise, so VS Code's extensions folder is NOT touched.
Write-Host "`n[20/31] Deleting %USERPROFILE%\.qoder\ subdirs (memories/canvas/knowledges/cache/session-env/extensions/plugins)..." -ForegroundColor Cyan
$userSubdirs = @("memories", "canvas", "knowledges", "cache", "session-env", "extensions", "plugins")
$step20Failed = $false
foreach ($subdir in $userSubdirs) {
    $path = Join-Path $userQoderRoot $subdir
    $result = Remove-QoderPathSafely -Path $path -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
    if ($result -eq "missing") {
        Write-Host "    [SKIP] $subdir (not present)" -ForegroundColor DarkGray
    } elseif ($result -eq "link-removed") {
        Write-Host "    [OK] $subdir (symlink removed; target untouched)" -ForegroundColor Green
    } elseif ($result -eq "delete-failed") {
        Write-Host "    [FAILED] $subdir (locked? see audit)" -ForegroundColor Red
        $step20Failed = $true
    } else {
        Write-Host "    [OK] $subdir" -ForegroundColor Green
    }
}
if ($step20Failed) { $failCount++ } else { $passCount++ }

# --- [21/31] Old ID_Backups purge (current run kept, same-day runs protected) ---
Write-Host "`n[21/31] Purging old ID_Backups directories (older than 24h only)..." -ForegroundColor Cyan
$purgeAuditStart = $audit.Count
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
# BS-7: the purge audits every delete with ok=$false when a dir survived; the
# old unconditional passCount++ turned those into a green step.
$purgeFailures = @($audit | Select-Object -Skip $purgeAuditStart |
    Where-Object { ($_.key -eq "id-backups-purge") -and (-not $_.ok) }).Count
if ($purgeFailures -gt 0) {
    Write-Host "[FAILED] purge had $purgeFailures failure(s) (locked dirs stay on disk)" -ForegroundColor Red
    $failCount++
} else {
    $passCount++
}

# --- [22/31] Post-write watchdog re-verify ---
Write-Host "`n[22/31] Post-write watchdog re-verify..." -ForegroundColor Cyan
$watchdogCoreFiles = @($machineTokenPath, $statusPath, $localDbPath)
$watchdogOk = Test-QoderWatchdogRecreation -CoreFiles $watchdogCoreFiles -BackupRoot $backupRoot -Audit ([ref]$audit)
if ($watchdogOk) { $passCount++ } else { $failCount++ }

# === v0.3 NEW: REGISTRY SOURCE + SYSTEM-LEVEL STEPS ==========================
# These steps run AFTER the Qoder file reset completes, so Qoder is already
# stopped and file verification doesn't see a mid-cycle adapter. They close the
# remaining leaks v0.3 originally missed:
#   - HKCU DeveloperTools deviceid: native addon source for machineid
#   - HKLM SQMClient MachineId: source for telemetry.sqmId
#   - state.vscdb.backup: stale encrypted auth/session backup
#   - NIC MAC + hostname: defense-in-depth system identifiers
# MAC + hostname are opt-out via -SkipMac / -SkipHostname. Failures here are
# recorded in the audit log but do NOT abort the earlier Qoder file reset.

$systemManifest = @{
    hostname = @{ old = $env:COMPUTERNAME; new = $null }
    adapters = @()
    registry = @()
}

# --- [23/31] HKCU DeveloperTools deviceid source ---
Write-Host "`n[23/31] Updating HKCU DeveloperTools deviceid source..." -ForegroundColor Cyan
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

# --- [24/31] HKLM SQMClient MachineId source ---
Write-Host "`n[24/31] Updating HKLM SQMClient MachineId source..." -ForegroundColor Cyan
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

# --- [25/31] state.vscdb.backup stale auth/session backups ---
Write-Host "`n[25/31] Deleting stale state.vscdb.backup files (no backup copy)..." -ForegroundColor Cyan
$step25Failed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $globalStoragePath = Join-Path $pr "User\globalStorage"
    $staleBackupPaths = @(
        (Join-Path $globalStoragePath "state.vscdb.backup"),
        (Join-Path $globalStoragePath "state.vscdb.backup-shm"),
        (Join-Path $globalStoragePath "state.vscdb.backup-wal")
    )

    $profileFailed = $false
    foreach ($stalePath in $staleBackupPaths) {
        if (-not (Remove-VerifiedFileNoBackup -Path $stalePath -AuditKey "stale-state-backup" -Audit ([ref]$audit))) {
            $profileFailed = $true
        }
    }

    if ($profileFailed) {
        Write-Host "    [$label] [FAILED] stale state.vscdb backup cleanup" -ForegroundColor Red
        $step25Failed = $true
    }
    else {
        Write-Host "    [$label] [OK] stale state.vscdb backups absent/deleted" -ForegroundColor Green
    }
}
if ($step25Failed) { $failCount++ } else { $passCount++ }

# --- [26/31] NIC MAC address rotation (physical adapters only) ---
if ($SkipMac) {
    Write-Host "`n[26/31] SKIPPED (-SkipMac) -- NIC MAC addresses left unchanged" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File "NetAdapter::all" -Key "NetworkAddress" -Before "skipped" -After "skipped-by-user" -Ok $true
}
else {
    Write-Host "`n[26/31] Rotating NIC MAC addresses (physical adapters only)..." -ForegroundColor Cyan
    $physicalAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })

    if ($physicalAdapters.Count -eq 0) {
        Write-Host "    [WARN] no physical, Up adapters found -- nothing to do" -ForegroundColor Yellow
        Add-AuditEntry -Audit ([ref]$audit) -File "NetAdapter::all" -Key "NetworkAddress" -Before "none" -After "no-adapters" -Ok $true
    }
    else {
        $step26Failed = $false
        foreach ($adapter in $physicalAdapters) {
            # Skip the loopback and any other weirdness.
            if ($adapter.Name -match '^Loopback') { continue }
            $newMac = New-RandomMacAddress
            $result = Set-AdapterMacAddress -Adapter $adapter -NewMac $newMac -Audit ([ref]$audit)
            if (-not $result.Success) {
                $step26Failed = $true
            }
            # Record the entry ONLY when the registry write actually landed: a
            # failed write has nothing to undo, and the restore script used to
            # invent an override for it. The previous NetworkAddress state
            # (value + whether it existed) makes the restore a true inversion.
            if ($result.WriteOk) {
                $systemManifest.adapters += @{
                    name             = $adapter.Name
                    interfaceGuid    = $adapter.InterfaceGuid
                    ifIndex          = $result.IfIndex
                    oldMac           = $result.OldMac
                    newMac           = $result.NewMac
                    previousValue    = $result.PreviousValue
                    previousExisted  = $result.PreviousExisted
                    writeOk          = $result.WriteOk
                }
            }
        }
        if ($step26Failed) { $failCount++ } else { $passCount++ }
    }
}

# --- [27/31] Hostname change ---
if ($SkipHostname) {
    Write-Host "`n[27/31] SKIPPED (-SkipHostname) -- hostname left unchanged" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName" -Key "ComputerName" -Before "skipped" -After "skipped-by-user" -Ok $true
}
else {
    Write-Host "`n[27/31] Changing hostname (registry-only, restart required for live processes)..." -ForegroundColor Cyan
    $newHostname = New-RandomHostname
    Write-Host "    old: $env:COMPUTERNAME -> new: $newHostname" -ForegroundColor Gray
    if (Set-SystemHostname -NewHostname $newHostname -OldHostname $env:COMPUTERNAME -Audit ([ref]$audit)) {
        $systemManifest.hostname.new = $newHostname
        $passCount++
    }
    else {
        $systemManifest.hostname.new = $null
        $failCount++
    }
}

# --- Persist system manifest + generate system restore script ---
$systemManifestPath = Join-Path $backupRoot "system_manifest.json"
# No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1). system_manifest.json
# is read back by the restore script; emitting a BOM corrupts ConvertFrom-Json.
[System.IO.File]::WriteAllText($systemManifestPath, ($systemManifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))
Add-AuditEntry -Audit ([ref]$audit) -File $systemManifestPath -Key "system-manifest" -Before "none" -After "saved" -Ok $true
Write-Host ""
Write-Host "[*] System manifest saved: $systemManifestPath" -ForegroundColor Gray

# Always generate the system restore script, even if both steps were skipped or
# failed -- the script just becomes a no-op for the empty bits.
$systemRestoreScriptPath = New-SystemRestoreScript -BackupRoot $backupRoot -App $app -Manifest $systemManifest -Timestamp $timestamp
Write-Host "[*] System restore script: $systemRestoreScriptPath" -ForegroundColor Gray

# === END v0.3 SYSTEM-LEVEL + v0.4 DEVICE-FLOW STEPS (marker) ===============
# (The v0.4 device-flow steps below run after the system steps on purpose:
# they are local-only file operations, so the MAC/hostname cycle above cannot
# disturb them, and the device-flow probe in [31/31] sees the final state.)

# --- [28/31] %USERPROFILE%\.qoder device files ---
# installation_id + .auth\machine_id are both 36B GUIDs (verified live
# 2026-09-15) that v0.3 never touched. Rotate to fresh lowercase GUIDs with
# verify-after; delete the credential-transaction sentinel + dns/endpoint
# caches with backup-first. Static assets (dynamic-error-codes/texts.json),
# settings/mcp/argv, and user content (projects/memory/skills) are left alone.
Write-Host "`n[28/31] Rotating %USERPROFILE%\.qoder device files (installation_id, .auth\machine_id)..." -ForegroundColor Cyan
$step28Failed = $false
$newQoderInstallationId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newQoderAuthMachineId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$qoderInstallationIdPath = Join-Path $userQoderRoot "installation_id"
$qoderAuthMachineIdPath = Join-Path $userQoderRoot ".auth\machine_id"
if (Set-VerifiedMachineIdFile -Path $qoderInstallationIdPath -Value $newQoderInstallationId -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $qoderInstallationIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] installation_id verified" -ForegroundColor Green
}
else {
    Write-Host "    [FAILED] installation_id verification failed" -ForegroundColor Red
    $step28Failed = $true
}
if (Set-VerifiedMachineIdFile -Path $qoderAuthMachineIdPath -Value $newQoderAuthMachineId -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $qoderAuthMachineIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    Write-Host "    [OK] .auth\machine_id verified" -ForegroundColor Green
}
else {
    Write-Host "    [FAILED] .auth\machine_id verification failed" -ForegroundColor Red
    $step28Failed = $true
}
$step28AuditStart = $audit.Count
$qoderCacheFiles = @(
    (Join-Path $userQoderRoot ".auth\.credential-transaction"),
    (Join-Path $userQoderRoot ".cache\dns-cache.json"),
    (Join-Path $userQoderRoot ".cache\endpoint-cache.json")
)
$binaryActions = Invoke-StoreDelete -Paths $qoderCacheFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
$actions += @($binaryActions)
foreach ($p in $qoderCacheFiles) {
    if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step28AuditStart -Path $p).Success) { $step28Failed = $true; break }
}
if ($step28Failed) { $failCount++ } else { $passCount++ }

# --- [29/31] Webview Chromium stores (per profile, if-present) ---
# IndexedDB/Partitions/Storage are absent on a fresh profile (verified
# 2026-09-15) but the /device/selectAccounts webview creates them at login.
# Delete-if-present with backup-first so a login-time webview cache can never
# carry the banned device state into the fresh profile.
Write-Host "`n[29/31] Deleting webview Chromium stores (IndexedDB/Partitions/Storage) (per profile)..." -ForegroundColor Cyan
$step29Failed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "IndexedDB"), (Join-Path $pr "Partitions"), (Join-Path $pr "Storage"))
    $step29AuditStart = $audit.Count
    $binaryActions = Invoke-StoreDelete -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    $anyFail = $false
    foreach ($p in $paths) {
        if (-not (Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step29AuditStart -Path $p).Success) { $anyFail = $true; break }
    }
    if ($anyFail) {
        Write-Host "    [$label] [PARTIAL] webview stores (some entries failed)" -ForegroundColor Yellow
        $step29Failed = $true
    }
    else {
        Write-Host "    [$label] [OK] webview stores (absent/deleted)" -ForegroundColor Green
    }
}
if ($step29Failed) { $failCount++ } else { $passCount++ }

# --- [30/31] .qoder CLI run state (tmp/telemetry + logs) ---
# .qoder\tmp\telemetry\active-runs + .qoder\logs\runs embed host/run IDs per
# CLI invocation. Per-FILE backup-first delete via the sweep-tree core twin
# (Clear-TreeFilesIndividually) - one locked log must not leave 99% of the
# tree on disk (the header promise is now real; steps [13]-[18] keep the
# whole-path store-delete by choice: small cache dirs, honest unit failures).
# Chat-bearing stores (SharedClientCache\db\local.db chat tables, memories/,
# canvas/, knowledges/, projects/) are never touched by this step.
Write-Host "`n[30/31] Deleting .qoder CLI run state (tmp/telemetry, logs)..." -ForegroundColor Cyan
$step30Failed = $false
$qoderRunTrees = @((Join-Path $userQoderRoot "tmp\telemetry"), (Join-Path $userQoderRoot "logs"))
foreach ($tree in $qoderRunTrees) {
    # BS-7 HIGH: these are the big run-manifest/log trees the per-file helper
    # was built for - one locked log must not leave 99% of the tree on disk
    # (the whole-tree delete fails FAST on the first lock). Steps [13]-[18]
    # deliberately stay on whole-path store-delete: small cache dirs whose
    # unit failure is honestly audited + counted.
    $sweep = Clear-TreeFilesIndividually -Path $tree -BackupRoot $backupRoot -BackupLabel (Split-Path -Leaf $tree) -Audit ([ref]$audit)
    if ($sweep.BackedUpTo) {
        $actions += @([ordered]@{
            action       = "delete"
            originalPath = $tree
            backupPath   = $sweep.BackedUpTo
            renamedPath  = $null
        })
    }
    if ($sweep.Failed -eq 0) {
        Write-Host ("    [OK] {0} (deleted {1} file(s))" -f $tree, $sweep.Deleted) -ForegroundColor Green
    }
    else {
        Write-Host ("    [PARTIAL] {0} (deleted {1}, failed {2} - see audit)" -f $tree, $sweep.Deleted, $sweep.Failed) -ForegroundColor Yellow
        $step30Failed = $true
    }
}
if ($step30Failed) { $failCount++ } else { $passCount++ }

# --- [31/31] Device-flow final probe (read-only, audited) ---
# Fails the run if any device/auth secret survived the scrub, if
# machine_token.json came back, or if the rotated .qoder IDs on disk drifted
# from the values written in [28/31]. Never silent-success.
Write-Host "`n[31/31] Probing device-flow absence (state.vscdb survivors, machine_token, .qoder IDs)..." -ForegroundColor Cyan
if (Test-QoderDeviceFlowAbsence -ProfileRoots $profileRoots -MachineTokenPath $machineTokenPath -QoderInstallationIdPath $qoderInstallationIdPath -ExpectedInstallationId $newQoderInstallationId -QoderAuthMachineIdPath $qoderAuthMachineIdPath -ExpectedAuthMachineId $newQoderAuthMachineId -Audit ([ref]$audit)) {
    Write-Host "    [OK] device-flow probe passed (zero survivors)" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "    [FAILED] device-flow probe found survivors (see audit)" -ForegroundColor Red
    $failCount++
}

# === END v0.3 SYSTEM-LEVEL + v0.4 DEVICE-FLOW STEPS ======================

# --- Audit + restore + summary ---
$auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
Write-AuditLog -Audit $audit -Path $auditPath
$restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App $app -Actions $actions

# Final verify probes on both profiles' storage.json + state.vscdb
$finalJsonOk = $true
$finalSqliteOk = $true
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $storagePath = Join-Path $pr "User\globalStorage\storage.json"
    $sqlitePath = Join-Path $pr "User\globalStorage\state.vscdb"

    $jsonOk = Confirm-JsonValues -Path $storagePath -Expected $storageUpdates
    if ($jsonOk) {
        Write-Host "[OK] final storage.json probe passed ($label)" -ForegroundColor Green
    } else {
        Write-Host "[FAILED] final storage.json probe failed ($label)" -ForegroundColor Red
        $finalJsonOk = $false
    }

    # BS-7: re-assert the value the run wrote (idempotent) instead of replaying
    # step [3]'s audit entries - the replay verified nothing about the CURRENT
    # file (a post-run recreation with the old id passed). The re-assert both
    # detects it (ok=false) and heals it. Missing DB file = honest FAILED (the
    # re-assert must never CREATE a store the reset left behind).
    $sqliteOk = $false
    if (Test-Path -LiteralPath $sqlitePath) {
        $fpReport = Invoke-GhostCore @("sqlite-update", $sqlitePath, (_B64Payload @{ "storage.serviceMachineId" = $ids.devDeviceId }))
        $sqliteOk = ($null -ne $fpReport -and $null -ne $fpReport.ok -and $fpReport.ok)
    }
    if ($sqliteOk) {
        Write-Host "[OK] final state.vscdb probe passed ($label)" -ForegroundColor Green
    } else {
        Write-Host "[FAILED] final state.vscdb probe failed ($label)" -ForegroundColor Red
        $finalSqliteOk = $false
    }
}

if (-not $finalJsonOk) { $failCount++ }
if (-not $finalSqliteOk) { $failCount++ }

if (-not (Test-Path -LiteralPath $restoreScriptPath) -or ((Get-Item -LiteralPath $restoreScriptPath).Length -le 0)) {
    Write-Host "[FAILED] restore script missing or empty" -ForegroundColor Red
    $failCount++
}

# Surface any per-file failures captured in the audit (e.g. logs/ tree where
# some files were still locked by an extension host after the retry budget).
# These don't abort the script but they DO matter for the identity-reset goal -- if logs
# leaked, the token+machineId URL is still on disk.
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
    Write-Host ">>> (the registry is already updated; \$env:COMPUTERNAME in any current shell is stale until reboot) <<<" -ForegroundColor Magenta
}

$qoderDoneMarker = "$env:TEMP\qoder_v0.5_done.txt"
$summaryLines = @(
    "PASS=$passCount",
    "FAIL=$failCount",
    "AUDIT=$auditPath",
    "RESTORE_FILES=$restoreScriptPath",
    "RESTORE_SYSTEM=$systemRestoreScriptPath",
    "SYSTEM_MANIFEST=$systemManifestPath",
    "HOSTNAME_PENDING_RESTART=$(if ($SkipHostname) { 'skipped' } else { 'yes' })"
)
# No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1). The done-marker is
# a key=value text file; emitting a BOM trips parsers that expect ASCII at byte 0.
[System.IO.File]::WriteAllText($qoderDoneMarker, ($summaryLines -join "`n"), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host ""
    Write-Host "Qoder reset completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Qoder reset completed successfully." -ForegroundColor Green
if (-not $SkipHostname) {
    Write-Host "Remember to RESTART WINDOWS for the new hostname to take effect." -ForegroundColor Yellow
}