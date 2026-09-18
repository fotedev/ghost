param(
    # v0.4 keeps the v0.3 opt-out switches for the system-level steps.
    # Default = ON (i.e., do them). Use -SkipMac / -SkipHostname to suppress.
    # Note: NO [CmdletBinding()] -- the v0.2 launch pattern uses
    # `cmd /c powershell -File <script> *> <log>`, and [CmdletBinding()] makes
    # the `*` in `*>` bind as a positional argument (the script rejects it).
    # Plain param() is fine here; switches work without CmdletBinding.
    [switch]$SkipMac,
    [switch]$SkipHostname
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# Self-elevate if not already admin. Re-launch with the same switches so the
# elevated copy sees the user's opt-out choices.
$qoderIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $qoderIsAdmin) {
    $qoderLogOut = "$env:TEMP\qoder_v0.4_result.log"
    $qoderScript = $MyInvocation.MyCommand.Path
    $qoderSwitchList = @()
    if ($SkipMac)      { $qoderSwitchList += "-SkipMac" }
    if ($SkipHostname) { $qoderSwitchList += "-SkipHostname" }
    $qoderSwitchString = if ($qoderSwitchList.Count -gt 0) { " " + ($qoderSwitchList -join " ") } else { "" }
    # Single-string argument list, same proven pattern as v0.2 -- avoids any
    # array-join quoting surprises with paths that contain spaces.
    $qoderArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$qoderScript`"$qoderSwitchString *> `"$qoderLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $qoderArgs -WindowStyle Normal -Wait
    if (Test-Path $qoderLogOut) {
        Get-Content $qoderLogOut
    }
    if (Test-Path "$env:TEMP\qoder_v0.4_done.txt") {
        Get-Content "$env:TEMP\qoder_v0.4_done.txt"
    }
    exit
}

# Qoder v0.4 -- comprehensive identity reset + system-level defenses + device-flow purge.
#
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
#     - Calls Rename-Computer -NewName "WIN-<8hex>" -Force (no -Restart, so the script
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

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:63). Set-Content
    # with -Encoding UTF8 emits a BOM under PowerShell 5.1, which corrupts the
    # JSON parsers in Qoder and falls back to the old machineid.
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

# Qoder Preferences is a Chromium JSON file with a nested
# electron.media.device_id_salt key. Sets it to a fresh uppercase GUID (N-format,
# no dashes) and verifies after re-read.
function Update-QoderPreferences {
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

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $null -After $null -Ok $false
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

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:384). Set-Content
    # with -Encoding UTF8 emits a BOM under PS 5.1, which Chromium's Preferences
    # parser rejects and falls back to the old device_id_salt.
    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "device_id_salt" -Before $beforeValue -After $null -Ok $false
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
                $null = & taskkill /F /T /IM "$processName.exe" 2>&1
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
# ItemTable leak the account email. Set-SqliteKeys only UPSERTs -- never deletes.
# This DELETEs and verifies the survivors are zero via read-only reopen.
# Uses Python with parameterized ? placeholders. The caller already backed up
# state.vscdb via Set-SqliteKeys (Backup-FileToTimestampDir uses -Force, so
# re-backing here would clobber the pristine copy).
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

    $pythonCommand = Get-PythonCommandInfo
    if (-not $pythonCommand) {
        foreach ($key in ($exactKeys + $likePatterns)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "python-missing" -Ok $false
        }
        Write-Host "    [FAILED] Python not found - cannot scrub state.vscdb secrets" -ForegroundColor Red
        return $false
    }

    $exactKeysPy = "[" + (($exactKeys | ForEach-Object { "'$_'" }) -join ", ") + "]"
    $likePatternsPy = "[" + (($likePatterns | ForEach-Object { "'$_'" }) -join ", ") + "]"

    $tempScriptPath = Join-Path $env:TEMP ("qoder_scrub_secrets_{0}.py" -f ([guid]::NewGuid().ToString("N")))
    $pythonScript = @"
import json
import sqlite3
import sys

db_path = sys.argv[1]
exact_keys = $exactKeysPy
like_patterns = $likePatternsPy

result = {"before": {}, "after": {}}

