#Requires -Version 5.1
# Claude Code Light Worker Launcher (headless/terminal, per-clone-home) - the
# FIRST suite of the Terminal Agents family (GHOST, 2026-11-21). Claude Code
# is a native terminal CLI: the interactive REPL IS a terminal TUI (runs
# fine standalone - no Electron, no asar lock), and `-p/--print` is the
# one-shot headless mode. Per-instance clones ride ONE env lever.
#
# Mechanism (Phase-0 evidence, LIVE-VERIFIED probes 2026-11-21, CLI 2.1.314):
#   - Binary: the npm shim at %APPDATA%\npm (claude.cmd / claude.ps1 -> node
#     node_modules\@anthropic-ai\claude-code\cli.js). A native build
#     (%USERPROFILE%\.local\bin\claude.exe, from `claude install`) is a
#     fallback candidate. The probe is FUNCTIONAL: --version must exit 0
#     reporting a version - never a bare path/Get-Command hit.
#   - ISOLATION LEVER (live-verified): CLAUDE_CONFIG_DIR=<clone home>. One
#     env var redirects the ENTIRE config surface - probe: a fresh dir +
#     `claude mcp list` created .claude.json + backups\ there, and
#     `claude auth status` reported that dir as configDirectory. The clone
#     home therefore holds .claude.json (identity), settings.json,
#     projects/ (transcripts), sessions/, history.jsonl, skills/, plugins/,
#     cache/, state/ and .credentials.json (OAuth token).
#   - IDENTITY (live-verified): a fresh config dir auto-generates its own
#     machineID + userID in .claude.json (probe machineID differed from the
#     Primary's). One credential = one instance - never share a login.
#   - HONEST LIMITS (DERIVED until live acceptance = TA-1):
#       * A fresh home has no auth: one-shot runs fail with an auth error
#         until `claude auth login` ran for THAT home (-Login mode). There
#         is no free-model fallback here (unlike the ZCode/OpenCode workers).
#       * Whether a fresh home needs interactive onboarding before headless
#         use is UNVERIFIED - if a one-shot reports an onboarding prompt,
#         run the bare REPL once for that home.
#   - Permissions: a one-shot task that needs tool approvals FAILS with a
#     permission error unless -Yolo is passed (--dangerously-skip-permissions,
#     the CLI's own DANGEROUS flag - unsupervised runs only).
#
# Modes:
#   default            interactive REPL on the clone's own state (the
#                      terminal TUI - fully supported here, unlike ZCode)
#   -Prompt "text"     one-shot: claude -p "<text>" (verify-after on exit code)
#   -Yolo              one-shot with --dangerously-skip-permissions
#   -Login             one-time interactive `claude auth login` for THIS home
#   -Status            read-only instance report (suite_status_lib row)
#
# VISIBILITY: every run mode writes <CloneHome>\.ghost-light-worker.json
# (launcher pid + mode) for the whole run and removes it on exit - the
# shared PID-marker contract (ghost_light_marker.ps1). Because
# CLAUDE_CONFIG_DIR is env-only (never in a command line), the marker is the
# ONLY attribution surface for a claude-code clone - status tools claim the
# launcher's process-tree descendants from it.
param(
    [ValidateSet('c1', 'c2', 'c3', 'c4', 'c5')]
    [string]$Instance = 'c1',
    [string]$Prompt = '',
    [string]$Model = '',
    [string]$Cwd = '',
    # One-shot bypass of ALL permission checks (--dangerously-skip-permissions).
    # The CLI prints its own DANGEROUS note; unsupervised runs only.
    [switch]$Yolo,
    [switch]$Login,
    [switch]$Status,
    [switch]$NoLoginWarn
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }

# Binary ladder: PATH `claude` first (functional probe), then the npm shim,
# then the native build. Every candidate must pass --version exiting 0 with
# a version-looking output ("2.1.314 (Claude Code)").
$BinCandidates = @()
try {
    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $BinCandidates += $cmd.Source }
} catch { }
$BinCandidates += @(
    (Join-Path $env:APPDATA 'npm\claude.cmd'),
    (Join-Path $UserProfile '.local\bin\claude.exe')
)
$ClaudeExe = $null
foreach ($candidate in $BinCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        $v = & $candidate --version 2>$null
        if ($LASTEXITCODE -eq 0 -and ("$v") -match '^\d+\.\d+') { $ClaudeExe = $candidate; break }
    } catch { }
}
if (-not $ClaudeExe) { throw "claude not found or non-functional. Checked: $($BinCandidates -join '; '). Install Claude Code (npm i -g @anthropic-ai/claude-code) and retry." }

