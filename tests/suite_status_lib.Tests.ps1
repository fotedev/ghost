#Requires -Version 5.1
# Tests for tools/suite_status_lib.ps1 - the shared cross-suite instance
# classifier (2026-11-21). Static contract pins + FUNCTIONAL classifier
# tests driven by injectable fake process snapshots (no live processes
# needed) and a temp-dir light-worker marker.

Describe 'Suite status lib - script hygiene + surface' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\suite_status_lib.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "suite_status_lib.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
        . $script:Path
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'covers all six suites (zcode, autoclaw2, cline, opencode, claudecode, codex)' {
        $names = Get-GhostSuiteNames
        foreach ($s in @('zcode', 'autoclaw2', 'cline', 'opencode', 'claudecode', 'codex')) {
            $names | Should -Contain $s
        }
    }

    It 'keeps the honest-labeling vocabulary (never guessed)' {
        ($script:Raw -match "'exe copy'") | Should -BeTrue
        ($script:Raw -match "'markers'") | Should -BeTrue
        ($script:Raw -match "'lockfile'") | Should -BeTrue
        ($script:Raw -match "'light worker'") | Should -BeTrue
        ($script:Raw -match 'UNCLASSIFIABLE externally') | Should -BeTrue
    }

    It 'carries the EC-K01 bare-exe main rule and the queue-based marker walk (the 2026-11-14 slice-pop fix)' {
        ($script:Raw -match "--type=") | Should -BeTrue
        ($script:Raw -match 'System\.Collections\.Queue') | Should -BeTrue
    }

    It 'claudecode is markers-only attribution (CLAUDE_CONFIG_DIR is env-only, never in argv)' {
        $script:GhostSuites['claudecode'].Attribution | Should -Be 'markers-only'
        foreach ($inst in $script:GhostSuites['claudecode'].Instances) {
            $inst.Markers.Count | Should -Be 0 -Because "claude-code has no command-line clone markers ($($inst.Key))"
            $inst.LightWorker | Should -BeTrue
        }
        $script:GhostSuites['claudecode'].WmiFamily | Should -Match 'node'
    }

    It 'codex is markers-only attribution (CODEX_HOME is env-only, never in argv)' {
        $script:GhostSuites['codex'].Attribution | Should -Be 'markers-only'
        foreach ($inst in $script:GhostSuites['codex'].Instances) {
            $inst.Markers.Count | Should -Be 0 -Because "codex has no command-line clone markers ($($inst.Key))"
            $inst.LightWorker | Should -BeTrue
            $inst.CloneHomeRel | Should -Match '^CodexClonesHome\\c[1-5]$'
        }
        $script:GhostSuites['codex'].WmiFamily | Should -Match 'codex'
        # the family filter must narrow the wide node% family to codex-shaped
        # processes only: the npm-shim cmdline path or the native exe NAME
        # (the classifier matches Name OR CommandLine)
        ('node "C:\U\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js" exec "hi"' -match $script:GhostSuites['codex'].CmdlineFamilyFilter) | Should -BeTrue
        ('codex.exe' -match $script:GhostSuites['codex'].CmdlineFamilyFilter) | Should -BeTrue
        ('codex' -match $script:GhostSuites['codex'].CmdlineFamilyFilter) | Should -BeTrue
        ('node "C:\U\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"' -match $script:GhostSuites['codex'].CmdlineFamilyFilter) | Should -BeFalse
    }

    It 'zcode defs match the frozen instance table (colors + copy exe names)' {
        $map = $script:GhostSuites['zcode'].Instances
        $map.Count | Should -Be 5
        ($map | Where-Object { $_.Key -eq 'Second' }).CopyExe | Should -Be 'ZCode-Blue.exe'
        ($map | Where-Object { $_.Key -eq 'Sixth' }).CopyExe | Should -Be 'ZCode-Orange.exe'
    }
}

