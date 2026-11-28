#requires -Version 5.1
<#
.SYNOPSIS
  OpenCode desktop clone-instance launcher for GHOST.

.DESCRIPTION
  Launches ONE fully isolated OpenCode desktop instance beside the Primary
  and/or other clones. Mechanism (docs/OPENCODE_CLONES_SPEC.md, verified
  statically against the installed 2.0.32 asar; LIVE-PENDING items gated at
  first run): the installed app carries the clone-home asar patch
  (tools/patch_opencode_clone_home.ps1) which redirects, per launch flag:

    --opencode-clone-home=<dir>   userData -> <dir>\desktop,
                                  sessionData -> <dir>\session, and the app's
                                  own XDG_DATA/CONFIG/CACHE/STATE_HOME ->
                                  <dir>\{data,config,cache,state}

  The per-clone Electron userData gives each clone its OWN
  requestSingleInstanceLock (keyed on userData), so N copies coexist
  natively. The same flag drives the patched setAppUserModelId wrap +
  browser-window-created listener: every clone window declares
  ai.opencode.desktop.<cN> (matching the shortcuts' AUMIDs), the per-color
  window icon and the "OpenCode <Color>" title, from
  <dir>\desktop\.opencode-clone-identity.json (written fresh by this
  launcher on every launch).

  NO seeding and NO credential copying (one credential = one instance):
  a fresh clone starts anonymous - ONE manual sign-in per clone. Clone
  "reset" = stop the instance, delete <ClonesRoot>\<cN>, launch again.

  Launch instances SEQUENTIALLY (use launch_opencode_clones_all.ps1);
  never elevated (UIPI rule applies even though the app itself is
  asInvoker). A bare OpenCode.exe launch (or a stock protocol launch)
  always opens the PRIMARY profile - launch clones only through this
  launcher or the per-clone shortcuts.

.PARAMETER Instance
  Clone slot: c1..c5 (validated).

.PARAMETER Status
  Show this clone's status (home tree, lockfile, identity, sign-in hint,
  process match) WITHOUT launching.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_opencode_clone.ps1 -Instance c1
  powershell -ExecutionPolicy Bypass -File launch_opencode_clone.ps1 -Instance c3 -Status
#>
param(
    [ValidateSet('c1','c2','c3','c4','c5')]
    [string]$Instance = 'c1',
    [switch]$Status,
    # Soft RAM guard threshold: at or above this many running OpenCode
    # instances, launching another one asks for confirmation (shared
    # ghost_launch_guard.ps1, same mechanics as the ZCode launcher).
    [ValidateRange(1, 10)]
    [int]$MaxConcurrent = 3,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

# --- Instance definitions (MUST stay in sync with
# tools/install_opencode_clone_shortcuts.ps1 $InstanceDefs) -------------------
$InstanceDefs = @{
    'c1' = @{ Color = 'Blue';   AumidSuffix = 'c1' }
    'c2' = @{ Color = 'Yellow'; AumidSuffix = 'c2' }
    'c3' = @{ Color = 'Green';  AumidSuffix = 'c3' }
    'c4' = @{ Color = 'Red';    AumidSuffix = 'c4' }
    'c5' = @{ Color = 'Orange'; AumidSuffix = 'c5' }  # generated placeholder - drop developer renders at tools\opencode-orange-branding\
}

# --- Portable paths ----------------------------------------------------------
$ExeCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop\OpenCode.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\opencode\OpenCode.exe')
)
$ExePath = $null
foreach ($c in $ExeCandidates) { if (Test-Path $c) { $ExePath = $c; break } }
$ResourcesDir = if ($ExePath) { Join-Path (Split-Path $ExePath -Parent) 'resources' } else { $null }
$AsarPath = if ($ResourcesDir) { Join-Path $ResourcesDir 'app.asar' } else { $null }
$ClonesRoot = Join-Path $env:USERPROFILE 'OpenCodeClonesHome'
$CloneHome = Join-Path $ClonesRoot $Instance
$DesktopDir = Join-Path $CloneHome 'desktop'      # Electron userData (patched setPath target)
$Lockfile = Join-Path $DesktopDir 'lockfile'
$IdentityJson = Join-Path $DesktopDir '.opencode-clone-identity.json'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # src\windows -> repo root
$BrandingDir = Join-Path $RepoRoot ("tools\opencode-" + ($InstanceDefs[$Instance].Color.ToLowerInvariant()) + "-branding")

