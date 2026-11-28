# SPDX-License-Identifier: Apache-2.0
# Tests for src/windows/ghost_opencode_service_port.ps1 - the CS-11 per-clone
# service-port seeding (2026-11-28). OpenCode v2.4.2 computes the service port
# default from the app version (win32 remap -> 28894 for 2.4.2) and the service
# REFUSES to start on collision; the seeded <cloneHome>\config\opencode\
# service.json (keys {password, port}, read by `serve --service`) gives every
# clone a distinct port. Functional coverage: the helper is dot-sourced and
# exercised against a real fixture clone home (fresh seed / skip / merge /
# invalid-JSON refusal), plus the frozen-map pins.

Describe 'OpenCode service-port seeding (CS-11)' {
    BeforeAll {
        $script:HelperPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\ghost_opencode_service_port.ps1")).Path
        $script:Raw = [System.IO.File]::ReadAllText($script:HelperPath)
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:HelperPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "ghost_opencode_service_port.ps1 does not parse: $($errors[0].Message)" }
        . $script:HelperPath
    }

    It 'helper is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:HelperPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'dot-sources the shared json_merge_lib (atomic Write-JsonNoBom - never a bare Set-Content)' {
        ($script:Raw -match [regex]::Escape('..\..\tools\json_merge_lib.ps1')) | Should -BeTrue
        ($script:Raw -match 'Write-JsonNoBom') | Should -BeTrue
        $code = $script:Raw -replace '(?s)<#.*?#>', ''
        $code = (($code -split "`r`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        ($code -match 'Set-Content') | Should -BeFalse -Because 'PS 5.1 Set-Content UTF8 emits a BOM and the launcher pin forbids Set-Content on service.json paths'
    }

    It 'carries the frozen map: c1..c5 -> 28901..28905, mutually distinct' {
        $map = $script:GhostOpenCodeServicePorts
        $map.Count | Should -Be 5
        foreach ($pair in @(@('c1', 28901), @('c2', 28902), @('c3', 28903), @('c4', 28904), @('c5', 28905))) {
            $map[$pair[0]] | Should -Be $pair[1]
        }
        ($map.Values | Sort-Object -Unique).Count | Should -Be 5 -Because 'the map only needs mutual distinctness; a duplicate would collide two clones'
        @($map.Keys | Sort-Object) | Should -BeExactly @('c1', 'c2', 'c3', 'c4', 'c5')
    }

    It 'fresh seed: writes the map port atomically (no BOM) and verify-after passes' {
        $h = Join-Path $TestDrive 'fresh'
        $r = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c2
        $r.Status | Should -Be 'seeded'
        $r.Port | Should -Be 28902
        $bytes = [System.IO.File]::ReadAllBytes($r.Path)
        ($bytes[0] -eq 0x7B) | Should -BeTrue -Because 'the written file must start with { (no BOM)'
        $back = Get-Content -LiteralPath $r.Path -Raw | ConvertFrom-Json
        $back.port | Should -Be 28902
    }

    It 'skip: a valid existing port wins (a hand-tuned port is never overwritten)' {
        $h = Join-Path $TestDrive 'skip'
        $null = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c1
        $r = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c1
        $r.Status | Should -Be 'skipped'
        $r.Port | Should -Be 28901
        $r.Note | Should -Match 'already carries a valid port'
    }

    It 'merge: preserves the password and replaces an INVALID port' {
        $h = Join-Path $TestDrive 'merge'
        $dir = Join-Path $h 'config\opencode'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'service.json'
        [System.IO.File]::WriteAllText($p, '{"password":"keepme","port":0}', (New-Object System.Text.UTF8Encoding $false))
        $r = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c3
        $r.Status | Should -Be 'seeded'
        $r.Port | Should -Be 28903
        $back = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $back.password | Should -Be 'keepme' -Because 'the pre-shared service password must survive the seed'
        $back.port | Should -Be 28903
    }

    It 'merge: a password-only file gains the port and keeps the password' {
        $h = Join-Path $TestDrive 'noport'
        $dir = Join-Path $h 'config\opencode'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'service.json'
        [System.IO.File]::WriteAllText($p, '{"password":"keepme"}', (New-Object System.Text.UTF8Encoding $false))
        $r = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c4
        $r.Status | Should -Be 'seeded'
        $r.Port | Should -Be 28904
        $back = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $back.password | Should -Be 'keepme'
        $back.port | Should -Be 28904
    }

    It 'invalid JSON: failed loudly, the broken file is not overwritten blindly' {
        $h = Join-Path $TestDrive 'broken'
        $dir = Join-Path $h 'config\opencode'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'service.json'
        [System.IO.File]::WriteAllText($p, '{ broken', (New-Object System.Text.UTF8Encoding $false))
        $r = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c5
        $r.Status | Should -Be 'failed'
        $r.Note | Should -Match 'not valid JSON'
        (Get-Content -LiteralPath $p -Raw) | Should -Be '{ broken' -Because 'a torn/hand-edited file must not be silently replaced'
    }

    It 'creates a missing config\opencode dir (fresh clone home)' {
        $h = Join-Path $TestDrive 'freshhome'
        $r = Initialize-GhostOpenCodeServicePort -CloneHome $h -Instance c1
        $r.Status | Should -Be 'seeded'
        (Test-Path (Join-Path $h 'config\opencode\service.json')) | Should -BeTrue
    }
}