conn = sqlite3.connect(db_path)
try:
    cursor = conn.cursor()
    for k in exact_keys:
        cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key = ?", (k,))
        result["before"][k] = cursor.fetchone()[0]
    for p in like_patterns:
        cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?", (p,))
        result["before"][p] = cursor.fetchone()[0]

    for k in exact_keys:
        cursor.execute("DELETE FROM ItemTable WHERE key = ?", (k,))
    for p in like_patterns:
        cursor.execute("DELETE FROM ItemTable WHERE key LIKE ?", (p,))
    conn.commit()
finally:
    conn.close()

verify_conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
try:
    verify_cursor = verify_conn.cursor()
    for k in exact_keys:
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key = ?", (k,))
        result["after"][k] = verify_cursor.fetchone()[0]
    for p in like_patterns:
        verify_cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?", (p,))
        result["after"][p] = verify_cursor.fetchone()[0]
finally:
    verify_conn.close()

print(json.dumps(result))
"@

    try {
        # No-BOM UTF-8 write for the temp .py (mirrors reset_zcode_windows-v1.0.ps1:176).
        # A BOM at the start of the temp file trips CPython's parser before the
        # shebang line is read.
        [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, (New-Object System.Text.UTF8Encoding $false))
        $commandOutput = & $pythonCommand.Source $tempScriptPath $DbPath
        if ($LASTEXITCODE -ne 0) {
            foreach ($key in ($exactKeys + $likePatterns)) {
                Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "command-failed" -Ok $false
            }
            Write-Host "    [FAILED] secret scrub Python command failed: $DbPath" -ForegroundColor Red
            return $false
        }

        $result = ($commandOutput -join "`n") | ConvertFrom-Json
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
    catch {
        foreach ($key in ($exactKeys + $likePatterns)) {
            Add-AuditEntry -Audit $Audit -File $DbPath -Key $key -Before $null -After "exception" -Ok $false
        }
        Write-Host "    [FAILED] secret scrub threw an error: $DbPath" -ForegroundColor Red
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempScriptPath) {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Post-reset watchdog probe: if a slow-shutdown helper recreated core auth files
# within 2s, re-delete. WARN (not FAIL) because the reset itself already succeeded.
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
        return
    }

    foreach ($path in $recreated) {
        Write-Host "    [WARN] watchdog recreated file, re-deleting: $path" -ForegroundColor Yellow
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        Add-AuditEntry -Audit $Audit -File $path -Key "watchdog-recreate" -Before "recreated" -After "re-deleted" -Ok $true
    }
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

# %USERPROFILE%\.qoder\argv.json is JSONC (comments allowed). ConvertFrom-Json
# cannot parse JSONC, so we regex-replace just the crash-reporter-id value and
# preserve every comment + other field verbatim.
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

    $raw = Get-Content -LiteralPath $Path -Raw
    $before = $null
    if ($raw -match '"crash-reporter-id"\s*:\s*"([^"]+)"') {
        $before = $matches[1]
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $pattern = '"crash-reporter-id"\s*:\s*"[^"]+"'
    $replacement = '"crash-reporter-id": "' + $NewCrashReporterId + '"'
    $newRaw = [regex]::Replace($raw, $pattern, $replacement)

    # No-BOM UTF-8 write (mirrors reset_zcode_windows-v1.0.ps1:923). The argv.json
    # is JSONC and Set-Content -Encoding UTF8 emits a BOM under PS 5.1, breaking
    # the Qoder JSONC loader for argv.json.
    [System.IO.File]::WriteAllText($Path, $newRaw, (New-Object System.Text.UTF8Encoding $false))

    # Re-read to confirm. JSONC reads back the same regex works.
    $verifyRaw = Get-Content -LiteralPath $Path -Raw
    $verifyMatch = [regex]::Match($verifyRaw, '"crash-reporter-id"\s*:\s*"([^"]+)"')
    $verified = if ($verifyMatch.Success) { $verifyMatch.Groups[1].Value } else { $null }

    $ok = ($verified -eq $NewCrashReporterId)
    Add-AuditEntry -Audit $Audit -File $Path -Key "crash-reporter-id" -Before $before -After $verified -Ok $ok
    return $ok
}

# Old ID_Backups directories (from previous reset runs) preserve complete snapshots
# of every identity file with the OLD ID still embedded. Six prior runs = six
# fingerprint snapshots on disk. Keep the newest run only; delete the rest. The
# newest backup is still safe to use for restore from this run.
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

    $binaryActions = Clear-BinaryIdentityStore -Paths @($Path) -Action "delete" -BackupRoot $BackupRoot -Audit $Audit -RootPath $env:USERPROFILE
    $Actions.Value += @($binaryActions)
    return "deleted"
}

