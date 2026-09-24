#requires -Version 5.1
<#
.SYNOPSIS
  Installs (or removes) Desktop + Start Menu shortcuts for the ZCode CLONE
  instances (Second / Third / Fourth). Default: all three.

.DESCRIPTION
  A Windows .lnk cannot set environment variables, and each clone ZCode instance
  is fully driven by env vars (ZCODE_DATA_BASE_DIR / ZCODE_DESKTOP_USER_DATA_DIR /
  ZCODE_DESKTOP_SESSION_DATA_DIR / HOME / ZCODE_ICON_DIR / ZCODE_AUMID_SUFFIX /
  ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME).
  So each shortcut points at src\windows\launch_zcode_second_instance.ps1 with
  -Instance <name>, which sets the isolation env and launches ZCode detached
  (cmd /c start) - any future launcher fix automatically applies to the shortcuts.

  Per-user locations only -> NO admin rights needed:
    Desktop    : [Environment]::GetFolderPath('Desktop')
    Start Menu : %APPDATA%\Microsoft\Windows\Start Menu\Programs

  Every write is re-read and compared (no silent-success). Unless -SkipAumid is
  given, each shortcut also gets System.AppUserModel.ID = <installed ZCode AUMID>
  + ".<N>" (N = 2/3/4 - the same value the app.asar patch computes for that
  clone), so a taskbar pin groups with the running clone's window.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_zcode_second_shortcuts.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_zcode_second_shortcuts.ps1 -Instance Third
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_zcode_second_shortcuts.ps1 -Remove
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_zcode_second_shortcuts.ps1 -Remove -Instance Fourth
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_zcode_second_shortcuts.ps1 -DesktopOnly
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_zcode_second_shortcuts.ps1 -RepairPrimaryAumid
#>
[CmdletBinding()]
param(
  # Which clone shortcut(s) to manage. Default: all three.
  [ValidateSet('Second', 'Third', 'Fourth')]
  [string[]]$Instance = @('Second', 'Third', 'Fourth'),
  [switch]$Remove,
  [switch]$DesktopOnly,
  [switch]$StartMenuOnly,
  [switch]$SkipAumid,
  [switch]$RepairPrimaryAumid
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Launcher = Join-Path $RepoRoot 'src\windows\launch_zcode_second_instance.ps1'

# Must stay in sync with the InstanceMap in launch_zcode_second_instance.ps1.
# Second is FROZEN (existing installed profile); Third = Yellow, Fourth = Green.
$InstanceDefs = @{
  'Second' = @{ ShortcutName = 'ZCode Second.lnk'; AumidSuffix = '2'
                BrandingRepo = 'zcode-blue-branding';   DisplayName = 'Blue' }
  'Third'  = @{ ShortcutName = 'ZCode Third.lnk';  AumidSuffix = '3'
                BrandingRepo = 'zcode-yellow-branding'; DisplayName = 'Yellow' }
  'Fourth' = @{ ShortcutName = 'ZCode Fourth.lnk'; AumidSuffix = '4'
                BrandingRepo = 'zcode-green-branding';  DisplayName = 'Green' }
}
$script:Failed = $false

if ($DesktopOnly -and $StartMenuOnly) { $DesktopOnly = $false; $StartMenuOnly = $false }

function Get-ShortcutTargets {
  param([string]$ShortcutName)
  $targets = @()
  if (-not $StartMenuOnly) {
    $targets += Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
  }
  if (-not $DesktopOnly) {
    $targets += Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$ShortcutName"
  }
  return $targets
}

function Assert-Value {
  param([string]$Name, [string]$Expected, [string]$Actual)
  if ($Actual -ieq $Expected) {
    Write-Host "      [ok] $Name" -ForegroundColor Green
  } else {
    Write-Host "      [FAILED] $Name : expected '$Expected' but read '$Actual'" -ForegroundColor Red
    $script:Failed = $true
  }
}
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

function Get-LnkAumid {
  # Reads System.AppUserModel.ID via the Shell property system. Verified to see
  # exactly what ShortcutAumid.Set persists; raw IPropertyStore::GetValue interop
  # returned VT_EMPTY for every key on PS 5.1 (marshaling), so it is not used.
  param([string]$Path)
  $sh = New-Object -ComObject Shell.Application
  $ns = $sh.Namespace((Split-Path -Parent $Path))
  if (-not $ns) { return $null }
  $item = $ns.ParseName((Split-Path -Leaf $Path))
  if (-not $item) { return $null }
  $v = $item.ExtendedProperty('System.AppUserModel.ID')
  if ($null -eq $v) { return $null }
  return ([string]$v)
}

function Get-PrimaryLnkPaths {
  return @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk')
  )
}

