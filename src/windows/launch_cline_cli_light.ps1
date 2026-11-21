#Requires -Version 5.1
# Cline Light Worker Launcher (headless, per-clone-home).
# Runs the Cline CLI against a clone's isolated state WITHOUT the desktop
# window: one Bun SEA process instead of a full Tauri app + hub/sidecar.
#
# Mechanism (Phase-0 evidence, 2026-11-17, cline-cli.exe 3.0.74):
#   - The desktop install ships a standalone CLI binary at
#     %LOCALAPPDATA%\Cline\cline-cli.exe (Bun single-executable application -
#     the SAME engine the desktop app spawns as its hub/sidecar daemons,
#     docs/CLINE_CLONES_SPEC.md 3.1). `--version` reports "3.0.74".
#   - `--help` captured 2026-11-17 (verbatim surface this script codes to):
#       prompt (positional)  "Your prompt. Default to start in act mode with
#                            auto-approve enabled." -> a positional prompt IS
#                            the one-shot mode; bare invocation = interactive
#       --json               JSON output instead of styled text (headless)
#       --auto-approve <b>   tool auto-approval (default: true)
#       -y, --yolo           auto-approve a LIMITED tool set (CI/benchmarks)
#       -t, --timeout <s>    one-shot run timeout (default 0 = none)
#       -m, --model <id>     model override for the session
#       auth [provider]      interactive provider login
#   - Per-clone isolation rides CLINE_DIR - the SAME env lever the desktop
#     clone launcher sets (launch_cline_clone.ps1 step env block; the binary
#     resolves its config dir from CLINE_DIR first, falling back to
#     ~/.cline). --config/--data-dir flags exist as documented fallbacks but
#     the env var is what the suite already standardizes on.
#   - Port levers: CLINE_HUB_PORT / CLINE_SIDECAR_PORT = the clone's fixed
#     ports from launch_cline_clone.ps1's PortPlan (25471..25475 / 3131..3135)
#     so a CLI hub the worker may spawn lands on the clone's own plan, never
#     on the stock 25463..25466/3126 range and never on a sibling clone's.
#   - HONEST LIMITS (DERIVED, no live run yet):
#       * When the desktop clone is RUNNING (hub lock held) the CLI shares
#         the same CLINE_DIR + hub port, so it is expected to ATTACH to the
#         clone's running hub (same home = shared sessions, the ZCode/OpenCode
#         light-worker precedent). This script WARNS and proceeds; if the
#         session misbehaves, close the desktop clone first. The attach
#         behavior itself is UNVERIFIED.
#       * Login persistence: the desktop clone's login is a WEBVIEW login
#         (WEBVIEW2_USER_DATA_FOLDER) and no auth/credential file surfaced in
#         the Primary's CLINE_DIR tree - so this script cannot file-verify a
#         login. -Auth runs the interactive `auth` flow and verifies the exit
#         code only; whether the desktop web login satisfies the CLI is
#         UNVERIFIED (live acceptance).
#
# Modes:
#   default           interactive CLI session on the clone's state (act mode,
#                     auto-approval ON - the CLI's own defaults)
#   -Prompt "text"    one-shot task: run, report the exit code, exit
#                     (-Timeout seconds caps it; -Json = machine-readable
#                     output; -NoAutoApprove = gate on tool approvals)
#   -Yolo             one-shot with the CLI's LIMITED auto-approve set
#                     (benchmarks/CI shape - DANGEROUS, the CLI's own warning)
#   -Auth             one-time interactive provider login for THIS clone home
param(
    [ValidateSet('c1', 'c2', 'c3', 'c4', 'c5')]
    [string]$Instance = 'c1',
    [string]$Prompt = '',
    [string]$Model = '',
    [string]$Cwd = '',
    [ValidateRange(0, 86400)]
    [int]$Timeout = 0,
    # One-shot machine-readable output (--json): the CLI's headless contract.
    [switch]$Json,
    # One-shot approval gating (--auto-approve false). The CLI DEFAULTS to
    # auto-approving all tools, so this is the way to make a run ask first.
    [switch]$NoAutoApprove,
    # One-shot with the CLI's limited auto-approve set (-y): unsupervised
    # runs in sandboxed/CI environments. The CLI prints its own DANGEROUS note.
    [switch]$Yolo,
    [switch]$Auth,
    # Binary override (functional probe still applies: --version must exit 0).
    [string]$ClineBin = ''
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

# Binary ladder: explicit -ClineBin override, then the desktop install's
# standalone CLI, then a PATH-installed `cline` (the npm distribution of the
# same engine). The probe is functional (--version must exit 0 reporting a
# bare semver - verified shape "3.0.74"), never a bare path/Get-Command hit.
$BinCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($ClineBin)) { $BinCandidates += $ClineBin }
$BinCandidates += (Join-Path $LocalAppData 'Cline\cline-cli.exe')
$pathBin = (Get-Command 'cline' -ErrorAction SilentlyContinue)
if ($pathBin -and $pathBin.Source) { $BinCandidates += $pathBin.Source }