# Delete every file under $Path individually with retry, then prune empty dirs.
# Why: Clear-BinaryIdentityStore does Remove-Item -Recurse on the whole tree,
# which fails FAST on the first locked file and leaves 99% of the tree intact.
# Verified on this box: 1-Cline.log locked by orphan kilo.exe, 237 other log
# files stayed on disk. Per-file delete means 1 stuck file doesn't block the
# rest -- we still delete 237/238 and surface the 1 failure honestly in audit.
function Clear-TreeFilesIndividually {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit
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

    # Prune empty dirs bottom-up so the root path can also be removed.
    $dirs = @(Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        $null = Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue
    }
    $null = Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue

    $summary = "deleted=$deleted failed=$failed"
    $ok = ($failed -eq 0)
    Add-AuditEntry -Audit $Audit -File $Path -Key "binary-store" -Before "present" -After $summary -Ok $ok

    return @{ Deleted = $deleted; Failed = $failed; FailedPaths = $failedPaths }
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

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before $before -After ("delete-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] could not delete stale backup: $Path" -ForegroundColor Red
        return $false
    }

    $ok = -not (Test-Path -LiteralPath $Path)
    $after = if ($ok) { "deleted" } else { "still-present" }
    Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before $before -After $after -Ok $ok
    if (-not $ok) {
        Write-Host "    [FAILED] stale backup still present after delete: $Path" -ForegroundColor Red
    }
    return $ok
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
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac }
    }

    # Save whatever was there before (could be empty/missing).
    $previousValue = (Get-ItemProperty -LiteralPath $classKey.PSPath -Name "NetworkAddress" -ErrorAction SilentlyContinue).NetworkAddress

    try {
        # 1) Write the new MAC into the registry. NetworkAddress expects 12 hex
        #    chars with no separators.
        Set-ItemProperty -LiteralPath $classKey.PSPath -Name "NetworkAddress" -Value $NewMac -Type String -Force -ErrorAction Stop
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("registry-write-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] could not write NetworkAddress to registry for $name" -ForegroundColor Red
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac }
    }

    # 2) Cycle the adapter so the driver re-reads the registry value. Sleep
    #    gives the PnP manager time to actually down/up the link.
    try {
        Disable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        # Some drivers refuse to disable if the adapter is in use. The
        # registry value is already written; flag partial success.
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("registry-written-disable-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [WARN] registry written but disable failed for $name -- reboot may be required" -ForegroundColor Yellow
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $previousValue }
    }

    Start-Sleep -Seconds 3

    try {
        Enable-NetAdapter -Name $name -Confirm:$false -ErrorAction Stop | Out-Null
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $auditFile -Key $auditKey -Before $oldMac -After ("enable-failed: " + $_.Exception.Message) -Ok $false
        Write-Host "    [FAILED] enable failed for $name -- network may be down, manual intervention required" -ForegroundColor Red
        return @{ Success = $false; OldMac = $oldMac; NewMac = $NewMac; PreviousValue = $previousValue }
    }

    Start-Sleep -Seconds 5

    # 3) Verify by re-reading the live MAC.
    $verified = $null
    try {
        $verified = (Get-NetAdapter -Name $name -ErrorAction Stop).MacAddress
    }
    catch {
        # Adapter may be initializing; one more retry.
        Start-Sleep -Seconds 5
        try {
            $verified = (Get-NetAdapter -Name $name -ErrorAction Stop).MacAddress
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

    return @{ Success = $ok; OldMac = $oldMac; NewMac = $NewMac; PreviousRegistryValue = $previousValue }
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

    # Re-read the registry locations to confirm. Two of the four locations
    # Rename-Computer touches are "active config" (updated immediately):
    #   - HKLM:\...\ComputerName\ComputerName     <-- ComputerName
    #   - HKLM:\...\Tcpip\Parameters\Hostname     <-- Hostname
    # The other two are "next-boot" (only updated by the kernel at boot):
    #   - HKLM:\...\ComputerName\ActiveComputerName
    #   - HKLM:\...\Tcpip\Parameters\NV Hostname
    # Without -Restart, the next-boot pair stays old until you restart. That's
    # expected, not a failure. Only verify the two live keys.
    $activeComputerName = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue).ComputerName
    $activeTcpipHost    = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Hostname" -ErrorAction SilentlyContinue).Hostname
    $nextBootActive     = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName" -Name "ComputerName" -ErrorAction SilentlyContinue).ComputerName
    $nextBootNv         = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "NV Hostname" -ErrorAction SilentlyContinue)."NV Hostname"

    $liveOk = ($activeComputerName -eq $NewHostname) -and ($activeTcpipHost -eq $NewHostname)
    $nextBootPending = ($nextBootActive -ne $NewHostname) -or ($nextBootNv -ne $NewHostname)

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
    Write-Host "[RESTORE] NIC `$(`$adapter.name): -> `$(`$adapter.oldMac)" -ForegroundColor Cyan
    `$psPath = `$interfaceGuidMap[`$adapter.interfaceGuid.ToLower()]
    if (-not `$psPath) {
        Write-Host "    [FAILED] could not find registry class key for `$(`$adapter.name) (interfaceGuid=`$(`$adapter.interfaceGuid))" -ForegroundColor Red
        continue
    }

    # oldMac from Get-NetAdapter is "AA-BB-CC-DD-EE-FF" -- convert to 12 hex chars
    `$oldMacNoSep = (`$adapter.oldMac -replace '-', '').ToUpper()

    try {
        Set-ItemProperty -LiteralPath `$psPath -Name "NetworkAddress" -Value `$oldMacNoSep -Type String -Force -ErrorAction Stop
    } catch {
        Write-Host "    [FAILED] registry write failed: `$(`$_.Exception.Message)" -ForegroundColor Red
        continue
    }

    try {
        Disable-NetAdapter -Name `$adapter.name -Confirm:`$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 3
        Enable-NetAdapter -Name `$adapter.name -Confirm:`$false -ErrorAction Stop | Out-Null
        Start-Sleep -Seconds 5
    } catch {
        Write-Host "    [WARN] adapter cycle failed (registry may still be correct): `$(`$_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        `$verified = (Get-NetAdapter -Name `$adapter.name -ErrorAction Stop).MacAddress
        `$normalized = (`$verified -replace '-', '').ToUpper()
        if (`$normalized -eq `$oldMacNoSep) {
            Write-Host "    [OK] `$(`$adapter.name) MAC restored: `$verified" -ForegroundColor Green
        } else {
            Write-Host "    [WARN] `$(`$adapter.name) verify mismatch: got=`$verified expected=`$oldMacNoSep (reboot may be required)" -ForegroundColor Yellow
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
    $pythonCommand = Get-PythonCommandInfo

    $exactKeysPy = "['secret://aicoding.auth.userInfo', 'secret://aicoding.auth.userPlan', 'secret://aicoding.auth.creditUsage', 'aicoding.auth.loginBroadcast', 'gituser']"
    $likePatternsPy = "['secret://blackbox.%', 'secret://aicoding.auth.%', '%secret.local.machine.variables%']"

    foreach ($pr in $ProfileRoots) {
        $dbPath = Join-Path $pr "User\globalStorage\state.vscdb"
        if (-not (Test-Path -LiteralPath $dbPath)) {
            Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before "missing" -After "skipped" -Ok $true
            continue
        }
        if (-not $pythonCommand) {
            Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before $null -After "python-missing" -Ok $false
            $probeOk = $false
            continue
        }

        $tempScriptPath = Join-Path $env:TEMP ("qoder_device_probe_{0}.py" -f ([guid]::NewGuid().ToString("N")))
        $pythonScript = @"
import json
import sqlite3
import sys

db_path = sys.argv[1]
exact_keys = $exactKeysPy
like_patterns = $likePatternsPy

conn = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True)
try:
    cursor = conn.cursor()
    survivors = 0
    for k in exact_keys:
        cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key = ?", (k,))
        survivors += cursor.fetchone()[0]
    for p in like_patterns:
        cursor.execute("SELECT COUNT(*) FROM ItemTable WHERE key LIKE ?", (p,))
        survivors += cursor.fetchone()[0]
finally:
    conn.close()

print(json.dumps({"survivors": survivors}))
"@
        try {
            # No-BOM UTF-8 write for the temp .py (mirrors Clear-QoderSecrets).
            [System.IO.File]::WriteAllText($tempScriptPath, $pythonScript, (New-Object System.Text.UTF8Encoding $false))
            $commandOutput = & $pythonCommand.Source $tempScriptPath $dbPath
            if ($LASTEXITCODE -ne 0) {
                Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before $null -After "command-failed" -Ok $false
                $probeOk = $false
                continue
            }
            $result = ($commandOutput -join "`n") | ConvertFrom-Json
            $ok = ($result.survivors -eq 0)
            Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before "scrubbed" -After ("survivors=" + $result.survivors) -Ok $ok
            if (-not $ok) {
                $probeOk = $false
            }
        }
        catch {
            Add-AuditEntry -Audit $Audit -File $dbPath -Key "device-flow-probe" -Before $null -After "exception" -Ok $false
            $probeOk = $false
        }
        finally {
            if (Test-Path -LiteralPath $tempScriptPath) {
                Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
            }
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

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== Qoder Identity Reset (v0.4) ===" -ForegroundColor Cyan
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
$clientDeviceId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$deviceIdSalt = ([guid]::NewGuid().ToString("N")).ToUpperInvariant()
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
    if (Set-JsonIdentity -Path $path -Updates $storageUpdates -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Actions ([ref]$actions)) {
        Write-Host "    [$label] [OK] storage.json verified" -ForegroundColor Green
    } else {
        Write-Host "    [$label] [FAILED] storage.json verification failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [3/31] state.vscdb serviceMachineId (per profile) ---
Write-Host "`n[3/31] Updating global state.vscdb serviceMachineId (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "User\globalStorage\state.vscdb"
    if (Set-SqliteKeys -Path $path -Updates @{ "storage.serviceMachineId" = $ids.devDeviceId } -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Actions ([ref]$actions)) {
        Write-Host "    [$label] [OK] state.vscdb serviceMachineId verified" -ForegroundColor Green
    } else {
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
$binaryActions = Clear-BinaryIdentityStore -Paths @($machineTokenPath, $statusPath, $quotaPath, $localDbPath, $localDbShmPath, $localDbWalPath) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
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
$binaryActions = Clear-BinaryIdentityStore -Paths @((Join-Path $root "SharedClientCache")) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $root
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
    $binaryActions = Clear-BinaryIdentityStore -Paths @($path) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
    $binaryActions = Clear-BinaryIdentityStore -Paths @($path) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Session Storage"), (Join-Path $pr "Local Storage"))
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    Write-Host "    [$label] [OK] Session/Local Storage" -ForegroundColor Green
}
$passCount++

# --- [13/31] Cache + Code Cache + GPUCache (per profile) ---
Write-Host "`n[13/31] Deleting Cache + Code Cache + GPUCache (per profile)..." -ForegroundColor Cyan
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Cache"), (Join-Path $pr "Code Cache"), (Join-Path $pr "GPUCache"))
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    Write-Host "    [$label] [OK] Cache stores" -ForegroundColor Green
}
$passCount++

# --- [14/31] Service Worker + blob_storage (per profile) ---
Write-Host "`n[14/31] Deleting Service Worker + blob_storage (per profile)..." -ForegroundColor Cyan
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Service Worker"), (Join-Path $pr "blob_storage"))
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    Write-Host "    [$label] [OK] Service Worker/blob_storage" -ForegroundColor Green
}
$passCount++

# --- [15/31] Crashpad + CrashFeedback (per profile) ---
Write-Host "`n[15/31] Deleting Crashpad + CrashFeedback (per profile)..." -ForegroundColor Cyan
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $paths = @((Join-Path $pr "Crashpad"), (Join-Path $pr "CrashFeedback"))
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    Write-Host "    [$label] [OK] Crashpad/CrashFeedback" -ForegroundColor Green
}
$passCount++

