#Requires -Version 5.1
<#
.SYNOPSIS
  Pure PE-resource core for per-clone ZCode exe identity patching - no process
  state, no file writes, no exit codes. Shared by tools\patch_zcode_exe_identity.ps1
  (which owns the copy / UpdateResource / verify / audit orchestration) and
  unit-tested by tests\zcode_exe_identity.Tests.ps1.

.DESCRIPTION
  Windows Task Manager takes the display name and icon of background-process
  groups from the executable IMAGE itself (VERSIONINFO FileDescription +
  embedded icon resource), not from AUMID shortcuts or window properties. All
  six ZCode instances run the same ZCode.exe, so every instance renders as the
  same stock-icon "ZCode (N)" row. The fix (approved 2026-11-11) is per-color
  exe copies with patched resources; this module holds the pure parts:

    - Get-ZcodeInstanceIdentityMap   the clone alias map (exe name <-> key <-> branding dir)
    - Read-GhostIcoFile              .ico parser (directory entries + frame bytes)
    - New-GhostGroupIconData         GRPICONDIR/GRPICONENTRY blob pointing at new RT_ICON ids
    - Get-GhostIcoSha256             frame-content fingerprint for the drift marker
    - Get-GhostVersionInfoTree       VS_VERSIONINFO parser (tree of blocks)
    - Set-GhostVersionInfoStringValue  sets one String value (e.g. FileDescription) in place
    - ConvertTo-GhostVersionInfoBytes  re-serializes the tree with correct 32-bit alignment

  VS_VERSIONINFO structure rules implemented here (MSDN "VS_VERSIONINFO"):
  each block is { WORD wLength; WORD wValueLength; WORD wType; WCHAR szKey[];
  pad-to-32-bit; Value; pad-to-32-bit; children }. For wType=1 (string) blocks
  wValueLength counts WORDs of the value INCLUDING the terminating null; for
  wType=0 (binary) blocks it counts bytes. Block lengths include trailing
  padding so every block starts on a 32-bit boundary relative to the resource
  start (offset 0 of the blob).

  The driver verifies every write by re-reading the patched resources and the
  FileDescription through the Windows version APIs - never silent success.
#>

function Get-ZcodeInstanceIdentityMap {
  # Per-clone exe-identity alias map. Parity-tested against $InstanceMap in
  # src\windows\launch_zcode_second_instance.ps1 (tests\zcode_exe_identity.Tests.ps1):
  # DisplayName + AumidSuffix + BrandingRepo must match exactly; ExeName is the
  # Task-Manager-identity copy the launcher starts clones from.
  # Frozen-keys rule: the instance keys (Second..Sixth) are plumbing; the
  # display vocabulary (Blue..Orange) is what users see, including the new
  # Task Manager group names.
  return @{
    'Second' = @{ ExeName = 'ZCode-Blue.exe';   DisplayName = 'Blue';   AumidSuffix = '2'; BrandingRepo = 'zcode-blue-branding' }
    'Third'  = @{ ExeName = 'ZCode-Yellow.exe'; DisplayName = 'Yellow'; AumidSuffix = '3'; BrandingRepo = 'zcode-yellow-branding' }
    'Fourth' = @{ ExeName = 'ZCode-Green.exe';  DisplayName = 'Green';  AumidSuffix = '4'; BrandingRepo = 'zcode-green-branding' }
    'Fifth'  = @{ ExeName = 'ZCode-Red.exe';    DisplayName = 'Red';    AumidSuffix = '5'; BrandingRepo = 'zcode-red-branding' }
    'Sixth'  = @{ ExeName = 'ZCode-Orange.exe'; DisplayName = 'Orange'; AumidSuffix = '6'; BrandingRepo = 'zcode-orange-branding' }
  }
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
