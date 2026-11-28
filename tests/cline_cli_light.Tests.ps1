# SPDX-License-Identifier: Apache-2.0
# Tests for the Cline light worker (2026-11-17): src/windows/
# launch_cline_cli_light.ps1 - the cline-cli.exe headless worker on the
# clone's own CLINE_DIR state (the ZCode/OpenCode light-worker pattern; the
# CLI is the desktop install's own Bun SEA binary). Static contract only -
# the live behaviors that stay user-supervised acceptance are documented in
# the script header (hub attach while the desktop clone runs, login
# persistence location).

Describe 'Cline light worker - launcher contract' {
    BeforeAll {
        $script:ScriptPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_cline_cli_light.ps1")).Path
        $tokens = $null; $errors = $null
        $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_cline_cli_light.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:ScriptPath)
        $script:DesktopLauncherRaw = [System.IO.File]::ReadAllText((Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_cline_clone.ps1")).Path)
    }

    It 'parses clean' {
        $errors.Count | Should -Be 0
    }

    It 'follows the tracked .ps1 file conventions (UTF-8 BOM + CRLF)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ([System.IO.File]::ReadAllText($script:ScriptPath) -match "`r`n") | Should -BeTrue
    }

    It 'resolves the binary through the documented ladder (override, desktop install, PATH) with a functional --version probe' {
        ($script:Raw -match [regex]::Escape("Join-Path `$LocalAppData 'Cline\cline-cli.exe'")) | Should -BeTrue
        ($script:Raw -match "Get-Command 'cline'") | Should -BeTrue
        ($script:Raw -match '--version') | Should -BeTrue
        # the probe gates on exit code + a bare semver shape ("3.0.74"), never a bare path hit
        ($script:Raw -match [regex]::Escape("if (`$LASTEXITCODE -eq 0 -and (`"`$v`") -match '^\d+\.\d+')")) | Should -BeTrue
    }

    It 'fails loud when no functional binary is found (remediation, never silent)' {
        ($script:Raw -match 'cline-cli\.exe not found or non-functional') | Should -BeTrue
    }

    It 'carries the frozen c1..c5 port plan matching launch_cline_clone.ps1 (drift tripwire)' {
        foreach ($port in @('25471', '3131', '25472', '3132', '25473', '3133', '25474', '3134', '25475', '3135')) {
            ($script:Raw -match $port) | Should -BeTrue -Because "port $port is part of the frozen clone port plan"
        }
        # every hub port the desktop launcher pins must appear in the light worker too
        $desktopPorts = [regex]::Matches($script:DesktopLauncherRaw, "Hub = (\d+); Sidecar = (\d+)") |
            ForEach-Object { @($_.Groups[1].Value, $_.Groups[2].Value) } | Select-Object -Unique
        $desktopPorts.Count | Should -Be 10 -Because 'the desktop launcher defines 5 hub + 5 sidecar ports'
        foreach ($p in $desktopPorts) {
            ($script:Raw -match [regex]::Escape($p)) | Should -BeTrue -Because "port $p must not drift between the desktop launcher and the light worker"
        }
    }

    It 'isolates via the SAME env levers the desktop clone launcher uses (CLINE_DIR + clone ports)' {
        ($script:Raw -match '\$env:CLINE_DIR = \$CloneDir') | Should -BeTrue
        ($script:Raw -match '\$env:CLINE_HUB_PORT') | Should -BeTrue
        ($script:Raw -match '\$env:CLINE_SIDECAR_PORT') | Should -BeTrue
    }

    It 'refuses an unseeded clone home with the launch-once remediation' {
        ($script:Raw -match [regex]::Escape('Launch its desktop instance once (GHOST.bat Cline [1]-[5]) to create it, then retry.')) | Should -BeTrue
    }

    It 'warns (never blocks) when the desktop clone holds the hub lock - shared-home semantics' {
        ($script:Raw -match [regex]::Escape('data\locks\hub\production.json.instance.lock')) | Should -BeTrue
        ($script:Raw -match 'appears RUNNING \(hub lock held\)') | Should -BeTrue
        # the lock branch may only Write-Host WARNINGS - no throw/exit inside it
        $lockBlock = [regex]::Match($script:Raw, 'if \(Test-Path -LiteralPath \$HubLock\)[\s\S]*?^\}', 'Multiline').Value
        ($lockBlock -match '(throw|exit )') | Should -BeFalse -Because 'a running desktop clone must not block the light worker'
    }

    It 'one-shot mode appends the prompt positionally and passes the documented headless flags' {
        ($script:Raw -match [regex]::Escape('if ($Json) { $runArgs += ''--json'' }')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('@(''--auto-approve'', ''false'')')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('$runArgs += ''-y''')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('@(''-t'', "$Timeout")')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('@(''-m'', $Model)')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('$runArgs += $Prompt')) | Should -BeTrue
    }

    It 'rejects contradictory approval policies (-Yolo + -NoAutoApprove)' {
        ($script:Raw -match '-Yolo and -NoAutoApprove are mutually exclusive') | Should -BeTrue
    }

    It 'binds the working directory on BOTH mechanisms (the OpenCode stale-PWD lesson)' {
        ($script:Raw -match '\$env:PWD = \$Cwd') | Should -BeTrue
        ($script:Raw -match '\[Environment\]::CurrentDirectory = \$Cwd') | Should -BeTrue
    }

    It '-Auth is interactive-only and gated on the CLI exit code (no file-verified persistence claim)' {
        ($script:Raw -match '-Auth is an interactive mode and cannot combine with -Prompt\.') | Should -BeTrue
        ($script:Raw -match '& \$CliExe auth') | Should -BeTrue
        ($script:Raw -match 'no file-verified') | Should -BeTrue
    }

    It 'does not capture the CLI call in a pipeline (the swallowed-stdout lesson)' {
        ($script:Raw -match '& \$CliExe @runArgs') | Should -BeTrue
        ($script:Raw -match '& \$CliExe\r\n') | Should -BeTrue
    }

    It 'documents its honest limits in the header (hub attach + login persistence unverified)' {
        ($script:Raw -match 'attach') | Should -BeTrue
        ($script:Raw -match 'UNVERIFIED') | Should -BeTrue
    }
}