function Test-LockfileHeld {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
        return $false
    } catch { return $true }
}

function Get-CloneProcess {
    # Marker-first classification: a main OpenCode.exe whose command line
    # carries this clone's home flag. WMI may return empty command lines for
    # some processes (the AutoClaw PEB-scrub precedent) - callers fall back to
    # the lockfile probe for those.
    $needle = "--opencode-clone-home=" + $CloneHome
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" -ErrorAction SilentlyContinue)
    $matched = @()
    foreach ($p in $procs) {
        if ($p.CommandLine -and $p.CommandLine.Contains($needle)) { $matched += $p }
    }
    return @{ All = $procs; Matched = $matched; CommandLineReadable = @($procs | Where-Object { $_.CommandLine }).Count -gt 0 }
}

# --- Status mode --------------------------------------------------------------
if ($Status) {
    Write-Host "=== OpenCode $($InstanceDefs[$Instance].Color) clone status ==="
    Write-Host "clone home  : $CloneHome"
    Write-Host "exists      : $(Test-Path $CloneHome)"
    foreach ($sub in @('desktop','session','data','config','cache','state')) {
        $p = Join-Path $CloneHome $sub
        if (Test-Path $p) { Write-Host ("  {0,-8}: present" -f $sub) }
    }
    if (Test-LockfileHeld $Lockfile) {
        Write-Host 'lockfile    : HELD (instance running)'
    } elseif (Test-Path $Lockfile) {
        Write-Host 'lockfile    : free (cleanly stopped)'
    } else {
        Write-Host 'lockfile    : absent (never started)'
    }
    $procInfo = Get-CloneProcess
    if ($procInfo.Matched.Count -gt 0) {
        Write-Host ("process     : {0} OpenCode.exe process(es) carry this clone's flag" -f $procInfo.Matched.Count)
    } elseif (-not $procInfo.CommandLineReadable) {
        Write-Host 'process     : OpenCode.exe running but command lines unreadable (WMI) - trust the lockfile probe'
    } else {
        Write-Host 'process     : no process carries this clone flag'
    }
    # CS-11: the per-clone service port (the frozen map seed written by the
    # [2d/5] pre-launch step; the spawned `serve --service` child reads it).
    $svcCfg = Join-Path $CloneHome 'config\opencode\service.json'
    if (Test-Path -LiteralPath $svcCfg) {
        try {
            $svc = Get-Content -LiteralPath $svcCfg -Raw | ConvertFrom-Json
            if ($svc.port -ge 1 -and $svc.port -le 65535) {
                Write-Host "service port: $($svc.port) (per-clone seed - the version default collides across instances on 2.4.2+)"
            } else {
                Write-Host 'service port: config present but no valid port - the version default applies (collision risk on 2.4.2+)'
            }
        } catch { Write-Host 'service port: config unreadable' }
    } else {
        Write-Host 'service port: not seeded yet (the next launch runs [2d/5]) - collision risk on 2.4.2+'
    }
    if (Test-Path $IdentityJson) {
        try {
            $id = Get-Content -LiteralPath $IdentityJson -Raw | ConvertFrom-Json
            Write-Host "identity    : aumidSuffix=$($id.aumidSuffix) title='$($id.title)'"
        } catch { Write-Host 'identity    : marker unreadable (will be rewritten on next launch)' }
    } else {
        Write-Host 'identity    : not written yet (first launch pending)'
    }
    $auth = Join-Path $CloneHome 'data\auth.json'
    if (Test-Path $auth) {
        Write-Host 'sign-in     : data\auth.json present (verify in-app)'
    } else {
        Write-Host 'sign-in     : no auth.json yet (anonymous - ONE manual sign-in pending)'
    }
    return
}

# --- Preflight ----------------------------------------------------------------
if (-not $ExePath) {
    Write-Error "OpenCode.exe not found under $env:LOCALAPPDATA\Programs (looked in @opencode-aidesktop and opencode)"
    exit 1
}
Write-Host "install     : $ExePath"

