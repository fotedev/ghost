#Requires -Version 5.1
# T3 Code provider-instance seeder for the OpenCode clone fleet (c1..c5).
# Adds (or with -Remove removes) five `acpRegistry` provider instances to
# ~/.t3/userdata/settings.json so every OpenCode clone is a T3 "Local ACP
# command" - the OpenCode counterpart of the five ZCode instances seeded by
# hand for the bridge (docs/T3_ZCODE_BRIDGE_SPEC.md 9.1: backup + verify-after).
#
# Design (live-verified 2026-11-07):
#   - The entries carry NO env field. Per-clone isolation rides OUR launcher:
#     commandArgs = powershell -File launch_opencode_cli_light.ps1 -Instance cN -Acp,
#     and the launcher sets the four XDG env levers before exec'ing
#     `opencode acp` (handshake verified: protocolVersion 1 + a real
#     session/new under c2's env). Zero dependence on any T3 env-override
#     schema - the same shape the ZCode entries use (env inside the script).
#   - T3 reads settings.json ONLY at startup: the app must be CLOSED while
#     this script runs (install-scoped running guard, loud throw).
#   - Merge, never overwrite: only the five opencode-* keys are touched;
#     favorites and every other providerInstance (incl. the five zcode-*)
#     survive untouched. Idempotent - re-running updates the values in place.
#   - Backup first: <settings>.bak-t3-opencode-<stamp>; verify-after re-read
#     deep-compares every seeded (or removed) key; never silent-success.
#   - T3-UI acceptance (Providers render, streamed reply, model switch) is
#     USER-SUPERVISED and stays pending in docs/OPENCODE_CLONES_SPEC.md 3.9.1.
#
# Exit codes: 0 = seeded/removed/already-as-asked; 1 = any failure.
param(
    [switch]$Remove,
    # Test/fixture override - defaults to the real T3 settings file.
    [string]$SettingsPath = '',
    # Test override for the repo root (defaults to this script's repo).
    [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-OpenCodeT3InstanceDefs {
    # The frozen clone keys c1..c5 + the suite's display vocabulary. Orange
    # accent is the documented PLACEHOLDER (no developer hex exists yet -
    # AGENTS.md branding notes), the other four are the staged accents.
    @(
        @{ Key = 'opencode-c1'; Instance = 'c1'; Color = 'Blue';   Accent = '#2A7CBD' }
        @{ Key = 'opencode-c2'; Instance = 'c2'; Color = 'Yellow'; Accent = '#ECC31E' }
        @{ Key = 'opencode-c3'; Instance = 'c3'; Color = 'Green';  Accent = '#37A188' }
        @{ Key = 'opencode-c4'; Instance = 'c4'; Color = 'Red';    Accent = '#BD2A32' }
        @{ Key = 'opencode-c5'; Instance = 'c5'; Color = 'Orange'; Accent = '#C8620A' }
    )
}

function New-T3OpenCodeEntry {
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Def,
        [Parameter(Mandatory = $true)] [string]$CommandPath,
        [Parameter(Mandatory = $true)] [string[]]$CommandArgs
    )
    [pscustomobject]@{
        driver = 'acpRegistry'
        displayName = "OpenCode $($Def.Color)"
        accentColor = $def.Accent
        enabled = $true
        config = [pscustomobject]@{
            source = 'local'
            commandPath = $CommandPath
            commandArgs = $CommandArgs
            customModels = @()
        }
    }
}

function Assert-T3Closed {
    # Install-scoped running guard: T3 Code reads settings.json only at
    # startup, so any running copy would lose (or overwrite) the seed.
    # Two probes: install-dir Path match AND the exe's ProcessName ("T3
    # Code (Beta)") - an elevated T3 hides its Path from a non-elevated
    # caller, so the name probe catches what the path probe cannot.
    $t3Procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.Path -and $_.Path -like '*t3code*') -or ($_.ProcessName -like 'T3 Code*')
    })
    if ($t3Procs.Count -gt 0) {
        $list = ($t3Procs | ForEach-Object { "{0} (pid {1})" -f $_.ProcessName, $_.Id }) -join ', '
        throw "T3 Code is running ($list). Close it first - T3 reads ~/.t3/userdata/settings.json only at startup, then re-run this script."
    }
}

