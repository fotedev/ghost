#Requires -Version 5.1
# AutoClaw Clone Instance Launcher (inst1 / inst2 / inst3 / inst4)
#
# Launches a fully independent AutoClaw clone beside the Primary. Mechanism
# (reverse-engineered + live-verified, docs/AUTOCLAW_CLONES_SPEC.md):
#   - requestSingleInstanceLock() keys off the PROFILE DIR and this app HONOURS
#     --user-data-dir (unlike ZCode) -> per-clone --user-data-dir is the lock
#     separator; env vars are still the primary isolation lever (belt+braces).
#   - Gateway state moves with the HOME: the Electron main derives
#     ~/.openclaw-autoclaw from os.homedir(), and node's homedir() honours
#     USERPROFILE/HOME -> per-clone USERPROFILE+HOME moves the whole state tree.
#   - Gateway port: AUTOCLAW_GATEWAY_PORT is the supported override, but a busy
#     port silently shifts up to +9 -> the ACTUAL bound port is read back and
#     recorded, never assumed (no-silent-success).
#   - MCP port: hardcoded 4-slot array widened to 8 by tools\patch_autoclaw_ports.ps1
#     (marker-gated). inst4 has NO MCP slot without that patch.
#   - One credential = one instance: the seed copies the Primary profile but
#     strips every live credential (auth token, refreshToken, token-cache,
#     paired.json never copied). Each clone needs ONE manual login on first run.
#
# Launch instances SEQUENTIALLY, never in parallel (spec 6b). Do NOT run this
# elevated (UIPI; AGENTS.md ZCode rule applies equally here).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File launch_autoclaw_clone.ps1 [-Instance inst1|inst2|inst3|inst4] [-Status]

param(
    [ValidateSet('inst1', 'inst2', 'inst3', 'inst4')]
    [string]$Instance = 'inst1',
    [switch]$Status
)
$ErrorActionPreference = 'Stop'

# Portable paths: work for any Windows user, no hardcoded username.
$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$AppData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($AppData)) { $AppData = Join-Path $UserProfile 'AppData\Roaming' }

$AutoClawExeCandidates = @(
    'C:\Program Files\AutoClaw\AutoClaw.exe',
    'C:\Program Files (x86)\AutoClaw\AutoClaw.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw\AutoClaw.exe')
)
$AutoClawExe = $AutoClawExeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $AutoClawExe) { throw "AutoClaw.exe not found. Checked: $($AutoClawExeCandidates -join '; ')" }

$PrimaryProfile = Join-Path $AppData 'AutoClaw'          # %APPDATA%\AutoClaw (Electron profile)
$PrimaryState   = Join-Path $UserProfile '.openclaw-autoclaw'  # gateway state (never copied)
$CloneRoot      = Join-Path $UserProfile 'AutoClawCloneHome'

# Port plan (spec section 6). MCP ports are PRIMARY-DEPENDENT: instances grab
# the first FREE slot in start order, so the table's MCP port is only the
# EXPECTED value when the Primary (and earlier clones) run first. The launcher
# discovers the actual listening ports and records them.
$InstanceMap = @{
    'inst1' = @{ McpPort = 19682; GatewayPort = 18799 }
    'inst2' = @{ McpPort = 19683; GatewayPort = 18810 }
    'inst3' = @{ McpPort = 19684; GatewayPort = 18821 }
    'inst4' = @{ McpPort = 19685; GatewayPort = 18832 }
}
$cfg = $InstanceMap[$Instance]

$InstRoot       = Join-Path $CloneRoot $Instance
$CloneHome      = Join-Path $InstRoot 'home'     # USERPROFILE/HOME for this instance
$CloneProfile   = Join-Path $InstRoot 'profile'  # --user-data-dir target
$CloneTmp       = Join-Path $InstRoot 'tmp'      # TMPDIR/TEMP/TMP
$CloneState     = Join-Path $CloneHome '.openclaw-autoclaw'
# Strings that identify THIS clone's processes in any CommandLine.
$CloneMarkers   = @("*$CloneProfile*", "*$CloneHome*")

# === Local helpers (self-contained: no dot-sourcing of other scripts) =========

function New-HexId64 {
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
    # Functional probe (AGENTS.md Python rule applied to node): the candidate
    # must run --version and report v*. Fallback: the app-bundled node.exe.
    $candidates = @()
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += (Join-Path (Split-Path -Parent $AutoClawExe) 'resources\node\node.exe')
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try { $versionLine = & $candidate --version 2>$null } catch { continue }
        if ($LASTEXITCODE -eq 0 -and $versionLine -match "^v\d") { return $candidate }
    }
    return $null
}

function New-Ed25519KeypairJson {
    # Fresh ed25519 keypair matching identity\device.json's schema
    # (SPKI 113 chars + PKCS8 119 chars, verified live). Temp .js in TEMP only.
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
        if ($LASTEXITCODE -ne 0) { throw "node keygen failed (exit $LASTEXITCODE)" }
        $keypair = ($jsonText -join "") | ConvertFrom-Json
        if ($DeviceId) { $keypair.deviceId = $DeviceId }
        if ($keypair.publicKeyPem.Length -ne 113 -or $keypair.privateKeyPem.Length -ne 119) {
            throw ("keygen verify FAILED: PEM lengths {0}/{1} (expected 113/119)" -f $keypair.publicKeyPem.Length, $keypair.privateKeyPem.Length)
        }
        if ($keypair.deviceId -notmatch "^[0-9a-f]{64}$") { throw "keygen verify FAILED: deviceId is not 64-hex" }
        return $keypair
    }
    finally {
        if (Test-Path -LiteralPath $tempJs) { Remove-Item -LiteralPath $tempJs -Force }
    }
}

