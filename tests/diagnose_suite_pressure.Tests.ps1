# SPDX-License-Identifier: Apache-2.0
# Tests for tools/diagnose_suite_pressure.ps1 - the generic per-suite
# instance-pressure report (2026-11-17). Static contract: the tool was
# smoke-tested READ-ONLY against all three suites on the dev host; the
# live behavior needs no further functional tests beyond the wiring pins.

Describe 'Suite pressure report - script hygiene + surface' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\diagnose_suite_pressure.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "diagnose_suite_pressure.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
        $tokens2 = $null; $errors2 = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens2, [ref]$errors2)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It '-Suite is MANDATORY and limited to autoclaw2|cline|opencode (ZCode keeps its dedicated tools)' {
        $suiteParam = $script:Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Suite' }
        $suiteParam | Should -Not -BeNullOrEmpty
        "$($suiteParam.Attributes)" | Should -Match 'autoclaw2'
        "$($suiteParam.Attributes)" | Should -Match 'cline'
        "$($suiteParam.Attributes)" | Should -Match 'opencode'
        "$($suiteParam.Attributes)" | Should -Not -Match 'zcode'
    }

    It 'is fully read-only (no property-store stamp, no SetWindowText, no file writes)' {
        ($script:Raw -match 'SetValue|Commit\(\)') | Should -BeFalse
        ($script:Raw -match 'SetWindowTextW') | Should -BeFalse
        ($script:Raw -match 'WriteAllText|Add-Content|Set-Content') | Should -BeFalse
    }
}

Describe 'Suite pressure report - report contract' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\tools\diagnose_suite_pressure.ps1")).Path)
    }

    It 'sources the [1] table from the SHARED suite-status lib (TA-2 dedup) and injects its own snapshot' {
        ($script:Raw -match [regex]::Escape('. (Join-Path $PSScriptRoot ''suite_status_lib.ps1'')')) | Should -BeTrue
        ($script:Raw -match 'Get-GhostSuiteInstanceState -Suite \$Suite -Procs \$famProcs -Windows \$wins') | Should -BeTrue
        # the honest-labeling vocabulary now lives in the lib; the tool renders its rows
        ($script:Raw -match 'honestly labeled - shared classifier') | Should -BeTrue
        ($script:Raw -match '\$state\.Rows') | Should -BeTrue
    }

    It 'renders the lib row surface incl. the State/Signal/LightWorker columns' {
        ($script:Raw -match '\$_.State') | Should -BeTrue
        ($script:Raw -match '\$_.Signal') | Should -BeTrue
        ($script:Raw -match '\$_.LightWorker') | Should -BeTrue
        ($script:Raw -match 'Instance, Color, State, Signal, Lock, Window, LightWorker, Note') | Should -BeTrue
    }

    It 'keeps only its own section inputs in SuiteDefs (the classification inputs live in the lib)' {
        ($script:Raw -match 'LockProbe') | Should -BeFalse -Because 'lock probes are the lib suite rows now'
        ($script:Raw -match 'TitleMap') | Should -BeFalse
        ($script:Raw -match 'ProcFamily') | Should -BeTrue
        ($script:Raw -match 'LogDirs') | Should -BeTrue
    }

    It 'carries the commit-pressure block incl. the >=90% OOM warning' {
        ($script:Raw -match 'commit pressure is HIGH right now') | Should -BeTrue
        ($script:Raw -match 'renderer-OOM territory') | Should -BeTrue
        ($script:Raw -match 'NONE CONFIGURED') | Should -BeTrue
    }

    It 'scans Electron logs with the client-side .log/.txt filter and a -Depth bound (the .sqlite sweep lesson)' {
        ($script:Raw -match [regex]::Escape('$_.Extension -in ' + "'.log', '.txt'")) | Should -BeTrue
        ($script:Raw -match '-Depth 3') | Should -BeTrue
    }

    It 'skips absent log dirs loudly with provenance labels' {
        ($script:Raw -match 'ABSENT \(skipped loudly') | Should -BeTrue
        ($script:Raw -match 'DERIVED') | Should -BeTrue
    }

    It 'points ZCode at its dedicated tools' {
        ($script:Raw -match 'diagnose_zcode_freeze / diagnose_zcode_throttle') | Should -BeTrue
    }
}

Describe 'GHOST.bat + menu.json wiring for gids 116/117/118' {
    BeforeAll {
        $script:Bat = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\GHOST.bat")).Path)
        $script:Menu = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot "..\src\desktop\menu.json")).Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It 'resolvers map locals to gids 116 (AutoClaw2 24), 117 (Cline 20), 118 (OpenCode 24)' {
        ($script:Bat -match '"24" set "RESOLVED=116"') | Should -BeTrue
        ($script:Bat -match '"20" set "RESOLVED=117"') | Should -BeTrue
        ($script:Bat -match '"24" set "RESOLVED=118"') | Should -BeTrue
    }

    It 'dispatch cases carry the -Suite argument per suite' {
        ($script:Bat -match '"116" \(call :Run "tools\\diagnose_suite_pressure\.ps1" -Suite autoclaw2') | Should -BeTrue
        ($script:Bat -match '"117" \(call :Run "tools\\diagnose_suite_pressure\.ps1" -Suite cline') | Should -BeTrue
        ($script:Bat -match '"118" \(call :Run "tools\\diagnose_suite_pressure\.ps1" -Suite opencode') | Should -BeTrue
    }

    It 'menu rows match the dispatch args per suite' {
        $r116 = @(($script:Menu.sections | Where-Object { $_.name -eq 'AutoClaw2' }).rows) | Where-Object { $_.gid -eq 116 }
        $r117 = @(($script:Menu.sections | Where-Object { $_.name -eq 'Cline' }).rows) | Where-Object { $_.gid -eq 117 }
        $r118 = @(($script:Menu.sections | Where-Object { $_.name -eq 'OpenCode' }).rows) | Where-Object { $_.gid -eq 118 }
        foreach ($r in @($r116, $r117, $r118)) { $r.script | Should -Be 'tools/diagnose_suite_pressure.ps1' }
        ($r116.args -join ' ') | Should -Be '-Suite autoclaw2'
        ($r117.args -join ' ') | Should -Be '-Suite cline'
        ($r118.args -join ' ') | Should -Be '-Suite opencode'
    }
}
