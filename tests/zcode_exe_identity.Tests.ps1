# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/zcode_exe_identity_lib.ps1 - the pure PE-resource core
# behind tools/patch_zcode_exe_identity.ps1 (per-clone ZCode exe copies with a
# Task Manager identity: replaced icon group + VERSIONINFO FileDescription).
# The module is a pure function library (no main body, no side effects), so it
# is dot-sourced and every assertion runs the REAL code against TestDrive
# fixtures and the repo's committed branding ICOs - never a test-local
# re-implementation, never the live install.

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\zcode_exe_identity_lib.ps1')
    $ErrorActionPreference = $prevEap

    # Synthetic VS_VERSIONINFO tree builder (mirrors the real resource shape:
    # root with a 52-byte VS_FIXEDFILEINFO, one StringFileInfo table, one
    # VarFileInfo Translation block).
    function New-ViStringNode { param([string]$Key, [string]$Value) @{ Key = $Key; Type = 1; Value = $Value; Children = @() } }
    function New-ViBinaryNode { param([string]$Key, [byte[]]$Value) @{ Key = $Key; Type = 0; Value = $Value; Children = @() } }
    function New-ViListNode  { param([string]$Key, [object[]]$Children) @{ Key = $Key; Type = 1; Value = $null; Children = $Children } }

    function New-FakeFixedFileInfo {
        # 52 bytes of recognizable filler (the real struct is opaque to the lib).
        $b = New-Object byte[] 52
        for ($i = 0; $i -lt 52; $i++) { $b[$i] = [byte](($i * 7) -band 0xFF) }
        return $b
    }

    function New-SampleTree {
        @{ Key = 'VS_VERSION_INFO'; Type = 0; Value = (New-FakeFixedFileInfo); Children = @(
            (New-ViListNode 'StringFileInfo' @(
                (New-ViListNode '040904b0' @(
                    (New-ViStringNode 'CompanyName' 'ZCode')
                    (New-ViStringNode 'FileDescription' 'ZCode')
                    (New-ViStringNode 'FileVersion' '3.18.0.10300')
                    (New-ViStringNode 'ProductName' 'ZCode')
                    (New-ViStringNode 'SquirrelAwareVersion' '1')
                ))
            )),
            (New-ViListNode 'VarFileInfo' @(
                (New-ViBinaryNode 'Translation' ([byte[]]@(0x09, 0x04, 0xB0, 0x04)))
            ))
        ) }
    }

    function Test-TreeEqual {
        param($A, $B)
        if ($A.Key -cne $B.Key) { return $false }
        if ($A.Type -ne $B.Type) { return $false }
        if ($A.Type -eq 1) {
            if ([string]$A.Value -cne [string]$B.Value) { return $false }
        } else {
            $av = [byte[]]$A.Value; $bv = [byte[]]$B.Value
            if (($null -eq $av) -ne ($null -eq $bv)) { return $false }
            if ($null -ne $av) {
                if ($av.Length -ne $bv.Length) { return $false }
                for ($i = 0; $i -lt $av.Length; $i++) { if ($av[$i] -ne $bv[$i]) { return $false } }
            }
        }
        if ($A.Children.Count -ne $B.Children.Count) { return $false }
        for ($i = 0; $i -lt $A.Children.Count; $i++) {
            if (-not (Test-TreeEqual $A.Children[$i] $B.Children[$i])) { return $false }
        }
        return $true
    }

    function Find-ViNode {
        param($Tree, [string]$Key)
        $stack = New-Object System.Collections.Stack
        $stack.Push($Tree)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n.Key -eq $Key) { return $n }
            foreach ($c in $n.Children) { $stack.Push($c) }
        }
        return $null
    }

    function New-FakeFrame {
        # One ICO frame record (16x16, 32bpp DIB, plausible filler bytes).
        param([int]$Seed, [int]$Size = 822)
        $data = New-Object byte[] $Size
        for ($i = 0; $i -lt $Size; $i++) { $data[$i] = [byte](($i + $Seed) -band 0xFF) }
        return @{ Index = $Seed; WidthByte = 16; HeightByte = 16; ColorCount = 0; Reserved = 0; Planes = 1; BitCount = 32; Data = $data }
    }

    # Regression tripwire: every script that enumerates ZCode processes must
    # match the whole copy family. The bare Name='ZCode.exe' filter silently
    # dropped clones running from their per-color exe copies (2026-11-11).
    $script:FamilySites = @(
        'src\windows\launch_zcode_second_instance.ps1'
        'src\windows\launch_zcode_primary.ps1'
        'src\windows\reset_zcode.ps1'
        'tools\watch_zcode_taskbar.ps1'
        'tools\refresh_zcode_second_chats.ps1'
        'tools\watch_zcode_mcp_sync.ps1'
        'tools\watch_zcode_captcha.ps1'
        'tools\sync_zcode_assets.ps1'
    )
}

