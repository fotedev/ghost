# SPDX-License-Identifier: Apache-2.0
# Tests for the Terminal Agents claude-code pilot (2026-11-21):
# src/windows/launch_claude_code_light.ps1 + src/windows/reset_claude_code.ps1.
# Static contract pins + a FUNCTIONAL fixture-home reset (dry-run zero-write,
# real apply on a fake config dir, idempotence) through the real Python core.

Describe 'claude-code launcher - script hygiene + contract' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_claude_code_light.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_claude_code_light.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'instances are c1..c5 with the frozen per-color home layout' {
        ($script:Raw -match "\[ValidateSet\('c1', 'c2', 'c3', 'c4', 'c5'\)\]") | Should -BeTrue
        ($script:Raw -match 'ClaudeCodeClonesHome\\c1') | Should -BeTrue
    }

    It 'isolates via CLAUDE_CONFIG_DIR (the Phase-0 live-verified single lever)' {
        ($script:Raw -match '\$env:CLAUDE_CONFIG_DIR = \$CloneHome') | Should -BeTrue
    }

    It 'writes the shared light-worker PID marker around every run mode' {
        ($script:Raw -match [regex]::Escape('ghost_light_marker.ps1')) | Should -BeTrue
        ($script:Raw -match "Suite 'claudecode'") | Should -BeTrue
        ($script:Raw -match 'Remove-GhostLightMarker') | Should -BeTrue
    }

    It 'probes the binary FUNCTIONALLY (--version must exit 0 reporting a version)' {
        ($script:Raw -match '--version') | Should -BeTrue
        ($script:Raw -match [regex]::Escape("match '^\d+\.\d+'")) | Should -BeTrue -Because 'the version-shape gate, never a bare path hit'
    }

    It 'is honest about the no-free-model limit and the -Yolo permission flag' {
        ($script:Raw -match 'no free-model fallback') | Should -BeTrue
        ($script:Raw -match '--dangerously-skip-permissions') | Should -BeTrue
    }

    It 'login verify-after checks .credentials.json inside the clone home' {
        ($script:Raw -match '\.credentials\.json') | Should -BeTrue
        ($script:Raw -match 'auth login') | Should -BeTrue
    }

    It '-Status reads the shared suite status lib (claudecode suite)' {
        ($script:Raw -match 'suite_status_lib\.ps1') | Should -BeTrue
        ($script:Raw -match "-Suite 'claudecode'") | Should -BeTrue
    }
}

Describe 'claude-code resetter - script hygiene + planner contract' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\reset_claude_code.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "reset_claude_code.ps1 does not parse: $($errors[0].Message)" }
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

    It 'never kills processes (no lockfiles) and warns about the rewrite-on-exit race instead' {
        ($script:Raw -match 'Stop-Process|taskkill') | Should -BeFalse
        ($script:Raw -match 'rewrite \.claude\.json on exit') | Should -BeTrue
    }

    It 'targets the evidence-based identity/telemetry key list only' {
        foreach ($k in @('machineID', 'userID', 'firstStartTime', 'numStartups', 'skillUsage', 'pluginUsage')) {
            ($script:Raw -match ('"' + $k + '"')) | Should -BeTrue
        }
        ($script:Raw -match 'mcpServers') | Should -BeTrue -Because 'mcpServers config is PRESERVED (named in the plan output)'
    }

    It 'handles the layout asymmetry: Primary JSON at the profile root, clone JSON inside the home' {
        ($script:Raw -match 'LAYOUT-ASYMMETRIC') | Should -BeTrue
        ($script:Raw -match 'Join-Path \$UserProfile "\.claude\.json"') | Should -BeTrue
    }

    It 'respects the user-made-backup exclusion (~\.claude.json.bak-<name>)' {
        ($script:Raw -match 'bak-') | Should -BeTrue
    }
}

