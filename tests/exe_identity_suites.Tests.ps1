# Pester tests for the per-suite Task-Manager exe identity patchers added
# 2026-11-14 (AutoClaw2 / Cline / OpenCode on the generic core).
#
# The three patchers are thin wrappers over tools/exe_identity_lib.ps1 (the
# generic core, live-verified on ZCode). These tests cover each suite's
# instance map (exe names, branding ICO existence, display vocabulary) and
# tripwire the wiring: every patcher must ride the GENERIC lib and pass its
# OWN process family + audit dir - a copy/paste drift to another suite's
# family would corrupt the running gate and the Task Manager names.

Describe 'exe identity suite patchers' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\tools\patch_autoclaw2_exe_identity.ps1')
        . (Join-Path $PSScriptRoot '..\tools\patch_cline_exe_identity.ps1')
        . (Join-Path $PSScriptRoot '..\tools\patch_opencode_exe_identity.ps1')
    }

    Context 'AutoClaw2 map' {

        It 'carries all five clones with color-named exe copies' {
            $map = Get-Ac2InstanceIdentityMap
            $map.Keys.Count | Should -Be 5
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $map[$k].ExeName | Should -Match '^AutoClaw2-(Blue|Yellow|Green|Red|Orange)\.exe$'
            }
            ($map.Values.ExeName | Sort-Object -Unique).Count | Should -Be 5
        }

        It 'every branding dir holds a real tray_icon.ico' {
            foreach ($cfg in (Get-Ac2InstanceIdentityMap).Values) {
                Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..\tools') (Join-Path $cfg.BrandingRepo 'tray_icon.ico')) | Should -BeTrue
            }
        }
    }

    Context 'Cline map' {

        It 'carries all five clones with color-named exe copies' {
            $map = Get-ClineInstanceIdentityMap
            $map.Keys.Count | Should -Be 5
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $map[$k].ExeName | Should -Match '^Cline-(Blue|Yellow|Green|Red|Orange)\.exe$'
            }
            ($map.Values.ExeName | Sort-Object -Unique).Count | Should -Be 5
        }

        It 'every branding dir holds a real tray_icon.ico' {
            foreach ($cfg in (Get-ClineInstanceIdentityMap).Values) {
                Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..\tools') (Join-Path $cfg.BrandingRepo 'tray_icon.ico')) | Should -BeTrue
            }
        }
    }

    Context 'OpenCode map' {

        It 'carries all five clones with color-named exe copies' {
            $map = Get-OpenCodeInstanceIdentityMap
            $map.Keys.Count | Should -Be 5
            foreach ($k in @('c1', 'c2', 'c3', 'c4', 'c5')) {
                $map[$k].ExeName | Should -Match '^OpenCode-(Blue|Yellow|Green|Red|Orange)\.exe$'
            }
            ($map.Values.ExeName | Sort-Object -Unique).Count | Should -Be 5
        }

        It 'every branding dir holds a real tray_icon.ico' {
            foreach ($cfg in (Get-OpenCodeInstanceIdentityMap).Values) {
                Test-Path -LiteralPath (Join-Path (Join-Path $PSScriptRoot '..\tools') (Join-Path $cfg.BrandingRepo 'tray_icon.ico')) | Should -BeTrue
            }
        }
    }

    Context 'wiring tripwires (no cross-suite drift)' {

        It 'every new patcher rides the GENERIC lib, never the zcode shim' {
            foreach ($f in @('patch_autoclaw2_exe_identity.ps1', 'patch_cline_exe_identity.ps1', 'patch_opencode_exe_identity.ps1')) {
                $t = Get-Content (Join-Path (Join-Path $PSScriptRoot '..\tools') $f) -Raw
                $t | Should -Match 'exe_identity_lib\.ps1'
                $t | Should -Not -Match 'zcode_exe_identity_lib'
            }
        }

        It 'the ZCode wrapper still rides the zcode shim (map parity unchanged)' {
            $t = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_zcode_exe_identity.ps1') -Raw
            $t | Should -Match 'zcode_exe_identity_lib\.ps1'
            $t | Should -Match 'Invoke-GhostExeIdentityPatch'
        }

        It 'each forwarder passes its OWN suite process family' {
            $ac2 = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_autoclaw2_exe_identity.ps1') -Raw
            $cl = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_cline_exe_identity.ps1') -Raw
            $oc = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_opencode_exe_identity.ps1') -Raw
            $ac2 | Should -Match "'AutoClaw2\*'"
            $cl | Should -Match "'Cline\*'"
            $oc | Should -Match "'OpenCode\*'"
            $ac2 | Should -Not -Match "'Cline\*'"
            $cl | Should -Not -Match "'AutoClaw2\*'"
            $oc | Should -Not -Match "'AutoClaw2\*'"
        }

        It 'each patcher uses its own audit dir' {
            $ac2 = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_autoclaw2_exe_identity.ps1') -Raw
            $cl = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_cline_exe_identity.ps1') -Raw
            $oc = Get-Content (Join-Path $PSScriptRoot '..\tools\patch_opencode_exe_identity.ps1') -Raw
            $ac2 | Should -Match 'ghost-autoclaw2-exe-identity'
            $cl | Should -Match 'ghost-cline-exe-identity'
            $oc | Should -Match 'ghost-opencode-exe-identity'
        }

        It 'every new patcher carries the repo-only opt-in note (no silent live application)' {
            foreach ($f in @('patch_autoclaw2_exe_identity.ps1', 'patch_cline_exe_identity.ps1', 'patch_opencode_exe_identity.ps1')) {
                $t = Get-Content (Join-Path (Join-Path $PSScriptRoot '..\tools') $f) -Raw
                $t | Should -Match 'repo-only \+ opt-in'
            }
        }
    }
}
