#Requires -Version 5.1
# OpenCode Light Worker Launcher (headless, per-clone-home).
# Runs the OpenCode v2 CLI against a clone's isolated state WITHOUT the desktop
# window: one CLI process (plus its background service child on first task)
# instead of a full Electron instance.
#
# Mechanism (live-verified 2026-11-07 via spike on a scratch XDG env, CLI v2.2.5):
#   - The CLI ships with the desktop app at
#     <install>\resources\opencode-cli.exe (`--version` reports "opencode v2.2.5").
#   - Per-clone isolation rides the SAME four XDG env vars the clone-home asar
#     patch sets for the desktop app - the CLI honors them on Windows too
#     (verified with `debug paths`: data/cache/config/state all followed XDG_*,
#     while `home` stayed the real profile - XDG is the only lever here, no
#     HOME/USERPROFILE redirect needed):
#       XDG_DATA_HOME   -> <CloneHome>\data    (opencode.db, auth.json, log)
#       XDG_CONFIG_HOME -> <CloneHome>\config  (opencode.jsonc, service.json)
#       XDG_CACHE_HOME  -> <CloneHome>\cache   (bin runtime cache; first run may
#                                               download the CLI runtime there)
#       XDG_STATE_HOME  -> <CloneHome>\state
#     Sessions land in the clone's own opencode.db and share history with that
#     clone's desktop app (same home = same store).
#   - Headless surface, all verified:
#       run "<message>"   one-shot task; auto-starts the clone's background
#                         service on first use (answered a real turn on an
#                         ANONYMOUS home with the free model - see caveat)
#       serve             foreground v2 API/web server (HTTP 200 on a pinned
#                         port); the CALLER owns the process
#       service status/start/stop   background-service lifecycle (clean stop
#                         verified, zero orphan processes afterwards)
#   - A fresh/anonymous home still WORKS: `run` completed a turn with the free
#     model (iceman-free) and no auth.json present.
#
# MODEL CAVEAT (verified): an anonymous home (no auth.json) runs on the FREE
# model (iceman-free), NOT the clone's account plan. The fix is ONE
# `opencode auth login` per clone home (-Login mode: interactive flow;
# verify-after = <data>\opencode\auth.json appears and is not {}). One
# credential = one instance - never share a login across clone homes.
# Machine-env credentials (e.g. CLOUDFLARE_API_TOKEN) show up in `auth list`
# as source "environment" - they are NOT account logins and satisfy nothing.
#
# Modes:
#   default            interactive REPL: type a task per line, empty = exit
#                      (each task = one `run` call in a fresh session)
#   -Prompt "text"     one-shot: run the task and exit (verify-after on exit code)
#   -Server            foreground `serve` v2 API/web server (caller owns the
#                      process; never detach this mode; -Port to pin one)
#   -StopService       stop the clone's background service (the child that
#                      outlives closed windows - spec 3.8) and exit
#   -Login             one-time interactive `auth login` for THIS clone home
param(
    [ValidateSet('c1', 'c2', 'c3', 'c4', 'c5')]
    [string]$Instance = 'c1',
    [string]$Prompt = '',
    [string]$Model = '',
    [string]$Cwd = '',
    [int]$Port = 0,
    [switch]$Server,
    # Pass --auto to `run`: auto-approve permission requests. Headless tasks
    # that touch files or run commands hang on the approval prompt without it.
    [switch]$Auto,
    # Pass --standalone to `run`: private per-call server instead of the
    # clone's background service (nothing lingers after the task).
    [switch]$Standalone,
    # Pass --format json to `run`: machine-readable turn output. The default
    # renderer's final answer text is not guaranteed on a redirected
    # (non-TTY) stdout - live-verified 2026-11-07 the turn succeeds and lands
    # in the session store while stdout may end after the model header - so
    # scripted consumers must use -Json (the CLI's own contract).
    [switch]$Json,
    # Foreground `acp` Agent Client Protocol server on stdio - the T3 Code
    # "Local ACP command" surface. The XDG env levers above give each T3
    # provider instance its own clone home (handshake live-verified 2026-11-07:
    # protocolVersion 1 + a real session/new under c2's env). Like -Server,
    # the CALLER owns the pipe; never detach this mode.
    [switch]$Acp,
    [switch]$Login,
    [switch]$StopService,
    [switch]$NoLoginWarn
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

# CLI path: ships inside the desktop app install (electron-builder NSIS with
# the "@opencode-aidesktop" app-id prefix - verified layout). The Program Files
# entries cover alternate install shapes; the probe is functional (--version
# must exit 0 reporting an opencode version), never a bare path/Get-Command hit.
$CliCandidates = @(
    (Join-Path $LocalAppData 'Programs\@opencode-aidesktop\resources\opencode-cli.exe'),
    'C:\Program Files\OpenCode\resources\opencode-cli.exe',
    'C:\Program Files (x86)\OpenCode\resources\opencode-cli.exe'
)
$CliExe = $null
foreach ($candidate in $CliCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        $v = & $candidate --version 2>$null
        if ($LASTEXITCODE -eq 0 -and ("$v") -match '^opencode v\d') { $CliExe = $candidate; break }
    } catch { }
}
if (-not $CliExe) { throw "opencode-cli.exe not found or non-functional. Checked: $($CliCandidates -join '; '). Install/repair the OpenCode desktop app and retry." }

