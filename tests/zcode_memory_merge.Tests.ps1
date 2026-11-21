# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/zcode_memory_merge.ps1 - the pure merge core shared by
# tools/sync_zcode_memories.ps1 (MEMORY.md index union + mojibake peel). The
# module is a pure function library (no main body, no side effects), so it is
# dot-sourced and every assertion runs the REAL merge code against TestDrive
# fixtures - never a test-local re-implementation, never the live stores.
#
# Every mojibake FIXTURE is built programmatically
# ([Text.Encoding]::GetEncoding(1252).GetString([Text.Encoding]::UTF8.GetBytes(clean)))
# so this file itself never contains mojibake bytes - keeping it pure-ASCII
# no-BOM UTF-8 makes the fixtures independent of how any editor or CI
# re-saves the file.

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\zcode_memory_merge.ps1')
    $ErrorActionPreference = $prevEap

    function New-Mojibake {
        # Re-mangle $Clean by $Layers rounds of "UTF-8 bytes read as CP1252" -
        # exactly what PS 5.1 Get-Content (ANSI) + re-append did per merge pass.
        param([string]$Clean, [int]$Layers = 1)
        $cp = [System.Text.Encoding]::GetEncoding(1252)
        $s = $Clean
        for ($i = 0; $i -lt $Layers; $i++) {
            $s = $cp.GetString([System.Text.Encoding]::UTF8.GetBytes($s))
        }
        return $s
    }

    $script:Dash = [char]0x2014   # em dash - the char that starts the cascade
    $script:Alef = [char]0x0627   # Arabic alef - outside CP1252 entirely
}

