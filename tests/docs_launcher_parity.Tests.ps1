# SPDX-License-Identifier: Apache-2.0
# Docs <-> launcher parity (issue #2 item 3). GHOST.bat is the source of truth
# for the six submenus' row positions; docs/cli.md is the human map of them.
# The invariant this pins - the drift class caught 2026-11-20 (the cli.md
# header claimed [1]-[31]/[1]-[13]/[1]-[9]/[1]-[12] ceilings, three
# identity-reset headings cited pre-renumber rows, ~20 rows had no citation
# at all after the 2026-11-14..17 renumbers, and nothing failed):
#   1. every submenu row position the .bat renders is cited in docs/cli.md
#      ("<Name> [N]", or a "<Name> [N]-[M]" range that covers N);
#   2. the cli.md intro states the exact per-submenu ceilings;
#   3. the launcher-side wiring those citations hang off is itself sound:
#      every :Opt row resolves through its :*One resolver to a gid the
#      :DispatchOne table actually dispatches (and no dangling resolver case),
#      and menu.json renders the same rows in the same order as the .bat.
# No live scripts are run.

BeforeAll {
    $script:Repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:BatText = Get-Content -LiteralPath (Join-Path $Repo 'GHOST.bat') -Raw
    $script:Menu = Get-Content -LiteralPath (Join-Path $Repo 'src\desktop\menu.json') -Raw |
        ConvertFrom-Json
    $script:CliRaw = Get-Content -LiteralPath (Join-Path $Repo 'docs\cli.md') -Raw

    # GHOST.bat block label -> the submenu name docs/cli.md cites
    $script:BlockToName = [ordered]@{
        'RESETS'   = 'IDE Resets'
        'ZCODE'    = 'ZCode'
        'MAINT'    = 'Maintenance'
        'AUTOCLAW' = 'AutoClaw2'
        'CLINE'    = 'Cline'
        'OPENCODE' = 'OpenCode'
    }
    $script:BlockToResolver = @{
        'RESETS'   = 'ResetsOne'
        'ZCODE'    = 'ZCodeOne'
        'MAINT'    = 'MaintOne'
        'AUTOCLAW' = 'AutoClawOne'
        'CLINE'    = 'ClineOne'
        'OPENCODE' = 'OpenCodeOne'
    }

    # slice one :LABEL block: from its label line to the next line-start ':' label
    function Get-BatBlock {
        param([string]$Text, [string]$Label)
        $m = [regex]::Match($Text, "(?ms)^:$Label\r?\n(.*?)^:")
        if (-not $m.Success) { throw "could not locate the :$Label block in GHOST.bat" }
        return $m.Groups[1].Value
    }

    # the :Opt rows of a submenu block (local id + label); [0] Back is not a task row
    function Get-OptRows {
        param([string]$Block)
        $rows = @()
        foreach ($line in ($Block -split "`r?`n")) {
            if ($line -match '^\s*call :Opt (\S+) "([^"]*)"') {
                if ($Matches[1] -eq '0') { continue }
                $rows += [pscustomobject]@{ local = [int]$Matches[1]; label = $Matches[2] }
            }
        }
        return ,$rows
    }

    # a resolver's local id -> global task id cases
    function Get-ResolverCases {
        param([string]$Block)
        $map = @{}
        foreach ($line in ($Block -split "`r?`n")) {
            if ($line -match 'if "%~1"=="(\d+)"\s+set "RESOLVED=(\d+)"') {
                $map[[int]$Matches[1]] = [int]$Matches[2]
            }
        }
        return $map
    }

    # parse the six submenus: display name -> @{ Rows; ResolverCases; Max }
    $script:Submenus = [ordered]@{}
    foreach ($blockLabel in $BlockToName.Keys) {
        $name = $BlockToName[$blockLabel]
        $rows = Get-OptRows -Block (Get-BatBlock -Text $BatText -Label $blockLabel)
        $resolver = Get-ResolverCases -Block (
            Get-BatBlock -Text $BatText -Label $BlockToResolver[$blockLabel])
        $Submenus[$name] = @{
            Rows         = $rows
            ResolverCases = $resolver
            Max          = $rows.Count
        }
    }

    # dispatched gids (same parse shape as tests/ghost_hub_menu.Tests.ps1)
    $dispatchMatch = [regex]::Match($BatText, '(?ms)^:DispatchOne\r?\n(.*?)^:RunChain')
    if (-not $dispatchMatch.Success) { throw 'could not locate the :DispatchOne block in GHOST.bat' }
    $gids = @()
    foreach ($line in ($dispatchMatch.Groups[1].Value -split "`r?`n")) {
        if ($line -match '^if "%~1"=="(\d+)"') { $gids += [int]$Matches[1] }
    }
    $script:DispatchGids = @($gids | Sort-Object -Unique)

    # docs/cli.md scan surfaces. The body (from the first '## ' heading on) is
    # what per-row citations must cover - slicing the intro off means the
    # header's own "[1]-[N]" ranges can never satisfy the coverage check.
    # Both surfaces get whitespace collapsed so line-wrapped ranges match.
    $firstHeading = $CliRaw.IndexOf('## ')
    if ($firstHeading -lt 0) { throw 'docs/cli.md has no section headings' }
    $script:CliIntro = ($CliRaw.Substring(0, $firstHeading) -replace '\s+', ' ')
    $script:CliBody = ($CliRaw.Substring($firstHeading) -replace '\s+', ' ')

    # cited local ids for one submenu from the body: "<Name> [N]" plus
    # "<Name> [N]-[M]" ranges expanded to N..M
    function Get-CitedLocals {
        param([string]$SubmenuName)
        $cited = @()
        $esc = [regex]::Escape($SubmenuName)
        foreach ($m in [regex]::Matches($CliBody, "$esc \[(\d+)\](?:-(?:\[(\d+)\]|(\d+)))?")) {
            $lo = [int]$m.Groups[1].Value
            $hi = [int]$m.Groups[1].Value
            if ($m.Groups[2].Success) { $hi = [int]$m.Groups[2].Value }
            elseif ($m.Groups[3].Success) { $hi = [int]$m.Groups[3].Value }
            if ($hi -ge $lo -and ($hi - $lo) -le 100) { $cited += ($lo..$hi) }
        }
        return @($cited | Sort-Object -Unique)
    }
}

