#Requires -Version 5.1
# ZCode Light Worker Launcher (headless, per-clone-account).
# Runs a clone's ZCode account WITHOUT its desktop window: one node process
# (~0.9 GB commit with plugin hosts) instead of a full Electron instance
# (~1.6 GB+ private commit measured across the running fleet, 2026-10-28).
#
# Mechanism (live-verified 2026-10-28 on ZCodeSecondHome):
#   - The CLI bundle is resources\glm\zcode.cjs; headless = -p "<prompt>" and
#     long-lived = the "app-server" stdio subcommand. Both run fine under the
#     system node (v24 verified); the interactive TUI does NOT - @zcode/tui
#     only resolves inside the app's own Electron runtime (app.asar), so a
#     standalone TUI is impossible (see docs/ZCODE_LIGHT_MODE.md).
#   - Per-account isolation rides the env levers:
#       HOME + USERPROFILE      -> <CloneHome>   (redirects cli\config.json +
#                                                   cli\db\db.sqlite via os.homedir())
#       ZCODE_DATA_BASE_DIR     -> <CloneHome>   (redirects v2\credentials.json +
#                                                   telemetry + provider_config.json)
#       ZCODE_STORAGE_DIR       -> <CloneHome>\.zcode  (cli\exec, clipboard, caches)
#     Sessions land in the clone's own db.sqlite and share history with that
#     clone's desktop app (same home = same store).
#
# MODEL CAVEAT (verified): a home without a standalone CLI login runs headless
# turns on the FREE opencode-zen model (muse-spark-1.3-contributor-free), NOT
# the account's Start Plan - the desktop app injects the plan adapter into its
# own children (hasInjectedModelAdapter), and a hand-written
# defaultModelSelection in provider_config.json is normalized away by the CLI.
# The sanctioned fix is ONE `zcode login zai` per clone home (this script
# prints the exact command when it detects the default is missing); the login
# writes the correct defaultModelSelection itself. Until then, light workers
# burn the free model, not the plan.
#
# Modes:
#   default            interactive REPL: type a task per line, empty = exit
#   -Prompt "text"     one-shot: run the task and exit (verify-after on exit code)
#   -Server            foreground `app-server` stdio worker for orchestrators
#                      (the caller owns the pipe; never detach this mode)
param(
    [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth')]
    [string]$Instance = 'Second',
    [string]$Prompt = '',
    [ValidateSet('build', 'edit', 'plan', 'yolo', 'guarded')]
    [string]$Mode = 'build',
    [string]$Cwd = '',
    [switch]$Server,
    # One-time interactive `zcode login zai` for THIS clone home: the browser
    # OAuth writes defaultModelSelection itself, which is what routes light
    # workers AND the T3 bridge to the account's Start Plan (verify-after).
    [switch]$Login,
    [switch]$NoLoginWarn
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

# CLI bundle path: same install locations the desktop launcher probes.
$ZcodeCliCandidates = @(
    (Join-Path $LocalAppData 'Programs\ZCode\resources\glm\zcode.cjs'),
    'C:\Program Files\ZCode\resources\glm\zcode.cjs',
    'C:\Program Files (x86)\ZCode\resources\glm\zcode.cjs'
)
$ZcodeCli = $ZcodeCliCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ZcodeCli) { throw "zcode.cjs not found. Checked: $($ZcodeCliCandidates -join '; ')" }

$InstanceMap = @{
    'Second' = @{ Home = 'ZCodeSecondHome'; AccentHex = '#066BCB'; DisplayName = 'Blue' }
    'Third'  = @{ Home = 'ZCodeThirdHome';  AccentHex = '#D4AA10'; DisplayName = 'Yellow' }
    'Fourth' = @{ Home = 'ZCodeFourthHome'; AccentHex = '#13826A'; DisplayName = 'Green' }
    'Fifth'  = @{ Home = 'ZCodeFifthHome';  AccentHex = '#CA0607'; DisplayName = 'Red' }
    'Sixth'  = @{ Home = 'ZCodeSixthHome';  AccentHex = '#CB5D06'; DisplayName = 'Orange' }
}
$cfg = $InstanceMap[$Instance]
$CloneHome = Join-Path $UserProfile $cfg.Home
$CloneZCode = Join-Path $CloneHome '.zcode'

if (-not (Test-Path -LiteralPath (Join-Path $CloneZCode 'v2\credentials.json'))) {
    throw "Clone home $Instance has no profile yet ($CloneZCode). Launch its desktop instance once (GHOST.bat ZCode [1]-[5]) to seed it, then retry."
}

# Per-account env levers. USERPROFILE is set alongside HOME because the CLI's
# os.homedir() follows USERPROFILE on Windows while one bundle helper reads
# HOME - both is the only shape verified end-to-end (db, config, credentials,
# plugins and logs all landed in the clone home).
$env:HOME = $CloneHome
$env:USERPROFILE = $CloneHome
$env:ZCODE_DATA_BASE_DIR = $CloneHome
$env:ZCODE_STORAGE_DIR = $CloneZCode

# Node probe = functional (matches the repo's Python rule): a candidate only
# counts when --version exits 0 reporting a version.
$NodeExe = $null
$nodeCandidates = @()
try {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $nodeCandidates += $cmd.Source }
} catch { }
$nodeCandidates += 'C:\Program Files\nodejs\node.exe'
foreach ($candidate in $nodeCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) { continue }
    try {
        $v = & $candidate --version 2>$null
        if ($LASTEXITCODE -eq 0 -and ("$v") -match '^v\d+') { $NodeExe = $candidate; break }
    } catch { }
}
if (-not $NodeExe) { throw "node.exe not found or non-functional. Install Node.js (https://nodejs.org) and re-run." }

