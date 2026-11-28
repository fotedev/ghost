# SPDX-License-Identifier: Apache-2.0
# Tests for tools/status_zcode_instances.ps1 - the ZCode six-instance status
# report (ZCode Maintenance [32], gid 108). TA-2 dedup (2026-11-28): the
# classification is SOURCED FROM tools/suite_status_lib.ps1 now (the tool's
# former inline copy was the seed the lib was extracted from); this tool keeps
# its own detail probes (roaming/clone home/deviceMid) + the commit pressure.
# Static pins: the tool stays read-only and lib-backed.

Describe 'ZCode instances status - TA-2 lib-backed contract' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\status_zcode_instances.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "status_zcode_instances.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'is CRLF-clean (repo eol=crlf rule for tracked .ps1; this subject ships ASCII without a BOM)' {
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'sources the classification from the shared suite-status lib (TA-2 dedup)' {
        ($script:Raw -match [regex]::Escape(". (Join-Path `$PSScriptRoot 'suite_status_lib.ps1')")) | Should -BeTrue
        ($script:Raw -match 'Get-GhostSuiteInstanceState -Suite zcode') | Should -BeTrue
        ($script:Raw -match '\$state\.Rows') | Should -BeTrue
    }

    It 'carries NO inline classifier anymore (the EC-K01/copy-exe/marker rules live in the lib)' {
        ($script:Raw -match 'function Get-ZcodeInstanceMains') | Should -BeFalse
        ($script:Raw -match 'function Test-SubtreeMarkers') | Should -BeFalse
        ($script:Raw -match [regex]::Escape("Name LIKE 'ZCode%'")) | Should -BeFalse -Because 'the family filter is the lib suite row now'
    }

    It 'keeps its own detail probes (roaming dir, clone home, deviceMid) + the commit pressure' {
        ($script:Raw -match 'Get-ZcodeDeviceMidPrefix') | Should -BeTrue
        ($script:Raw -match 'telemetry-state\.json') | Should -BeTrue
        ($script:Raw -match 'pressure') | Should -BeTrue
        ($script:Raw -match 'PrivateMemorySize64') | Should -BeTrue
    }

    It 'stays strictly read-only (no Set-Content/Add-Content/WriteAllText/registry writes)' {
        ($script:Raw -match 'Set-Content|Add-Content|WriteAllText|SetValue') | Should -BeFalse
    }

    It 'keeps the instance table in sync with the lib suite row (frozen keys + the MUST-match vocabulary)' {
        foreach ($key in 'Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth') {
            ($script:Raw -match ("Key = '" + $key + "'")) | Should -BeTrue
        }
        foreach ($copy in 'ZCode-Blue.exe', 'ZCode-Yellow.exe', 'ZCode-Green.exe', 'ZCode-Red.exe', 'ZCode-Orange.exe') {
            ($script:Raw -match [regex]::Escape($copy)) | Should -BeTrue
        }
    }
}
