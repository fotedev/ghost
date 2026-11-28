# SPDX-License-Identifier: Apache-2.0
# Tests for tools/patch_opencode_clone_home.mjs + .ps1 - the engine v5
# SERVICE-REGISTRY SCOPING family (CS-10 tail, 2026-11-28). OpenCode v2.3.2's
# spawned CLI service child self-registers service.json under whatever
# XDG_STATE_HOME the child's env carried at process start; the app's win32
# desktop-init deleter (`delete process.env.XDG_STATE_HOME`, byte-verified ONE
# site in the whole asar) strips that lever after the patched clone-home branch
# set it, so the child registered at the MACHINE-DEFAULT registry and a later
# Primary launch would JOIN the clone's daemon (last-writer-wins mirror break).
# Engine v5 guards the deleter with the patch's own global
# (`globalThis.__opencodeCloneHome||`) - clones keep their state home and
# register clone-locally; the Primary keeps stock behavior. Static pins only:
# the engine is an argv-driven script, not a module - the splice itself is
# proven by the in-engine node --check gate + the live verification recorded in
# docs/OPENCODE_CLONES_SPEC.md 3.8.1.

Describe 'OpenCode clone-home patch engine - v5 service-registry contract' {
    BeforeAll {
        $script:MjsPath = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\patch_opencode_clone_home.mjs")).Path
        $script:Ps1Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\patch_opencode_clone_home.ps1")).Path
        $script:Mjs = [System.IO.File]::ReadAllText($script:MjsPath)
        $script:Ps1Raw = [System.IO.File]::ReadAllText($script:Ps1Path)
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Ps1Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "patch_opencode_clone_home.ps1 does not parse: $($errors[0].Message)" }
    }

    It 'ps1 is CRLF-clean (repo eol=crlf rule for tracked .ps1)' {
        ($script:Ps1Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'this test file itself is CRLF + UTF-8 BOM' {
        $selfBytes = [System.IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'opencode_clone_patch.Tests.ps1'))
        ($selfBytes[0] -eq 0xEF -and $selfBytes[1] -eq 0xBB -and $selfBytes[2] -eq 0xBF) | Should -BeTrue
    }

    It 'declares engine v5 in BOTH the .mjs and the .ps1 driver' {
        ($script:Mjs -match 'const ENGINE_VERSION = 5;') | Should -BeTrue
        ($script:Ps1Raw -match '\$script:EngineVersion = 5') | Should -BeTrue
    }

    It 'the .mjs is syntactically valid (node --check, when node is on PATH)' {
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) { Set-ItResult -Skipped -Because 'node is not on PATH'; return }
        $null = & $node.Source --check $script:MjsPath 2>&1
        ($LASTEXITCODE -eq 0) | Should -BeTrue
    }

    It 'the service-registry family is registered with the exact pristine anchor + guarded replacement' {
        ($script:Mjs -match 'name: "service-registry"') | Should -BeTrue
        ($script:Mjs -match [regex]::Escape('const SVC_PRISTINE = "delete process.env.XDG_STATE_HOME";')) | Should -BeTrue
        ($script:Mjs -match [regex]::Escape('globalThis.__opencodeCloneHome||delete process.env.XDG_STATE_HOME')) | Should -BeTrue -Because 'the splice must guard the deleter with the patch global - clones keep their state home, the Primary keeps stock'
    }

    It 'the splice is idempotent: the done-check runs before the split' {
        $svcAt = $script:Mjs.IndexOf('name: "service-registry"')
        ($svcAt -gt 0) | Should -BeTrue
        $doneAt = $script:Mjs.IndexOf('if (src.includes(SVC_DONE))', $svcAt)
        $splitAt = $script:Mjs.IndexOf('src.split(SVC_PRISTINE)', $svcAt)
        ($doneAt -gt 0 -and $splitAt -gt $doneAt) | Should -BeTrue -Because 'the guarded replacement CONTAINS the pristine anchor - the done-check must win or a re-run would splice again'
    }

    It 'the anchor is UNIQUE: the engine aborts on any site-count drift' {
        ($script:Mjs -match 'const SVC_EXPECTED_SITES = 1;') | Should -BeTrue
        ($script:Mjs -match [regex]::Escape('if (totals["service-registry"] > SVC_EXPECTED_SITES)')) | Should -BeTrue
        ($script:Mjs -match [regex]::Escape('service-registry anchor drift')) | Should -BeTrue
    }

    It 'an anchor-absent build (pre-2.3.2 layout) is skipped loudly, never a failure' {
        ($script:Mjs -match 'if \(p\.name === "service-registry"\) \{ skipped\.push\(p\.name\); continue; \}') | Should -BeTrue
        ($script:Mjs -match '\bskipped\b,') | Should -BeTrue -Because 'the success JSON must carry the skipped list'
        ($script:Ps1Raw -match [regex]::Escape('$engineJson.skipped')) | Should -BeTrue
        ($script:Ps1Raw -match 'anchor absent on this build') | Should -BeTrue -Because 'the driver must surface the skip loudly'
    }

    It 'the splice marker is verify-pinned (the bare anchor survives inside the guard, so it is NOT a marker)' {
        ($script:Mjs -match 'case "service-registry":') | Should -BeTrue
        ($script:Mjs -match [regex]::Escape('return ["__opencodeCloneHome||delete"];')) | Should -BeTrue
    }

    It 'ps1 probe carries the SVC tier and requires the splice at verify-after unless the engine skipped' {
        ($script:Ps1Raw -match 'SVC=') | Should -BeTrue
        ($script:Ps1Raw -match [regex]::Escape("const svcNeed=JSON.parse(process.argv[2]||'[]')")) | Should -BeTrue
        ($script:Ps1Raw -match '\$SvcSkipped = \(\$engineJson\.skipped -contains "service-registry"\)') | Should -BeTrue
    }

    It 'ps1 pristine-backup sanity gate includes service-registry in the no-fresh-changes check' {
        ($script:Ps1Raw -match '\$engineJson\.totals\.''service-registry'' -eq 0') | Should -BeTrue
    }
}
