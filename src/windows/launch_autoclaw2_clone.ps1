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
  disabling, no port patching - the v2.1.1 engine runs in-process (no
  shared-port conflict observed with 3 concurrent copies) and no patch is
  needed for isolation. Taskbar identity was the one deferred item
  (spec §7) and shipped 2026-11-06 as an OPTIONAL env patch: AutoClaw2
  4.0.0 ships unpacked (plain-text main.cjs), and
  tools\patch_autoclaw2_identity.ps1 (GHOST.bat AutoClaw2 [13]) makes the
  AUMID + window icon read ZWORK_AUMID / ZWORK_CLONE_ICON, which this
  launcher sets per clone below (matching the SHORTCUT AUMIDs
  com.zhipuai.autoclaw2.cN, so pins and running windows group together).
  A stock bundle simply IGNORES the two env vars - cosmetic degradation
  only, warned loudly - so unlike the OpenCode patch gate there is no
  correctness hazard and the launch always proceeds.

  Launch instances SEQUENTIALLY (use launch_autoclaw2_clones_all.ps1);
  never elevated (UIPI rule applies even though the app itself is
  asInvoker).

.PARAMETER Instance
  Clone slot: c1..c5 (validated).

.PARAMETER Status
  Show this clone's status (profile dir, lockfile held/free, process
  count, device-id hash prefix) WITHOUT launching.

.PARAMETER SkipMcpSync
  Skip the pre-launch MCP sync step [2b] for this launch only (incident
  triage escape hatch - e.g. the 2026-11-05 E5 verdict: externally-written
  MCP rows are never adopted by the app, so re-applying them on every
  launch just re-seeds the red sources list).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_autoclaw2_clone.ps1 -Instance c1
  powershell -ExecutionPolicy Bypass -File launch_autoclaw2_clone.ps1 -Instance c3 -Status
#>
param(
    [ValidateSet('c1','c2','c3','c4','c5')]
    [string]$Instance = 'c1',
    [switch]$Status,
    [switch]$SkipMcpSync
)
$ErrorActionPreference = 'Stop'

# --- Portable paths ---------------------------------------------------------
$ExePath    = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\AutoClaw2.exe'
$ClonesRoot = Join-Path $env:USERPROFILE 'AutoClaw2ClonesHome'
$ProfileDir = Join-Path $ClonesRoot $Instance

# Clone color identity - MUST stay in sync with the BrandingRepo map in
# tools\install_autoclaw2_clone_shortcuts.ps1 (one installer, one vocabulary).
$InstanceColor = @{ c1 = 'blue'; c2 = 'yellow'; c3 = 'green'; c4 = 'red'; c5 = 'orange' }

