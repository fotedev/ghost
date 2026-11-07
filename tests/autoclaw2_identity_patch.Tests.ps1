# SPDX-License-Identifier: Apache-2.0
# Tests for tools/patch_autoclaw2_identity.ps1 - the AutoClaw2 (zwork)
# window-level taskbar identity patch. The splice core is extracted VERBATIM
# from the driver via the PowerShell AST (the driver's main body must not
# execute), then exercised against a synthetic main.cjs fixture that mirrors
# the real 4.0.0 minified shapes (including the relaunchCommand backtick
# template literal, which must survive untouched). Node-dependent assertions
# run the REAL spliced fixture under node - functional proof of the
# env-driven identity semantics, never a test-local reimplementation.
# The LIVE-bundle test is THREE-STATE (2026-11-07, after the first real apply
# invalidated the original pristine-only premise 6 minutes after it was
# written): pristine (each Find anchor exactly once, no done-anchor) PASSES;
# fully patched (each done-anchor exactly once + marker sha256After verified
# + recorded backup present) PASSES; anything else (an app update landed a
# new bundle shape, or a splice crashed mid-way) FAILS loudly. After an app
# update the bundle is stock again, so the pristine branch passes and the
# driver re-applies on its next run - the state machine handles updates.
# -Skip gates use a static node-presence probe (Pester evaluates the Skip
# expression outside BeforeAll scope); each test re-probes functionally.

$script:VendorNode = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\vendor\node\node.exe'
# Pester 6: It bodies cannot see top-level $script: assignments OR functions,
# so every -Skip gate and body recomputes its paths inline (the lesson from
# the first runs of this file - the sibling patch_surgery.Tests.ps1 uses
# literal paths for the same reason).
$script:NodeSkipGate = -not ((Get-Command node -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $script:VendorNode))

Describe 'AutoClaw2 identity patch - anchor table' {
    BeforeAll {
        $patch = Join-Path $PSScriptRoot "..\tools\patch_autoclaw2_identity.ps1"
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($patch, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "patch_autoclaw2_identity.ps1 does not parse" }
        $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-IdentitySplice' }, $true)
        $fn.Count | Should -Be 1 -Because "the splice core must exist exactly once"
        Invoke-Expression $fn[0].Extent.Text
        $assign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:Anchors' }, $true)
        $assign.Count | Should -Be 1 -Because "the anchor table must exist exactly once"
        Invoke-Expression ('$script:Anchors = ' + $assign[0].Right.Extent.Text)
    }

    It 'declares exactly 3 distinct, backtick-free anchors' {
        $script:Anchors.Count | Should -Be 3
        foreach ($a in $script:Anchors) {
            $a.Find | Should -Not -Be $a.Replace
            $a.Find | Should -Not -Match '`' -Because "the relaunchCommand template literal must never be inside a splice anchor"
            $a.Name | Should -Not -BeNullOrEmpty
        }
        ($script:Anchors | ForEach-Object { $_.Name } | Select-Object -Unique).Count | Should -Be 3
    }

    It 'live 4.0.0 main.cjs is exactly pristine (anchors x1) or exactly patched (done-anchors x1, marker sha verified)' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\app\dist\main.cjs'))) {
        $bundle = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\app\dist\main.cjs'
        $text = [System.IO.File]::ReadAllText($bundle)
        $findCounts = @{}; $replCounts = @{}
        foreach ($a in $script:Anchors) {
            $findCounts[$a.Name] = [regex]::Matches($text, [regex]::Escape($a.Find)).Count
            $replCounts[$a.Name] = [regex]::Matches($text, [regex]::Escape($a.Replace)).Count
        }
        $pristine = ((@($findCounts.Values) -eq 1).Count -eq 3) -and ((@($replCounts.Values) -eq 0).Count -eq 3)
        $patched = ((@($replCounts.Values) -eq 1).Count -eq 3) -and ((@($findCounts.Values) -eq 0).Count -eq 3)
        if ($patched) {
            # PATCHED state - verify the applied bundle against the marker:
            # live sha256 must equal the recorded post-patch hash, and the
            # recorded pristine backup (when non-empty; a -Force re-record
            # writes backupPath='') must exist for -Restore.
            $markerPath = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\app\autoclaw2-identity-patch.marker.json'
            Test-Path -LiteralPath $markerPath | Should -BeTrue -Because "a patched bundle must carry the identity-patch marker"
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            $liveHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
            $liveHash | Should -Be $marker.sha256After -Because "the live bundle must byte-match the marker's recorded post-patch hash"
            if ($marker.backupPath) {
                Test-Path -LiteralPath $marker.backupPath | Should -BeTrue -Because "the recorded pristine backup must exist for -Restore"
                (Get-FileHash -LiteralPath $marker.backupPath -Algorithm SHA256).Hash | Should -Be $marker.sha256Before -Because "the backup must byte-match the marker's recorded pre-patch hash"
            }
            $true | Should -BeTrue -Because "live bundle is fully patched - done-anchors x1 with marker sha256 verified"
            return
        }
        if ($pristine) {
            # PRISTINE state - stock 4.0.0 bundle (or a post-update re-download);
            # the driver re-applies with a fresh backup on its next run.
            $true | Should -BeTrue -Because "live bundle is pristine - every Find anchor occurs exactly once and no done-anchor leaked"
            return
        }
        # NEITHER cleanly patched NOR pristine: an app update landed a NEW
        # bundle shape (anchors moved/renamed) or a splice crashed mid-way.
        $detail = ($script:Anchors | ForEach-Object { "{0}: find={1} repl={2}" -f $_.Name, $findCounts[$_.Name], $replCounts[$_.Name] }) -join '; '
        throw "live main.cjs is neither pristine nor cleanly patched ($detail) - re-derive the anchors (see AUTOCLAW2_CLONES_SPEC.md anchor procedure)"
    }
}

