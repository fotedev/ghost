#Requires -Version 5.1
<#
.SYNOPSIS
  Generic PE-resource core for Task-Manager exe identity patching - shared by
  ALL FOUR suites (ZCode / AutoClaw2 / Cline / OpenCode) since 2026-11-14.

.DESCRIPTION
  Windows Task Manager takes the display name and icon of background-process
  groups from the executable IMAGE itself (VERSIONINFO FileDescription +
  embedded icon resource), not from AUMID shortcuts or window properties.
  When every clone of a suite runs the same stock exe, every instance renders
  as an identical "<App> (N)" row. The fix is per-color exe copies with
  patched resources, built in the install dir and launched instead of the
  stock exe.

  This module holds the mechanics ONE copy for every suite:

    - Read-GhostIcoFile / New-GhostGroupIconData / Get-GhostIcoSha256
      .ico parsing + GRPICONDIR building + frame fingerprint
    - Get-GhostVersionInfoTree / Set-GhostVersionInfoStringValue /
      ConvertTo-GhostVersionInfoBytes / Write-GhostVersionInfoNode
      VS_VERSIONINFO parse / set / re-serialize (32-bit aligned)
    - Get-GhostFileSha256 / Test-ByteArrayEqual
    - ConvertTo-ResourceNamePtr / Remove-ResourceNamePtr /
      Get-PeResourceEntries / Get-PeResourceBytes
      Win32 resource enumeration + reads (datafile mapping)
    - Write-GhostExeAuditLine   JSONL audit per suite dir
    - Invoke-GhostExeIdentityPatch   the FULL one-target flow: freshness
      gate -> running gate -> copy -> resource update transaction -> re-read
      verify -> sidecar marker. Returns 'built' | 'fresh' | 'skip-running' |
      'dryrun'.

  Each suite keeps a thin wrapper (tools\patch_<suite>_exe_identity.ps1)
  that supplies only its instance map, install-dir resolution and engine
  version; tools\zcode_exe_identity_lib.ps1 additionally keeps the ZCode
  alias map on top of this module. The Win32 P/Invoke type
  (GhostExeIdentity.Native) is compiled here once, guarded.

  VS_VERSIONINFO structure rules (MSDN): each block is
  { WORD wLength; WORD wValueLength; WORD wType; WCHAR szKey[]; pad32; Value;
  pad32; children }. wType=1 counts WORDs of the value INCLUDING the null;
  wType=0 counts bytes. Block lengths include trailing padding so every block
  starts 32-bit aligned relative to the resource start.

  The driver verifies every write by re-reading the patched resources and the
  FileDescription - never silent success. Moved from patch_zcode_exe_identity
  (live-verified 2026-11-11) + zcode_exe_identity_lib verbatim; behavior is
  byte-identical, ownership only.
#>

$script:RtIcon = 3
$script:RtGroupIcon = 14
$script:RtVersion = 16
$script:LoadLibraryAsDatafile = 2

if (-not ('GhostExeIdentity.Native' -as [type])) {
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
}

function Read-GhostIcoFile {
  # Parses a .ico file into frame records. Throws on truncated/malformed input -
  # the caller never builds a group resource from partial frames.
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { throw "ICO not found: $Path" }
  $resolved = (Resolve-Path -LiteralPath $Path).Path
  $bytes = [System.IO.File]::ReadAllBytes($resolved)
  if ($bytes.Length -lt 6) { throw "ICO too small: $Path" }
  $icoType = [BitConverter]::ToUInt16($bytes, 2)
  if ($icoType -ne 1) { throw "Not an ICO file (type=$icoType): $Path" }
  $count = [BitConverter]::ToUInt16($bytes, 4)
  if ($count -lt 1) { throw "ICO has no frames: $Path" }
  $frames = @()
  for ($i = 0; $i -lt $count; $i++) {
    $off = 6 + (16 * $i)
    if (($off + 16) -gt $bytes.Length) { throw "ICO directory truncated at frame ${i}: $Path" }
    $size = [BitConverter]::ToUInt32($bytes, $off + 8)
    $imgOff = [BitConverter]::ToUInt32($bytes, $off + 12)
    if (($imgOff + $size) -gt $bytes.Length) { throw "ICO frame ${i} data out of range: $Path" }
    if ($size -lt 1) { throw "ICO frame ${i} is empty: $Path" }
    $data = New-Object byte[] $size
    [Array]::Copy($bytes, [int]$imgOff, $data, 0, [int]$size)
    $frames += ,@{
      Index      = $i
      WidthByte  = $bytes[$off]       # 0 means 256
      HeightByte = $bytes[$off + 1]   # 0 means 256
      ColorCount = $bytes[$off + 2]
      Reserved   = $bytes[$off + 3]
      Planes     = [BitConverter]::ToUInt16($bytes, $off + 4)
      BitCount   = [BitConverter]::ToUInt16($bytes, $off + 6)
      Data       = $data
    }
  }
  return @{ Frames = $frames }
}