# Patch gate: a launch WITHOUT the patch in place would open the PRIMARY
# profile (the flag alone does nothing stock) - abort loudly instead.
Write-Host "[1/5] Verifying the clone-home patch..."
$patchOk = $false
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if ($nodeCmd -and (Test-Path $AsarPath)) {
    $probe = & $nodeCmd.Source -e "const fs=require('fs');try{const b=fs.readFileSync(process.argv[1]);const need=['__opencodeCloneHome','__opencodeCloneIdentity','--opencode-clone-home'];const missing=need.filter(s=>!b.includes(s));process.exit(missing.length?1:0)}catch(e){process.exit(3)}" $AsarPath
    $patchOk = ($LASTEXITCODE -eq 0)
}
if (-not $patchOk) {
    Write-Warning "The clone-home patch is NOT applied to this OpenCode install."
    Write-Warning "Launching now would open the PRIMARY profile, not the clone. Run GHOST.bat -> [6] OpenCode Multi-Instance & Clones -> [7] Apply clone-home patch (app must be closed), then relaunch."
    exit 1
}
Write-Host '      patch signatures present.'

# Home tree: pre-create so the identity marker can be written before first boot
# (ye() would mkdir the same layout anyway - this makes first boot identical to
# later boots).
Write-Host "[2/5] Preparing clone home..."
foreach ($sub in @('desktop','session','data','config','cache','state')) {
    $p = Join-Path $CloneHome $sub
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
Write-Host "      $CloneHome"

# Definitions-only config sync (CS-1, docs\OPENCODE_CONFIG_SYNC_PLAN.md):
# MCP + provider DEFINITIONS from the Primary onto this clone's config -
# BEFORE the clone starts, so there is no running-instance race and no
# -McpOnly distinction is needed (the ZCode watcher pattern). Child-process
# only (exit codes - never dot-sourced); a failed sync warns and NEVER
# blocks the launch, and the sync itself skips a config-less first run
# (the clone starts anonymous by design).
$SyncScript = Join-Path $RepoRoot 'tools\sync_opencode_config.ps1'
if (Test-Path -LiteralPath $SyncScript) {
    Write-Host '[2b/5] Syncing Primary definitions into the clone config...'
    $syncOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $SyncScript -Instance $Instance 2>&1
    $syncExit = $LASTEXITCODE
    foreach ($l in @($syncOut)) { Write-Host "      $l" }
    if ($syncExit -ne 0) {
        Write-Warning "config sync exited $syncExit - continuing the launch anyway (a failed sync must never block a launch; see the lines above)."
    }
} else {
    Write-Warning "sync child not found: $SyncScript - definitions sync skipped."
}

# 2d) Seed the per-clone service port (CS-11, 2026-11-28): OpenCode v2.4.2
#     computes the service port default from the version (the win32 remap
#     yields 28894 for 2.4.2) and the service REFUSES to start on collision -
#     two instances can only coexist on distinct seeded ports. The spawned
#     `opencode-cli.exe serve --service` child reads
#     <configHome>\opencode\service.json (the CONFIG home the XDG preempt
#     below points at the clone; the desktop app itself never touches this
#     file). The shared helper writes the frozen map port there, preserving
#     any existing keys (notably the pre-shared password) and skipping loudly
#     when a valid port is already present. Best-effort by contract: a failed
#     seed warns (the next service spawn would hit the documented
#     port-collision error) and NEVER blocks the launch.
$ServicePortHelper = Join-Path $PSScriptRoot 'ghost_opencode_service_port.ps1'
Write-Host '[2d/5] Seed the per-clone service port'
if (Test-Path -LiteralPath $ServicePortHelper) {
    . $ServicePortHelper
    $svcSeed = Initialize-GhostOpenCodeServicePort -CloneHome $CloneHome -Instance $Instance
    Write-Host ("      service port: {0} ({1})" -f $svcSeed.Port, $svcSeed.Note)
    if ($svcSeed.Status -eq 'failed') {
        Write-Warning "service-port seed failed - the clone's service may refuse to start while another instance's service holds the default port (CS-11; see the port-collision note in the service log)."
    }
} else {
    Write-Warning "ghost_opencode_service_port.ps1 not found - port seeding skipped (CS-11)."
}

# 2c) Ensure the resident config-sync watcher a fresh install needs is alive
#     AND set to autostart (CS-1 v2, 2026-11-17; the ZCode launcher 2e
#     pattern): a config edit made while no clone is launching otherwise
#     never reaches the clones. A user who only installs the clones never
#     opens GHOST to start it manually - so every legitimate clone launch
#     (menu, Desktop/Start shortcut, Launch ALL) heals it: start hidden when
#     not running, and install the Startup .lnk once so future logins are
#     covered. Running the ensure twice is harmless: the probe is a mutex
#     test (no WMI), and the watcher's own mutex guard exits any duplicate
#     copy silently. Best-effort by contract: any failure warns and NEVER
#     blocks the launch.
function Test-WatcherRunning([string]$MutexName) {
    # initiallyOwned=$false: created=$false means someone else holds it.
    $created = $false
    $probe = New-Object System.Threading.Mutex($false, $MutexName, [ref]$created)
    $probe.Close()
    return (-not $created)
}
function Ensure-ResidentWatcher([string]$Name, [string]$ScriptPath, [string]$MutexName, [string]$AutostartLnk) {
    try {
        if (Test-WatcherRunning $MutexName) {
            Write-Host "[watchers] $Name already running."
            return
        }
        # One-time: make sure the Startup .lnk exists so future logins are
        # covered even if this is the only clone launch of the session. The
        # watcher script owns the .lnk spec (-InstallAutostart verifies after
        # writing); we only re-check existence and warn, never fail the launch.
        if (-not (Test-Path -LiteralPath $AutostartLnk)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -InstallAutostart | Out-Null
            if (-not (Test-Path -LiteralPath $AutostartLnk)) {
                Write-Host "[watchers] $Name autostart install failed (non-fatal - the watcher still starts now)." -ForegroundColor Yellow
            }
        }
        # PS 5.1 ArgumentList joins with spaces WITHOUT quoting: pre-quote the
        # -File path so repo paths containing spaces survive.
        $fileArg = '"{0}"' -f $ScriptPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $fileArg)
        Write-Host "[watchers] started $Name (hidden, autostart ensured)." -ForegroundColor Green
    } catch {
        Write-Host "[watchers] $Name could not be ensured ($($_.Exception.Message)) - continuing." -ForegroundColor Yellow
    }
}
$ConfigWatcherScript = Join-Path $PSScriptRoot '..\..\tools\watch_opencode_config_sync.ps1'
$StartupFolder = [Environment]::GetFolderPath('Startup')
Write-Host '[2c/5] Ensure resident config-sync watcher'
if (Test-Path -LiteralPath $ConfigWatcherScript) {
    Ensure-ResidentWatcher -Name 'OpenCode config sync watcher' -ScriptPath $ConfigWatcherScript `
        -MutexName 'OpencodeConfigSyncWatcher' -AutostartLnk (Join-Path $StartupFolder 'OpenCode config sync watcher.lnk')
} else {
    Write-Host '[watchers] tools\watch_opencode_config_sync.ps1 not found - skipping.' -ForegroundColor Yellow
}

# Running guard: the per-clone single-instance lock keys off the clone's own
# userData, so launching a RUNNING clone just focuses it - inform, not block.
if (Test-LockfileHeld $Lockfile) {
    Write-Warning "'$Instance' appears to be RUNNING (lockfile held) - this launch will focus it instead of starting a new copy."
    exit 0
}

# --- RAM/concurrency guard (2026-11-14, shared lib) ---------------------------
# Same soft guard as the ZCode launcher (ghost_launch_guard.ps1): several
# concurrent Electron instances exhausted the Windows commit limit once
# (renderer-OOM 2026-09-25, ZCode-verified). Reached only when THIS clone is
# provably not running (the lockfile focus path above exits early).
. "$PSScriptRoot\ghost_launch_guard.ps1"
$ocMains = @(Get-GhostSuiteMainIds -WmiFamilyFilter "Name LIKE 'OpenCode%'")
if ($ocMains.Count -ge $MaxConcurrent) {
    $guardProceed = Invoke-GhostLaunchGuard -RunningMains $ocMains.Count -MaxConcurrent $MaxConcurrent `
        -SuiteName 'OpenCode' -WmiFamilyFilter "Name LIKE 'OpenCode%'" -ProcessFamily 'OpenCode*' `
        -RiskLine '[ram-guard] More instances risk the same renderer-OOM commit-limit freeze documented for ZCode (verified 2026-09-25).' `
        -NonInteractive:$NonInteractive
    if (-not $guardProceed) {
        exit 0
    }
}

