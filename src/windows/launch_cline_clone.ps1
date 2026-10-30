#requires -Version 5.1
<#
.SYNOPSIS
  Cline desktop (Tauri) clone-instance launcher for GHOST.

.DESCRIPTION
  Launches ONE fully isolated Cline instance beside any other running
  copies. Mechanism live-verified 2026-10-24 on this host (see
  docs/CLINE_CLONES_SPEC.md):

    CLINE_DIR               -> the whole ~\.cline state tree (db, locks,
                                logs, settings, secrets) per clone
    WEBVIEW2_USER_DATA_FOLDER -> the Chromium/WebView2 profile holding the
                                accounts.cline.app web login session
                                (stock location: %LOCALAPPDATA%\bot.cline.app)
    CLINE_HUB_PORT          -> the hub daemon port (stock default 25463,
                                candidate range 25463..25466)
    CLINE_SIDECAR_PORT      -> the desktop sidecar port (stock default 3126)

  The app is Tauri 2.11.1 (Rust + wry/WebView2, asInvoker - env vars
  survive the launch). Its tauri-plugin-single-instance guard is a named
  mutex (bot.cline.app-sim, session-local) PLUS a hidden WM_COPYDATA
  window (class bot.cline.app-sic, title bot.cline.app-siw): a second
  copy only exits when FindWindowW FINDS that window. The launcher
  renames the hidden window (bot.cline.app-siw.neutralized) before and
  after every launch, so every clone boots instead of exiting - while a
  normally-launched stock Cline keeps working beside them.

  Because the app-level single-instance is neutralized, this launcher
  MUST enforce per-clone single-instance itself: it aborts when the
  clone's own hub lock (<CLINE_DIR>\data\locks\hub\production.json.
  instance.lock) is held by a live process.

  Identity: a fresh profile has NO secrets.json / providers tokens
  (machineId = HKLM MachineGuid, shared - the GHOST ground truth); each
  clone needs ONE manual sign-in. One credential = one instance
  (ZCode rule, generalized).

  Deliberate non-goals v1 (2026-10-24): no exe/asar patching (nothing to
  patch - no asar, and the mechanism needs none), no taskbar window
  patch (running windows share the base AUMID; clone SHORTCUTS carry
  suffixed AUMIDs bot.cline.app.cN so pins stay distinct - developer
  decision, reported), no seeding (fresh profile per clone).

  Launch instances SEQUENTIALLY (use launch_cline_clones_all.ps1);
  never elevated (UIPI).

.PARAMETER Instance
  Clone slot: c1..c5 (validated).

.PARAMETER Status
  Show this clone's status WITHOUT launching: profile dir, hub-lock
  probe, sign-in hint, expected ports, single-instance window state.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_cline_clone.ps1 -Instance c1
  powershell -ExecutionPolicy Bypass -File launch_cline_clone.ps1 -Instance c3 -Status
#>
param(
    [ValidateSet('c1','c2','c3','c4','c5')]
    [string]$Instance = 'c1',
    [switch]$Status
)
$ErrorActionPreference = 'Stop'

# --- Portable paths ---------------------------------------------------------
$ExePath    = Join-Path $env:LOCALAPPDATA 'Cline\cline-app.exe'
$ClonesRoot = Join-Path $env:USERPROFILE 'ClineClonesHome'
$CloneDir   = Join-Path $ClonesRoot $Instance
$WebViewDir = Join-Path $CloneDir 'webview'
$HubLock    = Join-Path $CloneDir 'data\locks\hub\production.json.instance.lock'

# Per-clone ports (fixed table, outside the stock defaults AND the stock
# hub candidate range 25463..25466 / sidecar 3126 - a clone never fights
# the Primary's ports and never drifts into another clone's).
$PortPlan = @{
    'c1' = @{ Hub = 25471; Sidecar = 3131 }
    'c2' = @{ Hub = 25472; Sidecar = 3132 }
    'c3' = @{ Hub = 25473; Sidecar = 3133 }
    'c4' = @{ Hub = 25474; Sidecar = 3134 }
    'c5' = @{ Hub = 25475; Sidecar = 3135 }
}

# --- Single-instance window plumbing (tauri-plugin-single-instance) ---------
$SiClass   = 'bot.cline.app-sic'
$SiTitle   = 'bot.cline.app-siw'
$SiGone    = 'bot.cline.app-siw.neutralized'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClineSiWindow
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SetWindowTextW(IntPtr hWnd, string lpString);
}
'@

function Test-SingleInstanceWindowFindable {
    return ([ClineSiWindow]::FindWindowW($SiClass, $SiTitle) -ne [IntPtr]::Zero)
}

function Neutralize-SingleInstanceWindow {
    # Rename the hidden WM_COPYDATA window so FindWindowW fails on it.
    # The plugin's second-instance exit path runs ONLY when the window is
    # found (verified live 2026-10-24); a renamed window = instances boot.
    if (-not (Test-SingleInstanceWindowFindable)) { return $true }
    $hwnd = [ClineSiWindow]::FindWindowW($SiClass, $SiTitle)
    $ok   = [ClineSiWindow]::SetWindowTextW($hwnd, $SiGone)
    if (-not $ok) { return $false }
    # verify-after: the exact (class, title) pair must no longer resolve
    return (-not (Test-SingleInstanceWindowFindable))
}

function Test-HubLockHeld {
    if (-not (Test-Path $HubLock)) { return $false }
    try {
        $fs = [System.IO.File]::Open($HubLock, 'Open', 'Read', 'None')
        $fs.Close()
        return $false
    } catch { return $true }
}

