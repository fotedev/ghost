#requires -Version 5.1
<#
.SYNOPSIS
  Installs (or removes) Desktop + Start Menu shortcuts for the AutoClaw2
  CLONE instances (c1..c5). Default: all five.

.DESCRIPTION
  A Windows .lnk cannot set environment variables, and each AutoClaw2 clone
  is fully driven by ZWORK_USER_DATA / AUTOCLAW_PROFILE_ROOT. So every
  shortcut points at src\windows\launch_autoclaw2_clone.ps1 -Instance <id>,
  which sets the isolation env and starts AutoClaw2.exe - any future
  launcher fix automatically applies to the shortcuts (same pattern as
  tools\install_autoclaw_clone_shortcuts.ps1 for the v1.20 suite).

  Per-clone icons: tools\autoclaw2-<color>-branding\tray_icon.ico generated
  by tools\make_clone_icon.ps1 from the app's own 512x512 app-icon-square
  asset (a monochrome WHITE logo - hue-rotate is a no-op on gray art, so
  the first run shipped five byte-identical icons; fixed 2026-10-23 with
  the -TintHue/-TintSat colorize mode). Tints calibrated from the old
  autoclaw/zcode suites: blue 206 / yellow 46 / green 166 / red 356 /
  orange 25 (sat 0.82-0.98, value preserved, dark tile background
  untouched). Missing branding
  falls back to the AutoClaw2.exe icon - never a set-but-absent path.

  AUMID: each shortcut gets System.AppUserModel.ID =
  com.zhipuai.autoclaw2.cN (base com.zhipuai.autoclaw2 is declared by the
  app itself in main.cjs; read from the stock AutoClaw.lnk when present).
  Known limitation (shared with v1 suite): RUNNING windows declare the
  base AUMID, so taskbar GROUPING shows one button while pins stay
  per-clone until a window-level patch exists. Do not regress the
  Shell.Application ExtendedProperty read rule (no raw .lnk regex).

  Per-user locations only -> NO admin rights needed.

.PARAMETER Remove
  Delete the clone shortcuts instead of creating them.

.PARAMETER Instance
  Install/Remove a single clone (c1..c5) instead of all five.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -Instance c3
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -Remove
#>
param(
    [switch]$Remove,
    [ValidateSet('c1','c2','c3','c4','c5','')]
    [string]$Instance = ''
)
$ErrorActionPreference = 'Stop'

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot   = Split-Path -Parent $scriptPath
$Launcher  = Join-Path $RepoRoot 'src\windows\launch_autoclaw2_clone.ps1'
$Desktop   = [Environment]::GetFolderPath('Desktop')
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

if (-not (Test-Path $Launcher)) { Write-Error "launcher not found: $Launcher" }

$InstanceDefs = @{
    'c1' = @{ ShortcutName = 'AutoClaw2 c1.lnk'; BrandingRepo = 'autoclaw2-blue-branding';   DisplayName = 'Blue' }
    'c2' = @{ ShortcutName = 'AutoClaw2 c2.lnk'; BrandingRepo = 'autoclaw2-yellow-branding'; DisplayName = 'Yellow' }
    'c3' = @{ ShortcutName = 'AutoClaw2 c3.lnk'; BrandingRepo = 'autoclaw2-green-branding';  DisplayName = 'Green' }
    'c4' = @{ ShortcutName = 'AutoClaw2 c4.lnk'; BrandingRepo = 'autoclaw2-red-branding';    DisplayName = 'Red' }
    'c5' = @{ ShortcutName = 'AutoClaw2 c5.lnk'; BrandingRepo = 'autoclaw2-orange-branding'; DisplayName = 'Orange' }
}

$TargetIds = if ($Instance) { @($Instance) } else { @('c1','c2','c3','c4','c5') }