$CliExe = $null
foreach ($candidate in $BinCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        $v = & $candidate --version 2>$null
        if ($LASTEXITCODE -eq 0 -and ("$v") -match '^\d+\.\d+') { $CliExe = $candidate; break }
    } catch { }
}
if (-not $CliExe) { throw "cline-cli.exe not found or non-functional. Checked: $($BinCandidates -join '; '). Install/repair the Cline desktop app and retry." }

# Display vocabulary: colors are the user-facing clone names; the frozen
# c1..c5 keys stay in params, dirs and ports only (frozen plumbing).
$InstanceMap = @{
    'c1' = @{ Home = 'ClineClonesHome\c1'; Color = 'Blue';   Hub = 25471; Sidecar = 3131 }
    'c2' = @{ Home = 'ClineClonesHome\c2'; Color = 'Yellow'; Hub = 25472; Sidecar = 3132 }
    'c3' = @{ Home = 'ClineClonesHome\c3'; Color = 'Green';  Hub = 25473; Sidecar = 3133 }
    'c4' = @{ Home = 'ClineClonesHome\c4'; Color = 'Red';    Hub = 25474; Sidecar = 3134 }
    'c5' = @{ Home = 'ClineClonesHome\c5'; Color = 'Orange'; Hub = 25475; Sidecar = 3135 }
}
$cfg = $InstanceMap[$Instance]
$CloneDir = Join-Path $UserProfile $cfg.Home

# Light-worker PID-marker contract (shared lib): one JSON marker per clone
# home for the whole worker run, removed on exit; readers validate pid
# liveness so a hard-killed worker reads as stale, never as running.
. (Join-Path $PSScriptRoot 'ghost_light_marker.ps1')
$LightMarkerPath = Join-Path $CloneDir '.ghost-light-worker.json'

if (-not (Test-Path -LiteralPath $CloneDir)) {
    throw "Clone home $($cfg.Color) does not exist yet ($CloneDir). Launch its desktop instance once (GHOST.bat Cline [1]-[5]) to create it, then retry."
}

# Running-desktop guard: WARN, never block (same-home sharing is the point of
# a light worker - the ZCode/OpenCode precedent). Held hub lock = the desktop
# clone owns this home right now; the CLI is expected to attach to its hub.
$HubLock = Join-Path $CloneDir 'data\locks\hub\production.json.instance.lock'
if (Test-Path -LiteralPath $HubLock) {
    $lockHeld = $false
    try {
        $fs = [System.IO.File]::Open($HubLock, 'Open', 'Read', 'None')
        $fs.Close()
    } catch { $lockHeld = $true }
    if ($lockHeld) {
        Write-Host "[light] WARNING: $($cfg.Color)'s desktop clone appears RUNNING (hub lock held)." -ForegroundColor Yellow
        Write-Host '[light] The CLI shares this home + hub port, so it should attach to the running hub' -ForegroundColor Yellow
        Write-Host '[light] (sessions shared - same store). If this session misbehaves, close the' -ForegroundColor Yellow
        Write-Host '[light] desktop clone first and retry.' -ForegroundColor Yellow
    }
}