# Identity marker + icon (consumed by the patched AUMID wrap and the
# browser-window-created window stamper; rewritten fresh on every launch).
Write-Host "[3/5] Writing clone identity marker..."
$iconPath = Join-Path $DesktopDir '.opencode-clone-icon.ico'
$identity = [ordered]@{
    aumidSuffix = $InstanceDefs[$Instance].AumidSuffix
    title       = "OpenCode " + $InstanceDefs[$Instance].Color
}
if (Test-Path (Join-Path $BrandingDir 'tray_icon.ico')) {
    Copy-Item (Join-Path $BrandingDir 'tray_icon.ico') $iconPath -Force
    if (-not (Test-Path $iconPath)) { throw "icon copy FAILED: $iconPath" }
    $identity.iconPath = $iconPath
} else {
    Write-Warning ("Branding not found at {0} - window icon degraded (taskbar identity still applies; drop tray_icon.ico there and relaunch)." -f $BrandingDir)
}
$identity | ConvertTo-Json -Depth 3 | Set-Content -Path $IdentityJson -Encoding UTF8
$verify = Get-Content -LiteralPath $IdentityJson -Raw | ConvertFrom-Json
if ($verify.aumidSuffix -ne $InstanceDefs[$Instance].AumidSuffix) { throw "identity marker verify FAILED: re-read mismatch" }
Write-Host "      aumidSuffix=$($verify.aumidSuffix) title='$($verify.title)'"

