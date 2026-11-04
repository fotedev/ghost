# Lean Pester suite for the AutoClaw2 sync orchestrators (tools/sync_autoclaw2_*.ps1).
#
# Scope note: this suite pins the ORCHESTRATOR surface only - target parsing,
# exit codes 0/1/2, verdict rendering, quiet mode - against a throwaway
# USERPROFILE fixture. The merge/plan/apply/import/revert logic itself lives in
# src/python/ghost/autoclaw2.py and is pinned by the 39-case unittest batch
# (tests/python/test_ghost_autoclaw2.py); duplicating it here would re-implement
# the fixture, not add coverage.

Describe 'AutoClaw2 sync orchestrators' {

    BeforeAll {
        $script:repo = Split-Path -Parent $PSScriptRoot
        $script:mcpScript = Join-Path $script:repo 'tools\sync_autoclaw2_mcp.ps1'
        $script:chatsScript = Join-Path $script:repo 'tools\sync_autoclaw2_chats.ps1'
        $script:fixturePath = Join-Path ([System.IO.Path]::GetTempPath()) (
            'ac2-pester-' + [guid]::NewGuid().ToString('N'))
        # never-signed-in clones: profile dirs exist, accounts\ is empty (G1/F2)
        New-Item -ItemType Directory -Path (
            Join-Path $script:fixturePath 'AutoClaw2ClonesHome\c1\accounts') -Force | Out-Null
        New-Item -ItemType Directory -Path (
            Join-Path $script:fixturePath 'AppData\Roaming') -Force | Out-Null

        # Pester 5: helper functions must be defined inside BeforeAll to be
        # visible from It blocks (a Describe-body definition runs at discovery
        # time in the wrong scope).
        function Invoke-Orchestrator {
            param(
                [string]$ScriptPath,
                [string[]]$Arguments
            )
            $origHome = $env:USERPROFILE
            $origAppData = $env:APPDATA
            $env:USERPROFILE = $script:fixturePath
            $env:APPDATA = Join-Path $script:fixturePath 'AppData\Roaming'
            try {
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
                    -File $ScriptPath @Arguments 2>&1
                return @{ code = $LASTEXITCODE; out = ($out | Out-String) }
            }
            finally {
                $env:USERPROFILE = $origHome
                $env:APPDATA = $origAppData
            }
        }
    }

    AfterAll {
        if (Test-Path $script:fixturePath) {
            Remove-Item $script:fixturePath -Recurse -Force
        }
    }

    Context 'sync_autoclaw2_mcp.ps1' {

        It 'rejects an unknown target with exit 1' {
            $r = Invoke-Orchestrator $script:mcpScript @('-Target', 'c9')
            $r.code | Should -Be 1
            $r.out | Should -Match "unknown target 'c9'"
        }

        It 'skips a never-signed-in clone with exit 0 and no write' {
            $r = Invoke-Orchestrator $script:mcpScript @('-Target', 'c1')
            $r.code | Should -Be 0
            $r.out | Should -Match '\[SKIP\] c1'
            $r.out | Should -Match 'All targets converged'
        }

        It 'dry run prints the plan and writes nothing (exit 0)' {
            $r = Invoke-Orchestrator $script:mcpScript @('-Target', 'c1', '-DryRun')
            $r.code | Should -Be 0
            $r.out | Should -Match 'Dry run only - nothing was written'
        }

        It 'refuses -From Primary when no Primary profile exists (exit 2)' {
            $r = Invoke-Orchestrator $script:mcpScript @('-From', 'Primary', '-Target', 'c1')
            $r.code | Should -Be 2
            $r.out | Should -Match '\[REFUSED\]'
        }

        It 'RestoreBackup with no backups exits 0 with a SKIP line' {
            $r = Invoke-Orchestrator $script:mcpScript @('-RestoreBackup', '-Target', 'c1')
            $r.code | Should -Be 0
            $r.out | Should -Match 'no backups to restore'
        }

        It 'quiet mode suppresses tag lines but keeps the exit code' {
            $r = Invoke-Orchestrator $script:mcpScript @('-Target', 'c1', '-Quiet')
            $r.code | Should -Be 0
            $r.out | Should -Not -Match '\[SKIP\]'
        }
    }

    Context 'sync_autoclaw2_chats.ps1' {

        It 'rejects an unknown target with exit 1' {
            $r = Invoke-Orchestrator $script:chatsScript @('-Mode', 'Import', '-Target', 'c9', '-SessionId', '00000000-0000-4000-8000-000000000000')
            $r.code | Should -Be 1
            $r.out | Should -Match "unknown target 'c9'"
        }

        It 'Import without -SessionId exits 1 with a remedy' {
            $r = Invoke-Orchestrator $script:chatsScript @('-Mode', 'Import')
            $r.code | Should -Be 1
            $r.out | Should -Match 'needs -SessionId'
        }

        It 'Revert without -ImportId exits 1 with a remedy' {
            $r = Invoke-Orchestrator $script:chatsScript @('-Revert')
            $r.code | Should -Be 1
            $r.out | Should -Match 'needs -ImportId'
        }

        It 'inventory skips a never-signed-in clone and still writes the report (exit 0)' {
            $r = Invoke-Orchestrator $script:chatsScript @('-Mode', 'Inventory', '-Target', 'c1')
            $r.code | Should -Be 0
            $r.out | Should -Match '\[SKIP\] c1'
            $r.out | Should -Match 'Report:'
        }

        It 'Import into a never-signed-in clone is refused with exit 2 when every target refuses' {
            $r = Invoke-Orchestrator $script:chatsScript @(
                '-Mode', 'Import', '-Target', 'c1',
                '-SessionId', '00000000-0000-4000-8000-000000000000', '-Apply')
            $r.code | Should -Be 2
            $r.out | Should -Match '\[REFUSED\]'
        }
    }
}
