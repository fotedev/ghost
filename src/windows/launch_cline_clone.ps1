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
    [switch]$Status,
    # Soft RAM guard threshold: at or above this many running Cline
    # instances, launching another one asks for confirmation (shared
    # ghost_launch_guard.ps1, same mechanics as the ZCode launcher).
    [ValidateRange(1, 10)]
    [int]$MaxConcurrent = 3,
    [switch]$NonInteractive,
    # Escape hatch for the pre-launch MCP settings sync (the AutoClaw2 [2b]
    # pattern): a failed sync warns and never blocks, so this switch exists
    # only to skip it entirely.
    [switch]$SkipMcpSync
)
$ErrorActionPreference = 'Stop'

# Display vocabulary (2026-11-03): colors are the user-facing clone names;
# the frozen c1..c5 keys stay in params, dirs and AUMIDs only.
$CloneColor = @{ 'c1' = 'Blue'; 'c2' = 'Yellow'; 'c3' = 'Green'; 'c4' = 'Red'; 'c5' = 'Orange' }[$Instance]

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

# --- Window-level taskbar identity (CS-2, 2026-11-17) -------------------------
# The AutoClaw-v2 pattern, external variant (docs/CLINE_WINDOW_IDENTITY_PLAN.md
# §3): the Tauri app has NO patchable surface, so the launcher stamps
# System.AppUserModel.ID onto the MAIN exe's top-level window property store
# (top shell precedence, re-groups live) + renames the window title. The
# property-store mechanics are the proven ZCode step-4 block verbatim-adapted
# (ole32 PropVariantClear - oleaut32 dropped that export in Win10 19041.7548,
# ground truth #6). Identity is COSMETIC: every stamp failure warns loudly and
# NEVER blocks the launch.
if (-not ('ClineWindowAumid' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class ClineWindowAumid {
    [StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
        [FieldOffset(8)] public long longValue;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }
    [DllImport("shell32.dll")] public static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    // oleaut32 dropped this export in Win10 19041.7548 (2026-07 CU) - ole32 keeps it
    [DllImport("ole32.dll")] public static extern int PropVariantClear(ref PROPVARIANT pv);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool SetWindowTextW(IntPtr hWnd, string lpString);
    public static readonly PROPERTYKEY PKEY_AUMID = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    static Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    // Stamp + read back; returns what the store actually holds.
    public static string Stamp(IntPtr hwnd, string aumid) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        IntPtr pStr = Marshal.StringToCoTaskMemUni(aumid);
        try {
            PROPVARIANT pv = new PROPVARIANT();
            pv.vt = 31; // VT_LPWSTR
            pv.pointerValue = pStr;
            var key = PKEY_AUMID;
            store.SetValue(ref key, ref pv);
            store.Commit();
        } finally { Marshal.FreeCoTaskMem(pStr); }
        return Read(hwnd);
    }
    public static string Read(IntPtr hwnd) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        PROPVARIANT back;
        var key = PKEY_AUMID;
        store.GetValue(ref key, out back);
        // VT_LPWSTR is CoTaskMem-allocated by the property store: copy the
        // string out first, then free the variant, or a resident caller leaks.
        string result;
        if (back.vt == 31) result = Marshal.PtrToStringUni(back.pointerValue);
        else if (back.vt == 0) result = "<EMPTY>";
        else result = "<readback vt=" + back.vt + ">";
        PropVariantClear(ref back);
        return result;
    }
}
"@
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
    Write-Host "=== Cline $CloneColor clone status ==="
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
    $mcpSettings = Join-Path $CloneDir 'data\settings\cline_mcp_settings.json'
    if (Test-Path $mcpSettings) {
        try {
            $mcpCfg = Get-Content -LiteralPath $mcpSettings -Raw | ConvertFrom-Json
            $n = 0
            if ($mcpCfg.mcpServers) { $n = @($mcpCfg.mcpServers.PSObject.Properties).Count }
            Write-Host ("mcp settings: {0} server definition(s)" -f $n)
        } catch { Write-Host 'mcp settings: file present but does not parse (rewritten on next sync)' }
    } else {
        Write-Host 'mcp settings: absent (synced from the Primary on next launch)'
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
    # Window-level identity (CS-2): report the FIRST live cline-app main
    # window's property-store AUMID (read-only; the launcher stamps clones).
    $live = Get-Process -Name 'cline-app' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($live) {
        $aumid = [ClineWindowAumid]::Read($live.MainWindowHandle)
        Write-Host ("window aumid : '{0}' (pid {1}, title '{2}')" -f $aumid, $live.Id, $live.MainWindowTitle)
    } else {
        Write-Host 'window aumid : no live cline-app main window'
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

# --- RAM/concurrency guard (2026-11-14, shared lib) ---------------------------
# Same soft guard as the ZCode launcher (ghost_launch_guard.ps1): several
# concurrent instances exhausted the Windows commit limit once (renderer-OOM
# 2026-09-25, ZCode-verified). Reached only when THIS clone is provably not
# running (the hub-lock abort above).
. "$PSScriptRoot\ghost_launch_guard.ps1"
$clineMains = @(Get-GhostSuiteMainIds -WmiFamilyFilter "Name LIKE 'Cline%'")
if ($clineMains.Count -ge $MaxConcurrent) {
    $guardProceed = Invoke-GhostLaunchGuard -RunningMains $clineMains.Count -MaxConcurrent $MaxConcurrent `
        -SuiteName 'Cline' -WmiFamilyFilter "Name LIKE 'Cline%'" -ProcessFamily 'Cline*' `
        -RiskLine '[ram-guard] More instances risk the same renderer-OOM commit-limit freeze documented for ZCode (verified 2026-09-25).' `
        -NonInteractive:$NonInteractive
    if (-not $guardProceed) {
        exit 0
    }
}

# --- [2b] Pre-launch MCP settings sync (2026-11-17, the AutoClaw2 [2b] / -----
#     CS-1 [2b/5] pattern): the Primary's data\settings\cline_mcp_settings.json
#     is the definitions source; this clone's own copy is the target. Child
#     process only (exit codes - never dot-sourced); a failed sync warns and
#     NEVER blocks the launch. The store is auth-free ({"mcpServers": {}}),
#     so the sync may also create it for a fresh clone.
$McpSyncScript = Join-Path $PSScriptRoot '..\..\tools\sync_cline_mcp.ps1'
if (-not $SkipMcpSync) {
    if (Test-Path -LiteralPath $McpSyncScript) {
        Write-Host '[2b] Syncing Primary MCP settings into the clone...'
        $syncOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $McpSyncScript -Instance $Instance -Quiet 2>&1
        $syncExit = $LASTEXITCODE
        foreach ($l in @($syncOut)) { Write-Host "      $l" }
        if ($syncExit -ne 0) {
            Write-Warning "MCP sync exited $syncExit - continuing the launch anyway (a failed sync must never block a launch; see the lines above)."
        }
    } else {
        Write-Warning "MCP sync child not found: $McpSyncScript - MCP sync skipped."
    }
} else {
    Write-Host '[2b] MCP sync skipped (-SkipMcpSync).'
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

Write-Host "launching Cline $CloneColor clone ..."
Write-Host "  CLINE_DIR                 = $env:CLINE_DIR"
Write-Host "  WEBVIEW2_USER_DATA_FOLDER = $env:WEBVIEW2_USER_DATA_FOLDER"
Write-Host "  CLINE_HUB_PORT            = $env:CLINE_HUB_PORT"
Write-Host "  CLINE_SIDECAR_PORT        = $env:CLINE_SIDECAR_PORT"

$proc = Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath) -PassThru
Write-Host "spawned pid $($proc.Id)."

# Window-level identity targets (CS-2): the AUMID must EQUAL the shortcut's
# (bot.cline.app.cN) so the running button resolves the clone shortcut's
# colored icon; the distinct title prevents the ZCode pin-collision class
# (a window titled like the Primary can hijack Cline.lnk on pin). vN comes
# from the exe's VERSIONINFO.
$wantAumid = "bot.cline.app.$Instance"
$exeVersion = ''
try { $exeVersion = [string](Get-Item -LiteralPath $ExePath -ErrorAction Stop).VersionInfo.FileVersion } catch { }
$wantTitle = if ($exeVersion) { "Cline $CloneColor v$exeVersion" } else { "Cline $CloneColor" }
$stampLastHandle = [Int64]0
$stampSeen = ''

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
    # Re-stamp on main-window handle change (splash -> real window swap):
    # only THIS clone's own process is stamped - WebView2 renders in child
    # msedgewebview2.exe processes and must never be touched (plan §3.1).
    if (-not $proc.HasExited -and $proc.MainWindowHandle -ne 0) {
        $curHandle = [Int64]$proc.MainWindowHandle
        if ($curHandle -ne $stampLastHandle) {
            $stampLastHandle = $curHandle
            $titleOk = [ClineWindowAumid]::SetWindowTextW($proc.MainWindowHandle, $wantTitle)
            $stampSeen = [ClineWindowAumid]::Stamp($proc.MainWindowHandle, $wantAumid)
            Write-Host ("[identity] stamped pid {0} hwnd 0x{1:X} -> read-back '{2}' (title set: {3})" -f $proc.Id, $curHandle, $stampSeen, $titleOk)
        }
    }
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

# Final identity verify: read back from a FRESH resolve - a stamp on a window
# that has since exited must not count as success. Identity is COSMETIC: any
# mismatch is a loud WARN, never a launch failure (plan acceptance 3).
$finalAumid = ''
if (-not $proc.HasExited -and $proc.MainWindowHandle -ne 0) {
    $finalAumid = [ClineWindowAumid]::Read($proc.MainWindowHandle)
}
if ($finalAumid -eq $wantAumid) {
    Write-Host ("[identity] verified: window AUMID '{0}', title '{1}'." -f $finalAumid, $proc.MainWindowTitle) -ForegroundColor Green
} else {
    Write-Warning ("[identity] window AUMID read-back '{0}' != wanted '{1}' - taskbar grouping degraded (pins still carry the per-clone AUMIDs). Identity is cosmetic; the launch stands." -f $finalAumid, $wantAumid)
}
Write-Host ""
Write-Host "launched. First run of a fresh profile needs ONE manual sign-in." -ForegroundColor Green
