# Pester tests for the Cline reset script's pure helpers.
#
# The script carries a dot-source guard: dot-sourcing it defines the helper
# functions and RETURNS before any mutation/elevation path runs, so these
# tests exercise exactly the safety-critical mapping logic (which state trees
# a target touches, which webview profile belongs to it, in which order
# All-mode resets, the marker tables the stop step classifies by) without
# touching any real profile.

Describe 'reset_cline helpers' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\windows\reset_cline.ps1')
    }

    Context 'Get-ClineTargetRoot' {

        It 'maps Primary to ~\.cline' {
            Get-ClineTargetRoot -Label 'Primary' | Should -Be (Join-Path $env:USERPROFILE '.cline')
        }

        It 'maps c1..c5 under ClineClonesHome' {
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                Get-ClineTargetRoot -Label $k | Should -Be (Join-Path (Join-Path $env:USERPROFILE 'ClineClonesHome') $k)
            }
        }

        It 'produces five distinct clone roots' {
            $roots = @('c1', 'c2', 'c3', 'c4', 'c5') | ForEach-Object { Get-ClineTargetRoot -Label $_ }
            ($roots | Sort-Object -Unique).Count | Should -Be 5
        }
    }

    Context 'Get-ClineWebviewRoot' {

        It 'maps the Primary webview to the stock %LOCALAPPDATA%\bot.cline.app profile' {
            Get-ClineWebviewRoot -Label 'Primary' | Should -Be (Join-Path $env:LOCALAPPDATA 'bot.cline.app')
        }

        It 'maps clone webviews into the clone home (per-clone WEBVIEW2_USER_DATA_FOLDER)' {
            Get-ClineWebviewRoot -Label 'c3' | Should -Be (Join-Path (Join-Path $env:USERPROFILE 'ClineClonesHome') 'c3\webview')
        }
    }

    Context 'Get-ClineTargetOrder' {

        It 'orders All as clones first, Primary LAST' {
            $order = Get-ClineTargetOrder -Label 'All'
            $order | Should -Be @('c1', 'c2', 'c3', 'c4', 'c5', 'Primary')
            $order[-1] | Should -Be 'Primary'
        }

        It 'passes a single target through' {
            Get-ClineTargetOrder -Label 'c4' | Should -Be @('c4')
            Get-ClineTargetOrder -Label 'Primary' | Should -Be @('Primary')
        }
    }

    Context 'Get-ClineTargetDisplay' {

        It 'uses the color-led display vocabulary with the frozen key in parens' {
            Get-ClineTargetDisplay -Label 'c1' | Should -Be 'Blue (c1)'
            Get-ClineTargetDisplay -Label 'c2' | Should -Be 'Yellow (c2)'
            Get-ClineTargetDisplay -Label 'c3' | Should -Be 'Green (c3)'
            Get-ClineTargetDisplay -Label 'c4' | Should -Be 'Red (c4)'
            Get-ClineTargetDisplay -Label 'c5' | Should -Be 'Orange (c5)'
            Get-ClineTargetDisplay -Label 'Primary' | Should -Be 'Primary'
        }
    }

    Context 'port plan' {

        It 'carries the exact per-clone port table (disjoint from the stock 25463..25466 / 3126)' {
            $script:ClinePortPlan['c1'] | Should -Be @(25471, 3131)
            $script:ClinePortPlan['c2'] | Should -Be @(25472, 3132)
            $script:ClinePortPlan['c3'] | Should -Be @(25473, 3133)
            $script:ClinePortPlan['c4'] | Should -Be @(25474, 3134)
            $script:ClinePortPlan['c5'] | Should -Be @(25475, 3135)
        }
    }

    Context 'clone markers' {

        It 'matches each clone marker against its own state-tree path only' {
            $cmdlineFor = {
                param($k)
                'node.exe C:\Users\X\ClineClonesHome\' + $k + '\data\hub\hub.js --port 25471'
            }
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $cmd = & $cmdlineFor $k
                $hit = $false
                foreach ($m in $script:ClineCloneMarkers[$k]) { if ($cmd -like $m) { $hit = $true } }
                $hit | Should -BeTrue
                foreach ($other in @('c1', 'c2', 'c3', 'c4', 'c5') | Where-Object { $_ -ne $k }) {
                    $otherHit = $false
                    foreach ($m in $script:ClineCloneMarkers[$other]) { if ($cmd -like $m) { $otherHit = $true } }
                    $otherHit | Should -BeFalse
                }
            }
        }

        It 'matches the Primary marker against the stock state-tree path' {
            $cmd = 'node.exe C:\Users\X\.cline\data\hub\hub.js --port 25463'
            $hit = $false
            foreach ($m in $script:ClinePrimaryMarkers) { if ($cmd -like $m) { $hit = $true } }
            $hit | Should -BeTrue
        }
    }
}
