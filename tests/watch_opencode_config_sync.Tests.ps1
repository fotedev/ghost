# SPDX-License-Identifier: Apache-2.0
# Tests for tools/watch_opencode_config_sync.ps1 - the OpenCode config sync
# watcher (CS-1 v2, 2026-11-17; ZCode MCP-sync-watcher pattern ported onto
# sync_opencode_config.ps1). Static contract only: the watcher is a resident
# loop whose interesting behavior (backup, verify-after, audit, running-skip)
# lives in the CHILD sync script, which has its own fixture-tested merge core
# (tests/opencode_config_merge.Tests.ps1). What must be pinned HERE is the
# wiring contract: which child it spawns, which mutex/log/lnk names it owns,
# the JSONC parse-guard, and the deliberately-absent -ApplyLive/-Target
# surface (no live-apply until OpenCode's re-read timing is verified -
# docs/TASK_BACKLOG.md).

Describe 'OpenCode config sync watcher - script hygiene' {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\watch_opencode_config_sync.ps1")).Path
        $tokens = $null; $errors = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "watch_opencode_config_sync.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:ScriptPath)
    }

    It 'declares #Requires -Version 5.1' {
        (Get-Content -LiteralPath $script:ScriptPath -TotalCount 1) -match '#Requires -Version 5.1' | Should -BeTrue
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptPath)
        ($bytes.Length -gt 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "`r`n") | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse -Because "bare LF must not survive the CRLF normalization"
    }
}

Describe 'OpenCode config sync watcher - param surface' {
    BeforeAll {
        $script:Pb = $script:ScriptAst.ParamBlock
        $script:ParamNames = @($script:Pb.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }

    It 'declares the resident/one-shot surface' {
        @($script:ParamNames) | Should -Contain 'RunOnce'
        @($script:ParamNames) | Should -Contain 'DryRun'
        @($script:ParamNames) | Should -Contain 'IntervalSeconds'
        @($script:ParamNames) | Should -Contain 'LogFile'
        @($script:ParamNames) | Should -Contain 'InstallAutostart'
        @($script:ParamNames) | Should -Contain 'RemoveAutostart'
    }

    It 'has NO -ApplyLive and NO -Target (the live behavior is the CHILD''S default - CS-7 LIVE-VERIFIED 2026-11-22)' {
        @($script:ParamNames) | Should -Not -Contain 'ApplyLive' -Because "the live sync needs no flag: the child syncs running clones by default (LIVE-VERIFIED probe; -SkipRunning is the child's own opt-out)"
        @($script:ParamNames) | Should -Not -Contain 'Target' -Because "the watcher always syncs ALL clones via the child's -Target All"
        # the header documents the verified verdict (why no flag exists)
        ($script:Raw -match 'LIVE-VERIFIED 2026-11-22') | Should -BeTrue
        ($script:Raw -match 'fires .config\.updated. in') | Should -BeTrue
    }

    It 'defaults IntervalSeconds to 5 and LogFile under watch-opencode-config-sync' {
        $iv = $script:Pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'IntervalSeconds' }
        ($iv.DefaultValue.Extent.Text) | Should -Be '5'
        $lf = $script:Pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'LogFile' }
        ($lf.DefaultValue.Extent.Text) | Should -Match 'watch-opencode-config-sync'
    }
}

Describe 'OpenCode config sync watcher - wiring contract' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\tools\watch_opencode_config_sync.ps1")).Path)
    }

    It 'spawns sync_opencode_config.ps1 -Target All as the only writer' {
        ($script:Raw -match [regex]::Escape('sync_opencode_config.ps1')) | Should -BeTrue
        ($script:Raw -match '-Target All') | Should -BeTrue
    }

    It 'passes -DryRun through to the child' {
        ($script:Raw -match "\`$argStr \+= ' -DryRun'") | Should -BeTrue
    }

    It 'runs the child console-less with the 600s kill cap (watcher must never flash a window or wedge)' {
        ($script:Raw -match 'CreateNoWindow = \$true') | Should -BeTrue
        ($script:Raw -match 'WaitForExit\(600000\)') | Should -BeTrue
    }

    It 'guards the Primary with the JSONC-aware parse (ConvertFrom-JsoncText, never naive ConvertFrom-Json)' {
        ($script:Raw -match [regex]::Escape('opencode_config_merge.ps1')) | Should -BeTrue
        ($script:Raw -match 'ConvertFrom-JsoncText') | Should -BeTrue
    }

    It 'skips a torn Primary instead of syncing from it' {
        ($script:Raw -match 'no sync from an invalid file') | Should -BeTrue
    }

    It 'owns mutex OpencodeConfigSyncWatcher + the startup process scan + the Startup .lnk' {
        ($script:Raw -match "'OpencodeConfigSyncWatcher'") | Should -BeTrue
        ($script:Raw -match 'Get-OtherWatcherPids') | Should -BeTrue
        ($script:Raw -match [regex]::Escape('OpenCode config sync watcher.lnk')) | Should -BeTrue
    }

    It 'deep re-verifies every 60 passes with the debounced signature guard' {
        ($script:Raw -match '\$script:PassCount % 60') | Should -BeTrue
        ($script:Raw -match 'TotalMilliseconds -lt 800') | Should -BeTrue
    }
}

