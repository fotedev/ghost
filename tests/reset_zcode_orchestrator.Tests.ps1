# Run the real Both/All dispatch in Windows PowerShell against inert child
# stubs. Extract only the dispatch and display logic: no profile reads/writes,
# process termination, or elevation code is available in this fixture.
Describe 'ZCode reset orchestrator' {
    BeforeAll {
        $source = Join-Path $PSScriptRoot '..\src\windows\reset_zcode.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $display = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Get-ZcodeTargetDisplay'
        })
        $dispatch = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [System.Management.Automation.Language.IfStatementAst] -and
                $_.Clauses[0].Item1.Extent.Text -match "(?s)'Both'.*'All'"
        })
        $display.Count | Should -Be 1
        $dispatch.Count | Should -Be 1

        # Spaces deliberately exercise the real native -File argument boundary.
        $fixtureDir = Join-Path $TestDrive 'ZCode reset fixture'
        [void][IO.Directory]::CreateDirectory($fixtureDir)
        $fixturePath = Join-Path $fixtureDir 'reset_zcode.ps1'
        $stub = @'
$ErrorActionPreference = 'Stop'
if ($env:GHOST_ZCODE_FIXTURE_CHILD -eq '1') {
    # Reject a missing or wrong -Target without ever re-entering dispatch.
    if ($Target -in @('Both', 'All') -or $DryRun) { throw "Unexpected child arguments: $Target, DryRun=$DryRun" }
    Write-Output ("fixture child: {0} SkipQoder={1}" -f $Target, $SkipQoder.IsPresent)
    if ($env:GHOST_ZCODE_FIXTURE_FAILURE -in @($Target, 'All')) { exit 23 }
    exit 0
}
$env:GHOST_ZCODE_FIXTURE_CHILD = '1'
'@
        $fixture = @(
            $ast.ParamBlock.Extent.Text
            $stub
            $display[0].Extent.Text
            $dispatch[0].Extent.Text
            "throw 'The dispatcher should have exited.'"
        ) -join "`r`n"
        [IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($true))

        function Invoke-ZcodeResetFixture([string]$Target, [switch]$DryRun, [switch]$SkipQoder, [string]$FailTarget = 'None') {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Target {1}' -f $fixturePath, $Target
            if ($DryRun) { $psi.Arguments += ' -DryRun' }
            if ($SkipQoder) { $psi.Arguments += ' -SkipQoder' }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['GHOST_ZCODE_FIXTURE_CHILD'] = '0'
            $psi.EnvironmentVariables['GHOST_ZCODE_FIXTURE_FAILURE'] = $FailTarget
            $proc = [System.Diagnostics.Process]::Start($psi)
            try {
                $stdout = $proc.StandardOutput.ReadToEndAsync()
                $stderr = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit(60000)) {
                    $proc.Kill()
                    throw "ZCode dispatch fixture timed out for $Target"
                }
                [pscustomobject]@{
                    ExitCode = $proc.ExitCode
                    Output = $stdout.GetAwaiter().GetResult()
                    ErrorOutput = $stderr.GetAwaiter().GetResult()
                }
            } finally {
                $proc.Dispose()
            }
        }
    }

    Context '-Target <Mode>' -ForEach @(
        @{ Mode = 'Both'; Targets = @('Secondary', 'Primary') }
        @{ Mode = 'All'; Targets = @('Third', 'Fourth', 'Fifth', 'Sixth', 'Secondary', 'Primary') }
    ) {
        It 'launches each child in order and only includes Qoder with Primary' {
            $result = Invoke-ZcodeResetFixture -Target $Mode
            $result.ErrorOutput | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $actual = ($result.Output -split '\r?\n') -like 'fixture child: *'
            $expected = foreach ($label in $Targets) {
                'fixture child: {0} SkipQoder={1}' -f $label, ($label -ne 'Primary')
            }
            ($actual -join "`n") | Should -BeExactly ($expected -join "`n")
        }

        It 'lists the same targets without launching a child in -DryRun' {
            $result = Invoke-ZcodeResetFixture -Target $Mode -DryRun
            $result.ErrorOutput | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Not -Match 'fixture child:'
            $planned = [regex]::Matches($result.Output, '(?m)^  child reset -Target (\w+)') |
                ForEach-Object { $_.Groups[1].Value }
            ($planned -join ',') | Should -BeExactly ($Targets -join ',')
        }

        It 'honors an explicit -SkipQoder for Primary in the plan and the launch' {
            $plan = Invoke-ZcodeResetFixture -Target $Mode -DryRun -SkipQoder
            $plan.ExitCode | Should -Be 0
            $plan.Output | Should -Not -Match 'incl\. Qoder'
            $result = Invoke-ZcodeResetFixture -Target $Mode -SkipQoder
            $result.ErrorOutput | Should -BeNullOrEmpty
            $result.ExitCode | Should -Be 0
            $result.Output | Should -Match 'fixture child: Primary SkipQoder=True'
            $result.Output | Should -Not -Match 'incl\. Qoder'
        }
    }

    It 'continues after a child failure, reports each exit code, and exits 1' {
        $result = Invoke-ZcodeResetFixture -Target Both -FailTarget Secondary
        $result.ExitCode | Should -Be 1
        $result.Output | Should -Match 'Blue \(Secondary\) exit: 23'
        $result.Output | Should -Match 'Primary exit: 0'
        $result.Output | Should -Match '\[FAILED\]'
    }

    It 'does not claim IDs were generated when every child fails' {
        $result = Invoke-ZcodeResetFixture -Target All -FailTarget All
        $result.ExitCode | Should -Be 1
        [regex]::Matches($result.Output, '(?m) exit: 23\s*$').Count | Should -Be 6
        $result.Output | Should -Not -Match 'IDs were generated'
    }
}
