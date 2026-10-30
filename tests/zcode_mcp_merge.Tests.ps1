# SPDX-License-Identifier: Apache-2.0
# Unit tests for tools/zcode_mcp_merge.ps1 - the pure merge core shared by
# tools/sync_zcode_assets.ps1 (Sync-McpDefinitions) and consumed on every
# change by tools/watch_zcode_mcp_sync.ps1. The module is a pure function
# library (no main body, no side effects), so it is dot-sourced and every
# assertion runs the REAL merge code against TestDrive fixtures - never a
# test-local re-implementation, never the live configs.

BeforeAll {
    $prevEap = $ErrorActionPreference
    . (Join-Path $PSScriptRoot '..\tools\zcode_mcp_merge.ps1')
    $ErrorActionPreference = $prevEap

    function New-ServerMap {
        param([hashtable]$Entries)
        $o = New-Object PSObject
        foreach ($k in $Entries.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $Entries[$k] }
        return $o
    }

    function New-StdioEntry {
        # $Enabled $null = no 'enabled' key at all (the app allows its absence).
        param([object]$Enabled = $true, [string]$Token = 'tok_primary', [string[]]$ArgList = @('server.mjs'))
        $o = [pscustomobject]@{
            type    = 'stdio'
            command = 'node'
            args    = $ArgList
            env     = [pscustomobject]@{ TOKEN = $Token }
        }
        if ($null -ne $Enabled) { $o | Add-Member -NotePropertyName enabled -NotePropertyValue $Enabled }
        return $o
    }
}

