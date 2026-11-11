#requires -Version 5.1
<#
.SYNOPSIS
  Builds per-clone ZCode.exe copies ("ZCode-Blue.exe" ... "ZCode-Orange.exe")
  in the install dir and patches their embedded icon + FileDescription, so
  Windows Task Manager renders one colored, named group per clone instead of
  six identical stock "ZCode (N)" rows.

.DESCRIPTION
  Task Manager's background-process groups take their display name and icon
  from the executable IMAGE itself (VERSIONINFO FileDescription + embedded
  icon resource) - not from AUMID shortcuts or window properties. All six
  instances run the same ZCode.exe, so the taskbar identity stack (per-clone
  AUMIDs, colored shortcuts, window stamping, ZCODE_ICON_DIR window/tray
  icons) colors the taskbar and the app rows but leaves every background
  group identical. This tool closes that gap:

    1. copies the stock ZCode.exe -> "ZCode-<Color>.exe" (same install dir, so
       all sibling support files resolve exactly like the stock exe),
    2. replaces the RT_GROUP_ICON + RT_ICON resources with the frames of
       tools\<color>-branding\tray_icon.ico (Win32 UpdateResource via P/Invoke,
       PS 5.1-safe),
    3. re-serializes the VERSIONINFO resource with FileDescription
       "ZCode <Color>" (via the pure core in zcode_exe_identity_lib.ps1),
    4. verifies AFTER writing: group bytes re-read from the file must equal the
       built blob, new RT_ICONs must exist, old RT_ICONs must be gone,
       FileDescription must read back exactly and ProductName/FileVersion must
       be unchanged. Any miss = loud FAILED + audit entry + exit 1 - never
       silent success.

  Drift / self-heal: a sidecar "<exe>.ghost-id.json" marker carries the source
  exe size + mtime + SHA256 and the branding-ico SHA256. The launcher's
  pre-launch step (launch_zcode_second_instance.ps1 step 2f) fast-checks the
  marker and re-invokes this tool on drift (app update replaced ZCode.exe, or
  the branding icon changed, or the engine version bumped).

  The stock ZCode.exe is NEVER touched, so the Primary keeps its stock Task
  Manager identity. Copies lose their Authenticode validity (resource edits
  invalidate the signature hash) - on AV-protected machines SmartScreen may
  prompt on first launch; this dev box runs no AV (see the docs note).

  Exit codes: 0 = every target fresh, patched, dry-run or skipped-because-
  running; 1 = any hard failure (verify miss, patch failure, missing input).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_exe_identity.ps1 -Target Fourth
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_exe_identity.ps1 -Target All -DryRun
#>
[CmdletBinding()]
param(
  [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
  [string]$Target = 'All',
  [string]$InstallDir,
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'zcode_exe_identity_lib.ps1')

# Engine version: bump to force a rebuild of every copy on the next run/launch.
# v1 (2026-11-11): initial icon-group replacement + FileDescription patch.
$script:EngineVersion = 1

$script:RtIcon = 3
$script:RtGroupIcon = 14
$script:RtVersion = 16
$script:LoadLibraryAsDatafile = 2

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace GhostExeIdentity {
    public static class Native {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr BeginUpdateResourceW(string pFileName, bool bDeleteExistingResources);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool UpdateResourceW(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "UpdateResourceW")]
        public static extern bool UpdateResourcePtrW(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, IntPtr lpData, uint cbData);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool EndUpdateResourceW(IntPtr hUpdate, bool fDiscard);
        public delegate bool EnumResNameProc(IntPtr hModule, IntPtr lpszType, IntPtr lpszName, IntPtr lParam);
        public delegate bool EnumResLangProc(IntPtr hModule, IntPtr lpszType, IntPtr lpszName, ushort wIDLanguage, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool EnumResourceNamesW(IntPtr hModule, IntPtr lpType, EnumResNameProc lpEnumFunc, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool EnumResourceLanguagesW(IntPtr hModule, IntPtr lpType, IntPtr lpName, EnumResLangProc lpEnumFunc, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr FindResourceW(IntPtr hModule, IntPtr lpName, IntPtr lpType);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint SizeofResource(IntPtr hModule, IntPtr hResInfo);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr LoadResource(IntPtr hModule, IntPtr hResInfo);
        [DllImport("kernel32.dll")]
        public static extern IntPtr LockResource(IntPtr hResData);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibraryExW(string lpFileName, IntPtr hFile, uint dwFlags);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeLibrary(IntPtr hLibModule);
        public static IntPtr MakeIntRes(int id) { return new IntPtr(id); }
        public static bool IsIntRes(IntPtr p) { return p.ToInt64() <= 0xFFFF; }
    }
}
"@

function Set-GhostConsoleUtf8 {
  # PS 5.1 decodes native stdout with the console encoding; make it UTF-8 so
  # colored output and paths survive. (Same helper name as identity_utils.ps1.)
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  } catch { }
}

function Resolve-ZcodeInstallDir {
  # Same candidate ladder as patch_zcode_icon_override.ps1 so both tools agree
  # on the install dir. Requires the stock ZCode.exe (the copy source).
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA 'Programs\ZCode'),
    'C:\Program Files\ZCode',
    'C:\Program Files (x86)\ZCode'
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'ZCode.exe'))) {
      return $c
    }
  }
  throw 'ZCode install not found. Pass -InstallDir <path> explicitly.'
}

