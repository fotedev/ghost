#Requires -Version 5.1
# AutoClaw Identity Reset v0.1
#
# GHOST-shaped identity reset for AutoClaw (Electron 33 desktop agent, install
# at C:\Program Files\AutoClaw). AutoClaw keeps TWO independent device
# identities plus one live operator credential (verified on this host,
# docs/AUTOCLAW_CLONES_SPEC.md sections 4/8):
#   - %APPDATA%\AutoClaw\auth.json             .deviceId (64-hex, backend id)
#   - %APPDATA%\AutoClaw\identity\device.json  ed25519 keypair + deviceId
#   - ~\.openclaw-autoclaw\devices\paired.json operator token (admin-scoped)
# This script rotates the first two and deletes the third (its own gateway
# regenerates it on next start), per target instance.
#
#   - -Target Primary -> %APPDATA%\AutoClaw + %USERPROFILE%\.openclaw-autoclaw
#   - -Target instN   -> %USERPROFILE%\AutoClawCloneHome\instN\{profile,home}
#   - -Target All     -> inst1 + inst2 + inst3 + inst4, then Primary
#                        (clones first, Primary last -- ZCode rule)
#
# PRESERVATION: auth.json .token/.refreshToken/.userInfo are never touched by
# the reset (a live login survives; token removal is a CLONE seed-scrub job in
# launch_autoclaw_clone.ps1). Chats/sessions/agents under the state dir are
# never wiped. token-cache.json / launch.json / official.json are out of scope
# for v0.1.
#
# UPDATER NOTE: settings.json .system.autoUpdate is forced to $false on EVERY
# target, Primary included. Any instance auto-updating would replace the
# patched app.asar (tools/patch_autoclaw_ports.ps1, A2) -- the port patch must
# be re-applied after a manual app update.
#
# PS 5.1 COMPAT: no [CmdletBinding()], no ternary, no $Input variable,
# RandomNumberGenerator via .GetBytes() only. No-BOM UTF-8 on every write.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File reset_autoclaw.ps1 [-Target Primary|inst1|inst2|inst3|inst4|All] [-DryRun]
# Prerequisite: close AutoClaw first (the script also force-kills it).
# Requirement: node on PATH (or the app-bundled node.exe) for ed25519 keygen.

param(
    [ValidateSet('Primary', 'inst1', 'inst2', 'inst3', 'inst4', 'All')][string]$Target = 'Primary',
    [switch]$DryRun
)

. "$PSScriptRoot\identity_utils.ps1"

$ErrorActionPreference = "Stop"