Describe 'GHOST.bat submenu wiring (the source of truth the docs hang off)' {
    It 'parses all six submenu blocks with ascending 1..N local ids' {
        $Submenus.Keys.Count | Should -Be 6
        foreach ($name in $Submenus.Keys) {
            $info = $Submenus[$name]
            $info.Rows.Count | Should -BeGreaterThan 0 -Because "the $name submenu must render rows"
            $locals = @($info.Rows | ForEach-Object { $_.local }) | Sort-Object
            ($locals -join ',') | Should -Be ((1..$info.Rows.Count) -join ',') -Because "$name local ids"
        }
    }

    It 'every :Opt row has a resolver case mapping to a dispatched gid, and no resolver case dangles' {
        foreach ($name in $Submenus.Keys) {
            $info = $Submenus[$name]
            $rowLocals = @($info.Rows | ForEach-Object { $_.local })
            $resolverLocals = @($info.ResolverCases.Keys | Sort-Object)
            $noCase = @($rowLocals | Where-Object { -not $info.ResolverCases.ContainsKey($_) })
            $noRow = @($resolverLocals | Where-Object { $rowLocals -notcontains $_ })
            $noCase | Should -Be @() -Because "$name rows without a resolver case: $($noCase -join ',')"
            $noRow | Should -Be @() -Because "$name resolver cases without a rendered row: $($noRow -join ',')"
            foreach ($local in $rowLocals) {
                $info.ResolverCases[$local] | Should -BeIn $DispatchGids -Because `
                    "$name [$local] resolves to gid $($info.ResolverCases[$local])"
            }
        }
    }

    It 'menu.json renders the same rows in the same order as every submenu (gid + label per position)' {
        foreach ($name in $Submenus.Keys) {
            $info = $Submenus[$name]
            $sec = @($Menu.sections | Where-Object { $_.name -eq $name })[0]
            $sec | Should -Not -BeNullOrEmpty -Because "menu.json must carry the $name section"
            $menuRows = @($sec.rows)
            $menuRows.Count | Should -Be $info.Rows.Count -Because "$name row count"
            for ($i = 0; $i -lt $info.Rows.Count; $i++) {
                $batRow = $info.Rows[$i]
                $gid = $info.ResolverCases[$batRow.local]
                # the one intentional spelling difference: the .bat writes
                # "Windsurf\Devin" (cmd-safe), menu.json "Windsurf/Devin"
                $batLabel = $batRow.label.Replace('\', '/')
                $menuRow = $menuRows[$i]
                $menuRow.gid | Should -Be $gid -Because "$name position $($batRow.local) (1-based)"
                $menuRow.label.Replace('\', '/') | Should -Be $batLabel -Because `
                    "$name [$($batRow.local)] label drift"
            }
        }
    }
}

Describe 'docs/cli.md parity with GHOST.bat' {
    It 'the intro states the exact six submenu ceilings' {
        $pattern = 'IDE Resets \[1\]-\[(\d+)\] / ZCode Multi-Instance & Clones \[1\]-\[(\d+)\] / ' +
            'System & GHOST Maintenance \[1\]-\[(\d+)\] / AutoClaw2 Multi-Instance & Clones \[1\]-\[(\d+)\] / ' +
            'Cline Multi-Instance & Clones \[1\]-\[(\d+)\] / OpenCode Multi-Instance & Clones \[1\]-\[(\d+)\]'
        $m = [regex]::Match($CliIntro, $pattern)
        $m.Success | Should -BeTrue -Because 'the cli.md intro must state all six submenu ranges'
        if ($m.Success) {
            $stated = @{
                'IDE Resets'  = [int]$m.Groups[1].Value
                'ZCode'       = [int]$m.Groups[2].Value
                'Maintenance' = [int]$m.Groups[3].Value
                'AutoClaw2'   = [int]$m.Groups[4].Value
                'Cline'       = [int]$m.Groups[5].Value
                'OpenCode'    = [int]$m.Groups[6].Value
            }
            foreach ($name in $Submenus.Keys) {
                $stated[$name] | Should -Be $Submenus[$name].Max -Because "$name submenu ceiling"
            }
        }
    }

    It 'the intro cites the main-menu [U] updater row' {
        $CliIntro | Should -Match '\[U\]'
    }

    It 'every submenu row position is cited in the docs/cli.md body' {
        $gaps = @()
        foreach ($name in $Submenus.Keys) {
            $cited = Get-CitedLocals -SubmenuName $name
            foreach ($r in $Submenus[$name].Rows) {
                if ($cited -notcontains $r.local) {
                    $gaps += "$name [$($r.local)] $($r.label)"
                }
            }
        }
        $gaps | Should -Be @() -Because `
            "docs/cli.md must cite every menu row (a '<Name> [N]' or '<Name> [N]-[M]' citation each); missing: $($gaps -join '; ')"
    }
}
