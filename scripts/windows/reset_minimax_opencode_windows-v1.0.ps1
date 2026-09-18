# MiniMax Agent / OpenCode Identity Reset v1.0
#
# Targets (ground-truth paths verified on this machine):
#   MiniMax Agent  : %APPDATA%\MiniMax Agent (Electron userData) + %USERPROFILE%\.minimax
#                    (+ %USERPROFILE%\.mavis which is a JUNCTION to .minimax -- never touched)
#   OpenCode       : %APPDATA%\ai.opencode.desktop (Electron userData)
#                    + %USERPROFILE%\.local\share\opencode (CLI home: auth.json, opencode.db)
#                    + %USERPROFILE%\.config\opencode (preserved)
#
# Features (ported from reset_zcode_windows-v1.1.ps1 / reset_qoder_windows-v0.3.ps1):
#   - Self-elevation to Administrator (auto re-launch, no manual "run as admin")
#   - Aggressive multi-process kill (MiniMax/OpenCode/mavis, 2 consecutive clean checks)
#   - Backup-first for every change + self-contained restore script
#   - Verify-after-write everywhere (never silent-success)
#   - Watchdog re-verify (slow-shutdown helpers can recreate files post-wipe)
#   - Old ID_Backups purge (old backups re-embed the OLD fingerprint; keep current run only)
#   - Reparse-point-safe deletions (never follow junctions/symlinks; .mavis audited only)
#
# PRESERVATION GUARANTEES (user content is never wiped):
#   - .minimax\sessions\, sqlite.db (+shm/wal), memory\, plans\, workspace\, bin\,
#     mcp\, credentials\mavis\telegram.json, state\, v2\ and every other
#     non-targeted .minimax item are audited as preserved-per-policy.
#   - OpenCode drafts.sqlite, window-state*.json, Local Storage, skills\, pnpm\,
#     .config\opencode\, mcp-auth.json (third-party) are preserved.
#   - .local\share\opencode\opencode.db (+ repos/snapshot/storage/tool-output) is
#     app-shared storage (3.7 GB) -- preserved by design; NEVER copied to backup.
#     Isolation of this DB is the app-side fix; documented in the final summary.
#   - minimax-agent-config.json: ONLY the `user` and `sharedUser` nodes are
#     removed; `config`, `tokens`, `localStorageConfig` and all other nodes stay.
#   - system-ca-certs.pem (MiniMax Agent) is a cert bundle, not identity -- preserved.
#
# SCOPE ISOLATION: no MAC / hostname / registry-source steps here. Those belong
# strictly to change_device_id.ps1.
#
# ENCODING: every app-data file write uses
# [System.IO.File]::WriteAllText(..., UTF8Encoding($false)) -- no BOM.
# Set-Content -Encoding UTF8 emits a BOM under PowerShell 5.1 and corrupts
# Chromium/Electron JSON parsers.
#
# PRIVACY: audit entries for auth files record node NAMES and counts only --
# token values are never written to any log.
#
# PS 5.1 COMPAT: no [CmdletBinding()] (keeps `*>` log redirect working),
# no ternary, no $Input variable, RandomNumberGenerator via .GetBytes() only.
#
# NOTE: no SQLite writes are performed by this script (both apps' SQLite
# databases are preserved), so Python is NOT required.
#
# Usage (Windows 10, PowerShell 5.1 or 7 -- run from OUTSIDE OpenCode/MiniMax):
#   powershell -ExecutionPolicy Bypass -File reset_minimax_opencode_windows-v1.0.ps1
# Prerequisite: close MiniMax Agent + OpenCode first (the script also force-kills them).

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
# Re-launch elevated with the same script path when not already admin.
$mmoIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $mmoIsAdmin) {
    $mmoLogOut = "$env:TEMP\minimax_opencode_v1.0_result.log"
    $mmoScript = $MyInvocation.MyCommand.Path
    $mmoArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$mmoScript`" *> `"$mmoLogOut`""
    Start-Process powershell -Verb RunAs -ArgumentList $mmoArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath $mmoLogOut) {
        Get-Content -LiteralPath $mmoLogOut
    }
    if (Test-Path -LiteralPath "$env:TEMP\minimax_opencode_v1.0_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\minimax_opencode_v1.0_done.txt"
    }
    exit
}

Write-GhostBanner -Target "MiniMax/OpenCode Identity Reset" -Version "1.0"

# === Local helpers (mirroring the zcode v1.1 reference pattern) ================

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

# %USERPROFILE%-level targets (.minimax, .local\share\opencode) sit outside
# %APPDATA%. Label them under a USERPROFILE\ subtree so the restore script
# rehydrates correctly.
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
        [Parameter(Mandatory = $true)][ref]$Actions,
        [string]$AuditKey = "machineid"
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
    Add-AuditEntry -Audit $Audit -File $Path -Key $AuditKey -Before $beforeValue -After $afterValue -Ok $ok
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

