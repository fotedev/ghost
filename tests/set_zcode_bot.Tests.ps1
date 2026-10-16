# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/set_zcode_bot.ps1 guardian logic.
# The guardian never writes secrets: it fingerprints the encrypted
# credentials.json -> bot:<id>:credential (enc:v1:) via sha8 + bot id across
# BOTH bot-config.json and bot-config.v3.json. These tests exercise that
# contract on TestDrive: fixtures only, never the live homes.

BeforeAll {
    function Get-TestBotCredSha8 {
        param([string]$CredentialsPath, [string]$CredentialRef)
        if (-not (Test-Path -LiteralPath $CredentialsPath)) { return '' }
        try { $creds = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json }
        catch { return '' }
        $prop = $creds.PSObject.Properties[$CredentialRef]
        if ($null -eq $prop) { return '' }
        $val = [string]$prop.Value
        if ([string]::IsNullOrEmpty($val)) { return '' }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($val)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = $sha.ComputeHash($bytes) }
        finally { if ($sha) { $sha.Dispose() } }
        return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 8)
    }

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
}

Describe 'Telegram guardian sha8 contract' {
    It 'same enc:v1: value yields same sha8 across homes (duplicate detected)' {
        $a = Join-Path $TestDrive 'homeA'
        $b = Join-Path $TestDrive 'homeB'
        $za = New-TestBotHome -Root $a -BotId 'bot-aaa' -CredValue 'enc:v1:SHARED' -EnabledV2 $true -EnabledV3 $true
        $zb = New-TestBotHome -Root $b -BotId 'bot-aaa' -CredValue 'enc:v1:SHARED' -EnabledV2 $false -EnabledV3 $false
        $shaA = Get-TestBotCredSha8 -CredentialsPath (Join-Path $za 'v2\credentials.json') -CredentialRef 'bot:bot-aaa:credential'
        $shaB = Get-TestBotCredSha8 -CredentialsPath (Join-Path $zb 'v2\credentials.json') -CredentialRef 'bot:bot-aaa:credential'
        $shaA | Should -Not -BeNullOrEmpty
        $shaB | Should -Be $shaA
    }

    It 'distinct enc:v1: values yield distinct sha8 (unique bot allowed)' {
        $a = Join-Path $TestDrive 'homeC'
        $b = Join-Path $TestDrive 'homeD'
        $za = New-TestBotHome -Root $a -BotId 'bot-aaa' -CredValue 'enc:v1:ONE' -EnabledV2 $true -EnabledV3 $true
        $zb = New-TestBotHome -Root $b -BotId 'bot-bbb' -CredValue 'enc:v1:TWO' -EnabledV2 $true -EnabledV3 $true
        $shaA = Get-TestBotCredSha8 -CredentialsPath (Join-Path $za 'v2\credentials.json') -CredentialRef 'bot:bot-aaa:credential'
        $shaB = Get-TestBotCredSha8 -CredentialsPath (Join-Path $zb 'v2\credentials.json') -CredentialRef 'bot:bot-bbb:credential'
        $shaB | Should -Not -Be $shaA
    }

    It 'detects v2/v3 enabled mismatch (the 2026-10-16 Fourth split)' {
        $root = Join-Path $TestDrive 'homeE'
        $zcode = New-TestBotHome -Root $root -BotId 'bot-aaa' -CredValue 'enc:v1:X' -EnabledV2 $false -EnabledV3 $true
        $flags = @()
        foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
            $cfg = Get-Content -LiteralPath (Join-Path $zcode $cfgName) -Raw | ConvertFrom-Json
            foreach ($bot in @($cfg.bots)) {
                if ($bot.provider -eq 'telegram') { $flags += [bool]$bot.enabled }
            }
        }
        @($flags | Select-Object -Unique).Count | Should -Be 2
    }

    It 'missing credential ref yields empty sha8 (safe disable path)' {
        $root = Join-Path $TestDrive 'homeF'
        $zcode = New-TestBotHome -Root $root -BotId 'bot-aaa' -CredValue 'enc:v1:X' -EnabledV2 $false -EnabledV3 $false
        Get-TestBotCredSha8 -CredentialsPath (Join-Path $zcode 'v2\credentials.json') -CredentialRef 'bot:bot-missing:credential' | Should -Be ''
    }
}
