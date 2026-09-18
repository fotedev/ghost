# ZCode Second Instance Launcher
# Launches a fully independent 2nd ZCode window alongside the primary instance.
# Mechanism (reverse-engineered from resources/app.asar -> out/main/index.js):
#   - Electron single-instance lock lives in userData dir (app.getPath('userData')).
#     The app OVERWRITES --user-data-dir CLI flag via app.setPath("userData", qn),
#     so the ONLY way to separate locks is via env vars:
#       ZCODE_DESKTOP_USER_DATA_DIR / ZCODE_DESKTOP_SESSION_DATA_DIR
#   - Chat/history/SQLite lives under getDataBaseDir()/.zcode where
#     getDataBaseDir() = $inMemory || ZCODE_DATA_BASE_DIR || HOME || os.homedir().
#     Isolating ZCODE_DATA_BASE_DIR (+ HOME + Electron home) gives an independent
#     tasks-index.sqlite / db.sqlite with no SQLITE_BUSY contention.
#   - CUA helper pipes are random per launch (zcode-cua-helper-<16hex>), no conflict.
$ErrorActionPreference = 'Stop'

# Portable paths: work for any Windows user, no hardcoded username.
$UserProfile  = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$AppData      = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($AppData)) { $AppData = Join-Path $UserProfile 'AppData\Roaming' }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

# Auto-detect ZCode.exe (per-user install first, then machine-wide fallbacks).
$ZCodeExeCandidates = @(
    (Join-Path $LocalAppData 'Programs\ZCode\ZCode.exe'),
    'C:\Program Files\ZCode\ZCode.exe',
    'C:\Program Files (x86)\ZCode\ZCode.exe'
)
$ZCodeExe = $ZCodeExeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $ZCodeExe) { throw "ZCode.exe not found. Checked: $($ZCodeExeCandidates -join '; ')" }

$PrimaryZCode    = Join-Path $UserProfile '.zcode'   # contains .zcode\ (primary profile)

$SecondHome      = Join-Path $UserProfile 'ZCodeSecondHome'  # DATA_BASE_DIR (will contain .zcode\)
$SecondZCode     = Join-Path $SecondHome '.zcode'
$SecondUserData  = Join-Path $AppData 'ZCode-Second'
$SecondSession   = Join-Path $SecondUserData 'session'

if (-not (Test-Path -LiteralPath $ZCodeExe)) { throw "ZCode.exe not found: $ZCodeExe" }

# 1) Ensure directories exist
New-Item -ItemType Directory -Path $SecondHome -Force | Out-Null
New-Item -ItemType Directory -Path $SecondUserData -Force | Out-Null
New-Item -ItemType Directory -Path $SecondSession -Force | Out-Null

