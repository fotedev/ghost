#Requires -Version 5.1
# Codex Light Worker Launcher (headless/terminal, per-clone-home) - the
# SECOND suite of the Terminal Agents family (GHOST, 2026-11-21). The OpenAI
# Codex CLI is a native Rust terminal binary: the interactive TUI IS the
# default subcommand (runs fine standalone - no Electron, no asar lock), and
# `codex exec` is the one-shot headless mode. Per-instance clones ride ONE
# env lever.
#
# Mechanism (Phase-0 evidence, LIVE-VERIFIED probes 2026-11-21, CLI 0.166.0):
#   - Binary: the npm shim at %APPDATA%\npm (codex.cmd / codex.ps1 -> node
#     node_modules\@openai\codex\bin\codex.js -> the vendored native
#     codex.exe). The native exe is also a direct fallback candidate. The
#     probe is FUNCTIONAL: --version must exit 0 reporting "codex-cli N.N.N"
#     - never a bare path/Get-Command hit.
#   - ISOLATION LEVER (live-verified): CODEX_HOME=<clone home>. One env var
#     redirects the ENTIRE state surface - probe: --version, `codex login
#     status`, `codex mcp list` and an exec attempt all honored the override
#     (the binary's own banner names codex_home) and the Primary ~/.codex was
#     byte-identical before/after. A REAL run attempt auto-generates the
#     runtime state in the fresh home: installation_id (36 B UUID), six
#     SQLite stores (state_5/logs_2/goals_1/queue_1/memories_1/
#     thread_history_1 + -wal/-shm), .sandbox_migration, .sandbox\ logs,
#     .tmp\ plugin clones, sessions\ and skills\. config.toml and auth.json
#     are NOT auto-created (auth comes from login; config.toml is
#     user-authored).
#   - IDENTITY (live-verified): a fresh home generates its own
#     installation_id on first run. One credential = one instance - never
#     share a login.
#   - HONEST LIMITS (live-captured 2026-11-21):
#       * A fresh home has no auth: `codex login status` prints "Not logged
#         in" (exit 1) and a one-shot exec fails with an AUTH error after
#         printing its banner - it does NOT hang silently (unlike
#         claude-code). Fix = -Login for THIS home (browser flow) or
#         `codex login --with-api-key` (key via stdin). No free-model
#         fallback here.
#       * `codex exec` READS STDIN ("Reading additional input from
#         stdin...") - the one-shot mode below closes stdin so the run
#         cannot stall on an open console pipe.
#       * codex loads SKILLS from the SHARED ~\.agents store (live-verified:
#         a fresh-home exec read C:\Users\FOTE\.agents\skills\*.md) - skills
#         are NOT isolated per clone home.
#       * Under a TEMP-shaped home the binary warns it refuses to create
#         PATH-alias helper binaries; real clone homes under the user
#         profile are unaffected.
#   - Permissions: `codex exec` defaults to sandbox read-only + approval
#     never; a task that must write files needs -Yolo (--yolo =
#     --dangerously-bypass-approvals-and-sandbox, the CLI's own DANGEROUS
#     flag - unsupervised runs only).
#
# Modes:
#   default            interactive REPL (codex TUI) on the clone's own state
#   -Prompt "text"     one-shot: codex exec "<text>" (stdin closed; verify on
#                      exit code)
#   -Model "name"      override the model (-m)
#   -Yolo              run with --yolo (bypass approvals AND sandbox)
#   -Login             one-time interactive `codex login` for THIS home
#   -Status            read-only instance report (suite_status_lib row)
#
# VISIBILITY: every run mode writes <CloneHome>\.ghost-light-worker.json
# (launcher pid + mode) for the whole run and removes it on exit - the
# shared PID-marker contract (ghost_light_marker.ps1). Because CODEX_HOME is
# env-only (never in a command line), the marker is the ONLY attribution
# surface for a codex clone - status tools claim the launcher's
# process-tree descendants from it.
param(
    [ValidateSet('c1', 'c2', 'c3', 'c4', 'c5')]
    [string]$Instance = 'c1',
    [string]$Prompt = '',
    [string]$Model = '',
    [string]$Cwd = '',
    # One-shot bypass of approvals AND sandbox (--yolo). The CLI prints its
    # own DANGEROUS note; unsupervised runs only.
    [switch]$Yolo,
    [switch]$Login,
    [switch]$Status,
    [switch]$NoLoginWarn
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }

# Binary ladder: PATH `codex` first (functional probe), then the npm shim,
# then the vendored native exe. Every candidate must pass --version exiting
# 0 with the live-verified output shape ("codex-cli 0.166.0").
$BinCandidates = @()
try {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { $BinCandidates += $cmd.Source }
} catch { }
$BinCandidates += @(
    (Join-Path $env:APPDATA 'npm\codex.cmd'),
    (Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe')
)
$CodexExe = $null
foreach ($candidate in $BinCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        $v = & $candidate --version 2>$null
        if ($LASTEXITCODE -eq 0 -and ("$v") -match 'codex-cli\s+\d+\.\d+') { $CodexExe = $candidate; break }
    } catch { }
}
if (-not $CodexExe) { throw "codex not found or non-functional. Checked: $($BinCandidates -join '; '). Install the Codex CLI (npm i -g @openai/codex) and retry." }

# Display vocabulary: colors are the user-facing instance names; the frozen
# c1..c5 keys stay in params and dirs only (frozen plumbing).
$InstanceMap = @{
    'c1' = @{ Home = 'CodexClonesHome\c1'; Color = 'Blue' }
    'c2' = @{ Home = 'CodexClonesHome\c2'; Color = 'Yellow' }
    'c3' = @{ Home = 'CodexClonesHome\c3'; Color = 'Green' }
    'c4' = @{ Home = 'CodexClonesHome\c4'; Color = 'Red' }
    'c5' = @{ Home = 'CodexClonesHome\c5'; Color = 'Orange' }
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
    $state = Get-GhostSuiteInstanceState -Suite 'codex'
    $row = @($state.Rows | Where-Object { $_.Instance -eq $Instance })[0]
    $lwPath = Join-Path $CloneHome '.ghost-light-worker.json'
    Write-Host "=== Codex CLI $Instance ($($cfg.Color)) status ===" -ForegroundColor Cyan
    Write-Host ("  clone home  : {0} ({1})" -f $CloneHome, $(if (Test-Path -LiteralPath $CloneHome) { 'present' } else { 'absent (first launch creates it)' }))
    Write-Host ("  identity    : {0}" -f $(if (Test-Path -LiteralPath (Join-Path $CloneHome 'installation_id')) { 'installation_id present (own install id)' } else { 'no identity yet (first run generates one)' }))
    Write-Host ("  login       : {0}" -f $(if (Test-Path -LiteralPath (Join-Path $CloneHome 'auth.json')) { 'auth.json present' } else { 'NOT logged in (run -Login for this home)' }))
    Write-Host ("  light worker: {0}" -f $row.LightWorker)
    Write-Host ("  fleet       : {0}/{1} instances running (Maintenance [6] = the cross-suite view)" -f `
            @($state.Rows | Where-Object { $_.State -eq 'RUNNING' }).Count, $state.Rows.Count)
    exit 0
}

if ($Login) {
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) { throw "-Login is an interactive mode and cannot combine with -Prompt." }
    New-Item -ItemType Directory -Path $CloneHome -Force | Out-Null
    Write-Host "[login] One-time account login for $($cfg.Color) (CODEX_HOME: $CloneHome)." -ForegroundColor Cyan
    Write-Host "[login] A browser/device flow will open - sign in with THIS instance's account." -ForegroundColor Cyan
    Write-Host '[login] One credential = one instance; never reuse another clone home''s login.' -ForegroundColor Cyan
    Write-Host '[login] (API-key alternative: codex login --with-api-key, key via stdin - run it in a' -ForegroundColor Cyan
    Write-Host '[login]  terminal where CODEX_HOME is this home.)' -ForegroundColor Cyan
    $env:CODEX_HOME = $CloneHome
    & $CodexExe login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[login] FAILED - exit code $LASTEXITCODE (see output above)." -ForegroundColor Red
        exit 1
    }
    # Verify-after: the login must persist credentials into the clone home
    # (auth.json inside CODEX_HOME).
    if (Test-Path -LiteralPath (Join-Path $CloneHome 'auth.json')) {
        Write-Host '[login] OK - auth.json written; headless runs now use this instance''s account.' -ForegroundColor Green
        exit 0
    }
    Write-Host '[login] FAILED - login exited 0 but no auth.json landed in the clone home.' -ForegroundColor Red
    Write-Host "[login] (checked: $(Join-Path $CloneHome 'auth.json'))" -ForegroundColor Red
    exit 1
}

# Clone home lifecycle: unlike the desktop suites there is no first desktop
# run to seed it - the light worker CREATES the home on first launch (the
# first real run generates installation_id + the SQLite state stores).
New-Item -ItemType Directory -Path $CloneHome -Force | Out-Null

# Per-clone env lever - the ONE isolation variable (Phase-0 live-verified).
$env:CODEX_HOME = $CloneHome

# Light-worker PID-marker contract (shared lib): the ONLY attribution surface
# for a codex clone (CODEX_HOME is env-only, never in argv).
. (Join-Path $PSScriptRoot 'ghost_light_marker.ps1')
$LightMarkerPath = Join-Path $CloneHome '.ghost-light-worker.json'

# Login check: a fresh home has no auth.json - a headless one-shot then
# FAILS WITH AN AUTH ERROR after printing its banner (live-captured
# 2026-11-21: unlike claude-code it does NOT hang silently).
if (-not $NoLoginWarn -and -not (Test-Path -LiteralPath (Join-Path $CloneHome 'auth.json'))) {
    Write-Host "[model] WARNING: $($cfg.Color) has no account login - a headless one-shot fails with an" -ForegroundColor Yellow
    Write-Host '[model] AUTH error (no free-model fallback for codex). One-time fix - run this script' -ForegroundColor Yellow
    Write-Host '[model] again with -Login (interactive browser flow; it writes <clone-home>\auth.json)' -ForegroundColor Yellow
    Write-Host '[model] or use `codex login --with-api-key` with CODEX_HOME pointed at this home.' -ForegroundColor Yellow
    Write-Host '[model] One credential = one instance.' -ForegroundColor Yellow
}

if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $UserProfile }
if (-not (Test-Path -LiteralPath $Cwd)) { throw "Working directory does not exist: $Cwd" }
Push-Location -LiteralPath $Cwd
# Project-directory binding: codex resolves its project/trust from the
# process CWD (PS children inherit the PROVIDER location, so Push-Location +
# CurrentDirectory keep the child aligned).
[Environment]::CurrentDirectory = $Cwd

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    Write-Host "[light] $($cfg.Color) one-shot task (cwd=$Cwd)..." -ForegroundColor Cyan
    $runArgs = @('exec', '--skip-git-repo-check', $Prompt)
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $runArgs += @('--model', $Model) }
    if ($Yolo) { $runArgs += '--yolo' }
    Write-GhostLightMarker -Path $LightMarkerPath -Suite 'codex' -Instance $Instance -Mode 'prompt'
    try {
        # NO output capture around this call (the OpenCode lesson: assigning
        # the output swallows the CLI's stdout) - call as a statement. The
        # $null feed closes STDIN: codex exec reads additional input from
        # stdin (live-verified) and would otherwise wait on an open console
        # pipe.
        $null | & $CodexExe @runArgs
        $exit = $LASTEXITCODE
    } finally {
        Remove-GhostLightMarker -Path $LightMarkerPath
        Pop-Location
    }
    if ($exit -ne 0) {
        Write-Host ("[light] FAILED - exit code {0} (output above). Auth error = run -Login for this home; sandbox/approval denial = add -Yolo." -f $exit) -ForegroundColor Red
        exit 1
    }
    exit 0
}

# Interactive REPL on the clone's own state - the terminal TUI, fully
# supported (no Electron lock here, unlike the ZCode worker).
Write-Host ("[light] Codex CLI {0} worker - state isolated to {1}" -f $cfg.Color, $cfg.Home) -ForegroundColor Cyan
Write-Host "[light] cli=$CodexExe  cwd=$Cwd"
Write-Host '[light] Exit the REPL to return. One-shot tasks that write files need -Yolo.'
Write-GhostLightMarker -Path $LightMarkerPath -Suite 'codex' -Instance $Instance -Mode 'repl'
try {
    & $CodexExe
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