function Resolve-JsonPropertyPath {
    param(
        [Parameter(Mandatory = $true)]$Root,
        [Parameter(Mandatory = $true)][string]$DottedPath,
        [switch]$CreateMissing
    )
    $segments = $DottedPath.Split('.')
    $current = $Root
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $segment = $segments[$i]
        if ($null -ne $current.PSObject.Properties[$segment]) {
            $next = $current.$segment
            if ($next -isnot [PSCustomObject]) { throw ("path segment '{0}' of '{1}' is not an object" -f $segment, $DottedPath) }
            $current = $next
        }
        elseif ($CreateMissing) {
            $next = [pscustomobject]@{ }
            Add-Member -InputObject $current -NotePropertyName $segment -NotePropertyValue $next
            $current = $next
        }
        else { return $null }
    }
    return @{ Container = $current; Leaf = $segments[$segments.Count - 1] }
}

function Set-NestedJsonVerified {
    # backup -> mutate dotted keys -> no-BOM write -> verify-after re-read.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Updates,
        [string]$BackupPath
    )
    if ($BackupPath) {
        $parent = Split-Path -Path $BackupPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
        Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    }
    $content = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($key in $Updates.Keys) {
        $loc = Resolve-JsonPropertyPath -Root $content -DottedPath $key -CreateMissing
        $leaf = $loc.Leaf
        if ($null -ne $loc.Container.PSObject.Properties[$leaf]) { $loc.Container.$leaf = $Updates[$key] }
        else { Add-Member -InputObject $loc.Container -NotePropertyName $leaf -NotePropertyValue $Updates[$key] }
    }
    [System.IO.File]::WriteAllText($Path, ($content | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
    $verify = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $allOk = $true
    foreach ($key in $Updates.Keys) {
        $loc = Resolve-JsonPropertyPath -Root $verify -DottedPath $key
        $actual = $null
        if ($loc -and ($null -ne $loc.Container.PSObject.Properties[$loc.Leaf])) { $actual = $loc.Container.($loc.Leaf) }
        if ($actual -ne $Updates[$key]) { $allOk = $false }
    }
    return $allOk
}

function Get-CloneSubtreePids {
    # Candidate roots + TREE-LEVEL attribution. PROCESS MARKERS first (the ZCode
    # lesson), hardened after the live 2026-10-15 verify miss (a running clone
    # that cmdline classification failed to see for its whole 30s window):
    #   - empty-cmdline AutoClaw.exe mains are CANDIDATES (WMI race - the ZCode
    #     rule), attributed only via evidence below; the Primary can never carry
    #     a clone marker, so a raced Primary tree cannot be misattributed.
    #   - marker match is TREE-LEVEL: a main whose own CommandLine lost the flag
    #     is still ours when any descendant carries it.
    #   - NewPids (pids that appeared after OUR launch) attribute their tree.
    param(
        [string[]]$Markers,
        [int[]]$NewPids = @()
    )

    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $byId = @{ }
    $byParent = @{ }
    foreach ($p in $all) {
        $pidInt = [int]$p.ProcessId
        $byId[$pidInt] = $p
        $ppid = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $p
    }

    $candidates = @($all | Where-Object {
        $procCmd = [string]$_.CommandLine
        $_.Name -eq "AutoClaw.exe" -and (
            [string]::IsNullOrWhiteSpace($procCmd) -or
            (($Markers | Where-Object { $procCmd -like $_ }) -ne $null) -or
            ($NewPids -contains [int]$_.ProcessId))
    })

    if ($candidates.Count -eq 0) { return @() }

    $result = New-Object "System.Collections.Generic.HashSet[int]"
    foreach ($c in $candidates) {
        $rootId = [int]$c.ProcessId
        if ($result.Contains($rootId)) { continue }

        $members = New-Object "System.Collections.Generic.HashSet[int]"
        [void]$members.Add($rootId)
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue($rootId)
        while ($queue.Count -gt 0) {
            $id = [int]$queue.Dequeue()
            if (-not $byParent.ContainsKey($id)) { continue }
            foreach ($child in $byParent[$id]) {
                $cid = [int]$child.ProcessId
                if ($members.Add($cid)) { $queue.Enqueue($cid) }
            }
        }

        $attributed = ($NewPids -contains $rootId)
        if (-not $attributed) {
            foreach ($m in $members) {
                $proc = $byId[$m]
                if (-not $proc) { continue }
                $procCmd = [string]$proc.CommandLine
                if (-not [string]::IsNullOrWhiteSpace($procCmd) -and
                    (($Markers | Where-Object { $procCmd -like $_ }) -ne $null)) {
                    $attributed = $true
                    break
                }
            }
        }
        if ($attributed) {
            foreach ($m in $members) { [void]$result.Add($m) }
        }
    }
    return @($result)
}

function Test-ProfileLockHeld {
    # WMI-independent liveness evidence: Chromium holds profile\lockfile with no
    # sharing, so an exclusive open fails ONLY while a live instance owns it.
    # The file REMAINS on disk after an unclean exit (verified 2026-10-15), so
    # existence proves nothing - the open attempt is the signal.
    param([string]$ProfileDir)
    $lockPath = Join-Path $ProfileDir 'lockfile'
    if (-not (Test-Path -LiteralPath $lockPath)) { return $false }
    try {
        $fs = [System.IO.File]::Open($lockPath, 'Open', 'Read', 'None')
        if ($fs) { $fs.Close() }
        return $false
    }
    catch { return $true }
}

function Get-CloneListeningPorts {
    param(
        [int[]]$SubtreePids,
        [int]$MinPort,
        [int]$MaxPort
    )
    if ($SubtreePids.Count -eq 0) { return @() }
    try {
        $ports = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -ge $MinPort -and $_.LocalPort -le $MaxPort -and ($SubtreePids -contains $_.OwningProcess) } |
            Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
        return $ports
    }
    catch { return @() }
}

