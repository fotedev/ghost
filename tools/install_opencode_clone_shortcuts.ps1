#requires -Version 5.1
<#
.SYNOPSIS
  Installs (or removes) Desktop + Start Menu shortcuts for the OpenCode
  desktop CLONE instances (c1..c5). Default: all five.

.DESCRIPTION
  A Windows .lnk cannot carry the --opencode-clone-home isolation flag, so
  every shortcut points at src\windows\launch_opencode_clone.ps1
  -Instance <id>, which verifies the clone-home asar patch, writes the
  clone identity marker and starts OpenCode.exe with the per-clone flag -
  any future launcher fix automatically applies to the shortcuts (same
  pattern as the Cline/AutoClaw2 installers).

  Per-clone icons: tools\opencode-<color>-branding\tray_icon.ico
  (blue/yellow/green/red staged 2026-10-17 from developer renders; orange
  generated 2026-10-24 via tools\make_clone_icon.ps1 -HueRotate 180 from
  the blue master - PLACEHOLDER, drop developer renders at
  tools\opencode-orange-branding\ and re-run this installer). Missing
  branding falls back to the OpenCode.exe icon - never a set-but-absent
  path.

  AUMID: each shortcut gets System.AppUserModel.ID =
  ai.opencode.desktop.cN (base ai.opencode.desktop declared by the app;
  read from the stock Start Menu OpenCode.lnk when present via
  Shell.Application ExtendedProperty - never raw .lnk decoding). Unlike
  the Cline suite, the RUNNING windows also declare the suffixed AUMID
  (the clone-home asar patch wraps the app's single setAppUserModelId
  call + stamps windows via browser-window-created), so taskbar grouping
  and pins are both per-clone.

  -RepairPrimaryAumid: pinning a clone window can rewrite the stock
  OpenCode.lnk with a clone AUMID and wipe its icon (EC-C01, the ZCode
  hijack class) - this strips clone suffixes back to the base AUMID and
  restores the exe icon across Desktop and Start Menu locations. The
  resident check is manual here (the ZCode watcher pattern is not wired
  for OpenCode); re-run this switch after a confirmed hijack.

  Per-user locations only -> NO admin rights needed.

.PARAMETER Remove
  Delete the clone shortcuts instead of creating them.

.PARAMETER Instance
  Install/Remove a single clone (c1..c5) instead of all five.

.PARAMETER RepairPrimaryAumid
  Repair the stock OpenCode.lnk after a clone-AUMID hijack (strips
  suffixes, restores the exe icon). Implies no shortcut creation.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_opencode_clone_shortcuts.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_opencode_clone_shortcuts.ps1 -Instance c3
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_opencode_clone_shortcuts.ps1 -Remove
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_opencode_clone_shortcuts.ps1 -RepairPrimaryAumid
#>
param(
    [switch]$Remove,
    [switch]$RepairPrimaryAumid,
    [ValidateSet('c1','c2','c3','c4','c5','')]
    [string]$Instance = ''
)
$ErrorActionPreference = 'Stop'

$scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot   = Split-Path -Parent $scriptPath
$Launcher   = Join-Path $RepoRoot 'src\windows\launch_opencode_clone.ps1'
$ExeCandidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop\OpenCode.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\opencode\OpenCode.exe')
)
$ExePath = $null
foreach ($c in $ExeCandidates) { if (Test-Path $c) { $ExePath = $c; break } }
$Desktop    = [Environment]::GetFolderPath('Desktop')
$StartMenu  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

if (-not (Test-Path $Launcher)) { Write-Error "launcher not found: $Launcher" }

$InstanceDefs = @{
    'c1' = @{ ShortcutName = 'OpenCode c1.lnk'; BrandingRepo = 'opencode-blue-branding';   DisplayName = 'Blue' }
    'c2' = @{ ShortcutName = 'OpenCode c2.lnk'; BrandingRepo = 'opencode-yellow-branding'; DisplayName = 'Yellow' }
    'c3' = @{ ShortcutName = 'OpenCode c3.lnk'; BrandingRepo = 'opencode-green-branding';  DisplayName = 'Green' }
    'c4' = @{ ShortcutName = 'OpenCode c4.lnk'; BrandingRepo = 'opencode-red-branding';    DisplayName = 'Red' }
    'c5' = @{ ShortcutName = 'OpenCode c5.lnk'; BrandingRepo = 'opencode-orange-branding'; DisplayName = 'Orange' }
}