function New-GhostGroupIconData {
  # Builds the RT_GROUP_ICON (GRPICONDIR) blob: 6-byte directory header +
  # 14-byte GRPICONENTRY per frame, each pointing at the new RT_ICON resource
  # id in $IconIds (same order as $Frames). dwBytesInRes carries the real image
  # size; loaders ignore it but Resource Hacker-style tools read it.
  param($Frames, [int[]]$IconIds)
  if ($Frames.Count -ne $IconIds.Count) {
    throw "Frames/IconIds count mismatch: $($Frames.Count) vs $($IconIds.Count)"
  }
  if ($IconIds.Count -gt 0xFFFF) { throw "Too many frames for one icon group" }
  foreach ($id in $IconIds) {
    if ($id -lt 1 -or $id -gt 0xFFFF) { throw "RT_ICON id out of range: $id" }
  }
  $ms = New-Object System.IO.MemoryStream
  $bw = New-Object System.IO.BinaryWriter($ms)
  $bw.Write([uint16]0)                       # idReserved
  $bw.Write([uint16]1)                       # idType (icon)
  $bw.Write([uint16][int]$Frames.Count)      # idCount
  for ($i = 0; $i -lt $Frames.Count; $i++) {
    $f = $Frames[$i]
    $bw.Write([byte][int]$f.WidthByte)
    $bw.Write([byte][int]$f.HeightByte)
    $bw.Write([byte][int]$f.ColorCount)
    $bw.Write([byte][int]$f.Reserved)
    $bw.Write([uint16][int]$f.Planes)
    $bw.Write([uint16][int]$f.BitCount)
    $bw.Write([uint32][int]$f.Data.Length)
    $bw.Write([uint16][int]$IconIds[$i])
  }
  $bw.Flush()
  # Comma-protected: a bare byte[] return is unrolled by the pipeline into
  # Object[]-of-bytes at the call site.
  return ,$ms.ToArray()
}

