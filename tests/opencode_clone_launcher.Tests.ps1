# SPDX-License-Identifier: Apache-2.0
# Tests for src/windows/launch_opencode_clone.ps1 - the OpenCode desktop
# clone launcher's CS-10 service-sharing guard + XDG preemption (2026-11-23).
# OpenCode v2.3.2 introduced a machine-global background-service registry
# ($XDG_STATE_HOME\opencode\service.json) and the desktop main entry JOINS a
# live compatible service at startup (pure read-only reuse) BEFORE the
# patched in-app clone-home branch can set XDG_STATE_HOME - so a launched
# clone joined the Primary's daemon and its sessions would land in the
# Primary's data home (the service process owns the data home; clients talk
# HTTP). The launcher now PREEMPTS at the process-env level: the four XDG_*
# levers are set (and restored) around Start-Process, so every in-app read
# resolves the clone's own state home and the clone spawns its OWN service.

Describe 'OpenCode desktop clone launcher - script hygiene + CS-10 contract' {
    BeforeAll {
        $script:Path = (Resolve-Path (Join-Path $PSScriptRoot "..\src\windows\launch_opencode_clone.ps1")).Path
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:Path, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "launch_opencode_clone.ps1 does not parse: $($errors[0].Message)" }
        $script:Raw = [System.IO.File]::ReadAllText($script:Path)
    }

    It 'is CRLF + UTF-8 BOM (repo eol=crlf rule for tracked .ps1)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:Path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
        ($script:Raw -match "(?<!`r)`n") | Should -BeFalse
    }

    It 'carries the CS-10 verdict: v2.3.2 service joining + the service-owns-the-data-home impact' {
        ($script:Raw -match 'CS-10 SERVICE-SHARING GUARD') | Should -BeTrue
        ($script:Raw -match 'Service\.discover\(\) at startup') | Should -BeTrue
        ($script:Raw -match 'sessions land in the') | Should -BeTrue -Because 'the header must state that a joining clone''s sessions land in the service''s data home'
    }

    It 'reads the machine service registry under the DEFAULT state home (never the clone home)' {
        ($script:Raw -match [regex]::Escape('local\state\opencode\service.json')) | Should -BeTrue
        # the guard only READS the registry - GHOST never writes or deletes it
        ($script:Raw -match 'Set-Content.*service\.json|Remove-Item.*service\.json') | Should -BeFalse
    }

    It 'the guard probes pid liveness with an opencode-family sanity check' {
        ($script:Raw -match 'Get-Process -Id \$svcRec\.pid') | Should -BeTrue
        ($script:Raw -match "ProcessName -like 'opencode\*'") | Should -BeTrue -Because 'pid recycling must not read a dead record as a live service'
    }

    It 'warns loudly when the Primary service is alive (the isolation hazard exists at launch time)' {
        ($script:Raw -match 'Primary OpenCode service is RUNNING') | Should -BeTrue
        ($script:Raw -match 'spawn its OWN isolated service') | Should -BeTrue
    }

    It 'the XDG preempt sets all FOUR levers to the frozen clone subdirs' {
        foreach ($pair in @(
            @('XDG_DATA_HOME', 'data'),
            @('XDG_CONFIG_HOME', 'config'),
            @('XDG_CACHE_HOME', 'cache'),
            @('XDG_STATE_HOME', 'state')
        )) {
            ($script:Raw -match ('''' + $pair[0] + '''\s*=\s*''' + $pair[1] + '''')) | Should -BeTrue
        }
    }

    It 'the preempt is scoped to the spawned app: saved before, restored in finally, Start-Process inside the try' {
        ($script:Raw -match '\$savedXdg\[\$xdg\] = \[Environment\]::GetEnvironmentVariable\(\$xdg\)') | Should -BeTrue
        $spawnAt = $script:Raw.IndexOf('Start-Process -FilePath $LaunchExe')
        ($spawnAt -gt 0) | Should -BeTrue
        $tryAt = $script:Raw.LastIndexOf('try {', $spawnAt)
        $finallyAt = $script:Raw.IndexOf('} finally {', $spawnAt)
        ($tryAt -gt 0 -and $finallyAt -gt $spawnAt) | Should -BeTrue -Because 'Start-Process must run while the levers are set; the restore must follow it'
    }

    It 'does not redirect HOME or USERPROFILE (only the four XDG levers)' {
        ($script:Raw -match '\$env:HOME\s*=') | Should -BeFalse
        ($script:Raw -match '\$env:USERPROFILE\s*=') | Should -BeFalse -Because 'USERPROFILE is only read here, never redirected'
    }
}