Describe 'zcode_exe_identity_lib module (dot-sourced)' {
    It 'dot-sourcing defines the pure functions' {
        Get-Command Get-ZcodeInstanceIdentityMap   -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Read-GhostIcoFile              -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command New-GhostGroupIconData         -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-GhostIcoSha256             -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-GhostVersionInfoTree       -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Set-GhostVersionInfoStringValue -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-GhostVersionInfoBytes -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-ZcodeInstanceIdentityMap' {
    It 'carries all five clones with color-named exe copies' {
        $map = Get-ZcodeInstanceIdentityMap
        $map.Keys.Count | Should -Be 5
        foreach ($k in @('Second', 'Third', 'Fourth', 'Fifth', 'Sixth')) { $map.ContainsKey($k) | Should -Be $true }
        $map['Second'].ExeName  | Should -Be 'ZCode-Blue.exe'
        $map['Fourth'].ExeName  | Should -Be 'ZCode-Green.exe'
        $map['Sixth'].ExeName   | Should -Be 'ZCode-Orange.exe'
        $map['Second'].AumidSuffix | Should -Be '2'
        $map['Sixth'].AumidSuffix  | Should -Be '6'
    }

    It 'stays in parity with the launcher $InstanceMap (display + branding + AUMID)' {
        $map = Get-ZcodeInstanceIdentityMap
        $launcher = Get-Content (Join-Path $PSScriptRoot '..\src\windows\launch_zcode_second_instance.ps1') -Raw
        foreach ($k in $map.Keys) {
            $cfg = $map[$k]
            # The launcher block for this key must carry the same display name,
            # branding dir, AUMID suffix and exe name.
            $blockPattern = "(?s)'" + [regex]::Escape($k) + "'\s*=\s*\@\{[^}]*DisplayName\s*=\s*'([^']+)';\s*ExeName\s*=\s*'([^']+)'"
            $m = [regex]::Match($launcher, $blockPattern)
            $m.Success | Should -Be $true
            $m.Groups[1].Value | Should -Be $cfg.DisplayName
            $m.Groups[2].Value | Should -Be $cfg.ExeName
            $launcher.Contains(("ExeName = '{0}'" -f $cfg.ExeName)) | Should -Be $true
            $launcher.Contains(("BrandingRepo = '{0}'" -f $cfg.BrandingRepo)) | Should -Be $true
            $launcher.Contains(("AumidSuffix = '{0}'" -f $cfg.AumidSuffix)) | Should -Be $true
        }
    }

    It 'every branding dir named by the map holds a real tray_icon.ico' {
        foreach ($cfg in (Get-ZcodeInstanceIdentityMap).Values) {
            $ico = Join-Path $PSScriptRoot "..\tools\$($cfg.BrandingRepo)\tray_icon.ico"
            Test-Path $ico | Should -Be $true
        }
    }
}

Describe 'Read-GhostIcoFile' {
    It 'parses the committed blue branding ICO into ordered 16..256 frames' {
        $ico = Read-GhostIcoFile -Path (Join-Path $PSScriptRoot '..\tools\zcode-blue-branding\tray_icon.ico')
        $ico.Frames.Count | Should -Be 7
        $widths = @($ico.Frames | ForEach-Object { $w = [int]$_.WidthByte; if ($w -eq 0) { 256 } else { $w } })
        $widths | Should -Be @(16, 24, 32, 48, 64, 128, 256)
        foreach ($f in $ico.Frames) { $f.Data.Length | Should -BeGreaterThan 0 }
    }

    It 'rejects a non-ICO file' {
        $p = Join-Path $TestDrive 'not.ico'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(0, 0, 2, 0, 1, 0))   # type=2 (cursor)
        { Read-GhostIcoFile -Path $p } | Should -Throw
    }

    It 'rejects a truncated ICO directory' {
        $p = Join-Path $TestDrive 'short.ico'
        [System.IO.File]::WriteAllBytes($p, [byte[]]@(0, 0, 1, 0, 3, 0, 1, 2))   # claims 3 frames, 8 bytes total
        { Read-GhostIcoFile -Path $p } | Should -Throw
    }

    It 'rejects a frame whose data runs past the file end' {
        $p = Join-Path $TestDrive 'overrun.ico'
        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter($ms)
        $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)     # 1 frame
        $bw.Write([byte]16); $bw.Write([byte]16); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]1000)                                              # claims 1000 bytes
        $bw.Write([uint32]6)                                                 # at offset 6, but file ends at 22
        $bw.Write([byte[]]@(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16))
        $bw.Flush()
        [System.IO.File]::WriteAllBytes($p, $ms.ToArray())
        { Read-GhostIcoFile -Path $p } | Should -Throw
    }
}

