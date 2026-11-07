# SPDX-License-Identifier: Apache-2.0
# Tests for src/windows/launch_opencode_cli_light.ps1 - the OpenCode
# headless/light worker launcher (ZCode LIGHT pattern; CLI surface and XDG
# isolation live-verified 2026-11-07 on a scratch env, opencode-cli v2.2.5).
# Static structure (param surface, instance map, env levers, verify helper)
# is extracted via the PowerShell AST so the driver body never executes.
# The fail-fast guard is exercised FUNCTIONALLY in a child powershell whose
# LOCALAPPDATA/USERPROFILE are poisoned to an empty temp dir: no CLI
# candidate can exist, so the launcher must throw loudly and touch nothing.

Describe 'OpenCode light launcher - script hygiene' {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_opencode_cli_light.ps1")).Path
        $tokens = $null; $errors = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_opencode_cli_light.ps1 does not parse: $($errors[0].Message)" }
    }

    It 'declares #Requires -Version 5.1' {
        (Get-Content -LiteralPath $script:ScriptPath -TotalCount 1) -match '#Requires -Version 5.1' | Should -BeTrue
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptPath)
        ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        ($text -match "`r`n") | Should -BeTrue
        ($text -match "(?<!`r)`n") | Should -BeFalse -Because "bare LF must not survive the CRLF normalization"
    }
}

Describe 'OpenCode light launcher - instance map' {
    BeforeAll {
        $assign = $script:ScriptAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$InstanceMap' }, $true)
        $assign.Count | Should -Be 1 -Because "the instance map must exist exactly once"
        Invoke-Expression ('$script:Map = ' + $assign[0].Right.Extent.Text)
    }

    It 'maps exactly c1..c5' {
        @($script:Map.Keys | Sort-Object) | Should -Be @('c1', 'c2', 'c3', 'c4', 'c5')
    }

    It 'home dirs are OpenCodeClonesHome\cN (FROZEN plumbing - never renamed)' {
        foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
            $script:Map[$k].Home | Should -Be ("OpenCodeClonesHome\" + $k)
        }
    }

    It 'carries the color display vocabulary in suite order' {
        @($script:Map['c1'].Color, $script:Map['c2'].Color, $script:Map['c3'].Color, $script:Map['c4'].Color, $script:Map['c5'].Color) |
            Should -Be @('Blue', 'Yellow', 'Green', 'Red', 'Orange')
    }
}

