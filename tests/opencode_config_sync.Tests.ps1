# SPDX-License-Identifier: Apache-2.0
# Functional tests for tools/sync_opencode_config.ps1 - the OpenCode
# definitions-only Primary -> clone config sync child (CS-1 + CS-7). The
# child runs end-to-end through %TEMP% fixture homes (its merge invariant
# is covered by tests/opencode_config_merge.Tests.ps1; this file pins the
# child-level contract):
#   - the CS-7 Phase-0 verdict (LIVE-VERIFIED 2026-11-22): a RUNNING clone
#     (lockfile held) is SYNCED BY DEFAULT - the v2.3.2 service re-reads
#     its config on change (the reload-probe verify-after reports
#     VERIFIED / NOT observed against the clone's own service log); the
#     v1 npm CLI binary is startup-only, so "NOT observed" is a WARN,
#     never a failure;
#   - -SkipRunning restores the old skip as an opt-out;
#   - config-less clones stay skipped (anonymous-first-run design);
#   - -DryRun writes nothing; the Primary is read-only (hash re-checked).

Describe 'OpenCode config sync child - script hygiene + CS-7 contract' {
    BeforeAll {
        $script:Child = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\sync_opencode_config.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Child, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "sync_opencode_config.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Child)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Child)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'carries the CS-7 Phase-0 verdict: running clones are SYNCED live (LIVE-VERIFIED)' {
        ($script:Raw -match 'CS-7 Phase-0 VERDICT \(LIVE-VERIFIED 2026-11-22') | Should -BeTrue
        ($script:Raw -match 'config\.updated` within ~2s') | Should -BeTrue -Because 'the controlled live probe fired the reload in ~2s for both write styles'
        # no -ApplyLive flag: the live behavior is the DEFAULT, not an opt-in
        ($script:Raw -match '\$ApplyLive') | Should -BeFalse
    }

    It 'the flip surface: -SkipRunning opt-out + -ReloadProbeSeconds verify-after' {
        ($script:Raw -match '\[switch\]\$SkipRunning') | Should -BeTrue
        ($script:Raw -match '\[int\]\$ReloadProbeSeconds = 8') | Should -BeTrue
        ($script:Raw -match 'SkipRunning requested; the launcher''s pre-launch step covers it next launch') | Should -BeTrue
    }

    It 'the live-reload verify-after polls the clone service log for config.updated' {
        ($script:Raw -match 'data\\opencode\\log\\opencode\.log') | Should -BeTrue
        ($script:Raw -match 'reload VERIFIED - config\.updated fired') | Should -BeTrue
        ($script:Raw -match 'reload NOT observed within') | Should -BeTrue
        ($script:Raw -match 'next session/launch picks it up') | Should -BeTrue -Because 'absence is a WARN (startup-only binaries), never a failure'
    }

    It 'the Primary is read-only by construction (parse + hash re-check, never written)' {
        ($script:Raw -match 'ReadAllBytes\(\$PrimaryConfig\)') | Should -BeTrue
        ($script:Raw -match 'this tool must be read-only on the Primary') | Should -BeTrue
    }
}

