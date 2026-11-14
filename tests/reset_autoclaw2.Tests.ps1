# Pester tests for the AutoClaw2 reset script's pure helpers.
#
# The script carries a dot-source guard: dot-sourcing it defines the helper
# functions and RETURNS before any mutation/elevation path runs, so these
# tests exercise exactly the safety-critical mapping logic (which profile
# roots a target touches, in which order All-mode resets, what the
# device-id.json contract looks like) without touching any real profile.

Describe 'reset_autoclaw2 helpers' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\windows\reset_autoclaw2.ps1')
    }

    Context 'Get-Ac2TargetRoots' {

        It 'maps Primary to the roaming AutoClaw-oversea-official profile' {
            $root = Get-Ac2TargetRoots -Label 'Primary'
            $root | Should -Be (Join-Path $env:APPDATA 'AutoClaw-oversea-official')
        }

        It 'maps c1..c5 under AutoClaw2ClonesHome' {
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $root = Get-Ac2TargetRoots -Label $k
                $root | Should -Be (Join-Path (Join-Path $env:USERPROFILE 'AutoClaw2ClonesHome') $k)
            }
        }

        It 'produces five distinct clone roots' {
            $roots = @('c1', 'c2', 'c3', 'c4', 'c5') | ForEach-Object { Get-Ac2TargetRoots -Label $_ }
            ($roots | Sort-Object -Unique).Count | Should -Be 5
        }
    }

    Context 'Get-Ac2TargetOrder' {

        It 'orders All as clones first, Primary LAST' {
            $order = Get-Ac2TargetOrder -Label 'All'
            $order | Should -Be @('c1', 'c2', 'c3', 'c4', 'c5', 'Primary')
            $order[-1] | Should -Be 'Primary'
        }

        It 'passes a single target through' {
            Get-Ac2TargetOrder -Label 'c3' | Should -Be @('c3')
            Get-Ac2TargetOrder -Label 'Primary' | Should -Be @('Primary')
        }
    }

    Context 'Get-Ac2TargetDisplay' {

        It 'uses the color-led display vocabulary with the frozen key in parens' {
            Get-Ac2TargetDisplay -Label 'c1' | Should -Be 'Blue (c1)'
            Get-Ac2TargetDisplay -Label 'c2' | Should -Be 'Yellow (c2)'
            Get-Ac2TargetDisplay -Label 'c3' | Should -Be 'Green (c3)'
            Get-Ac2TargetDisplay -Label 'c4' | Should -Be 'Red (c4)'
            Get-Ac2TargetDisplay -Label 'c5' | Should -Be 'Orange (c5)'
            Get-Ac2TargetDisplay -Label 'Primary' | Should -Be 'Primary'
        }
    }

    Context 'Test-DeviceIdShape' {

        It 'accepts the exact live shape {"schemaVersion":1,"deviceId":"<uuid>"}' {
            $json = [pscustomobject]@{ schemaVersion = 1; deviceId = 'df051f9d-909d-4dff-87df-6051f452110f' }
            Test-DeviceIdShape $json | Should -BeTrue
        }

        It 'rejects a wrong schemaVersion, missing/empty deviceId and null' {
            Test-DeviceIdShape ([pscustomobject]@{ schemaVersion = 2; deviceId = 'x' }) | Should -BeFalse
            Test-DeviceIdShape ([pscustomobject]@{ schemaVersion = 1 }) | Should -BeFalse
            Test-DeviceIdShape ([pscustomobject]@{ schemaVersion = 1; deviceId = '' }) | Should -BeFalse
            Test-DeviceIdShape ([pscustomobject]@{ schemaVersion = 1; deviceId = '  ' }) | Should -BeFalse
            Test-DeviceIdShape $null | Should -BeFalse
        }
    }

    Context 'clone markers' {

        It 'matches each clone marker against its own profile dir path only' {
            $cmdlineFor = {
                param($k)
                'C:\...\AutoClaw2.exe" --type=renderer --user-data-dir="C:\Users\X\AutoClaw2ClonesHome\' + $k + '"'
            }
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $cmd = & $cmdlineFor $k
                # own marker matches
                $hit = $false
                foreach ($m in $script:Ac2CloneMarkers[$k]) { if ($cmd -like $m) { $hit = $true } }
                $hit | Should -BeTrue
                # every OTHER clone marker must not match
                foreach ($other in @('c1', 'c2', 'c3', 'c4', 'c5') | Where-Object { $_ -ne $k }) {
                    $otherHit = $false
                    foreach ($m in $script:Ac2CloneMarkers[$other]) { if ($cmd -like $m) { $otherHit = $true } }
                    $otherHit | Should -BeFalse
                }
                # the Primary marker must not match a clone subtree
                $primaryHit = $false
                foreach ($m in $script:Ac2PrimaryMarkers) { if ($cmd -like $m) { $primaryHit = $true } }
                $primaryHit | Should -BeFalse
            }
        }

        It 'matches the Primary marker against the roaming profile dir' {
            $cmd = 'C:\...\AutoClaw2.exe" --type=renderer --user-data-dir="C:\Users\X\AppData\Roaming\AutoClaw-oversea-official"'
            $hit = $false
            foreach ($m in $script:Ac2PrimaryMarkers) { if ($cmd -like $m) { $hit = $true } }
            $hit | Should -BeTrue
        }
    }
}

Describe 'subtree-walk tripwire (repo-wide)' {

    # 2026-11-14: an array-slice "pop" ($stack = $stack[1..($stack.Count-1)])
    # does NOT shrink a 1-element array in PowerShell - @('A')[1..0] == @('A')
    # (out-of-range indices clamp) - so a slice-based subtree walk SPINS
    # FOREVER on leaf nodes while its seen-map makes the spin invisible.
    # Caught live by the very first run of tools/status_zcode_instances.ps1
    # with real ZCode processes running; the same latent pattern was sitting
    # in the three new reset scripts' stop steps (a real reset with a running
    # instance would have hung forever). All walks now use Queue semantics
    # (Dequeue REMOVES). This tripwire forbids the pattern from ever
    # returning.
    It 'no subtree walk uses the 1..Count-1 slice-pop pattern' {
        $offenders = @()
        foreach ($dir in @('src\windows', 'tools')) {
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot ('..\' + $dir)) -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
                $t = Get-Content -LiteralPath $f.FullName -Raw
                if ($t -match '\$\w+\s*=\s*\$\w+\[1\.\.\(\$\w+\.Count\s*-\s*1\)\]') {
                    $offenders += $f.Name
                }
            }
        }
        $offenders | Should -BeNullOrEmpty -Because ('slice-pop walks hang forever on leaf nodes; offenders: ' + ($offenders -join ', '))
    }
}