function Test-HttpHealth {
    param([int]$Port, [int]$TimeoutSec = 3)
    try {
        $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/health" -f $Port) -UseBasicParsing -TimeoutSec $TimeoutSec
        return @{ Ok = $true; Body = $resp.Content }
    }
    catch { return @{ Ok = $false; Body = $_.Exception.Message } }
}

function Get-JsonMemberValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

# === -Status mode (read-only) ==================================================

if ($Status) {
    $markerPath = Join-Path (Split-Path -Parent $AutoClawExe) 'resources\autoclaw-ports-patch.marker.json'
    Write-Host "=== AutoClaw clones status ===" -ForegroundColor Cyan
    Write-Host ("Exe: {0}" -f $AutoClawExe)
    Write-Host ("MCP port patch: {0}" -f $(if (Test-Path -LiteralPath $markerPath) { "APPLIED ($(Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json | ForEach-Object { 'engine v' + $_.patchVersion }))" } else { "NOT APPLIED (max 3 clones with distinct MCP slots)" }))
    foreach ($name in @('inst1', 'inst2', 'inst3', 'inst4')) {
        $row = $InstanceMap[$name]
        $root = Join-Path $CloneRoot $name
        $homeDir = Join-Path $root 'home'
        $prof = Join-Path $root 'profile'
        Write-Host ""
        Write-Host ("--- {0} (gateway req {1}) ---" -f $name, $row.GatewayPort) -ForegroundColor White
        Write-Host ("  profile exists: {0}" -f (Test-Path -LiteralPath (Join-Path $prof 'auth.json')))
        $pids = Get-CloneSubtreePids -Markers @("*$prof*", "*$homeDir*")
        Write-Host ("  processes: {0}" -f $(if ($pids.Count) { $pids -join "," } else { "not running" }))
        if ($pids.Count) {
            $mcp = Get-CloneListeningPorts -SubtreePids $pids -MinPort 19681 -MaxPort 19688
            $gw = Get-CloneListeningPorts -SubtreePids $pids -MinPort $row.GatewayPort -MaxPort ($row.GatewayPort + 9)
            foreach ($port in @($mcp + $gw)) {
                $h = Test-HttpHealth -Port $port
                Write-Host ("  listening {0}: /health {1}" -f $port, $(if ($h.Ok) { "OK " + $h.Body } else { "FAIL (" + $h.Body + ")" }))
            }
            if (($mcp.Count + $gw.Count) -eq 0) { Write-Host "  no MCP/gateway ports found in expected ranges" -ForegroundColor Yellow }
        }
        $recordPath = Join-Path $root 'instance-record.json'
        if (Test-Path -LiteralPath $recordPath) {
            $rec = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
            Write-Host ("  last record: mcp={0} gateway={1} (requested {2}) at {3}" -f $rec.actualMcpPort, $rec.actualGatewayPort, $rec.requestedGatewayPort, $rec.launchedAt)
        }
    }
    exit 0
}

# === Launch flow ================================================================

if (-not (Test-Path -LiteralPath (Join-Path $PrimaryProfile 'auth.json'))) {
    throw "Primary AutoClaw profile not found ($PrimaryProfile\auth.json). Launch the Primary once first."
}

