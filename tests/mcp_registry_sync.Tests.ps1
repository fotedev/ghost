#Requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Unit tests for the MCP central registry pieces added with the claude-code +
# codex targets (2026-11-07):
#   - tools\mcp\codex_toml.ps1  (pure TOML reader/writer for [mcp_servers.*])
#   - tools\mcp\master-mcp.json invariants (parseable; every entry has command
#     or url; NO literal secret values - only ${VAR} placeholders / statics)
#   - tools\mcp\master-mcp.local.json parses (gitignored overlay)
# The sync script itself is NOT dot-sourced (it has a main body that would run
# and touch live configs) - these tests exercise the pure module and the
# registry files only, never any live app config.

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\zcode_mcp_merge.ps1')
    . (Join-Path $PSScriptRoot '..\tools\mcp\codex_toml.ps1')
    $ErrorActionPreference = $prevEap

    $script:MasterPath = Join-Path $PSScriptRoot '..\tools\mcp\master-mcp.json'
    $script:OverlayPath = Join-Path $PSScriptRoot '..\tools\mcp\master-mcp.local.json'
}

Describe 'codex_toml module (dot-sourced)' {
    It 'dot-sourcing defines the pure TOML functions' {
        Get-Command ConvertFrom-TomlValue      -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertFrom-CodexTomlText  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-TomlLiteral      -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-TomlValue        -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-CodexTomlSection -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Write-CodexTomlFile        -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertFrom-CodexTomlText (light TOML parser)' {
    It 'parses mcp_servers tables into the synthetic JSON-shaped view' {
        $toml = @'
model = "gpt-5"

[mcp_servers.alpha]
command = 'C:\tools\a.exe'
args = ['--flag', 'value with spaces']

[mcp_servers.alpha.env]
TOKEN = 'abc'
COUNT = "7"

[mcp_servers.beta]
command = 'npx'

[projects.'c:\work']
trust_level = "trusted"
'@
        $root = ConvertFrom-CodexTomlText $toml
        $root.mcp_servers.alpha.command | Should -Be 'C:\tools\a.exe'
        @($root.mcp_servers.alpha.args).Count    | Should -Be 2
        $root.mcp_servers.alpha.args[1]          | Should -Be 'value with spaces'
        $root.mcp_servers.alpha.env.TOKEN        | Should -Be 'abc'
        $root.mcp_servers.alpha.env.COUNT        | Should -Be '7'   # double-quoted = string, not number
        $root.mcp_servers.beta.command           | Should -Be 'npx'
        $root.mcp_servers.PSObject.Properties['projects'] | Should -BeNullOrEmpty
        $root.mcp_servers.PSObject.Properties['model']    | Should -BeNullOrEmpty
    }

    It 'preserves value types: integers, booleans, empty arrays' {
        $toml = @'
[mcp_servers.gamma]
command = 'x'
args = []
retries = 3
strict = true
'@
        $e = (ConvertFrom-CodexTomlText $toml).mcp_servers.gamma
        @($e.args).Count       | Should -Be 0
        $e.retries             | Should -Be 3
        $e.strict              | Should -Be $true
    }

    It 'stops capturing at the first non-mcp_servers table' {
        $toml = @'
[mcp_servers.a]
command = 'x'

[something_else]
key = 'value'

[mcp_servers.b.env]
K = 'v'
'@
        $root = ConvertFrom-CodexTomlText $toml
        $root.mcp_servers.PSObject.Properties['a'] | Should -Not -BeNullOrEmpty
        # [mcp_servers.b.env] without a parent [mcp_servers.b] still yields b.env
        $root.mcp_servers.b.env.K | Should -Be 'v'
        $root.mcp_servers.PSObject.Properties['something_else'] | Should -BeNullOrEmpty
    }

    It 'tolerates comments and blank lines' {
        $toml = @'
# top comment
[mcp_servers.a]   # trailing comment
command = 'x'     # another

[mcp_servers.a.env]
# nested comment
K = 'v'
'@
        $e = (ConvertFrom-CodexTomlText $toml).mcp_servers.a
        $e.command | Should -Be 'x'
        $e.env.K   | Should -Be 'v'
    }
}

Describe 'ConvertTo-CodexTomlSection / Write-CodexTomlFile (writer)' {
    It 'refuses server names that are not TOML bare keys' {
        { ConvertTo-CodexTomlSection 'bad.name' ([pscustomobject]@{ command = 'x' }) } | Should -Throw '*bare key*'
    }

    It 'round-trips: write -> parse yields an equal tree (order-insensitive)' {
        $toml = @'
model = "gpt-5"
notify = ['C:\n.exe']

[mcp_servers.alpha]
command = 'C:\tools\a.exe'
args = ['--flag']
startup_timeout_sec = 120

[mcp_servers.alpha.env]
PATHISH = 'C:\x\y'
FLAG = '1'
'@
        $root = ConvertFrom-CodexTomlText $toml
        $path = Join-Path $TestDrive 'config.toml'
        Write-CodexTomlFile -Path $path -WorkRoot $root -OriginalText $toml
        $back = ConvertFrom-CodexTomlText ([System.IO.File]::ReadAllText($path))
        $equal = Test-DeepEqual (ConvertTo-DeepHashtable $root) (ConvertTo-DeepHashtable $back)
        $equal | Should -Be $true -Because 'a full round-trip must be lossless for mcp_servers content'
    }

    It 'preserves non-mcp_servers content verbatim (comments, other tables)' {
        $toml = @'
# keep me
model = "gpt-5"

[projects.'c:\work']
trust_level = "trusted"

[mcp_servers.old]
command = 'gone'
'@
        $root = ConvertFrom-CodexTomlText @'
[mcp_servers.new]
command = 'here'
'@
        $path = Join-Path $TestDrive 'config.toml'
        Write-CodexTomlFile -Path $path -WorkRoot $root -OriginalText $toml
        $text = [System.IO.File]::ReadAllText($path)
        $text | Should -Match '# keep me'
        $text | Should -Match 'model = "gpt-5"'
        $text | Should -Match "\[projects\.'c:\\work'\]"
        $text | Should -Match 'trust_level = "trusted"'
        $text | Should -Not -Match 'command = ''gone'''
        $text | Should -Match "\[mcp_servers\.new\]"
    }

    It 'writes literal strings for backslash paths and quoted strings when needed' {
        $lines = ConvertTo-CodexTomlSection 'x' ([pscustomobject]@{ command = 'C:\a\b.exe'; note = "it's" })
        ($lines -join "`n") | Should -Match "command = 'C:\\a\\b\.exe'"
        ($lines -join "`n") | Should -Match 'note = "it''s"'
    }
}

Describe 'master-mcp.json registry invariants' {
    BeforeAll {
        $script:Master = Get-Content $script:MasterPath -Raw | ConvertFrom-Json
    }

    It 'parses and has an mcpServers container' {
        $script:Master.mcpServers | Should -Not -BeNullOrEmpty
    }

    It 'every entry has exactly one of command / url' {
        foreach ($p in @($script:Master.mcpServers.PSObject.Properties)) {
            $e = $p.Value
            $hasCmd = ($null -ne $e.PSObject.Properties['command'])
            $hasUrl = ($null -ne $e.PSObject.Properties['url'])
            ($hasCmd -or $hasUrl) | Should -Be $true -Because "entry '$($p.Name)' needs a transport"
        }
    }

    It 'env/headers carry ${VAR} placeholders or harmless statics - never literal secrets' {
        foreach ($p in @($script:Master.mcpServers.PSObject.Properties)) {
            foreach ($mapName in @('env', 'headers')) {
                $mp = $p.Value.PSObject.Properties[$mapName]
                if ($null -eq $mp) { continue }
                foreach ($kv in @($mp.Value.PSObject.Properties)) {
                    $v = [string]$kv.Value
                    $isPlaceholder = $v -like '${*}'
                    $isTokenShaped = ($v.Length -ge 32 -and $v -match '^[A-Za-z0-9_\-\.=+/]+$')
                    $isTokenShaped | Should -Be $false -Because "'$($p.Name).$mapName.$($kv.Name)' looks like a literal secret"
                    if (-not $isPlaceholder) {
                        ($v.Length -lt 64) | Should -Be $true -Because "'$($p.Name).$mapName.$($kv.Name)' static values must be short config constants"
                    }
                }
            }
        }
    }

    It 'scoping keys only reference real sync targets or reserved non-target app names' {
        $known = @('cursor', 'windsurf', 'vscode', 'zcode', 'minimax', 'opencode', 'claude-code', 'codex', 'copilot-computer-use')
        foreach ($p in @($script:Master.mcpServers.PSObject.Properties)) {
            $op = $p.Value.PSObject.Properties['only']
            if ($null -eq $op) { continue }
            foreach ($t in @($op.Value)) {
                $known | Should -Contain ([string]$t).ToLowerInvariant() -Because "'$($p.Name)' scopes to unknown app '$t'"
            }
        }
    }
}

Describe 'master-mcp.local.json overlay (gitignored)' {
    It 'parses when present' {
        if (-not (Test-Path $script:OverlayPath)) { Set-ItResult -Inconclusive -Because 'overlay not present on this checkout' }
        { Get-Content $script:OverlayPath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}