Describe 'OpenCode light launcher - param surface' {
    BeforeAll {
        $script:Pb = $script:ScriptAst.ParamBlock
        $script:ParamNames = @($script:Pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    It 'exposes the five modes + passthrough levers' {
        foreach ($p in @('Instance', 'Prompt', 'Model', 'Cwd', 'Port', 'Server', 'Acp', 'Auto', 'Standalone', 'Json', 'Login', 'StopService', 'NoLoginWarn')) {
            $script:ParamNames | Should -Contain $p
        }
    }

    It 'restricts -Instance to the frozen clone keys c1..c5' {
        $inst = $script:Pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Instance' }
        $set = $inst.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
        $set | Should -Not -BeNullOrEmpty
        @($set.PositionalArguments | ForEach-Object { $_.Value }) | Should -Be @('c1', 'c2', 'c3', 'c4', 'c5')
    }
}

Describe 'OpenCode light launcher - env levers (spike-verified mechanism)' {
    It 'sets the four XDG levers and redirects nothing else' {
        $text = [System.IO.File]::ReadAllText($script:ScriptPath)
        foreach ($v in @('XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_STATE_HOME')) {
            ($text -match ("\`$env:{0}\s*=" -f $v)) | Should -BeTrue -Because "$v is one of the four verified levers"
        }
        ($text -match '\$env:HOME\s*=') | Should -BeFalse -Because "debug paths verified `home` stays the real profile - HOME must NOT be redirected"
        ($text -match '\$env:USERPROFILE\s*=') | Should -BeFalse -Because "USERPROFILE is only read here, never redirected"
    }

    It 'invokes only spike-verified subcommands' {
        $text = [System.IO.File]::ReadAllText($script:ScriptPath)
        foreach ($frag in @("'run'", "'serve'", "'acp'", 'service stop', 'service status', 'auth login', '--auto', '--standalone', "'--format', 'json'")) {
            ($text -match [regex]::Escape($frag)) | Should -BeTrue -Because "$frag must be reachable"
        }
    }

    It 'propagates -Cwd via $env:PWD (the CLI resolves its project from PWD, not the process CWD)' {
        # Live-verified 2026-11-07: PowerShell children inherit a STALE PWD
        # from the parent shell; opencode-cli run read $env:PWD and bound
        # every turn to the launcher's own launch dir project (sessions
        # recorded the repo dir) while the banner printed the requested
        # -Cwd. With $env:PWD=$Cwd the session recorded -Cwd (proven on a
        # scratch dir). CurrentDirectory is kept as belt-and-braces.
        $text = [System.IO.File]::ReadAllText($script:ScriptPath)
        ($text -match '\$env:PWD\s*=\s*\$Cwd') | Should -BeTrue
        ($text -match '\[Environment\]::CurrentDirectory\s*=\s*\$Cwd') | Should -BeTrue
    }

    It 'never captures Invoke-LightRun output (assignment would swallow the CLI stdout)' {
        # Live-verified 2026-11-07: "$ok = Invoke-LightRun" captured the
        # CLI's entire stdout into the variable (turn succeeded, answer in
        # the store, stdout empty). Both call sites must be bare statements.
        # Comment lines are stripped first - the function itself documents
        # the anti-pattern in prose.
        $code = (Get-Content -LiteralPath $script:ScriptPath | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        ($code -match '\$\w+ = Invoke-LightRun') | Should -BeFalse
        ($code -match '\$null = Invoke-LightRun') | Should -BeFalse
    }
}

Describe 'OpenCode light launcher - Test-CloneLoggedIn verify primitive' {
    BeforeAll {
        $fn = $script:ScriptAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Test-CloneLoggedIn' }, $true)
        $fn.Count | Should -Be 1 -Because "the auth verify helper must exist exactly once"
        Invoke-Expression $fn[0].Extent.Text
        $script:FixtureDir = Join-Path ([System.IO.Path]::GetTempPath()) ("oc-light-tests-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FixtureDir | Out-Null
    }
    AfterAll {
        if (Test-Path -LiteralPath $script:FixtureDir) { Remove-Item -LiteralPath $script:FixtureDir -Recurse -Force }
    }

    It 'reports NOT logged in when auth.json is missing' {
        $AuthJsonPath = Join-Path $script:FixtureDir 'missing.json'
        Test-CloneLoggedIn | Should -BeFalse
    }

    It 'reports NOT logged in for empty and literal-{} stores (reset script writes {} as the wiped state)' {
        $AuthJsonPath = Join-Path $script:FixtureDir 'empty.json'
        Set-Content -LiteralPath $AuthJsonPath -Value '' -NoNewline
        Test-CloneLoggedIn | Should -BeFalse
        $AuthJsonPath = Join-Path $script:FixtureDir 'braces.json'
        Set-Content -LiteralPath $AuthJsonPath -Value ' {} ' -NoNewline
        Test-CloneLoggedIn | Should -BeFalse
    }

    It 'reports logged in once real credentials landed' {
        $AuthJsonPath = Join-Path $script:FixtureDir 'auth.json'
        Set-Content -LiteralPath $AuthJsonPath -Value '{"example":{"type":"api","key":"k"}}' -NoNewline
        Test-CloneLoggedIn | Should -BeTrue
    }
}

Describe 'OpenCode light launcher - fail-fast guard (functional child)' {
    It 'throws loudly when no CLI candidate exists (poisoned LOCALAPPDATA/USERPROFILE) and touches nothing' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oc-light-guard-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi.Arguments = ("-NoProfile -ExecutionPolicy Bypass -File `"{0}`"" -f $script:ScriptPath)
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['LOCALAPPDATA'] = $tmp
            $psi.EnvironmentVariables['USERPROFILE'] = $tmp
            $p = [System.Diagnostics.Process]::Start($psi)
            $out = $p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()
            $p.WaitForExit()
            $p.ExitCode | Should -Be 1 -Because "an uncaught fail-fast throw exits 1"
            $out | Should -Match 'opencode-cli\.exe not found or non-functional'
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        }
    }
}