foreach ($dir in @($InstRoot, $CloneHome, $CloneProfile, $CloneTmp)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$NodeExe = $null
# Seed-completion marker, written only AFTER the full seed+scrub verified.
# needsSeed keyed on auth.json alone let an aborted robocopy's PARTIAL profile
# (auth.json present, stores inconsistent) pass as seeded and launch broken -
# verified live 2026-10-15 (app died within seconds on a half-copied profile).
$seedMarker = Join-Path $CloneHome '.autoclaw-seeded'
$reconMarker = Join-Path $CloneHome '.autoclaw-credentials-reconciled'
$needsSeed = -not (Test-Path -LiteralPath $seedMarker)

# Is this clone already running? Re-launching focuses the existing window and
# exits (single-instance lock is keyed on the profile dir) - report, don't relaunch.
$runningPids = Get-CloneSubtreePids -Markers $CloneMarkers
if ($runningPids.Count -gt 0) {
    Write-Host "[launch] $Instance already running (pids: $($runningPids -join ', ')) - nothing to do."
    Write-Host "         Use -Status for ports, or reset_autoclaw.ps1 -Target $Instance to reset it."
    exit 0
}

# 1) One-time seed: copy the Primary profile so the clone opens with the user's
#    chats/projects. Credential stores are EXCLUDED - one credential = one
#    instance (spec section 8 outranks the section 7.2 exclude list: the live
#    token/refreshToken live in token-cache.json and *.backup files too).
if ($needsSeed) {
    # The first-run seed copies a live Chromium profile - leveldb LOCK files and
    # open databases CANNOT be copied while the Primary runs (robocopy exit >= 8,
    # verified live 2026-10-15). Mirror the resetters: first run requires the
    # Primary closed; later launches (profile exists) never hit this path.
    $primaryProcs = @(Get-Process -Name AutoClaw -ErrorAction SilentlyContinue)
    if ($primaryProcs.Count -gt 0) {
        Write-Host "[seed] AutoClaw is running - the FIRST-RUN seed needs it closed (locked profile files)." -ForegroundColor Yellow
        Write-Host "[seed] Waiting up to 180s for AutoClaw to close (later launches do not need this)..."
        for ($i = 0; $i -lt 36; $i++) {
            Start-Sleep -Seconds 5
            if (-not (Get-Process -Name AutoClaw -ErrorAction SilentlyContinue)) { break }
        }
        if (@(Get-Process -Name AutoClaw -ErrorAction SilentlyContinue).Count -gt 0) {
            throw "[seed] AutoClaw still running. Close it and re-run the launcher (first run only)."
        }
        Start-Sleep -Seconds 3   # let file handles release
    }
    # A partial profile from an aborted earlier seed is never a working profile
    # (needsSeed = no auth.json) - clear it so robocopy starts clean, and drop
    # the reconcile marker with it so the next run's state is coherent.
    if (Test-Path -LiteralPath $CloneProfile) {
        Write-Host "[seed] Clearing partial profile from an aborted earlier seed..."
        Remove-Item -LiteralPath $CloneProfile -Recurse -Force
    }
    if (Test-Path -LiteralPath $reconMarker) { Remove-Item -LiteralPath $reconMarker -Force }
    Write-Host "[seed] First run for ${Instance}: cloning Primary profile -> $CloneProfile (excluding live locks)..."
    robocopy $PrimaryProfile $CloneProfile /E `
        /XD 'logs' 'Cache' 'Code Cache' 'GPUCache' 'DawnGraphiteCache' 'DawnWebGPUCache' `
        /XF '*.log' 'lockfile' 'LOCK' 'auth.json.backup' 'token-cache.json' 'token-cache.json.backup' 'settings.json.backup*' | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Remove-Item -LiteralPath $CloneProfile -Recurse -Force -ErrorAction SilentlyContinue
        throw "[seed] robocopy failed with exit code $LASTEXITCODE -- partial profile removed; close AutoClaw and re-run"
    }
    # Remove copied SQLite journals so the clone starts from a consistent checkpoint
    Get-ChildItem -Path $CloneProfile -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-shm' -or $_.Name -like '*-wal' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Write-Host "[seed] Clone complete. The gateway state tree ($CloneState) is NOT copied - fresh identity."
    if (-not (Test-Path -LiteralPath (Join-Path $CloneProfile 'auth.json'))) {
        throw "[seed] verify FAILED: seed profile has no auth.json - aborting before launch"
    }
}

