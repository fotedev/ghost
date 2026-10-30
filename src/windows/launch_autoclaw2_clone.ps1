#requires -Version 5.1
<#
.SYNOPSIS
  AutoClaw2 (v2.1.1, zwork) clone-instance launcher for GHOST.

.DESCRIPTION
  Launches ONE fully isolated AutoClaw2 instance beside any other running
  copies (the v2.1.1 Primary and/or other clones). Mechanism is the app's
  OFFICIAL override, live-verified 2026-10-23 on this host (see
  docs/AUTOCLAW2_CLONES_SPEC.md):

    ZWORK_USER_DATA -> pins the Electron userData dir BEFORE
        requestSingleInstanceLock() is acquired
        (zwork-single-instance-lock.ts:
        requestSingleInstanceLockForPinnedProfile), so each profile gets
        its OWN lock and N instances coexist (observed: 3 concurrent
        copies, each log "zwork.update.single_instance acquired:true").
    AUTOCLAW_PROFILE_ROOT -> relocates the legacy v1.x migration source
        (read-only surface; default ~\.openclaw-autoclaw). Pointed at the
        clone's own dir so a clone NEVER reads a live Primary's state.

  Why no USERPROFILE tricks (unlike the v1.20 suite): AutoClaw2.exe's
  manifest is asInvoker (verified 2026-10-23) - no UAC boundary, env vars
  survive the launch - and the app never reads --user-data-dir from argv
  (0 refs in main.cjs). ZWORK_USER_DATA is the only supported lever.

  Identity: per-profile device\device-id.json is generated FRESH by the
  app on first run (sha256 prefixes verified unique across profiles),
  so NO identity seeding and NO credential copying: each clone needs ONE
  manual sign-in. One credential = one instance still applies - sign each
  clone into its own account to avoid Telegram polling 409s and
  cross-account billing (ZCode rule, generalized).

  Deliberate non-goals in v1 of this suite (2026-10-23): no auto-update
  disabling, no port patching, no taskbar AUMID patch - the v2.1.1 engine
  runs in-process (no shared-port conflict observed with 3 concurrent
  copies) and no asar patch is needed for isolation. Running windows all
  share the base AUMID com.zhipuai.autoclaw2; clone SHORTCUTS carry
  suffixed AUMIDs (com.zhipuai.autoclaw2.cN) so pins stay distinct.

  Launch instances SEQUENTIALLY (use launch_autoclaw2_clones_all.ps1);
  never elevated (UIPI rule applies even though the app itself is
  asInvoker).

.PARAMETER Instance
  Clone slot: c1..c5 (validated).

.PARAMETER Status
  Show this clone's status (profile dir, lockfile held/free, process
  count, device-id hash prefix) WITHOUT launching.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_autoclaw2_clone.ps1 -Instance c1
  powershell -ExecutionPolicy Bypass -File launch_autoclaw2_clone.ps1 -Instance c3 -Status
#>
param(
    [ValidateSet('c1','c2','c3','c4','c5')]
    [string]$Instance = 'c1',
    [switch]$Status
)
$ErrorActionPreference = 'Stop'

# --- Portable paths ---------------------------------------------------------
$ExePath    = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\AutoClaw2.exe'
$ClonesRoot = Join-Path $env:USERPROFILE 'AutoClaw2ClonesHome'
$ProfileDir = Join-Path $ClonesRoot $Instance

# --- Status mode ------------------------------------------------------------
if ($Status) {
    Write-Host "=== AutoClaw2 clone '$Instance' status ==="
    Write-Host "profile dir : $ProfileDir"
    Write-Host "exists      : $(Test-Path $ProfileDir)"
    $lockfile = Join-Path $ProfileDir 'lockfile'
    if (Test-Path $lockfile) {
        try {
            $fs = [System.IO.File]::Open($lockfile, 'Open', 'Read', 'None')
            $fs.Close(); Write-Host 'lockfile    : free (not running)'
        } catch { Write-Host 'lockfile    : HELD (instance running)' }
    } else {
        Write-Host 'lockfile    : absent (never started or cleanly stopped)'
    }
    $dev = Join-Path $ProfileDir 'device\device-id.json'
    if (Test-Path $dev) {
        $h = (Get-FileHash $dev -Algorithm SHA256).Hash
        Write-Host "device-id   : sha256 $($h.Substring(0,12))... (unique per profile)"
    } else { Write-Host 'device-id   : (not generated yet - first run pending)' }
    if (Test-Path (Join-Path $ProfileDir 'accounts')) {
        Write-Host 'sign-in     : accounts dir present (verify in-app)'
    } else { Write-Host 'sign-in     : no accounts dir yet (fresh profile)' }
    $procCount = @(Get-Process -Name AutoClaw2 -ErrorAction SilentlyContinue).Count
    Write-Host "processes   : $procCount AutoClaw2 process(es) TOTAL (all copies - per-clone attribution is not externally observable)"
    return
}

