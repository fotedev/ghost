# SPDX-License-Identifier: Apache-2.0
# Tests for tools/install_t3_opencode_instances.ps1 - the T3 Code
# provider-instance seeder for the OpenCode clone fleet. The core
# (Invoke-T3OpenCodeSeed + its two helpers) is extracted VERBATIM via the
# PowerShell AST and exercised against TEMP settings.json fixtures - the
# real ~/.t3 file is never touched by these tests. The driver's main body
# must not execute during extraction.

Describe 'T3 OpenCode seeding - script hygiene' {
    BeforeAll {
        $script:SeedPath = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\install_t3_opencode_instances.ps1")).Path
        $tokens = $null; $errors = $null
        $script:SeedAst = [System.Management.Automation.Language.Parser]::ParseFile($script:SeedPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "install_t3_opencode_instances.ps1 does not parse: $($errors[0].Message)" }

        foreach ($fnName in @('Get-OpenCodeT3InstanceDefs', 'New-T3OpenCodeEntry', 'Invoke-T3OpenCodeSeed')) {
            $fn = $script:SeedAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $fnName }, $true)
            if ($fn.Count -ne 1) { throw "expected exactly one $fnName, got $($fn.Count)" }
            Invoke-Expression $fn[0].Extent.Text
        }
        $script:PowershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script:LauncherPath = 'C:\repo\src\windows\launch_opencode_cli_light.ps1'
    }

    It 'declares #Requires -Version 5.1 and is CRLF + BOM' {
        (Get-Content -LiteralPath $script:SeedPath -TotalCount 1) -match '#Requires -Version 5.1' | Should -BeTrue
        $bytes = [System.IO.File]::ReadAllBytes($script:SeedPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
    }

    It 'keeps a running-T3 guard (settings are read only at startup)' {
        ((Get-Content -LiteralPath $script:SeedPath -Raw) -match 'Assert-T3Closed') | Should -BeTrue
    }
}

Describe 'T3 OpenCode seeding - instance table' {
    BeforeAll {
        # Pester 6: functions Invoke-Expression'd in another Describe's
        # BeforeAll are not visible here (the sibling suites re-extract per
        # Describe for the same reason).
        $fn = $script:SeedAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Get-OpenCodeT3InstanceDefs' }, $true)
        if ($fn.Count -ne 1) { throw "expected exactly one Get-OpenCodeT3InstanceDefs, got $($fn.Count)" }
        Invoke-Expression $fn[0].Extent.Text
    }

    It 'maps exactly opencode-c1..c5 with the suite colors and accents' {
        $defs = Get-OpenCodeT3InstanceDefs
        $defs.Count | Should -Be 5
        @($defs | ForEach-Object { $_.Instance }) | Should -Be @('c1', 'c2', 'c3', 'c4', 'c5')
        @($defs | ForEach-Object { $_.Color }) | Should -Be @('Blue', 'Yellow', 'Green', 'Red', 'Orange')
        @($defs | ForEach-Object { $_.Key }) | Should -Be @('opencode-c1', 'opencode-c2', 'opencode-c3', 'opencode-c4', 'opencode-c5')
        $defs[0].Accent | Should -Be '#2A7CBD'
        $defs[4].Accent | Should -Match '^#[0-9A-Fa-f]{6}$'
    }
}