# --- Status mode ------------------------------------------------------------
if ($Status) {
    Write-Host "=== Cline clone '$Instance' status ==="
    Write-Host "profile dir : $CloneDir"
    Write-Host "exists      : $(Test-Path $CloneDir)"
    if (Test-Path $HubLock) {
        if (Test-HubLockHeld) { Write-Host 'hub lock    : HELD (instance running)' }
        else { Write-Host 'hub lock    : free (not running)' }
    } else {
        Write-Host 'hub lock    : absent (never started or cleanly stopped)'
    }
    if (Test-Path (Join-Path $CloneDir 'data\secrets.json')) {
        Write-Host 'sign-in     : secrets.json present (signed in at least once)'
    } else {
        Write-Host 'sign-in     : no secrets.json yet (fresh profile - ONE manual sign-in)'
    }
    $ports = $PortPlan[$Instance]
    foreach ($p in @($ports.Hub, $ports.Sidecar)) {
        $l = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($l) {
            $owner = Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue
            Write-Host ("port {0,-5}    : LISTENING (pid {1}, {2})" -f $p, $l.OwningProcess, $(if ($owner) { $owner.Name } else { 'unknown' }))
        } else {
            Write-Host ("port {0,-5}    : not listening" -f $p)
        }
    }
    if (Test-SingleInstanceWindowFindable) {
        Write-Host 'si window   : FINDABLE - next clone launch would exit! Run the launcher to neutralize.' -ForegroundColor Yellow
    } else {
        Write-Host 'si window   : not findable (neutralized or absent)'
    }
    return
}

# --- Preflight --------------------------------------------------------------
if (-not (Test-Path $ExePath)) {
    Write-Error "cline-app.exe not found at: $ExePath"
    exit 1
}
foreach ($d in @($CloneDir, $WebViewDir)) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "created dir: $d"
    }
}

# Per-clone single-instance: the app-level guard is neutralized below, so
# WE must refuse a second copy on the same data dir (two writers on one
# SQLite/hub tree). Abort, never warn-and-continue.
if (Test-HubLockHeld) {
    Write-Error "'$Instance' appears to be RUNNING (hub lock held). Use its window instead; stop it before relaunching."
    exit 1
}

# --- Neutralize the single-instance window (pre-launch) ---------------------
# Covers a stock Cline that started earlier and created the window.
if (-not (Neutralize-SingleInstanceWindow)) {
    Write-Warning "could not neutralize the single-instance window (different integrity level?) - this launch may exit instead of starting."
}

# --- Launch -----------------------------------------------------------------
$ports = $PortPlan[$Instance]
$env:CLINE_DIR               = $CloneDir
$env:WEBVIEW2_USER_DATA_FOLDER = $WebViewDir
$env:CLINE_HUB_PORT          = [string]$ports.Hub
$env:CLINE_SIDECAR_PORT      = [string]$ports.Sidecar

Write-Host "launching Cline clone '$Instance' ..."
Write-Host "  CLINE_DIR                 = $env:CLINE_DIR"
Write-Host "  WEBVIEW2_USER_DATA_FOLDER = $env:WEBVIEW2_USER_DATA_FOLDER"
Write-Host "  CLINE_HUB_PORT            = $env:CLINE_HUB_PORT"
Write-Host "  CLINE_SIDECAR_PORT        = $env:CLINE_SIDECAR_PORT"

$proc = Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath) -PassThru
Write-Host "spawned pid $($proc.Id)."

# --- Post-launch verify (60s window) ----------------------------------------
$dataOk   = $false
$portOk   = $false
$windowOk = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 2
    if ($proc.HasExited) {
        Write-Host "FAILED: cline-app (pid $($proc.Id)) exited during startup." -ForegroundColor Red
        Write-Host "  hint: the single-instance window may have been findable at launch;" -ForegroundColor DarkGray
        Write-Host "        re-run this launcher (it neutralizes the window first)." -ForegroundColor DarkGray
        exit 1
    }
    # The fresh instance may have created a NEW hidden window (it happens
    # when this boot was the mutex creator); neutralize as soon as seen.
    Neutralize-SingleInstanceWindow | Out-Null
    if (-not $dataOk -and (Test-Path (Join-Path $CloneDir 'data'))) { $dataOk = $true }
    if (-not $portOk) {
        $hub = Get-NetTCPConnection -State Listen -LocalPort $ports.Hub -ErrorAction SilentlyContinue |
               Select-Object -First 1
        $side = Get-NetTCPConnection -State Listen -LocalPort $ports.Sidecar -ErrorAction SilentlyContinue |
                Select-Object -First 1
        if ($hub -and $side) { $portOk = $true }
    }
    if (-not (Test-SingleInstanceWindowFindable)) { $windowOk = $true }
    if ($dataOk -and $portOk -and $windowOk) { break }
}

Write-Host ""
Write-Host ("state dir materialized : {0}" -f $(if ($dataOk) { 'OK' } else { 'NOT SEEN (60s) - check the app window' }))
Write-Host ("hub port {0} + sidecar port {1} : {2}" -f $ports.Hub, $ports.Sidecar, $(if ($portOk) { 'LISTENING (OK)' } else { 'NOT LISTENING (60s)' }))
Write-Host ("single-instance window : {0}" -f $(if ($windowOk) { 'neutralized (OK)' } else { 'STILL FINDABLE - FAILED' }))
if (-not ($dataOk -and $portOk -and $windowOk)) {
    Write-Warning "one or more post-launch checks did not pass within 60s - inspect the output above."
}
Write-Host ""
Write-Host "launched. First run of a fresh profile needs ONE manual sign-in." -ForegroundColor Green