# 2) One-time seed: clone history so 2nd instance opens with same chats/projects.
#    Never overwrites an existing 2nd profile (instances stay independent afterwards).
if (-not (Test-Path -LiteralPath (Join-Path $SecondZCode 'v2\setting.json'))) {
    Write-Host '[seed] First run: cloning .zcode -> SecondHome\.zcode (excluding live locks)...'
    if (-not (Test-Path -LiteralPath $PrimaryZCode)) { throw "Primary .zcode not found: $PrimaryZCode" }
    New-Item -ItemType Directory -Path $SecondZCode -Force | Out-Null
    # robocopy exit codes 0-7 = success; mirror content but skip live SQLite journals/locks
    robocopy $PrimaryZCode $SecondZCode /E /XD 'crash' 'logs' 'tmp' 'bots-runtime-locks' 'runtime' /XF '*.log' | Out-Null
    # Remove any copied SQLite journals so the clone starts from a consistent checkpoint
    Get-ChildItem -Path $SecondZCode -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-shm' -or $_.Name -like '*-wal' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Write-Host '[seed] Clone complete.'

    # 2b) Seed-hazard scrub: the clone carries PRIMARY identity + account links.
    # Without this, the Secondary would relaunch with duplicated IDs/tokens.
    # Rotate to fresh values now (chat history preserved; only identity scrubbed).
    Write-Host '[seed-scrub] Rotating cloned identity values (fresh independent IDs)...' -ForegroundColor Cyan
    $noBom = New-Object System.Text.UTF8Encoding $false
    try {
        $telPath = Join-Path $SecondZCode 'v2\telemetry-state.json'
        if (Test-Path -LiteralPath $telPath) {
            try {
                $tj = Get-Content -LiteralPath $telPath -Raw | ConvertFrom-Json
                $tj.deviceMid = ([guid]::NewGuid().ToString()).ToLowerInvariant()
                [System.IO.File]::WriteAllText($telPath, ($tj | ConvertTo-Json -Depth 20), $noBom)
                Write-Host '[seed-scrub] telemetry-state.json deviceMid rotated.' -ForegroundColor Green
            } catch { Write-Host "[seed-scrub] telemetry-state.json SKIP ($($_.Exception.Message))" -ForegroundColor Yellow }
        }
        $setPath = Join-Path $SecondZCode 'v2\setting.json'
        if (Test-Path -LiteralPath $setPath) {
            try {
                $sj = Get-Content -LiteralPath $setPath -Raw | ConvertFrom-Json
                $newSid = 'd_' + (-join ((1..14) | ForEach-Object { 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'[(Get-Random -Maximum 62)] }))
                if ($null -ne $sj.PSObject.Properties['webRemoteControlExternalRelayDevice']) {
                    $sj.webRemoteControlExternalRelayDevice.deviceSid = $newSid
                } else {
                    Add-Member -InputObject $sj -NotePropertyName 'webRemoteControlExternalRelayDevice' -NotePropertyValue @{ deviceSid = $newSid }
                }
                [System.IO.File]::WriteAllText($setPath, ($sj | ConvertTo-Json -Depth 20), $noBom)
                Write-Host '[seed-scrub] setting.json deviceSid rotated.' -ForegroundColor Green
            } catch { Write-Host "[seed-scrub] setting.json SKIP ($($_.Exception.Message))" -ForegroundColor Yellow }
        }
        $credPath = Join-Path $SecondZCode 'v2\credentials.json'
        if (Test-Path -LiteralPath $credPath) {
            try {
                $cj = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
                $del = @()
                foreach ($prop in @($cj.PSObject.Properties)) {
                    if ($prop.Name.StartsWith('oauth:', [System.StringComparison]::OrdinalIgnoreCase) -or ($prop.Name -ieq 'zcodejwttoken')) { $del += $prop.Name }
                }
                foreach ($k in $del) { $null = $cj.PSObject.Properties.Remove($k) }
                [System.IO.File]::WriteAllText($credPath, ($cj | ConvertTo-Json -Depth 20), $noBom)
                Write-Host ("[seed-scrub] credentials.json OAuth cleared: {0} keys (fresh login required)." -f $del.Count) -ForegroundColor Green
            } catch { Write-Host "[seed-scrub] credentials.json SKIP ($($_.Exception.Message))" -ForegroundColor Yellow }
        }
        $cfgPath = Join-Path $SecondZCode 'v2\config.json'
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $gj = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                $n = 0
                if (($null -ne $gj) -and ($null -ne $gj.PSObject.Properties['provider'])) {
                    foreach ($prop in $gj.provider.PSObject.Properties) {
                        if (($null -ne $prop.Value) -and ($null -ne $prop.Value.PSObject.Properties['options']) -and ($null -ne $prop.Value.options.PSObject.Properties['apiKey']) -and ($prop.Value.options.apiKey -ne '')) {
                            $prop.Value.options.apiKey = ''; $n++
                        }
                    }
                    [System.IO.File]::WriteAllText($cfgPath, ($gj | ConvertTo-Json -Depth 20), $noBom)
                }
                Write-Host ("[seed-scrub] config.json provider apiKeys blanked: {0} (re-enter on next login)." -f $n) -ForegroundColor Green
            } catch { Write-Host "[seed-scrub] config.json SKIP ($($_.Exception.Message))" -ForegroundColor Yellow }
        }
        $updPath = Join-Path $SecondUserData '.updaterId'
        if (Test-Path -LiteralPath $updPath) {
            [System.IO.File]::WriteAllText($updPath, ([guid]::NewGuid().ToString()).ToLowerInvariant(), $noBom)
            Write-Host '[seed-scrub] Secondary .updaterId rotated.' -ForegroundColor Green
        }
    } catch { Write-Host "[seed-scrub] WARN: $($_.Exception.Message) (launch continues)" -ForegroundColor Yellow }
} else {
    Write-Host '[seed] Second profile already exists, skipping clone (independent).'
}

# 3) Launch 2nd instance in a dedicated env scope (process-scoped, does not pollute user env)
$env:ZCODE_DATA_BASE_DIR = $SecondHome
$env:ZCODE_DESKTOP_USER_DATA_DIR = $SecondUserData
$env:ZCODE_DESKTOP_SESSION_DATA_DIR = $SecondSession
$env:ZCODE_DESKTOP_HOME_DIR = $SecondHome
$env:HOME = $SecondHome

Write-Host "[launch] DATA_BASE_DIR=$($env:ZCODE_DATA_BASE_DIR)"
Write-Host "[launch] USER_DATA_DIR=$($env:ZCODE_DESKTOP_USER_DATA_DIR)"
Write-Host "[launch] SESSION_DIR=$($env:ZCODE_DESKTOP_SESSION_DATA_DIR)"

$proc = Start-Process -FilePath $ZCodeExe -PassThru
Write-Host "[launch] Second ZCode PID=$($proc.Id). Both windows should now be visible as 'ZCode'."
Write-Host '[verify] Get-Process ZCode | Where MainWindowHandle -ne 0  should list 2 rows.'
