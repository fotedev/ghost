# SPDX-License-Identifier: Apache-2.0
# Tests for the Terminal Agents codex suite (2026-11-21):
# src/windows/launch_codex_light.ps1 + src/windows/reset_codex.ps1.
# Static contract pins + a FUNCTIONAL fixture-home reset (dry-run zero-write,
# real apply on a fake CODEX_HOME, idempotence via the fresh-home guard)
# through the real Python core.

Describe 'codex launcher - script hygiene + contract' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_codex_light.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_codex_light.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'instances are c1..c5 with the frozen per-color home layout' {
        ($script:Raw -match "\[ValidateSet\('c1', 'c2', 'c3', 'c4', 'c5'\)\]") | Should -BeTrue
        ($script:Raw -match 'CodexClonesHome\\c1') | Should -BeTrue
    }

    It 'isolates via CODEX_HOME (the Phase-0 live-verified single lever)' {
        ($script:Raw -match '\$env:CODEX_HOME = \$CloneHome') | Should -BeTrue
    }

    It 'writes the shared light-worker PID marker around every run mode' {
        ($script:Raw -match [regex]::Escape('ghost_light_marker.ps1')) | Should -BeTrue
        ($script:Raw -match "Suite 'codex'") | Should -BeTrue
        ($script:Raw -match 'Remove-GhostLightMarker') | Should -BeTrue
    }

    It 'probes the binary FUNCTIONALLY (--version must exit 0 reporting codex-cli N.N.N)' {
        ($script:Raw -match '--version') | Should -BeTrue
        ($script:Raw -match [regex]::Escape("match 'codex-cli\s+\d+\.\d+'")) | Should -BeTrue -Because 'the live-verified version shape (codex-cli 0.166.0), never a bare path hit'
    }

    It 'is honest about the no-free-model limit and the -Yolo flag' {
        ($script:Raw -match 'no free-model fallback') | Should -BeTrue
        ($script:Raw -match '--yolo') | Should -BeTrue
    }

    It 'login verify-after checks auth.json inside the clone home' {
        ($script:Raw -match 'auth\.json') | Should -BeTrue
        ($script:Raw -match '& \$CodexExe login') | Should -BeTrue
    }

    It '-Status reads the shared suite status lib (codex suite)' {
        ($script:Raw -match 'suite_status_lib\.ps1') | Should -BeTrue
        ($script:Raw -match "-Suite 'codex'") | Should -BeTrue
    }

    It '-Status climbs TWO levels to the repo root for the lib (live-caught 2026-11-21: src\windows is two deep)' {
        ($script:Raw -match [regex]::Escape('Split-Path (Split-Path $PSScriptRoot -Parent) -Parent')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('Join-Path $PSScriptRoot ''..\tools\suite_status_lib.ps1''')) | Should -BeFalse -Because 'a one-level climb lands in src\tools (nonexistent) and the dot-source dies'
    }

    It 'the one-shot mode is codex exec with stdin CLOSED (codex exec reads stdin - live-verified)' {
        ($script:Raw -match "'exec'") | Should -BeTrue
        ($script:Raw -match '--skip-git-repo-check') | Should -BeTrue
        ($script:Raw -match [regex]::Escape('$null | & $CodexExe @runArgs')) | Should -BeTrue -Because 'an open console pipe would stall the run ("Reading additional input from stdin...")'
    }

    It 'documents the honest limits: auth failure (not a hang) and the shared skills store' {
        ($script:Raw -match 'does NOT hang silently') | Should -BeTrue -Because 'unlike claude-code, the unauthenticated exec fails loudly (live-captured)'
        ($script:Raw -match '~\\\.agents') | Should -BeTrue -Because 'skills come from the SHARED agents store - not isolated per clone home'
    }
}

Describe 'codex resetter - script hygiene + planner contract' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\reset_codex.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "reset_codex.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'the dry-run planner runs FIRST and exits before any mutation (W1-9 shape)' {
        $planAt = $script:Raw.IndexOf('DRY-RUN PLAN')
        $bannerAt = $script:Raw.IndexOf('Write-GhostBanner -Target')
        ($planAt -ge 0 -and $bannerAt -gt $planAt) | Should -BeTrue -Because 'a plan must never mutate'
        ($script:Raw -match 'DRY-RUN complete - nothing was written or killed\.') | Should -BeTrue
    }

    It 'never self-elevates (everything is user-scope)' {
        ($script:Raw -match 'RunAs|IsInRole|Administrator') | Should -BeFalse
    }

    It 'never kills processes and warns about the open-SQLite-handle race instead' {
        ($script:Raw -match 'Stop-Process|taskkill') | Should -BeFalse
        ($script:Raw -match 'holds SQLite handles') | Should -BeTrue
    }

    It 'targets the evidence-based identity anchors only (auth.json + installation_id + cap_sid)' {
        foreach ($f in @('auth\.json', 'installation_id', 'cap_sid')) {
            ($script:Raw -match $f) | Should -BeTrue
        }
        # the runtime SQLite sweep is prefix-scoped so the preserved stores can
        # never fall into the pattern
        foreach ($flt in @('state_\*\.sqlite\*', 'logs_\*\.sqlite\*', 'goals_\*\.sqlite\*', 'queue_\*\.sqlite\*')) {
            ($script:Raw -match $flt) | Should -BeTrue
        }
        ($script:Raw -match 'memories_') | Should -BeTrue -Because 'memories_*.sqlite is PRESERVED (named in the plan output)'
        ($script:Raw -match 'thread_history_') | Should -BeTrue -Because 'thread_history_*.sqlite is PRESERVED (named in the plan output)'
    }

    It 'has NO layout asymmetry: Primary and clones both consolidate inside the home' {
        ($script:Raw -match 'LAYOUT-ASYMMETRIC') | Should -BeFalse -Because 'codex has no profile-root JSON - CODEX_HOME only moves where inside is'
        ($script:Raw -match 'Join-Path \$UserProfile "\.codex"') | Should -BeTrue
    }

    It 'refuses a fresh/never-run home loudly (both identity anchors absent)' {
        ($script:Raw -match 'fresh/never-run home') | Should -BeTrue
    }

    It 'preserves config.toml, AGENTS.md and the desktop app state (named in the plan output)' {
        foreach ($f in @('config\.toml', 'AGENTS\.md', '\.codex-global-state\.json', 'session_index\.jsonl')) {
            ($script:Raw -match $f) | Should -BeTrue
        }
    }
}

