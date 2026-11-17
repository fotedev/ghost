# SPDX-License-Identifier: Apache-2.0
# Tests for tools/watch_suite_taskbar.ps1 - the generic AutoClaw2/OpenCode
# taskbar-identity watcher (the ZCode watcher mechanics parameterized,
# 2026-11-17). Static contract: the live stamp behavior is user-supervised
# acceptance (the watcher ships off by default; the launchers' ensure-steps
# are NOT wired for it - the menu row is the entry point).

Describe 'Suite taskbar watcher - script hygiene' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\watch_suite_taskbar.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "watch_suite_taskbar.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'declares #Requires -Version 5.1' {
        (Get-Content -LiteralPath $script:Path -TotalCount 1) -match '#Requires -Version 5.1' | Should -BeTrue
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }
}

Describe 'Suite taskbar watcher - suite surface' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\watch_suite_taskbar.ps1")).Path
        $tokens = $null; $errors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It '-Suite is MANDATORY and limited to autoclaw2|opencode (Cline excluded by plan)' {
        $pb = $script:Ast.ParamBlock
        $suiteParam = $pb.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Suite' }
        $suiteParam | Should -Not -BeNullOrEmpty
        $attrs = ($suiteParam.Attributes | ForEach-Object { $_.TypeName.Name }) -join ','
        ($suiteParam.Attributes | ForEach-Object { "$_" }) -join ' ' | Should -Match 'autoclaw2'
        "$($suiteParam.Attributes)" | Should -Match 'opencode'
        "$($suiteParam.Attributes)" | Should -Not -Match 'cline'
    }

    It 'declares the resident surface (RunOnce/IntervalSeconds/LogFile/InstallAutostart/RemoveAutostart)' {
        $names = @($script:Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($n in @('RunOnce', 'IntervalSeconds', 'LogFile', 'InstallAutostart', 'RemoveAutostart')) {
            @($names) | Should -Contain $n
        }
    }

    It 'uses the suite-owned AUMID bases + mutexes + log dirs + Startup .lnk names' {
        ($script:Raw -match "'com\.zhipuai\.autoclaw2'") | Should -BeTrue
        ($script:Raw -match "'ai\.opencode\.desktop'") | Should -BeTrue
        ($script:Raw -match "'Autoclaw2TaskbarIdentityWatcher'") | Should -BeTrue
        ($script:Raw -match "'OpencodeTaskbarIdentityWatcher'") | Should -BeTrue
        ($script:Raw -match 'watch-autoclaw2-taskbar') | Should -BeTrue
        ($script:Raw -match 'watch-opencode-taskbar') | Should -BeTrue
        ($script:Raw -match [regex]::Escape('AutoClaw2 taskbar identity.lnk')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('OpenCode taskbar identity.lnk')) | Should -BeTrue
    }
}