function Repair-PrimaryAumid {
  # Pinning from a clone's taskbar entry (its window title differs, but older
  # revisions shared the title) can make Windows rewrite the PRIMARY's ZCode.lnk
  # stamped with the clone's AUMID ("<base>.<N>"). That stole the Primary's
  # Start-menu pin and let the empty-icon ZCode.lnk win taskbar icon resolution
  # for the clone. Strip any trailing ".<N>" clone suffix from the primary
  # shortcut's AUMID; verify by re-read.
  Add-AumidType
  $repaired = 0
  $base = $null
  foreach ($c in (Get-PrimaryLnkPaths)) {
    if (-not (Test-Path -LiteralPath $c)) { continue }
    $id = Get-LnkAumid $c
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    if ($base -eq $null) { $base = $id }
    if ($id -notmatch '\.\d+$') { continue }
    $clean = $id -replace '\.\d+$', ''
    try {
      [ShortcutAumid]::Set($c, $clean)
      $after = Get-LnkAumid $c
      if ($after -ieq $clean) {
        Write-Host "  [ok] repaired AUMID '$id' -> '$clean' in $c" -ForegroundColor Green
        $repaired++
        if ($base -eq $id) { $base = $clean }
      } else {
        Write-Host "  [FAILED] AUMID still '$after' after repair in $c" -ForegroundColor Red
        $script:Failed = $true
      }
    } catch {
      Write-Host "  [FAILED] AUMID repair on $c : $($_.Exception.Message)" -ForegroundColor Red
      $script:Failed = $true
    }
  }
  if ($repaired -eq 0) { Write-Host '  [ok] no clone AUMID collision on the primary shortcut.' -ForegroundColor Green }
  return $base
}

function Get-InstalledZCodeAumid {
  foreach ($c in (Get-PrimaryLnkPaths)) {
    if (Test-Path -LiteralPath $c) {
      $id = Get-LnkAumid $c
      if (-not [string]::IsNullOrWhiteSpace($id)) { return $id }
    }
  }
  return $null
}

if ($RepairPrimaryAumid) {
  Write-Host '[repair] Checking primary ZCode.lnk AUMID...'
  Add-AumidType
  [void](Repair-PrimaryAumid)
  if ($script:Failed) { Write-Host 'FAILED - see lines above.' -ForegroundColor Red; exit 1 }
  Write-Host 'SUCCESS - primary shortcut AUMID healthy.' -ForegroundColor Green
  Write-Host 'If the Start-menu pin did not come back by itself, right-click ZCode in' -ForegroundColor Yellow
  Write-Host 'the app list once and choose Pin to Start.' -ForegroundColor Yellow
  exit 0
}

if (-not (Test-Path -LiteralPath $Launcher)) { throw "Launcher not found: $Launcher" }
$psExe     = Join-Path $PSHOME 'powershell.exe'
$workDir   = Split-Path -Parent $Launcher

# Blue/yellow/green icons ride on the one-time app.asar patch; warn when absent.
$exeCandidates = @(
  (Join-Path $env:LOCALAPPDATA 'Programs\ZCode\ZCode.exe'),
  'C:\Program Files\ZCode\ZCode.exe',
  'C:\Program Files (x86)\ZCode\ZCode.exe'
)
$zexe = $exeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($zexe) {
  $marker = Join-Path (Split-Path -Parent $zexe) 'resources\zcode-icon-patch.marker.json'
  if (-not (Test-Path -LiteralPath $marker)) {
    Write-Host '  [warn] app.asar icon patch marker missing - window icons stay default until' -ForegroundColor Yellow
    Write-Host '         you close ZCode and run: tools\patch_zcode_icon_override.ps1 (menu [13])' -ForegroundColor Yellow
  }
}

if ($Remove) {
  Write-Host '[1/1] Removing shortcuts...'
  foreach ($inst in $Instance) {
    $def = $InstanceDefs[$inst]
    foreach ($t in (Get-ShortcutTargets -ShortcutName $def.ShortcutName)) {
      if (Test-Path -LiteralPath $t) {
        Remove-Item -LiteralPath $t -Force
        if (Test-Path -LiteralPath $t) {
          Write-Host "  [FAILED] still exists after delete: $t" -ForegroundColor Red
          $script:Failed = $true
        } else {
          Write-Host "  [ok] removed: $t" -ForegroundColor Green
        }
      } else {
        Write-Host "  [skip] not present: $t"
      }
    }
  }
  if ($script:Failed) { Write-Host 'FAILED - see lines above.' -ForegroundColor Red; exit 1 }
  Write-Host 'SUCCESS - shortcuts removed.' -ForegroundColor Green
  exit 0
}