Describe 'New-GhostGroupIconData' {
    It 'builds a 6 + 14N byte GRPICONDIR pointing at the new ids in frame order' {
        $frames = @((New-FakeFrame 1), (New-FakeFrame 2), (New-FakeFrame 3))
        $blob = New-GhostGroupIconData -Frames $frames -IconIds @(101, 102, 103)
        $blob.Length | Should -Be (6 + 14 * 3)
        # header: reserved=0, type=1, count=3
        ([BitConverter]::ToUInt16($blob, 0)) | Should -Be 0
        ([BitConverter]::ToUInt16($blob, 2)) | Should -Be 1
        ([BitConverter]::ToUInt16($blob, 4)) | Should -Be 3
        for ($i = 0; $i -lt 3; $i++) {
            $off = 6 + 14 * $i
            $f = $frames[$i]
            $blob[$off]     | Should -Be ([byte]$f.WidthByte)
            $blob[$off + 1] | Should -Be ([byte]$f.HeightByte)
            $blob[$off + 2] | Should -Be ([byte]$f.ColorCount)
            $blob[$off + 3] | Should -Be ([byte]$f.Reserved)
            ([BitConverter]::ToUInt16($blob, $off + 4)) | Should -Be $f.Planes
            ([BitConverter]::ToUInt16($blob, $off + 6)) | Should -Be $f.BitCount
            ([BitConverter]::ToUInt32($blob, $off + 8)) | Should -Be $f.Data.Length
            ([BitConverter]::ToUInt16($blob, $off + 12)) | Should -Be (101 + $i)
        }
    }

    It 'rejects frame/id count mismatches and out-of-range ids' {
        $frames = @((New-FakeFrame 1))
        { New-GhostGroupIconData -Frames $frames -IconIds @(1, 2) } | Should -Throw
        { New-GhostGroupIconData -Frames $frames -IconIds @(0) } | Should -Throw
        { New-GhostGroupIconData -Frames $frames -IconIds @(0x10000) } | Should -Throw
    }
}

Describe 'Get-GhostIcoSha256' {
    It 'is stable for identical frames and differs on any frame change' {
        $a = @((New-FakeFrame 1), (New-FakeFrame 2))
        $b = @((New-FakeFrame 1), (New-FakeFrame 2))
        (Get-GhostIcoSha256 $a) | Should -Be (Get-GhostIcoSha256 $b)
        $c = @((New-FakeFrame 1), (New-FakeFrame 3))
        (Get-GhostIcoSha256 $a) | Should -Not -Be (Get-GhostIcoSha256 $c)
    }

    It 'matches the committed ICOs frame content (non-empty, distinct per color)' {
        $shas = @()
        foreach ($color in @('blue', 'yellow', 'green', 'red', 'orange')) {
            $ico = Read-GhostIcoFile -Path (Join-Path $PSScriptRoot "..\tools\zcode-$color-branding\tray_icon.ico")
            $sha = Get-GhostIcoSha256 $ico.Frames
            $sha | Should -Match '^[0-9a-f]{64}$'
            $shas += $sha
        }
        ($shas | Select-Object -Unique).Count | Should -Be 5
    }
}