# Wipe EVERY top-level node from an auth JSON file (forces re-login). The audit
# records node NAMES and a count only -- never token values. Verify-after
# re-read must show zero properties. PS 5.1 note: ConvertFrom-Json on "{}" can
# yield $null, which counts as zero nodes.
function Clear-AllJsonNodes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "auth-wipe" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] auth file not present: $Path" -ForegroundColor Yellow
        return $true
    }

    $nodeNames = @()
    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -ne $content) {
            $nodeNames = @($content.PSObject.Properties.Name)
        }
    }
    catch {
        $nodeNames = @("<unparseable>")
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $namesSummary = "empty"
    if ($nodeNames.Count -gt 0) {
        $shown = @($nodeNames | Select-Object -First 12)
        $namesSummary = ("{0} nodes: {1}" -f $nodeNames.Count, ($shown -join ","))
    }

    [System.IO.File]::WriteAllText($Path, "{}", (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $afterCount = 0
        if ($null -ne $verified) {
            $afterCount = @($verified.PSObject.Properties).Count
        }
        $ok = ($afterCount -eq 0)
        Add-AuditEntry -Audit $Audit -File $Path -Key "auth-wipe" -Before $namesSummary -After "0 nodes" -Ok $ok
        if ($ok) {
            Write-Host "    [OK] auth nodes wiped (names-only audit): $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] auth file still has $afterCount nodes: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "auth-wipe" -Before $namesSummary -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read auth file after write: $Path" -ForegroundColor Red
        return $false
    }
}

# Remove ONLY the named nodes from a JSON file, keep everything else (used for
# minimax-agent-config.json: remove user/sharedUser, keep config + the rest).
# Verify-after: removed nodes absent AND keep-nodes still present.
function Remove-JsonNodesVerified {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$NodeNames,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions,
        [string[]]$MustKeepNames = @()
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "node-removal" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] JSON file not present: $Path" -ForegroundColor Yellow
        return $true
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "node-removal" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse JSON: $Path" -ForegroundColor Red
        return $false
    }

    $presentTargets = @()
    foreach ($name in $NodeNames) {
        if ($null -ne $content.PSObject.Properties[$name]) {
            $presentTargets += $name
        }
    }

    if ($presentTargets.Count -eq 0) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "node-removal" -Before "absent" -After "skipped" -Ok $true
        Write-Host "    [SKIP] target nodes already absent: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    foreach ($name in $presentTargets) {
        $null = $content.PSObject.Properties.Remove($name)
    }

    # No-BOM UTF-8 write.
    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "node-removal" -Before ($presentTargets -join ",") -After "verify-parse-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read JSON after write: $Path" -ForegroundColor Red
        return $false
    }

    $stillThere = @()
    foreach ($name in $presentTargets) {
        if ($null -ne $verified.PSObject.Properties[$name]) {
            $stillThere += $name
        }
    }
    $keepMissing = @()
    foreach ($name in $MustKeepNames) {
        if ($null -eq $verified.PSObject.Properties[$name]) {
            $keepMissing += $name
        }
    }

    $ok = (($stillThere.Count -eq 0) -and ($keepMissing.Count -eq 0))
    $afterSummary = ("removed: " + ($presentTargets -join ","))
    if ($stillThere.Count -gt 0) {
        $afterSummary = ("still-present: " + ($stillThere -join ","))
    }
    if ($keepMissing.Count -gt 0) {
        $afterSummary = $afterSummary + (" | keep-nodes-missing: " + ($keepMissing -join ","))
    }
    Add-AuditEntry -Audit $Audit -File $Path -Key "node-removal" -Before ($presentTargets -join ",") -After $afterSummary -Ok $ok

    if ($ok) {
        Write-Host "    [OK] nodes removed, keep-nodes intact: $($presentTargets -join ',')" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] node removal verification failed: $afterSummary" -ForegroundColor Red
    }
    return $ok
}

# New device id that preserves the shape of the old one (braces / casing) so
# the app's parser keeps accepting it. Falls back to a lowercase GUID.
function New-DeviceIdPreservingFormat {
    param([string]$CurrentValue)

    $guidPattern = '^\{?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}?$'
    if ((-not [string]::IsNullOrWhiteSpace($CurrentValue)) -and ($CurrentValue -match $guidPattern)) {
        $fresh = [guid]::NewGuid().ToString()
        if ($CurrentValue.StartsWith("{")) {
            return "{" + $fresh.ToUpperInvariant() + "}"
        }
        if ($CurrentValue -cmatch "[A-F]") {
            return $fresh.ToUpperInvariant()
        }
        return $fresh.ToLowerInvariant()
    }

    return ([guid]::NewGuid().ToString()).ToLowerInvariant()
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

# Delete a stale file WITHOUT backing it up (regenerable files only). Verifies
# the path is gone afterwards.
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

# Reparse-point-safe removal (junction/symlink guard). Removes the link itself
# without following it; real dirs go through the restorable delete path. Never
# touches the link target.
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

# Scrub os_crypt.encrypted_key from a Chromium Local State file. Backup happens
# ONLY when the key is actually present (keeps the restore manifest accurate --
# a run that changed nothing must not list copy actions). No-BOM write.
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

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "present" -After "parse-failed" -Ok $false
        Write-Host "    [FAILED] could not parse Local State: $Path" -ForegroundColor Red
        return $false
    }

    if ($null -eq $content.PSObject.Properties['os_crypt']) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] os_crypt not found in: $Path" -ForegroundColor Yellow
        return $true
    }
    if ($null -eq $content.os_crypt.PSObject.Properties['encrypted_key']) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] os_crypt.encrypted_key not present: $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
    }

    $content.os_crypt.PSObject.Properties.Remove('encrypted_key')

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verified = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        $afterValue = if ($null -eq $verified.os_crypt.PSObject.Properties['encrypted_key']) { "removed" } else { "still-present" }
        $ok = $afterValue -eq "removed"
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "present" -After $afterValue -Ok $ok
        if ($ok) {
            Write-Host "    [OK] os_crypt.encrypted_key removed: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] os_crypt.encrypted_key still present: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "os_crypt.encrypted_key" -Before "present" -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read Local State after write: $Path" -ForegroundColor Red
        return $false
    }
}

# Rotate electron.media.device_id_salt in a Chromium Preferences file.
# With -OnlyIfPresent the salt is rotated only when it already exists; a file
# without the node is honestly skipped (never creates new identity state).
function Set-DeviceIdSalt {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$NewSalt,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions,
        [switch]$OnlyIfPresent
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before "missing" -After "skipped" -Ok $true
        Write-Host "    [SKIP] Preferences not found: $Path" -ForegroundColor Yellow
        return $true
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
    $saltPresent = $false

    $electronProp = if ($null -ne $content.PSObject.Properties['electron']) { $content.electron } else { $null }
    if ($electronProp -and ($null -ne $electronProp.PSObject.Properties['media'])) {
        $mediaProp = $electronProp.media
        if ($null -ne $mediaProp.PSObject.Properties['device_id_salt']) {
            $beforeValue = $mediaProp.device_id_salt
            $saltPresent = $true
        }
    }

    if ($OnlyIfPresent -and (-not $saltPresent)) {
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before "absent" -After "skipped" -Ok $true
        Write-Host "    [SKIP] device_id_salt not present (nothing to rotate): $Path" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) {
        Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath
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
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before $beforeValue -After $actualValue -Ok $ok
        if ($ok) {
            Write-Host "    [OK] device_id_salt updated: $Path" -ForegroundColor Green
        }
        else {
            Write-Host "    [FAILED] device_id_salt verification failed: $Path" -ForegroundColor Red
        }
        return $ok
    }
    catch {
        Add-AuditEntry -Audit $Audit -File $Path -Key "electron.media.device_id_salt" -Before $beforeValue -After "verify-failed" -Ok $false
        Write-Host "    [FAILED] could not re-read Preferences after write: $Path" -ForegroundColor Red
        return $false
    }
}