# Per-clone env levers - the same ones the desktop launcher sets, so the CLI
# state lands in the clone's own tree and any hub lands on its own ports.
$env:CLINE_DIR = $CloneDir
$env:CLINE_HUB_PORT = "$($cfg.Hub)"
$env:CLINE_SIDECAR_PORT = "$($cfg.Sidecar)"

if ($Auth) {
    if (-not [string]::IsNullOrWhiteSpace($Prompt)) { throw "-Auth is an interactive mode and cannot combine with -Prompt." }
    Write-Host "[auth] One-time CLI account login for $($cfg.Color) (home: $CloneDir)." -ForegroundColor Cyan
    Write-Host "[auth] Follow the interactive flow in THIS console - it writes the clone's own CLI" -ForegroundColor Cyan
    Write-Host '[auth] auth state; never reuse another clone''s login. NOTE: no file-verified' -ForegroundColor Yellow
    Write-Host '[auth] persistence check exists yet (see the header) - the exit code is the gate.' -ForegroundColor Yellow
    & $CliExe auth
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[auth] FAILED - exit code $LASTEXITCODE (see output above)." -ForegroundColor Red
        exit 1
    }
    Write-Host '[auth] OK - login flow exited 0. If a one-shot run still reports an auth error,' -ForegroundColor Green
    Write-Host '[auth] the desktop web login / CLI auth split needs a live probe (LC-style).' -ForegroundColor Green
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $UserProfile }
if (-not (Test-Path -LiteralPath $Cwd)) { throw "Working directory does not exist: $Cwd" }
Push-Location -LiteralPath $Cwd
# Project-directory binding (the OpenCode light-worker lesson, DERIVED for
# Cline - the CLI may resolve its project from the PWD env var, and PS
# children inherit a STALE PWD from their parent shell):
$env:PWD = $Cwd
[Environment]::CurrentDirectory = $Cwd

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    Write-Host "[light] $($cfg.Color) one-shot task (cwd=$Cwd)..." -ForegroundColor Cyan
    $runArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $runArgs += @('-m', $Model) }
    if ($Timeout -gt 0) { $runArgs += @('-t', "$Timeout") }
    if ($Json) { $runArgs += '--json' }
    if ($Yolo -and $NoAutoApprove) { throw "-Yolo and -NoAutoApprove are mutually exclusive approval policies." }
    if ($Yolo) { $runArgs += '-y' }
    if ($NoAutoApprove) { $runArgs += @('--auto-approve', 'false') }
    $runArgs += $Prompt
    Write-GhostLightMarker -Path $LightMarkerPath -Suite 'cline' -Instance $Instance -Mode 'prompt'
    try {
        # NO pipeline capture around this call (the OpenCode lesson: assigning the
        # output swallows the CLI's stdout). Call as a statement, branch on exit.
        & $CliExe @runArgs
        $exit = $LASTEXITCODE
    } finally {
        Remove-GhostLightMarker -Path $LightMarkerPath
        Pop-Location
    }
    if ($exit -ne 0) {
        Write-Host ("[light] FAILED - exit code {0} (output above)." -f $exit) -ForegroundColor Red
        exit 1
    }
    exit 0
}

# Interactive CLI session on the clone's own state. The CLI's defaults apply
# and are loud by design: act mode + tool auto-approval ON - review before
# pressing Enter.
Write-Host ("[light] Cline {0} light worker - state isolated to {1}" -f $cfg.Color, $cfg.Home) -ForegroundColor Cyan
Write-Host "[light] cli=$CliExe  hub=$($cfg.Hub)  sidecar=$($cfg.Sidecar)"
Write-Host '[light] The CLI defaults to ACT MODE with tool auto-approval ON - review each'
Write-Host '[light] prompt before Enter. Exit the CLI session to return.'
Write-GhostLightMarker -Path $LightMarkerPath -Suite 'cline' -Instance $Instance -Mode 'repl'
try {
    & $CliExe
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
