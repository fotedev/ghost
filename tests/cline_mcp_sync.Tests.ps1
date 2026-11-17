# SPDX-License-Identifier: Apache-2.0
# Tests for tools/cline_mcp_merge.ps1 (pure merge core) + tools/sync_cline_mcp.ps1
# (the sync child) + the launcher/gid wiring. The merge invariant is the
# zcode_mcp_merge invariant adapted to Cline's per-server "disabled" flag
# (2026-11-17; the Primary's store verified auth-free on the dev host:
# {"mcpServers": {}}). The sync child is exercised FUNCTIONALLY against
# %TEMP% fixtures via its -PrimarySettings/-ClonesRoot overrides - the same
# acceptance shape docs/OPENCODE_CONFIG_SYNC_PLAN.md §5 uses for its sibling.

Describe 'Cline MCP merge core - script hygiene' {
    BeforeAll {
        $script:CorePath = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\cline_mcp_merge.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:CorePath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "cline_mcp_merge.ps1 does not parse: $($errors[0].Message)" }
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:CorePath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        ($text -match "(?<!`r)`n") | Should -BeFalse
    }
}

Describe 'Cline MCP merge core - the invariant' {
    BeforeAll {
        . (Resolve-Path (Join-Path $PSScriptRoot "..\tools\cline_mcp_merge.ps1")).Path

        function New-Server([string]$Name, [string]$Command, [string[]]$ArgList = @(), $Extra = $null) {
            $o = [ordered]@{ command = $Command; args = $ArgList }
            if ($Extra) { foreach ($k in $Extra.Keys) { $o[$k] = $Extra[$k] } }
            return [pscustomobject]$o
        }
        $script:NewServer = ${function:New-Server}
    }

    It 'a server new to the clone is added with the full Primary definition' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx' @('-y', 'fs')) } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        $changed = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $changed | Should -Be @('fs')
        $c.mcpServers.fs.command | Should -Be 'npx'
    }

    It 'a Primary definition update overwrites the clone definition' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'node' @('new.js')) } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'node' @('old.js')) } }
        $changed = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $changed | Should -Be @('fs')
        $c.mcpServers.fs.args | Should -Be 'new.js'
    }

    It 'an unchanged Primary definition leaves the clone alone (already in sync)' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx') } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx') } }
        $changed = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $changed | Should -BeNullOrEmpty
    }

    It 'the clone-local disabled=true survives a Primary definition update' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'node' @('new.js')) } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'node' @('old.js') @{ disabled = $true }) } }
        $null = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $c.mcpServers.fs.args | Should -Be 'new.js'
        $c.mcpServers.fs.disabled | Should -BeTrue
    }

    It 'the clone-local disabled=false (explicit) also survives' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx' @() @{ disabled = $true }) } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx' @() @{ disabled = $false }) } }
        $changed = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        # The Primary's disabled toggle is stripped from the definition, so the
        # clone's explicit disabled=false makes the effective maps IDENTICAL ->
        # already in sync (the merge never forces a Primary toggle onto an
        # existing clone server - that is the invariant).
        $changed | Should -BeNullOrEmpty
        $c.mcpServers.fs.disabled | Should -BeFalse
    }

    It 'a new server with no Primary disabled flag carries none (app default = enabled)' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx') } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        $null = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $c.mcpServers.fs.PSObject.Properties['disabled'] | Should -BeNullOrEmpty
    }

    It 'a new server carries the Primary disabled=true through (a Primary-disabled server lands disabled)' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx' @() @{ disabled = $true }) } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        $null = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $c.mcpServers.fs.disabled | Should -BeTrue
    }

    It 'clone-only servers are never removed' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx') } }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx'); local_only = (New-Server 'local_only' 'cmd') } }
        $changed = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $changed | Should -BeNullOrEmpty
        $c.mcpServers.local_only | Should -Not -BeNullOrEmpty
    }

    It 'a zero-server Primary changes nothing and mutates nothing' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx') } }
        $changed = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        $changed | Should -BeNullOrEmpty
        @($c.mcpServers.PSObject.Properties).Count | Should -Be 1
    }

    It 'the Primary object is never mutated by the merge' {
        $p = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx' @() @{ disabled = $true }) } }
        $before = ConvertTo-DeepHashtable ($p | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $c = [pscustomobject]@{ mcpServers = [pscustomobject]@{ fs = (New-Server 'fs' 'npx') } }
        $null = Invoke-ClineMcpMerge -PrimaryServers $p.mcpServers -CloneServers $c.mcpServers
        (Test-DeepEqual (ConvertTo-DeepHashtable ($p | ConvertTo-Json -Depth 10 | ConvertFrom-Json)) $before) | Should -BeTrue
    }

    It 'Write-JsonNoBom round-trips without a BOM' {
        $tmp = Join-Path $env:TEMP ("cline-merge-test-{0}.json" -f [guid]::NewGuid().ToString('N'))
        try {
            Write-JsonNoBom -Path $tmp -Object ([pscustomobject]@{ mcpServers = [pscustomobject]@{} })
            $bytes = [System.IO.File]::ReadAllBytes($tmp)
            ($bytes[0] -eq 0xEF) | Should -BeFalse
            { (Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json).PSObject.Properties['mcpServers'] } | Should -Not -Throw
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Cline MCP sync child - functional fixture runs' {
    BeforeAll {
        $script:ChildPath = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\sync_cline_mcp.ps1")).Path
        $script:PsExe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')

        function New-FixtureTree {
            $root = Join-Path $env:TEMP ("cline-mcp-fixture-{0}" -f [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $root 'primary\data\settings') -Force | Out-Null
            foreach ($c in @('c1', 'c2', 'c3')) {
                New-Item -ItemType Directory -Path (Join-Path $root "clones\$c\data\settings") -Force | Out-Null
            }
            return $root
        }
        function Invoke-Child([string]$PrimaryFile, [string]$ClonesDir, [string[]]$Extra = @()) {
            $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:ChildPath,
                '-PrimarySettings', $PrimaryFile, '-ClonesRoot', $ClonesDir) + $Extra
            $out = & $script:PsExe @args 2>&1
            return @{ Exit = $LASTEXITCODE; Out = (@($out) | ForEach-Object { "$_" }) -join "`n" }
        }
    }

    It 'syncs a fresh clone: creates the auth-free store, applies the Primary set, audits' {
        $root = New-FixtureTree
        try {
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            @'
{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "fs"], "disabled": true}, "git": {"command": "uvx", "args": ["mcp-git"]}}}
'@ | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $r = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1')
            $r.Exit | Should -Be 0
            $c1File = Join-Path $root 'clones\c1\data\settings\cline_mcp_settings.json'
            Test-Path $c1File | Should -BeTrue
            $cfg = Get-Content -LiteralPath $c1File -Raw | ConvertFrom-Json
            @($cfg.mcpServers.PSObject.Properties).Count | Should -Be 2
            $cfg.mcpServers.fs.disabled | Should -BeTrue
            $cfg.mcpServers.git.disabled | Should -BeNullOrEmpty
            (Test-Path (Join-Path $root 'clones\c1\mcp-sync-audit.jsonl')) | Should -BeTrue
            $audit = Get-Content (Join-Path $root 'clones\c1\mcp-sync-audit.jsonl') -Raw | ConvertFrom-Json
            $audit.created | Should -BeTrue
            ($audit.changed -join ',') | Should -Be 'fs,git'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'an existing clone definition + local disabled survive; clone-only server kept; backup written' {
        $root = New-FixtureTree
        try {
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {"fs": {"command": "node", "args": ["new.js"]}}}' | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $c1File = Join-Path $root 'clones\c1\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {"fs": {"command": "node", "args": ["old.js"], "disabled": true}, "localonly": {"command": "cmd", "args": ["/c", "x"]}}}' |
                Set-Content -LiteralPath $c1File -Encoding Ascii
            $r = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1')
            $r.Exit | Should -Be 0
            $cfg = Get-Content -LiteralPath $c1File -Raw | ConvertFrom-Json
            $cfg.mcpServers.fs.args | Should -Be 'new.js'
            $cfg.mcpServers.fs.disabled | Should -BeTrue
            $cfg.mcpServers.localonly | Should -Not -BeNullOrEmpty
            $backups = @(Get-ChildItem (Join-Path $root 'clones\c1\data\settings') -Filter 'cline_mcp_settings-pre-sync-*.json')
            $backups.Count | Should -Be 1
            (Get-Content $backups[0].FullName -Raw | ConvertFrom-Json).mcpServers.fs.args | Should -Be 'old.js'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'dry-run writes nothing and prints the would-apply list' {
        $root = New-FixtureTree
        try {
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {"fs": {"command": "npx"}}}' | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $r = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1', '-DryRun')
            $r.Exit | Should -Be 0
            (Test-Path (Join-Path $root 'clones\c1\data\settings\cline_mcp_settings.json')) | Should -BeFalse
            $r.Out | Should -Match 'would CREATE'
            $r.Out | Should -Match 'fs'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'second run is idempotent (already in sync, no new backup)' {
        $root = New-FixtureTree
        try {
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {"fs": {"command": "npx"}}}' | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $r1 = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1')
            $r2 = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1')
            $r2.Exit | Should -Be 0
            $r2.Out | Should -Match 'already in sync'
            @(Get-ChildItem (Join-Path $root 'clones\c1\data\settings') -Filter 'cline_mcp_settings-pre-sync-*.json').Count | Should -Be 0
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a RUNNING clone (hub lock held) is skipped with a warning' {
        $root = New-FixtureTree
        try {
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {"fs": {"command": "npx"}}}' | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $lock = Join-Path $root 'clones\c1\data\locks\hub\production.json.instance.lock'
            New-Item -ItemType Directory -Path (Split-Path $lock -Parent) -Force | Out-Null
            Set-Content -LiteralPath $lock -Value 'x'
            $hold = [System.IO.File]::Open($lock, 'Open', 'Read', 'Read')
            try {
                $r = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1')
                $r.Exit | Should -Be 0
                $r.Out | Should -Match 'RUNNING \(hub lock held\) - SKIPPED'
                (Test-Path (Join-Path $root 'clones\c1\data\settings\cline_mcp_settings.json')) | Should -BeFalse
            } finally { $hold.Dispose() }
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a missing clone home is skipped; a no-clones root exits clean' {
        $root = New-FixtureTree
        try {
            Remove-Item (Join-Path $root 'clones\c1') -Recurse -Force
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {"fs": {"command": "npx"}}}' | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $r = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Instance', 'c1')
            $r.Exit | Should -Be 0
            $r.Out | Should -Match 'no clone home'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'an unparseable Primary fails loudly (never syncs from an invalid file)' {
        $root = New-FixtureTree
        try {
            $primaryFile = Join-Path $root 'primary\data\settings\cline_mcp_settings.json'
            '{"mcpServers": {' | Set-Content -LiteralPath $primaryFile -Encoding Ascii
            $r = Invoke-Child $primaryFile (Join-Path $root 'clones') @('-Target', 'All')
            $r.Exit | Should -Be 1
            $r.Out | Should -Match 'not parse'
        } finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Cline launcher + GHOST.bat/menu wiring' {
    BeforeAll {
        $script:LauncherPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_cline_clone.ps1")).Path
        $tokens = $null; $errors = $null
        $script:LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_cline_clone.ps1 does not parse: $($errors[0].Message)" }
        $script:LauncherRaw = [System.IO.File]::ReadAllText($script:LauncherPath)
        $script:Bat = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\GHOST.bat")).Path)
        $script:Menu = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot "..\src\desktop\menu.json")).Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It 'launcher pre-launch step [2b] runs the sync child -Quiet with the escape hatch' {
        ($script:LauncherRaw -match '\[2b\] Syncing Primary MCP settings') | Should -BeTrue
        ($script:LauncherRaw -match [regex]::Escape('sync_cline_mcp.ps1')) | Should -BeTrue
        ($script:LauncherRaw -match '-Quiet') | Should -BeTrue
        ($script:LauncherRaw -match 'SkipMcpSync') | Should -BeTrue
        # The step must run BEFORE the neutralize step (pre-launch, no race).
        $syncIdx = $script:LauncherRaw.IndexOf('[2b] Syncing Primary MCP settings')
        $neutIdx = $script:LauncherRaw.IndexOf('# --- Neutralize the single-instance window')
        $syncIdx | Should -BeGreaterThan 0
        $neutIdx | Should -BeGreaterThan $syncIdx
    }

    It 'a failed sync never blocks the launch (warn + continue)' {
        ($script:LauncherRaw -match 'must never block a launch') | Should -BeTrue
    }

    It 'resolver maps locals 18/19 to gids 112/113 and the dispatch cases run the sync child' {
        ($script:Bat -match '"18" set "RESOLVED=112"') | Should -BeTrue
        ($script:Bat -match '"19" set "RESOLVED=113"') | Should -BeTrue
        ($script:Bat -match '"112" \(call :Run "tools\\sync_cline_mcp\.ps1" -Target All') | Should -BeTrue
        ($script:Bat -match '"113" \(call :Run "tools\\sync_cline_mcp\.ps1" -Target All -DryRun') | Should -BeTrue
    }

    It 'menu.json Cline rows match the dispatch cases' {
        $r112 = @(($script:Menu.sections | Where-Object { $_.name -eq 'Cline' }).rows) | Where-Object { $_.gid -eq 112 }
        $r113 = @(($script:Menu.sections | Where-Object { $_.name -eq 'Cline' }).rows) | Where-Object { $_.gid -eq 113 }
        $r112.script | Should -Be 'tools/sync_cline_mcp.ps1'
        ($r112.args -join ' ') | Should -Be '-Target All'
        $r113.script | Should -Be 'tools/sync_cline_mcp.ps1'
        ($r113.args -join ' ') | Should -Be '-Target All -DryRun'
    }
}