Describe 'Suite status lib - functional classifier (fake snapshots)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot "..\tools\suite_status_lib.ps1")
        # Fake WMI-shaped process factory
        function New-FakeProc {
            param([int]$Id, [int]$Parent, [string]$Name, [string]$Cmd)
            [pscustomobject]@{ ProcessId = $Id; ParentProcessId = $Parent; Name = $Name; CommandLine = $Cmd }
        }
    }

    It 'attributes a copy-exe main to its clone (definitive exe-copy signal)' {
        $procs = @(
            (New-FakeProc -Id 100 -Parent 1 -Name 'ZCode-Blue.exe' -Cmd '"C:\install\ZCode-Blue.exe"'),
            (New-FakeProc -Id 101 -Parent 100 -Name 'ZCode-Blue.exe' -Cmd '"C:\install\ZCode-Blue.exe" --type=renderer')
        )
        $state = Get-GhostSuiteInstanceState -Suite zcode -Procs $procs -Windows @() -UserProfileOverride "$env:TEMP"
        $second = @($state.Rows | Where-Object { $_.Instance -eq 'Second' })[0]
        $second.State | Should -Be 'RUNNING'
        $second.Signal | Should -Be 'exe copy'
        $second.Pids | Should -Contain 100
    }

    It 'attributes a stock-exe main via the subtree marker walk (BFS, not guessing)' {
        $procs = @(
            (New-FakeProc -Id 200 -Parent 1 -Name 'ZCode.exe' -Cmd '"C:\install\ZCode.exe"'),
            (New-FakeProc -Id 201 -Parent 200 -Name 'ZCode.exe' -Cmd '"C:\install\ZCode.exe" --type=utility --user-data-dir=C:\Users\X\AppData\Roaming\ZCode-Third'),
            (New-FakeProc -Id 300 -Parent 1 -Name 'ZCode.exe' -Cmd '"C:\install\ZCode.exe"')
        )
        $state = Get-GhostSuiteInstanceState -Suite zcode -Procs $procs -Windows @() -UserProfileOverride "$env:TEMP"
        $third = @($state.Rows | Where-Object { $_.Instance -eq 'Third' })[0]
        $third.State | Should -Be 'RUNNING'
        $third.Signal | Should -Be 'markers'
        $third.Pids | Should -Contain 200
        # the second bare main (no markers anywhere) is the Primary
        $primary = @($state.Rows | Where-Object { $_.Instance -eq 'Primary' })[0]
        $primary.Signal | Should -Be 'bare main'
        $primary.Pids | Should -Contain 300
    }

    It 'a deep leaf marker (grandchild) still claims the tree (queue walk works past depth 1)' {
        $procs = @(
            (New-FakeProc -Id 400 -Parent 1 -Name 'OpenCode.exe' -Cmd '"C:\install\OpenCode.exe"'),
            (New-FakeProc -Id 401 -Parent 400 -Name 'OpenCode.exe' -Cmd '"C:\install\OpenCode.exe" --type=renderer'),
            (New-FakeProc -Id 402 -Parent 401 -Name 'OpenCode.exe' -Cmd '"C:\install\OpenCode.exe" --type=utility --opencode-clone-home=C:\Users\X\OpenCodeClonesHome\c2')
        )
        $state = Get-GhostSuiteInstanceState -Suite opencode -Procs $procs -Windows @() -UserProfileOverride "$env:TEMP"
        $c2 = @($state.Rows | Where-Object { $_.Instance -eq 'c2' })[0]
        $c2.State | Should -Be 'RUNNING'
        $c2.Signal | Should -Be 'markers'
        $c2.Pids | Should -Contain 400
    }

    It 'an autoclaw2 clone with no signals is UNCLASSIFIABLE, never guessed' {
        $procs = @(New-FakeProc -Id 500 -Parent 1 -Name 'AutoClaw2.exe' -Cmd '"C:\install\AutoClaw2.exe"')
        $state = Get-GhostSuiteInstanceState -Suite autoclaw2 -Procs $procs -Windows @() -UserProfileOverride "$env:TEMP"
        $primary = @($state.Rows | Where-Object { $_.Instance -eq 'Primary' })[0]
        $primary.Signal | Should -Be 'bare main'
        $primary.Note | Should -Match 'stock-exe clones'
        $c1 = @($state.Rows | Where-Object { $_.Instance -eq 'c1' })[0]
        $c1.State | Should -Be 'stopped'
    }

    It 'a held lockfile reports HELD and claims the instance' {
        $tmpDir = Join-Path $env:TEMP ("ghost-lock-test-" + [guid]::NewGuid().ToString('N'))
        $lockDir = Join-Path $tmpDir 'OpenCodeClonesHome\c1\desktop'
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
        $lockPath = Join-Path $lockDir 'lockfile'
        Set-Content -Path $lockPath -Value 'x' -Encoding Ascii
        $fs = [System.IO.File]::Open($lockPath, 'Open', 'Read', 'None')   # hold it exclusively
        try {
            $procs = @()
            $state = Get-GhostSuiteInstanceState -Suite opencode -Procs $procs -Windows @() -UserProfileOverride $tmpDir
            $c1 = @($state.Rows | Where-Object { $_.Instance -eq 'c1' })[0]
            $c1.Lock | Should -Be 'HELD'
            $c1.Signal | Should -Be 'lockfile'
            $c1.State | Should -Be 'RUNNING'
        }
        finally {
            $fs.Close()
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'claude-code: an alive light-worker marker claims its launcher child processes (markers-only attribution)' {
        $tmpDir = Join-Path $env:TEMP ("ghost-cc-test-" + [guid]::NewGuid().ToString('N'))
        $cloneHome = Join-Path $tmpDir 'ClaudeCodeClonesHome\c1'
        New-Item -ItemType Directory -Path $cloneHome -Force | Out-Null
        # the Pester run itself is a powershell/pwsh process - its $PID passes
        # the marker liveness check; a fake node child hangs under it
        . (Join-Path $PSScriptRoot "..\src\windows\ghost_light_marker.ps1")
        $markerPath = Join-Path $cloneHome '.ghost-light-worker.json'
        Write-GhostLightMarker -Path $markerPath -Suite 'claudecode' -Instance 'c1' -Mode 'repl'
        $procs = @(
            (New-FakeProc -Id 600 -Parent $PID -Name 'node.exe' -Cmd 'node "C:\Users\X\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"'),
            (New-FakeProc -Id 601 -Parent $PID -Name 'node.exe' -Cmd 'node "C:\Users\X\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js" -p "task"')
        )
        try {
            $state = Get-GhostSuiteInstanceState -Suite claudecode -Procs $procs -Windows @() -UserProfileOverride $tmpDir
            $c1 = @($state.Rows | Where-Object { $_.Instance -eq 'c1' })[0]
            $c1.State | Should -Be 'RUNNING'
            $c1.Signal | Should -Be 'light worker'
            $c1.Pids | Should -Contain 600
            $c1.LightWorker | Should -Match 'YES \(pid'
            # unclaimed family procs are the user's own usage
            $primary = @($state.Rows | Where-Object { $_.Instance -eq 'Primary' })[0]
            $primary.State | Should -Be 'stopped'
        }
        finally {
            Remove-GhostLightMarker -Path $markerPath
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'codex: an alive light-worker marker claims its launcher child processes (markers-only attribution)' {
        $tmpDir = Join-Path $env:TEMP ("ghost-cx-test-" + [guid]::NewGuid().ToString('N'))
        $cloneHome = Join-Path $tmpDir 'CodexClonesHome\c1'
        New-Item -ItemType Directory -Path $cloneHome -Force | Out-Null
        . (Join-Path $PSScriptRoot "..\src\windows\ghost_light_marker.ps1")
        $markerPath = Join-Path $cloneHome '.ghost-light-worker.json'
        Write-GhostLightMarker -Path $markerPath -Suite 'codex' -Instance 'c1' -Mode 'prompt'
        $procs = @(
            (New-FakeProc -Id 610 -Parent $PID -Name 'codex.exe' -Cmd '"C:\...\@openai\codex-win32-x64\vendor\bin\codex.exe" exec "task"'),
            (New-FakeProc -Id 611 -Parent $PID -Name 'node.exe' -Cmd 'node "C:\Users\X\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js"')
        )
        try {
            $state = Get-GhostSuiteInstanceState -Suite codex -Procs $procs -Windows @() -UserProfileOverride $tmpDir
            $c1 = @($state.Rows | Where-Object { $_.Instance -eq 'c1' })[0]
            $c1.State | Should -Be 'RUNNING'
            $c1.Signal | Should -Be 'light worker'
            $c1.Pids | Should -Contain 610
            $c1.Pids | Should -Contain 611
            $c1.LightWorker | Should -Match 'YES \(pid'
            $primary = @($state.Rows | Where-Object { $_.Instance -eq 'Primary' })[0]
            $primary.State | Should -Be 'stopped'
            $primary.Note | Should -Match 'default-profile codex usage'
        }
        finally {
            Remove-GhostLightMarker -Path $markerPath
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'claude-code: unclaimed family processes are the Primary (honest, not GHOST-managed)' {
        $procs = @(New-FakeProc -Id 700 -Parent 1 -Name 'node.exe' -Cmd 'node "C:\Users\X\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"')
        $tmpDir = Join-Path $env:TEMP ("ghost-cc-empty-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        try {
            $state = Get-GhostSuiteInstanceState -Suite claudecode -Procs $procs -Windows @() -UserProfileOverride $tmpDir
            $primary = @($state.Rows | Where-Object { $_.Instance -eq 'Primary' })[0]
            $primary.Signal | Should -Be 'bare main'
            $primary.Note | Should -Match 'not GHOST-managed'
            $c1 = @($state.Rows | Where-Object { $_.Instance -eq 'c1' })[0]
            $c1.State | Should -Be 'stopped'
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'a stale light-worker marker (pid dead or non-PowerShell) never reads as running' {
        $tmpDir = Join-Path $env:TEMP ("ghost-cc-stale-" + [guid]::NewGuid().ToString('N'))
        $cloneHome = Join-Path $tmpDir 'ClaudeCodeClonesHome\c3'
        New-Item -ItemType Directory -Path $cloneHome -Force | Out-Null
        Set-Content -Path (Join-Path $cloneHome '.ghost-light-worker.json') `
            -Value '{"suite":"claudecode","instance":"c3","pid":4,"mode":"repl","startedAt":"stale"}' -Encoding Ascii
        try {
            $procs = @(New-FakeProc -Id 800 -Parent 4 -Name 'node.exe' -Cmd 'node "C:\Users\X\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js"')
            $state = Get-GhostSuiteInstanceState -Suite claudecode -Procs $procs -Windows @() -UserProfileOverride $tmpDir
            $c3 = @($state.Rows | Where-Object { $_.Instance -eq 'c3' })[0]
            $c3.State | Should -Be 'stopped'
            $c3.LightWorker | Should -Be 'stale marker'
        }
        finally {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
