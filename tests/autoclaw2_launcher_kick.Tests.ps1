# SPDX-License-Identifier: Apache-2.0
# Regression pins for the launcher-side taskbar-group KICK in
# src/windows/launch_autoclaw2_clone.ps1 (2026-11-09).
#
# Why this file exists: the 2026-11-06 identity PATCH alone was not enough.
# It sets System.AppUserModel.ID on the window before the first show, but the
# shell has already created that window's taskbar group by then and does not
# rebuild it on a plain property write - every clone kept sharing one button
# while its store read correctly (live: c1 + c5, stores .c1/.c5, one button).
# The launcher therefore KICKS: temp AUMID -> real AUMID, a real property
# CHANGE, so the shell tears the group down and recreates it.
#
# The spacing assertion is not cosmetic: a 300-400 ms temp->real pair can be
# coalesced by the shell - the temporary group is destroyed and the real one
# is never created, leaving the window with NO taskbar button at all
# (reproduced live on c5; a slower kick restored it).

Describe 'AutoClaw2 launcher taskbar kick' {
    BeforeAll {
        $loader = Join-Path $PSScriptRoot '..\src\windows\launch_autoclaw2_clone.ps1'
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($loader, [ref]$tokens, [ref]$errors)
        $script:ParseErrors = $errors.Count
        $script:Text = Get-Content -LiteralPath $loader -Raw
    }

    It 'parses (PS 5.1 parser, no syntax errors)' {
        $script:ParseErrors | Should -Be 0
    }

    It 'spawns with -PassThru so the kick can target the started PID' {
        $script:Text.Contains('Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path $ExePath) -PassThru') |
            Should -BeTrue
    }

    It 'kicks temp AUMID -> real AUMID with >=1.2s spacing (coalescing guard)' {
        $script:Text.Contains('[Ac2WindowIdentity]::Stamp($targetHwnd, "$expectedAumid.kick")') |
            Should -BeTrue -Because 'the temporary AUMID write is what forces the shell to rebuild the group'
        $script:Text.Contains('[Ac2WindowIdentity]::Stamp($targetHwnd, $expectedAumid)') |
            Should -BeTrue -Because 'the real AUMID must be written back'
        $script:Text | Should -Match 'Stamp\(\$targetHwnd, "\$expectedAumid\.kick"\)[\s\S]{0,300}?Start-Sleep -Milliseconds 1200[\s\S]{0,300}?Stamp\(\$targetHwnd, \$expectedAumid\)' -Because 'a 300-400 ms pair can be coalesced and drop the button entirely'
    }

    It 'verifies the read-back and reports FAILED instead of silent success' {
        $script:Text.Contains('FAILED: taskbar identity $kickResult') | Should -BeTrue
        $script:Text.Contains('$kickOk = $true') | Should -BeTrue
        $script:Text.Contains('$kickRead = [Ac2WindowIdentity]::Read($targetHwnd)') | Should -BeTrue
    }

    It 'targets only its own window: launched PID first, expected AUMID second' {
        $script:Text.Contains('$_.Pid -eq $launched.Id') | Should -BeTrue
        $script:Text.Contains('$_.Aumid -eq $expectedAumid') | Should -BeTrue
        # Never grab an arbitrary AutoClaw2 window just because it exists.
        $script:Text.Contains('$candidates | Select-Object -First 1') | Should -BeFalse
    }

    It 'imports PropVariantClear from ole32, never oleaut32 (ground truth #6)' {
        $script:Text | Should -Match 'DllImport\("ole32\.dll"\)[^\r\n]*PropVariantClear'
        $script:Text | Should -Not -Match 'DllImport\("oleaut32\.dll"\)[^\r\n]*PropVariantClear'
        $script:Text | Should -Not -Match 'DllImport\("propsys\.dll"\)[^\r\n]*PropVariantClear'
    }

    It 'keeps the frozen AUMID vocabulary used by the shortcut installer' {
        $script:Text.Contains('$env:ZWORK_AUMID = "com.zhipuai.autoclaw2.$Instance"') | Should -BeTrue
        $script:Text.Contains("c1 = 'blue'; c2 = 'yellow'; c3 = 'green'; c4 = 'red'; c5 = 'orange'") |
            Should -BeTrue -Because 'the clone colour map must stay in sync with install_autoclaw2_clone_shortcuts.ps1'
    }
}
