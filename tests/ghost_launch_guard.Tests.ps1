# Pester tests for the shared 3-way launch guard (ghost_launch_guard.ps1).
#
# The dialog/Read-Host routing is proven with Pester mocks - the real hidden
# console path pops a topmost MessageBox, so the resident tests only ever
# exercise the mocked branches plus the NonInteractive/-NeverAsk warn+continue
# contract (the watchdog/harness must never hang - 2026-11-01 lesson).

Describe 'ghost_launch_guard' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\windows\ghost_launch_guard.ps1')
    }

    Context 'Get-GhostSuiteMainIds (EC-K01 bare-exe rule)' {

        It 'counts bare-exe mains and empty-cmdline candidates, never helpers' {
            Mock Get-CimInstance {
                @(
                    # bare main (quoted path, no args)
                    [pscustomobject]@{ ProcessId = 100; Name = 'AutoClaw2.exe'; CommandLine = '"C:\Program Files\AutoClaw2\AutoClaw2.exe"' }
                    # bare main (unquoted, no args)
                    [pscustomobject]@{ ProcessId = 101; Name = 'AutoClaw2.exe'; CommandLine = 'C:\Program Files\AutoClaw2\AutoClaw2.exe' }
                    # renderer helper (--type=) - must NOT count
                    [pscustomobject]@{ ProcessId = 102; Name = 'AutoClaw2.exe'; CommandLine = '"C:\...\AutoClaw2.exe" --type=renderer --user-data-dir="X"' }
                    # node sidecar (extra args) - must NOT count
                    [pscustomobject]@{ ProcessId = 103; Name = 'node.exe'; CommandLine = 'node.exe C:\hub\hub.js --port 1' }
                    # empty CommandLine = WMI race on a fresh main - counts as candidate
                    [pscustomobject]@{ ProcessId = 104; Name = 'AutoClaw2.exe'; CommandLine = '' }
                )
            }
            $ids = Get-GhostSuiteMainIds -WmiFamilyFilter "Name LIKE 'AutoClaw2%'"
            ($ids | Sort-Object) | Should -Be @(100, 101, 104)
        }
    }

    Context 'Get-GhostSuiteCommitMb' {

        It 'sums the family commit and treats a missing family as zero' {
            Mock Get-Process {
                @(
                    [pscustomobject]@{ PrivateMemorySize64 = 100MB },
                    [pscustomobject]@{ PrivateMemorySize64 = 200MB }
                )
            }
            Get-GhostSuiteCommitMb -ProcessFamily 'ZCode*' | Should -Be 300
            Mock Get-Process { @() }
            Get-GhostSuiteCommitMb -ProcessFamily 'Nothing*' | Should -Be 0
        }
    }

    Context 'Invoke-GhostLaunchGuard routing' {

        It 'continues without asking for -NonInteractive (watchdog contract)' {
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'ZCode' `
                -WmiFamilyFilter "Name LIKE 'ZCode%'" -ProcessFamily 'ZCode*' `
                -RiskLine 'risk' -NonInteractive
            $out | Should -BeTrue
        }

        It 'continues without asking for -NeverAsk' {
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'AutoClaw2' `
                -WmiFamilyFilter "Name LIKE 'AutoClaw2%'" -ProcessFamily 'AutoClaw2*' `
                -RiskLine 'risk' -NeverAsk
            $out | Should -BeTrue
        }

        It 'redirected stdin warns and continues even without -NonInteractive' {
            Mock Get-GhostStdinRedirected { $true }
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'Cline' `
                -WmiFamilyFilter "Name LIKE 'Cline%'" -ProcessFamily 'Cline*' -RiskLine 'risk'
            $out | Should -BeTrue
        }

        It 'visible console + n answer cancels (y/N default)' {
            Mock Get-GhostStdinRedirected { $false }
            Mock Test-GhostConsoleVisible { $true }
            Mock Read-Host { 'n' }
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'Cline' `
                -WmiFamilyFilter "Name LIKE 'Cline%'" -ProcessFamily 'Cline*' -RiskLine 'risk'
            $out | Should -BeFalse
            Should -Invoke Read-Host -Times 1 -Exactly
        }

        It 'visible console + y answer proceeds' {
            Mock Get-GhostStdinRedirected { $false }
            Mock Test-GhostConsoleVisible { $true }
            Mock Read-Host { 'y' }
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'Cline' `
                -WmiFamilyFilter "Name LIKE 'Cline%'" -ProcessFamily 'Cline*' -RiskLine 'risk'
            $out | Should -BeTrue
        }

        It 'hidden console routes to the dialog; No cancels like the y/N default' {
            Mock Get-GhostStdinRedirected { $false }
            Mock Test-GhostConsoleVisible { $false }
            Mock Show-GhostLaunchGuardDialog { $false }
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'OpenCode' `
                -WmiFamilyFilter "Name LIKE 'OpenCode%'" -ProcessFamily 'OpenCode*' -RiskLine 'risk'
            $out | Should -BeFalse
            Should -Invoke Show-GhostLaunchGuardDialog -Times 1 -Exactly
        }

        It 'hidden console dialog Yes proceeds' {
            Mock Get-GhostStdinRedirected { $false }
            Mock Test-GhostConsoleVisible { $false }
            Mock Show-GhostLaunchGuardDialog { $true }
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'OpenCode' `
                -WmiFamilyFilter "Name LIKE 'OpenCode%'" -ProcessFamily 'OpenCode*' -RiskLine 'risk'
            $out | Should -BeTrue
        }

        It 'carries the suite name into the dialog title' {
            Mock Get-GhostStdinRedirected { $false }
            Mock Test-GhostConsoleVisible { $false }
            Mock Show-GhostLaunchGuardDialog { $true } -ParameterFilter { $Title -eq 'GHOST - ZCode RAM guard' }
            $out = Invoke-GhostLaunchGuard -RunningMains 4 -MaxConcurrent 3 -SuiteName 'ZCode' `
                -WmiFamilyFilter "Name LIKE 'ZCode%'" -ProcessFamily 'ZCode*' -RiskLine 'risk'
            $out | Should -BeTrue
            Should -Invoke Show-GhostLaunchGuardDialog -Times 1 -Exactly -ParameterFilter { $Title -eq 'GHOST - ZCode RAM guard' }
        }
    }

    Context 'Test-GhostConsoleVisible' {

        It 'returns a boolean without throwing in any console state' {
            Test-GhostConsoleVisible | Should -BeOfType [bool]
        }
    }
}