# --- [16/31] Preferences device_id_salt (per profile) ---
Write-Host "`n[16/31] Updating Preferences device_id_salt (per profile)..." -ForegroundColor Cyan
$stepFailed = $false
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "Preferences"
    if (Update-QoderPreferences -Path $path -NewDeviceIdSalt $deviceIdSalt -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $pr -TargetPath $path) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
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
foreach ($pr in $profileRoots) {
    $label = Get-ProfileLabel -MainRoot $root -ProfileRoot $pr
    $path = Join-Path $pr "logs"
    $binaryActions = Clear-BinaryIdentityStore -Paths @($path) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
    $actions += @($binaryActions)
    Write-Host "    [$label] [OK] logs" -ForegroundColor Green
}
$passCount++

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
foreach ($subdir in $userSubdirs) {
    $path = Join-Path $userQoderRoot $subdir
    $result = Remove-QoderPathSafely -Path $path -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
    if ($result -eq "missing") {
        Write-Host "    [SKIP] $subdir (not present)" -ForegroundColor DarkGray
    } elseif ($result -eq "link-removed") {
        Write-Host "    [OK] $subdir (symlink removed; target untouched)" -ForegroundColor Green
    } else {
        Write-Host "    [OK] $subdir" -ForegroundColor Green
    }
}
$passCount++

