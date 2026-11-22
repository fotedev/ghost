# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/opencode_config_merge.ps1 - the pure merge core of the
# OpenCode definitions-only Primary -> clone config sync (CS-1,
# docs\OPENCODE_CONFIG_SYNC_PLAN.md). The module is a pure function library
# (no main body, no side effects), so it is dot-sourced and every assertion
# runs the REAL merge code - never a test-local re-implementation, never a
# live config. The zcode cases are ported from tests/zcode_mcp_merge.Tests.ps1
# (the sync invariant is the same); the scrub cases pin decision D2.

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\opencode_config_merge.ps1')
    $ErrorActionPreference = $prevEap

    function New-Map {
        param([hashtable]$Entries)
        $o = New-Object PSObject
        foreach ($k in $Entries.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $Entries[$k] }
        return $o
    }

    function New-McpEntry {
        param([object]$Enabled = $true, [string]$Token = 'tok_primary', [string[]]$ArgList = @('server.mjs'))
        $o = [pscustomobject]@{
            type    = 'stdio'
            command = @('node', 'server.mjs')
            env     = [pscustomobject]@{ TOKEN = $Token }
        }
        if ($null -ne $Enabled) { $o | Add-Member -NotePropertyName enabled -NotePropertyValue $Enabled }
        return $o
    }

    function New-ProviderEntry {
        param([string]$ApiKey = 'sk-primary-secret', [string]$BaseUrl = 'https://api.example.com/v4', [string[]]$Models = @('glm-4.6'))
        $o = [pscustomobject]@{
            npm     = '@ai-sdk/openai-compatible'
            options = [pscustomobject]@{
                baseURL = $BaseUrl
                apiKey  = $ApiKey
            }
            models  = $Models
        }
        return $o
    }

    function New-RootConfig {
        param([hashtable]$Entries)
        $root = New-Object PSObject
        if ($Entries.ContainsKey('mcp'))      { $root | Add-Member -NotePropertyName mcp      -NotePropertyValue (New-Map -Entries $Entries['mcp']) }
        if ($Entries.ContainsKey('provider')) { $root | Add-Member -NotePropertyName provider -NotePropertyValue (New-Map -Entries $Entries['provider']) }
        return $root
    }
}

Describe 'opencode_config_merge module (dot-sourced)' {
    It 'dot-sourcing defines the pure merge functions' {
        Get-Command Invoke-OcConfigMerge     -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-DeepHashtable  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-DeepEqual           -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Write-JsonNoBom          -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertFrom-JsoncText    -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'ConvertFrom-JsoncText strips comments but keeps url schemes' {
        $cfg = ConvertFrom-JsoncText -Text @'
{
    // line comment
    "mcp": { /* block
comment */ "a": { "url": "https://x/y" } }
}
'@
        $cfg.mcp.a.url | Should -Be 'https://x/y'
    }
}

Describe 'Invoke-OcConfigMerge (the sync invariant - zcode cases ported)' {
    It 'existing entry: Primary definition wins, clone-local enabled toggle survives' {
        $primary = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $true -Token 'tok_new') } }
        $clone   = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $false -Token 'tok_old') } }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Changed | Should -Contain 'mcp.supabase'
        $clone.mcp.supabase.enabled | Should -Be $false
        $clone.mcp.supabase.env.TOKEN | Should -Be 'tok_new'
    }

    It 'new entry carries the Primary enabled value; clone-only entries are never removed' {
        $primary = New-RootConfig -Entries @{
            mcp = @{
                supabase = (New-McpEntry -Enabled $true)
                extra    = (New-McpEntry -Enabled $false)
            }
        }
        $clone = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $true); cloneOnly = (New-McpEntry -Enabled $true) } }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Changed | Should -Contain 'mcp.extra'
        $clone.mcp.extra.enabled | Should -Be $false
        $clone.mcp.cloneOnly | Should -Not -BeNullOrEmpty
    }

    It 'idempotent: a second merge reports nothing changed' {
        $primary = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $true) } }
        $clone   = New-RootConfig -Entries @{ mcp = @{} }
        [void](Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone)
        $r2 = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        @($r2.Changed).Count | Should -Be 0
    }

    It 'Primary with no mcp/provider blocks touches nothing' {
        $primary = New-Object PSObject
        $clone   = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $true) } }
        $before  = ConvertTo-DeepHashtable $clone
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        @($r.Changed).Count | Should -Be 0
        (Test-DeepEqual $before (ConvertTo-DeepHashtable $clone)) | Should -BeTrue
    }

    It 'the Primary config object is never mutated' {
        $primary = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $true) } }
        $before  = ConvertTo-DeepHashtable $primary
        $clone   = New-RootConfig -Entries @{ mcp = @{} }
        [void](Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone)
        (Test-DeepEqual $before (ConvertTo-DeepHashtable $primary)) | Should -BeTrue
    }
}