# --- Preflight --------------------------------------------------------------
if (-not (Test-Path $ExePath)) {
    Write-Error "AutoClaw2.exe not found at: $ExePath"
    exit 1
}

# --- Git-identity guard ------------------------------------------------------
# AutoClaw2 v2.1.1 injects GIT_AUTHOR_*/GIT_COMMITTER_*="zwork" into every
# agent shell (resources/app/dist/main.cjs, safeEnvironment), which overrides
# the user's global .gitconfig so every agent commit is authored "zwork".
# Re-apply the de-injection patch after every AutoClaw2 update. Non-fatal by
# design: a guard failure or an unexpected bundle layout must never block a
# launch.
$gitIdentityGuard = Join-Path $PSScriptRoot '..\..\tools\ensure_autoclaw2_git_identity.ps1'
if (Test-Path -LiteralPath $gitIdentityGuard) {
    try {
        & $gitIdentityGuard -InstallRoot (Split-Path $ExePath)
        if ($LASTEXITCODE -ne 0) { Write-Warning "git-identity guard exit $LASTEXITCODE (launch continues)" }
    } catch {
        Write-Warning "git-identity guard failed: $($_.Exception.Message)"
    }
} else {
    Write-Warning "git-identity guard script not found: $gitIdentityGuard"
}

if (-not (Test-Path $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    Write-Host "created profile dir: $ProfileDir"
}

# Hold check: the single-instance lock keys off the profile dir, so
# launching a RUNNING clone just focuses its window - inform, not block.
$lockfile = Join-Path $ProfileDir 'lockfile'
if (Test-Path $lockfile) {
    try {
        $fs = [System.IO.File]::Open($lockfile, 'Open', 'Read', 'None')
        $fs.Close()
    } catch {
        Write-Warning "'$Instance' appears to be RUNNING (lockfile held) - this launch will focus it instead of starting a new copy."
    }
}

# --- Launch -----------------------------------------------------------------
# Env set here is inherited by the child (asInvoker, no UAC reset).
$env:ZWORK_USER_DATA       = $ProfileDir
$env:AUTOCLAW_PROFILE_ROOT = Join-Path $ClonesRoot "$Instance-migration-root"

Write-Host "launching AutoClaw2 clone '$Instance' ..."
Write-Host "  ZWORK_USER_DATA       = $env:ZWORK_USER_DATA"
Write-Host "  AUTOCLAW_PROFILE_ROOT = $env:AUTOCLAW_PROFILE_ROOT"

Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath)

# Verify-after-launch (never-silent-success): Start-Process proves spawn, not
# survival - the v1 suite's 2026-10-15 crash class died within seconds on a
# half-built profile. A live instance holds its profile lockfile exclusively;
# poll for that hold (same probe idiom as the checks above).
$lockHeldSeen = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $lockfile) {
        try {
            $fs = [System.IO.File]::Open($lockfile, 'Open', 'Read', 'None')
            if ($fs) { $fs.Close() }
        } catch {
            $lockHeldSeen = $true
            break
        }
    }
}

Write-Host ""
if ($lockHeldSeen) {
    Write-Host "verified: profile lockfile held (instance live)." -ForegroundColor Green
    Write-Host "launched. First run of a fresh profile needs ONE manual sign-in." -ForegroundColor Green
} else {
    Write-Host "FAILED: profile lockfile never held within 30s - the process likely exited at startup. Check the profile logs under:" -ForegroundColor Red
    Write-Host "  $ProfileDir" -ForegroundColor Red
    exit 1
}