function Get-GhostFileSha256 {
  # Streamed hash - the 246 MB exe must not be slurped whole into memory.
  param([string]$Path)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $fs = [System.IO.File]::OpenRead($Path)
    try {
      return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '').ToLowerInvariant()
    } finally {
      $fs.Dispose()
    }
  } finally {
    $sha.Dispose()
  }
}

function Test-ByteArrayEqual {
  param([byte[]]$A, [byte[]]$B)
  if ($null -eq $A -or $null -eq $B) { return (($null -eq $A) -and ($null -eq $B)) }
  if ($A.Length -ne $B.Length) { return $false }
  for ($i = 0; $i -lt $A.Length; $i++) {
    if ($A[$i] -ne $B[$i]) { return $false }
  }
  return $true
}

function ConvertTo-ResourceNamePtr {
  # Resource names are either ints (MAKEINTRESOURCE) or RC string ids.
  # Returns @{ Ptr; Owned(bool) } - Owned strings must be freed by the caller.
  param($Name)
  if ($Name -is [int] -or $Name -is [long]) {
    return @{ Ptr = [GhostExeIdentity.Native]::MakeIntRes([int]$Name); Owned = $false }
  }
  $ptr = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni([string]$Name)
  return @{ Ptr = $ptr; Owned = $true }
}

function Remove-ResourceNamePtr {
  param($NamePtr)
  if ($NamePtr.Owned) {
    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($NamePtr.Ptr) | Out-Null
  }
}

function Get-PeResourceEntries {
  # Enumerates (name, language) pairs of one resource type on a datafile
  # module. Names keep their int/string shape - both appear in real PEs.
  param([IntPtr]$Module, [IntPtr]$Type, [string]$Label)
  $entries = New-Object System.Collections.ArrayList
  $nameCb = [GhostExeIdentity.Native+EnumResNameProc]{
    param($hMod, $lpszType, $lpszName, $lParam)
    $name = $null
    if ([GhostExeIdentity.Native]::IsIntRes($lpszName)) { $name = [int]$lpszName.ToInt64() }
    else { $name = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($lpszName) }
    $langCb = [GhostExeIdentity.Native+EnumResLangProc]{
      param($hMod2, $lpszType2, $lpszName2, $wLang, $lParam2)
      [void]$entries.Add(@{ Name = $name; Lang = $wLang })
      return $true
    }
    [void][GhostExeIdentity.Native]::EnumResourceLanguagesW($Module, $Type, $lpszName, $langCb, [IntPtr]::Zero)
    return $true
  }
    [void][GhostExeIdentity.Native]::EnumResourceNamesW($Module, $Type, $nameCb, [IntPtr]::Zero)
    # Emit FLAT: PowerShell's pipeline unrolls a returned ArrayList, so a bare
    # `return $entries` streams the hashtables one by one and the caller's
    # @() collects them correctly. A protected `return ,$entries` would hand
    # back ONE ArrayList object, and @() would then wrap it instead of
    # flattening it - which silently broke every downstream foreach here.
    foreach ($e in $entries) { $e }
}

