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
  retarget the stock AutoClaw shortcut to a colored executable, stamp a
  clone AUMID (com.zhipuai.autoclaw2.cN), or both. Repairs only recognized
  stock shortcuts in Desktop and Start Menu Programs. Backs up the link,
  then restores and verifies the stock executable, AUMID and icon.
  Color-named clone shortcuts are untouched.

.PARAMETER RefreshTaskbar
  After a repair, rebuild the current AutoClaw2 window groups once. Used by
  the clone launcher so a cold start cannot leave the stock icon grouped
  under the clone even after the shortcut has been corrected.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -Instance c3
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -Remove
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_autoclaw2_clone_shortcuts.ps1 -RepairPrimaryAumid
#>
param(
    [switch]$Remove,
    [switch]$RepairPrimaryAumid,
    [switch]$RefreshTaskbar,
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
    . (Join-Path $PSScriptRoot 'autoclaw2_primary_lnk.ps1')
    $exe = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\AutoClaw2.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Error "AutoClaw2.exe not found: $exe - cannot restore the stock shortcut"
    }
    $repaired = 0
    foreach ($lnkPath in @(Get-Ac2PrimaryShortcutPaths)) {
        $shortcut = $sh.CreateShortcut($lnkPath)
        $aumid = Get-ShortcutAumid $lnkPath
        $problem = Get-Ac2PrimaryShortcutProblem -TargetPath $shortcut.TargetPath -Aumid $aumid -StockExe $exe
        if (-not $problem) { continue }

        $before = (Get-FileHash -LiteralPath $lnkPath).Hash
        $backupDir = Join-Path $env:LOCALAPPDATA ('autoclaw2-sync\shortcut-backups\' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        $backup = Join-Path $backupDir (Split-Path -Leaf $lnkPath)
        Copy-Item -LiteralPath $lnkPath -Destination $backup
        if ((Get-FileHash -LiteralPath $backup).Hash -ne $before) {
            throw "Backup did not verify for '$lnkPath' - shortcut not modified."
        }

        try {
            $shortcut.TargetPath = $exe
            $shortcut.WorkingDirectory = Split-Path -Parent $exe
            $shortcut.Arguments = ''
            $shortcut.IconLocation = "$exe,0"
            $shortcut.Save()
            Set-ShortcutAumid -LnkPath $lnkPath -Aumid $BaseAumid
            $chk = $sh.CreateShortcut($lnkPath)
            $back = Get-ShortcutAumid $lnkPath
            if (($back -ine $BaseAumid) -or ($chk.TargetPath -ine $exe) -or
                ($chk.Arguments -ne '') -or (($chk.IconLocation -replace ',\s*0$', ',0') -ine "$exe,0")) {
                throw "Shortcut read-back mismatch: target='$($chk.TargetPath)', AUMID='$back', icon='$($chk.IconLocation)'"
            }
            Write-Host "OK: repaired '$lnkPath' ($problem); verified stock target, AUMID and icon. Backup: $backup"
            $repaired++
        } catch {
            Write-Warning "FAILED to repair '$lnkPath': $($_.Exception.Message)"
            Copy-Item -LiteralPath $backup -Destination $lnkPath -Force
            if ((Get-FileHash -LiteralPath $lnkPath).Hash -ne $before) {
                throw "Shortcut rollback did not verify; saved backup: $backup"
            }
            Write-Warning "Original shortcut restored and verified from '$backup'."
            $script:Failed = $true
        }
    }
    if ($repaired -gt 0) {
        Write-Host ""
        Write-Host "repaired $repaired shortcut(s). Re-pin from a running STOCK AutoClaw2 window if a pin still resolves to a clone identity."
        if ($RefreshTaskbar) {
            $watcher = Join-Path $PSScriptRoot 'watch_suite_taskbar.ps1'
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            & $psExe -NoProfile -ExecutionPolicy Bypass -File $watcher -Suite autoclaw2 -RunOnce
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'Shortcut repaired, but the live taskbar refresh failed.'
                $script:Failed = $true
            }
            # The refresh can exercise Explorer's shortcut resolution too.
            foreach ($path in @(Get-Ac2PrimaryShortcutPaths)) {
                $check = $sh.CreateShortcut($path)
                $id = Get-ShortcutAumid $path
                if (Get-Ac2PrimaryShortcutProblem -TargetPath $check.TargetPath -Aumid $id -StockExe $exe) {
                    Write-Warning "Stock shortcut drifted again after the taskbar refresh: $path"
                    $script:Failed = $true
                }
            }
        }
    } else {
        Write-Host "nothing needed repairing."
    }
    if (-not $Remove) {
        # 14-L3: a bare repair ends here. With -Remove both switches are
        # honored - the old unconditional return silently dropped the removal.
        if ($script:Failed) { Write-Host 'FAILED - see FAIL lines above.' -ForegroundColor Red; exit 1 }
        return
    }
    if ($script:Failed) {
        Write-Host 'repair FAILED - continuing to -Remove; its exit code reflects every failure.' -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "repair done - continuing to -Remove."
    }
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
                # 14-L4: verify-after on the delete (mirrors the zcode installer).
                if (Test-Path -LiteralPath $candidate) {
                    Remove-Item -LiteralPath $candidate -Force
                    if (Test-Path -LiteralPath $candidate) {
                        Write-Host "FAILED: still exists after delete: $candidate" -ForegroundColor Red
                        $script:Failed = $true
                    } else {
                        Write-Host "removed: $candidate"
                    }
                }
            }
            continue
        }
        if ((Test-Path $legacyLnk) -and ($legacyLnk -ine $lnk)) {
            # 2026-11-01 display-name unification: drop the pre-rename shortcut
            # so the Desktop/Start menu keeps exactly one entry per clone.
            Remove-Item $legacyLnk -Force
            Write-Host "removed legacy: $legacyLnk"
        }
        $iconResolved = $iconPath
        if (-not (Test-Path -LiteralPath $iconResolved)) {
            # 14-M3: the fallback must keep the header contract "never a
            # set-but-absent icon path" - only fall back when the exe exists.
            if (Test-Path -LiteralPath $exe) {
                Write-Warning "icon missing ($iconPath) - falling back to the exe icon"
                $iconResolved = $exe
            } else {
                Write-Warning "icon missing ($iconPath) AND the exe is absent ($exe) - IconLocation left unset (the run FAILs below)"
                $script:Failed = $true
                $iconResolved = $null
            }
        }
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`" -Instance $id"
        $s.WorkingDirectory = Split-Path -Parent $Launcher
        if ($iconResolved) { $s.IconLocation = "$iconResolved,0" }
        $s.Description      = "AutoClaw2 $($def.DisplayName) clone - isolated profile"
        $s.Save()

        try { Set-ShortcutAumid -LnkPath $lnk -Aumid $aumid } catch { Write-Warning "AUMID set failed on $lnk : $($_.Exception.Message)"; $script:Failed = $true }

        $chk = $sh.CreateShortcut($lnk)
        $aumidBack = Get-ShortcutAumid $lnk
        # Verify-after covers the icon too: "$path,index" -> the path must be
        # ABSOLUTE and exist (a relative IconLocation renders a blank shortcut
        # icon - the live bug this suite shipped with, fixed 2026-10-29).
        $iconBack = ($chk.IconLocation -replace ',\d+$', '')
        if ($iconResolved) {
            $iconOk = ($iconBack -ieq $iconResolved) -and [System.IO.Path]::IsPathRooted($iconBack) -and (Test-Path -LiteralPath $iconBack)
        } else {
            # 14-M3 unset-icon case: the IconLocation must be genuinely empty.
            $iconOk = [string]::IsNullOrWhiteSpace($chk.IconLocation)
        }
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
