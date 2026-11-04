# SPDX-License-Identifier: Apache-2.0
# Tests for tools/asar_surgery.mjs (the shared asar-surgery IO layer used by
# the ZCode icon-override v9+ and OpenCode clone-home v4+ patch engines) and
# the ZCode engine's CLI contract. All assertions run the REAL node code:
# the module's --selftest builds a synthetic asar (text entries, a >4 MiB
# binary entry, an empty file, a deduplicated twin pair sharing one offset,
# and an unpacked sidecar file), rebuilds it with two patches, verifies the
# round-trip, and exercises the corrupt-header abort - never the live app
# install. -Skip gates use a static node-presence probe (Pester evaluates the
# Skip expression outside BeforeAll scope); each test re-probes functionally.

Describe 'asar_surgery module' {
    It 'passes every selftest round-trip check' -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\nodejs\node.exe')) {
        # Functional node probe: only trust --version exiting 0 with a version.
        $node = 'C:\Program Files\nodejs\node.exe'
        $v = & $node --version 2>$null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because "node is present but not runnable" }

        $surgery = Join-Path $PSScriptRoot "..\tools\asar_surgery.mjs"
        $work = Join-Path $TestDrive "selftest-run"
        $out = & $node $surgery --selftest $work 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "selftest must pass: $($out -join ' | ')"
        $jsonLine = @($out) | Where-Object { $_ -match '^\{"ok"' } | Select-Object -Last 1
        $jsonLine | Should -Not -BeNullOrEmpty -Because "selftest must print a JSON verdict"
        $v2 = $jsonLine | ConvertFrom-Json
        $v2.ok | Should -BeTrue
        $v2.checks.builtSource | Should -BeTrue
        $v2.checks.patchedCount | Should -Be 2
        $v2.checks.patchedRels | Should -Contain "a.js"
        $v2.checks.patchedRels | Should -Contain "dup1.js"
        $v2.checks.dup2KeptOldOffset | Should -BeTrue   # dedup twin keeps the shared offset
        $v2.checks.corruptHeaderAborts | Should -BeTrue # parse refuses a mangled header
        $v2.checks.verifyErrors | Should -BeNullOrEmpty
    }

    It 'builds header pickles with correct u32 framing' -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\nodejs\node.exe')) {
        $node = 'C:\Program Files\nodejs\node.exe'
        $v = & $node --version 2>$null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because "node is present but not runnable" }

        # Probe imports the module by absolute file URL and checks the pickle
        # layout the live asar confirmed: [u32 4][u32 headerBufLen] +
        # [u32 payloadSize][u32 jsonLen][json][zero pad].
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $moduleUrl = "file:///" + ($repoRoot -replace "\\", "/") + "/tools/asar_surgery.mjs"
        $code = @"
import { buildHeaderBlock } from "$moduleUrl";
const header = { files: { "a.js": { size: 3, offset: "0" } } };
const { sizeBuf, headerBuf } = buildHeaderBlock(header);
const jsonLen = headerBuf.readUInt32LE(4);
const json = headerBuf.subarray(8, 8 + jsonLen).toString("utf8");
const magic = sizeBuf.readUInt32LE(0);
const headerBufLenMatches = sizeBuf.readUInt32LE(4) === headerBuf.length;
const payloadSizeMatches = headerBuf.readUInt32LE(0) === ((4 + jsonLen + 3) & ~3);
const headerParses = JSON.parse(json).files["a.js"].offset === "0";
const tailZeroPadded = headerBuf.subarray(8 + jsonLen).every((b) => b === 0);
console.log(JSON.stringify({ magic, headerBufLenMatches, payloadSizeMatches, headerParses, tailZeroPadded }));
if (magic !== 4 || !headerBufLenMatches || !payloadSizeMatches || !headerParses || !tailZeroPadded) process.exit(1);
"@
        $probe = Join-Path $TestDrive "pickle-probe.mjs"
        Set-Content -LiteralPath $probe -Value $code -Encoding UTF8
        $out = & $node $probe 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "pickle probe must pass: $($out -join ' | ')"
        $jsonLine = @($out) | Where-Object { $_ -match '^\{' } | Select-Object -Last 1
        $v3 = $jsonLine | ConvertFrom-Json
        $v3.magic | Should -Be 4
        $v3.headerBufLenMatches | Should -BeTrue
        $v3.payloadSizeMatches | Should -BeTrue
        $v3.headerParses | Should -BeTrue
        $v3.tailZeroPadded | Should -BeTrue
    }

    It 'refuses to run the ZCode engine without all three arguments' -Skip:(-not (Test-Path -LiteralPath 'C:\Program Files\nodejs\node.exe')) {
        $node = 'C:\Program Files\nodejs\node.exe'
        $v = & $node --version 2>$null
        if ($LASTEXITCODE -ne 0) { Set-ItResult -Skipped -Because "node is present but not runnable" }

        $engine = Join-Path $PSScriptRoot "..\tools\patch_zcode_icon_override.mjs"
        $out = & $node $engine 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join " ") | Should -Match "usage"
    }
}

