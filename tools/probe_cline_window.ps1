#Requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY Phase-0 discovery probe for the Cline window-identity work
  (docs/CLINE_WINDOW_IDENTITY_PLAN.md §4, backlog CS-2). Answers probes
  (a)-(c) against whatever cline-app.exe windows are LIVE right now; probe
  (d) (stamp survival across a clone restart) is manual: run the clone
  launcher, then re-run this probe and compare the read-back AUMID.

  Off-menu by design (the diagnosers' contract) - run it while a Cline
  window is open:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\probe_cline_window.ps1

  Writes NOTHING. Never elevated (UIPI: run at the same integrity level as
  the app, i.e. NOT from an admin console over a non-elevated Cline).

.Output per live main window
  pid / hwnd / title / class  - the top-level window anatomy (probe b: the
                                owner must be the Tauri MAIN exe, never an
                                msedgewebview2.exe child; probe c: is the
                                class/name stable across launches?)
  property-store AUMID        - what the shell currently honors (probe a:
                                is a process-explicit AUMID already set?)
  webview children            - count of msedgewebview2.exe whose parent is
                                this pid (the render tree the stamp must
                                NOT touch)
  SetCurrentProcessExplicitAppUserModelID in exe
                              - binary scan of cline-app.exe for the
                                process-explicit AUMID API string (probe a)
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

# Self-contained interop (same proven block as launch_cline_clone.ps1's
# ClineWindowAumid + GetClassNameW for the anatomy report; the probe is a
# separate process, so the launcher's compiled type is never pre-loaded).
if (-not ('ClineWindowProbe' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
public class ClineWindowProbe {
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    public static readonly PROPERTYKEY PKEY_AUMID = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    static Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    public static string Read(IntPtr hwnd) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        PROPVARIANT back;
        var key = PKEY_AUMID;
        store.GetValue(ref key, out back);
        // VT_LPWSTR is CoTaskMem-allocated: copy the string out first, then
        // free the variant (the resident-caller leak rule).
        string result;
        if (back.vt == 31) result = Marshal.PtrToStringUni(back.pointerValue);
        else if (back.vt == 0) result = "<EMPTY>";
        else result = "<readback vt=" + back.vt + ">";
        PropVariantClear(ref back);
        return result;
    }
    public static string ClassName(IntPtr hwnd) {
        var sb = new StringBuilder(256);
        GetClassNameW(hwnd, sb, 256);
        return sb.ToString();
    }
}
"@
}

Write-Host '=== Cline window identity Phase-0 probe (READ-ONLY) ==='
$proces = @(Get-Process -Name 'cline-app' -ErrorAction SilentlyContinue)
if ($proces.Count -eq 0) {
    Write-Host 'no cline-app.exe processes running - launch the Primary or a clone first, then re-run.'
    exit 0
}
$procMap = @{}
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='cline-app.exe' OR Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue)) {
    $procMap[[int]$p.ProcessId] = [int]$p.ParentProcessId
}
foreach ($p in $proces) {
    Write-Host ("--- pid {0}" -f $p.Id)
    if ($p.MainWindowHandle -eq 0) {
        Write-Host '    main window  : none (background copy)'
        continue
    }
    $cls = [ClineWindowProbe]::ClassName($p.MainWindowHandle)
    $aumid = [ClineWindowProbe]::Read($p.MainWindowHandle)
    Write-Host ("    main window  : hwnd 0x{0:X} title '{1}' class '{2}'" -f [Int64]$p.MainWindowHandle, $p.MainWindowTitle, $cls)
    Write-Host ("    store AUMID  : '{0}'" -f $aumid)
    $kids = @($procMap.Keys | Where-Object { $procMap[$_] -eq $p.Id })
    Write-Host ("    webview kids : {0} msedgewebview2.exe child process(es) - never stamp these" -f $kids.Count)
}
$exePath = Join-Path $env:LOCALAPPDATA 'Cline\cline-app.exe'
if (Test-Path $exePath) {
    # Latin-1 (byte-preserving) text scan - a per-byte PS loop over a
    # multi-MB exe would take minutes; IndexOf on the decoded text is
    # a single native pass.
    $text = [System.IO.File]::ReadAllText($exePath, [System.Text.Encoding]::GetEncoding(28591))
    $found = $text.Contains('SetCurrentProcessExplicitAppUserModelID')
    Write-Host ("--- exe scan  : SetCurrentProcessExplicitAppUserModelID present in cline-app.exe: {0}" -f $found)
} else {
    Write-Host "--- exe scan  : cline-app.exe not found at $exePath"
}
Write-Host ''
Write-Host 'probe (d) is manual: launch a clone via the launcher (it stamps), then re-run this probe and compare the store AUMID per pid.'