Describe 'OpenCode config sync child - functional fixture homes' {
    BeforeAll {
        $script:Child = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\sync_opencode_config.ps1")).Path

        function New-PrimaryConfig {
            # a tiny jsonc Primary (comments exercise the jsonc-aware reader;
            # servers sit NESTED under mcp.servers - the real app shape)
            param([string]$Path)
            New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
            $text = @'
{
    // primary definitions (the only source)
    "mcp": {
        "servers": {
            "probe-server": { "type": "stdio", "command": ["node", "probe.mjs"], "environment": {}, "enabled": true }
        }
    }
}
'@
            [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
        }

        function New-CloneHome {
            # a fixture clone home with an existing config (c1-style)
            param([string]$CloneHome, [switch]$NoConfig, [switch]$HoldLock, [switch]$WithSvcLog)
            New-Item -ItemType Directory -Path (Join-Path $CloneHome 'config\opencode') -Force | Out-Null
            if (-not $NoConfig) {
                [System.IO.File]::WriteAllText((Join-Path $CloneHome 'config\opencode\opencode.json'),
                    '{"mcp": {"servers": {}}}', (New-Object System.Text.UTF8Encoding($false)))
            }
            if ($HoldLock) {
                $lf = Join-Path $CloneHome 'desktop\lockfile'
                New-Item -ItemType Directory -Path (Split-Path -Parent $lf) -Force | Out-Null
                [System.IO.File]::WriteAllText($lf, 'held', (New-Object System.Text.UTF8Encoding($false)))
            }
            if ($WithSvcLog) {
                $logDir = Join-Path $CloneHome 'data\opencode\log'
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
                # two historical events: the probe must report NOT observed
                # (no NEW event fired by a fixture - there is no real service)
                [System.IO.File]::WriteAllText((Join-Path $logDir 'opencode.log'),
                    "timestamp=2026-11-22T00:00:00.000Z level=INFO run=a message=event event.type=config.updated`r`ntimestamp=2026-11-22T00:00:01.000Z level=INFO run=a message=event event.type=config.updated`r`n",
                    (New-Object System.Text.UTF8Encoding($false)))
            }
        }

        function Invoke-Child {
            param([string]$Primary, [string]$ClonesRoot, [switch]$DryRun, [switch]$SkipRunning)
            $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Child,
                '-PrimaryConfig', $Primary, '-ClonesRoot', $ClonesRoot, '-Target', 'All',
                '-ReloadProbeSeconds', '2')
            if ($DryRun) { $args += '-DryRun' }
            if ($SkipRunning) { $args += '-SkipRunning' }
            $out = & powershell @args 2>&1
            return @{ Exit = $LASTEXITCODE; Text = ($out -join "`n") }
        }
    }

    It 'a closed clone is synced: backup + merge + verify-after + audit land' {
        $root = Join-Path $env:TEMP ("ghost-ocsync-" + [guid]::NewGuid().ToString('N'))
        $pri = Join-Path $root 'primary.jsonc'
        New-PrimaryConfig -Path $pri
        $c1 = Join-Path $root 'OpenCodeClonesHome\c1'
        New-CloneHome -CloneHome $c1
        try {
            $r = Invoke-Child -Primary $pri -ClonesRoot (Join-Path $root 'OpenCodeClonesHome')
            $r.Exit | Should -Be 0
            ($r.Text -match 'wrote \+ verified') | Should -BeTrue
            # the merge landed (nested shape: mcp.servers.probe-server)
            $cfg = [System.IO.File]::ReadAllText((Join-Path $c1 'config\opencode\opencode.json')) | ConvertFrom-Json
            $cfg.mcp.servers.'probe-server'.enabled | Should -Be $true
            # backup + audit artifacts
            (@(Get-ChildItem $c1 -Filter 'config-pre-sync-*.json')).Count | Should -Be 1
            $audit = Get-Content (Join-Path $c1 'config-sync-audit.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            $audit.changed | Should -Contain 'mcp.servers.probe-server'
            $audit.verified | Should -BeTrue
            $audit.running | Should -BeFalse
            # the write left no atomic temp file behind
            (Test-Path -LiteralPath (Join-Path $c1 'config\opencode\opencode.json.ghost-tmp')) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a RUNNING clone (lockfile held) is SYNCED by default; the reload probe reports NOT observed' {
        $root = Join-Path $env:TEMP ("ghost-ocsync-run-" + [guid]::NewGuid().ToString('N'))
        $pri = Join-Path $root 'primary.jsonc'
        New-PrimaryConfig -Path $pri
        $clones = Join-Path $root 'OpenCodeClonesHome'
        $c2 = Join-Path $clones 'c2'
        New-CloneHome -CloneHome $c2 -HoldLock -WithSvcLog
        # hold the lockfile EXACTLY like the running app does: exclusive open
        $fs = [System.IO.File]::Open((Join-Path $c2 'desktop\lockfile'), 'Open', 'Read', 'None')
        try {
            $r = Invoke-Child -Primary $pri -ClonesRoot $clones
            $r.Exit | Should -Be 0
            ($r.Text -match 'RUNNING \(lockfile held\) - syncing live') | Should -BeTrue
            # the merge landed on the running clone
            $cfg = [System.IO.File]::ReadAllText((Join-Path $c2 'config\opencode\opencode.json')) | ConvertFrom-Json
            $cfg.mcp.servers.'probe-server'.enabled | Should -Be $true
            # the reload probe saw NO new event (a fixture has no real service)
            ($r.Text -match 'reload NOT observed within 2s') | Should -BeTrue
            # audit carries the CS-7 fields
            $audit = Get-Content (Join-Path $c2 'config-sync-audit.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
            $audit.running | Should -BeTrue
            $audit.liveReload | Should -BeFalse
        } finally {
            $fs.Close()
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '-SkipRunning restores the old skip as an opt-out' {
        $root = Join-Path $env:TEMP ("ghost-ocskip-" + [guid]::NewGuid().ToString('N'))
        $pri = Join-Path $root 'primary.jsonc'
        New-PrimaryConfig -Path $pri
        $clones = Join-Path $root 'OpenCodeClonesHome'
        $c2 = Join-Path $clones 'c2'
        New-CloneHome -CloneHome $c2 -HoldLock
        $fs = [System.IO.File]::Open((Join-Path $c2 'desktop\lockfile'), 'Open', 'Read', 'None')
        try {
            $r = Invoke-Child -Primary $pri -ClonesRoot $clones -SkipRunning
            $r.Exit | Should -Be 0
            ($r.Text -match 'appears RUNNING \(lockfile held\) - SKIPPED \(-SkipRunning requested') | Should -BeTrue
            (@(Get-ChildItem $c2 -Filter 'config-pre-sync-*.json' -ErrorAction SilentlyContinue)).Count | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $c2 'config-sync-audit.jsonl')) | Should -BeFalse
            ([System.IO.File]::ReadAllText((Join-Path $c2 'config\opencode\opencode.json'))) | Should -Be '{"mcp": {"servers": {}}}'
        } finally {
            $fs.Close()
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a config-less clone stays skipped (the sync never creates one)' {
        $root = Join-Path $env:TEMP ("ghost-ocsync-fresh-" + [guid]::NewGuid().ToString('N'))
        $pri = Join-Path $root 'primary.jsonc'
        New-PrimaryConfig -Path $pri
        $clones = Join-Path $root 'OpenCodeClonesHome'
        New-CloneHome -CloneHome (Join-Path $clones 'c3') -NoConfig
        try {
            $r = Invoke-Child -Primary $pri -ClonesRoot $clones
            $r.Exit | Should -Be 0
            ($r.Text -match 'no config\\opencode config yet') | Should -BeTrue
            (Test-Path -LiteralPath (Join-Path $clones 'c3\config\opencode\opencode.json')) | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '-DryRun plans and writes NOTHING (no backup, no audit, config untouched)' {
        $root = Join-Path $env:TEMP ("ghost-ocsync-dry-" + [guid]::NewGuid().ToString('N'))
        $pri = Join-Path $root 'primary.jsonc'
        New-PrimaryConfig -Path $pri
        $clones = Join-Path $root 'OpenCodeClonesHome'
        $c1 = Join-Path $clones 'c1'
        New-CloneHome -CloneHome $c1
        try {
            $r = Invoke-Child -Primary $pri -ClonesRoot $clones -DryRun
            $r.Exit | Should -Be 0
            ($r.Text -match 'would apply') | Should -BeTrue
            (@(Get-ChildItem $c1 -Filter 'config-pre-sync-*.json' -ErrorAction SilentlyContinue)).Count | Should -Be 0
            (Test-Path -LiteralPath (Join-Path $c1 'config-sync-audit.jsonl')) | Should -BeFalse
            ([System.IO.File]::ReadAllText((Join-Path $c1 'config\opencode\opencode.json'))) | Should -Be '{"mcp": {"servers": {}}}'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'the Primary config is untouched after a real run (read-only contract)' {
        $root = Join-Path $env:TEMP ("ghost-ocsync-pri-" + [guid]::NewGuid().ToString('N'))
        $pri = Join-Path $root 'primary.jsonc'
        New-PrimaryConfig -Path $pri
        $before = (Get-Item -LiteralPath $pri).Length
        $clones = Join-Path $root 'OpenCodeClonesHome'
        New-CloneHome -CloneHome (Join-Path $clones 'c1')
        try {
            $r = Invoke-Child -Primary $pri -ClonesRoot $clones
            $r.Exit | Should -Be 0
            (Get-Item -LiteralPath $pri).Length | Should -Be $before
            (@(Get-ChildItem $root -Filter 'primary.jsonc*')).Count | Should -Be 1 -Because 'no backup/temp of the Primary may ever be created'
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