Describe 'Invoke-OcConfigMerge (the secret scrub - decision D2)' {
    It 'a Primary provider syncs WITHOUT its apiKey, never a placeholder' {
        $primary = New-RootConfig -Entries @{ provider = @{ zai = (New-ProviderEntry -ApiKey 'sk-live-primary') } }
        $clone   = New-RootConfig -Entries @{ provider = @{} }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Scrubbed | Should -Contain 'provider.zai'
        $clone.provider.zai.PSObject.Properties['apiKey'] | Should -BeNullOrEmpty
        # the rest of the definition still synced
        $clone.provider.zai.options.baseURL | Should -Be 'https://api.example.com/v4'
        @($clone.provider.zai.models).Count | Should -Be 1
    }

    It 'a secret the CLONE already has survives the merge' {
        $primary = New-RootConfig -Entries @{ provider = @{ zai = (New-ProviderEntry -ApiKey 'sk-live-primary') } }
        $clone   = New-RootConfig -Entries @{ provider = @{ zai = (New-ProviderEntry -ApiKey 'sk-clone-own') } }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Scrubbed | Should -Contain 'provider.zai'
        # definition updated from Primary, but the clone's own key stays
        $clone.provider.zai.options.apiKey | Should -Be 'sk-clone-own'
    }

    It 'scrub covers the api_key spelling too' {
        $primary = New-RootConfig -Entries @{
            provider = @{
                zai = [pscustomobject]@{
                    npm     = '@ai-sdk/openai-compatible'
                    options = [pscustomobject]@{ api_key = 'sk-x' }
                }
            }
        }
        $clone = New-RootConfig -Entries @{ provider = @{} }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Scrubbed | Should -Contain 'provider.zai'
        $clone.provider.zai.options.PSObject.Properties['api_key'] | Should -BeNullOrEmpty
    }

    It 'mcp definitions copy env wholesale (the ZCode-sync precedent)' {
        $primary = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Token '${SUPABASE_ACCESS_TOKEN}') } }
        $clone   = New-RootConfig -Entries @{ mcp = @{} }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Changed | Should -Contain 'mcp.supabase'
        $clone.mcp.supabase.env.TOKEN | Should -Be '${SUPABASE_ACCESS_TOKEN}'
    }
}