Describe 'zcode_memory_merge module (dot-sourced)' {
    It 'dot-sourcing defines the pure merge functions' {
        Get-Command ConvertFrom-MojibakeLayers -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-MemoryIndexLines       -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Merge-MemoryIndexLines     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Write-MemoryIndexLines     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-MojibakeLayers' {
    It 'clean ASCII is unchanged' {
        $clean = '- [Note](note.md) - plain ascii hook'
        ConvertFrom-MojibakeLayers $clean | Should -Be $clean
    }

    It 'a clean line with an em dash is NOT peeled (its CP1252 bytes are not valid UTF-8)' {
        $clean = "- [Note](n.md) $script:Dash hook"
        ConvertFrom-MojibakeLayers $clean | Should -Be $clean
    }

    It 'clean Arabic is unchanged (characters outside CP1252 fail the encode first)' {
        $clean = "- [Arabic]($script:Alef.md) hook"
        ConvertFrom-MojibakeLayers $clean | Should -Be $clean
    }

    It 'an accented Latin-1 char in a clean line is unchanged' {
        $clean = 'caf' + [char]0x00E9
        ConvertFrom-MojibakeLayers $clean | Should -Be $clean
    }

    It 'one mojibake layer peels back to the original' {
        $clean = "- [Dash]($script:Dash.md) hook"
        ConvertFrom-MojibakeLayers (New-Mojibake -Clean $clean -Layers 1) | Should -Be $clean
    }

    It 'layered (re-mangled) mojibake peels all the way back (the 2026-11-21 incident shape)' {
        $clean = "- [Dash]($script:Dash.md) hook"
        ConvertFrom-MojibakeLayers (New-Mojibake -Clean $clean -Layers 3) | Should -Be $clean
    }

    It 'a mojibake accented char peels' {
        $clean = 'caf' + [char]0x00E9
        ConvertFrom-MojibakeLayers (New-Mojibake -Clean $clean -Layers 2) | Should -Be $clean
    }
}

Describe 'Get-MemoryIndexLines' {
    It 'reads a no-BOM UTF-8 file: trims, drops empties, keeps order' {
        $p = Join-Path $TestDrive 'idx.md'
        $lines = @('# Memory index', '- [A](a.md) hook', '', '  - [B](b.md) spaced  ', '- [C](c.md) hook')
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($p, $lines, $utf8NoBom)
        $got = Get-MemoryIndexLines -Path $p
        $got.Count | Should -Be 4
        $got[0] | Should -Be '# Memory index'
        $got[1] | Should -Be '- [A](a.md) hook'
        $got[2] | Should -Be '- [B](b.md) spaced'
        $got[3] | Should -Be '- [C](c.md) hook'
    }

    It 'strips a UTF-8 BOM and CRLF newlines' {
        $p = Join-Path $TestDrive 'bom.md'
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($p, "- [A](a.md)`r`n- [B](b.md)`r`n", $utf8Bom)
        $got = Get-MemoryIndexLines -Path $p
        $got.Count | Should -Be 2
        $got[0] | Should -Be '- [A](a.md)'
    }

    It 'non-ASCII content (Arabic) survives the read' {
        $p = Join-Path $TestDrive 'ar.md'
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllLines($p, @("- [Arabic]($script:Alef.md) hook"), $utf8NoBom)
        $got = Get-MemoryIndexLines -Path $p
        $got[0] | Should -Be "- [Arabic]($script:Alef.md) hook"
    }
}

Describe 'Merge-MemoryIndexLines (the sync invariant)' {
    It 'primary order kept, clone-only lines appended in clone order, duplicates dropped' {
        $primary = @('- [A](a.md) one', '- [B](b.md) two')
        $clone   = @('- [B](b.md) two', '- [C](c.md) three', '- [A](a.md) one')
        $merged = Merge-MemoryIndexLines -PrimaryLines $primary -CloneLines $clone
        $merged.Count | Should -Be 3
        $merged[0] | Should -Be '- [A](a.md) one'
        $merged[1] | Should -Be '- [B](b.md) two'
        $merged[2] | Should -Be '- [C](c.md) three'
    }

    It 'a mojibake clone line collapses onto its clean primary line (never accumulates)' {
        $clean  = "- [Note](n.md) $script:Dash hook"
        $primary = @($clean, '- [Other](o.md) x')
        $clone   = @((New-Mojibake -Clean $clean -Layers 2), '- [Fresh](f.md) y')
        $merged = Merge-MemoryIndexLines -PrimaryLines $primary -CloneLines $clone
        $merged.Count | Should -Be 3
        $merged[0] | Should -Be $clean
        $merged[2] | Should -Be '- [Fresh](f.md) y'
    }

    It 'primary lines are never removed, even when the clone lacks them' {
        $primary = @('- [A](a.md) one', '- [B](b.md) two')
        $clone   = @('- [C](c.md) three')
        $merged = Merge-MemoryIndexLines -PrimaryLines $primary -CloneLines $clone
        $merged.Count | Should -Be 3
        $merged[0] | Should -Be '- [A](a.md) one'
        $merged[1] | Should -Be '- [B](b.md) two'
    }

    It 'blank and whitespace-only lines are dropped from both sides' {
        $primary = @('- [A](a.md) one', '   ')
        $clone   = @('', '- [B](b.md) two', '  ')
        $merged = Merge-MemoryIndexLines -PrimaryLines $primary -CloneLines $clone
        $merged.Count | Should -Be 2
    }

    It 'empty inputs yield an empty result (the caller decides what an empty store means)' {
        $merged = Merge-MemoryIndexLines -PrimaryLines @() -CloneLines @()
        $merged.Count | Should -Be 0
    }
}

Describe 'Write-MemoryIndexLines (no-BOM UTF-8 contract)' {
    It 'writes UTF-8 WITHOUT a BOM and round-trips through Get-MemoryIndexLines' {
        $p = Join-Path $TestDrive 'out.md'
        $lines = @("- [A](a.md) $script:Dash dash", "- [Arabic]($script:Alef.md) x")
        Write-MemoryIndexLines -Path $p -Lines $lines
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $bytes.Length | Should -BeGreaterThan 0
        # BOM would be EF BB BF; the store is no-BOM UTF-8.
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
        $rt = Get-MemoryIndexLines -Path $p
        $rt.Count | Should -Be 2
        $rt[0] | Should -Be $lines[0]
        $rt[1] | Should -Be $lines[1]
    }

    It 'writes CRLF newlines (the store is Windows-authored)' {
        $p = Join-Path $TestDrive 'crlf.md'
        Write-MemoryIndexLines -Path $p -Lines @('- [A](a.md) one', '- [B](b.md) two')
        $text = [System.IO.File]::ReadAllText($p)
        $text | Should -Match "`r`n"
    }
}