# --- Window identity helper --------------------------------------------------
# The patched bundle sets System.AppUserModel.ID on the window BEFORE it is
# shown (setAppDetails, Xqn, right after the BrowserWindow ctor), but the shell
# has already created the taskbar group for the new window by then and does
# NOT rebuild it on a plain property write - two clones therefore keep sharing
# ONE taskbar button even though their window stores differ (live 2026-11-09:
# c1 + c5 both running, stores read com.zhipuai.autoclaw2.c1 and .c5, taskbar
# showed a single AutoClaw button). The fix is the ZCode KICK: write a
# temporary AUMID, then the real one - a real property CHANGE makes the shell
# tear down and recreate the group. Same window-property route as
# tools\watch_zcode_taskbar.ps1 (window-level AUMID has top precedence), so it
# also works on a stock bundle, where the app never sets the value at all.
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public class Ac2WindowIdentity {
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
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    // oleaut32 dropped this export in the 2026-07 CU (ground truth #6) - ole32 keeps it
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);

    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int n);

    static readonly PROPERTYKEY PKEY_AUMID = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    static Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    public static string Read(IntPtr hwnd) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        PROPVARIANT back;
        var key = PKEY_AUMID;
        store.GetValue(ref key, out back);
        string result;
        if (back.vt == 31) result = Marshal.PtrToStringUni(back.pointerValue);
        else if (back.vt == 0) result = "";
        else result = "<vt=" + back.vt + ">";
        PropVariantClear(ref back);
        return result;
    }

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

    // Ownerless, visible Chrome_WidgetWin_1 windows owned by AutoClaw2.exe
    // -> "pid|hwnd|aumid". The owner test skips tool windows; the process
    // name test scopes the scan to this suite's app only.
    public static string[] FindWindows() {
        var list = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            if (GetWindow(h, 4) != IntPtr.Zero) return true; // GW_OWNER
            var cls = new StringBuilder(256);
            GetClassNameW(h, cls, 256);
            if (cls.ToString() != "Chrome_WidgetWin_1") return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            try {
                var p = Process.GetProcessById((int)pid);
                if (!string.Equals(p.ProcessName, "AutoClaw2", StringComparison.OrdinalIgnoreCase)) return true;
            } catch { return true; }
            list.Add(pid + "|" + h.ToInt64() + "|" + Read(h));
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
"@

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
    $identityMarker = Join-Path (Split-Path -Parent $ExePath) 'resources\app\autoclaw2-identity-patch.marker.json'
    $cloneIcon = (Resolve-Path (Join-Path $PSScriptRoot "..\..\tools\autoclaw2-$($InstanceColor[$Instance])-branding\tray_icon.ico") -ErrorAction SilentlyContinue).ProviderPath
    Write-Host "identity    : window patch $(if (Test-Path -LiteralPath $identityMarker) { 'APPLIED' } else { 'stock - one-time fix: GHOST.bat AutoClaw2 [13]' })"
    Write-Host "              AUMID com.zhipuai.autoclaw2.$Instance  icon $(if ($cloneIcon) { $cloneIcon } else { "MISSING: tools\autoclaw2-$($InstanceColor[$Instance])-branding\tray_icon.ico" })"
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

# --- Pre-launch MCP sync [2b] ------------------------------------------------
# D7: this is the PRIMARY convergence path - the profile is provably closed
# here (a running clone only warns above and never reaches a second write),
# so a quick best-effort MCP sync lands on this very launch. Never blocks
# the launch: any failure is a warning only (same contract as ZCode's 2d).
# A refusal (exit 2) is NEVER silent: the sync prints its own [REFUSED]
# verdict and the launcher adds a warning so a hidden-console launch cannot
# swallow it (2026-11-05: the schema gate refusing every post-4.0.0 profile
# made this step a silent no-op for a whole day).
if ($SkipMcpSync) {
    Write-Host "pre-launch MCP sync: SKIPPED (-SkipMcpSync)"
} else {
    $ac2McpSync = Join-Path $PSScriptRoot '..\..\tools\sync_autoclaw2_mcp.ps1'
    if (Test-Path -LiteralPath $ac2McpSync) {
        try {
            & $ac2McpSync -Target $Instance -Quiet
            $syncExit = $LASTEXITCODE
            if ($syncExit -eq 2) {
                Write-Warning "pre-launch MCP sync REFUSED (exit 2 - see the [REFUSED] verdict above). Launch continues; the sync did NOT run."
            } elseif ($syncExit -ne 0) {
                Write-Warning "pre-launch MCP sync exit $syncExit (launch continues)"
            }
        } catch {
            Write-Warning "pre-launch MCP sync failed: $($_.Exception.Message) (launch continues)"
        }
    }
}

# --- Launch -----------------------------------------------------------------
# Env set here is inherited by the child (asInvoker, no UAC reset).
$env:ZWORK_USER_DATA       = $ProfileDir
$env:AUTOCLAW_PROFILE_ROOT = Join-Path $ClonesRoot "$Instance-migration-root"

# Clone taskbar identity (tools\patch_autoclaw2_identity.ps1, AutoClaw2 [13]):
# the patch makes the bundle read ZWORK_AUMID / ZWORK_CLONE_ICON. The AUMID
# matches the SHORTCUT AUMID (com.zhipuai.autoclaw2.cN) so a pinned clone and
# its running window group together; the icon is the same tinted tray_icon.ico
# the shortcuts carry. A stock bundle ignores both vars - degraded cosmetics
# only (EC-C06), warned below, launch always proceeds.
$env:ZWORK_AUMID = "com.zhipuai.autoclaw2.$Instance"
$cloneIcon = (Resolve-Path (Join-Path $PSScriptRoot "..\..\tools\autoclaw2-$($InstanceColor[$Instance])-branding\tray_icon.ico") -ErrorAction SilentlyContinue).ProviderPath
if ($cloneIcon) {
    $env:ZWORK_CLONE_ICON = $cloneIcon
} else {
    Remove-Item Env:ZWORK_CLONE_ICON -ErrorAction SilentlyContinue
    Write-Warning "clone icon missing (tools\autoclaw2-$($InstanceColor[$Instance])-branding\tray_icon.ico) - this launch uses the stock window icon (EC-B02)."
}
$identityMarker = Join-Path (Split-Path -Parent $ExePath) 'resources\app\autoclaw2-identity-patch.marker.json'
if (Test-Path -LiteralPath $identityMarker) {
    $identityNote = 'window identity patch: APPLIED'
} else {
    $identityNote = 'window identity patch: STOCK BUNDLE - taskbar buttons stay grouped'
    Write-Warning "$identityNote. One-time fix: GHOST.bat > AutoClaw2 > [13] (tools\patch_autoclaw2_identity.ps1)."
}

Write-Host "launching AutoClaw2 clone '$Instance' ..."
Write-Host "  ZWORK_USER_DATA       = $env:ZWORK_USER_DATA"
Write-Host "  AUTOCLAW_PROFILE_ROOT = $env:AUTOCLAW_PROFILE_ROOT"
Write-Host "  ZWORK_AUMID           = $env:ZWORK_AUMID"
Write-Host "  ZWORK_CLONE_ICON      = $(if ($env:ZWORK_CLONE_ICON) { $env:ZWORK_CLONE_ICON } else { '<unset>' })"
Write-Host "  $identityNote"

$launched = Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath) -PassThru

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