Write-Host '[1/4] Resolving paths...'
$installed = @{}
foreach ($inst in $Instance) {
  $def = $InstanceDefs[$inst]
  $iconIco = Join-Path $RepoRoot "tools\$($def.BrandingRepo)\tray_icon.ico"
  $iconOk = Test-Path -LiteralPath $iconIco
  if (-not $iconOk) {
    Write-Host "  [warn] $($def.DisplayName) icon not found: $iconIco - '$($def.ShortcutName)' will use the default icon." -ForegroundColor Yellow
  }
  $installed[$inst] = @{
    Def          = $def
    IconIco      = $iconIco
    IconOk       = $iconOk
    IconLocation = "$iconIco,0"
    Description  = "Launch an independent $inst ZCode clone ($($def.DisplayName.ToLowerInvariant()) branding, separate taskbar button)"
    Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`" -Instance $inst"
    Targets      = @(Get-ShortcutTargets -ShortcutName $def.ShortcutName)
  }
}

Write-Host '[2/4] Creating shortcuts (verify-after)...'
$ws = New-Object -ComObject WScript.Shell
foreach ($inst in $Instance) {
  $spec = $installed[$inst]
  Write-Host "  [$inst] $($spec.Def.ShortcutName)"
  foreach ($t in $spec.Targets) {
    Write-Host "    -> $t"
    $sc = $ws.CreateShortcut($t)
    $sc.TargetPath = $psExe
    $sc.Arguments = $spec.Arguments
    $sc.WorkingDirectory = $workDir
    if ($spec.IconOk) { $sc.IconLocation = $spec.IconLocation }
    $sc.Description = $spec.Description
    $sc.Save()
    if (-not (Test-Path -LiteralPath $t)) {
      Write-Host "    [FAILED] .lnk not written: $t" -ForegroundColor Red
      $script:Failed = $true
      continue
    }
    $chk = $ws.CreateShortcut($t)
    Assert-Value 'TargetPath'       $psExe            $chk.TargetPath
    Assert-Value 'Arguments'        $spec.Arguments   $chk.Arguments
    Assert-Value 'WorkingDirectory' $workDir          $chk.WorkingDirectory
    if ($spec.IconOk) { Assert-Value 'IconLocation' $spec.IconLocation $chk.IconLocation }
  }
}

Write-Host '[3/4] Setting AppUserModel.ID for taskbar pin grouping...'
if ($SkipAumid) {
  Write-Host '  [skip] -SkipAumid given.'
} else {
  Add-AumidType
  # self-heal first: a collision (ZCode.lnk stamped with a clone suffix) would
  # otherwise poison the base computation below into dev.zcode.app.2.2
  $base = Repair-PrimaryAumid
  if ([string]::IsNullOrWhiteSpace($base)) {
    $base = Get-InstalledZCodeAumid
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    Write-Host '  [skip] Could not read AUMID from the installed ZCode shortcut.' -ForegroundColor Yellow
    Write-Host '         Shortcuts still work; a taskbar pin may show a separate button.' -ForegroundColor Yellow
  } else {
    foreach ($inst in $Instance) {
      $spec = $installed[$inst]
      $expected = "$base.$($spec.Def.AumidSuffix)"
      Write-Host "  [$inst] base AUMID = $base  ->  shortcut AUMID = $expected"
      foreach ($t in $spec.Targets) {
        if (-not (Test-Path -LiteralPath $t)) { continue }
        try {
          [ShortcutAumid]::Set($t, $expected)
          Assert-Value 'AppUserModel.ID' $expected (Get-LnkAumid $t)
        } catch {
          Write-Host "  [FAILED] AUMID set on $t : $($_.Exception.Message)" -ForegroundColor Red
          $script:Failed = $true
        }
      }
    }
  }
}

Write-Host '[4/4] Summary'
if ($script:Failed) {
  Write-Host 'FAILED - see [FAILED] lines above.' -ForegroundColor Red
  exit 1
}
foreach ($inst in $Instance) {
  foreach ($t in $installed[$inst].Targets) { Write-Host "  installed: $t" -ForegroundColor Green }
}
Write-Host 'SUCCESS - double-click a clone shortcut on the Desktop or find it in the Start menu.' -ForegroundColor Green
Write-Host 'Optional: right-click a shortcut -> Pin to taskbar; the pin groups with that clone''s window.'
Write-Host 'Remove later with: tools\install_zcode_second_shortcuts.ps1 -Remove'
exit 0