Describe 'Cline light worker - menu wiring' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        $script:BatRaw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "GHOST.bat"))
        $script:MenuRaw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "src\desktop\menu.json"))
    }

    It 'resolves Cline locals 22/23 to gids 122/123 in :ClineOne' {
        ($script:BatRaw -match [regex]::Escape('if "%~1"=="22" set "RESOLVED=122"')) | Should -BeTrue
        ($script:BatRaw -match [regex]::Escape('if "%~1"=="23" set "RESOLVED=123"')) | Should -BeTrue
    }

    It 'dispatches gids 122/123 as detached rows of the light-worker script' {
        ($script:BatRaw -match [regex]::Escape('if "%~1"=="122" (call :Detached "Cline Light Worker" "-NoProfile" "src\windows\launch_cline_cli_light.ps1"')) | Should -BeTrue
        ($script:BatRaw -match [regex]::Escape('if "%~1"=="123" (call :Detached "Cline Clone CLI Login" "-NoProfile" "src\windows\launch_cline_cli_light.ps1" "-Auth"')) | Should -BeTrue
    }

    It 'menu.json carries gid 122/123 in the Cline section with the right modes' {
        $menu = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "src\desktop\menu.json")) | ConvertFrom-Json
        $cline = $menu.sections | Where-Object { $_.name -eq 'Cline' }
        $r122 = $cline.rows | Where-Object { $_.gid -eq 122 }
        $r123 = $cline.rows | Where-Object { $_.gid -eq 123 }
        $r122 | Should -Not -BeNullOrEmpty
        $r122.script | Should -Be 'src/windows/launch_cline_cli_light.ps1'
        $r122.mode | Should -Be 'detached'
        $r123 | Should -Not -BeNullOrEmpty
        ($r123.args -join ' ') | Should -Be '-Auth'
    }
}
