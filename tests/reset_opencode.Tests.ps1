# Pester tests for the OpenCode reset script's pure helpers.
#
# The script carries a dot-source guard: dot-sourcing it defines the helper
# functions and RETURNS before any mutation/elevation path runs, so these
# tests exercise exactly the safety-critical mapping logic (which surfaces a
# target touches, in which order All-mode resets, the marker tables the stop
# step classifies by) without touching any real profile.

Describe 'reset_opencode helpers' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\windows\reset_opencode.ps1')
    }

    Context 'Get-OpenCodeTargetRoots' {

        It 'maps Primary to ai.opencode.desktop + the stock XDG data home' {
            $r = Get-OpenCodeTargetRoots -Label 'Primary'
            $r.Desktop | Should -Be (Join-Path $env:APPDATA 'ai.opencode.desktop')
            $r.Session | Should -Be $r.Desktop
            $r.Xdg | Should -Be (Join-Path $env:USERPROFILE '.local\share\opencode')
        }

        It 'maps clones to their desktop/session/xdg surfaces' {
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $r = Get-OpenCodeTargetRoots -Label $k
                $cloneHome = Join-Path (Join-Path $env:USERPROFILE 'OpenCodeClonesHome') $k
                $r.Desktop | Should -Be (Join-Path $cloneHome 'desktop')
                $r.Session | Should -Be (Join-Path $cloneHome 'session')
                $r.Xdg | Should -Be (Join-Path $cloneHome 'data\opencode')
            }
        }
    }

    Context 'Get-OpenCodeTargetOrder' {

        It 'orders All as clones first, Primary LAST' {
            $order = Get-OpenCodeTargetOrder -Label 'All'
            $order | Should -Be @('c1', 'c2', 'c3', 'c4', 'c5', 'Primary')
            $order[-1] | Should -Be 'Primary'
        }

        It 'passes a single target through' {
            Get-OpenCodeTargetOrder -Label 'c2' | Should -Be @('c2')
            Get-OpenCodeTargetOrder -Label 'Primary' | Should -Be @('Primary')
        }
    }

    Context 'Get-OpenCodeTargetDisplay' {

        It 'uses the color-led display vocabulary with the frozen key in parens' {
            Get-OpenCodeTargetDisplay -Label 'c1' | Should -Be 'Blue (c1)'
            Get-OpenCodeTargetDisplay -Label 'c2' | Should -Be 'Yellow (c2)'
            Get-OpenCodeTargetDisplay -Label 'c3' | Should -Be 'Green (c3)'
            Get-OpenCodeTargetDisplay -Label 'c4' | Should -Be 'Red (c4)'
            Get-OpenCodeTargetDisplay -Label 'c5' | Should -Be 'Orange (c5)'
            Get-OpenCodeTargetDisplay -Label 'Primary' | Should -Be 'Primary'
        }
    }

    Context 'clone markers' {

        It 'matches each clone marker against its own clone-home path only' {
            $cmdlineFor = {
                param($k)
                'OpenCode.exe --opencode-clone-home=C:\Users\X\OpenCodeClonesHome\' + $k
            }
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $cmd = & $cmdlineFor $k
                $hit = $false
                foreach ($m in $script:OpenCodeCloneMarkers[$k]) { if ($cmd -like $m) { $hit = $true } }
                $hit | Should -BeTrue
                foreach ($other in @('c1', 'c2', 'c3', 'c4', 'c5') | Where-Object { $_ -ne $k }) {
                    $otherHit = $false
                    foreach ($m in $script:OpenCodeCloneMarkers[$other]) { if ($cmd -like $m) { $otherHit = $true } }
                    $otherHit | Should -BeFalse
                }
                $primaryHit = $false
                foreach ($m in $script:OpenCodePrimaryMarkers) { if ($cmd -like $m) { $primaryHit = $true } }
                $primaryHit | Should -BeFalse
            }
        }

        It 'matches the Primary marker against the userData dir' {
            $cmd = 'OpenCode.exe --type=renderer --user-data-dir=C:\Users\X\AppData\Roaming\ai.opencode.desktop'
            $hit = $false
            foreach ($m in $script:OpenCodePrimaryMarkers) { if ($cmd -like $m) { $hit = $true } }
            $hit | Should -BeTrue
        }
    }
}
