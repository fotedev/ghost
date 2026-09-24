# SPDX-License-Identifier: Apache-2.0
# Repository integrity tests: syntax gates + launcher/README drift guards.
# These exist so a rename or path change can never silently break the
# launchers (GHOST.bat/ghost.sh) or the documented entry points.
#
# Pester 6 scope note: It bodies see ONLY what they compute themselves
# ($PSScriptRoot is reliable; Describe/file-scope variables are not).
# Every It below is therefore fully self-contained; loops live INSIDE It
# bodies and throw a descriptive message on the first failure.

$script:bashAvailable = $null -ne (Get-Command bash -ErrorAction SilentlyContinue)

Describe "PowerShell syntax (Parser zero-errors)" {
    It "every .ps1 in src/windows and tools parses cleanly" {
        $files = @(
            (Get-ChildItem -Path (Join-Path $PSScriptRoot "..\src\windows") -Filter "*.ps1" -File) +
            (Get-ChildItem -Path (Join-Path $PSScriptRoot "..\tools") -Filter "*.ps1" -File -ErrorAction SilentlyContinue)
        )
        $files.Count | Should -BeGreaterThan 5
        $broken = @()
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
            if ($errors.Count -gt 0) {
                $broken += ("{0} line {1}: {2}" -f $file.Name, $errors[0].Extent.StartLineNumber, $errors[0].Message)
            }
        }
        if ($broken.Count -gt 0) {
            throw ("Syntax errors found:`n" + ($broken -join "`n"))
        }
    }
}

Describe "Bash syntax (bash -n)" -Skip:(-not $script:bashAvailable) {
    It "every .sh in src/linux plus ghost.sh passes bash -n" {
        $files = @(Get-ChildItem -Path (Join-Path $PSScriptRoot "..\src\linux") -Filter "*.sh" -File)
        $files += Get-Item -LiteralPath (Join-Path $PSScriptRoot "..\ghost.sh")
        $broken = @()
        foreach ($file in $files) {
            $null = & bash -n $file.FullName 2>&1
            if ($LASTEXITCODE -ne 0) {
                $broken += $file.Name
            }
        }
        $broken | Should -BeNullOrEmpty
    }
}

Describe "GHOST.bat dispatch integrity" {
    It "resolves every menu-dispatched script to an existing file" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        $raw = Get-Content -LiteralPath (Join-Path $repoRoot "GHOST.bat") -Raw
        # Direct -File "..." targets plus the script path argument handed to the
        # :Run / :RunWith / :Detached / :StartClone subroutines (which invoke
        # -File "%~N" themselves, so those %-tokens never match below).
        $targets = @([regex]::Matches($raw, '-File "([^"]+\.ps1)"') +
                     [regex]::Matches($raw, 'call :\w+\s+(?:"[^"]*"\s+)*?"((?:src|tools)\\[^"]+\.ps1)"') |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique)
        $targets.Count | Should -BeGreaterOrEqual 8

        # %~dp0 in GHOST.bat resolves to the repo root.
        $missing = @($targets |
            ForEach-Object { $_ -replace [regex]::Escape("%~dp0"), ($repoRoot + "\") } |
            Where-Object { -not (Test-Path -LiteralPath $_) })
        $missing | Should -BeNullOrEmpty

        $stale = @($targets | Where-Object { $_ -like "scripts\*" })
        $stale | Should -BeNullOrEmpty
    }
}

Describe "ghost.sh dispatch integrity" {
    It "resolves every \$LINUX_DIR target to an existing file in src/linux" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        $targets = @([regex]::Matches(
            (Get-Content -LiteralPath (Join-Path $repoRoot "ghost.sh") -Raw),
            '\$LINUX_DIR/([a-z_]+\.sh)') |
            ForEach-Object { $_.Groups[1].Value } |
            Select-Object -Unique)
        $targets.Count | Should -BeGreaterOrEqual 3

        $missing = @($targets | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot (Join-Path "src\linux" $_))) })
        $missing | Should -BeNullOrEmpty
    }
}

Describe "README consistency" {
    It "documents every current src script" {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\README.md") -Raw
        $files = @(
            (Get-ChildItem -Path (Join-Path $PSScriptRoot "..\src\windows") -Filter "*.ps1" -File) +
            (Get-ChildItem -Path (Join-Path $PSScriptRoot "..\src\linux") -Filter "*.sh" -File)
        )
        $missing = @($files | Where-Object { $readme -notmatch [regex]::Escape($_.Name) })
        $missing | Should -BeNullOrEmpty
    }

    It "does not reference superseded versioned filenames" {
        $readme = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\README.md") -Raw
        $readme | Should -Not -Match "reset_[a-z_]+_windows-v\d"
    }

    It "has no stale scripts/ paths in tracked text files (CHANGELOG exempt: rename history)" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        $hits = & git -C $repoRoot grep -l -E "scripts[/\\\\](windows|linux)" -- "*.md" "*.bat" "*.sh" "*.txt" "*.yml" ":!CHANGELOG.md" 2>$null
        @($hits).Count | Should -Be 0
    }
}

Describe "Governance files present" {
    It "has all governance/config files, non-empty" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        $missing = @()
        foreach ($name in @("LICENSE", "NOTICE", "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SECURITY.md", "CHANGELOG.md", ".env.example", ".gitattributes", "tests\PSScriptAnalyzerSettings.psd1")) {
            $p = Join-Path $repoRoot $name
            if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -le 0) {
                $missing += $name
            }
        }
        $missing | Should -BeNullOrEmpty
    }

    It "has .github workflows and issue templates" {
        $repoRoot = (Get-Item (Join-Path $PSScriptRoot "..")).FullName
        Test-Path -LiteralPath (Join-Path $repoRoot ".github\workflows\ci.yml") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repoRoot ".github\ISSUE_TEMPLATE\bug_report.yml") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repoRoot ".github\ISSUE_TEMPLATE\feature_request.yml") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repoRoot ".github\PULL_REQUEST_TEMPLATE.md") | Should -BeTrue
    }
}