$InstanceMap = @{
    'c1' = @{ Home = 'OpenCodeClonesHome\c1'; Color = 'Blue' }
    'c2' = @{ Home = 'OpenCodeClonesHome\c2'; Color = 'Yellow' }
    'c3' = @{ Home = 'OpenCodeClonesHome\c3'; Color = 'Green' }
    'c4' = @{ Home = 'OpenCodeClonesHome\c4'; Color = 'Red' }
    'c5' = @{ Home = 'OpenCodeClonesHome\c5'; Color = 'Orange' }
}
$cfg = $InstanceMap[$Instance]
$CloneHome = Join-Path $UserProfile $cfg.Home

if (-not (Test-Path -LiteralPath $CloneHome)) {
    throw "Clone home $($cfg.Color) does not exist yet ($CloneHome). Launch its desktop instance once (GHOST.bat OpenCode [1]-[5]) to create it, then retry."
}

# Per-clone env levers - the four XDG homes, identical to what the clone-home
# asar patch feeds the desktop app. Verified live: the CLI routes
# data/cache/config/state through them on Windows; `home` stays the real
# profile so no HOME/USERPROFILE redirect is wanted here.
$env:XDG_DATA_HOME = Join-Path $CloneHome 'data'
$env:XDG_CONFIG_HOME = Join-Path $CloneHome 'config'
$env:XDG_CACHE_HOME = Join-Path $CloneHome 'cache'
$env:XDG_STATE_HOME = Join-Path $CloneHome 'state'
$AuthJsonPath = Join-Path $env:XDG_DATA_HOME 'opencode\auth.json'

# Standalone-login check: <data>\opencode\auth.json is the account-login store
# (reset_minimax_opencode.ps1 -KeepLogin preserves exactly this file). Missing
# = headless runs resolve to the FREE model, so warn with the fix (unless
# silenced). Machine-env credentials never count as a login.
function Test-CloneLoggedIn {
    if (-not (Test-Path -LiteralPath $AuthJsonPath)) { return $false }
    try {
        $raw = Get-Content -LiteralPath $AuthJsonPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Trim() -eq '{}') { return $false }
        return $true
    } catch { return $false }
}

if (-not $NoLoginWarn -and -not (Test-CloneLoggedIn)) {
    Write-Host "[model] WARNING: $($cfg.Color) has no account login - headless runs use the FREE model" -ForegroundColor Yellow
    Write-Host '[model] (iceman-free), NOT this clone''s account plan.' -ForegroundColor Yellow
    Write-Host '[model] One-time fix: run this script again with -Login (interactive flow; it writes' -ForegroundColor Yellow
    Write-Host '[model] <data>\opencode\auth.json). One credential = one instance.' -ForegroundColor Yellow
}

if ($StopService) {
    Write-Host "[light] Stopping the background service for $($cfg.Color) (home: $CloneHome)..." -ForegroundColor Cyan
    & $CliExe service stop
    $stopExit = $LASTEXITCODE
    # Verify-after: `service status` must report stopped (idempotent when no
    # service was running).
    $statusOut = (& $CliExe service status 2>&1 | Out-String)
    if ($stopExit -eq 0 -and $statusOut -match '(?i)stopped') {
        Write-Host '[light] OK - service stopped (verify-after passed).' -ForegroundColor Green
        exit 0
    }
    Write-Host ("[light] FAILED - service stop exit {0}, status still: {1}" -f $stopExit, $statusOut.Trim()) -ForegroundColor Red
    exit 1
}