Describe 'Suite taskbar watcher - mechanics contract' {
    BeforeAll {
        $script:Raw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\tools\watch_suite_taskbar.ps1")).Path)
    }

    It 'imports PropVariantClear from OLE32 - never oleaut32 (ground truth #6)' {
        ($script:Raw -match [regex]::Escape('[DllImport("ole32.dll")] public static extern int PropVariantClear(ref PROPVARIANT pv);')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('oleaut32.dll")] public static extern int PropVariantClear')) | Should -BeFalse
    }

    It 'classifies by per-color exe copy FIRST, then argv markers, then the opencode title map' {
        ($script:Raw -match 'Copy-exe identity FIRST') | Should -BeTrue
        ($script:Raw -match [regex]::Escape("if (`$Suite -eq 'opencode') { `$markers = @(`"OpenCodeClonesHome\c`$i`") }")) | Should -BeTrue -Because 'argv markers exist ONLY for opencode (autoclaw2 passes env, not argv)'
        ($script:Raw -match "'OpenCode Blue'") | Should -BeTrue
    }

    It 'covers the whole copy family via the suite WMI filter (never a bare exe name)' {
        ($script:Raw -match "Name LIKE 'AutoClaw2%'") | Should -BeTrue
        ($script:Raw -match "Name LIKE 'OpenCode%'") | Should -BeTrue
    }

    It 'is honest about the stock-exe AutoClaw2 limit (warn + skip, never re-stamp to base)' {
        ($script:Raw -match 'classifies as Primary \(stock-exe AutoClaw2 clone') | Should -BeTrue
        ($script:Raw -match 'left alone') | Should -BeTrue
    }

    It 'kicks via the .kick toggle and verifies the final stamp by re-read' {
        ($script:Raw -match '\.kick') | Should -BeTrue
        ($script:Raw -match 'FAILED - read-back') | Should -BeTrue
    }

    It 'guards single instance per suite (named mutex + startup process scan incl. -Suite scoping)' {
        ($script:Raw -match 'Get-OtherWatcherPids') | Should -BeTrue
        ($script:Raw -match '\$suiteArg') | Should -BeTrue
    }

    It 'primary-lnk hijack guard shells out to the installer -RepairPrimaryAumid (120s cap) and verifies by re-read' {
        ($script:Raw -match '-RepairPrimaryAumid') | Should -BeTrue
        ($script:Raw -match 'WaitForExit\(120000\)') | Should -BeTrue
        ($script:Raw -match 'CreateNoWindow = \$true') | Should -BeTrue
        ($script:Raw -match 'Verify-after re-read') | Should -BeTrue
    }

    It 'hijack predicate = AUMID equal to a CLONE identity (read via Shell ExtendedProperty)' {
        ($script:Raw -match "ExtendedProperty\('System\.AppUserModel\.ID'\)") | Should -BeTrue
        ($script:Raw -match '\$cloneAumids -contains \$id') | Should -BeTrue
    }
}

Describe 'GHOST.bat + menu.json wiring for gids 114/115' {
    BeforeAll {
        $script:Bat = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\GHOST.bat")).Path)
        $script:Menu = Get-Content -LiteralPath (Resolve-Path (Join-Path $PSScriptRoot "..\src\desktop\menu.json")).Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    It 'resolvers map locals 23 to gids 114 (AutoClaw2) and 115 (OpenCode)' {
        ($script:Bat -match '"23" set "RESOLVED=114"') | Should -BeTrue
        ($script:Bat -match '"23" set "RESOLVED=115"') | Should -BeTrue
    }

    It 'dispatch cases carry the -Suite argument' {
        ($script:Bat -match '"114" \(call :Detached "AutoClaw2 Taskbar Watcher" "-NoProfile" "tools\\watch_suite_taskbar\.ps1" "-Suite autoclaw2"') | Should -BeTrue
        ($script:Bat -match '"115" \(call :Detached "OpenCode Taskbar Watcher" "-NoProfile" "tools\\watch_suite_taskbar\.ps1" "-Suite opencode"') | Should -BeTrue
    }

    It 'menu rows match the dispatch args per suite' {
        $r114 = @(($script:Menu.sections | Where-Object { $_.name -eq 'AutoClaw2' }).rows) | Where-Object { $_.gid -eq 114 }
        $r115 = @(($script:Menu.sections | Where-Object { $_.name -eq 'OpenCode' }).rows) | Where-Object { $_.gid -eq 115 }
        $r114.script | Should -Be 'tools/watch_suite_taskbar.ps1'
        ($r114.args -join ' ') | Should -Be '-Suite autoclaw2'
        $r115.script | Should -Be 'tools/watch_suite_taskbar.ps1'
        ($r115.args -join ' ') | Should -Be '-Suite opencode'
    }

    It 'both submenus render the watcher row at local 23' {
        ($script:Bat -match 'Opt 23 "Taskbar identity watcher"') | Should -BeTrue
    }
}