# --- [2f/5] Task Manager identity - per-color exe copy (2026-11-17) -----------
# The ZCode launcher step-2f pattern (see the AutoClaw2 launcher for the full
# rationale; the 2026-11-14 repo-only opt-in decision is REVERSED by the
# parity build-out plan). Best-effort by contract: any failure falls back to
# the stock exe with a loud warning - never blocks the launch.
$ExeIdentityTool = Join-Path $PSScriptRoot '..\..\tools\patch_opencode_exe_identity.ps1'
$ExeColorCap = @{ c1 = 'Blue'; c2 = 'Yellow'; c3 = 'Green'; c4 = 'Red'; c5 = 'Orange' }[$Instance]
$LaunchExe = $ExePath
$CloneExe = Join-Path (Split-Path -Parent $ExePath) "OpenCode-$ExeColorCap.exe"
Write-Host '[2f/5] Task Manager identity - per-color exe copy'
if (Test-Path -LiteralPath $ExeIdentityTool) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ExeIdentityTool -Target $Instance -InstallDir (Split-Path -Parent $ExePath)
    if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $CloneExe)) {
        $LaunchExe = $CloneExe
        Write-Host "[launch] starting from OpenCode-$ExeColorCap.exe (colored Task Manager group)." -ForegroundColor Green
    } else {
        Write-Host "[launch] exe copy unavailable (tool exit $LASTEXITCODE) - starting from the stock OpenCode.exe; Task Manager keeps the stock row." -ForegroundColor Yellow
    }
} else {
    Write-Host '[launch] tools\patch_opencode_exe_identity.ps1 not found - starting from the stock OpenCode.exe.' -ForegroundColor Yellow
}

