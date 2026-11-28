# SPDX-License-Identifier: Apache-2.0
Describe 'AutoClaw2 stock shortcut drift' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\autoclaw2_primary_lnk.ps1')
        $script:Stock = 'C:\Apps\AutoClaw2\AutoClaw2.exe'
    }

    It 'detects the real Start Menu drift even when the AUMID is already stock' {
        Get-Ac2PrimaryShortcutProblem 'C:\Apps\AutoClaw2\AutoClaw2-Blue.exe' 'com.zhipuai.autoclaw2' $script:Stock |
            Should -Be 'stock shortcut targets a per-color executable'
    }

    It 'detects a clone AUMID on a shortcut still pointing at the stock executable' {
        Get-Ac2PrimaryShortcutProblem $script:Stock 'com.zhipuai.autoclaw2.c1' $script:Stock |
            Should -Be 'stock shortcut carries a clone identity'
    }

    It 'leaves stock, foreign AUMIDs and copies outside this install alone' {
        Get-Ac2PrimaryShortcutProblem $script:Stock 'com.zhipuai.autoclaw2' $script:Stock | Should -BeNullOrEmpty
        Get-Ac2PrimaryShortcutProblem 'C:\Apps\AutoClaw2\AutoClaw2-Blue.exe' 'foreign.app' $script:Stock | Should -BeNullOrEmpty
        Get-Ac2PrimaryShortcutProblem 'C:\Elsewhere\AutoClaw2-Blue.exe' 'com.zhipuai.autoclaw2.c1' $script:Stock | Should -BeNullOrEmpty
        Get-Ac2PrimaryShortcutProblem 'C:\Windows\powershell.exe' 'com.zhipuai.autoclaw2.c1' $script:Stock | Should -BeNullOrEmpty
    }

    It 'scopes Desktop and Start Menu candidates to the two stock names' {
        foreach ($name in @('AutoClaw.lnk', 'AutoClaw2.lnk', 'AutoClaw2 Blue.lnk')) {
            New-Item -ItemType File -Path (Join-Path $TestDrive $name) | Out-Null
        }
        $leaves = @(Get-Ac2PrimaryShortcutPaths -Roots @($TestDrive, $TestDrive) | Split-Path -Leaf)
        $leaves.Count | Should -Be 2
        $leaves | Should -Contain 'AutoClaw.lnk'
        $leaves | Should -Contain 'AutoClaw2.lnk'
        $leaves | Should -Not -Contain 'AutoClaw2 Blue.lnk'
    }
}
