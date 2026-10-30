#requires -Version 5.1
<#
.SYNOPSIS
  Installs (or removes) Desktop + Start Menu shortcuts for the Cline
  CLONE instances (c1..c5). Default: all five.

.DESCRIPTION
  A Windows .lnk cannot set environment variables, and each Cline clone
  is fully driven by CLINE_DIR / WEBVIEW2_USER_DATA_FOLDER /
  CLINE_HUB_PORT / CLINE_SIDECAR_PORT. So every shortcut points at
  src\windows\launch_cline_clone.ps1 -Instance <id>, which sets the
  isolation env, neutralizes the single-instance window and starts
  cline-app.exe - any future launcher fix automatically applies to the
  shortcuts (same pattern as the AutoClaw2 installer).

  Per-clone icons: tools\cline-<color>-branding\tray_icon.ico (blue/
  yellow/green/red staged 2026-10-17 from developer renders; orange
  generated 2026-10-24 via tools\make_clone_icon.ps1 -TintHue from the
  blue master). Missing branding falls back to the cline-app.exe icon -
  never a set-but-absent path.

  AUMID: each shortcut gets System.AppUserModel.ID = bot.cline.app.cN
  (base bot.cline.app declared by the app; read from the stock Start
  Menu Cline.lnk when present). Known limitation (developer decision
  2026-10-24): RUNNING windows declare the base identity, so taskbar
  GROUPING shows one button while pins stay per-clone - no window-level
  patch (nothing to patch: the app is Tauri/WebView2, no asar). Do not
  regress the Shell.Application ExtendedProperty read rule (no raw .lnk
  regex).

  Per-user locations only -> NO admin rights needed.

.PARAMETER Remove
  Delete the clone shortcuts instead of creating them.

.PARAMETER Instance
  Install/Remove a single clone (c1..c5) instead of all five.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_cline_clone_shortcuts.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_cline_clone_shortcuts.ps1 -Instance c3
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_cline_clone_shortcuts.ps1 -Remove
#>
param(
    [switch]$Remove,
    [ValidateSet('c1','c2','c3','c4','c5','')]
    [string]$Instance = ''
)
$ErrorActionPreference = 'Stop'

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot   = Split-Path -Parent $scriptPath
# A relative $RepoRoot (bare-filename $MyInvocation fallback) once leaked a
# RELATIVE path into the .lnk IconLocation - Windows cannot resolve a relative
# icon path, so every shortcut rendered BLANK (live bug found 2026-10-29 on
# the Desktop/Start Menu/taskbar icons). Resolve against the current location
# and refuse to continue when the root is not absolute.
$RepoRoot = (Resolve-Path $RepoRoot).ProviderPath
if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
    throw "repo root resolved non-absolute: '$RepoRoot' - run the installer against the real repo folder"
}
$Launcher   = Join-Path $RepoRoot 'src\windows\launch_cline_clone.ps1'
$ExePath    = Join-Path $env:LOCALAPPDATA 'Cline\cline-app.exe'
$Desktop    = [Environment]::GetFolderPath('Desktop')
$StartMenu  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

if (-not (Test-Path $Launcher)) { Write-Error "launcher not found: $Launcher" }

$InstanceDefs = @{
    'c1' = @{ ShortcutName = 'Cline c1.lnk'; BrandingRepo = 'cline-blue-branding';   DisplayName = 'Blue' }
    'c2' = @{ ShortcutName = 'Cline c2.lnk'; BrandingRepo = 'cline-yellow-branding'; DisplayName = 'Yellow' }
    'c3' = @{ ShortcutName = 'Cline c3.lnk'; BrandingRepo = 'cline-green-branding';  DisplayName = 'Green' }
    'c4' = @{ ShortcutName = 'Cline c4.lnk'; BrandingRepo = 'cline-red-branding';    DisplayName = 'Red' }
    'c5' = @{ ShortcutName = 'Cline c5.lnk'; BrandingRepo = 'cline-orange-branding'; DisplayName = 'Orange' }
}

$TargetIds = if ($Instance) { @($Instance) } else { @('c1','c2','c3','c4','c5') }

# --- AUMID plumbing: COM IPersistFile + IPropertyStore (mirror of the
# --- live-verified AutoClaw installer implementation, ShellLink COM route).
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

# Base AUMID: read from the stock Start Menu Cline.lnk (the app declares
# bot.cline.app); verified constant as the fallback.
$BaseAumid = 'bot.cline.app'
$stockLnk  = Join-Path $StartMenu 'Cline.lnk'
if (Test-Path $stockLnk) {
    $readAumid = Get-ShortcutAumid $stockLnk
    if ($readAumid) { $BaseAumid = $readAumid }
}

$sh = New-Object -ComObject WScript.Shell

foreach ($id in $TargetIds) {
    $def      = $InstanceDefs[$id]
    $iconPath = Join-Path $RepoRoot "tools\$($def.BrandingRepo)\tray_icon.ico"
    $aumid    = "$BaseAumid.$id"

    foreach ($root in @($Desktop, $StartMenu)) {
        $lnk = Join-Path $root $def.ShortcutName
        if ($Remove) {
            if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host "removed: $lnk" }
            continue
        }
        if (-not (Test-Path $iconPath)) {
            Write-Warning "icon missing ($iconPath) - falling back to exe icon"
            $iconPath = $ExePath
        }
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`" -Instance $id"
        $s.WorkingDirectory = Split-Path -Parent $Launcher
        $s.IconLocation     = "$iconPath,0"
        $s.Description      = "Cline clone $id ($($def.DisplayName)) - isolated profile"
        $s.Save()

        try { Set-ShortcutAumid -LnkPath $lnk -Aumid $aumid } catch { Write-Warning "AUMID set failed on $lnk : $($_.Exception.Message)" }

        $chk = $sh.CreateShortcut($lnk)
        # Verify-after covers the icon too: "$path,index" -> the path must be
        # ABSOLUTE and exist (a relative IconLocation renders a blank shortcut
        # icon - the live bug this suite shipped with, fixed 2026-10-29).
        $iconBack = ($chk.IconLocation -replace ',\d+$', '')
        $iconOk   = ($iconBack -ieq $iconPath) -and [System.IO.Path]::IsPathRooted($iconBack) -and (Test-Path -LiteralPath $iconBack)
        $ok  = ($chk.TargetPath -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -and
               ($chk.Arguments -match "launch_cline_clone\.ps1.*-Instance $id") -and
               $iconOk
        $aumidBack = Get-ShortcutAumid $lnk
        Write-Host ("{0} : {1}  aumid={2}  icon={3}" -f $(if ($ok) {'OK  '} else {'FAIL'}), $lnk, $(if ($aumidBack) { $aumidBack } else { '<none>' }), $(if ($iconOk) { $iconBack } else { "BAD: $($chk.IconLocation)" }))
    }
}

if (-not $Remove) {
    Write-Host ""
    Write-Host "shortcuts installed. Start clones SEQUENTIALLY (double-click one at a time," -ForegroundColor Green
    Write-Host "or run launch_cline_clones_all.ps1 once)." -ForegroundColor Green
}