# --- [21/31] Old ID_Backups purge (keep newest only) ---
Write-Host "`n[21/31] Purging old ID_Backups directories (keep current run only)..." -ForegroundColor Cyan
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $idBackupsRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
$passCount++

# --- [22/31] Post-write watchdog re-verify ---
Write-Host "`n[22/31] Post-write watchdog re-verify..." -ForegroundColor Cyan
$watchdogCoreFiles = @($machineTokenPath, $statusPath, $localDbPath)
Test-QoderWatchdogRecreation -CoreFiles $watchdogCoreFiles -BackupRoot $backupRoot -Audit ([ref]$audit)
$passCount++

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
            $systemManifest.adapters += @{
                name          = $adapter.Name
                interfaceGuid = $adapter.InterfaceGuid
                oldMac        = $result.OldMac
                newMac        = $result.NewMac
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
$binaryActions = Clear-BinaryIdentityStore -Paths $qoderCacheFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
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
    $binaryActions = Clear-BinaryIdentityStore -Paths $paths -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $pr
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
# CLI invocation. Whole-tree backup-first delete (mirrors steps [13-15/31]).
# Chat-bearing stores (SharedClientCache\db\local.db chat tables, memories/,
# canvas/, knowledges/, projects/) are never touched by this step.
Write-Host "`n[30/31] Deleting .qoder CLI run state (tmp/telemetry, logs)..." -ForegroundColor Cyan
$step30Failed = $false
$qoderRunTrees = @((Join-Path $userQoderRoot "tmp\telemetry"), (Join-Path $userQoderRoot "logs"))
foreach ($tree in $qoderRunTrees) {
    $step30AuditStart = $audit.Count
    $binaryActions = Clear-BinaryIdentityStore -Paths @($tree) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
    $actions += @($binaryActions)
    if ((Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $step30AuditStart -Path $tree).Success) {
        Write-Host "    [OK] $tree" -ForegroundColor Green
    }
    else {
        Write-Host "    [PARTIAL] $tree (some entries failed)" -ForegroundColor Yellow
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

    $sqliteAuditEntries = @($audit | Where-Object { $_.file -eq $sqlitePath -and $_.key -eq "storage.serviceMachineId" })
    $sqliteOk = ($sqliteAuditEntries.Count -gt 0) -and ($sqliteAuditEntries[-1].ok -eq $true)
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
# These don't abort the script but they DO matter for the unban goal -- if logs
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

$qoderDoneMarker = "$env:TEMP\qoder_v0.4_done.txt"
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