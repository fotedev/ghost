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
  tools\install_zcode_second_shortcuts.ps1; the v1.20 installer this file
  originally mirrored left with the v1.20 sunset).

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
  com.zhipuai.autoclaw2.cN. The base constant wins - deriving it from the
  v1 Desktop lnk once contaminated every v2 shortcut (cross-suite bug,
  fixed 2026). Since 2026-11-06 the RUNNING windows carry the same
  suffixed AUMID + colored icon via the window identity patch
  (tools\patch_autoclaw2_identity.ps1, ZWORK_AUMID/ZWORK_CLONE_ICON) -
  see spec §7 - so pins and windows group together. Do not regress the
  Shell.Application ExtendedProperty read rule (no raw .lnk regex).

  Per-user locations only -> NO admin rights needed.

.PARAMETER Remove
  Delete the clone shortcuts instead of creating them.

.PARAMETER Instance
  Install/Remove a single clone (c1..c5) instead of all five.

.PARAMETER RepairPrimaryAumid
  EC-C01 repair: pinning a clone window (or taskbar pin maintenance) can
  rewrite a STOCK AutoClaw2 shortcut with a clone AUMID
  (com.zhipuai.autoclaw2.cN) and wipe its IconLocation. Scans every
  shortcut in the Desktop + Start-menu Programs locations that targets
  AutoClaw2.exe, strips a clone-suffixed AUMID back to the base and
  restores the exe icon. Nothing else is touched.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -Instance c3
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -Remove
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -RepairPrimaryAumid
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
# A relative $RepoRoot (bare-filename $MyInvocation fallback) once leaked a
# RELATIVE path into the .lnk IconLocation - Windows cannot resolve a relative
# icon path, so every shortcut rendered BLANK (live bug found 2026-10-29 on
# the Desktop/Start Menu/taskbar icons). Resolve against the current location
# and refuse to continue when the root is not absolute.
$RepoRoot = (Resolve-Path $RepoRoot).ProviderPath
if (-not [System.IO.Path]::IsPathRooted($RepoRoot)) {
    throw "repo root resolved non-absolute: '$RepoRoot' - run the installer against the real repo folder"
}
$Launcher  = Join-Path $RepoRoot 'src\windows\launch_autoclaw2_clone.ps1'
$Desktop   = [Environment]::GetFolderPath('Desktop')
$StartMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'

if (-not (Test-Path $Launcher)) { Write-Error "launcher not found: $Launcher" }