# --- Launch --------------------------------------------------------------------
# Start-Process is detached and env-inheriting; the app is asInvoker so the
# argv flags (the isolation channel) survive untouched. Identity rides argv
# too (engine v2: the app's main bundle is ESM - no require - so the
# injected resolver reads ONLY argv). Each flag is quoted as ONE argument so
# spaced values stay single argv entries; the injected parser strips quotes.
#
# CS-10 SERVICE-SHARING GUARD + XDG PREEMPTION (2026-11-23): OpenCode v2.3.2
# introduced a machine-global background-service registry at
# `$XDG_STATE_HOME\opencode\service.json` ({id, version, url, pid, password},
# /api/info basic-auth health probe) and the desktop main entry calls
# Service.discover() at startup as PURE READ-ONLY REUSE - a live compatible
# record means the instance JOINS that service instead of spawning its own.
# The service process owns the data home (its spawn env carries the XDG
# redirection; clients talk HTTP), so a joining clone's sessions land in the
# service's data home = the Primary's ~/.local/share/opencode/opencode.db -
# a clone-isolation break. The patched in-app clone-home branch sets
# XDG_STATE_HOME too, but evidently runs AFTER the startup discover() read
# (observed live: c1 joined the Primary's daemon while the patch was
# applied and the flag was on argv). The launcher therefore PREEMPTS at the
# process-env level: the four XDG_* levers are set here (Start-Process
# inherits them), so EVERY in-app read - whenever it runs - resolves the
# clone's own state home, finds no registry, and spawns the clone's OWN
# service (the v1-era per-instance model the suite's isolation was built
# on). Idempotent with the in-app branch (same values). The levers are
# restored after the spawn so the launcher's other helper children keep the
# machine-default env.
$svcRegistry = Join-Path $env:USERPROFILE '.local\state\opencode\service.json'
if (Test-Path -LiteralPath $svcRegistry) {
    try {
        $svcRec = Get-Content -LiteralPath $svcRegistry -Raw -Encoding UTF8 | ConvertFrom-Json
        $svcAlive = $false
        if ($svcRec.pid) {
            $svcProc = Get-Process -Id $svcRec.pid -ErrorAction SilentlyContinue
            $svcAlive = ($null -ne $svcProc -and $svcProc.ProcessName -like 'opencode*')
        }
        if ($svcAlive) {
            Write-Warning ("Primary OpenCode service is RUNNING (pid {0}, {1}, v{2}) - the clone will spawn its OWN isolated service (XDG preempted); its sessions stay clone-local. Do not mistake the shared daemon for clone activity." -f $svcRec.pid, $svcRec.url, $svcRec.version)
        } else {
            Write-Host ("[launch] stale machine service registry (pid {0} not running) - the clone spawns its own service." -f $svcRec.pid)
        }
    } catch {
        Write-Host "[launch] could not read the machine service registry ($svcRegistry): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
Write-Host "[4/5] Launching OpenCode $($InstanceDefs[$Instance].Color) clone ..."
$installDir = Split-Path $ExePath -Parent
$launchArgs = @(
    "`"--opencode-clone-home=$CloneHome`"",
    "`"--opencode-clone-id=$($InstanceDefs[$Instance].AumidSuffix)`""
)
if ($identity.title) { $launchArgs += "`"--opencode-clone-title=$($identity.title)`"" }
if ($identity.iconPath) { $launchArgs += "`"--opencode-clone-icon=$($identity.iconPath)`"" }
# The XDG preempt: saved + restored so only the spawned app sees them.
# Subdir names = the frozen clone layout (data/config/cache/state - the same
# dirs the launcher pre-creates and the patch's in-app branch sets).
$XdgMap = @{
    'XDG_DATA_HOME'   = 'data'
    'XDG_CONFIG_HOME' = 'config'
    'XDG_CACHE_HOME'  = 'cache'
    'XDG_STATE_HOME'  = 'state'
}
$savedXdg = @{}
foreach ($xdg in $XdgMap.Keys) {
    $savedXdg[$xdg] = [Environment]::GetEnvironmentVariable($xdg)
    [Environment]::SetEnvironmentVariable($xdg, (Join-Path $CloneHome $XdgMap[$xdg]))
}
try {
    $proc = Start-Process -FilePath $LaunchExe -WorkingDirectory $installDir -ArgumentList $launchArgs -PassThru
} finally {
    foreach ($xdg in $XdgMap.Keys) {
        [Environment]::SetEnvironmentVariable($xdg, $savedXdg[$xdg])
    }
}
Write-Host ("      started pid {0}" -f $proc.Id)
Write-Host ("      XDG preempted: {0} (data/config/cache/state -> the clone home; the app spawns its OWN service)." -f $CloneHome) -ForegroundColor Green

Write-Host "[5/5] Verify-after-launch (up to 60s)..."
$deadline = (Get-Date).AddSeconds(60)
$lockSeen = $false
$procSeen = $false
$cmdlReadable = $true
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (-not $lockSeen -and (Test-LockfileHeld $Lockfile)) { $lockSeen = $true }
    $pi = Get-CloneProcess
    if (-not $pi.CommandLineReadable) { $cmdlReadable = $false }
    if ($pi.Matched.Count -gt 0) { $procSeen = $true; break }
    if ($lockSeen -and $cmdlReadable) { break }
}
$ok = $false
if ($procSeen) {
    $ok = $true
    Write-Host ("      verified: {0} process(es) carry this clone's flag; lockfile HELD." -f $pi.Matched.Count)
} elseif ($lockSeen) {
    # Command lines unreadable (AutoClaw PEB-scrub precedent) - the clone's own
    # lockfile being held inside ITS home is decisive evidence the redirect engaged.
    $ok = $true
    Write-Host '      verified via the clone lockfile (command lines unreadable - WMI limitation, flag match unavailable).'
} else {
    Write-Warning '      NOT verified within 60s: no flag-matched process and no lockfile. Check whether an OpenCode window opened; if it is the PRIMARY profile, close it and re-run the patch before launching clones.'
}
if (-not $ok) { exit 1 }

Write-Host ""
Write-Host "launched. A fresh clone needs ONE manual sign-in (never automated)." -ForegroundColor Green