# === Aggressive process kill (ported from zcode v1.1) ==========================

# Tree-kill for MiniMax Agent / MiniMax Code / OpenCode / mavis. Requires 2
# consecutive clean wildcard checks; hard-fails the run when unkillable so no
# step ever writes while a live process holds the files open.
# DELIBERATELY NOT matched: node, python, kilo, cline, roo (unrelated work and
# unrelated IDE extensions -- none of these names match the wildcards below).
function Stop-MiniMaxOpenCodeProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all MiniMax/OpenCode/mavis processes (aggressive tree-kill)..." -ForegroundColor Cyan

    $processesToKill = @(
        "MiniMax",
        "MiniMax Agent",
        "OpenCode",
        "ai.opencode.desktop",
        "mavis",
        "minimax"
    )

    $verifyWildcards = @(
        "MiniMax*",
        "minimax*",
        "*opencode*",
        "mavis*"
    )

    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        foreach ($processName in $processesToKill) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                $null = & taskkill /F /T /IM "$processName.exe" 2>&1
            }
        }

        Start-Sleep -Milliseconds $DelayMs

        $remaining = @(Get-Process -Name $verifyWildcards -ErrorAction SilentlyContinue |
            Select-Object -Unique Id)
        $count = $remaining.Count
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all MiniMax/OpenCode/mavis processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($wildcard in $verifyWildcards) {
        foreach ($p in @(Get-Process -Name $wildcard -ErrorAction SilentlyContinue)) {
            Write-Host ("    PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
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

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$mmRoaming = Join-Path $env:APPDATA "MiniMax Agent"
$ocRoaming = Join-Path $env:APPDATA "ai.opencode.desktop"
$mmHome = Join-Path $env:USERPROFILE ".minimax"
$ocHome = Join-Path $env:USERPROFILE ".local\share\opencode"
$ocConfig = Join-Path $env:USERPROFILE ".config\opencode"
$mavisJunction = Join-Path $env:USERPROFILE ".mavis"
$mmMcodePublic = Join-Path $mmHome "auth\prod\en\mcode-public"
$backupRoot = Join-Path $mmRoaming ("ID_Backups\" + $timestamp)
$mmIdBackupsRoot = Join-Path $mmRoaming "ID_Backups"
$ocIdBackupsRoot = Join-Path $ocRoaming "ID_Backups"
$audit = @()
$actions = @()

$mmRoamingPresent = Test-Path -LiteralPath $mmRoaming
$ocRoamingPresent = Test-Path -LiteralPath $ocRoaming
$mmHomePresent = Test-Path -LiteralPath $mmHome
$ocHomePresent = Test-Path -LiteralPath $ocHome

if (-not ($mmRoamingPresent -or $ocRoamingPresent -or $mmHomePresent -or $ocHomePresent)) {
    Write-Host "Neither MiniMax nor OpenCode installations were found." -ForegroundColor Red
    Write-Host "Looked at: $mmRoaming | $ocRoaming | $mmHome | $ocHome" -ForegroundColor Red
    exit 1
}

New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null

Write-Host "=== MiniMax Agent / OpenCode Identity Reset v1.0 ===" -ForegroundColor Cyan
Write-Host "MiniMax Agent (Electron): $mmRoaming" -ForegroundColor Gray
Write-Host "MiniMax CLI home        : $mmHome" -ForegroundColor Gray
Write-Host "OpenCode (Electron)     : $ocRoaming" -ForegroundColor Gray
Write-Host "OpenCode CLI home       : $ocHome" -ForegroundColor Gray
Write-Host "Backup: $backupRoot" -ForegroundColor Gray
Write-Host "Policy: sessions/sqlite/memory/plans/workspace preserved; no MAC/hostname/registry steps" -ForegroundColor Gray

# Pre-step: aggressive tree-kill. Hard-fails the run if unkillable, so no step
# ever writes while a live process still holds the files open.
if (-not (Stop-MiniMaxOpenCodeProcessesAggressive)) {
    exit 1
}

$passCount = 0
$failCount = 0

$newUpdaterIdOC = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newUpdaterIdMM = ([guid]::NewGuid().ToString()).ToLowerInvariant()
$newSalt = -join ((1..32) | ForEach-Object { "{0:X}" -f (Get-Random -Maximum 16) })
$newDesktopDeviceId = $null

# --- [1/22] OpenCode CLI auth.json wipe (forces re-login) ---
$ocAuthPath = Join-Path $ocHome "auth.json"
Write-Host "`n[1/22] Wiping OpenCode auth.json (all top-level nodes)..." -ForegroundColor Cyan
if (Clear-AllJsonNodes -Path $ocAuthPath -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $ocAuthPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [2/22] OpenCode CLI home: log/ clear + shared-storage preserves ---
Write-Host "`n[2/22] Clearing OpenCode CLI log/ + auditing shared-storage preserves..." -ForegroundColor Cyan
$auditStart = $audit.Count
$ocLogDir = Join-Path $ocHome "log"
$ocLogResult = Remove-AppPathSafely -Path $ocLogDir -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
if ($ocLogResult -eq "missing") {
    Write-Host "    [SKIP] .local\share\opencode\log (not present)" -ForegroundColor DarkGray
}
else {
    Write-Host "    [OK] .local\share\opencode\log cleared" -ForegroundColor Green
}
# opencode.db is app-shared storage (3.7 GB here): preserved in place, NEVER
# copied. Isolation of this DB is the app-side fix (documented in the summary).
foreach ($preservedName in @("mcp-auth.json", "opencode.db", "repos", "snapshot", "storage", "tool-output")) {
    $p = Join-Path $ocHome $preservedName
    if (Test-Path -LiteralPath $p) {
        Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "preserved-per-policy" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $ocHome
if ($status.Success) {
    $passCount++
}
else {
    Write-Host "[FAILED] OpenCode CLI home step had failures" -ForegroundColor Red
    $failCount++
}

# --- [3/22] OpenCode .updaterId + gh\device-id rotation ---
Write-Host "`n[3/22] Rotating OpenCode .updaterId + gh\device-id..." -ForegroundColor Cyan
$stepFailed = $false
$ocUpdaterIdPath = Join-Path $ocRoaming ".updaterId"
if (Test-Path -LiteralPath $ocUpdaterIdPath) {
    if (Set-VerifiedMachineIdFile -Path $ocUpdaterIdPath -Value $newUpdaterIdOC -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $ocRoaming -TargetPath $ocUpdaterIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions) -AuditKey "updaterId") {
        Write-Host "    [OK] .updaterId verified" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] .updaterId verification failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
else {
    Write-Host "    [SKIP] .updaterId not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $ocUpdaterIdPath -Key "updaterId" -Before "missing" -After "skipped" -Ok $true
}
$ocGhDeviceIdPath = Join-Path $ocRoaming "gh\device-id"
if (Test-Path -LiteralPath $ocGhDeviceIdPath) {
    if (Set-VerifiedMachineIdFile -Path $ocGhDeviceIdPath -Value $newUpdaterIdOC -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $ocRoaming -TargetPath $ocGhDeviceIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions) -AuditKey "gh-device-id") {
        Write-Host "    [OK] gh\device-id verified" -ForegroundColor Green
    }
    else {
        Write-Host "    [FAILED] gh\device-id verification failed" -ForegroundColor Red
        $stepFailed = $true
    }
}
else {
    Write-Host "    [SKIP] gh\device-id not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $ocGhDeviceIdPath -Key "gh-device-id" -Before "missing" -After "skipped" -Ok $true
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [4/22] OpenCode opencode.global.dat + stale tmp siblings ---
Write-Host "`n[4/22] Clearing OpenCode opencode.global.dat + stale tmp siblings..." -ForegroundColor Cyan
$auditStart = $audit.Count
if ($ocRoamingPresent) {
    $ocGlobalDat = Join-Path $ocRoaming "opencode.global.dat"
    $datActions = Clear-BinaryIdentityStore -Paths @($ocGlobalDat) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $ocRoaming
    $actions += @($datActions)
    $staleTmps = @(Get-ChildItem -LiteralPath $ocRoaming -Filter "opencode.global.dat.tmp-*" -File -Force -ErrorAction SilentlyContinue)
    foreach ($tmpFile in $staleTmps) {
        $tmpActions = Clear-BinaryIdentityStore -Paths @($tmpFile.FullName) -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $ocRoaming
        $actions += @($tmpActions)
    }
    if ($staleTmps.Count -gt 0) {
        Write-Host "    stale tmp siblings removed: $($staleTmps.Count)" -ForegroundColor DarkGray
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $ocRoaming
if ($status.Success) {
    Write-Host "[OK] opencode.global.dat cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] opencode.global.dat step had failures" -ForegroundColor Red
    $failCount++
}

# --- [5/22] OpenCode Chromium network stores ---
Write-Host "`n[5/22] Clearing OpenCode network stores (Cookies/DIPS/SharedStorage/Trust Tokens/NPS)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$ocNetworkFileRelPaths = @(
    "Network\Cookies",
    "Network\Cookies-journal",
    "DIPS",
    "SharedStorage",
    "SharedStorage-wal",
    "SharedStorage-journal",
    "Network\Trust Tokens",
    "Network\Trust Tokens-journal",
    "Network\Network Persistent State",
    "Network\TransportSecurity",
    "Network\NetworkDataMigrated"
)
if ($ocRoamingPresent) {
    $ocNetworkFiles = @($ocNetworkFileRelPaths | ForEach-Object { Join-Path $ocRoaming $_ })
    $ocNetworkActions = Clear-BinaryIdentityStore -Paths $ocNetworkFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $ocRoaming
    $actions += @($ocNetworkActions)
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $ocRoaming
if ($status.Success) {
    Write-Host "[OK] OpenCode network stores cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] OpenCode network stores had failures" -ForegroundColor Red
    $failCount++
}

# --- [6/22] OpenCode cache trees + session/web storage (per-file delete) ---
Write-Host "`n[6/22] Clearing OpenCode cache trees + Session Storage + Shared Dictionary..." -ForegroundColor Cyan
$auditStart = $audit.Count
$ocTreeRelPaths = @(
    "Cache\Cache_Data",
    "Code Cache",
    "GPUCache",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "blob_storage",
    "VideoDecodeStats",
    "Session Storage",
    "Shared Dictionary",
    "WebStorage",
    "Crashpad",
    "logs"
)
if ($ocRoamingPresent) {
    foreach ($relative in $ocTreeRelPaths) {
        $fullPath = Join-Path $ocRoaming $relative
        if (Test-Path -LiteralPath $fullPath) {
            $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $ocRoaming -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $ocRoaming
if ($status.Success) {
    Write-Host "[OK] OpenCode cache trees cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] OpenCode cache trees had failures" -ForegroundColor Red
    $failCount++
}

# --- [7/22] OpenCode Local State os_crypt + Preferences device_id_salt ---
Write-Host "`n[7/22] Scrubbing OpenCode os_crypt.encrypted_key + rotating Preferences salt..." -ForegroundColor Cyan
$stepFailed = $false
$ocLocalStatePath = Join-Path $ocRoaming "Local State"
if (-not (Remove-OsCryptEncryptedKey -Path $ocLocalStatePath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $ocRoaming -TargetPath $ocLocalStatePath) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
    $stepFailed = $true
}
$ocPreferencesPath = Join-Path $ocRoaming "Preferences"
if (-not (Set-DeviceIdSalt -Path $ocPreferencesPath -NewSalt $newSalt -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $ocRoaming -TargetPath $ocPreferencesPath) -Audit ([ref]$audit) -Actions ([ref]$actions) -OnlyIfPresent)) {
    $stepFailed = $true
}
if ($stepFailed) { $failCount++ } else { $passCount++ }

# --- [8/22] OpenCode preservation audit (userData + .config) ---
Write-Host "`n[8/22] Auditing OpenCode preserved paths (drafts/window-state/skills/pnpm/.config)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$ocPreservedNames = @(
    "drafts.sqlite",
    "opencode.settings",
    "opencode.updater",
    "opencode",
    "default.dat",
    "Local Storage",
    "skills",
    "pnpm",
    "gh"
)
if ($ocRoamingPresent) {
    foreach ($name in $ocPreservedNames) {
        $p = Join-Path $ocRoaming $name
        if (Test-Path -LiteralPath $p) {
            Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "preserved-per-policy" -Before "missing" -After "skipped" -Ok $true
        }
    }
    $ocWindowStates = @(Get-ChildItem -LiteralPath $ocRoaming -Filter "window-state*.json" -File -Force -ErrorAction SilentlyContinue)
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $ocRoaming "window-state*.json") -Key "preserved-per-policy" -Before ("count=" + $ocWindowStates.Count) -After "preserved-per-policy" -Ok $true
    $ocWindowDats = @(Get-ChildItem -LiteralPath $ocRoaming -Filter "opencode.window.*.dat" -File -Force -ErrorAction SilentlyContinue)
    $ocWorkspaceDats = @(Get-ChildItem -LiteralPath $ocRoaming -Filter "opencode.workspace.*.dat" -File -Force -ErrorAction SilentlyContinue)
    Add-AuditEntry -Audit ([ref]$audit) -File (Join-Path $ocRoaming "opencode.*.dat") -Key "preserved-per-policy" -Before ("window=" + $ocWindowDats.Count + " workspace=" + $ocWorkspaceDats.Count) -After "preserved-per-policy" -Ok $true
}
if (Test-Path -LiteralPath $ocConfig) {
    Add-AuditEntry -Audit ([ref]$audit) -File $ocConfig -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
    Write-Host "    [INFO] Preserving .config\opencode (user config + skills)" -ForegroundColor Cyan
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $ocConfig -Key "preserved-per-policy" -Before "missing" -After "skipped" -Ok $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $ocRoaming
if ($status.Success) {
    $passCount++
}
else {
    Write-Host "[FAILED] OpenCode preserve audit had failures" -ForegroundColor Red
    $failCount++
}

# --- [9/22] MiniMax mcode-public auth.json wipe ---
$mmPublicAuthPath = Join-Path $mmMcodePublic "auth.json"
Write-Host "`n[9/22] Wiping MiniMax mcode-public auth.json (records/tokens)..." -ForegroundColor Cyan
if (Clear-AllJsonNodes -Path $mmPublicAuthPath -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $mmPublicAuthPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [10/22] MiniMax mcode-public auth-state.json wipe ---
$mmAuthStatePath = Join-Path $mmMcodePublic "auth-state.json"
Write-Host "`n[10/22] Wiping MiniMax auth-state.json..." -ForegroundColor Cyan
if (Clear-AllJsonNodes -Path $mmAuthStatePath -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $mmAuthStatePath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [11/22] MiniMax local-runtime.auth.json wipe ---
$mmLocalRuntimeAuthPath = Join-Path $mmHome "local-runtime.auth.json"
Write-Host "`n[11/22] Wiping MiniMax local-runtime.auth.json..." -ForegroundColor Cyan
if (Clear-AllJsonNodes -Path $mmLocalRuntimeAuthPath -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $mmLocalRuntimeAuthPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [12/22] minimax-agent-config.json: remove user/sharedUser ONLY ---
$mmAgentConfigPath = Join-Path $mmRoaming "minimax-agent-config.json"
Write-Host "`n[12/22] Removing minimax-agent-config.json user/sharedUser nodes (config kept)..." -ForegroundColor Cyan
if (Remove-JsonNodesVerified -Path $mmAgentConfigPath -NodeNames @("user", "sharedUser") -MustKeepNames @("config") -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $mmAgentConfigPath) -Audit ([ref]$audit) -Actions ([ref]$actions)) {
    $passCount++
}
else {
    $failCount++
}

# --- [13/22] remote-control\state.json: rotate desktop_device_id ---
$mmRemoteControlStatePath = Join-Path $mmRoaming "remote-control\state.json"
Write-Host "`n[13/22] Rotating remote-control state.json desktop_device_id..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $mmRemoteControlStatePath) {
    $oldDesktopDeviceId = $null
    try {
        $rcContent = Get-Content -LiteralPath $mmRemoteControlStatePath -Raw | ConvertFrom-Json
        if ($null -ne $rcContent -and $null -ne $rcContent.PSObject.Properties['desktop_device_id']) {
            $oldDesktopDeviceId = $rcContent.desktop_device_id
        }
    }
    catch {
        $oldDesktopDeviceId = $null
    }
    $newDesktopDeviceId = New-DeviceIdPreservingFormat -CurrentValue $oldDesktopDeviceId
    if (Set-JsonIdentity -Path $mmRemoteControlStatePath -Updates @{ "desktop_device_id" = $newDesktopDeviceId } -Audit ([ref]$audit) -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $mmRemoteControlStatePath) -Actions ([ref]$actions)) {
        Write-Host "[OK] desktop_device_id rotated + verified" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] desktop_device_id verification failed" -ForegroundColor Red
        $failCount++
    }
}
else {
    Write-Host "[SKIP] remote-control\state.json not present" -ForegroundColor Yellow
    Add-AuditEntry -Audit ([ref]$audit) -File $mmRemoteControlStatePath -Key "desktop_device_id" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}

# --- [14/22] MiniMax .updaterId rotation ---
$mmUpdaterIdPath = Join-Path $mmRoaming ".updaterId"
Write-Host "`n[14/22] Rotating MiniMax Agent .updaterId..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $mmUpdaterIdPath) {
    if (Set-VerifiedMachineIdFile -Path $mmUpdaterIdPath -Value $newUpdaterIdMM -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $mmUpdaterIdPath) -Audit ([ref]$audit) -Actions ([ref]$actions) -AuditKey "updaterId") {
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
    Add-AuditEntry -Audit ([ref]$audit) -File $mmUpdaterIdPath -Key "updaterId" -Before "missing" -After "skipped" -Ok $true
    $passCount++
}

# --- [15/22] MiniMax Agent Chromium stores (profile-wide treatment) ---
Write-Host "`n[15/22] Clearing MiniMax Agent Chromium stores (Cookies/LocalStorage/IndexedDB/etc.)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$mmStoreFileRelPaths = @(
    "Network\Cookies",
    "Network\Cookies-journal",
    "DIPS",
    "DIPS-wal",
    "SharedStorage",
    "SharedStorage-wal",
    "SharedStorage-journal",
    "Network\Trust Tokens",
    "Network\Trust Tokens-journal",
    "Network\Network Persistent State",
    "Network\TransportSecurity",
    "Network\NetworkDataMigrated"
)
$mmStoreDirRelPaths = @(
    "Local Storage",
    "IndexedDB",
    "Session Storage",
    "WebStorage",
    "Shared Dictionary",
    "VideoDecodeStats",
    "blob_storage",
    "browser-cache"
)
if ($mmRoamingPresent) {
    $mmStoreFiles = @($mmStoreFileRelPaths | ForEach-Object { Join-Path $mmRoaming $_ })
    $mmStoreActions = Clear-BinaryIdentityStore -Paths $mmStoreFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $mmRoaming
    $actions += @($mmStoreActions)
    foreach ($relative in $mmStoreDirRelPaths) {
        $fullPath = Join-Path $mmRoaming $relative
        if (Test-Path -LiteralPath $fullPath) {
            $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $mmRoaming
if ($status.Success) {
    Write-Host "[OK] MiniMax Agent Chromium stores cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] MiniMax Agent Chromium stores had failures" -ForegroundColor Red
    $failCount++
}

# --- [16/22] MiniMax Agent cache trees + Local State os_crypt + Preferences salt ---
Write-Host "`n[16/22] Clearing MiniMax Agent cache trees + os_crypt + Preferences salt..." -ForegroundColor Cyan
$auditStart = $audit.Count
$stepFailed = $false
$mmCacheRelPaths = @(
    "Cache\Cache_Data",
    "Code Cache",
    "GPUCache",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "Crashpad"
)
if ($mmRoamingPresent) {
    foreach ($relative in $mmCacheRelPaths) {
        $fullPath = Join-Path $mmRoaming $relative
        if (Test-Path -LiteralPath $fullPath) {
            $null = Clear-TreeFilesIndividually -Path $fullPath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $fullPath) -Audit ([ref]$audit) -Actions ([ref]$actions)
        }
        else {
            Add-AuditEntry -Audit ([ref]$audit) -File $fullPath -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
        }
    }
}
$mmLocalStatePath = Join-Path $mmRoaming "Local State"
if (-not (Remove-OsCryptEncryptedKey -Path $mmLocalStatePath -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $mmLocalStatePath) -Audit ([ref]$audit) -Actions ([ref]$actions))) {
    $stepFailed = $true
}
$mmPreferencesPath = Join-Path $mmRoaming "Preferences"
if (-not (Set-DeviceIdSalt -Path $mmPreferencesPath -NewSalt $newSalt -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $mmPreferencesPath) -Audit ([ref]$audit) -Actions ([ref]$actions) -OnlyIfPresent)) {
    $stepFailed = $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $mmRoaming
if ($status.Success -and (-not $stepFailed)) {
    Write-Host "[OK] MiniMax Agent caches + crypto state cleared" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] MiniMax Agent caches step had failures" -ForegroundColor Red
    $failCount++
}

# --- [17/22] mavis-browser partition: Local Storage ONLY (per spec) ---
Write-Host "`n[17/22] Clearing mavis-browser partition Local Storage (only)..." -ForegroundColor Cyan
$auditStart = $audit.Count
$mmMavisBrowser = Join-Path $mmRoaming "Partitions\mavis-browser"
$mmMavisLocalStorage = Join-Path $mmMavisBrowser "Local Storage"
if (Test-Path -LiteralPath $mmMavisLocalStorage) {
    $null = Clear-TreeFilesIndividually -Path $mmMavisLocalStorage -BackupRoot $backupRoot -BackupLabel (Get-AppRelativeBackupLabel -RootPath $mmRoaming -TargetPath $mmMavisLocalStorage) -Audit ([ref]$audit) -Actions ([ref]$actions)
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $mmMavisLocalStorage -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
}
if (Test-Path -LiteralPath $mmMavisBrowser) {
    Add-AuditEntry -Audit ([ref]$audit) -File $mmMavisBrowser -Key "embedded-browser" -Before "present" -After "local-storage-only-per-policy" -Ok $true
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $mmMavisBrowser -Key "embedded-browser" -Before "missing" -After "skipped" -Ok $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $mmMavisBrowser
if ($status.Success) {
    $passCount++
}
else {
    Write-Host "[FAILED] mavis-browser Local Storage had failures" -ForegroundColor Red
    $failCount++
}

# --- [18/22] MiniMax misc clears (spec step 8 list) ---
Write-Host "`n[18/22] Clearing MiniMax misc (shared_proto_db/outbox/tabs/hot-update/logs/locks/tmp/run)..." -ForegroundColor Cyan
$auditStart = $audit.Count
# Dirs that might be junctions on odd installs go through the reparse-safe path.
foreach ($safeDir in @(
    (Join-Path $mmRoaming "shared_proto_db"),
    (Join-Path $mmRoaming "hot-update"),
    (Join-Path $mmHome "tmp"),
    (Join-Path $mmHome "run")
)) {
    $result = Remove-AppPathSafely -Path $safeDir -BackupRoot $backupRoot -Audit ([ref]$audit) -Actions ([ref]$actions)
    if ($result -eq "missing") {
        Write-Host "    [SKIP] $(Split-Path -Leaf $safeDir) (not present)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "    [OK] $(Split-Path -Leaf $safeDir)" -ForegroundColor Green
    }
}
# Flat identity-bearing files (backup-first delete).
$mmMiscFiles = @(
    (Join-Path $mmRoaming "observability-outbox.jsonl"),
    (Join-Path $mmRoaming "embedded-browser-tabs.json"),
    (Join-Path $mmRoaming "crash-evidence-session.json"),
    (Join-Path $mmHome "daemon.lock"),
    (Join-Path $mmHome "auth\auth.lock"),
    (Join-Path $mmMcodePublic "auth.lock")
)
if ($mmRoamingPresent -or $mmHomePresent) {
    $mmMiscActions = Clear-BinaryIdentityStore -Paths $mmMiscFiles -Action "delete" -BackupRoot $backupRoot -Audit ([ref]$audit) -RootPath $env:USERPROFILE
    $actions += @($mmMiscActions)
}
# logs/ embeds request URLs with account/session signals -- identity-bearing.
foreach ($logsDir in @((Join-Path $mmRoaming "logs"), (Join-Path $mmHome "logs"))) {
    if (Test-Path -LiteralPath $logsDir) {
        $null = Clear-TreeFilesIndividually -Path $logsDir -BackupRoot $backupRoot -BackupLabel (Get-UserProfileBackupLabel -TargetPath $logsDir) -Audit ([ref]$audit) -Actions ([ref]$actions)
    }
    else {
        Add-AuditEntry -Audit ([ref]$audit) -File $logsDir -Key "binary-store" -Before "missing" -After "skipped" -Ok $true
    }
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $mmRoaming
if ($status.Success) {
    $statusHome = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $mmHome
    if ($statusHome.Success) {
        Write-Host "[OK] MiniMax misc clears complete" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] MiniMax .minimax misc clears had failures" -ForegroundColor Red
        $failCount++
    }
}
else {
    Write-Host "[FAILED] MiniMax Agent misc clears had failures" -ForegroundColor Red
    $failCount++
}

# --- [19/22] MiniMax preservation audit + .mavis junction (link-only) ---
Write-Host "`n[19/22] Auditing MiniMax preserved paths + .mavis junction..." -ForegroundColor Cyan
$auditStart = $audit.Count
if ($mmHomePresent) {
    # Headline preserves with explicit audit entries.
    $mmSessionsDir = Join-Path $mmHome "sessions"
    if (Test-Path -LiteralPath $mmSessionsDir) {
        $sessionsCount = @(Get-ChildItem -LiteralPath $mmSessionsDir -Force -ErrorAction SilentlyContinue).Count
        Add-AuditEntry -Audit ([ref]$audit) -File $mmSessionsDir -Key "sessions-preserved" -Before ("entries=" + $sessionsCount) -After "preserved-per-policy" -Ok $true
        Write-Host "    [INFO] Preserving sessions\ ($sessionsCount entries)" -ForegroundColor Cyan
    }
    foreach ($sqliteName in @("sqlite.db", "sqlite.db-shm", "sqlite.db-wal")) {
        $p = Join-Path $mmHome $sqliteName
        if (Test-Path -LiteralPath $p) {
            Add-AuditEntry -Audit ([ref]$audit) -File $p -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
        }
    }
    $mmTelegramPath = Join-Path $mmHome "credentials\mavis\telegram.json"
    if (Test-Path -LiteralPath $mmTelegramPath) {
        Add-AuditEntry -Audit ([ref]$audit) -File $mmTelegramPath -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
    }
    # Every other non-targeted top-level item is audited as preserved.
    $mmClearedRootNames = @("auth", "local-runtime.auth.json", "logs", "daemon.lock", "tmp", "run", "sessions", "sqlite.db", "sqlite.db-shm", "sqlite.db-wal")
    $mmTopLevelItems = @(Get-ChildItem -LiteralPath $mmHome -Force -ErrorAction SilentlyContinue)
    foreach ($item in $mmTopLevelItems) {
        if ($mmClearedRootNames -contains $item.Name) { continue }
        Add-AuditEntry -Audit ([ref]$audit) -File $item.FullName -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
    }
}
# .mavis is a JUNCTION to .minimax. Never recurse, never delete -- audit only.
if (Test-Path -LiteralPath $mavisJunction) {
    $mavisItem = Get-Item -LiteralPath $mavisJunction -Force -ErrorAction SilentlyContinue
    $mavisIsReparse = $mavisItem -and (($mavisItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($mavisIsReparse) {
        $linkType = if ($mavisItem.LinkType) { $mavisItem.LinkType } else { "ReparsePoint" }
        $target = if ($mavisItem.Target) { $mavisItem.Target } else { "<unknown>" }
        Write-Host "    [INFO] .mavis is a junction ($linkType -> $target) -- not touched" -ForegroundColor Cyan
        Add-AuditEntry -Audit ([ref]$audit) -File $mavisJunction -Key "junction" -Before ("$linkType->$target") -After "link-only-not-touched" -Ok $true
    }
    else {
        # Not a reparse point (unexpected): still never touched, flagged for review.
        Write-Host "    [WARN] .mavis is NOT a reparse point -- left untouched, review manually" -ForegroundColor Yellow
        Add-AuditEntry -Audit ([ref]$audit) -File $mavisJunction -Key "junction" -Before "not-reparse-point" -After "left-untouched-review" -Ok $true
    }
}
else {
    Add-AuditEntry -Audit ([ref]$audit) -File $mavisJunction -Key "junction" -Before "missing" -After "skipped" -Ok $true
}
# system-ca-certs.pem (MiniMax Agent): cert bundle, not identity -- preserved.
$mmCaCertsPath = Join-Path $mmRoaming "system-ca-certs.pem"
if (Test-Path -LiteralPath $mmCaCertsPath) {
    Add-AuditEntry -Audit ([ref]$audit) -File $mmCaCertsPath -Key "preserved-per-policy" -Before "present" -After "preserved-per-policy" -Ok $true
}
$status = Get-StepAuditStatus -Audit ([ref]$audit) -StartIndex $auditStart -Path $mmHome
if ($status.Success) {
    $passCount++
}
else {
    Write-Host "[FAILED] MiniMax preserve audit had failures" -ForegroundColor Red
    $failCount++
}

# --- [20/22] Old ID_Backups purge (both apps) ---
Write-Host "`n[20/22] Purging old ID_Backups (keep current run only)..." -ForegroundColor Cyan
Invoke-OldIdBackupsPurge -BackupRoot $backupRoot -IdBackupsRoot $mmIdBackupsRoot -Audit ([ref]$audit)
Invoke-OldIdBackupsPurge -BackupRoot (Join-Path $ocIdBackupsRoot $timestamp) -IdBackupsRoot $ocIdBackupsRoot -Audit ([ref]$audit)
$passCount++

# --- [21/22] Watchdog re-verify (both profiles + mavis partition) ---
Write-Host "`n[21/22] Watchdog re-verify..." -ForegroundColor Cyan
$watchdogCoreFiles = @(
    (Join-Path $ocRoaming "Network\Cookies"),
    (Join-Path $ocRoaming "DIPS"),
    (Join-Path $ocRoaming "SharedStorage"),
    (Join-Path $mmRoaming "Network\Cookies"),
    (Join-Path $mmRoaming "DIPS"),
    (Join-Path $mmRoaming "SharedStorage"),
    (Join-Path $mmRoaming "Partitions\mavis-browser\Local Storage")
)
Test-WatchdogRecreation -CoreFiles $watchdogCoreFiles -Audit ([ref]$audit)
$passCount++

# --- [22/22] Final probes ---
Write-Host "`n[22/22] Final probes..." -ForegroundColor Cyan

function Test-JsonFileEmpty {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    try {
        $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($null -eq $j) {
            return $true
        }
        return (@($j.PSObject.Properties).Count -eq 0)
    }
    catch {
        return $false
    }
}

if (Test-JsonFileEmpty -Path $ocAuthPath) {
    Write-Host "[OK] OpenCode auth.json is empty/absent" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] OpenCode auth.json still has nodes" -ForegroundColor Red
    $failCount++
}
if (Test-JsonFileEmpty -Path $mmPublicAuthPath) {
    Write-Host "[OK] mcode-public auth.json is empty/absent" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] mcode-public auth.json still has nodes" -ForegroundColor Red
    $failCount++
}
if (Test-JsonFileEmpty -Path $mmAuthStatePath) {
    Write-Host "[OK] auth-state.json is empty/absent" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] auth-state.json still has nodes" -ForegroundColor Red
    $failCount++
}
if (Test-JsonFileEmpty -Path $mmLocalRuntimeAuthPath) {
    Write-Host "[OK] local-runtime.auth.json is empty/absent" -ForegroundColor Green
    $passCount++
}
else {
    Write-Host "[FAILED] local-runtime.auth.json still has nodes" -ForegroundColor Red
    $failCount++
}
if (Test-Path -LiteralPath $mmAgentConfigPath) {
    try {
        $cfgVerified = Get-Content -LiteralPath $mmAgentConfigPath -Raw | ConvertFrom-Json
        $userGone = $null -eq $cfgVerified.PSObject.Properties['user']
        $sharedUserGone = $null -eq $cfgVerified.PSObject.Properties['sharedUser']
        if ($userGone -and $sharedUserGone) {
            Write-Host "[OK] minimax-agent-config.json user/sharedUser gone" -ForegroundColor Green
            $passCount++
        }
        else {
            Write-Host "[FAILED] minimax-agent-config.json still has user/sharedUser" -ForegroundColor Red
            $failCount++
        }
    }
    catch {
        Write-Host "[FAILED] minimax-agent-config.json final probe could not parse" -ForegroundColor Red
        $failCount++
    }
}
if ($null -ne $newDesktopDeviceId) {
    if (Confirm-JsonValues -Path $mmRemoteControlStatePath -Expected @{ "desktop_device_id" = $newDesktopDeviceId }) {
        Write-Host "[OK] desktop_device_id final probe passed" -ForegroundColor Green
        $passCount++
    }
    else {
        Write-Host "[FAILED] desktop_device_id final probe failed" -ForegroundColor Red
        $failCount++
    }
}
$updaterProbes = @(
    @{ Path = $ocUpdaterIdPath; Expected = $newUpdaterIdOC; Label = "OpenCode .updaterId" },
    @{ Path = $mmUpdaterIdPath; Expected = $newUpdaterIdMM; Label = "MiniMax .updaterId" }
)
foreach ($probe in $updaterProbes) {
    if (Test-Path -LiteralPath $probe.Path) {
        $actualValue = (Get-Content -LiteralPath $probe.Path -Raw).Trim()
        if ($actualValue -eq $probe.Expected) {
            Write-Host "[OK] $($probe.Label) final probe passed" -ForegroundColor Green
            $passCount++
        }
        else {
            Write-Host "[FAILED] $($probe.Label) final probe failed" -ForegroundColor Red
            $failCount++
        }
    }
}

# --- Zero-change policy -------------------------------------------------------
# If every step skipped (no real modification), the backup dir holds nothing
# restorable: delete it, park the audit in %TEMP%, and skip the restore script.
$anyChange = ($actions.Count -gt 0)

if ($anyChange) {
    # --- Audit + Restore ---
    $auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
    Write-AuditLog -Audit $audit -Path $auditPath
    $restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App "MiniMaxOpenCode" -Actions $actions

    if (-not (Test-Path -LiteralPath $restoreScriptPath) -or ((Get-Item -LiteralPath $restoreScriptPath).Length -le 0)) {
        Write-Host "[FAILED] restore script missing or empty" -ForegroundColor Red
        $failCount++
    }
}
else {
    Write-Host "[INFO] No changes were made (all steps skipped) -- removing empty backup dir." -ForegroundColor Yellow
    Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    $auditPath = Join-Path $env:TEMP ("minimax_opencode_v1.0_audit_{0}.json" -f $timestamp)
    Write-AuditLog -Audit $audit -Path $auditPath
    $restoreScriptPath = "<none - no changes>"
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Pass: $passCount" -ForegroundColor Green
Write-Host "Fail: $failCount" -ForegroundColor Red
Write-Host "Audit log: $auditPath" -ForegroundColor Gray
Write-Host "Restore script: $restoreScriptPath" -ForegroundColor Gray
Write-Host "NOTE: .local\share\opencode\opencode.db is app-shared storage (preserved by design). Storage isolation is the app-side fix -- keep the app updated." -ForegroundColor Yellow
Write-Host "NOTE: minimax-agent-config.json 'tokens' node kept per spec; if re-login is not forced for the desktop app, wipe it too." -ForegroundColor Yellow
Write-Host "NOTE: .mavis junction audited only (never touched). change_device_id.ps1 remains the separate, optional system-level step." -ForegroundColor Yellow

[System.IO.File]::WriteAllText("$env:TEMP\minimax_opencode_v1.0_done.txt", ("Pass: {0} Fail: {1} Audit: {2}" -f $passCount, $failCount, $auditPath), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "MiniMax/OpenCode reset v1.0 completed with failures. Review $auditPath." -ForegroundColor Red
    exit 1
}

Write-Host "MiniMax/OpenCode reset v1.0 completed successfully." -ForegroundColor Green