if ($Login) {
    Write-Host "[login] One-time account login for $($cfg.Color) (home: $CloneHome)." -ForegroundColor Cyan
    Write-Host "[login] Follow the interactive flow in THIS console - it writes the clone's own" -ForegroundColor Cyan
    Write-Host '[login] auth.json; never reuse another clone''s login.' -ForegroundColor Cyan
    & $CliExe auth login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[login] FAILED - exit code $LASTEXITCODE (see output above)." -ForegroundColor Red
        exit 1
    }
    # Verify-after: the login must persist credentials into the clone's data
    # home (auth.json, non-empty and not the literal "{}").
    if (Test-CloneLoggedIn) {
        Write-Host '[login] OK - auth.json written; headless runs now use this clone''s account.' -ForegroundColor Green
        exit 0
    }
    Write-Host '[login] FAILED - login exited 0 but no auth.json landed in the clone data home.' -ForegroundColor Red
    Write-Host "[login] (checked: $AuthJsonPath)" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $UserProfile }
if (-not (Test-Path -LiteralPath $Cwd)) { throw "Working directory does not exist: $Cwd" }
Push-Location -LiteralPath $Cwd
# Project-directory binding (live-verified 2026-11-07, two mechanisms):
# - The CLI resolves its project from the PWD ENV VAR (unix convention), NOT
#   the process CWD. PowerShell children inherit a STALE PWD from their
#   parent shell (bash/CMD never updates it on Set-Location), so without
#   this line every `run` turn silently bound to the launcher's own launch
#   dir's project while the banner printed the requested -Cwd (sessions
#   recorded the repo dir; with $env:PWD set the session recorded -Cwd).
# - [Environment]::CurrentDirectory keeps the Win32 CWD aligned for any
#   child that reads it the Windows way (PowerShell passes the PROVIDER
#   location as the child working directory, so Push-Location already
#   covers that side; this line is belt-and-braces for spawned shells).
$env:PWD = $Cwd
[Environment]::CurrentDirectory = $Cwd

function Invoke-LightRun {
    param([string]$Text)
    $runArgs = @('run')
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $runArgs += @('--model', $Model) }
    if ($Auto) { $runArgs += '--auto' }
    if ($Standalone) { $runArgs += '--standalone' }
    if ($Json) { $runArgs += @('--format', 'json') }
    $runArgs += $Text
    # NO pipeline capture around this call: assigning the function's output
    # ($ok = Invoke-LightRun / $null = ...) swallows the CLI's ENTIRE stdout
    # (live-verified: the turn succeeded, the answer landed in the session
    # store, and stdout showed only the banner). Call it as a statement and
    # branch on $LASTEXITCODE at the call site.
    & $CliExe @runArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("[light] FAILED - exit code {0} (output above; see {1}\opencode\log\opencode.log)." -f $LASTEXITCODE, $env:XDG_DATA_HOME) -ForegroundColor Red
    }
}

if ($Server) {
    Write-Host "[light] $($cfg.Color) v2 API/web server - the CALLER owns this process." -ForegroundColor Cyan
    Write-Host "[light] home=$CloneHome cli=$CliExe"
    $serveArgs = @('serve')
    if ($Port -gt 0) { $serveArgs += @('--port', "$Port") }
    & $CliExe @serveArgs
    Pop-Location
    exit $LASTEXITCODE
}

if ($Acp) {
    if ($Server -or (-not [string]::IsNullOrWhiteSpace($Prompt))) {
        throw "-Acp is a foreground stdio mode and cannot combine with -Server or -Prompt."
    }
    Write-Host "[light] $($cfg.Color) ACP server on stdio - the CALLER owns this pipe." -ForegroundColor Cyan
    Write-Host "[light] home=$CloneHome cli=$CliExe"
    $acpArgs = @('acp')
    & $CliExe @acpArgs
    Pop-Location
    exit $LASTEXITCODE
}

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    Write-Host "[light] $($cfg.Color) one-shot task (cwd=$Cwd)..." -ForegroundColor Cyan
    Invoke-LightRun -Text $Prompt
    Pop-Location
    if ($LASTEXITCODE -ne 0) { exit 1 }
    exit 0
}

# Interactive REPL: one `run` per task; first task auto-starts the clone's
# background service, later tasks reuse it. The service keeps running after
# exit (same lifetime model as the desktop clone) - -StopService ends it.
Write-Host ("[light] OpenCode {0} light worker - state isolated to {1}" -f $cfg.Color, $cfg.Home) -ForegroundColor Cyan
Write-Host '[light] Type a task and press Enter. Empty input exits. Each task is a fresh session'
Write-Host '[light] in the clone''s own store (shareable with its desktop app).'
Write-Host '[light] Tasks that edit files or run commands need -Auto, or they wait on approval.'
try {
    while ($true) {
        $task = Read-Host '[light] task'
        if ([string]::IsNullOrWhiteSpace($task)) { Write-Host '[light] bye.'; Pop-Location; exit 0 }
        Invoke-LightRun -Text $task
    }
} finally {
    Pop-Location
}
