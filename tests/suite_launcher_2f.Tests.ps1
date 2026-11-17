# SPDX-License-Identifier: Apache-2.0
# Tests for the launcher 2f exe-identity wiring (2026-11-17; the ZCode
# step-2f pattern ported to the AutoClaw2/Cline/OpenCode launchers - the
# 2026-11-14 repo-only opt-in decision REVERSED by the parity build-out
# plan) + the per-suite dry-run reset plan rows (gids 119/120/121).

Describe 'Launcher 2f exe-identity wiring' {
    BeforeAll {
        $script:Launchers = @(
            @{ File = 'launch_autoclaw2_clone.ps1'; Tool = 'patch_autoclaw2_exe_identity.ps1'; Copy = 'AutoClaw2-$ExeColorCap.exe'; Stock = 'AutoClaw2.exe' }
            @{ File = 'launch_cline_clone.ps1';     Tool = 'patch_cline_exe_identity.ps1';     Copy = 'Cline-$ExeColorCap.exe';     Stock = 'cline-app.exe' }
            @{ File = 'launch_opencode_clone.ps1';  Tool = 'patch_opencode_exe_identity.ps1';  Copy = 'OpenCode-$ExeColorCap.exe';  Stock = 'OpenCode.exe' }
        )
        $script:Asts = @{}
        foreach ($l in $script:Launchers) {
            $p = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\$($l.File)")).Path
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw "$($l.File) does not parse: $($errors[0].Message)" }
            $script:Asts[$l.File] = @{ Ast = $ast; Raw = [System.IO.File]::ReadAllText($p) }
        }
    }

    It 'each launcher runs its suite patcher with -Target <instance> + -InstallDir' {
        foreach ($l in $script:Launchers) {
            $raw = $script:Asts[$l.File].Raw
            ($raw -match [regex]::Escape($l.Tool)) | Should -BeTrue -Because $l.File
            ($raw -match '-Target \$Instance -InstallDir \(Split-Path -Parent \$ExePath\)') | Should -BeTrue -Because $l.File
        }
    }

    It 'each launcher falls back to the STOCK exe on any 2f failure (never blocks the launch)' {
        foreach ($l in $script:Launchers) {
            $raw = $script:Asts[$l.File].Raw
            ($raw -match '\$LaunchExe = \$ExePath') | Should -BeTrue -Because $l.File
            ($raw -match 'exe copy unavailable \(tool exit') | Should -BeTrue -Because $l.File
        }
    }

    It 'each launcher launches from $LaunchExe, not the stock $ExePath' {
        foreach ($l in $script:Launchers) {
            $raw = $script:Asts[$l.File].Raw
            ($raw -match 'Start-Process -FilePath \$LaunchExe') | Should -BeTrue -Because $l.File
            ($raw -match 'Start-Process -FilePath \$ExePath ') | Should -BeFalse -Because "the stock-exe direct launch must be gone in $($l.File)"
        }
    }

    It 'copy names follow the <App>-<Color>.exe convention' {
        foreach ($l in $script:Launchers) {
            ($script:Asts[$l.File].Raw -match [regex]::Escape($l.Copy)) | Should -BeTrue -Because $l.File
        }
    }

    It 'the 2f step runs BEFORE the launch in each launcher' {
        foreach ($l in $script:Launchers) {
            $raw = $script:Asts[$l.File].Raw
            $idx2f = $raw.IndexOf('Task Manager identity - per-color exe copy')
            $idxLaunch = $raw.IndexOf('Start-Process -FilePath $LaunchExe')
            $idx2f | Should -BeGreaterThan 0
            $idxLaunch | Should -BeGreaterThan $idx2f
        }
    }
}

Describe 'GHOST.bat + menu.json wiring for the dry-run plan rows (gids 119/120/121)' {
    BeforeAll {
        $script:Bat = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\GHOST.bat")).Path)
        $script:Menu = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot "..\src\desktop\menu.json")).Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It 'resolvers map locals 25/21/25 to gids 119/120/121' {
        ($script:Bat -match '"25" set "RESOLVED=119"') | Should -BeTrue
        ($script:Bat -match '"21" set "RESOLVED=120"') | Should -BeTrue
        ($script:Bat -match '"25" set "RESOLVED=121"') | Should -BeTrue
    }

    It 'dispatch cases run the resetters with -Target All -DryRun' {
        ($script:Bat -match '"119" \(call :Run "src\\windows\\reset_autoclaw2\.ps1" -Target All -DryRun') | Should -BeTrue
        ($script:Bat -match '"120" \(call :Run "src\\windows\\reset_cline\.ps1" -Target All -DryRun') | Should -BeTrue
        ($script:Bat -match '"121" \(call :Run "src\\windows\\reset_opencode\.ps1" -Target All -DryRun') | Should -BeTrue
    }

    It 'menu rows match the dispatch args' {
        $r119 = @(($script:Menu.sections | Where-Object { $_.name -eq 'AutoClaw2' }).rows) | Where-Object { $_.gid -eq 119 }
        $r120 = @(($script:Menu.sections | Where-Object { $_.name -eq 'Cline' }).rows) | Where-Object { $_.gid -eq 120 }
        $r121 = @(($script:Menu.sections | Where-Object { $_.name -eq 'OpenCode' }).rows) | Where-Object { $_.gid -eq 121 }
        ($r119.args -join ' ') | Should -Be '-Target All -DryRun'
        ($r120.args -join ' ') | Should -Be '-Target All -DryRun'
        ($r121.args -join ' ') | Should -Be '-Target All -DryRun'
    }

    It 'the dry-run rows render in all three submenus' {
        ($script:Bat -match 'Opt 25 "Dry-run reset plan"') | Should -BeTrue
        ($script:Bat -match 'Opt 21 "Dry-run reset plan"') | Should -BeTrue
    }
}