# 2) Seed-scrub: rotate every identity-bearing value, keep the history, carry no
#    live credential. Verify-after re-read on each write.
if ($needsSeed) {
    Write-Host "[seed-scrub] Rotating cloned identity values (fresh independent IDs)..." -ForegroundColor Cyan
    if (-not $NodeExe) { $NodeExe = Get-AutoClawNodeCommand }
    if (-not $NodeExe) { throw "node not found on PATH and no bundled node.exe - cannot regenerate identity\device.json" }

    # 2a) auth.json: fresh deviceId; token/refreshToken REMOVED (keep userInfo
    #     so the clone opens on the account and prompts for login).
    $authPath = Join-Path $CloneProfile 'auth.json'
    $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    $newAuthId = New-HexId64
    $auth.deviceId = $newAuthId
    $hadToken = ($null -ne (Get-JsonMemberValue $auth 'token')) -or ($null -ne (Get-JsonMemberValue $auth 'refreshToken'))
    foreach ($k in @('token', 'refreshToken')) {
        if ($null -ne $auth.PSObject.Properties[$k]) { $null = $auth.PSObject.Properties.Remove($k) }
    }
    [System.IO.File]::WriteAllText($authPath, ($auth | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
    $authVerify = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    if ($authVerify.deviceId -ne $newAuthId) { throw "[seed-scrub] verify FAILED: auth.json deviceId not rotated" }
    if (($null -ne (Get-JsonMemberValue $authVerify 'token')) -or ($null -ne (Get-JsonMemberValue $authVerify 'refreshToken'))) {
        throw "[seed-scrub] verify FAILED: auth.json still carries a live token"
    }
    Write-Host ("[seed-scrub] auth.json deviceId rotated; token/refreshToken removed ({0}) - one manual login required." -f $(if ($hadToken) { "Primary token dropped" } else { "none present" })) -ForegroundColor Green

    # 2b) identity\device.json: fresh ed25519 keypair + deviceId (the backend
    #     pins the public key for pairing - regenerating makes the clone a
    #     distinct device, not a lookalike).
    $deviceJsonPath = Join-Path $CloneProfile 'identity\device.json'
    if (Test-Path -LiteralPath $deviceJsonPath) {
        $keypair = New-Ed25519KeypairJson -NodeExe $NodeExe -DeviceId (New-HexId64)
        $ok = Set-NestedJsonVerified -Path $deviceJsonPath -Updates @{
            "version"       = 1
            "deviceId"      = $keypair.deviceId
            "publicKeyPem"  = $keypair.publicKeyPem
            "privateKeyPem" = $keypair.privateKeyPem
            "createdAtMs"   = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        } -BackupPath (Join-Path $CloneProfile 'identity\device.json.preseed')
        if (-not $ok) { throw "[seed-scrub] verify FAILED: identity\device.json not verified after write" }
        Write-Host "[seed-scrub] identity\device.json keypair + deviceId rotated + verified." -ForegroundColor Green
    }

    # 2c) .updaterId: electron-updater install telemetry identity.
    $updPath = Join-Path $CloneProfile '.updaterId'
    if (Test-Path -LiteralPath $updPath) {
        $newUpdaterId = ([guid]::NewGuid().ToString()).ToLowerInvariant()
        [System.IO.File]::WriteAllText($updPath, $newUpdaterId, (New-Object System.Text.UTF8Encoding $false))
        if ((Get-Content -LiteralPath $updPath -Raw).Trim() -ne $newUpdaterId) {
            throw "[seed-scrub] verify FAILED: .updaterId not rotated"
        }
        Write-Host "[seed-scrub] .updaterId rotated + verified." -ForegroundColor Green
    }

    # 2d) settings.json: this instance's gateway port + updater guard (any
    #     instance auto-updating would replace the patched app.asar).
    $setPath = Join-Path $CloneProfile 'settings.json'
    if (Test-Path -LiteralPath $setPath) {
        $ok = Set-NestedJsonVerified -Path $setPath -Updates @{
            "gateway.port"      = $cfg.GatewayPort
            "gateway.url"       = "ws://127.0.0.1:$($cfg.GatewayPort)"
            "system.autoUpdate" = $false
        } -BackupPath (Join-Path $CloneProfile 'settings.json.preseed')
        if (-not $ok) { throw "[seed-scrub] verify FAILED: settings.json port/autoUpdate not verified after write" }
        Write-Host ("[seed-scrub] settings.json gateway={0} + autoUpdate=false verified." -f $cfg.GatewayPort) -ForegroundColor Green
    }

    # 2e) token-cache copies are excluded by the seed itself; double-check none
    #     slipped in (an older seed ran without the exclusion).
    foreach ($stale in @('token-cache.json', 'token-cache.json.backup', 'auth.json.backup')) {
        $stalePath = Join-Path $CloneProfile $stale
        if (Test-Path -LiteralPath $stalePath) {
            Remove-Item -LiteralPath $stalePath -Force
            Write-Host ("[seed-scrub] deleted stale credential copy: {0}" -f $stale) -ForegroundColor Yellow
        }
    }

    # Seed complete - only now is the profile allowed to count as seeded.
    New-Item -ItemType File -Path $seedMarker -Force | Out-Null
    if (-not (Test-Path -LiteralPath $seedMarker)) { throw "[seed] verify FAILED: seed marker not written" }
}
else {
    Write-Host "[seed] $Instance profile already seeded, skipping clone (independent)."
}

# 3) Marker-guarded one-time credential reconciliation: if this profile was
#    re-seeded or hand-copied from the Primary AFTER the initial scrub, it would
#    carry the PRIMARY's live token. Runs once ever per instance (ZCode
#    telegram-route rule) so a later deliberate login is never reverted.
if (Test-Path -LiteralPath $reconMarker) {
    Write-Host '[reconcile] Already reconciled, skipping.' -ForegroundColor DarkGray
}
else {
    $cloneAuthPath = Join-Path $CloneProfile 'auth.json'
    $primaryAuthPath = Join-Path $PrimaryProfile 'auth.json'
    if ((Test-Path -LiteralPath $cloneAuthPath) -and (Test-Path -LiteralPath $primaryAuthPath)) {
        $cloneAuth = Get-Content -LiteralPath $cloneAuthPath -Raw | ConvertFrom-Json
        $primaryAuth = Get-Content -LiteralPath $primaryAuthPath -Raw | ConvertFrom-Json
        $cloneToken = Get-JsonMemberValue $cloneAuth 'token'
        $primaryToken = Get-JsonMemberValue $primaryAuth 'token'
        if ($cloneToken -and $primaryToken -and ($cloneToken -eq $primaryToken)) {
            foreach ($k in @('token', 'refreshToken')) {
                if ($null -ne $cloneAuth.PSObject.Properties[$k]) { $null = $cloneAuth.PSObject.Properties.Remove($k) }
            }
            [System.IO.File]::WriteAllText($cloneAuthPath, ($cloneAuth | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
            $check = Get-Content -LiteralPath $cloneAuthPath -Raw | ConvertFrom-Json
            if ((Get-JsonMemberValue $check 'token') -or (Get-JsonMemberValue $check 'refreshToken')) {
                throw "[reconcile] verify FAILED: primary token still present in clone auth.json"
            }
            Write-Host "[reconcile] Clone carried the PRIMARY's live token - removed. Manual login required." -ForegroundColor Yellow
        }
        else {
            Write-Host "[reconcile] No shared credential found; nothing to do." -ForegroundColor DarkGray
        }
    }
    New-Item -ItemType File -Path $reconMarker -Force | Out-Null
}

# 4) Patch-state warning: inst4 has no MCP slot at all without the port patch.
$AsarMarker = Join-Path (Split-Path -Parent $AutoClawExe) 'resources\autoclaw-ports-patch.marker.json'
if (-not (Test-Path -LiteralPath $AsarMarker)) {
    Write-Host '[ports] NOTE: installed app.asar is NOT patched - distinct MCP slots cap at 3 clones,' -ForegroundColor Yellow
    Write-Host '        and inst4 has no MCP port. Close AutoClaw, run tools\patch_autoclaw_ports.ps1, relaunch.' -ForegroundColor Yellow
}

# 4b) State-dir override MARKER FILE. AutoClaw.exe's manifest declares
#     requireAdministrator: every launch self-elevates, and the elevated
#     process gets a FRESH ENVIRONMENT (verified live 2026-10-16 - env-based
#     isolation silently no-ops). --user-data-dir SURVIVES elevation, so the
#     patched app (engine v5) reads <userData>\.autoclaw-home for the clone
#     home. Write it fresh on every launch + verify-after re-read.
$homeMarker = Join-Path $CloneProfile '.autoclaw-home'
[System.IO.File]::WriteAllText($homeMarker, $CloneHome, (New-Object System.Text.UTF8Encoding $false))
$homeMarkerRead = (Get-Content -LiteralPath $homeMarker -Raw).Trim()
if ($homeMarkerRead -ne $CloneHome) {
    throw "[launch] verify FAILED: .autoclaw-home marker holds '$homeMarkerRead', expected '$CloneHome'"
}
Write-Host "[launch] .autoclaw-home marker verified -> $CloneHome" -ForegroundColor Green

# 5) Isolation proof baseline: the Primary's gateway config must not change.
$primaryHashBefore = $null
if (Test-Path -LiteralPath (Join-Path $PrimaryState 'openclaw.json')) {
    $primaryHashBefore = (Get-FileHash -LiteralPath (Join-Path $PrimaryState 'openclaw.json') -Algorithm SHA256).Hash
}

# 6) Launch detached. AutoClaw attaches to the parent console for stdout
#    logging (AGENTS.md .bat rules) - route through cmd /c start "" so there is
#    no console to hijack. Env vars ride the powershell -> cmd -> exe chain.
$env:USERPROFILE = $CloneHome
$env:HOME = $CloneHome
$env:TEMP = $CloneTmp
$env:TMP = $CloneTmp
$env:TMPDIR = $CloneTmp
$env:AUTOCLAW_GATEWAY_PORT = [string]$cfg.GatewayPort
# The state-dir isolation lever. USERPROFILE/HOME are NOT honoured by the app's
# main (its homedir() resolves the real Windows profile - verified live
# 2026-10-16), so the asar patch (engine v2, home-override) makes every
# homedir() site prefer AUTOCLAW_HOME_DIR. Without the patch the gateway state
# silently lands in the PRIMARY's ~/.openclaw-autoclaw.
$env:AUTOCLAW_HOME_DIR = $CloneHome

Write-Host "[launch] HOME=$env:USERPROFILE"
Write-Host "[launch] profile=$CloneProfile"
Write-Host "[launch] AUTOCLAW_GATEWAY_PORT=$env:AUTOCLAW_GATEWAY_PORT (may drift up to +9 - reading back the actual port)"

# pid-diff baseline: any AutoClaw.exe appearing after this point is OUR launch
# (sequential-launch rule guarantees no concurrent clone spawn).
# Get-Process (toolhelp32) is the RELIABLE pid source: Win32_Process
# intermittently omits AutoClaw.exe ENTIRELY - verified live 2026-10-16, a
# healthy main invisible to WMI snapshots minutes after start (this is the
# same failure class as the ZCode empty-CommandLine race, one level worse).
$beforePids = @(Get-Process -Name AutoClaw -ErrorAction SilentlyContinue |
    ForEach-Object { [int]$_.Id })
# -Verb RunAs: AutoClaw.exe's manifest declares requireAdministrator, so a
# non-elevated `start` hits the ERROR_ELEVATION_REQUIRED ShellExecute fallback,
# which launches the elevated process with a FRESH ENV *and* NO ARGUMENTS
# (verified live 2026-10-16 via PEB reads: every AutoClaw.exe ran with a bare
# command line). Elevating the launching cmd instead makes start's
# ShellExecute a plain CreateProcess - arguments survive. The app is elevated
# either way (its own manifest); UAC is silent for admin accounts with
# ConsentPromptBehaviorAdmin=0.
$null = Start-Process -FilePath "$env:ComSpec" -ArgumentList '/c', 'start', '""', "`"$AutoClawExe`"", "`"--user-data-dir=`"$CloneProfile`"" -Verb RunAs -WindowStyle Hidden

# 7) Verify-after-launch - the no-silent-success core.
# 7a) Liveness via three independent evidence channels (hardened after the
#     2026-10-15 miss where a live clone went unseen for the whole poll window):
#     attributed process tree (tree-level markers + pid-diff), or the profile
#     lockfile held open (WMI-independent).
$subtree = @()
$livenessEvidence = ""
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 1
    $nowPids = @(Get-Process -Name AutoClaw -ErrorAction SilentlyContinue |
        ForEach-Object { [int]$_.Id })
    $newPids = @($nowPids | Where-Object { $beforePids -notcontains $_ })
    $subtree = Get-CloneSubtreePids -Markers $CloneMarkers -NewPids $newPids
    if ($subtree.Count -gt 0) {
        $livenessEvidence = "attributed process tree, $($subtree.Count) pids"
        break
    }
    if ($newPids.Count -gt 0) {
        # WMI cmdline data unavailable (flap) but new AutoClaw pids exist - good
        # enough for liveness; ports fall back to the unattributed scan.
        $subtree = $newPids
        $livenessEvidence = "new AutoClaw pids after launch ($($newPids.Count)); WMI tree unavailable"
        break
    }
    if (Test-ProfileLockHeld -ProfileDir $CloneProfile) {
        $livenessEvidence = "profile lockfile held (process tree unresolved by WMI)"
        break
    }
}
if (-not $livenessEvidence) {
    Write-Host "[verify] FAILED - no liveness evidence within 60s (no attributed process tree, lockfile not held)." -ForegroundColor Red
    Write-Host "         Check $CloneProfile\logs or launch manually: `"$AutoClawExe`" --user-data-dir=`"$CloneProfile`"" -ForegroundColor Red
    exit 1
}
Write-Host "[verify] instance live: $livenessEvidence" -ForegroundColor Green
Start-Sleep -Seconds 5
$nowPids = @(Get-Process -Name AutoClaw -ErrorAction SilentlyContinue |
    ForEach-Object { [int]$_.Id })
$newPids = @($nowPids | Where-Object { $beforePids -notcontains $_ })
$subtreeAfter = @(Get-CloneSubtreePids -Markers $CloneMarkers -NewPids $newPids)
if ($subtreeAfter.Count -eq 0 -and $newPids.Count -gt 0) { $subtreeAfter = $newPids }
$stillLive = ($subtreeAfter.Count -gt 0) -or (Test-ProfileLockHeld -ProfileDir $CloneProfile)
if (-not $stillLive) {
    Write-Host "[verify] FAILED - instance died within 5s of liveness (crash on startup?)." -ForegroundColor Red
    exit 1
}
if ($subtreeAfter.Count -gt 0) {
    $firstPids = (@($subtreeAfter) | Select-Object -First 3) -join ","
    Write-Host ("[verify] stable after 5s: {0} pids ({1}...)" -f $subtreeAfter.Count, $firstPids) -ForegroundColor Green
}
else {
    Write-Host "[verify] stable after 5s: lockfile still held (tree unresolved - see 7b fallback)." -ForegroundColor Green
}

# 7b) Actual ports: scan the clone's own listening sockets (MCP array 19681..19688,
#     gateway requested..requested+9) - never assume the requested port held.
$actualMcp = @()
$actualGateway = @()
$portsUnattributed = $false
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep -Seconds 2
    $nowPids = @(Get-Process -Name AutoClaw -ErrorAction SilentlyContinue |
        ForEach-Object { [int]$_.Id })
    $newPids = @($nowPids | Where-Object { $beforePids -notcontains $_ })
    $fresh = @(Get-CloneSubtreePids -Markers $CloneMarkers -NewPids $newPids)
    if ($fresh.Count -eq 0 -and $newPids.Count -gt 0) { $fresh = $newPids }
    $actualMcp = Get-CloneListeningPorts -SubtreePids $fresh -MinPort 19681 -MaxPort 19688
    $actualGateway = Get-CloneListeningPorts -SubtreePids $fresh -MinPort $cfg.GatewayPort -MaxPort ($cfg.GatewayPort + 9)
    if ($actualMcp.Count -gt 0 -and $actualGateway.Count -gt 0) { break }
}
# Fallback: instance live (lockfile held) but the WMI tree never resolved -
# scan the ranges WITHOUT pid ownership and report as unattributed. A running
# Primary could own a port in-range, so these results are advisory only.
if (($actualMcp.Count -eq 0) -and ($actualGateway.Count -eq 0) -and (Test-ProfileLockHeld -ProfileDir $CloneProfile)) {
    $portsUnattributed = $true
    Write-Host "[verify] process tree unresolved by WMI - scanning port ranges unattributed (advisory)." -ForegroundColor Yellow
    try {
        $actualMcp = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -ge 19681 -and $_.LocalPort -le 19688 } |
            Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
        $actualGateway = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -ge $cfg.GatewayPort -and $_.LocalPort -le ($cfg.GatewayPort + 9) } |
            Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
    }
    catch { }
}