# --- AUMID plumbing: COM IPersistFile + IPropertyStore (mirror of the
# --- live-verified v1 installer implementation, ShellLink COM route).
function Add-AumidType {
  if ('ShortcutAumid' -as [type]) { return }
  $cs = @'
using System;
using System.Runtime.InteropServices;

public static class ShortcutAumid
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class ShellLinkCom { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010B-0000-0000-C000-000000000046")]
    private interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY { public Guid fmtid; public uint pid; }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint cProps);
        [PreserveSig] int GetAt(uint iProp, out PROPERTYKEY pkey);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        [PreserveSig] int Commit();
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)] // native x64 PROPVARIANT is 24 bytes
    private struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr ptr;
    }

    private const ushort VT_LPWSTR = 31;
    private static PROPERTYKEY AppIdKey()
    {
        PROPERTYKEY k;
        k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        k.pid = 5;
        return k;
    }

    public static void Set(string lnkPath, string aumid)
    {
        IPersistFile pf = (IPersistFile)new ShellLinkCom();
        pf.Load(lnkPath, 2); // STGM_READWRITE
        IPropertyStore ps = (IPropertyStore)pf;
        PROPERTYKEY key = AppIdKey();
        PROPVARIANT pv = new PROPVARIANT();
        pv.vt = VT_LPWSTR;
        pv.ptr = Marshal.StringToCoTaskMemUni(aumid);
        int hr = ps.SetValue(ref key, ref pv);
        Marshal.FreeCoTaskMem(pv.ptr);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        hr = ps.Commit();
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        pf.Save(lnkPath, true);
    }
}
'@
  Add-Type -TypeDefinition $cs
}

function Get-ShortcutAumid {
    param([string]$LnkPath)
    try {
        $shell  = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path -Parent $LnkPath))
        $item   = $folder.ParseName((Split-Path -Leaf $LnkPath))
        $val    = $item.ExtendedProperty('System.AppUserModel.ID')
        if ($val) { return [string]$val }
    } catch { }
    return $null
}

function Set-ShortcutAumid {
    param([string]$LnkPath, [string]$Aumid)
    Add-AumidType
    [ShortcutAumid]::Set($LnkPath, $Aumid)
}

$sh = New-Object -ComObject WScript.Shell
# v2 contract (launch_autoclaw2_clone.ps1:38-39): base AUMID com.zhipuai.autoclaw2,
# shortcuts carry com.zhipuai.autoclaw2.cN. The old code derived the base from the
# V1 Desktop AutoClaw.lnk - cross-suite contamination: every v2 shortcut got
# com.zhipuai.autoclaw.c1..c5 (or a bare ".cN" when the lnk was absent or
# AUMID-less). The constant wins; no lnk read.
$BaseAumid = 'com.zhipuai.autoclaw2'
$script:Failed = $false

foreach ($id in $TargetIds) {
    $def       = $InstanceDefs[$id]
    $exe       = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\AutoClaw2.exe'
    $iconRel   = "tools\$($def.BrandingRepo)\tray_icon.ico"
    $iconPath  = Join-Path $RepoRoot $iconRel
    $aumid     = "$BaseAumid.$id"

    foreach ($root in @($Desktop, $StartMenu)) {
        $lnk = Join-Path $root $def.ShortcutName
        if ($Remove) {
            if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "removed: $lnk" }
            continue
        }
        if (-not (Test-Path $iconPath)) {
            Write-Warning "icon missing ($iconPath) - falling back to exe icon"
            $iconPath = $exe
        }
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`" -Instance $id"
        $s.WorkingDirectory = Split-Path -Parent $Launcher
        $s.IconLocation     = "$iconPath,0"
        $s.Description      = "AutoClaw2 clone $id ($($def.DisplayName)) - isolated profile"
        $s.Save()

        try { Set-ShortcutAumid -LnkPath $lnk -Aumid $aumid } catch { Write-Warning "AUMID set failed on $lnk : $($_.Exception.Message)"; $script:Failed = $true }

        $chk = $sh.CreateShortcut($lnk)
        $aumidBack = Get-ShortcutAumid $lnk
        $ok  = ($chk.TargetPath -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -and
               ($chk.Arguments -match "launch_autoclaw2_clone\.ps1.*-Instance $id") -and
               ($aumidBack -eq $aumid)
        if (-not $ok) { $script:Failed = $true }
        Write-Host ("{0} : {1}  aumid={2}" -f $(if ($ok) {'OK  '} else {'FAIL'}), $lnk, $(if ($aumidBack) { $aumidBack } else { '<none>' }))
    }
}

if (-not $Remove) {
    Write-Host ""
    Write-Host "shortcuts installed. Start clones SEQUENTIALLY (double-click one at a time," -ForegroundColor Green
    Write-Host "or run launch_autoclaw2_clones_all.ps1 once)." -ForegroundColor Green
}
if ($script:Failed) { Write-Host 'FAILED - see FAIL lines above.' -ForegroundColor Red; exit 1 }
