# Dry-run parity for the five classic Windows resetters (issue #2 item 1,
# 2026-11-20): reset_cursor/trae/devin/minimax_opencode/qoder gained the
# W1-9-style report-only planner (the reset_zcode pattern) — planner BEFORE
# self-elevation (a plan never triggers UAC), hand-maintained step list
# cross-checked against the real "--- [N/M]" step headings (drift tripwire),
# and a functional zero-write probe under a fully redirected environment.

Describe 'reset dry-run parity (issue #2 item 1)' {
    BeforeAll {
        $script:RepoRoot = (Get-Item $PSScriptRoot).Parent.FullName
    }

    It '<Name>: declares -DryRun with the planner before self-elevation (no UAC path first)' -ForEach @(
        @{ Name = 'cursor';  File = 'reset_cursor.ps1' }
        @{ Name = 'trae';    File = 'reset_trae.ps1' }
        @{ Name = 'devin';   File = 'reset_devin.ps1' }
        @{ Name = 'minimax'; File = 'reset_minimax_opencode.ps1' }
        @{ Name = 'qoder';   File = 'reset_qoder.ps1' }
    ) {
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot ("src\windows\" + $File)))
        $raw | Should -Match '\[switch\]\$DryRun'
        $raw | Should -Match 'DRY-RUN PLAN'
        $raw | Should -Match 'DRY-RUN complete - nothing was written or killed'
        # the planner must sit before the self-elevation Start-Process so a
        # report-only run never triggers UAC
        ($raw.IndexOf('DRY-RUN PLAN')) | Should -BeLessThan ($raw.IndexOf('-Verb RunAs'))
    }

    It '<Name>: planner exits 0 and contains no write primitives' -ForEach @(
        @{ Name = 'cursor';  File = 'reset_cursor.ps1' }
        @{ Name = 'trae';    File = 'reset_trae.ps1' }
        @{ Name = 'devin';   File = 'reset_devin.ps1' }
        @{ Name = 'minimax'; File = 'reset_minimax_opencode.ps1' }
        @{ Name = 'qoder';   File = 'reset_qoder.ps1' }
    ) {
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot ("src\windows\" + $File)))
        # planner body = from its header to the "DRY-RUN complete" line: no
        # write/kill primitive may appear there; the trailing "exit 0" (after
        # the completion line, before self-elevation) is asserted separately
        $plannerStart = $raw.IndexOf('DRY-RUN PLAN')
        $plannerBody = $raw.Substring($plannerStart, $raw.IndexOf('DRY-RUN complete') - $plannerStart)
        $plannerBody | Should -Not -Match 'New-Item|WriteAllText|Add-Content|Start-Process|taskkill'
        $raw.Substring($raw.IndexOf('DRY-RUN complete'), $raw.IndexOf('-Verb RunAs') - $raw.IndexOf('DRY-RUN complete')) |
            Should -Match 'exit 0'
    }

    It '<Name>: planner step list matches the real step headings (drift tripwire)' -ForEach @(
        @{ Name = 'cursor';  File = 'reset_cursor.ps1' }
        @{ Name = 'trae';    File = 'reset_trae.ps1' }
        @{ Name = 'devin';   File = 'reset_devin.ps1' }
        @{ Name = 'minimax'; File = 'reset_minimax_opencode.ps1' }
        @{ Name = 'qoder';   File = 'reset_qoder.ps1' }
    ) {
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot ("src\windows\" + $File)))
        $stepHeads = @([regex]::Matches($raw, '#\s*---\s*\[(\d+[a-z]?)/(\d+)\]') |
            ForEach-Object { "{0}/{1}" -f $_.Groups[1].Value, $_.Groups[2].Value })
        $plannerRegion = $raw.Substring(0, $raw.IndexOf('-Verb RunAs'))
        # scan from the "Step plan" heading onward: a planner intro line that
        # mentions step ranges in [N/M] form (devin's does) must not count
        $scanFrom = $plannerRegion.LastIndexOf('Step plan')
        $planSteps = @([regex]::Matches($plannerRegion.Substring($scanFrom), '\[(\d+[a-z]?)/(\d+)\]\s') |
            ForEach-Object { "{0}/{1}" -f $_.Groups[1].Value, $_.Groups[2].Value })
        $planSteps.Count | Should -Be $stepHeads.Count -Because 'the dry-run plan must list every real step exactly once'
        for ($i = 0; $i -lt $stepHeads.Count; $i++) {
            $planSteps[$i] | Should -Be $stepHeads[$i] -Because "planner entry $($i + 1) must mirror step heading $($i + 1)"
        }
    }

    It '<Name>: functional zero-write probe - -DryRun under redirected env exits 0 and writes nothing' -ForEach @(
        @{ Name = 'cursor';  File = 'reset_cursor.ps1' }
        @{ Name = 'trae';    File = 'reset_trae.ps1' }
        @{ Name = 'devin';   File = 'reset_devin.ps1' }
        @{ Name = 'minimax'; File = 'reset_minimax_opencode.ps1' }
        @{ Name = 'qoder';   File = 'reset_qoder.ps1' }
    ) {
        $fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ghost-dryrun-" + $Name + "-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        # separate subtrees: powershell.exe itself materializes AppData\Roaming
        # under a redirected USERPROFILE (harness noise), so the zero-write
        # assertion targets the store roots (appdata) + an artifact scan
        $fakeAppData = Join-Path $fakeRoot 'appdata'
        $fakeHome = Join-Path $fakeRoot 'home'
        New-Item -Path $fakeAppData -ItemType Directory -Force | Out-Null
        New-Item -Path $fakeHome -ItemType Directory -Force | Out-Null
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell'
            $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -DryRun' -f (Join-Path $script:RepoRoot ("src\windows\" + $File))
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $null = $psi.EnvironmentVariables.Remove('APPDATA')
            $psi.EnvironmentVariables['APPDATA'] = $fakeAppData
            $psi.EnvironmentVariables['LOCALAPPDATA'] = $fakeAppData
            $psi.EnvironmentVariables['USERPROFILE'] = $fakeHome
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd()
            $null = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            $proc.ExitCode | Should -Be 0 -Because 'the planner exits 0 even on an empty fixture (plan-only semantics)'
            $out | Should -Match 'DRY-RUN complete - nothing was written or killed'
            $out | Should -Match 'DRY-RUN PLAN'
            # zero-write proof: the store roots gained NOTHING, and no backup/
            # audit/restore/marker artifact exists anywhere in the fixture
            @(Get-ChildItem -LiteralPath $fakeAppData -Recurse -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'the planner must not create backup dirs, markers or audit files'
            @(Get-ChildItem -LiteralPath $fakeRoot -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'ID_Backups|restore_|audit_|_done\.txt' }).Count | Should -Be 0 -Because 'no reset artifact may appear in plan-only mode'
        }
        finally {
            Remove-Item -LiteralPath $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