Describe 'AutoClaw2 identity patch - splice core (synthetic fixture)' {
    BeforeAll {
        $patch = Join-Path $PSScriptRoot "..\tools\patch_autoclaw2_identity.ps1"
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($patch, [ref]$tokens, [ref]$errors)
        $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Invoke-IdentitySplice' }, $true)
        Invoke-Expression $fn[0].Extent.Text
        $assign = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -eq '$script:Anchors' }, $true)
        Invoke-Expression ('$script:Anchors = ' + $assign[0].Right.Extent.Text)

        # Mirrors the REAL minified shapes (byte-level anchors) of AutoClaw2
        # 4.0.0 main.cjs. Single-quoted here-string: backticks and $ are literal.
        $script:Fixture = @'
var Uf = { app: { isPackaged: true, setName: function (n) { globalThis.__name = n; }, setAppUserModelId: function (a) { globalThis.__procAumid = a; }, setAboutPanelOptions: function (o) { globalThis.__about = o; } } };
var Kqn = "com.zhipuai.autoclaw2", p0 = "AutoClaw", Tgt = p0, Zqn = p0;
function Yqn(n,e=process.platform,r=p0,i=r){Zqn=r,Tgt=i,n.setName(p0),e==="win32"&&n.setAppUserModelId(Kqn),n.setAboutPanelOptions({applicationName:i})}
function Xqn(n,e,r=process.platform){r==="win32"&&n.setAppDetails({appId:Kqn,appIconPath:e,appIconIndex:0,relaunchCommand:`"${e}"`,relaunchDisplayName:Tgt})}
var l = { setIcon: function (p) { globalThis.__winIcon = p; }, setAppDetails: function (d) { globalThis.__details = d; } };
Uf.app.isPackaged&&Xqn(l,process.execPath);
Yqn(Uf.app);
'@
    }

    It 'splices all 3 anchors and preserves the backtick literal verbatim' {
        $r = Invoke-IdentitySplice -Text $script:Fixture
        $r.Ok | Should -BeTrue
        $r.AlreadyApplied | Should -BeFalse
        $r.Applied.Count | Should -Be 3
        foreach ($a in $script:Anchors) {
            [regex]::Matches($r.Text, [regex]::Escape($a.Find)).Count | Should -Be 0
            [regex]::Matches($r.Text, [regex]::Escape($a.Replace)).Count | Should -Be 1
        }
        # The relaunchCommand template literal must survive byte-for-byte.
        $r.Text | Should -Match ([regex]::Escape('relaunchCommand:`"${e}"`'))
    }

    It 'is idempotent: re-splicing a patched fixture reports AlreadyApplied' {
        $once = Invoke-IdentitySplice -Text $script:Fixture
        $twice = Invoke-IdentitySplice -Text $once.Text
        $twice.Ok | Should -BeTrue
        $twice.AlreadyApplied | Should -BeTrue
        $twice.Text | Should -Be $once.Text
    }

    It 'aborts with anchor drift when an anchor is missing (bundle changed)' {
        $noAnchor2 = ($script:Fixture -split "`n" | Where-Object { $_ -notmatch 'setAppDetails' }) -join "`n"
        $r = Invoke-IdentitySplice -Text $noAnchor2
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'window-details'
        $r.Message | Should -Match 'exactly 1'
    }

    It 'aborts on a MIXED state (only one anchor already patched)' {
        $a1 = $script:Anchors[0]
        $half = $script:Fixture.Replace($a1.Find, $a1.Replace)
        $r = Invoke-IdentitySplice -Text $half
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'process-aumid'
    }

    It 'produces a node --check-clean bundle' -Skip:(-not ((Get-Command node -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $script:VendorNode))) {
        $cmd = Get-Command node -ErrorAction SilentlyContinue
        $node = if ($cmd) { $cmd.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\vendor\node\node.exe' }
        if (-not (Test-Path -LiteralPath $node)) { Set-ItResult -Skipped -Because "node is not runnable"; return }
        $r = Invoke-IdentitySplice -Text $script:Fixture
        $f = Join-Path $TestDrive "spliced.cjs"
        [System.IO.File]::WriteAllText($f, $r.Text, (New-Object System.Text.UTF8Encoding($false)))
        & $node --check $f 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "the spliced bundle must stay valid JavaScript"
    }

    It 'spliced fixture is functionally env-driven under node (clone identity)' -Skip:(-not ((Get-Command node -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $script:VendorNode))) {
        $cmd = Get-Command node -ErrorAction SilentlyContinue
        $node = if ($cmd) { $cmd.Source } else { Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\vendor\node\node.exe' }
        if (-not (Test-Path -LiteralPath $node)) { Set-ItResult -Skipped -Because "node is not runnable"; return }
        $r = Invoke-IdentitySplice -Text $script:Fixture
        $fixture = Join-Path $TestDrive "identity-fixture.cjs"
        [System.IO.File]::WriteAllText($fixture, $r.Text, (New-Object System.Text.UTF8Encoding($false)))
        $driver = Join-Path $TestDrive "identity-driver.cjs"
        @'
require(process.argv[2]);
console.log(JSON.stringify({
  procAumid: globalThis.__procAumid === undefined ? null : globalThis.__procAumid,
  appId: globalThis.__details ? globalThis.__details.appId : null,
  iconPath: globalThis.__details ? globalThis.__details.appIconPath : null,
  relaunch: globalThis.__details ? globalThis.__details.relaunchCommand : null,
  winIcon: globalThis.__winIcon === undefined ? null : globalThis.__winIcon
}));
'@ | Set-Content -LiteralPath $driver -Encoding UTF8

        # Clone launch: env drives the AUMID, the taskbar icon AND the window icon.
        $env:ZWORK_AUMID = 'com.zhipuai.autoclaw2.c1'
        $env:ZWORK_CLONE_ICON = 'C:\clone\blue.ico'
        try {
            $out = & $node $driver $fixture 2>&1
            $LASTEXITCODE | Should -Be 0 -Because "clone run must succeed: $($out -join ' | ')"
            $v = (@($out) | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
            $v.procAumid | Should -Be 'com.zhipuai.autoclaw2.c1'
            $v.appId | Should -Be 'com.zhipuai.autoclaw2.c1'
            $v.iconPath | Should -Be 'C:\clone\blue.ico'
            $v.winIcon | Should -Be 'C:\clone\blue.ico'
            # relaunchCommand stays the EXE (the parameter e), never the icon.
            $v.relaunch | Should -Be ('"' + (Get-Item -LiteralPath $node).FullName + '"')
        } finally {
            Remove-Item Env:ZWORK_AUMID -ErrorAction SilentlyContinue
            Remove-Item Env:ZWORK_CLONE_ICON -ErrorAction SilentlyContinue
        }

        # Stock launch: no env = byte-for-byte stock behaviour.
        Remove-Item Env:ZWORK_AUMID -ErrorAction SilentlyContinue
        Remove-Item Env:ZWORK_CLONE_ICON -ErrorAction SilentlyContinue
        $out2 = & $node $driver $fixture 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "stock run must succeed: $($out2 -join ' | ')"
        $v2 = (@($out2) | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $v2.procAumid | Should -Be 'com.zhipuai.autoclaw2'
        $v2.appId | Should -Be 'com.zhipuai.autoclaw2'
        $v2.iconPath | Should -Be ($v2.relaunch -replace '^"|"$', '') -Because "stock appIconPath is process.execPath, same as the relaunch command"
        $v2.winIcon | Should -BeNullOrEmpty
    }
}
