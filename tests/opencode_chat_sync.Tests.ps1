# Static contract for the OpenCode cross-instance chat sync (2026-11-20):
# tools/sync_opencode_chats.ps1 + src/python/ghost/opencode.py + the
# GHOST.bat/menu.json wiring (OpenCode [26]/[27], gids 124/125).
# The FUNCTIONAL side (fixture dbs: import/remap/idempotence/revert) is
# covered by tests/python/test_ghost_opencode.py; the orchestrator's own
# fixture matrix ran against %TEMP% dbs before landing.

Describe 'opencode chat sync - files and conventions' {
    BeforeAll {
        $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $script:Tool = Join-Path $script:RepoRoot 'tools\sync_opencode_chats.ps1'
        $script:Core = Join-Path $script:RepoRoot 'src\python\ghost\opencode.py'
        $script:Main = Join-Path $script:RepoRoot 'src\python\ghost\__main__.py'
        $script:ToolRaw = [System.IO.File]::ReadAllText($script:Tool)
        $script:CoreRaw = [System.IO.File]::ReadAllText($script:Core)
    }

    It 'tool exists, is PS 5.1, and carries no BOM' {
        Test-Path $script:Tool | Should -BeTrue
        $script:ToolRaw | Should -Match '#Requires -Version 5\.1'
        $bytes = [System.IO.File]::ReadAllBytes($script:Tool)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
    }

    It 'tool lines are CRLF-terminated (the repo .ps1 convention, .gitattributes)' {
        ($script:ToolRaw -notmatch "`r`n") | Should -BeFalse
    }

    It 'tool resolves the clone root OpenCodeClonesHome + per-clone data dir + the Primary XDG root' {
        $script:ToolRaw | Should -Match 'OpenCodeClonesHome'
        $script:ToolRaw | Should -Match 'data\\opencode'
        $script:ToolRaw | Should -Match '\.local\\share\\opencode'
    }

    It 'tool keeps the CS-1 lockfile probe shape (exclusive open, held = RUNNING -> SKIP)' {
        $script:ToolRaw | Should -Match "'desktop\\lockfile'"
        $script:ToolRaw | Should -Match '\[System\.IO\.File\]::Open\(\$lockfile'
        $script:ToolRaw | Should -Match 'appears RUNNING \(lockfile held\)'
    }

    It 'tool drives the core verbs and honors exit 2 as a refusal (never a crash)' {
        foreach ($verb in 'oc-chat-inventory', 'oc-chat-import', 'oc-chat-revert') {
            $script:ToolRaw | Should -Match ([regex]::Escape("'" + $verb + "'"))
        }
        $script:ToolRaw | Should -Match '\$LASTEXITCODE -notin 0, 2'
    }

    It 'tool writes an audit of ids + counts only (never message bodies)' {
        $script:ToolRaw | Should -Match 'chat-sync-audit\.jsonl'
        $script:ToolRaw | Should -Match ([regex]::Escape('# ids only - never bodies'))
        $script:ToolRaw | Should -Not -Match 'data\)\s*-join'
    }

    It 'core refuses schema drift and never reads the auth/app tables' {
        $script:CoreRaw | Should -Match 'schema-mismatch'
        foreach ($t in 'account', 'credential', 'control_account', 'kv',
                 'session_inbox', 'automation', 'permission', 'worktree') {
            $script:CoreRaw | Should -Match ([regex]::Escape('"' + $t + '"'))
        }
    }

    It 'core is registered in __main__ with the one-base64-payload contract' {
        $mainRaw = [System.IO.File]::ReadAllText($script:Main)
        foreach ($verb in 'oc-chat-inventory', 'oc-chat-import', 'oc-chat-revert') {
            $mainRaw | Should -Match ([regex]::Escape('"' + $verb + '"'))
        }
        $mainRaw | Should -Match 'from ghost import .*opencode'
    }
}

Describe 'opencode chat sync - GHOST.bat + menu.json wiring' {
    BeforeAll {
        $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.FullName
        $script:BatRaw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'GHOST.bat'))
        $script:Menu = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "src\desktop\menu.json")) | ConvertFrom-Json
    }

    It 'dispatches gid 124 as the inventory diff (no -Apply)' {
        ($script:BatRaw -match ([regex]::Escape('if "%~1"=="124" (call :Run "tools\sync_opencode_chats.ps1" -Target All & exit /b)'))) | Should -BeTrue
    }

    It 'dispatches gid 125 as the guarded import (-AllMissing -Apply, the AC2 [10] semantics)' {
        ($script:BatRaw -match ([regex]::Escape('if "%~1"=="125" (call :Run "tools\sync_opencode_chats.ps1" -Target All -AllMissing -Apply & exit /b)'))) | Should -BeTrue
    }

    It 'OpenCodeOne maps locals 26/27 to gids 124/125' {
        ($script:BatRaw -match ([regex]::Escape('if "%~1"=="26" set "RESOLVED=124"'))) | Should -BeTrue
        ($script:BatRaw -match ([regex]::Escape('if "%~1"=="27" set "RESOLVED=125"'))) | Should -BeTrue
    }

    It 'the OpenCode submenu carries the Chat Sync div with rows 26/27' {
        ($script:BatRaw -match ([regex]::Escape('call :Div "Chat Sync"'))) | Should -BeTrue
        ($script:BatRaw -match ([regex]::Escape('call :Opt 26 "Chat sync inventory"'))) | Should -BeTrue
        ($script:BatRaw -match ([regex]::Escape('call :Opt 27 "Import missing chats"'))) | Should -BeTrue
    }

    It 'menu.json carries gid 124/125 in the OpenCode section with matching scripts/args' {
        $oc = $script:Menu.sections | Where-Object { $_.name -eq 'OpenCode' }
        $inv = $oc.rows | Where-Object { $_.gid -eq 124 }
        $imp = $oc.rows | Where-Object { $_.gid -eq 125 }
        $inv | Should -Not -BeNullOrEmpty
        $imp | Should -Not -BeNullOrEmpty
        $inv.script | Should -Be 'tools/sync_opencode_chats.ps1'
        $inv.args -join ' ' | Should -Be '-Target All'
        $imp.script | Should -Be 'tools/sync_opencode_chats.ps1'
        ($imp.args -join ' ') | Should -Be '-Target All -AllMissing -Apply'
        $inv.mode | Should -Be $imp.mode
    }

    It 'the retired AutoClaw v1 gids stay reserved-dead (37-40, 63 never reused)' {
        foreach ($g in 37, 38, 39, 40, 63) {
            ($script:BatRaw -match ('if "%~1"=="{0}"' -f $g)) | Should -BeFalse
        }
        $allGids = @($script:Menu.sections | ForEach-Object { $_.rows } | ForEach-Object { $_.gid })
        foreach ($g in 37, 38, 39, 40, 63) {
            $allGids | Should -Not -Contain $g
        }
    }
}
