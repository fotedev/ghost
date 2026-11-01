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

Describe "T3 bridge child env (0.17.1 provider-config lever)" {
    # Unit gates for the FIFTH env lever (2026-10-31 plain-node bootstrap
    # regression): buildChildEnv must carry ZCODE_BUILTIN_PROVIDER_CONFIG_FILE,
    # resolveBuiltinProviderConfig must prefer the bundled install copy and fall
    # back to the newest runtime-cache copy, and spawnAppServer must fail fast
    # with a clear message when neither exists (before any process spawns).
    It "buildChildEnv + resolveBuiltinProviderConfig + spawnAppServer fail-fast (lib unit)" -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\nodejs\node.exe')) {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        $node = 'C:\Program Files\nodejs\node.exe'
        $v = & $node --version 2>$null
        ($LASTEXITCODE -eq 0 -and ("$v") -match '^v\d+') | Should -BeTrue
        $libUrl = ([System.Uri](Join-Path $repoRoot 'tools\t3_bridge_lib.mjs')).AbsoluteUri
        $js = @'
import { buildChildEnv, resolveBuiltinProviderConfig, spawnAppServer } from '__LIB_URL__';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const out = {};
const mk = () => fs.mkdtempSync(path.join(os.tmpdir(), 't3bridge-test-'));
const rm = (dir) => { try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* best effort */ } };

// Case A: bundled install copy present -> resolved + lever set on the env.
{
    const root = mk(); const home = mk();
    try {
        fs.mkdirSync(path.join(root, 'resources', 'glm'), { recursive: true });
        fs.mkdirSync(path.join(root, 'resources', 'config', 'provider'), { recursive: true });
        const cli = path.join(root, 'resources', 'glm', 'zcode.cjs');
        fs.writeFileSync(cli, '//stub');
        const bundled = path.join(root, 'resources', 'config', 'provider', 'zcode-builtin.json');
        fs.writeFileSync(bundled, '{}');
        out.bundledResolved = resolveBuiltinProviderConfig(cli, home) === bundled;
        const env = buildChildEnv(home, bundled);
        out.envHasLever = env.ZCODE_BUILTIN_PROVIDER_CONFIG_FILE === bundled;
        out.envHasFour = env.HOME === home && env.USERPROFILE === home &&
            env.ZCODE_DATA_BASE_DIR === home && env.ZCODE_STORAGE_DIR === path.join(home, '.zcode');
        out.envOmitsWhenAbsent = buildChildEnv(home).ZCODE_BUILTIN_PROVIDER_CONFIG_FILE === undefined;
    } finally { rm(root); rm(home); }
}

// Case B: bundled missing -> newest runtime-cache copy wins; nothing at all ->
// spawnAppServer throws the clear message BEFORE spawning any process.
{
    const root = mk(); const home = mk(); const emptyHome = mk();
    try {
        fs.mkdirSync(path.join(root, 'resources', 'glm'), { recursive: true });
        const cli = path.join(root, 'resources', 'glm', 'zcode.cjs');
        fs.writeFileSync(cli, '//stub');
        const oldCopy = path.join(home, '.zcode', 'v2', 'runtime', 'provider', 'windows-x86_64', '3.16.0', 'endpoint-a', 'zcode-builtin.json');
        const newCopy = path.join(home, '.zcode', 'v2', 'runtime', 'provider', 'windows-x86_64', '3.17.1', 'endpoint-b', 'zcode-builtin.json');
        fs.mkdirSync(path.dirname(oldCopy), { recursive: true });
        fs.mkdirSync(path.dirname(newCopy), { recursive: true });
        fs.writeFileSync(oldCopy, '{"rev":1}');
        fs.writeFileSync(newCopy, '{"rev":2}');
        const t = Date.now() / 1000;
        fs.utimesSync(oldCopy, t - 100, t - 100);
        fs.utimesSync(newCopy, t, t);
        out.cacheFallbackNewest = resolveBuiltinProviderConfig(cli, home) === newCopy;
        let threw = null;
        try { spawnAppServer(cli, emptyHome); } catch (e) { threw = String(e.message); }
        out.spawnThrowsClear = threw !== null && threw.includes('bundled provider config') &&
            threw.includes('Launch the ZCode desktop app');
    } finally { rm(root); rm(home); rm(emptyHome); }
}

process.stdout.write('RESULT:' + JSON.stringify(out));
'@
        $js = $js.Replace('__LIB_URL__', $libUrl)
        $output = & $node --input-type=module -e $js 2>&1
        $text = ($output -join "`n")
        $m = [regex]::Match($text, 'RESULT:(\{.*\})')
        $m.Success | Should -BeTrue -Because "node harness must print a RESULT json; got: $text"
        $r = $m.Groups[1].Value | ConvertFrom-Json
        foreach ($key in @('bundledResolved', 'envHasLever', 'envHasFour', 'envOmitsWhenAbsent', 'cacheFallbackNewest', 'spawnThrowsClear')) {
            $r.$key | Should -BeTrue -Because "$key must hold"
        }
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