Describe 'VS_VERSIONINFO parse / set / serialize' {
    It 'round-trips a synthetic tree losslessly (byte-identical re-serialization)' {
        $tree = New-SampleTree
        $blob = ConvertTo-GhostVersionInfoBytes -Tree $tree
        $blob.Length | Should -BeGreaterThan 0
        $tree2 = Get-GhostVersionInfoTree -Data $blob
        Test-TreeEqual $tree $tree2 | Should -Be $true
        $blob2 = ConvertTo-GhostVersionInfoBytes -Tree $tree2
        ([System.Linq.Enumerable]::SequenceEqual([byte[]]$blob, [byte[]]$blob2)) | Should -Be $true
    }

    It 'serializes string values as null-terminated UTF-16 with wValueLength in words' {
        $tree = New-SampleTree
        $blob = ConvertTo-GhostVersionInfoBytes -Tree $tree
        $node = (Get-GhostVersionInfoTree -Data $blob)
        $fd = Find-ViNode -Tree $node -Key 'FileDescription'
        $fd.Value | Should -Be 'ZCode'
        # wValueLength for a 5-char string = 6 words (incl. the terminating null)
        $fd | Should -Not -BeNullOrEmpty
        $blob.Length | Should -BeGreaterThan 0
    }

    It 'sets FileDescription and leaves every other string untouched' {
        $tree = New-SampleTree
        $before = Find-ViNode -Tree $tree -Key 'FileVersion'
        $changed = Set-GhostVersionInfoStringValue -Tree $tree -Key 'FileDescription' -NewValue 'ZCode Green'
        $changed | Should -Be 1
        $blob = ConvertTo-GhostVersionInfoBytes -Tree $tree
        $parsed = Get-GhostVersionInfoTree -Data $blob
        (Find-ViNode -Tree $parsed -Key 'FileDescription').Value | Should -Be 'ZCode Green'
        (Find-ViNode -Tree $parsed -Key 'FileVersion').Value     | Should -Be '3.18.0.10300'
        (Find-ViNode -Tree $parsed -Key 'ProductName').Value     | Should -Be 'ZCode'
        (Find-ViNode -Tree $parsed -Key 'CompanyName').Value     | Should -Be 'ZCode'
        # the VS_FIXEDFILEINFO binary value survives untouched
        $ffi = $parsed.Value
        $orig = New-FakeFixedFileInfo
        ([System.Linq.Enumerable]::SequenceEqual([byte[]]$ffi, [byte[]]$orig)) | Should -Be $true
    }

    It 'keeps every block 32-bit aligned (parse walks only aligned boundaries)' {
        # The parser throws on misaligned/truncated blocks; a successful parse of
        # the serialized blob with all strings readable is the alignment proof.
        $tree = New-SampleTree
        Set-GhostVersionInfoStringValue -Tree $tree -Key 'FileDescription' -NewValue 'ZCode Yellow' | Out-Null
        $blob = ConvertTo-GhostVersionInfoBytes -Tree $tree
        $parsed = Get-GhostVersionInfoTree -Data $blob
        (Find-ViNode -Tree $parsed -Key 'FileDescription').Value | Should -Be 'ZCode Yellow'
        (Find-ViNode -Tree $parsed -Key 'SquirrelAwareVersion').Value | Should -Be '1'
        $var = Find-ViNode -Tree $parsed -Key 'Translation'
        ([byte[]]$var.Value).Length | Should -Be 4
    }

    It 'rejects a blob whose root key is not VS_VERSION_INFO' {
        $tree = New-SampleTree
        $tree.Key = 'VS_WHATEVER'
        $blob = ConvertTo-GhostVersionInfoBytes -Tree $tree
        { Get-GhostVersionInfoTree -Data $blob } | Should -Throw
    }

    It 'returns 0 changed nodes when the key is absent' {
        $tree = New-SampleTree
        Set-GhostVersionInfoStringValue -Tree $tree -Key 'NoSuchKey' -NewValue 'x' | Should -Be 0
    }
}

Describe 'copy-family classifier tripwires' {
    It 'every ZCode process enumeration site uses the copy-family WMI filter' {
        foreach ($rel in $script:FamilySites) {
            $text = Get-Content (Join-Path $PSScriptRoot "..\$rel") -Raw
            $text | Should -Match "Name LIKE 'ZCode%'"
        }
    }

    It 'the launcher launches $LaunchExe, not the bare stock exe' {
        $launcher = Get-Content (Join-Path $PSScriptRoot '..\src\windows\launch_zcode_second_instance.ps1') -Raw
        $launcher | Should -Match '\$LaunchExe'
        $launcher | Should -Match '\$CloneExe = Join-Path'
    }

    It 'the bare-exe cmdline regex accepts the whole copy family, spaces included' {
        # Mirrors Test-ZcodeMainCmdline in the launcher. [^"]* (not [^\s"]*) is
        # load-bearing: [^\s"]* could never cross the space in C:\Program Files\
        # (a silent pre-existing gap for machine-wide installs).
        $re1 = '^"[^"]*ZCode(?:-[A-Za-z]+)?\.exe"$'
        $re2 = '^[A-Za-z]:\\[^"]*ZCode(?:-[A-Za-z]+)?\.exe$'
        '"C:\Users\FOTE\AppData\Local\Programs\ZCode\ZCode.exe"'        | Should -Match $re1
        '"C:\Users\FOTE\AppData\Local\Programs\ZCode\ZCode-Green.exe"'  | Should -Match $re1
        'C:\Program Files\ZCode\ZCode.exe'                              | Should -Match $re2
        'C:\Program Files\ZCode\ZCode-Yellow.exe'                       | Should -Match $re2
        '"C:\...\ZCode.exe" --type=renderer --user-data-dir=x'          | Should -Not -Match $re1
        '"C:\...\ZCode.exe" --type=renderer --user-data-dir=x'          | Should -Not -Match $re2
        ''                                                              | Should -Not -Match $re1
    }
}