Describe 'OpenCode launcher - watcher ensure step (2c)' {
    BeforeAll {
        $script:LauncherPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_opencode_clone.ps1")).Path
        $tokens = $null; $errors = $null
        $script:LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_opencode_clone.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:LauncherPath)
    }

    It 'step 2c exists and runs the watcher script by path' {
        ($script:Raw -match '\[2c/5\] Ensure resident config-sync watcher') | Should -BeTrue
        ($script:Raw -match [regex]::Escape('watch_opencode_config_sync.ps1')) | Should -BeTrue
    }

    It 'ensures with the watcher-owned mutex and Startup .lnk names' {
        ($script:Raw -match "'OpencodeConfigSyncWatcher'") | Should -BeTrue
        ($script:Raw -match [regex]::Escape('OpenCode config sync watcher.lnk')) | Should -BeTrue
    }

    It 'is best-effort by contract (warn + continue, never throw out of the ensure)' {
        # The ensure helper must swallow its own failures - a watcher hiccup
        # must never block a launch (ZCode 2e contract).
        $fn = $script:LauncherAst.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Ensure-ResidentWatcher' }, $true)
        $fn.Count | Should -Be 1
        ($fn[0].Body.Extent.Text -match 'catch') | Should -BeTrue
    }

    It 'runs BEFORE the lockfile running-guard (a running clone still heals the watcher)' {
        $ensureIdx = $script:Raw.IndexOf('[2c/5] Ensure resident config-sync watcher')
        $guardIdx = $script:Raw.IndexOf("appears to be RUNNING (lockfile held)")
        $ensureIdx | Should -BeGreaterThan 0
        $guardIdx | Should -BeGreaterThan $ensureIdx
    }
}

Describe 'GHOST.bat + menu.json wiring for gids 110/111' {
    BeforeAll {
        $script:Bat = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\GHOST.bat")).Path)
        $script:Menu = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot "..\src\desktop\menu.json")).Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:OcRows = @(($script:Menu.sections | Where-Object { $_.name -eq 'OpenCode' }).rows)
    }

    It 'resolver maps locals 21/22 to gids 110/111' {
        ($script:Bat -match '"21" set "RESOLVED=110"') | Should -BeTrue
        ($script:Bat -match '"22" set "RESOLVED=111"') | Should -BeTrue
    }

    It 'dispatch cases run the same scripts the menu rows declare' {
        ($script:Bat -match '"110" \(call :Run "tools\\sync_opencode_config\.ps1" -Target All') | Should -BeTrue
        ($script:Bat -match '"111" \(call :Detached "OpenCode Config Sync Watcher" "-NoProfile" "tools\\watch_opencode_config_sync\.ps1"') | Should -BeTrue
        $r110 = $script:OcRows | Where-Object { $_.gid -eq 110 }
        $r111 = $script:OcRows | Where-Object { $_.gid -eq 111 }
        $r110.script | Should -Be 'tools/sync_opencode_config.ps1'
        ($r110.args -join ' ') | Should -Be '-Target All'
        $r111.script | Should -Be 'tools/watch_opencode_config_sync.ps1'
        $r111.mode | Should -Be 'detached'
    }

    It 'the OpenCode submenu renders both new rows' {
        ($script:Bat -match '"Sync configs to all clones"') | Should -BeTrue
        ($script:Bat -match '"Config sync watcher"') | Should -BeTrue
    }
}
