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
    [switch]$Status
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
    Write-Host "=== OpenCode clone '$Instance' status ==="
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

# Running guard: the per-clone single-instance lock keys off the clone's own
# userData, so launching a RUNNING clone just focuses it - inform, not block.
if (Test-LockfileHeld $Lockfile) {
    Write-Warning "'$Instance' appears to be RUNNING (lockfile held) - this launch will focus it instead of starting a new copy."
    exit 0
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

# --- Launch --------------------------------------------------------------------
# Start-Process is detached and env-inheriting; the app is asInvoker so the
# argv flags (the isolation channel) survive untouched. Identity rides argv
# too (engine v2: the app's main bundle is ESM - no require - so the
# injected resolver reads ONLY argv). Each flag is quoted as ONE argument so
# spaced values stay single argv entries; the injected parser strips quotes.
Write-Host "[4/5] Launching OpenCode clone '$Instance' ..."
$installDir = Split-Path $ExePath -Parent
$launchArgs = @(
    "`"--opencode-clone-home=$CloneHome`"",
    "`"--opencode-clone-id=$($InstanceDefs[$Instance].AumidSuffix)`""
)
if ($identity.title) { $launchArgs += "`"--opencode-clone-title=$($identity.title)`"" }
if ($identity.iconPath) { $launchArgs += "`"--opencode-clone-icon=$($identity.iconPath)`"" }
$proc = Start-Process -FilePath $ExePath -WorkingDirectory $installDir -ArgumentList $launchArgs -PassThru
Write-Host ("      started pid {0}" -f $proc.Id)

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
