# SPDX-License-Identifier: Apache-2.0
# Tests for the Cline window-identity work (CS-2, 2026-11-17): the
# launcher-side stamp step in launch_cline_clone.ps1 (docs/
# CLINE_WINDOW_IDENTITY_PLAN.md §3) + the read-only Phase-0 probe tool
# (tools/probe_cline_window.ps1). Static contract only - the live stamp
# behavior (real window grouping, restart survival = probe d) is
# user-supervised acceptance per the plan.

Describe 'Cline window stamp - launcher contract' {
    BeforeAll {
        $script:LauncherPath = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_cline_clone.ps1")).Path
        $tokens = $null; $errors = $null
        $script:LauncherAst = [System.Management.Automation.Language.Parser]::ParseFile($script:LauncherPath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_cline_clone.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:LauncherPath)
    }

    It 'still parses with the stamp additions' {
        $errors.Count | Should -Be 0
    }

    It 'imports PropVariantClear from OLE32 - never oleaut32 (ground truth #6)' {
        ($script:Raw -match [regex]::Escape('[DllImport("ole32.dll")] public static extern int PropVariantClear(ref PROPVARIANT pv);')) | Should -BeTrue
        ($script:Raw -match [regex]::Escape('oleaut32.dll")] public static extern int PropVariantClear')) | Should -BeFalse
    }

    It 'stamps the shortcut-matching AUMID bot.cline.app.cN' {
        ($script:Raw -match '\$wantAumid = "bot\.cline\.app\.\$Instance"') | Should -BeTrue
    }

    It 'stamps only its OWN child process (never WebView2 children)' {
        ($script:Raw -match '\$proc\.MainWindowHandle') | Should -BeTrue
        # no code may enumerate or touch the WebView2 render children
        ($script:Raw -match "(Get-Process|Get-CimInstance).*msedgewebview2") | Should -BeFalse -Because 'WebView2 render children are outside the stamp contract'
    }

    It 're-stamps on main-window handle change inside the poll (splash-swap tolerant)' {
        ($script:Raw -match '\$stampLastHandle') | Should -BeTrue
        ($script:Raw -match '\[ClineWindowAumid\]::Stamp\(\$proc\.MainWindowHandle') | Should -BeTrue
    }

    It 'verifies by read-back and degrades loudly WITHOUT blocking the launch' {
        ($script:Raw -match "read-back .* != wanted") | Should -BeTrue
        ($script:Raw -match 'Identity is cosmetic; the launch stands') | Should -BeTrue
    }

    It 'guards the Add-Type against an in-session re-run (the ZcodeWindowAumid lesson)' {
        ($script:Raw -match "if \(-not \('ClineWindowAumid' -as \[type\]\)\)") | Should -BeTrue
    }

    It '-Status reports the live window AUMID' {
        ($script:Raw -match "'window aumid :") | Should -BeTrue
        ($script:Raw -match '\[ClineWindowAumid\]::Read\(\$live\.MainWindowHandle\)') | Should -BeTrue
    }

    It 'sets a distinct window title "Cline <Color> vN" (the pin-collision guard)' {
        ($script:Raw -match '"Cline \$CloneColor v\$exeVersion"') | Should -BeTrue
        ($script:Raw -match 'SetWindowTextW\(\$proc\.MainWindowHandle, \$wantTitle\)') | Should -BeTrue
    }
}

Describe 'Cline window probe tool (Phase-0, read-only)' {
    BeforeAll {
        $script:ProbePath = (Resolve-Path (Join-Path $PSScriptRoot "..\tools\probe_cline_window.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:ProbePath, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "probe_cline_window.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:ProbePath)
    }

    It 'is read-only by contract (no SetValue/Commit outside the interop definition, no writes)' {
        ($script:Raw -match 'store\.SetValue') | Should -BeFalse -Because 'the probe must never stamp'
        ($script:Raw -match 'SetWindowTextW\(') | Should -BeFalse -Because 'the probe must never rename windows'
    }

    It 'scans the exe for the process-explicit AUMID API (probe a)' {
        ($script:Raw -match 'SetCurrentProcessExplicitAppUserModelID') | Should -BeTrue
    }

    It 'classifies WebView2 children per cline-app pid (probe b)' {
        ($script:Raw -match 'msedgewebview2') | Should -BeTrue
    }

    It 'reports window class + title + store AUMID (probes a/c)' {
        ($script:Raw -match 'GetClassNameW') | Should -BeTrue
        ($script:Raw -match 'store AUMID') | Should -BeTrue
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:ProbePath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }
}