function Invoke-T3OpenCodeSeed {
    # Core (testable against a fixture via -SettingsPath): merge or remove
    # the five opencode-* provider instances, backup-first, verify-after.
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$LauncherPath,
        [Parameter(Mandatory = $true)] [string]$PowershellPath,
        [switch]$Remove
    )
    $defs = Get-OpenCodeT3InstanceDefs

    if (Test-Path -LiteralPath $Path) {
        $root = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } else {
        if ($Remove) {
            Write-Host "[t3-opencode] nothing to remove - $Path does not exist." -ForegroundColor Yellow
            return $defs
        }
        Write-Host "[t3-opencode] settings file missing - starting a fresh one: $Path" -ForegroundColor Yellow
        $root = [pscustomobject]@{}
    }
    if (-not ($root.PSObject.Properties['providerInstances'])) {
        if ($Remove) {
            Write-Host '[t3-opencode] nothing to remove - no providerInstances block.' -ForegroundColor Yellow
            return $defs
        }
        $root | Add-Member -NotePropertyName providerInstances -NotePropertyValue ([pscustomobject]@{})
    }
    $pi = $root.providerInstances

    $commandArgsBase = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $LauncherPath)
    foreach ($def in $defs) {
        if ($Remove) {
            if ($pi.PSObject.Properties[$def.Key]) {
                $pi.PSObject.Properties.Remove($def.Key)
            }
            continue
        }
        $entry = New-T3OpenCodeEntry -Def $def -CommandPath $PowershellPath `
            -CommandArgs ($commandArgsBase + @('-Instance', $def.Instance, '-Acp'))
        if ($pi.PSObject.Properties[$def.Key]) {
            $pi.PSObject.Properties.Remove($def.Key)
        }
        $pi | Add-Member -NotePropertyName $def.Key -NotePropertyValue $entry
    }

    if (-not $Remove) {
        # Backup-first before the first write that changes the file. A
        # missing file (fresh seed) has nothing to back up.
        if (Test-Path -LiteralPath $Path) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = "$Path.bak-t3-opencode-$stamp"
            Copy-Item -LiteralPath $Path -Destination $backup -Force
            Write-Host "[t3-opencode] backup: $backup" -ForegroundColor DarkGray
        }
    }

    $json = ConvertTo-Json -InputObject $root -Depth 20
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))

    # Verify-after: re-read and deep-compare every touched key. Never silent.
    $re = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $failures = @()
    foreach ($def in $defs) {
        $have = $re.providerInstances.PSObject.Properties[$def.Key]
        if ($Remove) {
            if ($have) { $failures += "$($def.Key) still present after -Remove" }
            continue
        }
        if (-not $have) { $failures += "$($def.Key) missing after write"; continue }
        $wantJson = ConvertTo-Json -InputObject $pi.PSObject.Properties[$def.Key].Value -Depth 20 -Compress
        $haveJson = ConvertTo-Json -InputObject $have.Value -Depth 20 -Compress
        if ($wantJson -ne $haveJson) { $failures += "$($def.Key) does not match what was written" }
    }
    if ($failures.Count -gt 0) {
        throw ("T3 settings verify-after FAILED: {0}" -f ($failures -join '; '))
    }
    return $defs
}

# ---- main ----
if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Join-Path $env:USERPROFILE '.t3\userdata\settings.json' }
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$LauncherPath = Join-Path $RepoRoot 'src\windows\launch_opencode_cli_light.ps1'
if (-not (Test-Path -LiteralPath $LauncherPath)) { throw "Launcher not found: $LauncherPath" }
$PowershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowershellPath)) { throw "powershell.exe not found: $PowershellPath" }

if (-not $Remove) {
    Assert-T3Closed
}

$defs = Invoke-T3OpenCodeSeed -Path $SettingsPath -LauncherPath $LauncherPath -PowershellPath $PowershellPath -Remove:$Remove

if ($Remove) {
    Write-Host '[t3-opencode] OK - the five OpenCode provider instances were removed (verify-after passed).' -ForegroundColor Green
} else {
    Write-Host '[t3-opencode] OK - seeded five OpenCode provider instances (verify-after passed):' -ForegroundColor Green
    foreach ($def in $defs) {
        Write-Host ("[t3-opencode]   {0} ({1}) -> powershell -File launch_opencode_cli_light.ps1 -Instance {2} -Acp" -f $def.Color, $def.Key, $def.Instance) -ForegroundColor Gray
    }
    Write-Host '[t3-opencode] Start T3 Code - the instances appear under Providers. One manual' -ForegroundColor Gray
    Write-Host '[t3-opencode] `opencode auth login` per clone home (or -Login) attaches its account;' -ForegroundColor Gray
    Write-Host '[t3-opencode] anonymous homes run the FREE model.' -ForegroundColor Gray
}
exit 0
