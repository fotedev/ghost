# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/set_zcode_bot.ps1 guardian logic.
# The script is DOT-SOURCED (its dot-source guard defines the functions and
# the path map only - no live scan, no exit), so every assertion below runs
# the REAL script code (Get-BotCredentialSha8 / Get-HomeTelegramBots) against
# TestDrive fixtures - never the live homes, never a test-local
# re-implementation. The guardian never writes secrets: it fingerprints the
# encrypted credentials.json -> bot:<id>:credential (enc:v1:) via sha8 + bot
# id across BOTH bot-config.json and bot-config.v3.json.

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\set_zcode_bot.ps1')
    $ErrorActionPreference = $prevEap

    function New-TestBotHome {
        param([string]$Root, [string]$BotId, [string]$CredValue, [bool]$EnabledV2, [bool]$EnabledV3)
        $zcode = Join-Path $Root '.zcode'
        New-Item -ItemType Directory -Path (Join-Path $zcode 'v2') -Force | Out-Null
        $creds = [ordered]@{ }
        $creds[('bot:' + $BotId + ':credential')] = $CredValue
        [System.IO.File]::WriteAllText((Join-Path $zcode 'v2\credentials.json'), ($creds | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
        foreach ($pair in @(@('bot-config.json', $EnabledV2), @('bot-config.v3.json', $EnabledV3))) {
            $cfg = [ordered]@{
                version = 2
                bots    = @(@{
                        id            = $BotId
                        name          = 'TestBot'
                        provider      = 'telegram'
                        enabled       = $pair[1]
                        credentialRef = ('bot:' + $BotId + ':credential')
                    })
            }
            [System.IO.File]::WriteAllText((Join-Path $zcode ('v2\' + $pair[0])), ($cfg | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
        }
        return $zcode
    }

    function New-TestPaths {
        param([string]$ZCodePath)
        return @{ ZCode = $ZCodePath; Roaming = $ZCodePath; Home = $ZCodePath }
    }
}

Describe 'Telegram guardian (real script code, dot-sourced)' {
    It 'dot-sourcing defines the guardian functions without running the live scan' {
        Get-Command Get-BotCredentialSha8 -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-HomeTelegramBots -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Get-AllTelegramBots -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'same enc:v1: value yields same sha8 across homes (duplicate detected)' {
        $a = Join-Path $TestDrive 'homeA'
        $b = Join-Path $TestDrive 'homeB'
        $za = New-TestBotHome -Root $a -BotId 'bot-aaa' -CredValue 'enc:v1:SHARED' -EnabledV2 $true -EnabledV3 $true
        $zb = New-TestBotHome -Root $b -BotId 'bot-aaa' -CredValue 'enc:v1:SHARED' -EnabledV2 $false -EnabledV3 $false
        $shaA = Get-BotCredentialSha8 -CredentialsPath (Join-Path $za 'v2\credentials.json') -CredentialRef 'bot:bot-aaa:credential'
        $shaB = Get-BotCredentialSha8 -CredentialsPath (Join-Path $zb 'v2\credentials.json') -CredentialRef 'bot:bot-aaa:credential'
        $shaA | Should -Match '^[0-9a-f]{8}$'
        $shaB | Should -Be $shaA
    }

    It 'distinct enc:v1: values yield distinct sha8 (unique bot allowed)' {
        $a = Join-Path $TestDrive 'homeC'
        $b = Join-Path $TestDrive 'homeD'
        $za = New-TestBotHome -Root $a -BotId 'bot-aaa' -CredValue 'enc:v1:ONE' -EnabledV2 $true -EnabledV3 $true
        $zb = New-TestBotHome -Root $b -BotId 'bot-bbb' -CredValue 'enc:v1:TWO' -EnabledV2 $true -EnabledV3 $true
        $shaA = Get-BotCredentialSha8 -CredentialsPath (Join-Path $za 'v2\credentials.json') -CredentialRef 'bot:bot-aaa:credential'
        $shaB = Get-BotCredentialSha8 -CredentialsPath (Join-Path $zb 'v2\credentials.json') -CredentialRef 'bot:bot-bbb:credential'
        $shaB | Should -Not -Be $shaA
    }

    It 'detects v2/v3 enabled mismatch (the 2026-10-16 Fourth split)' {
        $root = Join-Path $TestDrive 'homeE'
        $zcode = New-TestBotHome -Root $root -BotId 'bot-aaa' -CredValue 'enc:v1:X' -EnabledV2 $false -EnabledV3 $true
        $rows = @(Get-HomeTelegramBots -Name 'Fourth' -Paths (New-TestPaths -ZCodePath $zcode))
        $rows.Count | Should -Be 2
        @($rows | Where-Object { $_.File -eq 'v2\bot-config.json' -and -not $_.Enabled }).Count | Should -Be 1
        @($rows | Where-Object { $_.File -eq 'v2\bot-config.v3.json' -and $_.Enabled }).Count | Should -Be 1
        @($rows | ForEach-Object { $_.Enabled } | Select-Object -Unique).Count | Should -Be 2
    }

    It 'missing credential ref yields empty sha8 (safe disable path)' {
        $root = Join-Path $TestDrive 'homeF'
        $zcode = New-TestBotHome -Root $root -BotId 'bot-aaa' -CredValue 'enc:v1:X' -EnabledV2 $false -EnabledV3 $false
        Get-BotCredentialSha8 -CredentialsPath (Join-Path $zcode 'v2\credentials.json') -CredentialRef 'bot:bot-missing:credential' | Should -Be ''
    }

    It 'non-telegram rows and parse-failed config files are skipped by the scan' {
        $zcode = Join-Path $TestDrive 'homeG'
        $v2 = Join-Path $zcode 'v2'
        New-Item -ItemType Directory -Path $v2 -Force | Out-Null
        $mixed = [ordered]@{
            bots = @(
                @{ id = 'bot-tg'; provider = 'telegram'; enabled = $true; credentialRef = 'bot:bot-tg:credential' },
                @{ id = 'bot-nt'; provider = 'slack'; enabled = $true; credentialRef = 'bot:bot-nt:credential' }
            )
        }
        [System.IO.File]::WriteAllText((Join-Path $v2 'bot-config.json'), ($mixed | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding $false))
        [System.IO.File]::WriteAllText((Join-Path $v2 'bot-config.v3.json'), '{ not valid json', (New-Object System.Text.UTF8Encoding $false))
        $rows = @(Get-HomeTelegramBots -Name 'Second' -Paths (New-TestPaths -ZCodePath $zcode))
        $rows.Count | Should -Be 1
        $rows[0].Id | Should -Be 'bot-tg'
        $rows[0].File | Should -Be 'v2\bot-config.json'
        $rows[0].CredSha8 | Should -Be ''   # credentials.json absent -> empty sha8
    }
}