# 2026-11-01 display-name unification: the shortcut FILE names use the color
# vocabulary shared by all four suites ("<Suite> <Color>.lnk"); the cN names
# are legacy and are cleaned up on every install/remove run. Instance keys,
# clone dirs and AUMIDs stay frozen.
$InstanceDefs = @{
    'c1' = @{ ShortcutName = 'AutoClaw2 Blue.lnk';   LegacyShortcutName = 'AutoClaw2 c1.lnk'; BrandingRepo = 'autoclaw2-blue-branding';   DisplayName = 'Blue' }
    'c2' = @{ ShortcutName = 'AutoClaw2 Yellow.lnk'; LegacyShortcutName = 'AutoClaw2 c2.lnk'; BrandingRepo = 'autoclaw2-yellow-branding'; DisplayName = 'Yellow' }
    'c3' = @{ ShortcutName = 'AutoClaw2 Green.lnk';  LegacyShortcutName = 'AutoClaw2 c3.lnk'; BrandingRepo = 'autoclaw2-green-branding';  DisplayName = 'Green' }
    'c4' = @{ ShortcutName = 'AutoClaw2 Red.lnk';    LegacyShortcutName = 'AutoClaw2 c4.lnk'; BrandingRepo = 'autoclaw2-red-branding';    DisplayName = 'Red' }
    'c5' = @{ ShortcutName = 'AutoClaw2 Orange.lnk'; LegacyShortcutName = 'AutoClaw2 c5.lnk'; BrandingRepo = 'autoclaw2-orange-branding'; DisplayName = 'Orange' }
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

if ($RepairPrimaryAumid) {
    # EC-C01 (P0): only a SUFFIXED base.<cN> value is a hijack; the base itself
    # and foreign AUMIDs are left untouched. AUMIDs are read via Shell
    # ExtendedProperty - never by decoding the .lnk bytes (EC-C09).
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\AutoClaw2.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Write-Error "AutoClaw2.exe not found: $exe - cannot restore the stock icon" }
    $repaired = 0
    foreach ($root in @($Desktop, $StartMenu)) {
        foreach ($lnkFile in @(Get-ChildItem -LiteralPath $root -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
            $t = $sh.CreateShortcut($lnkFile.FullName)
            if (-not $t.TargetPath -or ($t.TargetPath -ine $exe)) { continue }
            $aumid = Get-ShortcutAumid $lnkFile.FullName
            if (-not $aumid) { Write-Host "no AUMID  : $($lnkFile.FullName)"; continue }
            if ($aumid -eq $BaseAumid) { Write-Host "clean    : $($lnkFile.FullName) ($aumid)"; continue }
            if (-not $aumid.StartsWith($BaseAumid + '.')) {
                Write-Host "foreign  : $($lnkFile.FullName) AUMID '$aumid' does not start with '$BaseAumid.' - leaving untouched"
                continue
            }
            Set-ShortcutAumid -LnkPath $lnkFile.FullName -Aumid $BaseAumid
            $s2 = $sh.CreateShortcut($lnkFile.FullName)
            $s2.IconLocation = "$exe,0"
            $s2.Save()
            $back = Get-ShortcutAumid $lnkFile.FullName
            $chk = $sh.CreateShortcut($lnkFile.FullName)
            $ok = ($back -eq $BaseAumid) -and ($chk.IconLocation -like "$exe*")
            Write-Host ("{0} : repaired {1} -> aumid={2} icon={3}" -f $(if ($ok) {'OK  '} else {'FAIL'}), $lnkFile.FullName, $(if ($back) { $back } else { '<none>' }), $chk.IconLocation)
            if ($ok) { $repaired++ } else { $script:Failed = $true }
        }
    }
    if ($repaired -gt 0) {
        Write-Host ""
        Write-Host "repaired $repaired shortcut(s). Re-pin from a running STOCK AutoClaw2 window if a pin still resolves to a clone identity."
    } else {
        Write-Host "nothing needed repairing."
    }
    if ($script:Failed) { Write-Host 'FAILED - see FAIL lines above.' -ForegroundColor Red; exit 1 }
    return
}

foreach ($id in $TargetIds) {
    $def       = $InstanceDefs[$id]
    $exe       = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\AutoClaw2.exe'
    $iconRel   = "tools\$($def.BrandingRepo)\tray_icon.ico"
    $iconPath  = Join-Path $RepoRoot $iconRel
    $aumid     = "$BaseAumid.$id"

    foreach ($root in @($Desktop, $StartMenu)) {
        $lnk = Join-Path $root $def.ShortcutName
        $legacyLnk = Join-Path $root $def.LegacyShortcutName
        if ($Remove) {
            foreach ($candidate in @($lnk, $legacyLnk)) {
                if (Test-Path $candidate) { Remove-Item $candidate -Force; Write-Host "removed: $candidate" }
            }
            continue
        }
        if ((Test-Path $legacyLnk) -and ($legacyLnk -ine $lnk)) {
            # 2026-11-01 display-name unification: drop the pre-rename shortcut
            # so the Desktop/Start menu keeps exactly one entry per clone.
            Remove-Item $legacyLnk -Force
            Write-Host "removed legacy: $legacyLnk"
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
        $s.Description      = "AutoClaw2 $($def.DisplayName) clone - isolated profile"
        $s.Save()

        try { Set-ShortcutAumid -LnkPath $lnk -Aumid $aumid } catch { Write-Warning "AUMID set failed on $lnk : $($_.Exception.Message)"; $script:Failed = $true }

        $chk = $sh.CreateShortcut($lnk)
        $aumidBack = Get-ShortcutAumid $lnk
        # Verify-after covers the icon too: "$path,index" -> the path must be
        # ABSOLUTE and exist (a relative IconLocation renders a blank shortcut
        # icon - the live bug this suite shipped with, fixed 2026-10-29).
        $iconBack = ($chk.IconLocation -replace ',\d+$', '')
        $iconOk   = ($iconBack -ieq $iconPath) -and [System.IO.Path]::IsPathRooted($iconBack) -and (Test-Path -LiteralPath $iconBack)
        $ok  = ($chk.TargetPath -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') -and
               ($chk.Arguments -match "launch_autoclaw2_clone\.ps1.*-Instance $id") -and
               ($aumidBack -eq $aumid) -and
               $iconOk
        if (-not $ok) { $script:Failed = $true }
        Write-Host ("{0} : {1}  aumid={2}  icon={3}" -f $(if ($ok) {'OK  '} else {'FAIL'}), $lnk, $(if ($aumidBack) { $aumidBack } else { '<none>' }), $(if ($iconOk) { $iconBack } else { "BAD: $($chk.IconLocation)" }))
    }
}

if (-not $Remove) {
    Write-Host ""
    Write-Host "shortcuts installed. Start clones SEQUENTIALLY (double-click one at a time," -ForegroundColor Green
    Write-Host "or run launch_autoclaw2_clones_all.ps1 once)." -ForegroundColor Green
}
if ($script:Failed) { Write-Host 'FAILED - see FAIL lines above.' -ForegroundColor Red; exit 1 }