function Get-GhostIcoSha256 {
  # Content fingerprint over the frame BYTES (not the container): the marker
  # drift check uses it to rebuild copies when the branding icon changes.
  param($Frames)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $ms = New-Object System.IO.MemoryStream
    foreach ($f in $Frames) {
      $d = [byte[]]$f.Data
      $ms.Write($d, 0, $d.Length)
    }
    return ([BitConverter]::ToString($sha.ComputeHash($ms.ToArray())) -replace '-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-GhostVersionInfoTree {
  # Parses a VS_VERSIONINFO resource blob into a tree of hashtables:
  #   @{ Key=[string]; Type=[int]; Value=[string|byte[]|$null]; Children=@(...) }
  # Throws when the root key is not VS_VERSION_INFO (guards against feeding it
  # an unrelated resource).
  param([byte[]]$Data)
  if ($Data.Length -lt 6) { throw "Version resource too small ($($Data.Length) bytes)" }

  function Read-ViNode {
    param([byte[]]$B, [int]$Start, [int]$End)
    if (($Start + 6) -gt $End) { throw "Version block header out of range at $Start" }
    $len = [BitConverter]::ToUInt16($B, $Start)
    $vlen = [BitConverter]::ToUInt16($B, $Start + 2)
    $type = [BitConverter]::ToUInt16($B, $Start + 4)
    if ($len -lt 6 -or ($Start + $len) -gt $End) { throw "Version block length invalid at $Start (wLength=$len)" }
    # szKey: null-terminated UTF-16 starting at Start+6.
    $keyStart = $Start + 6
    $k = $keyStart
    while (($k + 1) -lt ($Start + $len) -and (($B[$k] -ne 0) -or ($B[$k + 1] -ne 0))) { $k += 2 }
    if (($k + 2) -gt $End) { throw "Version key not null-terminated at $Start" }
    $keyBytes = ($k + 2) - $keyStart
    $key = [System.Text.Encoding]::Unicode.GetString($B, $keyStart, $keyBytes - 2)
    # Value begins at the first 32-bit boundary after szKey.
    $valueStart = $keyStart + $keyBytes
    while (($valueStart % 4) -ne 0) { $valueStart++ }
    $valueBytes = 0
    $value = $null
    if ($vlen -gt 0) {
      $valueBytes = if ($type -eq 1) { $vlen * 2 } else { $vlen }
      if (($valueStart + $valueBytes) -gt ($Start + $len)) {
        throw "Version value out of range at $Start (key=$key)"
      }
      if ($type -eq 1) {
        $chars = [Math]::Max(0, $valueBytes - 2)   # strip the terminating null
        $value = [System.Text.Encoding]::Unicode.GetString($B, $valueStart, $chars)
      } else {
        $vb = New-Object byte[] $valueBytes
        [Array]::Copy($B, $valueStart, $vb, 0, $valueBytes)
        $value = $vb
      }
    }
    # Children begin at the first 32-bit boundary after the value.
    $childStart = $valueStart + $valueBytes
    while (($childStart % 4) -ne 0) { $childStart++ }
    $childEnd = $Start + $len
    $children = @()
    while (($childStart + 6) -le $childEnd) {
      $nextLen = [BitConverter]::ToUInt16($B, $childStart)
      if ($nextLen -le 0) { break }   # pure padding tail - stop
      $children += ,(Read-ViNode $B $childStart $childEnd)
      $childStart += $nextLen
    }
    return @{
      Key      = $key
      Type     = [int]$type
      Value    = $value
      Children = $children
    }
  }

  $root = Read-ViNode $Data 0 $Data.Length
  if ($root.Key -ne 'VS_VERSION_INFO') {
    throw "Unexpected version resource root key: '$($root.Key)'"
  }
  return $root
}

function Set-GhostVersionInfoStringValue {
  # Sets every string node whose szKey matches $Key (leaf String blocks inside
  # StringFileInfo tables; szKey nodes themselves are never touched because a
  # key node has no Value). Returns the number of nodes changed.
  param($Tree, [string]$Key, [string]$NewValue)
  if ($Tree.Key -ne 'VS_VERSION_INFO') { throw "Not a version-info tree" }
  $hits = 0
  $stack = New-Object System.Collections.Stack
  $stack.Push($Tree)
  while ($stack.Count -gt 0) {
    $n = $stack.Pop()
    if (($n.Type -eq 1) -and ($n.Key -eq $Key) -and ($null -ne $n.Value)) {
      if ([string]$n.Value -cne $NewValue) {
        $n.Value = $NewValue
        $hits++
      }
    }
    foreach ($c in $n.Children) { $stack.Push($c) }
  }
  return $hits
}

function ConvertTo-GhostVersionInfoBytes {
  # Re-serializes the tree: header (wLength/wValueLength patched in at the end)
  # + szKey + pad32 + value + pad32 + children (each child serialized at its
  # absolute offset so all alignment is relative to the resource start), then
  # the whole block is padded to a 32-bit boundary and wLength includes that
  # trailing pad. Throws when a block exceeds the 16-bit wLength field.
  param($Tree)
  $ms = New-Object System.IO.MemoryStream
  Write-GhostVersionInfoNode -Ms $ms -Node $Tree -StartOffset 0
  # Comma-protected against the pipeline's byte[] unrolling (see above).
  return ,$ms.ToArray()
}

function Write-GhostVersionInfoNode {
  # $StartOffset is this block's absolute offset in the shared stream (all
  # alignment is relative to the resource start = offset 0). $bw.BaseStream.Position
  # is ALWAYS absolute, so child starts and pad checks use the position as-is -
  # adding $StartOffset would double-count the base and place nested children
  # at multiplied offsets (zero-filled gaps, a bloated blob).
  param([System.IO.MemoryStream]$Ms, $Node, [int]$StartOffset)
  $bw = New-Object System.IO.BinaryWriter($Ms)
  $bw.BaseStream.Position = $StartOffset
  $bw.Write([uint16]0)                      # wLength placeholder
  $bw.Write([uint16]0)                      # wValueLength placeholder
  $bw.Write([uint16][int]$Node.Type)
  $keyBytes = [System.Text.Encoding]::Unicode.GetBytes(([string]$Node.Key) + [string][char]0)
  $bw.Write($keyBytes)
  while (([int]$bw.BaseStream.Position % 4) -ne 0) { $bw.Write([byte]0) }
  $vlen = 0
  if ($null -ne $Node.Value) {
    if ($Node.Type -eq 1) {
      $vbytes = [System.Text.Encoding]::Unicode.GetBytes(([string]$Node.Value) + [string][char]0)
      $vlen = [int]($vbytes.Length / 2)
      $bw.Write($vbytes)
    } else {
      $vbytes = [byte[]]$Node.Value
      $vlen = $vbytes.Length
      $bw.Write($vbytes)
    }
  }
  while (([int]$bw.BaseStream.Position % 4) -ne 0) { $bw.Write([byte]0) }
  foreach ($c in $Node.Children) {
    Write-GhostVersionInfoNode -Ms $Ms -Node $c -StartOffset ([int]$bw.BaseStream.Position)
  }
  while (([int]$bw.BaseStream.Position % 4) -ne 0) { $bw.Write([byte]0) }
  $total = [int]$bw.BaseStream.Position - $StartOffset
  if ($total -gt 0xFFFF) { throw "Version block exceeds 64KB at offset $StartOffset (key='$($Node.Key)')" }
  if (($Node.Type -eq 1) -and ($vlen -gt 0xFFFF)) { throw "Version string value exceeds 64K words (key='$($Node.Key)')" }
  $bw.BaseStream.Seek($StartOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
  $bw.Write([uint16]$total)
  $bw.Write([uint16]$vlen)
  $bw.BaseStream.Position = $StartOffset + $total
}

function Get-GhostFileSha256 {
  # Streamed hash - a ~235 MB exe must not be slurped whole into memory.
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

function Write-GhostExeAuditLine {
  # JSONL audit, one dir per suite (e.g. %LOCALAPPDATA%\ghost-zcode-exe-identity).
  param([Parameter(Mandatory = $true)][string]$AuditDir, [hashtable]$Entry)
  try {
    if (-not (Test-Path -LiteralPath $AuditDir)) { New-Item -ItemType Directory -Path $AuditDir -Force | Out-Null }
    $entry.ts = (Get-Date).ToUniversalTime().ToString('o')
    $json = ConvertTo-Json $Entry -Compress
    [System.IO.File]::AppendAllText((Join-Path $AuditDir 'audit.jsonl'), $json + "`r`n")
  } catch {
    Write-Host "[warn] audit write failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

function Invoke-GhostExeIdentityPatch {
  # One clone target, generic: freshness gate -> running gate -> copy ->
  # resource update transaction -> re-read verify -> sidecar marker.
  # Returns 'built' | 'fresh' | 'skip-running' | 'dryrun'. Throws on any
  # verify-after mismatch (the caller records the failure).
  param(
    [Parameter(Mandatory = $true)][string]$SourceExe,
    [Parameter(Mandatory = $true)][string]$TargetExe,
    [Parameter(Mandatory = $true)][string]$IcoPath,
    [Parameter(Mandatory = $true)][string]$FileDescription,
    [Parameter(Mandatory = $true)][string]$ExeLabel,
    [Parameter(Mandatory = $true)][string]$TargetName,
    [Parameter(Mandatory = $true)][int]$EngineVersion,
    [Parameter(Mandatory = $true)][string]$SuiteProcessFamily,
    [Parameter(Mandatory = $true)][string]$AuditDir,
    [switch]$DryRun,
    [switch]$Force
  )

  $markerPath = "$TargetExe.ghost-id.json"
  $t0 = [DateTime]::UtcNow

  # 1) Fingerprints. The ~235 MB exe is hashed only when the cheap size+mtime
  #    quick-check disagrees with the marker (touch-only change = still fresh).
  $srcItem = Get-Item -LiteralPath $SourceExe
  if (-not (Test-Path -LiteralPath $IcoPath)) {
    throw "branding ICO missing: $IcoPath"
  }
  $ico = Read-GhostIcoFile -Path $IcoPath
  $iconSha = Get-GhostIcoSha256 $ico.Frames

  $marker = $null
  if (Test-Path -LiteralPath $markerPath) {
    try { $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json } catch { $marker = $null }
  }
  $fresh = $false
  if ($marker -and (-not $Force) -and (Test-Path -LiteralPath $TargetExe)) {
    if (([int]$marker.engineVersion -eq $EngineVersion) -and
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
        $sha = Get-GhostFileSha256 -Path $SourceExe
        if ($sha -eq $marker.sourceSha256) {
          $marker.sourceMtimeUtc = $srcItem.LastWriteTimeUtc.ToString('o')
          [System.IO.File]::WriteAllText($markerPath, (ConvertTo-Json $marker -Compress), (New-Object System.Text.UTF8Encoding($false)))
          $fresh = $true
        }
      }
    }
  }
  if ($fresh) {
    Write-Host "[ok] $ExeLabel already fresh (engine $EngineVersion, source unchanged)" -ForegroundColor Green
    Write-GhostExeAuditLine -AuditDir $AuditDir -Entry @{ target = $TargetName; exe = $ExeLabel; action = 'fresh'; ok = 1; detail = 'marker up to date' }
    return 'fresh'
  }

  # 2) Running gate: the exe of a live process cannot be rewritten (sharing
  #    violation), and the copy must exist for the process to be running.
  $running = @(Get-Process -Name $SuiteProcessFamily -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -ieq $TargetExe) })
  if ($running.Count -gt 0) {
    Write-Host "[skip] $ExeLabel is running (pids: $($running.ProcessId -join ', ')) - close it, then re-run to rebuild" -ForegroundColor Yellow
    Write-GhostExeAuditLine -AuditDir $AuditDir -Entry @{ target = $TargetName; exe = $ExeLabel; action = 'skip-running'; ok = 1; detail = "pids=$($running.ProcessId -join ',')" }
    return 'skip-running'
  }

  if ($DryRun) {
    Write-Host "[dryrun] would rebuild ${ExeLabel}:" -ForegroundColor Cyan
    Write-Host "         source   = $SourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB)"
    Write-Host "         icon     = $IcoPath ($($ico.Frames.Count) frames)"
    Write-Host "         rename   = FileDescription -> '$FileDescription'"
    Write-GhostExeAuditLine -AuditDir $AuditDir -Entry @{ target = $TargetName; exe = $ExeLabel; action = 'dryrun'; ok = 1; detail = 'no writes' }
    return 'dryrun'
  }

  # 3) Copy. A stale, non-running copy is simply overwritten.
  try {
    [System.IO.File]::Copy($SourceExe, $TargetExe, $true)
  } catch {
    Write-Host "[FAIL] copy failed for ${ExeLabel}: $($_.Exception.Message)" -ForegroundColor Red
    Write-GhostExeAuditLine -AuditDir $AuditDir -Entry @{ target = $TargetName; exe = $ExeLabel; action = 'copy'; ok = 0; detail = $_.Exception.Message }
    throw
  }

  # 4) Capture the source identity fields the verify step must find unchanged.
  $srcVi = (Get-Item -LiteralPath $SourceExe).VersionInfo
  $origProductName = [string]$srcVi.ProductName
  $origFileVersion = [string]$srcVi.FileVersion

  # 5) Read the copy's current resources (datafile mapping) BEFORE the update
  #    handle opens - the two must not hold the file at the same time.
  $hmod = [GhostExeIdentity.Native]::LoadLibraryExW($TargetExe, [IntPtr]::Zero, $script:LoadLibraryAsDatafile)
  if ($hmod -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "LoadLibraryEx(datafile) failed on $TargetExe (winerror $err)"
  }
  try {
    $groups = @(Get-PeResourceEntries -Module $hmod -Type ([IntPtr]$script:RtGroupIcon) -Label 'RT_GROUP_ICON')
    $icons = @(Get-PeResourceEntries -Module $hmod -Type ([IntPtr]$script:RtIcon) -Label 'RT_ICON')
    $versions = @(Get-PeResourceEntries -Module $hmod -Type ([IntPtr]$script:RtVersion) -Label 'RT_VERSION')
    if ($groups.Count -eq 0) {
      throw "no RT_GROUP_ICON resources found in $TargetExe - unexpected for a real Electron exe; aborting"
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
        throw "verify-prep: RT_VERSION name=$($v.Name) lang=$($v.Lang) unreadable from $TargetExe"
      }
      $tree = Get-GhostVersionInfoTree -Data $data
      $changed = Set-GhostVersionInfoStringValue -Tree $tree -Key 'FileDescription' -NewValue $FileDescription
      if ($changed -gt 0) {
        $versionPatches += ,@{ Name = $v.Name; Lang = $v.Lang; Data = (ConvertTo-GhostVersionInfoBytes -Tree $tree) }
      }
    }
    if ($versionPatches.Count -eq 0) {
      throw "verify-prep: no RT_VERSION carried a FileDescription string - refusing to build $TargetExe without its Task Manager name"
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

  $hupd = [GhostExeIdentity.Native]::BeginUpdateResourceW($TargetExe, $false)
  if ($hupd -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "BeginUpdateResourceW failed on $TargetExe (winerror $err)"
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
  $hmod2 = [GhostExeIdentity.Native]::LoadLibraryExW($TargetExe, [IntPtr]::Zero, $script:LoadLibraryAsDatafile)
  if ($hmod2 -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "verify: LoadLibraryEx failed on $TargetExe (winerror $err)"
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
  $vi = (Get-Item -LiteralPath $TargetExe).VersionInfo
  if ([string]$vi.FileDescription -cne $FileDescription) {
    throw "verify: FileDescription is '$($vi.FileDescription)', expected '$FileDescription'"
  }
  if ([string]$vi.ProductName -cne $origProductName) {
    throw "verify: ProductName changed ('$($vi.ProductName)', expected '$origProductName')"
  }
  if ([string]$vi.FileVersion -cne $origFileVersion) {
    throw "verify: FileVersion changed ('$($vi.FileVersion)', expected '$origFileVersion')"
  }

  # 8) Marker + audit.
  $srcSha = Get-GhostFileSha256 -Path $SourceExe
  $markerOut = [ordered]@{
    engineVersion   = $EngineVersion
    appliedAt       = (Get-Date).ToUniversalTime().ToString('o')
    exe             = $ExeLabel
    sourceSha256    = $srcSha
    sourceSizeBytes = $srcItem.Length
    sourceMtimeUtc  = $srcItem.LastWriteTimeUtc.ToString('o')
    iconSha256      = $iconSha
    fileDescription = $FileDescription
    groupsPatched   = $groups.Count
    iconsAdded      = $ico.Frames.Count
    iconsDeleted    = $icons.Count
    versionsPatched = $versionPatches.Count
    timingsMs       = [int]([DateTime]::UtcNow - $t0).TotalMilliseconds
  }
  [System.IO.File]::WriteAllText($markerPath, (ConvertTo-Json $markerOut -Compress), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[ok] $ExeLabel rebuilt: icon = '$FileDescription' ($($markerOut.timingsMs) ms)" -ForegroundColor Green
  Write-GhostExeAuditLine -AuditDir $AuditDir -Entry @{ target = $TargetName; exe = $ExeLabel; action = 'build'; ok = 1; detail = "desc='$FileDescription' frames=$($ico.Frames.Count) ms=$($markerOut.timingsMs)" }
  return 'built'
}