# Display vocabulary: colors are the user-facing instance names; the frozen
# c1..c5 keys stay in params and dirs only (frozen plumbing).
$InstanceMap = @{
    'c1' = @{ Home = 'ClaudeCodeClonesHome\c1'; Color = 'Blue' }
    'c2' = @{ Home = 'ClaudeCodeClonesHome\c2'; Color = 'Yellow' }
    'c3' = @{ Home = 'ClaudeCodeClonesHome\c3'; Color = 'Green' }
    'c4' = @{ Home = 'ClaudeCodeClonesHome\c4'; Color = 'Red' }
    'c5' = @{ Home = 'ClaudeCodeClonesHome\c5'; Color = 'Orange' }
}
$cfg = $InstanceMap[$Instance]
$CloneHome = Join-Path $UserProfile $cfg.Home

if ($Status) {
    # Read-only row for THIS instance via the shared suite status lib.
    # PATH NOTE (live-caught 2026-11-21): $PSScriptRoot is <repo>\src\windows -
    # TWO levels below the repo root - so the lib must climb TWO levels. A
    # single '..\tools' resolves to <repo>\src\tools (which does not exist)
    # and the dot-source dies with CommandNotFoundException.
    $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $lib = Join-Path $repoRoot 'tools\suite_status_lib.ps1'
    . $lib
    $state = Get-GhostSuiteInstanceState -Suite 'claudecode'
    $row = @($state.Rows | Where-Object { $_.Instance -eq $Instance })[0]
    $lwPath = Join-Path $CloneHome '.ghost-light-worker.json'
    Write-Host "=== Claude Code $Instance ($($cfg.Color)) status ===" -ForegroundColor Cyan
    Write-Host ("  clone home  : {0} ({1})" -f $CloneHome, $(if (Test-Path -LiteralPath $CloneHome) { 'present' } else { 'absent (first launch creates it)' }))
    Write-Host ("  identity    : {0}" -f $(if (Test-Path -LiteralPath (Join-Path $CloneHome '.claude.json')) { '.claude.json present (own machineID)' } else { 'no identity yet (first run generates one)' }))
    Write-Host ("  login       : {0}" -f $(if (Test-Path -LiteralPath (Join-Path $CloneHome '.credentials.json')) { 'credentials present' } else { 'NOT logged in (run -Login for this home)' }))
    Write-Host ("  light worker: {0}" -f $row.LightWorker)
    Write-Host ("  fleet       : {0}/{1} instances running (Maintenance [6] = the cross-suite view)" -f `
            @($state.Rows | Where-Object { $_.State -eq 'RUNNING' }).Count, $state.Rows.Count)
    exit 0
}

if ($Login) {
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) { throw "-Login is an interactive mode and cannot combine with -Prompt." }
    New-Item -ItemType Directory -Path $CloneHome -Force | Out-Null
    Write-Host "[login] One-time account login for $($cfg.Color) (config dir: $CloneHome)." -ForegroundColor Cyan
    Write-Host "[login] A browser window will open - sign in with THIS instance's account." -ForegroundColor Cyan
    Write-Host '[login] One credential = one instance; never reuse another clone home''s login.' -ForegroundColor Cyan
    $env:CLAUDE_CONFIG_DIR = $CloneHome
    & $ClaudeExe auth login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[login] FAILED - exit code $LASTEXITCODE (see output above)." -ForegroundColor Red
        exit 1
    }
    # Verify-after: the login must persist credentials into the clone home
    # (.credentials.json inside CLAUDE_CONFIG_DIR).
    if (Test-Path -LiteralPath (Join-Path $CloneHome '.credentials.json')) {
        Write-Host '[login] OK - .credentials.json written; headless runs now use this instance''s account.' -ForegroundColor Green
        exit 0
    }
    Write-Host '[login] FAILED - login exited 0 but no .credentials.json landed in the clone home.' -ForegroundColor Red
    Write-Host "[login] (checked: $(Join-Path $CloneHome '.credentials.json'))" -ForegroundColor Red
    exit 1
}

# Clone home lifecycle: unlike the desktop suites there is no first desktop
# run to seed it - the light worker CREATES the home on first launch.
New-Item -ItemType Directory -Path $CloneHome -Force | Out-Null

# Per-clone env lever - the ONE isolation variable (Phase-0 live-verified).
$env:CLAUDE_CONFIG_DIR = $CloneHome

# Light-worker PID-marker contract (shared lib): the ONLY attribution surface
# for a claude-code clone (CLAUDE_CONFIG_DIR is env-only, never in argv).
. (Join-Path $PSScriptRoot 'ghost_light_marker.ps1')
$LightMarkerPath = Join-Path $CloneHome '.ghost-light-worker.json'

# Login check: a fresh home has no .credentials.json - one-shot runs will
# fail with an auth error, so say so loudly (unless silenced). There is no
# free-model fallback for claude-code.
if (-not $NoLoginWarn -and -not (Test-Path -LiteralPath (Join-Path $CloneHome '.credentials.json'))) {
    Write-Host "[model] WARNING: $($cfg.Color) has no account login - one-shot runs will fail with an auth" -ForegroundColor Yellow
    Write-Host '[model] error (no free-model fallback for claude-code).' -ForegroundColor Yellow
    Write-Host '[model] One-time fix: run this script again with -Login (interactive browser flow; it' -ForegroundColor Yellow
    Write-Host '[model] writes <clone-home>\.credentials.json). One credential = one instance.' -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $UserProfile }
if (-not (Test-Path -LiteralPath $Cwd)) { throw "Working directory does not exist: $Cwd" }
Push-Location -LiteralPath $Cwd
# Project-directory binding: claude resolves its project from the process
# CWD (the OpenCode PWD-env lesson does not apply here - claude reads the
# Win32 CWD - but PS children inherit the PROVIDER location, so
# Push-Location + CurrentDirectory keep the child aligned).
[Environment]::CurrentDirectory = $Cwd

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    Write-Host "[light] $($cfg.Color) one-shot task (cwd=$Cwd)..." -ForegroundColor Cyan
    $runArgs = @('-p', $Prompt)
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $runArgs += @('--model', $Model) }
    if ($Yolo) { $runArgs += '--dangerously-skip-permissions' }
    Write-GhostLightMarker -Path $LightMarkerPath -Suite 'claudecode' -Instance $Instance -Mode 'prompt'
    try {
        # NO pipeline capture around this call (the OpenCode lesson: assigning
        # the output swallows the CLI's stdout). Call as a statement.
        & $ClaudeExe @runArgs
        $exit = $LASTEXITCODE
    } finally {
        Remove-GhostLightMarker -Path $LightMarkerPath
        Pop-Location
    }
    if ($exit -ne 0) {
        Write-Host ("[light] FAILED - exit code {0} (output above). Auth error = run -Login for this home; permission error = add -Yolo." -f $exit) -ForegroundColor Red
        exit 1
    }
    exit 0
}

# Interactive REPL on the clone's own state - the terminal TUI, fully
# supported (no Electron lock here, unlike the ZCode worker).
Write-Host ("[light] Claude Code {0} worker - config isolated to {1}" -f $cfg.Color, $cfg.Home) -ForegroundColor Cyan
Write-Host "[light] cli=$ClaudeExe  cwd=$Cwd"
Write-Host '[light] Exit the REPL to return. Tasks needing tool approvals in -p mode require -Yolo.'
Write-GhostLightMarker -Path $LightMarkerPath -Suite 'claudecode' -Instance $Instance -Mode 'repl'
try {
    & $ClaudeExe
    $exit = $LASTEXITCODE
} finally {
    Remove-GhostLightMarker -Path $LightMarkerPath
    Pop-Location
}
if ($exit -ne 0) {
    Write-Host ("[light] session ended with exit code {0}." -f $exit) -ForegroundColor Yellow
    exit $exit
}
exit 0
