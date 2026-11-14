# SPDX-License-Identifier: Apache-2.0
# Parity + schema tests for the GHOST desktop launcher (GHOST.exe hub):
#   src/desktop/menu.json  - the GUI's menu data (loaded at runtime)
#   src/desktop/GhostHub.cs - the WinForms shell
#   GHOST.bat :DispatchOne - the console launcher's global task table
# The invariant: the exe can never silently drift from the .bat menu. Every
# gid the .bat dispatches must exist in menu.json with the same script and a
# wrapper-compatible mode, and vice versa. No live scripts are run.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Menu = Get-Content -LiteralPath (Join-Path $Repo 'src\desktop\menu.json') -Raw |
        ConvertFrom-Json
    $script:BatText = Get-Content -LiteralPath (Join-Path $Repo 'GHOST.bat') -Raw
    $script:HubText = Get-Content -LiteralPath (Join-Path $Repo 'src\desktop\GhostHub.cs') -Raw
    $script:BuildText = Get-Content -LiteralPath (Join-Path $Repo 'tools\build_ghost_exe.ps1') -Raw

    # flatten menu rows with their section name attached
    $script:AllRows = @()
    foreach ($sec in $Menu.sections) {
        foreach ($row in $sec.rows) {
            $row | Add-Member -NotePropertyName section -NotePropertyValue $sec.name -Force
            $AllRows += $row
        }
    }

    # known modes (the C# RunRow switch must handle exactly these)
    $script:KnownModes = @('inline', 'inline-note', 'zcode-reset', 'confirm-reset',
        'confirm-run', 'detached', 'windows-staggered', 'chain-pause')
    # gids retired with the AutoClaw v1.20 sunset (37-40), unused (63)
    # (74 = the AutoClaw2 MCP sync watcher - reserved 2026-11-04, LIVE 2026-11-14)
    $script:ReservedGids = @(37, 38, 39, 40, 63)

    # wrapper -> expected menu.json mode (:Run* wrappers, GHOST.bat)
    $script:ModeByWrapper = @{
        'Run'                = 'inline'
        'RunWith'            = 'inline-note'
        'RunZcodeReset'      = 'zcode-reset'
        'RunAc2Reset'        = 'zcode-reset'
        'RunClineReset'      = 'zcode-reset'
        'RunOpenCodeReset'   = 'zcode-reset'
        'ConfirmReset'       = 'confirm-reset'
        'ConfirmAc2Reset'    = 'confirm-reset'
        'ConfirmClineReset'  = 'confirm-reset'
        'ConfirmOpenCodeReset' = 'confirm-reset'
        'ConfirmRun'         = 'confirm-run'
        'Detached'           = 'detached'
        'StartClone'         = 'detached'
    }
    # wrapper -> index of the quoted token holding the script path
    # (:Detached = title, psFlags, script; :ConfirmReset/:ConfirmRun = label,
    # script; :ConfirmAc2Reset/:ConfirmClineReset/:ConfirmOpenCodeReset =
    # label, script)
    $script:ScriptArgIndex = @{
        'Run'                  = 0
        'RunWith'              = 0
        'RunZcodeReset'        = 0
        'RunAc2Reset'          = 0
        'RunClineReset'        = 0
        'RunOpenCodeReset'     = 0
        'ConfirmReset'         = 1
        'ConfirmAc2Reset'      = 1
        'ConfirmClineReset'    = 1
        'ConfirmOpenCodeReset' = 1
        'ConfirmRun'           = 1
        'Detached'             = 2
        'StartClone'           = 0
    }

    # parse :DispatchOne: single-line cases + multi-line block cases
    # (anchored on line-start labels - ':RunChain' also appears in a main-menu
    # call long before the dispatch block, and ':DispatchOne' in the resolver
    # calls before its label)
    $dispatchMatch = [regex]::Match($BatText, '(?ms)^:DispatchOne\r?\n(.*?)^:RunChain')
    if (-not $dispatchMatch.Success) { throw 'could not locate the :DispatchOne block in GHOST.bat' }
    $dispatch = $dispatchMatch.Groups[1].Value
    # tokenize a wrapper argument region: "quoted (may contain spaces)" or
    # bare words - the shape every :DispatchOne case uses
    function Split-BatTokens {
        param([string]$S)
        $out = @()
        foreach ($m in [regex]::Matches($S, '"([^"]*)"|(\S+)')) {
            if ($m.Groups[1].Success) { $out += $m.Groups[1].Value }
            else { $out += $m.Groups[2].Value }
        }
        return ,$out
    }
    $script:SingleLine = @{}   # gid -> @{ wrapper; script; tokens; full }
    $script:BlockGids = @()
    foreach ($line in ($dispatch -split "`r?`n")) {
        if ($line -match 'if "%~1"=="(\d+)"\s+\(call :(\w+)\s+(.+?) & exit /b\)') {
            $gid = [int]$Matches[1]
            $tokens = @([regex]::Matches($Matches[3], '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
            $SingleLine[$gid] = @{ wrapper = $Matches[2]; tokens = $tokens
                                   full = (Split-BatTokens $Matches[3]) }
        } elseif ($line -match '^if "%~1"=="(\d+)" \($') {
            $BlockGids += [int]$Matches[1]
        }
    }

    function Convert-RepoPath {
        param([string]$P)
        return ($P -replace '/', '\')
    }

    function Test-ScriptExists {
        param([string]$P)
        return (Test-Path -LiteralPath (Join-Path $Repo (Convert-RepoPath $P)))
    }

    # wrapper -> which full tokens carry the script's arguments (after the
    # wrapper's own slots: Run/RunZcodeReset = [script, args...];
    # RunWith = [script, note, args...]; ConfirmRun = [label, script, text,
    # args...]; Detached = [title, psFlags, script, argsString, notes...];
    # ConfirmReset = [label, script, argsString])
    function Get-BatArgs {
        param([string]$Wrapper, [string[]]$Full)
        switch ($Wrapper) {
            'Detached' {
                if ($Full.Count -gt 3 -and $Full[3]) {
                    return @($Full[3] -split '\s+' | Where-Object { $_ })
                }
                return @()
            }
            'ConfirmReset' {
                if ($Full.Count -gt 2 -and $Full[2]) {
                    return @($Full[2] -split '\s+' | Where-Object { $_ })
                }
                return @()
            }
            'ConfirmAc2Reset' {
                if ($Full.Count -gt 2 -and $Full[2]) {
                    return @($Full[2] -split '\s+' | Where-Object { $_ })
                }
                return @()
            }
            'ConfirmClineReset' {
                if ($Full.Count -gt 2 -and $Full[2]) {
                    return @($Full[2] -split '\s+' | Where-Object { $_ })
                }
                return @()
            }
            'ConfirmOpenCodeReset' {
                if ($Full.Count -gt 2 -and $Full[2]) {
                    return @($Full[2] -split '\s+' | Where-Object { $_ })
                }
                return @()
            }
            'Run'                { $rest = 1 }
            'RunZcodeReset'      { $rest = 1 }
            'RunAc2Reset'        { $rest = 1 }
            'RunClineReset'      { $rest = 1 }
            'RunOpenCodeReset'   { $rest = 1 }
            'RunWith'            { $rest = 2 }
            'ConfirmRun'         { $rest = 3 }
            default         { throw "unexpected wrapper '$Wrapper'" }
        }
        if ($Full.Count -gt $rest) { return @($Full[$rest..($Full.Count - 1)]) }
        return @()
    }
}

Describe 'menu.json schema' {
    It 'parses with the six GHOST.bat submenu sections in display order' {
        ($Menu.sections | ForEach-Object { $_.name }) -join ',' |
            Should -Be 'IDE Resets,ZCode,AutoClaw2,Cline,OpenCode,Maintenance'
    }

    It 'every row has a gid in the 1-104 range, unique per section, and no retired/reserved gid' {
        foreach ($sec in $Menu.sections) {
            $gids = @($sec.rows | ForEach-Object { $_.gid })
            ($gids | Select-Object -Unique).Count | Should -Be $gids.Count -Because "section '$($sec.name)'"
        }
        $gids = @($AllRows | ForEach-Object { $_.gid })
        $gids.Count | Should -BeGreaterThan 0
        foreach ($g in $gids) {
            $g | Should -BeGreaterThan 0
            $g | Should -BeLessOrEqual 104
            $ReservedGids | Should -Not -Contain $g
        }
    }

    It 'a gid shared across sections runs the identical script/args/mode (gid 7: IDE Resets [7] = ZCode [14])' {
        foreach ($d in @($AllRows | Group-Object gid | Where-Object { $_.Count -gt 1 })) {
            ($d.Group | Select-Object -ExpandProperty script -Unique).Count | Should -Be 1 -Because "gid $($d.Name)"
            ($d.Group | Select-Object -ExpandProperty mode -Unique).Count | Should -Be 1 -Because "gid $($d.Name)"
            ($d.Group | ForEach-Object { $_.args -join ' ' } | Select-Object -Unique).Count | Should -Be 1 -Because "gid $($d.Name)"
        }
        # gid 7 is the documented cross-menu duplicate (cli.md: IDE Resets [7] AND ZCode [14])
        (@($AllRows | Where-Object { $_.gid -eq 7 })).Count | Should -Be 2
    }

    It 'every row uses a known mode' {
        foreach ($r in $AllRows) {
            $r.mode | Should -BeIn $KnownModes -Because "gid $($r.gid) uses mode '$($r.mode)'"
        }
    }

    It 'action rows carry an existing script; block rows carry existing step scripts' {
        foreach ($r in $AllRows) {
            if ($r.mode -in @('windows-staggered', 'chain-pause')) {
                $r.steps.Count | Should -BeGreaterThan 0 -Because "gid $($r.gid) is a block row"
                foreach ($s in $r.steps) {
                    $s.script | Should -Not -BeNullOrEmpty
                    Test-ScriptExists $s.script | Should -BeTrue -Because "gid $($r.gid) step script $($s.script)"
                }
            } else {
                $r.script | Should -Not -BeNullOrEmpty -Because "gid $($r.gid) is an action row"
                Test-ScriptExists $r.script | Should -BeTrue -Because "gid $($r.gid) script $($r.script)"
            }
        }
    }

    It 'block rows carry the expected shape: gid 18 staggered with delays, 35/51/61 chain-pause' {
        $g18 = $AllRows | Where-Object { $_.gid -eq 18 }
        $g18.mode | Should -Be 'windows-staggered'
        $g18.steps.Count | Should -Be 5
        foreach ($s in $g18.steps) { $s.delaySec | Should -Be 3 }
        foreach ($g in @(35, 51, 61)) {
            $row = $AllRows | Where-Object { $_.gid -eq $g }
            $row.mode | Should -Be 'chain-pause'
            $row.steps.Count | Should -Be 5
        }
    }

    It 'block rows launch the right launcher script per suite' {
        ($AllRows | Where-Object { $_.gid -eq 18 }).steps.script | Select-Object -Unique |
            Should -Be 'src/windows/launch_zcode_second_instance.ps1'
        ($AllRows | Where-Object { $_.gid -eq 35 }).steps.script | Select-Object -Unique |
            Should -Be 'src/windows/launch_autoclaw2_clone.ps1'
        ($AllRows | Where-Object { $_.gid -eq 51 }).steps.script | Select-Object -Unique |
            Should -Be 'src/windows/launch_cline_clone.ps1'
        ($AllRows | Where-Object { $_.gid -eq 61 }).steps.script | Select-Object -Unique |
            Should -Be 'src/windows/launch_opencode_clone.ps1'
    }

    It 'confirmation rows carry a confirmText and destructive ZCode resets use the reset wrapper mode' {
        foreach ($g in @(1, 12, 21, 66)) {
            $row = @($AllRows | Where-Object { $_.gid -eq $g })[0]
            $row.confirmText | Should -Not -BeNullOrEmpty -Because "gid $g is a confirmed action"
        }
        foreach ($g in @(7, 11, 19, 20, 42, 65)) {
            (@($AllRows | Where-Object { $_.gid -eq $g })[0]).mode | Should -Be 'zcode-reset'
        }
    }
}

Describe 'menu.json matches GHOST.bat :DispatchOne parity' {
    It 'every dispatched gid exists in menu.json and every menu gid is dispatched' {
        $dispatchGids = @($SingleLine.Keys) + $BlockGids | ForEach-Object { [int]$_ } | Sort-Object -Unique
        $menuGids = @($AllRows | ForEach-Object { $_.gid }) | Sort-Object -Unique
        $missingFromMenu = @($dispatchGids | Where-Object { $menuGids -notcontains $_ })
        $missingFromDispatch = @($menuGids | Where-Object { $dispatchGids -notcontains $_ })
        $missingFromMenu | Should -Be @() -Because "dispatched gids absent from menu.json: $($missingFromMenu -join ',')"
        $missingFromDispatch | Should -Be @() -Because "menu.json gids absent from :DispatchOne: $($missingFromDispatch -join ',')"
    }

    It 'the .bat dispatch table was actually parsed (sanity: 60+ single-line cases, 4 block cases)' {
        $SingleLine.Count | Should -BeGreaterThan 60
        $BlockGids | Sort-Object | Should -Be @(18, 35, 51, 61)
    }

    It 'each action gid maps to the same script as its .bat dispatch case' {
        foreach ($gid in $SingleLine.Keys) {
            $case = $SingleLine[$gid]
            $row = @($AllRows | Where-Object { $_.gid -eq [int]$gid })[0]
            $row | Should -Not -BeNullOrEmpty -Because "gid $gid"
            $idx = $ScriptArgIndex[$case.wrapper]
            $batScript = $case.tokens[$idx]
            (Convert-RepoPath $row.script) | Should -Be (Convert-RepoPath $batScript) -Because "gid $gid"
        }
    }

    It 'each action gid passes the same arguments as its .bat dispatch case' {
        foreach ($gid in $SingleLine.Keys) {
            $case = $SingleLine[$gid]
            $row = @($AllRows | Where-Object { $_.gid -eq [int]$gid })[0]
            $row | Should -Not -BeNullOrEmpty -Because "gid $gid"
            $batArgs = @(Get-BatArgs -Wrapper $case.wrapper -Full $case.full)
            if ($case.wrapper -eq 'RunWith') {
                # -WaitForClose is the .bat spelling of menu.json's waitForClose flag
                $batHasWait = ($batArgs -contains '-WaitForClose')
                $batArgs = @($batArgs | Where-Object { $_ -ne '-WaitForClose' })
                ([bool]$row.waitForClose) | Should -Be $batHasWait -Because "gid $gid waitForClose parity"
            }
            if ($case.wrapper -eq 'Detached') {
                $row.title | Should -Be $case.full[0] -Because "gid $gid detached title"
                $row.psFlags | Should -Be $case.full[1] -Because "gid $gid detached psFlags"
            }
            $because = "gid $gid args drift - the .bat passes '{0}' but menu.json says '{1}' (the 2026-11-11 gid 76 class: a missing flag makes the hub row fail on its own script)" -f
                ($batArgs -join ' '), (@($row.args) -join ' ')
            @($row.args) | Should -Be $batArgs -Because $because
        }
    }

    It 'each action gid uses a wrapper-compatible mode' {
        foreach ($gid in $SingleLine.Keys) {
            $case = $SingleLine[$gid]
            $row = @($AllRows | Where-Object { $_.gid -eq [int]$gid })[0]
            $row.mode | Should -Be $ModeByWrapper[$case.wrapper] -Because "gid $gid dispatches through :$($case.wrapper)"
        }
    }
}

Describe 'GhostHub.cs rot-guard' {
    It 'loads menu.json at runtime and handles every known mode' {
        $HubText | Should -Match 'menu\.json'
        foreach ($m in $KnownModes) {
            $HubText | Should -Match ([regex]::Escape('"' + $m + '"')) -Because "RunRow must handle mode $m"
        }
    }

    It 'spawns powershell with -ExecutionPolicy Bypass and powers the UAC guard' {
        $HubText | Should -Match '-ExecutionPolicy Bypass'
        $HubText | Should -Match 'WindowsPrincipal'
        $HubText | Should -Match 'ghost-hub'
    }
}

Describe 'build_ghost_exe.ps1 inputs' {
    It 'compiles GhostHub.cs with the manifest, icon and serializer reference' {
        $BuildText | Should -Match 'GhostHub\.cs'
        $BuildText | Should -Match 'app\.manifest'
        $BuildText | Should -Match 'win32icon'
        $BuildText | Should -Match 'System\.Web\.Extensions\.dll'
    }

    It 'stamps the version from the first released CHANGELOG section' {
        $BuildText | Should -Match ([regex]::Escape('## \[(\d+\.\d+\.\d+)\]'))
        $changelog = Get-Content -LiteralPath (Join-Path $Repo 'CHANGELOG.md') -Raw
        ($changelog -match '(?m)^## \[(\d+\.\d+\.\d+)\]') | Should -BeTrue
    }
}