$TargetIds = if ($Instance) { @($Instance) } else { @('c1','c2','c3','c4','c5') }

# --- AUMID plumbing: COM IPersistFile + IPropertyStore (mirror of the
# --- live-verified AutoClaw/Cline installer implementation, ShellLink COM route).
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

# Base AUMID: read from the stock Start Menu OpenCode.lnk (the app declares
# ai.opencode.desktop); verified constant as the fallback.
$BaseAumid = 'ai.opencode.desktop'
$stockLnk  = Join-Path $StartMenu 'OpenCode.lnk'
if (Test-Path $stockLnk) {
    $readAumid = Get-ShortcutAumid $stockLnk
    if ($readAumid) { $BaseAumid = $readAumid }
}

if ($RepairPrimaryAumid) {
    if (-not $ExePath) { Write-Error "OpenCode.exe not found - cannot restore the stock icon" }
    # The stock shortcut may carry the base AUMID already or a hijacked
    # base.cN one; only a suffixed value is a hijack (EC-C01).
    $repaired = 0
    foreach ($lnk in @((Join-Path $Desktop 'OpenCode.lnk'), (Join-Path $StartMenu 'OpenCode.lnk'))) {
        if (-not (Test-Path $lnk)) { continue }
        $aumid = Get-ShortcutAumid $lnk
        if (-not $aumid) { Write-Host "no AUMID on $lnk - nothing to repair"; continue }
        if ($aumid -eq $BaseAumid) { Write-Host "clean    : $lnk ($aumid)"; continue }
        if (-not $aumid.StartsWith($BaseAumid + '.')) {
            Write-Host "foreign  : $lnk AUMID '$aumid' does not start with '$BaseAumid.' - leaving untouched"
            continue
        }
        Set-ShortcutAumid -LnkPath $lnk -Aumid $BaseAumid
        $sh2 = New-Object -ComObject WScript.Shell
        $s2  = $sh2.CreateShortcut($lnk)
        $s2.IconLocation = "$ExePath,0"
        $s2.Save()
        $back = Get-ShortcutAumid $lnk
        $chk  = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $ok   = ($back -eq $BaseAumid) -and ($chk.IconLocation -like "$ExePath*")
        Write-Host ("{0} : repaired {1} -> aumid={2} icon={3}" -f $(if ($ok) {'OK  '} else {'FAIL'}), $lnk, $back, $chk.IconLocation)
        if ($ok) { $repaired++ } 
    }
    if ($repaired -gt 0) {
        Write-Host ""
        Write-Host "repaired $repaired shortcut(s). Pin the Primary again from a running stock OpenCode window if the Start pin still looks wrong."
    } else {
        Write-Host "nothing needed repairing."
    }
    return
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
        if (-not $iconPath) {
            Write-Warning "OpenCode.exe not found either - falling back to the powershell host icon"
            $iconPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        }
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`" -Instance $id"
        $s.WorkingDirectory = Split-Path -Parent $Launcher
        $s.IconLocation     = "$iconPath,0"
        $s.Description      = "OpenCode clone $id ($($def.DisplayName)) - isolated clone home"
        $s.Save()

        try { Set-ShortcutAumid -LnkPath $lnk -Aumid $aumid } catch { Write-Warning "AUMID set failed on $lnk : $($_.Exception.Message)" }

        $chk = $sh.CreateShortcut($lnk)
        $ok  = ($chk.TargetPath -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -and
               ($chk.Arguments -match "launch_opencode_clone\.ps1.*-Instance $id")
        $aumidBack = Get-ShortcutAumid $lnk
        Write-Host ("{0} : {1}  aumid={2}" -f $(if ($ok) {'OK  '} else {'FAIL'}), $lnk, $(if ($aumidBack) { $aumidBack } else { '<none>' }))
    }
}

if (-not $Remove) {
    Write-Host ""
    Write-Host "shortcuts installed. Start clones SEQUENTIALLY (double-click one at a time," -ForegroundColor Green
    Write-Host "or run launch_opencode_clones_all.ps1 once)." -ForegroundColor Green
}
