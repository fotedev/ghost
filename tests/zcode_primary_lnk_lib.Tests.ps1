# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/zcode_primary_lnk_lib.ps1 - the pure decision core for
# the recurring PRIMARY ZCode.lnk hijack (shared by the shortcuts installer's
# -RepairPrimaryAumid and the resident taskbar watcher's hijack guard). The
# lib is a pure function library (no COM, no side effects), so it is
# dot-sourced and every assertion runs the REAL code against TestDrive
# fixtures - never a test-local re-implementation, never the live install.
#
# Regression context (2026-11-11, live-verified): a pin rewrite drifted the
# Start-menu ZCode.lnk TARGET onto ZCode-Orange.exe; the old repair kept the
# drifted target ("the lnk's own target wins") and set the icon FROM it, so
# the Primary tile stayed orange behind a clean AUMID the AUMID-only guard
# could no longer see. These tests pin the widened detection and the
# repairability gating (target/icon checks demand a stock exe to restore to).

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\zcode_primary_lnk_lib.ps1')
    $ErrorActionPreference = $prevEap
    $stock = Join-Path $TestDrive 'install\ZCode.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $stock) -Force | Out-Null
    Set-Content -Path $stock -Value 'x'
}

Describe 'Get-ZCodePrimaryLnkPaths' {
    # Join-Path validates the drive qualifier, so injected roots must be real
    # drives - TestDrive fixtures, not fake letters.
    It 'joins ZCode.lnk under Desktop + both Start Menu locations, in order' {
        $desk = Join-Path $TestDrive 'desk'; $ad = Join-Path $TestDrive 'appdata'; $pd = Join-Path $TestDrive 'pdata'
        $paths = Get-ZCodePrimaryLnkPaths -DesktopPath $desk -AppDataRoot $ad -ProgramDataRoot $pd
        $paths.Count | Should -Be 3
        $paths[0] | Should -Be (Join-Path $desk 'ZCode.lnk')
        $paths[1] | Should -Be (Join-Path $ad 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk')
        $paths[2] | Should -Be (Join-Path $pd 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk')
    }
}

Describe 'Get-ZCodeExeCandidates' {
    It 'always names the stock ZCode.exe, never a per-color copy' {
        $la = Join-Path $TestDrive 'la'; $pf = Join-Path $TestDrive 'pf'; $pfx86 = Join-Path $TestDrive 'pfx86'
        $cands = Get-ZCodeExeCandidates -LocalAppData $la -ProgramFiles $pf -ProgramFilesX86 $pfx86
        $cands.Count | Should -Be 3
        foreach ($c in $cands) { (Split-Path -Leaf $c) | Should -Be 'ZCode.exe' }
        $cands[0] | Should -Be (Join-Path $la 'Programs\ZCode\ZCode.exe')
    }
    It 'skips blank roots instead of emitting a rooted fallback path' {
        $pf = Join-Path $TestDrive 'pf'
        $cands = Get-ZCodeExeCandidates -LocalAppData '' -ProgramFiles $pf -ProgramFilesX86 $null
        $cands.Count | Should -Be 1
        $cands[0] | Should -Be (Join-Path $pf 'ZCode\ZCode.exe')
    }
}

Describe 'Resolve-StockZCodeExe' {
    It 'returns the first candidate that exists on disk' {
        $a = Join-Path $TestDrive 'a\ZCode.exe'
        $b = Join-Path $TestDrive 'b\ZCode.exe'
        New-Item -ItemType Directory -Path (Split-Path -Parent $b) -Force | Out-Null
        Set-Content -Path $b -Value 'x'
        Resolve-StockZCodeExe -Candidates @($a, $b) | Should -Be $b
    }
    It 'returns null when nothing exists' {
        Resolve-StockZCodeExe -Candidates @((Join-Path $TestDrive 'missing\ZCode.exe')) | Should -BeNullOrEmpty
    }
}

Describe 'Test-ZCodeCloneExeTarget' {
    It 'flags a per-color exe copy target regardless of directory' {
        Test-ZCodeCloneExeTarget -TargetPath 'C:\Users\FOTE\AppData\Local\Programs\ZCode\ZCode-Orange.exe' | Should -BeTrue
        Test-ZCodeCloneExeTarget -TargetPath 'D:\anywhere\ZCode-Blue.exe' | Should -BeTrue
    }
    It 'normalizes forward slashes' {
        Test-ZCodeCloneExeTarget -TargetPath 'L:/x/ZCode-Orange.exe' | Should -BeTrue
    }
    It 'accepts the stock ZCode.exe and unrelated executables' {
        Test-ZCodeCloneExeTarget -TargetPath $stock | Should -BeFalse
        Test-ZCodeCloneExeTarget -TargetPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' | Should -BeFalse
        Test-ZCodeCloneExeTarget -TargetPath 'C:\x\ZCode2.exe' | Should -BeFalse
    }
    It 'rejects backup/index artifacts and empty targets' {
        Test-ZCodeCloneExeTarget -TargetPath 'C:\x\ZCode-Orange.exe.bak' | Should -BeFalse
        Test-ZCodeCloneExeTarget -TargetPath 'C:\x\ZCode-Orange' | Should -BeFalse
        Test-ZCodeCloneExeTarget -TargetPath '' | Should -BeFalse
        Test-ZCodeCloneExeTarget -TargetPath '   ' | Should -BeFalse
    }
}

Describe 'Test-PrimaryLnkHijackState' {
    It 'flags a clone-suffixed AUMID even when target and icon look healthy' {
        $r = Test-PrimaryLnkHijackState -Aumid 'dev.zcode.app.6' -TargetPath $stock -IconLocation "$stock,0" -StockExe $stock
        $r | Should -Not -BeNullOrEmpty
        $r | Should -Match 'AUMID'
    }
    It 'accepts the base AUMID and a non-numeric suffix' {
        Test-PrimaryLnkHijackState -Aumid 'dev.zcode.app' -TargetPath $stock -IconLocation "$stock,0" -StockExe $stock | Should -BeNullOrEmpty
        Test-PrimaryLnkHijackState -Aumid 'dev.zcode.app.foo' -TargetPath $stock -IconLocation "$stock,0" -StockExe $stock | Should -BeNullOrEmpty
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation "$stock,0" -StockExe $stock | Should -BeNullOrEmpty
    }
    It 'flags a target drifted onto a clone exe copy' {
        $r = Test-PrimaryLnkHijackState -Aumid 'dev.zcode.app' -TargetPath 'C:\x\ZCode-Orange.exe' -IconLocation "$stock,0" -StockExe $stock
        $r | Should -Not -BeNullOrEmpty
        $r | Should -Match 'target'
    }
    It 'gates the target/icon checks on a resolvable stock exe (never demands an unrepairable fix)' {
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath 'C:\x\ZCode-Orange.exe' -IconLocation 'C:\x\tray_icon.ico,0' -StockExe '' | Should -BeNullOrEmpty
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation '' -StockExe '' | Should -BeNullOrEmpty
    }
    It 'flags a wiped icon field (the verified 2026-09-28 ",0" shape) and an empty one' {
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation ',0' -StockExe $stock | Should -Match 'icon'
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation '' -StockExe $stock | Should -Match 'icon'
    }
    It 'flags an icon field pointing anywhere but the stock exe' {
        $r = Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation 'C:\x\zcode-orange-branding\tray_icon.ico,0' -StockExe $stock
        $r | Should -Match 'icon'
    }
    It 'accepts the stock icon at any explicit index, case-insensitively' {
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation "$stock,0" -StockExe $stock | Should -BeNullOrEmpty
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation "$stock,1" -StockExe $stock | Should -BeNullOrEmpty
        Test-PrimaryLnkHijackState -Aumid '' -TargetPath $stock -IconLocation "$($stock.ToUpper()),0" -StockExe $stock | Should -BeNullOrEmpty
    }
}

Describe 'installer + watcher consume the shared lib' {
    It 'the installer repair path wires the lib and carries no private copy of the predicate' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\tools\install_zcode_second_shortcuts.ps1') -Raw
        $t | Should -Match 'zcode_primary_lnk_lib\.ps1'
        $t | Should -Match 'Repair-PrimaryLnkTarget'
        $t | Should -Match 'Get-StockZCodeExe'
        $t | Should -Not -Match 'function Get-ZCodeExeForIcon'
    }
    It 'the watcher guard wires the lib and decides through the shared state test' {
        $t = Get-Content (Join-Path $PSScriptRoot '..\tools\watch_zcode_taskbar.ps1') -Raw
        $t | Should -Match 'zcode_primary_lnk_lib\.ps1'
        $t | Should -Match 'Test-PrimaryLnkHijackState'
        # The old inline AUMID-suffix decision is gone - the lib decides.
        $oldInline = 'if ($id -match ' + "'" + '\.\d+$' + "'" + ')'
        $t | Should -Not -Match ([regex]::Escape($oldInline))
    }
}