Describe 'claude-code resetter - functional fixture-home reset' {
    BeforeAll {
        $script:Resetter = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\reset_claude_code.ps1")).Path
        $script:Fixture = Join-Path $env:TEMP ("ghost-cc-reset-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Fixture -Force | Out-Null

        function New-JsonFile {
            param([string]$Path, [hashtable]$Data)
            ($Data | ConvertTo-Json -Depth 5) | Set-Content -Path $Path -Encoding Ascii
        }

        function New-FixtureHome {
            # a fake CLAUDE_CONFIG_DIR-shaped home (the consolidated layout)
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'backups') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'state') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'cache') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:Fixture 'projects') -Force | Out-Null
            Set-Content -Path (Join-Path $script:Fixture 'projects\transcript.jsonl') -Value '{"v":1}' -Encoding Ascii
            New-JsonFile (Join-Path $script:Fixture '.claude.json') @{
                machineID          = 'deadbeef00000000000000000000000000000000000000000000000000000000'
                userID             = 'user-1111'
                numStartups        = 42
                firstStartTime     = '2026-01-01T00:00:00.000Z'
                tipsHistory        = @('t1')
                skillUsage         = @{ a = 1 }
                mcpServers         = @{ playwright = @{ type = 'stdio'; command = 'npx' } }
                projects           = @{ 'C:\proj' = @{ history = @() } }
                hasCompletedOnboarding = $true
                migrationVersion   = 1
            }
            Set-Content -Path (Join-Path $script:Fixture '.credentials.json') -Value '{"token":"x"}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'backups\.claude.json.backup.123') -Value '{"machineID":"old"}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'state\mcp-discover-verdicts.json') -Value '{}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'mcp-needs-auth-cache.json') -Value '{}' -Encoding Ascii
            Set-Content -Path (Join-Path $script:Fixture 'settings.json') -Value '{"env":{}}' -Encoding Ascii
        }

        function Get-JsonKeys {
            param([string]$Path)
            if (-not (Test-Path -LiteralPath $Path)) { return @() }
            return @((Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).PSObject.Properties.Name)
        }
    }

    It 'dry-run writes NOTHING to the fixture home' {
        New-FixtureHome
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Resetter -ConfigDir $script:Fixture -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        ($out -join "`n") | Should -Match 'DRY-RUN complete - nothing was written'
        (Test-Path -LiteralPath (Join-Path $script:Fixture '.credentials.json')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture '.claude.json')) | Should -BeTrue
        (Get-JsonKeys (Join-Path $script:Fixture '.claude.json')) | Should -Contain 'machineID'
    }

    It 'a real run scrubs identity keys + credentials, sweeps remnants, PRESERVES chats/config' {
        New-FixtureHome
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Resetter -ConfigDir $script:Fixture 2>&1
        $LASTEXITCODE | Should -Be 0
        $text = $out -join "`n"
        $keys = Get-JsonKeys (Join-Path $script:Fixture '.claude.json')
        # identity + telemetry GONE
        foreach ($gone in @('machineID', 'userID', 'numStartups', 'firstStartTime', 'tipsHistory', 'skillUsage')) {
            $keys | Should -Not -Contain $gone
        }
        # config PRESERVED
        foreach ($kept in @('mcpServers', 'projects', 'hasCompletedOnboarding', 'migrationVersion')) {
            $keys | Should -Contain $kept
        }
        # credentials + remnants GONE
        (Test-Path -LiteralPath (Join-Path $script:Fixture '.credentials.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'backups\.claude.json.backup.123')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'state\mcp-discover-verdicts.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'mcp-needs-auth-cache.json')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'cache')) | Should -BeFalse
        # chat/config surfaces PRESERVED
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'projects\transcript.jsonl')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'settings.json')) | Should -BeTrue
        # backup + audit artifacts landed
        (Test-Path -LiteralPath (Join-Path $script:Fixture 'ID_Backups')) | Should -BeTrue
        ($text -match 'fresh machineID') | Should -BeTrue
    }

    It 'is idempotent - a second run is all verified no-ops and still exits 0' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Resetter -ConfigDir $script:Fixture 2>&1
        $LASTEXITCODE | Should -Be 0
        $text = $out -join "`n"
        ($text -match 'already logged out') | Should -BeTrue
        ($text -match 'no-op') | Should -BeTrue
        (Get-JsonKeys (Join-Path $script:Fixture '.claude.json')) | Should -Not -Contain 'machineID'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:Fixture -Recurse -Force -ErrorAction SilentlyContinue
    }
}