function Get-PeResourceBytes {
  param([IntPtr]$Module, [IntPtr]$Type, [IntPtr]$NamePtr, [uint16]$Lang)
  $res = [GhostExeIdentity.Native]::FindResourceW($Module, $NamePtr, $Type)
  if ($res -eq [IntPtr]::Zero) { return $null }
  $size = [GhostExeIdentity.Native]::SizeofResource($Module, $res)
  if ($size -lt 1) { return $null }
  $h = [GhostExeIdentity.Native]::LoadResource($Module, $res)
  if ($h -eq [IntPtr]::Zero) { return $null }
  $p = [GhostExeIdentity.Native]::LockResource($h)
  if ($p -eq [IntPtr]::Zero) { return $null }
  $bytes = New-Object byte[] $size
  [System.Runtime.InteropServices.Marshal]::Copy($p, $bytes, 0, [int]$size)
  # Comma-protected: a bare byte[] return is unrolled by the pipeline into
  # Object[]-of-bytes at the call site.
  return ,$bytes
}

function Write-GhostAuditLine {
  param([hashtable]$Entry)
  $dir = Join-Path $env:LOCALAPPDATA 'ghost-zcode-exe-identity'
  try {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $entry.ts = (Get-Date).ToUniversalTime().ToString('o')
    $json = ConvertTo-Json $Entry -Compress
    [System.IO.File]::AppendAllText((Join-Path $dir 'audit.jsonl'), $json + "`r`n")
  } catch {
    Write-Host "[warn] audit write failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

function Invoke-ExeIdentityPatch {
  # One clone target: freshness gate -> running gate -> copy -> patch ->
  # verify -> marker. Returns 'built' | 'fresh' | 'skip-running' | 'dryrun'.
  param([string]$InstallPath, [hashtable]$Cfg, [switch]$DryRun, [switch]$Force)

  $targetExe = Join-Path $InstallPath $Cfg.ExeName
  $sourceExe = Join-Path $InstallPath 'ZCode.exe'
  $icoPath = Join-Path (Join-Path $PSScriptRoot $Cfg.BrandingRepo) 'tray_icon.ico'
  $desc = "ZCode $($Cfg.DisplayName)"
  $markerPath = "$targetExe.ghost-id.json"
  $t0 = [DateTime]::UtcNow

  # 1) Fingerprints. The 246 MB exe is hashed only when the cheap size+mtime
  #    quick-check disagrees with the marker (touch-only change = still fresh).
  $srcItem = Get-Item -LiteralPath $sourceExe
  if (-not (Test-Path -LiteralPath $icoPath)) {
    throw "branding ICO missing: $icoPath"
  }
  $ico = Read-GhostIcoFile -Path $icoPath
  $iconSha = Get-GhostIcoSha256 $ico.Frames

  $marker = $null
  if (Test-Path -LiteralPath $markerPath) {
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch { $marker = $null }
  }
  $fresh = $false
  if ($marker -and (-not $Force) -and (Test-Path -LiteralPath $targetExe)) {
    if (([int]$marker.engineVersion -eq $script:EngineVersion) -and
        ([long]$marker.sourceSizeBytes -eq $srcItem.Length) -and
        ($marker.iconSha256 -eq $iconSha)) {
      $mtMatch = $false
      try {
        $mtMatch = ([datetime]$marker.sourceMtimeUtc).ToUniversalTime() -eq $srcItem.LastWriteTimeUtc
      } catch { $mtMatch = $false }
      if ($mtMatch) {
        $fresh = $true
      } else {
        # mtime changed: only still-fresh when the CONTENT hash is unchanged.
        $sha = Get-GhostFileSha256 -Path $sourceExe
        if ($sha -eq $marker.sourceSha256) {
          $marker.sourceMtimeUtc = $srcItem.LastWriteTimeUtc.ToString('o')
          [System.IO.File]::WriteAllText($markerPath, (ConvertTo-Json $marker -Compress), (New-Object System.Text.UTF8Encoding($false)))
          $fresh = $true
        }
      }
    }
  }
  if ($fresh) {
    Write-Host "[ok] $($Cfg.ExeName) already fresh (engine $($script:EngineVersion), source unchanged)" -ForegroundColor Green
    Write-GhostAuditLine -Entry @{ target = $Target; exe = $Cfg.ExeName; action = 'fresh'; ok = 1; detail = 'marker up to date' }
    return 'fresh'
  }

  # 2) Running gate: the exe of a live process cannot be rewritten (sharing
  #    violation), and the copy must exist for the process to be running.
  $running = @(Get-Process -Name 'ZCode*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $targetExe) })
  if ($running.Count -gt 0) {
    Write-Host "[skip] $($Cfg.ExeName) is running (pids: $($running.ProcessId -join ', ')) - close it, then re-run to rebuild" -ForegroundColor Yellow
    Write-GhostAuditLine -Entry @{ target = $Target; exe = $Cfg.ExeName; action = 'skip-running'; ok = 1; detail = "pids=$($running.ProcessId -join ',')" }
    return 'skip-running'
  }

  if ($DryRun) {
    Write-Host "[dryrun] would rebuild $($Cfg.ExeName):" -ForegroundColor Cyan
    Write-Host "         source   = $sourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB)"
    Write-Host "         icon     = $icoPath ($($ico.Frames.Count) frames)"
    Write-Host "         rename   = FileDescription -> '$desc'"
    Write-GhostAuditLine -Entry @{ target = $Target; exe = $Cfg.ExeName; action = 'dryrun'; ok = 1; detail = 'no writes' }
    return 'dryrun'
  }

  # 3) Copy. A stale, non-running copy is simply overwritten.
  try {
    [System.IO.File]::Copy($sourceExe, $targetExe, $true)
  } catch {
    Write-Host "[FAIL] copy failed for $($Cfg.ExeName): $($_.Exception.Message)" -ForegroundColor Red
    Write-GhostAuditLine -Entry @{ target = $Target; exe = $Cfg.ExeName; action = 'copy'; ok = 0; detail = $_.Exception.Message }
    throw
  }

  # 4) Capture the source identity fields the verify step must find unchanged.
  $srcVi = (Get-Item -LiteralPath $sourceExe).VersionInfo
  $origProductName = [string]$srcVi.ProductName
  $origFileVersion = [string]$srcVi.FileVersion

  # 5) Read the copy's current resources (datafile mapping) BEFORE the update
  #    handle opens - the two must not hold the file at the same time.
  $hmod = [GhostExeIdentity.Native]::LoadLibraryExW($targetExe, [IntPtr]::Zero, $script:LoadLibraryAsDatafile)
  if ($hmod -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LoadLibraryEx(datafile) failed on $targetExe (winerror $err)"
  }
  try {
    $groups = @(Get-PeResourceEntries -Module $hmod -Type ([IntPtr]$script:RtGroupIcon) -Label 'RT_GROUP_ICON')
    $icons = @(Get-PeResourceEntries -Module $hmod -Type ([IntPtr]$script:RtIcon) -Label 'RT_ICON')
    $versions = @(Get-PeResourceEntries -Module $hmod -Type ([IntPtr]$script:RtVersion) -Label 'RT_VERSION')
    if ($groups.Count -eq 0) {
      throw "no RT_GROUP_ICON resources found in $targetExe - unexpected for a real Electron exe; aborting"
    }

    # New RT_ICON ids above every existing one; the old icons are deleted so the
    # copy carries exactly the branding frames.
    $maxIconId = 0
    foreach ($e in $icons) {
      if ($e.Name -is [int] -and ([int]$e.Name -gt $maxIconId)) { $maxIconId = [int]$e.Name }
    }
    $newIds = @()
    for ($i = 0; $i -lt $ico.Frames.Count; $i++) { $newIds += ($maxIconId + 1 + $i) }
    $groupData = New-GhostGroupIconData -Frames $ico.Frames -IconIds $newIds

    # VERSIONINFO patches: re-serialize each RT_VERSION with the new
    # FileDescription. MUST run while $hmod is still mapped - after FreeLibrary
    # the handle is dead and Get-PeResourceBytes would silently return $null
    # (the verify step caught exactly that on the first live run).
    $versionPatches = @()
    foreach ($v in $versions) {
      $namePtr = ConvertTo-ResourceNamePtr -Name $v.Name
      try {
        $data = Get-PeResourceBytes -Module $hmod -Type ([IntPtr]$script:RtVersion) -NamePtr $namePtr.Ptr -Lang $v.Lang
      } finally {
        Remove-ResourceNamePtr -NamePtr $namePtr
      }
      if ($null -eq $data) {
        throw "verify-prep: RT_VERSION name=$($v.Name) lang=$($v.Lang) unreadable from $targetExe"
      }
      $tree = Get-GhostVersionInfoTree -Data $data
      $changed = Set-GhostVersionInfoStringValue -Tree $tree -Key 'FileDescription' -NewValue $desc
      if ($changed -gt 0) {
        $versionPatches += ,@{ Name = $v.Name; Lang = $v.Lang; Data = (ConvertTo-GhostVersionInfoBytes -Tree $tree) }
      }
    }
    if ($versionPatches.Count -eq 0) {
      throw "verify-prep: no RT_VERSION carried a FileDescription string - refusing to build $targetExe without its Task Manager name"
    }
  } finally {
    [GhostExeIdentity.Native]::FreeLibrary($hmod) | Out-Null
  }

  # 6) Write: groups, new icons (per language present), delete old icons,
  #    version resources. One update transaction; discard on any failure.
  $langs = @{}
  foreach ($g in $groups) { $langs[[int]$g.Lang] = $true }
  foreach ($e in $icons) { $langs[[int]$e.Lang] = $true }
  if ($langs.Count -eq 0) { $langs[1033] = $true }

  $hupd = [GhostExeIdentity.Native]::BeginUpdateResourceW($targetExe, $false)
  if ($hupd -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "BeginUpdateResourceW failed on $targetExe (winerror $err)"
  }
  try {
    foreach ($g in $groups) {
      $np = ConvertTo-ResourceNamePtr -Name $g.Name
      try {
        if (-not [GhostExeIdentity.Native]::UpdateResourceW($hupd, [IntPtr]$script:RtGroupIcon, $np.Ptr, [uint16][int]$g.Lang, $groupData, [uint32]$groupData.Length)) {
          throw "UpdateResourceW(GROUP_ICON name=$($g.Name) lang=$($g.Lang)) failed (winerror $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
      } finally { Remove-ResourceNamePtr -NamePtr $np }
    }
    for ($i = 0; $i -lt $ico.Frames.Count; $i++) {
      $frame = [byte[]]$ico.Frames[$i].Data
      foreach ($lang in @($langs.Keys)) {
        if (-not [GhostExeIdentity.Native]::UpdateResourceW($hupd, [IntPtr]$script:RtIcon, [GhostExeIdentity.Native]::MakeIntRes([int]$newIds[$i]), [uint16][int]$lang, $frame, [uint32]$frame.Length)) {
          throw "UpdateResourceW(RT_ICON id=$($newIds[$i]) lang=$lang) failed (winerror $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
      }
    }
    foreach ($e in $icons) {
      if ($e.Name -is [int] -and ($newIds -contains [int]$e.Name)) { continue }
      $np = ConvertTo-ResourceNamePtr -Name $e.Name
      try {
        if (-not [GhostExeIdentity.Native]::UpdateResourcePtrW($hupd, [IntPtr]$script:RtIcon, $np.Ptr, [uint16][int]$e.Lang, [IntPtr]::Zero, [uint32]0)) {
          throw "UpdateResourceW(delete RT_ICON name=$($e.Name) lang=$($e.Lang)) failed (winerror $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
      } finally { Remove-ResourceNamePtr -NamePtr $np }
    }
    foreach ($v in $versionPatches) {
      $np = ConvertTo-ResourceNamePtr -Name $v.Name
      try {
        if (-not [GhostExeIdentity.Native]::UpdateResourceW($hupd, [IntPtr]$script:RtVersion, $np.Ptr, [uint16][int]$v.Lang, [byte[]]$v.Data, [uint32]([byte[]]$v.Data).Length)) {
          throw "UpdateResourceW(VERSION name=$($v.Name) lang=$($v.Lang)) failed (winerror $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
      } finally { Remove-ResourceNamePtr -NamePtr $np }
    }
    if (-not [GhostExeIdentity.Native]::EndUpdateResourceW($hupd, $false)) {
      throw "EndUpdateResourceW failed (winerror $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }
    $hupd = [IntPtr]::Zero
  } catch {
    # Discard the pending transaction so the copy stays at its pre-update state.
    if ($hupd -ne [IntPtr]::Zero) {
      [GhostExeIdentity.Native]::EndUpdateResourceW($hupd, $true) | Out-Null
    }
    throw
  }

  # 7) Verify-after (the repo's no-silent-success rule): re-read the file and
  #    compare against exactly what was written.
  $hmod2 = [GhostExeIdentity.Native]::LoadLibraryExW($targetExe, [IntPtr]::Zero, $script:LoadLibraryAsDatafile)
  if ($hmod2 -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "verify: LoadLibraryEx failed on $targetExe (winerror $err)"
  }
  try {
    foreach ($g in $groups) {
      $np = ConvertTo-ResourceNamePtr -Name $g.Name
      try {
        $readBack = Get-PeResourceBytes -Module $hmod2 -Type ([IntPtr]$script:RtGroupIcon) -NamePtr $np.Ptr -Lang $g.Lang
        if (-not (Test-ByteArrayEqual -A $readBack -B $groupData)) {
          throw "verify: group icon bytes mismatch for name=$($g.Name) lang=$($g.Lang)"
        }
      } finally { Remove-ResourceNamePtr -NamePtr $np }
    }
    for ($i = 0; $i -lt $ico.Frames.Count; $i++) {
      foreach ($lang in @($langs.Keys)) {
        $readBack = Get-PeResourceBytes -Module $hmod2 -Type ([IntPtr]$script:RtIcon) -NamePtr ([GhostExeIdentity.Native]::MakeIntRes([int]$newIds[$i])) -Lang ([uint16][int]$lang)
        if ($null -eq $readBack) {
          throw "verify: new RT_ICON id=$($newIds[$i]) lang=$lang missing"
        }
        if (-not (Test-ByteArrayEqual -A $readBack -B ([byte[]]$ico.Frames[$i].Data))) {
          throw "verify: RT_ICON id=$($newIds[$i]) lang=$lang bytes mismatch"
        }
      }
    }
    foreach ($e in $icons) {
      if ($e.Name -is [int] -and ($newIds -contains [int]$e.Name)) { continue }
      $np = ConvertTo-ResourceNamePtr -Name $e.Name
      try {
        $still = Get-PeResourceBytes -Module $hmod2 -Type ([IntPtr]$script:RtIcon) -NamePtr $np.Ptr -Lang $e.Lang
        if ($null -ne $still) {
          throw "verify: old RT_ICON name=$($e.Name) lang=$($e.Lang) survived the delete"
        }
      } finally { Remove-ResourceNamePtr -NamePtr $np }
    }
  } finally {
    [GhostExeIdentity.Native]::FreeLibrary($hmod2) | Out-Null
  }
  $vi = (Get-Item -LiteralPath $targetExe).VersionInfo
  if ([string]$vi.FileDescription -cne $desc) {
    throw "verify: FileDescription is '$($vi.FileDescription)', expected '$desc'"
  }
  if ([string]$vi.ProductName -cne $origProductName) {
    throw "verify: ProductName changed ('$($vi.ProductName)', expected '$origProductName')"
  }
  if ([string]$vi.FileVersion -cne $origFileVersion) {
    throw "verify: FileVersion changed ('$($vi.FileVersion)', expected '$origFileVersion')"
  }

  # 8) Marker + audit.
  $srcSha = Get-GhostFileSha256 -Path $sourceExe
  $marker = [ordered]@{
    engineVersion   = $script:EngineVersion
    appliedAt       = (Get-Date).ToUniversalTime().ToString('o')
    exe             = $Cfg.ExeName
    sourceSha256    = $srcSha
    sourceSizeBytes = $srcItem.Length
    sourceMtimeUtc  = $srcItem.LastWriteTimeUtc.ToString('o')
    iconSha256      = $iconSha
    fileDescription = $desc
    groupsPatched   = $groups.Count
    iconsAdded      = $ico.Frames.Count
    iconsDeleted    = $icons.Count
    versionsPatched = $versionPatches.Count
    timingsMs       = [int]([DateTime]::UtcNow - $t0).TotalMilliseconds
  }
  [System.IO.File]::WriteAllText($markerPath, (ConvertTo-Json $marker -Compress), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[ok] $($Cfg.ExeName) rebuilt: icon = $($Cfg.DisplayName), FileDescription = '$desc' ($($marker.timingsMs) ms)" -ForegroundColor Green
  Write-GhostAuditLine -Entry @{ target = $Target; exe = $Cfg.ExeName; action = 'build'; ok = 1; detail = "desc='$desc' frames=$($ico.Frames.Count) ms=$($marker.timingsMs)" }
  return 'built'
}

# ---- main ----------------------------------------------------------------

Set-GhostConsoleUtf8 | Out-Null

$installPath = Resolve-ZcodeInstallDir -Override $InstallDir
$sourceExe = Join-Path $installPath 'ZCode.exe'
$srcItem = Get-Item -LiteralPath $sourceExe
Write-Host "install = $installPath"
Write-Host "source  = $sourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB, engine $script:EngineVersion)"
if ($DryRun) { Write-Host 'mode    = DRY RUN (no writes)' -ForegroundColor Cyan }

$targets = @($Target)
if ($Target -eq 'All') { $targets = @('Second', 'Third', 'Fourth', 'Fifth', 'Sixth') }
$map = Get-ZcodeInstanceIdentityMap

$summary = @{ built = 0; fresh = 0; skipped = 0; dryrun = 0; failed = 0 }
foreach ($t in $targets) {
  $cfg = $map[$t]
  try {
    $result = Invoke-ExeIdentityPatch -InstallPath $installPath -Cfg $cfg -DryRun:$DryRun -Force:$Force
    if ($result -eq 'built') { $summary.built++ }
    elseif ($result -eq 'fresh') { $summary.fresh++ }
    elseif ($result -eq 'skip-running') { $summary.skipped++ }
    elseif ($result -eq 'dryrun') { $summary.dryrun++ }
  } catch {
    $summary.failed++
    Write-Host "[FAIL] $t ($($cfg.ExeName)): $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Write-GhostAuditLine -Entry @{ target = $Target; exe = $cfg.ExeName; action = 'patch'; ok = 0; detail = $_.Exception.Message }
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "dry run: $($summary.dryrun) target(s) would be rebuilt. Re-run without -DryRun to apply."
} else {
  Write-Host "summary: $($summary.built) built, $($summary.fresh) already fresh, $($summary.skipped) skipped (running), $($summary.failed) failed"
}
if ($summary.failed -gt 0) { exit 1 }
exit 0