# --- Self-elevation -----------------------------------------------------------
# Re-launch elevated with the same script path when not already admin.
# Forwards -Target / -DryRun so child runs keep their scope after UAC.
$autoclawIsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $autoclawIsAdmin) {
    $autoclawScript = $MyInvocation.MyCommand.Path
    $autoclawFwd = " -Target $Target"
    if ($DryRun) { $autoclawFwd += " -DryRun" }
    # -File passes only declared switches; a redirect operator after -File is
    # just swallowed as an undeclared argument. The *_done.txt marker file
    # (not a log) is the persisted result channel - the elevated console shows
    # the full live output while the run progresses.
    $autoclawArgs = "-ExecutionPolicy Bypass -NoProfile -File `"$autoclawScript`"$autoclawFwd"
    Start-Process powershell -Verb RunAs -ArgumentList $autoclawArgs -WindowStyle Normal -Wait
    if (Test-Path -LiteralPath "$env:TEMP\autoclaw_v0.1_done.txt") {
        Get-Content -LiteralPath "$env:TEMP\autoclaw_v0.1_done.txt"
    }
    exit
}

Write-GhostBanner -Target "AutoClaw Identity Reset [$Target]" -Version "0.1"

# === Layout (frozen -- docs/AUTOCLAW_CLONES_SPEC.md section 3) =================

$script:CloneRoot = Join-Path $env:USERPROFILE "AutoClawCloneHome"
# Gateway preferred ports (spec section 6). The actual bound port may drift up
# to +9 (PORT_PROBE_RANGE) -- the launcher records the real one; this table is
# only what settings.json REQUESTS.
$script:GatewayPorts = @{
    "Primary" = 18789
    "inst1"   = 18799
    "inst2"   = 18810
    "inst3"   = 18821
    "inst4"   = 18832
}

function Get-TargetPaths {
    param([Parameter(Mandatory = $true)][string]$TargetName)
    if ($TargetName -eq "Primary") {
        return @{
            Roaming = Join-Path $env:APPDATA "AutoClaw"
            State   = Join-Path $env:USERPROFILE ".openclaw-autoclaw"
        }
    }
    $instRoot = Join-Path $script:CloneRoot $TargetName
    return @{
        Roaming = Join-Path $instRoot "profile"
        State   = Join-Path $instRoot "home\.openclaw-autoclaw"
    }
}

function Resolve-TargetList {
    param([Parameter(Mandatory = $true)][string]$TargetName)
    if ($TargetName -eq "All") {
        # Clones first, Primary last (AGENTS.md ZCode All-mode rule).
        return @("inst1", "inst2", "inst3", "inst4", "Primary")
    }
    return @($TargetName)
}

# === Local helpers ============================================================

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

function New-HexId64 {
    # Fresh 64-hex device id (auth.json / device.json .deviceId format),
    # crypto RNG via .GetBytes() (PS 5.1 safe; .Fill() is .NET Core only).
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object byte[] 32
        $rng.GetBytes($bytes)
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        if ($rng) { $rng.Dispose() }
    }
}

function Get-AutoClawNodeCommand {
    # Functional probe, never a bare Get-Command (AGENTS.md Python rule,
    # applied to node): the candidate must run --version and report v*.
    # Fallback: the app-bundled node.exe.
    $candidates = @()
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += "C:\Program Files\AutoClaw\resources\node\node.exe"
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $versionLine = & $candidate --version 2>$null
        }
        catch { continue }
        if ($LASTEXITCODE -eq 0 -and $versionLine -match "^v\d") {
            return $candidate
        }
    }
    return $null
}

function New-Ed25519KeypairJson {
    # Generates {version, deviceId, publicKeyPem, privateKeyPem, createdAtMs}
    # matching %APPDATA%\AutoClaw\identity\device.json's schema exactly:
    # SPKI PEM (113 chars) + PKCS8 PEM (119 chars), ed25519 -- verified live.
    # node:crypto is the generator (PS 5.1 cannot produce ed25519). The temp
    # .js lives in $env:TEMP, never next to the database file.
    param(
        [Parameter(Mandatory = $true)][string]$NodeExe,
        [Parameter(Mandatory = $true)][string]$DeviceId
    )

    $tempJs = Join-Path $env:TEMP ("autoclaw_keygen_" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".js")
    $js = @'
const { generateKeyPairSync, randomBytes } = require("crypto");
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
const out = {
  version: 1,
  deviceId: randomBytes(32).toString("hex"),
  publicKeyPem: publicKey.export({ type: "spki", format: "pem" }),
  privateKeyPem: privateKey.export({ type: "pkcs8", format: "pem" }),
  createdAtMs: Date.now()
};
process.stdout.write(JSON.stringify(out));
'@
    [System.IO.File]::WriteAllText($tempJs, $js, (New-Object System.Text.UTF8Encoding $false))
    try {
        $jsonText = & $NodeExe $tempJs 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "node keygen failed (exit $LASTEXITCODE)"
        }
        $keypair = $jsonText -join "" | ConvertFrom-Json
        if ($DeviceId) { $keypair.deviceId = $DeviceId }
        $pub = $keypair.publicKeyPem
        $priv = $keypair.privateKeyPem
        if (-not $pub -or -not $priv -or $pub.Length -ne 113 -or $priv.Length -ne 119) {
            throw ("keygen verify FAILED: PEM lengths {0}/{1} (expected 113/119)" -f $pub.Length, $priv.Length)
        }
        if (-not $keypair.deviceId -or $keypair.deviceId -notmatch "^[0-9a-f]{64}$") {
            throw "keygen verify FAILED: deviceId is not 64-hex"
        }
        return $keypair
    }
    finally {
        if (Test-Path -LiteralPath $tempJs) { Remove-Item -LiteralPath $tempJs -Force }
    }
}

function Resolve-JsonPropertyPath {
    # Walks a dotted path ("gateway.port") inside a parsed PSCustomObject.
    # Returns @{ Container = <obj>; Leaf = <lastSegment> }, or $null when a
    # segment is missing and -CreateMissing is off.
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$DottedPath,
        [switch]$CreateMissing
    )

    $segments = $DottedPath.Split('.')
    $current = $Root
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $segment = $segments[$i]
        if (Test-ObjectProperty -Object $current -Name $segment) {
            $next = $current.$segment
            if ($next -isnot [PSCustomObject]) {
                throw ("path segment '{0}' of '{1}' exists but is not an object" -f $segment, $DottedPath)
            }
            $current = $next
        }
        elseif ($CreateMissing) {
            $next = [pscustomobject]@{ }
            Add-Member -InputObject $current -NotePropertyName $segment -NotePropertyValue $next
            $current = $next
        }
        else {
            return $null
        }
    }
    return @{ Container = $current; Leaf = $segments[$segments.Count - 1] }
}

function Get-NestedJsonLeaf {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$DottedPath
    )
    $loc = Resolve-JsonPropertyPath -Root $Root -DottedPath $DottedPath
    if (-not $loc) { return $null }
    $leaf = $loc.Leaf
    if (Test-ObjectProperty -Object $loc.Container -Name $leaf) { return $loc.Container.$leaf }
    return $null
}

function Set-NestedJsonIdentity {
    # Set-JsonIdentity handles top-level keys only; AutoClaw's targets are
    # nested ("gateway.port", "update.checkOnStart"). Same contract as
    # Set-JsonIdentity: backup -> mutate -> no-BOM write -> verify-after
    # re-read -> one audit entry per key. Returns $true only if every key
    # re-read equals its new value.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Updates,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$BackupRoot,
        [string]$BackupLabel,
        [ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] JSON file not found: $Path" -ForegroundColor Red
        return $false
    }

    if ($BackupRoot -and $BackupLabel) {
        $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
        if ($backupPath) { Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath }
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $null -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] could not parse JSON: $Path" -ForegroundColor Red
        return $false
    }

    $beforeValues = @{ }
    try {
        foreach ($key in $Updates.Keys) {
            $beforeValues[$key] = Get-NestedJsonLeaf -Root $content -DottedPath $key
            $loc = Resolve-JsonPropertyPath -Root $content -DottedPath $key -CreateMissing
            $leaf = $loc.Leaf
            if (Test-ObjectProperty -Object $loc.Container -Name $leaf) {
                $loc.Container.$leaf = $Updates[$key]
            }
            else {
                Add-Member -InputObject $loc.Container -NotePropertyName $leaf -NotePropertyValue $Updates[$key]
            }
        }
    }
    catch {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $Updates[$key] -Ok $false
        }
        Write-Host ("[FAILED] nested key patch: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))

    try {
        $verifiedContent = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        foreach ($key in $Updates.Keys) {
            Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $Updates[$key] -Ok $false
        }
        Write-Host "[FAILED] could not re-read JSON after write: $Path" -ForegroundColor Red
        return $false
    }

    $allMatched = $true
    foreach ($key in $Updates.Keys) {
        $actualValue = Get-NestedJsonLeaf -Root $verifiedContent -DottedPath $key
        $ok = $actualValue -eq $Updates[$key]
        Add-AuditEntry -Audit $Audit -File $Path -Key $key -Before $beforeValues[$key] -After $actualValue -Ok $ok
        if (-not $ok) { $allMatched = $false }
    }

    return $allMatched
}

function Set-VerifiedTextFile {
    # No-BOM UTF-8 plain-text write + verify-after re-read (.updaterId shape).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [string]$BackupRoot,
        [string]$BackupLabel,
        [ref]$Actions
    )

    $beforeValue = $null
    if (Test-Path -LiteralPath $Path) {
        $beforeValue = (Get-Content -LiteralPath $Path -Raw).Trim()
        if ($BackupRoot -and $BackupLabel) {
            $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
            if ($backupPath) { Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath }
        }
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding $false))
    $afterValue = (Get-Content -LiteralPath $Path -Raw).Trim()
    $ok = $afterValue -eq $Value
    Add-AuditEntry -Audit $Audit -File $Path -Key "updaterId" -Before $beforeValue -After $afterValue -Ok $ok
    return $ok
}

function Remove-VerifiedBackedUpFile {
    # Backup -> delete -> verify-absent. Used for devices\paired.json (the
    # live operator credential): a reset must not leave it, and its own
    # gateway regenerates a fresh one at next start.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [Parameter(Mandatory = $true)][string]$BackupLabel,
        [ref]$Actions
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "[SKIP] $Path not present (nothing to scrub)" -ForegroundColor Yellow
        return $true
    }

    $backupPath = Backup-FileToTimestampDir -Source $Path -BackupRoot $BackupRoot -Label $BackupLabel
    if ($backupPath) { Add-ActionEntry -Actions $Actions -OriginalPath $Path -BackupPath $backupPath }
    Remove-Item -LiteralPath $Path -Force
    $absent = -not (Test-Path -LiteralPath $Path)
    Add-AuditEntry -Audit $Audit -File $Path -Key "paired.json delete" -Before "present" -After $(if ($absent) { "absent" } else { "STILL PRESENT" }) -Ok $absent
    if (-not $absent) {
        Write-Host "[FAILED] paired.json still present after delete: $Path" -ForegroundColor Red
    }
    return $absent
}

function Stop-AutoClawProcessesAggressive {
    param(
        [int]$MaxAttempts = 10,
        [int]$DelayMs = 1500
    )

    Write-Host "[*] Terminating all AutoClaw + gateway processes (aggressive tree-kill)..." -ForegroundColor Cyan

    $processesToKill = @("AutoClaw", "openclaw")
    $consecutiveClean = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        foreach ($processName in $processesToKill) {
            if (Get-Process -Name $processName -ErrorAction SilentlyContinue) {
                $null = & taskkill /F /T /IM "$processName.exe" 2>&1
            }
        }

        Start-Sleep -Milliseconds $DelayMs

        $count = @(Get-Process -Name "AutoClaw*" -ErrorAction SilentlyContinue).Count
        $count += @(Get-Process -Name "openclaw*" -ErrorAction SilentlyContinue).Count
        Write-Host "    attempt $attempt/$MaxAttempts - remaining processes: $count" -ForegroundColor DarkGray

        if ($count -eq 0) {
            $consecutiveClean++
            if ($consecutiveClean -ge 2) {
                Write-Host "[OK] all AutoClaw processes terminated (confirmed across 2 checks)" -ForegroundColor Green
                return $true
            }
        }
        else {
            $consecutiveClean = 0
        }
    }

    Write-Host "[FAILED] processes still running after $MaxAttempts attempts. Aborting reset." -ForegroundColor Red
    foreach ($p in @(Get-Process -Name "AutoClaw*" -ErrorAction SilentlyContinue)) {
        Write-Host ("    AutoClaw PID {0}: {1}" -f $p.Id, $p.Path) -ForegroundColor Red
    }
    return $false
}

function Invoke-TargetReset {
    # The per-target step sequence. Every step is backup -> mutate -> verify.
    # Audit/Actions arrive as [ref]s created in the caller's scope (mutation
    # must propagate); pass/fail counts are returned, never assigned across
    # scopes ($x++ inside a function only shadows the caller's variable).
    param(
        [Parameter(Mandatory = $true)][string]$TargetName,
        [Parameter(Mandatory = $true)][ref]$Audit,
        [Parameter(Mandatory = $true)][ref]$Actions,
        [Parameter(Mandatory = $true)][string]$BackupRoot,
        [string]$NodeExe
    )

    $targetPass = 0
    $targetFail = 0

    $paths = Get-TargetPaths -TargetName $TargetName
    $roaming = $paths.Roaming
    $state = $paths.State
    $gatewayPort = $script:GatewayPorts[$TargetName]

    Write-Host ""
    Write-Host ("=== Target: {0} ===" -f $TargetName) -ForegroundColor Cyan
    Write-Host ("  roaming: {0}" -f $roaming) -ForegroundColor DarkGray
    Write-Host ("  state:   {0}" -f $state) -ForegroundColor DarkGray
    Write-Host ("  gateway: {0}" -f $gatewayPort) -ForegroundColor DarkGray

    $targetPresent = Test-Path -LiteralPath $roaming
    if (-not $targetPresent) {
        Write-Host "[SKIP] roaming profile not found ($roaming) - instance never launched. Nothing to reset." -ForegroundColor Yellow
        return $true
    }

    $script:stepIndex = 0
    $totalSteps = 7

    # --- [1/7] auth.json .deviceId ------------------------------------------------
    $script:stepIndex++
    $authPath = Join-Path $roaming "auth.json"
    Write-Host ("`n[{0}/{1}] auth.json: rotate deviceId" -f $script:stepIndex, $totalSteps) -ForegroundColor White
    if (Test-Path -LiteralPath $authPath) {
        $newAuthDeviceId = New-HexId64
        if ($DryRun) {
            Write-Host ("  [DRY-RUN] would set deviceId -> {0}" -f $newAuthDeviceId) -ForegroundColor Yellow
            $step1Ok = $true
        }
        else {
            $step1Ok = Set-JsonIdentity -Path $authPath -Updates @{ "deviceId" = $newAuthDeviceId } `
                -Audit $Audit -BackupRoot $BackupRoot -BackupLabel "auth.json" -Actions $Actions
            if ($step1Ok) { Write-Host "[OK] auth.json deviceId rotated + verified" -ForegroundColor Green }
            else { Write-Host "[FAILED] auth.json deviceId not verified after write" -ForegroundColor Red }
        }
    }
    else {
        Write-Host "[SKIP] auth.json not present" -ForegroundColor Yellow
        $step1Ok = $true
    }
    if ($step1Ok) { $targetPass++ } else { $targetFail++ }

    # --- [2/7] identity\device.json: fresh ed25519 keypair + deviceId -------------
    $script:stepIndex++
    $deviceJsonPath = Join-Path $roaming "identity\device.json"
    Write-Host ("`n[{0}/{1}] identity\device.json: regenerate ed25519 keypair + deviceId" -f $script:stepIndex, $totalSteps) -ForegroundColor White
    if (Test-Path -LiteralPath $deviceJsonPath) {
        $newDeviceId = New-HexId64
        if ($DryRun) {
            Write-Host ("  [DRY-RUN] would regenerate keypair + set deviceId -> {0}" -f $newDeviceId) -ForegroundColor Yellow
            $step2Ok = $true
        }
        else {
            $keypair = $null
            $step2Ok = $false
            try {
                $keypair = New-Ed25519KeypairJson -NodeExe $NodeExe -DeviceId $newDeviceId
                $step2Ok = $true
            }
            catch {
                Write-Host ("[FAILED] keygen: {0}" -f $_.Exception.Message) -ForegroundColor Red
            }
            if ($step2Ok) {
                $step2Ok = Set-JsonIdentity -Path $deviceJsonPath -Updates @{
                    "version"       = 1
                    "deviceId"      = $keypair.deviceId
                    "publicKeyPem"  = $keypair.publicKeyPem
                    "privateKeyPem" = $keypair.privateKeyPem
                    "createdAtMs"   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                } -Audit $Audit -BackupRoot $BackupRoot -BackupLabel (Join-Path "identity" "device.json") -Actions $Actions
                if ($step2Ok) { Write-Host "[OK] device.json keypair + deviceId rotated + verified" -ForegroundColor Green }
                else { Write-Host "[FAILED] device.json not verified after write" -ForegroundColor Red }
            }
        }
    }
    else {
        Write-Host "[SKIP] identity\device.json not present" -ForegroundColor Yellow
        $step2Ok = $true
    }
    if ($step2Ok) { $targetPass++ } else { $targetFail++ }

    # --- [3/7] settings.json: gateway port + updater guard ------------------------
    $script:stepIndex++
    $settingsPath = Join-Path $roaming "settings.json"
    Write-Host ("`n[{0}/{1}] settings.json: gateway.port={2}, url, update.autoUpdate=false" -f $script:stepIndex, $totalSteps, $gatewayPort) -ForegroundColor White
    if (Test-Path -LiteralPath $settingsPath) {
        if ($DryRun) {
            Write-Host ("  [DRY-RUN] would set gateway.port -> {0}, gateway.url -> ws://127.0.0.1:{0}, system.autoUpdate -> False" -f $gatewayPort) -ForegroundColor Yellow
            $step3Ok = $true
        }
        else {
            $step3Ok = Set-NestedJsonIdentity -Path $settingsPath -Updates @{
                "gateway.port"      = $gatewayPort
                "gateway.url"       = "ws://127.0.0.1:$gatewayPort"
                "system.autoUpdate" = $false
            } -Audit $Audit -BackupRoot $BackupRoot -BackupLabel "settings.json" -Actions $Actions
            if ($step3Ok) { Write-Host "[OK] settings.json port + url + autoUpdate verified" -ForegroundColor Green }
            else { Write-Host "[FAILED] settings.json not verified after write" -ForegroundColor Red }
        }
    }
    else {
        Write-Host "[SKIP] settings.json not present" -ForegroundColor Yellow
        $step3Ok = $true
    }
    if ($step3Ok) { $targetPass++ } else { $targetFail++ }

    # --- [4/7] .updaterId: rotate --------------------------------------------------
    $script:stepIndex++
    $updaterIdPath = Join-Path $roaming ".updaterId"
    Write-Host ("`n[{0}/{1}] .updaterId: rotate GUID" -f $script:stepIndex, $totalSteps) -ForegroundColor White
    $newUpdaterId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
    if ($DryRun) {
        Write-Host ("  [DRY-RUN] would set .updaterId -> {0}" -f $newUpdaterId) -ForegroundColor Yellow
        $step4Ok = $true
    }
    else {
        $step4Ok = Set-VerifiedTextFile -Path $updaterIdPath -Value $newUpdaterId `
            -Audit $Audit -BackupRoot $BackupRoot -BackupLabel ".updaterId" -Actions $Actions
        if ($step4Ok) { Write-Host "[OK] .updaterId rotated + verified" -ForegroundColor Green }
        else { Write-Host "[FAILED] .updaterId not verified after write" -ForegroundColor Red }
    }
    if ($step4Ok) { $targetPass++ } else { $targetFail++ }

    # --- [5/7] openclaw.json: gateway.mode + update.checkOnStart -------------------
    $script:stepIndex++
    $openclawJsonPath = Join-Path $state "openclaw.json"
    Write-Host ("`n[{0}/{1}] openclaw.json: gateway.mode=local, update.checkOnStart=false" -f $script:stepIndex, $totalSteps) -ForegroundColor White
    if (Test-Path -LiteralPath $openclawJsonPath) {
        if ($DryRun) {
            Write-Host "  [DRY-RUN] would ensure gateway.mode=local + update.checkOnStart=false" -ForegroundColor Yellow
            $step5Ok = $true
        }
        else {
            $step5Ok = Set-NestedJsonIdentity -Path $openclawJsonPath -Updates @{
                "gateway.mode"        = "local"
                "update.checkOnStart" = $false
            } -Audit $Audit -BackupRoot $BackupRoot -BackupLabel (Join-Path "state" "openclaw.json") -Actions $Actions
            if ($step5Ok) { Write-Host "[OK] openclaw.json mode + checkOnStart verified" -ForegroundColor Green }
            else { Write-Host "[FAILED] openclaw.json not verified after write" -ForegroundColor Red }
        }
    }
    else {
        # instN before its first launch has no state dir yet -- legitimate skip.
        Write-Host "[SKIP] openclaw.json not present (state dir not created yet)" -ForegroundColor Yellow
        $step5Ok = $true
    }
    if ($step5Ok) { $targetPass++ } else { $targetFail++ }

    # --- [6/7] devices\paired.json: delete the live operator credential ------------
    $script:stepIndex++
    $pairedPath = Join-Path $state "devices\paired.json"
    Write-Host ("`n[{0}/{1}] devices\paired.json: backup + delete (gateway regenerates)" -f $script:stepIndex, $totalSteps) -ForegroundColor White
    if ($DryRun) {
        if (Test-Path -LiteralPath $pairedPath) {
            Write-Host "  [DRY-RUN] would back up + delete paired.json (live operator credential)" -ForegroundColor Yellow
        }
        else {
            Write-Host "  [DRY-RUN] paired.json not present - nothing to delete" -ForegroundColor Yellow
        }
        $step6Ok = $true
    }
    else {
        $step6Ok = $true
        if (Test-Path -LiteralPath $pairedPath) {
            $step6Ok = Remove-VerifiedBackedUpFile -Path $pairedPath -Audit $Audit `
                -BackupRoot $BackupRoot -BackupLabel (Join-Path "state" "devices\paired.json") -Actions $Actions
            if ($step6Ok) { Write-Host "[OK] paired.json deleted (will be regenerated on next start)" -ForegroundColor Green }
        }
        else {
            Write-Host "[SKIP] paired.json not present" -ForegroundColor Yellow
        }
    }
    if ($step6Ok) { $targetPass++ } else { $targetFail++ }

    # --- [7/7] final re-verify ------------------------------------------------------
    $script:stepIndex++
    Write-Host ("`n[{0}/{1}] final re-verify" -f $script:stepIndex, $totalSteps) -ForegroundColor White
    $step7Ok = $true
    if (-not $DryRun) {
        if (Test-Path -LiteralPath $pairedPath) {
            Write-Host "[FAILED] watchdog: paired.json was recreated during the run" -ForegroundColor Red
            $step7Ok = $false
        }
        $verifyAuth = Join-Path $roaming "auth.json"
        if (Test-Path -LiteralPath $verifyAuth) {
            $authEntries = @($Audit.Value | Where-Object { $_.file -eq $verifyAuth -and $_.key -eq "deviceId" })
            if ($authEntries.Count -gt 0 -and $authEntries[-1].ok -ne $true) {
                Write-Host "[FAILED] watchdog: auth.json deviceId audit entry not ok" -ForegroundColor Red
                $step7Ok = $false
            }
        }
        if ($step7Ok) { Write-Host "[OK] watchdog re-verify passed" -ForegroundColor Green }
    }
    else {
        Write-Host "  [DRY-RUN] watchdog re-verify skipped" -ForegroundColor Yellow
    }
    if ($step7Ok) { $targetPass++ } else { $targetFail++ }

    return [pscustomobject]@{ Pass = $targetPass; Fail = $targetFail }
}

# === Main ======================================================================

# node is required for the ed25519 keygen (step 2). Detect once, up front, so a
# missing interpreter fails the run instead of silently skipping the keypair.
$script:NodeExe = $null
if (-not $DryRun) {
    $script:NodeExe = Get-AutoClawNodeCommand
    if (-not $script:NodeExe) {
        Write-Host "[FAILED] node not found on PATH and no bundled node.exe - cannot regenerate identity\device.json. Install Node.js and re-run." -ForegroundColor Red
        exit 1
    }
    Write-Host "node for keygen: $script:NodeExe" -ForegroundColor DarkGray
}

if ($DryRun) {
    Write-Host "*** DRY RUN - no files will be modified ***" -ForegroundColor Yellow
}
else {
    if (-not (Stop-AutoClawProcessesAggressive)) {
        Write-Host "AutoClaw reset aborted (processes unkillable)." -ForegroundColor Red
        exit 1
    }
}

$targetList = Resolve-TargetList -TargetName $Target
$passCount = 0
$failCount = 0
$audit = @()
$actions = @()
$primaryBackupRoot = $null

foreach ($singleTarget in $targetList) {
    $paths = Get-TargetPaths -TargetName $singleTarget
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupRoot = Join-Path $paths.Roaming ("ID_Backups\" + $timestamp)
    if ($singleTarget -eq "Primary") { $primaryBackupRoot = $backupRoot }
    $audit = @()
    $actions = @()

    $result = Invoke-TargetReset -TargetName $singleTarget -Audit ([ref]$audit) -Actions ([ref]$actions) -BackupRoot $backupRoot -NodeExe $script:NodeExe
    $passCount += $result.Pass
    $failCount += $result.Fail

    if ($DryRun) { continue }

    # --- Audit + Restore per target ---
    $auditPath = Join-Path $backupRoot ("audit_{0}.json" -f $timestamp)
    Write-AuditLog -Audit $audit -Path $auditPath
    $restoreScriptPath = New-RestoreScript -BackupRoot $backupRoot -App "AutoClaw" -Actions $actions
    Write-Host ("Audit log: {0}" -f $auditPath) -ForegroundColor Gray
    Write-Host ("Restore script: {0}" -f $restoreScriptPath) -ForegroundColor Gray
}

if ($DryRun) {
    Write-Host "`n*** DRY RUN complete - no changes were made ***" -ForegroundColor Yellow
    [System.IO.File]::WriteAllText("$env:TEMP\autoclaw_v0.1_done.txt", "DryRun complete - no changes made", (New-Object System.Text.UTF8Encoding $false))
    exit 0
}

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Pass: $passCount" -ForegroundColor Green
Write-Host "Fail: $failCount" -ForegroundColor Red
Write-Host "NOTE: system.autoUpdate is now $false on every reset instance - any app update reverts the MCP port patch; re-run tools\patch_autoclaw_ports.ps1 after updating." -ForegroundColor Yellow
Write-Host "NOTE: deleting devices\paired.json means re-pairing clients (e.g. Hermes) on next start." -ForegroundColor Yellow

[System.IO.File]::WriteAllText("$env:TEMP\autoclaw_v0.1_done.txt", ("Pass: {0} Fail: {1}" -f $passCount, $failCount), (New-Object System.Text.UTF8Encoding $false))

if ($failCount -gt 0) {
    Write-Host "AutoClaw reset v0.1 [$Target] completed with failures." -ForegroundColor Red
    exit 1
}

Write-Host "AutoClaw reset v0.1 [$Target] completed successfully." -ForegroundColor Green