Describe 'swap retry under real file locks (Invoke-AsarSwap)' {
    # The driver cannot be dot-sourced (its main body would execute), so the
    # REAL shipped functions are extracted verbatim from the driver file by
    # anchored regex and defined here - no test-local reimplementation. The
    # scenarios hold the candidate with FileShare.None (what antivirus does
    # while scanning a just-written file) from a background job: a lock
    # shorter than the 6x300 ms retry window must succeed after retries, and
    # a lock that outlasts the window must roll back with the ORIGINAL
    # app.asar back in place (rename-back) - the no-missing-asar guarantee.
    BeforeAll {
        $driver = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\tools\patch_zcode_icon_override.ps1") -Raw
        foreach ($fn in @("Test-SwapRetryableException", "Invoke-AsarSwap")) {
            $m = [regex]::Match($driver, "(?s)function $fn \{.*?(?=\r?\nfunction )")
            if (-not $m.Success) { throw "could not extract function $fn from the ZCode driver" }
            Invoke-Expression $m.Value
        }
        Get-Command Invoke-AsarSwap | Should -Not -BeNullOrEmpty
    }

    It 'succeeds after retries when the candidate is briefly locked' {
        $res = Join-Path $TestDrive "res-ok"; New-Item $res -ItemType Directory -Force | Out-Null
        $asar = Join-Path $res "app.asar"; Set-Content -LiteralPath $asar -Value "ORIGINAL"
        $work = Join-Path $TestDrive "work-ok"; New-Item $work -ItemType Directory -Force | Out-Null
        $cand = Join-Path $work "candidate.asar"; Set-Content -LiteralPath $cand -Value "PATCHED"
        $ready = Join-Path $TestDrive "ready-ok.flag"

        $job = Start-Job -ScriptBlock {
            param($path, $ready)
            $fs = [IO.File]::Open($path, 'Open', 'Read', 'None')
            Set-Content -LiteralPath $ready -Value "locked"
            Start-Sleep -Seconds 1
            $fs.Dispose()
        } -ArgumentList $cand, $ready
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Test-Path $ready | Should -BeTrue -Because "the lock must be established before the swap starts"

            Invoke-AsarSwap -ResourcesDir $res -CandidateAsar $cand -MinAsarBytes 1 -BackupAsar $asar -SkipUnpackedSwap

            Get-Content -LiteralPath $asar | Should -Be "PATCHED"
            Test-Path (Join-Path $res "app.asar.old") | Should -BeFalse
        } finally {
            # PS 5.1: Remove-Job has no -Wait; the job's file handle must be
            # closed BEFORE Pester deletes TestDrive.
            Wait-Job $job -Timeout 30 -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rolls back with the original asar when the lock outlasts the retry window' {
        $res = Join-Path $TestDrive "res-ex"; New-Item $res -ItemType Directory -Force | Out-Null
        $asar = Join-Path $res "app.asar"; Set-Content -LiteralPath $asar -Value "ORIGINAL"
        $work = Join-Path $TestDrive "work-ex"; New-Item $work -ItemType Directory -Force | Out-Null
        $cand = Join-Path $work "candidate.asar"; Set-Content -LiteralPath $cand -Value "PATCHED"
        $ready = Join-Path $TestDrive "ready-ex.flag"

        # 5 s hold > the full 6x300 ms retry window (~1.8 s)
        $job = Start-Job -ScriptBlock {
            param($path, $ready)
            $fs = [IO.File]::Open($path, 'Open', 'Read', 'None')
            Set-Content -LiteralPath $ready -Value "locked"
            Start-Sleep -Seconds 5
            $fs.Dispose()
        } -ArgumentList $cand, $ready
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not (Test-Path $ready) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
            Test-Path $ready | Should -BeTrue -Because "the lock must be established before the swap starts"

            { Invoke-AsarSwap -ResourcesDir $res -CandidateAsar $cand -MinAsarBytes 1 -BackupAsar $asar -SkipUnpackedSwap } |
                Should -Throw "*still blocked after 6 retries*"

            # rename-back guarantee: the install is not left without app.asar
            Get-Content -LiteralPath $asar | Should -Be "ORIGINAL"
            Test-Path (Join-Path $res "app.asar.old") | Should -BeFalse
            Test-Path $cand | Should -BeTrue -Because "a failed move must not consume the candidate"
        } finally {
            Wait-Job $job -Timeout 30 -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}