Describe 'zcode_mcp_merge module (dot-sourced)' {
    It 'dot-sourcing defines the pure merge functions' {
        Get-Command Invoke-McpMerge          -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command ConvertTo-DeepHashtable  -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Test-DeepEqual           -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command Write-JsonNoBom          -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-McpMerge (the sync invariant)' {
    It 'existing server: Primary definition wins, clone-local enabled toggle survives' {
        $primary = New-ServerMap -Entries @{
            supabase = New-StdioEntry -Enabled $true -Token 'tok_new' -ArgList @('C:/path/cli.js', '--project-ref', 'abc')
        }
        $clone = New-ServerMap -Entries @{
            supabase = New-StdioEntry -Enabled $false -Token 'tok_old' -ArgList @('C:\old\cli.js', '--project-ref', 'old')
        }
        $changed = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $changed | Should -Contain 'supabase'
        $out = $clone.supabase
        $out.args[0]         | Should -Be 'C:/path/cli.js'
        $out.args[2]         | Should -Be 'abc'
        $out.env.TOKEN       | Should -Be 'tok_new'
        $out.enabled         | Should -Be $false   # the ONLY field the Primary may not overwrite
    }

    It 'new server: carries the Primary enabled value' {
        $primary = New-ServerMap -Entries @{ sentry = [pscustomobject]@{ type = 'http'; url = 'https://mcp.sentry.dev/mcp'; enabled = $true } }
        $clone   = New-ServerMap -Entries @{}
        $changed = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $changed | Should -Contain 'sentry'
        $clone.sentry.enabled | Should -Be $true
        $clone.sentry.url     | Should -Be 'https://mcp.sentry.dev/mcp'
    }

    It 'new server without an enabled key in the Primary: none is invented' {
        $primary = New-ServerMap -Entries @{ bare = New-StdioEntry -Enabled $null }
        $clone   = New-ServerMap -Entries @{}
        $null = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $clone.bare.PSObject.Properties['enabled'] | Should -BeNullOrEmpty
    }

    It 'clone-only server: never removed' {
        $primary = New-ServerMap -Entries @{ github = New-StdioEntry -Enabled $true }
        $clone   = New-ServerMap -Entries @{ supabaseMasarx = New-StdioEntry -Enabled $true -Token 'tok_masarx' }
        $changed = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $changed | Should -Contain 'github'
        $clone.supabaseMasarx.env.TOKEN | Should -Be 'tok_masarx'
    }

    It 'already in sync: mutates nothing and reports an empty change list' {
        $entry = New-StdioEntry -Enabled $true -Token 'tok_same'
        $primary = New-ServerMap -Entries @{ github = $entry }
        # Independent deep copy so object identity cannot fake equality.
        $clone = New-ServerMap -Entries @{ github = ($entry | ConvertTo-Json -Depth 100 | ConvertFrom-Json) }
        $changed = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $changed | Should -BeNullOrEmpty
    }

    It 'key-order-insensitive: same content with reordered env keys is NOT drift' {
        $primary = New-ServerMap -Entries @{
            supabase = [pscustomobject]@{
                type = 'stdio'; command = 'node'; enabled = $true
                env  = [pscustomobject]@{ TOKEN = 't'; PROJECT = 'p' }
            }
        }
        $clone = New-ServerMap -Entries @{
            supabase = [pscustomobject]@{
                enabled = $true; command = 'node'; type = 'stdio'
                env     = [pscustomobject]@{ PROJECT = 'p'; TOKEN = 't' }
            }
        }
        $changed = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $changed | Should -BeNullOrEmpty
    }

    It 'Primary object is never mutated by the merge' {
        $primary = New-ServerMap -Entries @{ github = New-StdioEntry -Enabled $true -Token 'tok_p' }
        $before  = $primary.github | ConvertTo-Json -Depth 100
        $clone   = New-ServerMap -Entries @{ github = New-StdioEntry -Enabled $false -Token 'tok_c' }
        $null = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        ($primary.github | ConvertTo-Json -Depth 100) | Should -Be $before
    }

    It 'returns the changed list even when the clone map was empty (fresh clone)' {
        $primary = New-ServerMap -Entries @{
            a = New-StdioEntry -Enabled $true
            b = New-StdioEntry -Enabled $false
        }
        $clone = New-ServerMap -Entries @{}
        # Direct assignment (as sync_zcode_assets.ps1 consumes it): the comma
        # wrapper preserves the array through return, so Count is meaningful.
        $changed = Invoke-McpMerge -PrimaryServers $primary -CloneServers $clone
        $changed.Count | Should -Be 2
    }
}

Describe 'Write-JsonNoBom (file format contract)' {
    It 'writes UTF-8 WITHOUT a BOM, pretty-printed, with a trailing newline' {
        $p = Join-Path $TestDrive 'config.json'
        $obj = [pscustomobject]@{ mcp = [pscustomobject]@{ servers = [pscustomobject]@{} } }
        Write-JsonNoBom -Path $p -Object $obj
        $bytes = [System.IO.File]::ReadAllBytes($p)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        $text | Should -Match "`n$"                 # trailing newline (the app writes one too)
        $text | Should -Match '^{'                  # no BOM prefix survived as text
        { $null = $text | ConvertFrom-Json } | Should -Not -Throw
    }
}

Describe 'Test-DeepEqual / ConvertTo-DeepHashtable semantics' {
    It 'objects with different key order are equal; different values are not' {
        $a = ConvertTo-DeepHashtable ([pscustomobject]@{ x = 1; y = [pscustomobject]@{ b = 2; a = 1 } })
        $b = ConvertTo-DeepHashtable ([pscustomobject]@{ y = [pscustomobject]@{ a = 1; b = 2 }; x = 1 })
        Test-DeepEqual $a $b | Should -Be $true
        $c = ConvertTo-DeepHashtable ([pscustomobject]@{ x = 2; y = [pscustomobject]@{ b = 2; a = 1 } })
        Test-DeepEqual $a $c | Should -Be $false
    }

    It 'arrays are order-significant' {
        $a = ConvertTo-DeepHashtable ([pscustomobject]@{ args = @('one', 'two') })
        $b = ConvertTo-DeepHashtable ([pscustomobject]@{ args = @('two', 'one') })
        Test-DeepEqual $a $b | Should -Be $false
    }

    It 'null vs missing are equal; null vs value are not' {
        Test-DeepEqual $null $null | Should -Be $true
        $x = ConvertTo-DeepHashtable ([pscustomobject]@{ a = 1 })
        Test-DeepEqual $null $x | Should -Be $false
    }
}