$verifyOk = $true
if ($portsUnattributed) {
    Write-Host "[verify] WARN - port results below are UNATTRIBUTED (WMI tree unresolved; a running Primary could own an in-range port)." -ForegroundColor Yellow
}
if ($actualMcp.Count -eq 0) {
    Write-Host "[verify] WARN - no MCP port found in 19681..19688 for this clone (unpatched asar + 5 instances? primary holds the slots?)." -ForegroundColor Yellow
}
else {
    foreach ($port in $actualMcp) {
        $h = Test-HttpHealth -Port $port
        if ($h.Ok) { Write-Host ("[verify] MCP :$port /health OK") -ForegroundColor Green }
        else { Write-Host ("[verify] MCP :$port listening but /health FAILED ({0})" -f $h.Body) -ForegroundColor Yellow }
    }
}
if ($actualGateway.Count -eq 0) {
    Write-Host ("[verify] FAILED - no gateway port found in {0}..{1}." -f $cfg.GatewayPort, ($cfg.GatewayPort + 9)) -ForegroundColor Red
    $verifyOk = $false
}
else {
    $gwPort = $actualGateway[0]
    $h = Test-HttpHealth -Port $gwPort
    if ($h.Ok) {
        Write-Host ("[verify] gateway :$gwPort /health OK {0}" -f $h.Body) -ForegroundColor Green
        if ($gwPort -ne $cfg.GatewayPort) {
            Write-Host ("[verify] gateway port drift: requested {0}, actual {1} (recorded)." -f $cfg.GatewayPort, $gwPort) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ("[verify] FAILED - gateway :$gwPort listening but /health failed ({0})." -f $h.Body) -ForegroundColor Red
        $verifyOk = $false
    }
}

# 7c) paired.json: only the clone's own device key may appear (the live
#     operator credential must never be inherited). Poll while the gateway
#     boots; absent after the window -> WARN (created after first pairing).
$cloneOwnDeviceId = (Get-Content -LiteralPath (Join-Path $CloneProfile 'auth.json') -Raw | ConvertFrom-Json).deviceId
$pairedPath = Join-Path $CloneState 'devices\paired.json'
$pairedSeen = $false
for ($i = 0; $i -lt 45; $i++) {
    if (Test-Path -LiteralPath $pairedPath) { $pairedSeen = $true; break }
    Start-Sleep -Seconds 2
}
if ($pairedSeen) {
    $paired = Get-Content -LiteralPath $pairedPath -Raw | ConvertFrom-Json
    $keys = @($paired.PSObject.Properties.Name)
    $foreign = @($keys | Where-Object { $_ -ne $cloneOwnDeviceId })
    if ($foreign.Count -gt 0) {
        Write-Host "[verify] FAILED - paired.json contains foreign device keys: $($foreign -join ', ')" -ForegroundColor Red
        $verifyOk = $false
    }
    else {
        Write-Host "[verify] paired.json holds only this clone's device key." -ForegroundColor Green
    }
}
else {
    Write-Host "[verify] WARN - paired.json not created yet (appears after first pairing/login)." -ForegroundColor Yellow
}

# 7d) Isolation proof: the Primary's gateway config hash unchanged.
if ($primaryHashBefore) {
    $primaryHashAfter = (Get-FileHash -LiteralPath (Join-Path $PrimaryState 'openclaw.json') -Algorithm SHA256).Hash
    if ($primaryHashAfter -ne $primaryHashBefore) {
        Write-Host "[verify] FAILED - Primary openclaw.json changed during the launch cycle (isolation breach or concurrent Primary activity)." -ForegroundColor Red
        $verifyOk = $false
    }
    else {
        Write-Host "[verify] Primary openclaw.json hash unchanged (isolation proof)." -ForegroundColor Green
    }
}

# 8) Record the ACTUAL ports for -Status (verify the record re-reads).
$record = [ordered]@{
    instance            = $Instance
    requestedGatewayPort = $cfg.GatewayPort
    actualMcpPort       = $(if ($actualMcp.Count) { $actualMcp[0] } else { $null })
    actualGatewayPort   = $(if ($actualGateway.Count) { $actualGateway[0] } else { $null })
    launchedAt          = (Get-Date -Format "o")
    mainPids            = @((Get-CloneSubtreePids -Markers $CloneMarkers) | Select-Object -First 10)
    treeResolved        = (-not $portsUnattributed)
}
$recordPath = Join-Path $InstRoot 'instance-record.json'
[System.IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
$recordVerify = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
if ($recordVerify.instance -ne $Instance) { Write-Host "[record] WARN - instance-record.json did not verify after write." -ForegroundColor Yellow }

if (-not $verifyOk) {
    Write-Host "`n[launch] $Instance launched WITH VERIFY FAILURES - review the [verify] lines above." -ForegroundColor Red
    exit 1
}
Write-Host "`n[launch] $Instance verified and running. First run needs ONE manual login in its window." -ForegroundColor Green
