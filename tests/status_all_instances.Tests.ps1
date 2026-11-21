# SPDX-License-Identifier: Apache-2.0
# Tests for tools/status_all_instances.ps1 + its menu wiring - the unified
# cross-suite "who's running" report (2026-11-21, Maintenance [6] / gid 126,
# Terminal Agents [4] / gid 130).

Describe 'All-suites status - script hygiene + surface' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\status_all_instances.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "status_all_instances.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'is fully read-only (no file writes, no registry, no process kill)' {
        ($script:Raw -match 'WriteAllText|Add-Content|Set-Content|Stop-Process|taskkill') | Should -BeFalse
    }

    It 'defaults to every suite and accepts claudecode' {
        ($script:Raw -match "\[ValidateSet\('zcode', 'autoclaw2', 'cline', 'opencode', 'claudecode'\)\]") | Should -BeTrue
        ($script:Raw -match "@\('zcode', 'autoclaw2', 'cline', 'opencode', 'claudecode'\)") | Should -BeTrue
    }

    It 'accepts comma-separated suite lists (the GHOST.bat arg shape)' {
        ($script:Raw -match '\$Suites \| ForEach-Object \{ \$_ -split ' + "','") | Should -BeTrue
    }

    It 'carries the commit-pressure header and the honest-signal footer pointers' {
        ($script:Raw -match 'renderer-OOM territory') | Should -BeTrue
        ($script:Raw -match 'status_zcode_instances') | Should -BeTrue
        ($script:Raw -match 'taskbar watchers') | Should -BeTrue
        ($script:Raw -match 'ghost-light-worker') | Should -BeTrue
    }
}

Describe 'All-suites status - menu wiring (gid 126 Maintenance [6], gid 130 Terminal Agents [4])' {
    BeforeAll {
        $script:Bat = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\GHOST.bat")).Path)
        $script:Menu = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\src\desktop\menu.json") -Raw | ConvertFrom-Json
    }

    It 'GHOST.bat dispatches gid 126 = the fleet tool and gid 130 = the claude-code-scoped view' {
        ($script:Bat -match [regex]::Escape('if "%~1"=="126" (call :Run "tools\status_all_instances.ps1" & exit /b)')) | Should -BeTrue
        ($script:Bat -match [regex]::Escape('if "%~1"=="130" (call :Run "tools\status_all_instances.ps1" -Suites claudecode & exit /b)')) | Should -BeTrue
    }

    It 'Maintenance renders local [6] and TerminalOne resolves it to 126' {
        $maint = [regex]::Match($script:Bat, '(?ms)^:MAINT\r?\n(.*?)^:')
        ($maint.Groups[1].Value -match [regex]::Escape('call :Opt 6 "All-suites instance status"')) | Should -BeTrue
        $resolver = [regex]::Match($script:Bat, '(?ms)^:MaintOne\r?\n(.*?)^:')
        ($resolver.Groups[1].Value -match [regex]::Escape('if "%~1"=="6" set "RESOLVED=126"')) | Should -BeTrue
    }

    It 'Terminal Agents renders [1]-[5] and the resolver maps the locals to their gids' {
        $block = [regex]::Match($script:Bat, '(?ms)^:TERMINAL\r?\n(.*?)^:')
        ($block.Groups[1].Value -match [regex]::Escape('call :Opt 1 "Launch light worker c1"')) | Should -BeTrue
        ($block.Groups[1].Value -match [regex]::Escape('call :Opt 4 "Instance status"')) | Should -BeTrue
        ($block.Groups[1].Value -match [regex]::Escape('call :Opt 5 "Z.ai gateway setup - verify"')) | Should -BeTrue
        $resolver = [regex]::Match($script:Bat, '(?ms)^:TerminalOne\r?\n(.*?)^:')
        foreach ($pair in @(@('1', '127'), @('2', '128'), @('3', '129'), @('4', '130'), @('5', '132'))) {
            ($resolver.Groups[1].Value -match [regex]::Escape('if "%~1"=="' + $pair[0] + '" set "RESOLVED=' + $pair[1] + '"')) | Should -BeTrue
        }
    }

    It 'menu.json carries gid 126 in Maintenance and the Terminal Agents section 127-130+132' {
        $maint = @($Menu.sections | Where-Object { $_.name -eq 'Maintenance' })[0]
        (@($maint.rows | Where-Object { $_.gid -eq 126 })).Count | Should -Be 1
        $ta = @($Menu.sections | Where-Object { $_.name -eq 'Terminal Agents' })[0]
        $ta | Should -Not -BeNullOrEmpty
        (@($ta.rows | ForEach-Object { $_.gid }) -join ',') | Should -Be '127,128,129,130,132'
        (@($ta.rows | Where-Object { $_.mode -eq 'confirm-run' })).Count | Should -Be 1 -Because 'the reset row must ask first'
    }

    It 'GHOST.bat dispatches gid 132 = the launcher -Gateway mode (the Z.ai gateway row)' {
        ($script:Bat -match [regex]::Escape('if "%~1"=="132" (call :Run "src\windows\launch_claude_code_light.ps1" -Gateway & exit /b)')) | Should -BeTrue
    }
}
