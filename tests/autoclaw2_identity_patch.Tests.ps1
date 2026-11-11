# SPDX-License-Identifier: Apache-2.0
# Tests for tools/patch_autoclaw2_identity.ps1 - the AutoClaw2 (zwork)
# window + notification-tray identity patch. The splice core is extracted
# VERBATIM from the driver via the PowerShell AST (the driver's main body
# must not execute), then exercised against a synthetic main.cjs fixture
# that mirrors the real 4.0.0 minified shapes (including the relaunchCommand
# backtick template literal, which must survive untouched, and the mTr tray
# builder whose iconPath read is the patch-v2 tray anchor). Node-dependent
# assertions run the REAL spliced fixture under node - functional proof of
# the env-driven identity semantics, never a test-local reimplementation.
# The LIVE-bundle test is state-aware (three-state since 2026-11-07,
# resumable-aware since patch v2 2026-11-09): every anchor must be EITHER
# already spliced (its done-text present) OR pristine (its Find text exactly
# once). Fully patched PASSES (marker sha256After verified + recorded backup
# present); pristine and legacy-partial (v1) states PASS as resumable - the
# driver applies the remaining anchors on its next run; only a genuinely
# changed bundle layout (an anchor neither present nor already spliced)
# FAILS loudly. After an app update the bundle is stock again, so the
# pristine branch passes and the driver re-applies on its next run.
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

    It 'declares exactly 4 distinct, backtick-free anchors (v2 adds tray-icon)' {
        $script:Anchors.Count | Should -Be 4
        foreach ($a in $script:Anchors) {
            $a.Find | Should -Not -Be $a.Replace
            $a.Find | Should -Not -Match '`' -Because "the relaunchCommand template literal must never be inside a splice anchor"
            $a.Name | Should -Not -BeNullOrEmpty
        }
        ($script:Anchors | ForEach-Object { $_.Name } | Select-Object -Unique).Count | Should -Be 4
        @($script:Anchors | Where-Object { $_.Name -eq 'tray-icon' }).Count | Should -Be 1 -Because "patch v2 adds exactly one notification-tray anchor"
    }

    It 'live main.cjs is fully patched (marker sha verified), pristine, or cleanly resumable' -Skip:(-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\app\dist\main.cjs'))) {
        $bundle = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\app\dist\main.cjs'
        $text = [System.IO.File]::ReadAllText($bundle)
        $findCounts = @{}; $replCounts = @{}
        foreach ($a in $script:Anchors) {
            $findCounts[$a.Name] = [regex]::Matches($text, [regex]::Escape($a.Find)).Count
            $replCounts[$a.Name] = [regex]::Matches($text, [regex]::Escape($a.Replace)).Count
        }
        $doneAll = $true; $resumable = $true
        foreach ($a in $script:Anchors) {
            $done = $replCounts[$a.Name] -ge 1
            $splicable = $findCounts[$a.Name] -eq 1
            if ($done -and $splicable) {
                # both texts present: ambiguous bundle state, never legitimate
                $doneAll = $false; $resumable = $false
            } elseif (-not $done -and -not $splicable) {
                # neither present: the bundle layout changed (app update)
                $doneAll = $false; $resumable = $false
            } elseif (-not $done) {
                # pristine anchor: splicable, not yet applied
                $doneAll = $false
            }
        }
        if ($doneAll) {
            # PATCHED state - verify the applied bundle against the marker:
            # live sha256 must equal the recorded post-patch hash, and the
            # recorded backup (when non-empty; a -Force re-record writes
            # backupPath='') must exist and byte-match sha256Before. Since
            # patch v2 the backup may hold the pre-upgrade (legacy-patched)
            # state rather than pristine stock - sha256Before stays truthful
            # either way.
            $markerPath = Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2\resources\app\autoclaw2-identity-patch.marker.json'
            Test-Path -LiteralPath $markerPath | Should -BeTrue -Because "a patched bundle must carry the identity-patch marker"
            $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
            $liveHash = (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
            $liveHash | Should -Be $marker.sha256After -Because "the live bundle must byte-match the marker's recorded post-patch hash"
            if ($marker.backupPath) {
                Test-Path -LiteralPath $marker.backupPath | Should -BeTrue -Because "the recorded backup must exist for -Restore"
                (Get-FileHash -LiteralPath $marker.backupPath -Algorithm SHA256).Hash | Should -Be $marker.sha256Before -Because "the backup must byte-match the marker's recorded pre-patch hash"
            }
            $true | Should -BeTrue -Because "live bundle is fully patched - done-anchors x1 with marker sha256 verified"
            return
        }
        if ($resumable) {
            # PRISTINE or LEGACY state - stock bundle, or a v1-patched bundle
            # awaiting the v2 tray anchor; the driver applies/resumes on its
            # next run (per-anchor skip since patch v2).
            $true | Should -BeTrue -Because "live bundle is pristine or cleanly resumable - every anchor is either present x1 or already spliced"
            return
        }
        # NEITHER patched NOR resumable: an app update landed a NEW bundle
        # shape (anchors moved/renamed) or a splice crashed mid-way.
        $detail = ($script:Anchors | ForEach-Object { "{0}: find={1} repl={2}" -f $_.Name, $findCounts[$_.Name], $replCounts[$_.Name] }) -join '; '
        throw "live main.cjs is neither fully patched nor cleanly resumable ($detail) - re-derive the anchors (see AUTOCLAW2_CLONES_SPEC.md anchor procedure)"
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
        # 4.0.0 main.cjs, including the mTr tray builder (the patch-v2 tray
        # anchor lives on its iconPath read). Single-quoted here-string:
        # backticks and $ are literal.
        $script:Fixture = @'
var Uf = { app: { isPackaged: true, setName: function (n) { globalThis.__name = n; }, setAppUserModelId: function (a) { globalThis.__procAumid = a; }, setAboutPanelOptions: function (o) { globalThis.__about = o; } } };
var SU = { nativeImage: { createFromPath: function (o) { globalThis.__traySrc = o; return { isEmpty: function () { return false; }, isTemplateImage: function () { return false; }, resize: function (s) { return { setTemplateImage: function (b) { globalThis.__trayTemplate = b; return {}; } }; } }; }, createEmpty: function () { return { isEmpty: function () { return true; } }; } }, Tray: function (o) { globalThis.__trayImage = o; return { setToolTip: function () { }, setContextMenu: function () { }, on: function () { }, destroy: function () { } }; }, Menu: { buildFromTemplate: function (o) { return o; } } };
var pTr = { join: function (a, b) { return a + '\\' + b; } };
var Kqn = "com.zhipuai.autoclaw2", p0 = "AutoClaw", Tgt = p0, Zqn = p0;
function Yqn(n,e=process.platform,r=p0,i=r){Zqn=r,Tgt=i,n.setName(p0),e==="win32"&&n.setAppUserModelId(Kqn),n.setAboutPanelOptions({applicationName:i})}
function Xqn(n,e,r=process.platform){r==="win32"&&n.setAppDetails({appId:Kqn,appIconPath:e,appIconIndex:0,relaunchCommand:`"${e}"`,relaunchDisplayName:Tgt})}
var l = { setIcon: function (p) { globalThis.__winIcon = p; }, setAppDetails: function (d) { globalThis.__details = d; } };
Uf.app.isPackaged&&Xqn(l,process.execPath);
Yqn(Uf.app);
function PG(){return "AutoClaw";}
function xr(o,k){return k;}
function fTr(n){return(0,pTr.join)(n,"trayTemplate.png")}
function mTr(n){let e=n.createIcon??(o=>{let s=SU.nativeImage.createFromPath(o);if(s.isEmpty())return SU.nativeImage.createEmpty();let l=s.resize({width:18,height:18});return l.setTemplateImage(s.isTemplateImage()),l}),r=n.createTray??(o=>new SU.Tray(o)),i=n.buildMenu??(o=>SU.Menu.buildFromTemplate([...o])),t=r(e(n.iconPath));t.setToolTip(PG());let a=()=>{let o=n.language(),s=[{label:xr(o,"tray.open"),click:n.onOpen},{label:xr(o,"tray.quit"),click:n.onQuit}];t.setContextMenu(i(s))};return a(),t.on("click",n.onOpen),{dispose:()=>{t.destroy()},refresh:a}}
function UUr(n,e,r,i,t){n.tray=mTr({iconPath:fTr(e),language:r.current,onOpen:()=>{i.canOpenInteractiveWindows()&&t()},onQuit:()=>{FUr.app.quit()}}),r.attachTray(()=>{n.tray?.refresh()})}
var FUr = { app: { quit: function () { globalThis.__quit = true; } } };
UUr({tray:null},"C:\\app\\resources",{current:function(){return{};},attachTray:function(f){f()}},{canOpenInteractiveWindows:function(){return false;}},function(){});
'@
    }

    It 'splices all 4 anchors and preserves the backtick literal verbatim' {
        $r = Invoke-IdentitySplice -Text $script:Fixture
        $r.Ok | Should -BeTrue
        $r.AlreadyApplied | Should -BeFalse
        $r.Applied.Count | Should -Be 4
        $r.Applied | Should -Contain 'tray-icon' -Because "patch v2 splices the tray anchor"
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

    It 'resumes a legacy v1 state: only the missing tray anchor is applied, older anchors skipped' {
        $a1 = $script:Anchors[0]
        $legacy = $script:Fixture.Replace($a1.Find, $a1.Replace)
        $r = Invoke-IdentitySplice -Text $legacy
        $r.Ok | Should -BeTrue
        $r.AlreadyApplied | Should -BeFalse
        @($r.Skipped).Count | Should -Be 1
        $r.Skipped[0] | Should -Be 'process-aumid'
        $r.Applied.Count | Should -Be 3
        $r.Applied | Should -Not -Contain 'process-aumid'
        $r.Applied | Should -Contain 'tray-icon'
    }

    It 'aborts with anchor drift when an anchor is missing (bundle changed)' {
        $noAnchor2 = ($script:Fixture -split "`n" | Where-Object { $_ -notmatch 'setAppDetails' }) -join "`n"
        $r = Invoke-IdentitySplice -Text $noAnchor2
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'window-details'
        $r.Message | Should -Match 'exactly 1'
    }

    It 'aborts when an anchor is neither present nor already spliced (layout change)' {
        # strip the whole tray-builder block: the tray anchor's Find text no
        # longer exists and its done-text was never spliced -> hard drift.
        $noTray = ($script:Fixture -split "`n" | Where-Object { $_ -notmatch '^var SU =|^var pTr|^function PG|^function xr|^function fTr|^function mTr|^function UUr|^var FUr|^UUr\(' }) -join "`n"
        $r = Invoke-IdentitySplice -Text $noTray
        $r.Ok | Should -BeFalse
        $r.Message | Should -Match 'tray-icon'
        $r.Message | Should -Match 'exactly 1'
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

    It 'spliced fixture is functionally env-driven under node (clone window + tray identity)' -Skip:(-not ((Get-Command node -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $script:VendorNode))) {
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
  winIcon: globalThis.__winIcon === undefined ? null : globalThis.__winIcon,
  traySrc: globalThis.__traySrc === undefined ? null : globalThis.__traySrc,
  trayTemplate: globalThis.__trayTemplate === undefined ? null : globalThis.__trayTemplate
}));
'@ | Set-Content -LiteralPath $driver -Encoding UTF8

        # Clone launch: env drives the AUMID, the taskbar icon, the window
        # icon AND the notification-tray icon source.
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
            $v.traySrc | Should -Be 'C:\clone\blue.ico' -Because "the tray builder must receive the clone's tinted icon when ZWORK_CLONE_ICON is set"
            $v.trayTemplate | Should -BeFalse -Because "the tinted ico is not a macOS template image"
            # relaunchCommand stays the EXE (the parameter e), never the icon.
            $v.relaunch | Should -Be ('"' + (Get-Item -LiteralPath $node).FullName + '"')
        } finally {
            Remove-Item Env:ZWORK_AUMID -ErrorAction SilentlyContinue
            Remove-Item Env:ZWORK_CLONE_ICON -ErrorAction SilentlyContinue
        }

        # Stock launch: no env = byte-for-byte stock behaviour (tray keeps the
        # app's own trayTemplate.png).
        Remove-Item Env:ZWORK_AUMID -ErrorAction SilentlyContinue
        Remove-Item Env:ZWORK_CLONE_ICON -ErrorAction SilentlyContinue
        $out2 = & $node $driver $fixture 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "stock run must succeed: $($out2 -join ' | ')"
        $v2 = (@($out2) | Where-Object { $_ -match '^\{' } | Select-Object -Last 1) | ConvertFrom-Json
        $v2.procAumid | Should -Be 'com.zhipuai.autoclaw2'
        $v2.appId | Should -Be 'com.zhipuai.autoclaw2'
        $v2.iconPath | Should -Be ($v2.relaunch -replace '^"|"$', '') -Because "stock appIconPath is process.execPath, same as the relaunch command"
        $v2.winIcon | Should -BeNullOrEmpty
        $v2.traySrc | Should -Be 'C:\app\resources\trayTemplate.png' -Because "stock tray icon source is the app's own trayTemplate.png"
        $v2.trayTemplate | Should -BeFalse
    }
}