# --- Taskbar group kick [3] --------------------------------------------------
# Step [2] sets the window AUMID but NOT the group: the shell built this
# clone's taskbar group while the window was still identity-less, so a plain
# property read-back looks correct while the button stays merged with another
# instance (live 2026-11-09: c1 + c5, two distinct stores, one button).
# Kick = temp AUMID -> real AUMID, so the shell recreates the group. Target
# window: the launched process's own ownerless top-level window; on a focus
# relaunch (the started process exits, the running window is focused) fall
# back to the window already carrying this clone's AUMID. Never touches
# another clone's window: pid first, expected AUMID second, nothing else.
$kickOk = $false
$kickResult = 'not attempted'
$expectedAumid = $env:ZWORK_AUMID
$targetHwnd = [IntPtr]::Zero
$targetPid = 0
for ($i = 0; $i -lt 60 -and $targetHwnd -eq [IntPtr]::Zero; $i++) {
    $candidates = @()
    foreach ($line in [Ac2WindowIdentity]::FindWindows()) {
        $parts = $line -split '\|', 3
        $candidates += [pscustomobject]@{ Pid = [int]$parts[0]; Hwnd = [IntPtr][long]$parts[1]; Aumid = $parts[2] }
    }
    if ($launched) {
        $mine = @($candidates | Where-Object { $_.Pid -eq $launched.Id })
        if ($mine.Count -gt 0) { $targetHwnd = $mine[0].Hwnd; $targetPid = $mine[0].Pid; break }
    }
    $stamped = @($candidates | Where-Object { $_.Aumid -eq $expectedAumid })
    if ($stamped.Count -gt 0) { $targetHwnd = $stamped[0].Hwnd; $targetPid = $stamped[0].Pid; break }
    Start-Sleep -Seconds 1
}

if ($targetHwnd -eq [IntPtr]::Zero) {
    $kickResult = "FAILED: no AutoClaw2 window found within 60s (patch applied? AUMID $expectedAumid)"
    Write-Warning "taskbar identity kick: $kickResult"
} else {
    # Spacing is load-bearing: a 300-400 ms temp->real pair can be COALESCED
    # by the shell - the temporary group is destroyed and the real one is
    # never re-created, leaving the window with NO taskbar button at all
    # (reproduced live 2026-11-09 on c5; a slower kick restored it). 1.2 s
    # lets the shell finish the first re-group before the second write.
    $kickRead = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        [Ac2WindowIdentity]::Stamp($targetHwnd, "$expectedAumid.kick") | Out-Null
        Start-Sleep -Milliseconds 1200
        $kickRead = [Ac2WindowIdentity]::Stamp($targetHwnd, $expectedAumid)
        Start-Sleep -Milliseconds 1200
        $kickRead = [Ac2WindowIdentity]::Read($targetHwnd)
        if ($kickRead -eq $expectedAumid) { break }
    }
    if ($kickRead -eq $expectedAumid) {
        $kickOk = $true
        $kickResult = "window AUMID verified $expectedAumid (pid $targetPid, group kicked)"
    } else {
        $kickResult = "FAILED: read-back '$kickRead' != '$expectedAumid' (pid $targetPid)"
    }
}

Write-Host ""
if ($lockHeldSeen) {
    Write-Host "verified: profile lockfile held (instance live)." -ForegroundColor Green
    if ($kickOk) {
        Write-Host "verified: taskbar identity $kickResult" -ForegroundColor Green
    } else {
        Write-Host "FAILED: taskbar identity $kickResult" -ForegroundColor Red
    }
    Write-Host "launched. First run of a fresh profile needs ONE manual sign-in." -ForegroundColor Green
} else {
    Write-Host "FAILED: profile lockfile never held within 30s - the process likely exited at startup. Check the profile logs under:" -ForegroundColor Red
    Write-Host "  $ProfileDir" -ForegroundColor Red
    exit 1
}