# Standalone-login check: provider_config.json -> config.defaultModelSelection
# is the signature the CLI's own `login` flow writes. Missing = headless runs
# resolve to the free zen model, so warn with the exact fix (unless silenced).
if (-not $NoLoginWarn) {
    $provCfgPath = Join-Path $CloneZCode 'v2\provider_config.json'
    $hasDefaultModel = $false
    if (Test-Path -LiteralPath $provCfgPath) {
        try {
            $provRaw = Get-Content -LiteralPath $provCfgPath -Raw
            if ($provRaw -match '"defaultModelSelection"') { $hasDefaultModel = $true }
        } catch { $hasDefaultModel = $false }
    }
    if (-not $hasDefaultModel) {
        Write-Host "[model] WARNING: $Instance has no standalone CLI login - headless runs use the FREE" -ForegroundColor Yellow
        Write-Host '[model] opencode-zen model, NOT this account''s Start Plan (the desktop app injects the' -ForegroundColor Yellow
        Write-Host '[model] plan adapter only into its own children; hand-edited defaults are ignored).' -ForegroundColor Yellow
        Write-Host '[model] One-time fix - in a terminal run:' -ForegroundColor Yellow
        Write-Host ('[model]   set HOME={0}' -f $CloneHome) -ForegroundColor Yellow
        Write-Host ('[model]   set USERPROFILE={0}' -f $CloneHome) -ForegroundColor Yellow
        Write-Host ('[model]   set ZCODE_DATA_BASE_DIR={0}' -f $CloneHome) -ForegroundColor Yellow
        Write-Host ('[model]   set ZCODE_STORAGE_DIR={0}' -f $CloneZCode) -ForegroundColor Yellow
        Write-Host ('[model]   node "{0}" login zai' -f $ZcodeCli) -ForegroundColor Yellow
        Write-Host '[model] (log in with THIS clone''s account; the login writes the plan default itself).' -ForegroundColor Yellow
    }
}

if ($Login) {
    Write-Host "[login] One-time standalone login for $Instance (home: $CloneHome)." -ForegroundColor Cyan
    Write-Host "[login] A browser window will open - sign in with THIS clone's account." -ForegroundColor Cyan
    & $NodeExe $ZcodeCli login zai
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[login] FAILED - exit code $LASTEXITCODE (see output above)." -ForegroundColor Red
        exit 1
    }
    # Verify-after: the login flow itself writes defaultModelSelection into the
    # home's provider_config.json - its presence is the success signature.
    $provCfgPath = Join-Path $CloneZCode 'v2\provider_config.json'
    $hasDefaultModel = $false
    try {
        $provRaw = Get-Content -LiteralPath $provCfgPath -Raw
        if ($provRaw -match '"defaultModelSelection"') { $hasDefaultModel = $true }
    } catch { $hasDefaultModel = $false }
    if ($hasDefaultModel) {
        Write-Host '[login] OK - defaultModelSelection written; light workers and the T3 bridge now run on this account''s plan.' -ForegroundColor Green
        exit 0
    }
    Write-Host '[login] FAILED - login exited 0 but defaultModelSelection is still missing from provider_config.json.' -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Cwd)) { $Cwd = $UserProfile }

function Invoke-LightPrompt {
    param([string]$Text)
    & $NodeExe $ZcodeCli -p $Text --mode $Mode --cwd $Cwd
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("[light] FAILED - exit code {0} (output above; see {1}\.zcode\cli\log)." -f $LASTEXITCODE, $CloneHome) -ForegroundColor Red
    }
    return ($LASTEXITCODE -eq 0)
}

if ($Server) {
    Write-Host "[light] $Instance ($($cfg.DisplayName)) app-server on stdio - the CALLER owns this pipe." -ForegroundColor Cyan
    Write-Host "[light] home=$CloneHome cli=$ZcodeCli"
    & $NodeExe $ZcodeCli app-server
    exit $LASTEXITCODE
}

if (-not [string]::IsNullOrWhiteSpace($Prompt)) {
    Write-Host "[light] $Instance ($($cfg.DisplayName)) one-shot task (mode=$Mode, cwd=$Cwd)..." -ForegroundColor Cyan
    $ok = Invoke-LightPrompt -Text $Prompt
    if (-not $ok) { exit 1 }
    exit 0
}

# Interactive REPL: one node process per task, per-account isolation everywhere.
Write-Host ("[light] ZCode {0} light worker - account isolated to {1}" -f $Instance, $cfg.Home) -ForegroundColor Cyan
Write-Host '[light] Type a task and press Enter. Empty input exits. Each task is a fresh session'
Write-Host '[light] in the clone''s own store (shareable with its desktop app).'
while ($true) {
    $task = Read-Host '[light] task'
    if ([string]::IsNullOrWhiteSpace($task)) { Write-Host '[light] bye.'; exit 0 }
    $null = Invoke-LightPrompt -Text $task
}
