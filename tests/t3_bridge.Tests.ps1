#Requires -Modules Pester
# T3 ZCode bridge gates (docs/T3_ZCODE_BRIDGE_SPEC.md).
# Static: file presence + node --check syntax on every bridge tool (mirrors the
# CI "Node engines" step). Live: the fake ACP client end-to-end run is gated on
# a seeded clone home (CI has none; a local box with ZCodeSecondHome runs it).
# Everything computes inside each It (the repo's working Pester pattern).

Describe "T3 bridge static gates" {
    It "ships every bridge tool file" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        foreach ($rel in @(
            'tools\t3_bridge_lib.mjs',
            'tools\t3_bridge_probe.mjs',
            'tools\t3_zcode_bridge.mjs',
            'tools\t3_bridge_fake_client.mjs'
        )) {
            Test-Path -LiteralPath (Join-Path $repoRoot $rel) | Should -BeTrue -Because "$rel must exist"
        }
    }

    It "passes node --check on every bridge tool" -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\nodejs\node.exe')) {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        # Functional node probe: only trust --version exiting 0 with a version.
        $node = 'C:\Program Files\nodejs\node.exe'
        $v = & $node --version 2>$null
        ($LASTEXITCODE -eq 0 -and ("$v") -match '^v\d+') | Should -BeTrue
        foreach ($rel in @(
            'tools\t3_bridge_lib.mjs',
            'tools\t3_bridge_probe.mjs',
            'tools\t3_zcode_bridge.mjs',
            'tools\t3_bridge_fake_client.mjs'
        )) {
            & $node --check (Join-Path $repoRoot $rel) 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0 -Because "node --check $rel must pass"
        }
    }

    It "documents the spec the tools implement" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        Test-Path -LiteralPath (Join-Path $repoRoot 'docs\T3_ZCODE_BRIDGE_SPEC.md') | Should -BeTrue
    }
}

Describe "T3 bridge live acceptance (gated)" {
    It "runs the fake ACP client end-to-end against a seeded clone home" -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:USERPROFILE 'ZCodeSecondHome\.zcode\v2\credentials.json'))) {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        $node = 'C:\Program Files\nodejs\node.exe'
        $v = & $node --version 2>$null
        ($LASTEXITCODE -eq 0 -and ("$v") -match '^v\d+') | Should -BeTrue
        $client = Join-Path $repoRoot 'tools\t3_bridge_fake_client.mjs'
        $output = & $node $client --Instance Second --timeout-seconds 90 2>&1
        $text = $output -join "`n"
        $text | Should -Match 'FAKE-CLIENT PASS'
    }
}