Describe 'T3 OpenCode seeding - core on a temp fixture' {
    BeforeAll {
        # Re-extract for THIS Describe's scope (see the instance-table note).
        foreach ($fnName in @('Get-OpenCodeT3InstanceDefs', 'New-T3OpenCodeEntry', 'Invoke-T3OpenCodeSeed')) {
            $fn = $script:SeedAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $fnName }, $true)
            if ($fn.Count -ne 1) { throw "expected exactly one $fnName, got $($fn.Count)" }
            Invoke-Expression $fn[0].Extent.Text
        }
        $script:FixDir = Join-Path ([System.IO.Path]::GetTempPath()) ("oc-t3-seed-tests-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FixDir | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:FixDir) { Remove-Item -LiteralPath $script:FixDir -Recurse -Force }
    }

    It 'seeds 5 instances into an existing file, preserving unrelated keys' {
        $fixture = Join-Path $script:FixDir 'settings.json'
        @'
{
  "favorites": ["keep-me"],
  "providerInstances": {
    "zcode-second": { "driver": "acpRegistry", "displayName": "ZCode Blue", "enabled": true,
      "config": { "source": "local", "commandPath": "node.exe", "commandArgs": ["bridge", "--Instance", "Second"], "customModels": [] } }
  }
}
'@ | Set-Content -LiteralPath $fixture -NoNewline
        $defs = Invoke-T3OpenCodeSeed -Path $fixture -LauncherPath $script:LauncherPath -PowershellPath $script:PowershellPath
        $defs.Count | Should -Be 5

        $root = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
        $root.favorites[0] | Should -Be 'keep-me' -Because "unrelated top-level keys must survive"
        # PSCustomObject does not support string indexing in PS 5.1 - use the
        # PSObject property indexer.
        $root.providerInstances.PSObject.Properties['zcode-second'].Value | Should -Not -BeNullOrEmpty -Because "the ZCode instances must survive the merge"
        $root.providerInstances.PSObject.Properties.Name | Should -Contain 'opencode-c1'
        $entry = $root.providerInstances.PSObject.Properties['opencode-c1'].Value
        $entry.driver | Should -Be 'acpRegistry'
        $entry.displayName | Should -Be 'OpenCode Blue'
        $entry.enabled | Should -Be $true
        $entry.config.source | Should -Be 'local'
        $entry.config.commandPath | Should -Be $script:PowershellPath
        $entry.config.commandArgs[-3] | Should -Be '-Instance'
        $entry.config.commandArgs[-2] | Should -Be 'c1'
        $entry.config.commandArgs[-1] | Should -Be '-Acp'
        ($entry.config.commandArgs | Where-Object { $_ -like '*launch_opencode_cli_light.ps1' }).Count | Should -Be 1
    }

    It 'is idempotent: re-seeding updates in place without duplicating keys' {
        $fixture = Join-Path $script:FixDir 'settings.json'
        $null = Invoke-T3OpenCodeSeed -Path $fixture -LauncherPath $script:LauncherPath -PowershellPath $script:PowershellPath
        $null = Invoke-T3OpenCodeSeed -Path $fixture -LauncherPath $script:LauncherPath -PowershellPath $script:PowershellPath
        $root = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
        @($root.providerInstances.PSObject.Properties.Name | Where-Object { $_ -like 'opencode-*' }).Count | Should -Be 5
    }

    It 'removes exactly the five opencode keys and nothing else' {
        $fixture = Join-Path $script:FixDir 'settings.json'
        $null = Invoke-T3OpenCodeSeed -Path $fixture -LauncherPath $script:LauncherPath -PowershellPath $script:PowershellPath -Remove
        $root = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
        @($root.providerInstances.PSObject.Properties.Name | Where-Object { $_ -like 'opencode-*' }).Count | Should -Be 0
        $root.providerInstances.PSObject.Properties['zcode-second'].Value | Should -Not -BeNullOrEmpty
        $root.favorites[0] | Should -Be 'keep-me'
    }

    It 'creates a fresh settings file when none exists - no backup (nothing to back up), no Copy-Item crash' {
        $fixture = Join-Path $script:FixDir 'fresh.json'
        $null = Invoke-T3OpenCodeSeed -Path $fixture -LauncherPath $script:LauncherPath -PowershellPath $script:PowershellPath
        $root = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
        @($root.providerInstances.PSObject.Properties.Name | Where-Object { $_ -like 'opencode-*' }).Count | Should -Be 5
        (Get-ChildItem -LiteralPath $script:FixDir -Filter 'fresh.json.bak-t3-opencode-*').Count | Should -Be 0 -Because "a fresh seed has no prior file to back up"
    }

    It 'removal on a missing file is a loud no-op' {
        $missing = Join-Path $script:FixDir 'nope.json'
        { Invoke-T3OpenCodeSeed -Path $missing -LauncherPath $script:LauncherPath -PowershellPath $script:PowershellPath -Remove } | Should -Not -Throw
        Test-Path -LiteralPath $missing | Should -BeFalse
    }
}