Describe 'Invoke-OcConfigMerge (the REAL nested shape - the CS-7-wave live-caught bug)' {
    # The app stores servers NESTED under mcp.servers (live-verified
    # 2026-11-22 on the Primary + clone homes), and the Primary can also
    # carry DIRECT mcp entries alongside the nested block. The old flat-only
    # walk treated the WHOLE servers block as one entry and let the
    # Primary's copy silently drop clone-only servers inside it.

    It 'clone-only servers INSIDE mcp.servers survive (the live-caught drop)' {
        $primary = New-RootConfig -Entries @{ mcp = @{ servers = (New-Map -Entries @{ supabase = (New-McpEntry -Enabled $true) }) } }
        $clone   = New-RootConfig -Entries @{ mcp = @{ servers = (New-Map -Entries @{ cloneOnly = (New-McpEntry -Enabled $true) }) } }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        ($r.Changed | Where-Object { $_ -match '^mcp\.servers\.' }) | Should -Not -BeNullOrEmpty
        # Primary's definition landed AND the clone-only server survived
        $clone.mcp.servers.supabase.enabled | Should -Be $true
        $clone.mcp.servers.cloneOnly | Should -Not -BeNullOrEmpty
        $clone.mcp.servers.cloneOnly.enabled | Should -Be $true
    }

    It 'a DIRECT mcp entry (codeagentswarm-tasks shape) merges alongside the nested block' {
        $primary = New-RootConfig -Entries @{ mcp = @{
            'codeagentswarm-tasks' = (New-McpEntry -Enabled $true)
            servers = (New-Map -Entries @{ swarm = (New-McpEntry -Enabled $true) })
        } }
        $clone = New-RootConfig -Entries @{ mcp = @{ servers = (New-Map -Entries @{}) } }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Changed | Should -Contain 'mcp.codeagentswarm-tasks'
        $r.Changed | Should -Contain 'mcp.servers.swarm'
        $clone.mcp.'codeagentswarm-tasks' | Should -Not -BeNullOrEmpty
        $clone.mcp.servers.swarm.enabled | Should -Be $true
    }

    It 'clone-local enabled toggles survive INSIDE mcp.servers' {
        $primary = New-RootConfig -Entries @{ mcp = @{ servers = (New-Map -Entries @{ swarm = (New-McpEntry -Enabled $true) }) } }
        $clone   = New-RootConfig -Entries @{ mcp = @{ servers = (New-Map -Entries @{ swarm = (New-McpEntry -Enabled $false -Token 'tok_clone') }) } }
        $r = Invoke-OcConfigMerge -PrimaryConfig $primary -CloneConfig $clone
        $r.Changed | Should -Contain 'mcp.servers.swarm'
        $clone.mcp.servers.swarm.enabled | Should -Be $false -Because 'the clone-local toggle always survives'
    }
}

Describe 'sync contract (file-level, TestDrive)' {
    It 'Write-JsonNoBom round-trips and the written file has no BOM' {
        $cfg = New-RootConfig -Entries @{ mcp = @{ supabase = (New-McpEntry -Enabled $true) } }
        $p = Join-Path $TestDrive 'opencode.jsonc'
        Write-JsonNoBom -Path $p -Object $cfg
        $bytes = [System.IO.File]::ReadAllBytes($p)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        $back = ConvertFrom-JsoncText -Text ([System.Text.Encoding]::UTF8.GetString($bytes))
        $back.mcp.supabase.enabled | Should -Be $true
    }

    It 'the write is ATOMIC (CS-7 2026-11-22: temp + File.Replace - a concurrent reader never sees a torn file)' {
        # the implementation pins: a temp file then an atomic swap, never a
        # direct truncate+overwrite of the live path
        $raw = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\tools\opencode_config_merge.ps1'))
        ($raw -match 'ghost-tmp') | Should -BeTrue
        ($raw -match '\[System\.IO\.File\]::Replace\(') | Should -BeTrue
        ($raw -match '\[System\.IO\.File\]::Move\(') | Should -BeTrue
    }

    It 'overwrite path: a second write lands atomically and leaves no temp file behind' {
        $p = Join-Path $TestDrive 'overwrite.json'
        Write-JsonNoBom -Path $p -Object (New-RootConfig -Entries @{ mcp = @{ a = (New-McpEntry -Enabled $true) } })
        Write-JsonNoBom -Path $p -Object (New-RootConfig -Entries @{ mcp = @{ b = (New-McpEntry -Enabled $false) } })
        (Test-Path -LiteralPath "$p.ghost-tmp") | Should -BeFalse -Because 'the temp file must be consumed by the swap'
        $back = ConvertFrom-JsoncText -Text ([System.IO.File]::ReadAllText($p))
        $back.mcp.b.enabled | Should -Be $false
        $back.mcp.a | Should -BeNullOrEmpty
    }

    It 'create path: a first write to a missing path leaves no temp file behind' {
        $p = Join-Path $TestDrive 'fresh.json'
        Write-JsonNoBom -Path $p -Object (New-RootConfig -Entries @{ mcp = @{ a = (New-McpEntry -Enabled $true) } })
        (Test-Path -LiteralPath "$p.ghost-tmp") | Should -BeFalse
        (Test-Path -LiteralPath $p) | Should -BeTrue
    }
}