Describe 'codex resetter - functional fixture-home reset' {
    BeforeAll {
        $script:Resetter = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\reset_codex.ps1")).Path
        $script:Fixture = Join-Path $env:TEMP ("ghost-cx-reset-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Fixture -Force | Out-Null

        function New-FixtureHome {
            # a fake CODEX_HOME-shaped home (the consolidated layout - the
            # Phase-0 probed file set)
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'sessions\2026\01\01') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture '.sandbox') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture '.tmp') -Force | Out-Null
            Set-Content -Path (Join-Path $script:Fixture 'sessions\2026\01\01\rollout-x.jsonl') -Value '{"v":1}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'auth.json') -Value '{"OPENAI_API_KEY":"sk-FAKE-not-a-real-key","auth_mode":"api"}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'installation_id') -Value 'ca7e55d7-b7f7-40ae-abb0-66c5d156d07f' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'cap_sid') -Value 'sid-fake' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'config.toml') -Value "model = `"gpt-test`"`nnotify = `"noop`"" -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'AGENTS.md') -Value '# user instructions' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture '.codex-global-state.json') -Value '{"desktop-first-seen-at-ms":1}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'history.jsonl') -Value '{"text":"hi"}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'session_index.jsonl') -Value '{"id":"x"}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'version.json') -Value '{"latest_version":"0.0.0"}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture '.sandbox_migration') -Value '1' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture '.sandbox\sandbox.log') -Value 'log' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture '.tmp\junk.bin') -Value 'junk' -Encoding Ascii
            foreach ($store in @('state_5', 'logs_2', 'goals_1', 'queue_1', 'memories_1', 'thread_history_1')) {
                Set-Content -Path (Join-Path $script:Fixture ("$store.sqlite")) -Value 'sqlite' -Encoding Ascii
            }
            Set-Content -Path (Join-Path $script:Fixture 'state_5.sqlite-wal') -Value 'wal' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'state_5.sqlite-shm') -Value 'shm' -Encoding Ascii
        }
    }

    It 'dry-run writes NOTHING to the fixture home' {
        New-FixtureHome
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Resetter -CodexDir $script:Fixture -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'DRY-RUN complete - nothing was written'
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'auth.json')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'installation_id')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'state_5.sqlite')) | Should -BeTrue
    }

    It 'a real run removes the credential + install id + runtime stores, PRESERVES config/chats/memories' {
        New-FixtureHome
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Resetter -CodexDir $script:Fixture 2>&1
        $LASTEXITCODE | Should -Be 0
        $text = $out -join "`n"
        # identity + runtime GONE
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'auth.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'installation_id')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'cap_sid')) | Should -BeFalse
        foreach ($gone in @('state_5.sqlite', 'state_5.sqlite-wal', 'state_5.sqlite-shm', 'logs_2.sqlite', 'goals_1.sqlite', 'queue_1.sqlite', 'version.json', '.sandbox_migration')) {
            (Test-Path -LiteralPath (Join-Path $script:Fixture $gone)) | Should -BeFalse
        }
        (Test-Path -LiteralPath (Join-Path $script:Fixture '.sandbox\sandbox.log')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture '.tmp\junk.bin')) | Should -BeFalse
        # config/chat/memory surfaces PRESERVED
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'config.toml')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'AGENTS.md')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture '.codex-global-state.json')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'history.jsonl')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'session_index.jsonl')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'sessions\2026\01\01\rollout-x.jsonl')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'memories_1.sqlite')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'thread_history_1.sqlite')) | Should -BeTrue
        # backup + audit artifacts landed
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'ID_Backups')) | Should -BeTrue
        ($text -match 'FRESH identity') | Should -BeTrue
    }

    It 'a second run hits the fresh-home guard loudly (anchors deleted, not key-scrubbed) and still preserves everything' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Resetter -CodexDir $script:Fixture 2>&1
        $LASTEXITCODE | Should -Be 1
        $text = $out -join "`n"
        ($text -match 'fresh/never-run home') | Should -BeTrue -Because 'the anchors are deleted by a real reset - a rerun is a fresh home by definition'
        # the guard fires BEFORE any write: nothing new swept, nothing lost
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'config.toml')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'memories_1.sqlite')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'ID_Backups')) | Should -BeTrue
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
