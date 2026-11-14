#Requires -Version 5.1
# ZCode Clone Instance Launcher (Second / Third / Fourth / Fifth / Sixth)
# Launches a fully independent clone of ZCode alongside the primary instance.
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
#   - Per-clone branding (window + tray icon, separate taskbar button, in-app
#     accent color) rides on four env vars added by tools\patch_zcode_icon_override.ps1
#     into the installed app.asar:
#       ZCODE_ICON_DIR (dir with icon_windows.png + tray_icon.ico) /
#       ZCODE_AUMID_SUFFIX / ZCODE_ACCENT_HEX / ZCODE_INSTANCE_NAME
#     Without that one-time patch the app ignores all four -> default look, no harm.
param(
    # Which clone to launch. Defaults to Second so existing callers
    # (Launch-ZCode-Blue.bat, GHOST.bat ZCode submenu [1]) stay valid unchanged.
    [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth')]
    [string]$Instance = 'Second',
    # Soft RAM guard threshold: at or above this many running ZCode instances
    # (Primary + clones), launching another one asks for confirmation.
    [ValidateRange(1, 6)]
    [int]$MaxConcurrent = 3,
    # Experimental: launch the app with --disable-gpu (drops the per-instance
    # GPU process, ~200-400 MB commit each). Off by default - rendering falls
    # back to software, which may scroll slower.
    [switch]$LowRam,
    # Never ask on the RAM guard: at/over -MaxConcurrent it prints its warning
    # and continues. For unattended callers with a real but hidden console
    # stdin (tools\watch_zcode_captcha.ps1 relaunching a clone) - both the
    # console prompt and the dialog branch would block an unattended run.
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'

# --- Persistent launch log ---------------------------------------------------
# The launcher windows close automatically when done (GHOST.bat :StartClone) and
# the Desktop/Start-menu shortcuts run this script with -WindowStyle Hidden, so
# the console output is otherwise lost entirely. Append every run to
# tools\logs\launch_zcode_<Instance>.log via a transcript. One file per instance
# keeps the five parallel launchers from interleaving. Everything here is
# best-effort: a logging failure must never block the launch.
try {
    $logDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\tools\logs'))
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $script:LaunchLogPath = Join-Path $logDir ("launch_zcode_{0}.log" -f $Instance)
    Start-Transcript -Path $script:LaunchLogPath -Append -IncludeInvocationHeader | Out-Null
    Write-Host "[log] transcript: $script:LaunchLogPath"
} catch {
    Write-Host "[log] transcript disabled: $($_.Exception.Message)" -ForegroundColor Yellow
}
function Stop-LaunchLog {
    try { Stop-Transcript | Out-Null } catch { }
}

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

$PrimaryZCode = Join-Path $UserProfile '.zcode'   # contains .zcode\ (primary profile)

# Per-clone layout. The Second row is FROZEN (ZCodeSecondHome / ZCode-Second /
# AUMID '2' / blue) so upgrades never orphan an installed Secondary profile.
# Third = Yellow, Fourth = Green per the user's source artwork order.
$InstanceMap = @{
    'Second' = @{ Home = 'ZCodeSecondHome';  UserData = 'ZCode-Second'; AumidSuffix = '2'
                  BrandingRepo = 'zcode-blue-branding';   AccentHex = '#066BCB'; DisplayName = 'Blue';   ExeName = 'ZCode-Blue.exe' }
    'Third'  = @{ Home = 'ZCodeThirdHome';   UserData = 'ZCode-Third';  AumidSuffix = '3'
                  BrandingRepo = 'zcode-yellow-branding'; AccentHex = '#D4AA10'; DisplayName = 'Yellow'; ExeName = 'ZCode-Yellow.exe' }
    'Fourth' = @{ Home = 'ZCodeFourthHome';  UserData = 'ZCode-Fourth'; AumidSuffix = '4'
                  BrandingRepo = 'zcode-green-branding';  AccentHex = '#13826A'; DisplayName = 'Green';  ExeName = 'ZCode-Green.exe' }
    'Fifth'  = @{ Home = 'ZCodeFifthHome';   UserData = 'ZCode-Fifth';  AumidSuffix = '5'
                  BrandingRepo = 'zcode-red-branding';    AccentHex = '#CA0607'; DisplayName = 'Red';    ExeName = 'ZCode-Red.exe' }
    'Sixth'  = @{ Home = 'ZCodeSixthHome';   UserData = 'ZCode-Sixth';  AumidSuffix = '6'
                  BrandingRepo = 'zcode-orange-branding'; AccentHex = '#CB5D06'; DisplayName = 'Orange'; ExeName = 'ZCode-Orange.exe' }
}
$cfg = $InstanceMap[$Instance]

$CloneHome      = Join-Path $UserProfile $cfg.Home    # DATA_BASE_DIR (will contain .zcode\)
$CloneZCode     = Join-Path $CloneHome '.zcode'
$CloneUserData  = Join-Path $AppData $cfg.UserData
$CloneSession   = Join-Path $CloneUserData 'session'
# Strings that identify THIS clone's processes in any CommandLine (live-check).
$CloneMarkers   = @("*$($cfg.UserData)*", "*$($cfg.Home)*")

# Copy-family predicates (2026-11-11): clones launch from per-color exe copies
# (ZCode-Blue.exe .. ZCode-Orange.exe, built by tools\patch_zcode_exe_identity.ps1
# for the Task Manager identity). EVERY ZCode process enumeration in this script
# must match the whole copy family - a bare Name='ZCode.exe' filter silently
# drops every clone running from its copy (unguarded RAM count, dead PID diff,
# no window stamping). Empty CommandLine stays a main candidate (WMI race).
# NOTE: the unquoted-path branch uses [^"]* (NOT [^\s"]*) so machine-wide
# installs under C:\Program Files\... (path contains a space) match too - the
# old [^\s"]* class could never cross that space, a silent pre-existing gap.
$script:ZcodeFamilyWmiFilter = "Name LIKE 'ZCode%'"
function Test-ZcodeMainCmdline {
    param([string]$Cmdline)
    $c = ([string]$Cmdline).Trim()
    return ([string]::IsNullOrWhiteSpace($c)) -or
        ($c -match '^"[^"]*ZCode(?:-[A-Za-z]+)?\.exe"$') -or
        ($c -match '^[A-Za-z]:\\[^"]*ZCode(?:-[A-Za-z]+)?\.exe$')
}

# 0) RAM guard (2026-10-28): four+ concurrent instances exhausted the commit
#    limit once (renderer-OOM freeze, verified 2026-09-25) and the Start Plan
#    provider throttles high concurrency anyway. Soft guard: count running
#    ZCode mains; at or above -MaxConcurrent show live commit numbers and ask.
#    Relaunching an ALREADY-RUNNING clone only focuses its window, so the guard
#    never blocks that. The 3-way ask routing (visible prompt / hidden-console
#    dialog / non-interactive warn+continue) lives in the shared lib
#    ghost_launch_guard.ps1 since 2026-11-14 (AutoClaw2/Cline/OpenCode launch
#    the same guard).
. "$PSScriptRoot\ghost_launch_guard.ps1"
function Get-ZcodeMainIds {
    @(Get-CimInstance Win32_Process -Filter $script:ZcodeFamilyWmiFilter -ErrorAction SilentlyContinue | Where-Object {
        # Empty CommandLine is a known WMI race on fresh mains: keep as candidate.
        Test-ZcodeMainCmdline ([string]$_.CommandLine)
    } | Select-Object -ExpandProperty ProcessId)
}
function Test-ThisCloneRunning {
    # Same classification as the Telegram lock check (step 2c): walk every
    # main's process subtree and look for this clone's markers.
    $allProcs = @(Get-CimInstance Win32_Process -Filter $script:ZcodeFamilyWmiFilter -ErrorAction SilentlyContinue)
    if ($allProcs.Count -eq 0) { return $false }
    $byParent = @{}
    foreach ($p in $allProcs) {
        $ppid = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $p
    }
    foreach ($m in @($allProcs | Where-Object { Test-ZcodeMainCmdline ([string]$_.CommandLine) })) {
        $seen = @{}; $queue = New-Object System.Collections.Queue
        $queue.Enqueue([int]$m.ProcessId) | Out-Null
        while ($queue.Count -gt 0) {
            $id = $queue.Dequeue()
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            if ($byParent.ContainsKey($id)) {
                foreach ($c in $byParent[$id]) {
                    $cmd = [string]$c.CommandLine
                    foreach ($mk in $CloneMarkers) {
                        if ($cmd -like $mk) { return $true }
                    }
                    $queue.Enqueue([int]$c.ProcessId) | Out-Null
                }
            }
        }
    }
    return $false
}
$mainsNow = Get-ZcodeMainIds
if ($mainsNow.Count -ge $MaxConcurrent) {
    if (Test-ThisCloneRunning) {
        Write-Host ("[ram-guard] {0} is already running - this relaunch only focuses its window." -f $cfg.DisplayName)
    } else {
        $guardProceed = Invoke-GhostLaunchGuard -RunningMains $mainsNow.Count -MaxConcurrent $MaxConcurrent `
            -SuiteName 'ZCode' -WmiFamilyFilter $script:ZcodeFamilyWmiFilter -ProcessFamily 'ZCode*' `
            -RiskLine '[ram-guard] More instances risk the renderer-OOM freeze (verified 2026-09-25) plus Start Plan throttling.' `
            -LighterHint '[ram-guard] Lighter option: GHOST.bat ZCode [7] runs this account headless at about a quarter of the RAM.' `
            -NonInteractive:$NonInteractive
        if (-not $guardProceed) {
            Stop-LaunchLog
            exit 0
        }
    }
}

# 1) Ensure directories exist
New-Item -ItemType Directory -Path $CloneHome -Force | Out-Null
New-Item -ItemType Directory -Path $CloneUserData -Force | Out-Null
New-Item -ItemType Directory -Path $CloneSession -Force | Out-Null

# 2) One-time seed: clone history so the clone opens with same chats/projects.
#    Gate = completion MARKER (<CloneHome>\.zcode-seeded), written only after
#    the copy AND the identity scrub verified. The old single-file gate
#    (v2\setting.json) let an aborted robocopy pass as seeded once that one
#    file existed (the AutoClaw partial-seed lesson, live-verified). A
#    pre-marker profile built by an earlier launcher version is ADOPTED, never
#    re-seeded over. <CloneHome>\.zcode-seeding is written BEFORE the copy: a
#    crash mid-seed leaves it behind, and the next launch re-clears + re-seeds
#    the partial profile.
$SeedMarker    = Join-Path $CloneHome '.zcode-seeded'
$SeedingMarker = Join-Path $CloneHome '.zcode-seeding'
$noBom = New-Object System.Text.UTF8Encoding $false
$seedScrubOk = $true
if (Test-Path -LiteralPath $SeedMarker) {
    if (Test-Path -LiteralPath $SeedingMarker) {
        Remove-Item -LiteralPath $SeedingMarker -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[seed] $($cfg.DisplayName) profile already exists, skipping clone (independent)."
} elseif ((Test-Path -LiteralPath (Join-Path $CloneZCode 'v2\setting.json')) -and
          (-not (Test-Path -LiteralPath $SeedingMarker))) {
    Write-Host "[seed] Pre-marker profile found for $($cfg.DisplayName) - adopting it (never re-seed over live clone data)."
    [System.IO.File]::WriteAllText($SeedMarker, '', $noBom)
} else {
    Write-Host "[seed] First run for $($cfg.DisplayName): cloning .zcode -> $($cfg.Home)\.zcode (excluding live locks)..."
    if (-not (Test-Path -LiteralPath $PrimaryZCode)) { throw "Primary .zcode not found: $PrimaryZCode" }
    if (Test-Path -LiteralPath $SeedingMarker) {
        Write-Host '[seed] Stale seeding marker found - clearing the partial profile and re-seeding.'
        Remove-Item -LiteralPath $CloneZCode -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $CloneZCode -Force | Out-Null
    # Seeding marker BEFORE any copy: a crash mid-seed leaves the marker behind
    # so the next launch re-clears and re-seeds instead of adopting the partial.
    [System.IO.File]::WriteAllText($SeedingMarker, '', $noBom)
    # Primary-closed gate (2026-11-15): the copy source ~\.zcode holds the LIVE
    # shared CLI store (cli\db\db.sqlite), held open by EVERY running instance -
    # Primary and clones alike (verified ground truth; no stable per-profile
    # lockfile exists under ~\.zcode). Robocopying WAL-mode SQLite while a
    # writer is live can tear pages, and deleting the copied -wal journals
    # afterwards discards committed-but-uncheckpointed transactions. So the
    # seed waits for ALL ZCode mains to close (up to 180s = 36 x 5s; empty
    # CommandLine stays a main candidate per the WMI race) and fails CLOSED on
    # a WMI error. (The staged design said "Primary main"; implemented as "any
    # ZCode main" because the shared store gives every instance a handle on the
    # copied tree - strictly safer.)
    $primaryClosed = $false
    for ($i = 0; $i -lt 36; $i++) {
        $anyMains = $null
        try {
            $anyMains = @(Get-CimInstance Win32_Process -Filter $script:ZcodeFamilyWmiFilter -ErrorAction Stop |
                Where-Object { Test-ZcodeMainCmdline ([string]$_.CommandLine) })
        } catch {
            throw "[seed] ZCode process check failed (WMI unavailable) - refusing to copy a live profile. Close every ZCode instance manually and re-run."
        }
        if (@($anyMains).Count -eq 0) { $primaryClosed = $true; break }
        if ($i -eq 0) {
            Write-Host '[seed] A ZCode instance is running - the shared CLI store it holds must not be copied. Waiting up to 180s for every instance to close...' -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 5
    }
    if (-not $primaryClosed) {
        throw "[seed] ZCode is still running after 180s - refusing to copy the live profile (torn WAL copies + journal deletes lose recent chats). Close every ZCode instance (Primary AND clones), then re-run. First-time seeding of several clones: seed them ONE at a time, closing the previous clone before starting the next (the seed marker makes later launches skip)."
    }
    # robocopy exit codes 0-7 = success; 8+ = at least one failure (disk full,
    # path errors). Never proceed with a half-built seed profile: remove the
    # partial dir and throw (the seeding marker stays so the next launch
    # re-clears and re-seeds).
    robocopy $PrimaryZCode $CloneZCode /E /XD 'crash' 'logs' 'tmp' 'bots-runtime-locks' 'runtime' /XF '*.log' | Out-Null
    if ($LASTEXITCODE -ge 8) {
        Remove-Item -LiteralPath $CloneZCode -Recurse -Force -ErrorAction SilentlyContinue
        throw "[seed] robocopy failed with exit code $LASTEXITCODE -- partial clone dir removed; re-run to re-seed"
    }
    # Remove any copied SQLite journals so the clone starts from a consistent checkpoint
    # (-LiteralPath: -Path would glob a username containing [ and silently match nothing)
    Get-ChildItem -LiteralPath $CloneZCode -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-shm' -or $_.Name -like '*-wal' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    # 2b) Seed-hazard scrub: the clone carries PRIMARY identity + account links.
    # Without this, the clone would relaunch with duplicated IDs/tokens.
    # Rotate to fresh values now (chat history preserved; only identity scrubbed).
    # EVERY write below re-reads and verifies (never-silent-success); any FAILED
    # clears $seedScrubOk and the launch throws before starting the clone.
    Write-Host '[seed-scrub] Rotating cloned identity values (fresh independent IDs)...' -ForegroundColor Cyan
    try {
        $telPath = Join-Path $CloneZCode 'v2\telemetry-state.json'
        if (Test-Path -LiteralPath $telPath) {
            try {
                $tj = Get-Content -LiteralPath $telPath -Raw | ConvertFrom-Json
                $newMid = ([guid]::NewGuid().ToString()).ToLowerInvariant()
                $tj.deviceMid = $newMid
                [System.IO.File]::WriteAllText($telPath, ($tj | ConvertTo-Json -Depth 20), $noBom)
                $midBack = (Get-Content -LiteralPath $telPath -Raw | ConvertFrom-Json).deviceMid
                if ($midBack -ne $newMid) {
                    Write-Host '[seed-scrub] FAILED: telemetry-state.json deviceMid did not survive the write.' -ForegroundColor Red
                    $seedScrubOk = $false
                } else {
                    Write-Host '[seed-scrub] telemetry-state.json deviceMid rotated (verified).' -ForegroundColor Green
                }
            } catch {
                Write-Host "[seed-scrub] FAILED: telemetry-state.json ($($_.Exception.Message))" -ForegroundColor Red
                $seedScrubOk = $false
            }
        }
        $setPath = Join-Path $CloneZCode 'v2\setting.json'
        if (Test-Path -LiteralPath $setPath) {
            try {
                $sj = Get-Content -LiteralPath $setPath -Raw | ConvertFrom-Json
                # CSPRNG deviceSid (repo convention: RandomNumberGenerator.GetBytes
                # only - Get-Random is a time-seeded Mersenne-Twister PRNG).
                # Rejection sampling drops bytes >= 248 (256 mod 62 = 8 bias).
                $alnum = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
                $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
                try {
                    $rbuf = New-Object byte[] 32
                    $rng.GetBytes($rbuf)
                    $picked = @($rbuf | Where-Object { $_ -lt 248 } | ForEach-Object { $alnum[[int]($_ % 62)] })
                    while ($picked.Count -lt 14) {
                        $rng.GetBytes($rbuf)
                        $picked += @($rbuf | Where-Object { $_ -lt 248 } | ForEach-Object { $alnum[[int]($_ % 62)] })
                    }
                    $newSid = 'd_' + (-join $picked[0..13])
                } finally { if ($rng) { $rng.Dispose() } }
                if ($null -ne $sj.PSObject.Properties['webRemoteControlExternalRelayDevice']) {
                    $sj.webRemoteControlExternalRelayDevice.deviceSid = $newSid
                } else {
                    Add-Member -InputObject $sj -NotePropertyName 'webRemoteControlExternalRelayDevice' -NotePropertyValue @{ deviceSid = $newSid }
                }
                [System.IO.File]::WriteAllText($setPath, ($sj | ConvertTo-Json -Depth 20), $noBom)
                $sidBack = ((Get-Content -LiteralPath $setPath -Raw | ConvertFrom-Json).webRemoteControlExternalRelayDevice).deviceSid
                if ($sidBack -ne $newSid) {
                    Write-Host '[seed-scrub] FAILED: setting.json deviceSid did not survive the write.' -ForegroundColor Red
                    $seedScrubOk = $false
                } else {
                    Write-Host '[seed-scrub] setting.json deviceSid rotated (verified).' -ForegroundColor Green
                }
            } catch {
                Write-Host "[seed-scrub] FAILED: setting.json ($($_.Exception.Message))" -ForegroundColor Red
                $seedScrubOk = $false
            }
        }
        $credPath = Join-Path $CloneZCode 'v2\credentials.json'
        if (Test-Path -LiteralPath $credPath) {
            try {
                $cj = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
                $del = @()
                foreach ($prop in @($cj.PSObject.Properties)) {
                    if ($prop.Name.StartsWith('oauth:', [System.StringComparison]::OrdinalIgnoreCase) -or ($prop.Name -ieq 'zcodejwttoken')) { $del += $prop.Name }
                }
                if ($del.Count -gt 0) {
                    foreach ($k in $del) { $null = $cj.PSObject.Properties.Remove($k) }
                    [System.IO.File]::WriteAllText($credPath, ($cj | ConvertTo-Json -Depth 20), $noBom)
                    $credBack = Get-Content -LiteralPath $credPath -Raw | ConvertFrom-Json
                    $oauthLeft = 0
                    foreach ($prop in @($credBack.PSObject.Properties)) {
                        if ($prop.Name.StartsWith('oauth:', [System.StringComparison]::OrdinalIgnoreCase) -or ($prop.Name -ieq 'zcodejwttoken')) { $oauthLeft++ }
                    }
                    if ($oauthLeft -gt 0) {
                        Write-Host "[seed-scrub] FAILED: credentials.json still holds $oauthLeft OAuth key(s) after the write." -ForegroundColor Red
                        $seedScrubOk = $false
                    } else {
                        Write-Host ("[seed-scrub] credentials.json OAuth cleared: {0} key(s), verified (fresh login required)." -f $del.Count) -ForegroundColor Green
                    }
                } else {
                    Write-Host '[seed-scrub] credentials.json holds no OAuth keys - nothing to clear.' -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "[seed-scrub] FAILED: credentials.json ($($_.Exception.Message))" -ForegroundColor Red
                $seedScrubOk = $false
            }
        }
        $cfgPath = Join-Path $CloneZCode 'v2\config.json'
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
                }
                if ($n -gt 0) {
                    [System.IO.File]::WriteAllText($cfgPath, ($gj | ConvertTo-Json -Depth 20), $noBom)
                    # never-silent-success: re-read and assert every provider
                    # apiKey is now empty before claiming success.
                    $cfgBack = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
                    $keyLeft = 0
                    if (($null -ne $cfgBack) -and ($null -ne $cfgBack.PSObject.Properties['provider'])) {
                        foreach ($prop in $cfgBack.provider.PSObject.Properties) {
                            if (($null -ne $prop.Value) -and ($null -ne $prop.Value.PSObject.Properties['options']) -and ($null -ne $prop.Value.options.PSObject.Properties['apiKey']) -and ($prop.Value.options.apiKey -ne '')) { $keyLeft++ }
                        }
                    }
                    if ($keyLeft -gt 0) {
                        Write-Host "[seed-scrub] FAILED: config.json still holds $keyLeft non-empty provider apiKey(s) after the write." -ForegroundColor Red
                        $seedScrubOk = $false
                    } else {
                        Write-Host ("[seed-scrub] config.json provider apiKeys blanked: {0}, verified (re-enter on next login)." -f $n) -ForegroundColor Green
                    }
                } else {
                    Write-Host '[seed-scrub] config.json holds no non-empty provider apiKeys - nothing to blank.' -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "[seed-scrub] FAILED: config.json ($($_.Exception.Message))" -ForegroundColor Red
                $seedScrubOk = $false
            }
        }
        $updPath = Join-Path $CloneUserData '.updaterId'
        if (Test-Path -LiteralPath $updPath) {
            try {
                $newUpd = ([guid]::NewGuid().ToString()).ToLowerInvariant()
                [System.IO.File]::WriteAllText($updPath, $newUpd, $noBom)
                $updBack = [System.IO.File]::ReadAllText($updPath)
                if ($updBack -ne $newUpd) {
                    Write-Host '[seed-scrub] FAILED: .updaterId did not survive the write.' -ForegroundColor Red
                    $seedScrubOk = $false
                } else {
                    Write-Host '[seed-scrub] Clone .updaterId rotated (verified).' -ForegroundColor Green
                }
            } catch {
                Write-Host "[seed-scrub] FAILED: .updaterId ($($_.Exception.Message))" -ForegroundColor Red
                $seedScrubOk = $false
            }
        }
    } catch {
        Write-Host "[seed-scrub] FAILED: $($_.Exception.Message) (seed marker withheld; the clone will not launch)" -ForegroundColor Red
        $seedScrubOk = $false
    }
    if (-not $seedScrubOk) {
        # The seeding marker is deliberately left behind: the next launch
        # re-clears and re-seeds. The clone can never run on Primary identity.
        throw "[seed] Identity scrub FAILED - seed marker withheld so the clone never runs on Primary identity. Remove or fix '$CloneZCode' and re-run (the next launch auto-clears and re-seeds)."
    }
    [System.IO.File]::WriteAllText($SeedMarker, '', $noBom)
    Remove-Item -LiteralPath $SeedingMarker -Force -ErrorAction SilentlyContinue
    Write-Host '[seed] Clone complete (seed marker written).'
}

# 2c) Telegram routing (marker-guarded): one credential = one instance (EC-D03).
# Two pollers on one token cause HTTP 409 + random cross-account billing.
# v2 logic (2026-10-16): compare the clone's encrypted bot credential sha8
# (credentials.json -> bot:<id>:credential, enc:v1:, hash only, never values)
# + bot id against Primary across BOTH bot-config.json and bot-config.v3.json.
# Duplicate of Primary -> disabled in both files. Unique (UI-assisted flow:
# operator pasted a distinct BotFather token in the clone UI, app minted a
# fresh bot-<guid>) -> preserved + v2 marker so future launches never revert
# a deliberate unique bot. Legacy v1 markers (empty file) keep old behavior.
$tgMarker = Join-Path $CloneHome '.telegram-routed'
function Get-TgCredSha8 {
    param([string]$CredentialsPath, [string]$CredentialRef)
    if (-not (Test-Path -LiteralPath $CredentialsPath)) { return '' }
    try { $creds = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json }
    catch { return '' }
    $prop = $creds.PSObject.Properties[$CredentialRef]
    if ($null -eq $prop) { return '' }
    $val = [string]$prop.Value
    if ([string]::IsNullOrEmpty($val)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($val)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) }
    finally { if ($sha) { $sha.Dispose() } }
    return ([BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()).Substring(0, 8)
}
$tgMarkerText = ''
if (Test-Path -LiteralPath $tgMarker) {
    try { $tgMarkerText = (Get-Content -LiteralPath $tgMarker -Raw -ErrorAction SilentlyContinue) }
    catch { $tgMarkerText = '' }
}
if ($tgMarkerText -like 'v2 unique-bot*') {
    Write-Host '[telegram-route] v2 unique-bot marker, preserving clone bot.' -ForegroundColor DarkGray
} elseif (Test-Path -LiteralPath $tgMarker) {
    Write-Host '[telegram-route] Already reconciled, skipping.' -ForegroundColor DarkGray
} else {
    $tgNoBom = New-Object System.Text.UTF8Encoding $false
    $tgDisabled = 0        # VERIFIED disables only (re-read after write)
    $tgPreserved = 0
    $tgWriteFailed = $false
    # Fingerprint ALL Primary telegram bots (multi-bot: bot-config.v3 mints
    # bot-<guid> rows) into id + sha8 SETS - the old single-scalar probe kept
    # only the first bot with a credential, so a clone copy of bot #2 matched
    # nothing and was preserved as "unique" (duplicate poller on its token).
    $tgPrimarySha8s = @()
    $tgPrimaryIds = @()
    try {
        foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
            $tgPrimaryCfg = Join-Path $PrimaryZCode $cfgName
            if (-not (Test-Path -LiteralPath $tgPrimaryCfg)) { continue }
            $pj = Get-Content -LiteralPath $tgPrimaryCfg -Raw | ConvertFrom-Json
            foreach ($b in @($pj.bots)) {
                if ($b.provider -ne 'telegram') { continue }
                $sha = Get-TgCredSha8 -CredentialsPath (Join-Path $PrimaryZCode 'v2\credentials.json') -CredentialRef ([string]$b.credentialRef)
                if ($sha -ne '') { $tgPrimarySha8s += $sha }
                $bid = [string]$b.id
                if ($bid -ne '') { $tgPrimaryIds += $bid }
            }
        }
    } catch {
        # Swallowed by design: the failure is derived below from both sets
        # being empty; the exception detail is logged for diagnosis.
        Write-Host ("[telegram-route] Primary fingerprint read failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
    # Failure (the read threw, OR both sets end up empty) = fail CLOSED:
    # disable EVERY enabled clone bot. The old code only printed "falling back
    # to disable" and then PRESERVED the seed-copy duplicate - two pollers on
    # one token (HTTP 409 + cross-account billing), locked in by the marker.
    $tgPrimaryFailed = (($tgPrimarySha8s.Count -eq 0) -and ($tgPrimaryIds.Count -eq 0))
    if ($tgPrimaryFailed) {
        Write-Host '[telegram-route] Primary fingerprint unavailable - safe fallback: disabling every enabled clone Telegram bot.' -ForegroundColor Yellow
    }
    foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
        $tgCfg = Join-Path $CloneZCode $cfgName
        if (-not (Test-Path -LiteralPath $tgCfg)) { continue }
        $disabledInFile = @()
        try {
            $bj = Get-Content -LiteralPath $tgCfg -Raw | ConvertFrom-Json
            $changed = $false
            if (($null -ne $bj) -and ($null -ne $bj.PSObject.Properties['bots'])) {
                foreach ($b in $bj.bots) {
                    if ($b.provider -ne 'telegram') { continue }
                    if ($b.enabled -ne $true) { continue }
                    $cloneSha = Get-TgCredSha8 -CredentialsPath (Join-Path $CloneZCode 'v2\credentials.json') -CredentialRef ([string]$b.credentialRef)
                    $isDup = $false
                    if (($tgPrimarySha8s.Count -gt 0) -and ($cloneSha -ne '') -and ($tgPrimarySha8s -contains $cloneSha)) { $isDup = $true }
                    if (($tgPrimaryIds.Count -gt 0) -and ($tgPrimaryIds -contains ([string]$b.id))) { $isDup = $true }
                    if ($tgPrimaryFailed -or $isDup) {
                        $b.enabled = $false; $changed = $true; $disabledInFile += ([string]$b.id)
                    }
                    else {
                        if ($cloneSha -ne '') { $tgPreserved++ }
                        else { $b.enabled = $false; $changed = $true; $disabledInFile += ([string]$b.id) }
                    }
                }
            }
            if ($changed) {
                [System.IO.File]::WriteAllText($tgCfg, ($bj | ConvertTo-Json -Depth 20), $tgNoBom)
                # never-silent-success: re-read and verify every disable landed
                # before counting it; a write that did not stick withholds the
                # marker so the next launch retries the reconcile.
                $vbj = Get-Content -LiteralPath $tgCfg -Raw | ConvertFrom-Json
                $verified = $true
                foreach ($did in $disabledInFile) {
                    $vb = @($vbj.bots | Where-Object { ([string]$_.id) -eq $did })
                    if (($vb.Count -eq 0) -or ($null -eq $vb[0].enabled) -or ($vb[0].enabled -eq $true)) { $verified = $false }
                }
                if ($verified) { $tgDisabled += $disabledInFile.Count }
                else {
                    Write-Host "[telegram-route] FAILED: $cfgName disable(s) did not survive the write - marker withheld; next launch retries." -ForegroundColor Red
                    $tgWriteFailed = $true
                }
            }
        } catch {
            Write-Host "[telegram-route] FAILED: $cfgName ($($_.Exception.Message))" -ForegroundColor Red
            $tgWriteFailed = $true
        }
    }
    if ($tgDisabled -gt 0) { Write-Host ("[telegram-route] Disabled {0} duplicate Telegram bot(s) in {1}; Telegram stays on Primary." -f $tgDisabled, $cfg.DisplayName) -ForegroundColor Green }
    if ($tgPreserved -gt 0) { Write-Host ("[telegram-route] Preserved {0} unique Telegram bot row(s) in {1} (distinct credential)." -f $tgPreserved, $cfg.DisplayName) -ForegroundColor Green }
    if (($tgDisabled -eq 0) -and ($tgPreserved -eq 0) -and (-not $tgWriteFailed)) { Write-Host "[telegram-route] No enabled Telegram bots in $($cfg.DisplayName); nothing to do." -ForegroundColor DarkGray }
    # Drop stale polling locks, but ONLY when this clone is not running (a live
    # poller owns its lock dir). A running instance picks up the config change
    # on its next restart.
    try {
        $cloneLive = $false
        $allProcs = @(Get-CimInstance Win32_Process -Filter $script:ZcodeFamilyWmiFilter -ErrorAction SilentlyContinue)
        if ($allProcs.Count -gt 0) {
            $byParent = @{}
            foreach ($p in $allProcs) {
                $ppid = [int]$p.ParentProcessId
                if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
                $byParent[$ppid] += $p
            }
            foreach ($m in @($allProcs | Where-Object { Test-ZcodeMainCmdline ([string]$_.CommandLine) })) {
                $seen = @{}; $queue = New-Object System.Collections.Queue
                $queue.Enqueue([int]$m.ProcessId) | Out-Null
                while ($queue.Count -gt 0) {
                    $id = $queue.Dequeue()
                    if ($seen.ContainsKey($id)) { continue }
                    $seen[$id] = $true
                    if ($byParent.ContainsKey($id)) {
                        foreach ($c in $byParent[$id]) {
                            $cmd = [string]$c.CommandLine
                            foreach ($mk in $CloneMarkers) {
                                if ($cmd -like $mk) { $cloneLive = $true; break }
                            }
                            if ($cloneLive) { break }
                            $queue.Enqueue([int]$c.ProcessId) | Out-Null
                        }
                    }
                    if ($cloneLive) { break }
                }
                if ($cloneLive) { break }
            }
        }
        if ($cloneLive) {
            if ($tgDisabled -gt 0) { Write-Host "[telegram-route] $($cfg.DisplayName) is running: restart it once to apply (config saved)." -ForegroundColor Yellow }
        } else {
            $tgLockRoot = Join-Path $CloneZCode 'v2\bots-runtime-locks\telegram-polling'
            if (($tgDisabled -gt 0) -and (Test-Path -LiteralPath $tgLockRoot)) {
                Get-ChildItem -LiteralPath $tgLockRoot -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue }
                Write-Host "[telegram-route] Stale $($cfg.DisplayName) polling locks cleared." -ForegroundColor Green
            }
        }
    } catch { Write-Host "[telegram-route] lock check SKIP ($($_.Exception.Message))" -ForegroundColor Yellow }
    # Marker written ONLY when no write failed: a not-verified reconcile must
    # retry on the next launch, never be locked in as "already routed".
    if ($tgWriteFailed) {
        Write-Host '[telegram-route] Marker withheld - the failed reconcile retries on the next launch.' -ForegroundColor Yellow
    } elseif ($tgPreserved -gt 0) {
        $tgUniqueSha = ''
        $tgUniqueId = ''
        try {
            foreach ($cfgName in @('v2\bot-config.json', 'v2\bot-config.v3.json')) {
                $tgCfg = Join-Path $CloneZCode $cfgName
                if (-not (Test-Path -LiteralPath $tgCfg)) { continue }
                $uj = Get-Content -LiteralPath $tgCfg -Raw | ConvertFrom-Json
                foreach ($b in @($uj.bots)) {
                    if ($b.provider -ne 'telegram') { continue }
                    if ($b.enabled -ne $true) { continue }
                    $tgUniqueId = [string]$b.id
                    $tgUniqueSha = Get-TgCredSha8 -CredentialsPath (Join-Path $CloneZCode 'v2\credentials.json') -CredentialRef ([string]$b.credentialRef)
                    if ($tgUniqueSha -ne '') { break }
                }
                if ($tgUniqueSha -ne '') { break }
            }
        } catch { $tgUniqueSha = '' }
        if ($tgUniqueSha -ne '') {
            [System.IO.File]::WriteAllText($tgMarker, ('v2 unique-bot sha8=' + $tgUniqueSha + ' id=' + $tgUniqueId), $tgNoBom)
        }
        else {
            [System.IO.File]::WriteAllText($tgMarker, '', $tgNoBom)
        }
    }
    else {
        [System.IO.File]::WriteAllText($tgMarker, '', $tgNoBom)
    }
}

# 2d) Sync user-scope assets from the Primary into this clone BEFORE launch:
#     MCP server definitions (per-clone on/off toggles stay local), the shared
#     .agents skills junction, and the plugin cache. The clone is not running
#     yet, so writes are safe. A failed sync warns and continues - it must
#     never block the launch (fix later via GHOST.bat ZCode [17]).
$SyncScript = Join-Path $PSScriptRoot '..\..\tools\sync_zcode_assets.ps1'
Write-Host ''
Write-Host 'Step 2d) Sync clone assets from Primary - MCP definitions, skills junction, plugin cache'
if (Test-Path -LiteralPath $SyncScript) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SyncScript -Target $Instance
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Step 2d) sync reported FAILED items - launching anyway; re-run GHOST.bat ZCode [17] after closing the clones.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'Step 2d) tools\sync_zcode_assets.ps1 not found - skipping (clone stays as last synced).' -ForegroundColor Yellow
}

# 2e) Ensure the resident watchers a fresh install needs are alive AND set to
#     autostart: the MCP sync watcher (Primary config -> every clone, live,
#     running instances included) and the taskbar identity watcher (anti-merge
#     stamps). A user who only installs the clones never opens GHOST to start
#     these manually - so every legitimate clone launch (menu, Desktop/Start
#     shortcut, Launch ALL) heals both: start hidden when not running, and
#     install the Startup .lnk once so future logins are covered. Running the
#     ensure twice is harmless: the probe is a mutex test (no WMI), and each
#     watcher's own mutex guard exits any duplicate copy silently.
#     Best-effort by contract: any failure warns and NEVER blocks the launch.
function Test-WatcherRunning([string]$MutexName) {
    # initiallyOwned=$false: created=$false means someone else holds it.
    $created = $false
    $probe = New-Object System.Threading.Mutex($false, $MutexName, [ref]$created)
    $probe.Close()
    return (-not $created)
}
function Ensure-ResidentWatcher([string]$Name, [string]$ScriptPath, [string]$MutexName, [string]$AutostartLnk) {
    try {
        if (Test-WatcherRunning $MutexName) {
            Write-Host "[watchers] $Name already running."
            return
        }
        # One-time: make sure the Startup .lnk exists so future logins are
        # covered even if this is the only clone launch of the session. The
        # watcher script owns the .lnk spec (-InstallAutostart verifies after
        # writing); we only re-check existence and warn, never fail the launch.
        if (-not (Test-Path -LiteralPath $AutostartLnk)) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -InstallAutostart | Out-Null
            if (-not (Test-Path -LiteralPath $AutostartLnk)) {
                Write-Host "[watchers] $Name autostart install failed (non-fatal - the watcher still starts now)." -ForegroundColor Yellow
            }
        }
        # PS 5.1 ArgumentList joins with spaces WITHOUT quoting: pre-quote the
        # -File path so repo paths containing spaces survive.
        $fileArg = '"{0}"' -f $ScriptPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $fileArg)
        Write-Host "[watchers] started $Name (hidden, autostart ensured)." -ForegroundColor Green
    } catch {
        Write-Host "[watchers] $Name could not be ensured ($($_.Exception.Message)) - continuing." -ForegroundColor Yellow
    }
}
$McpWatcherScript = Join-Path $PSScriptRoot '..\..\tools\watch_zcode_mcp_sync.ps1'
$TaskbarWatcherScript = Join-Path $PSScriptRoot '..\..\tools\watch_zcode_taskbar.ps1'
$StartupFolder = [Environment]::GetFolderPath('Startup')
Write-Host ''
Write-Host 'Step 2e) Ensure resident watchers - MCP sync + taskbar identity'
if (Test-Path -LiteralPath $McpWatcherScript) {
    Ensure-ResidentWatcher -Name 'MCP sync watcher' -ScriptPath $McpWatcherScript `
        -MutexName 'ZcodeMcpSyncWatcher' -AutostartLnk (Join-Path $StartupFolder 'ZCode MCP sync watcher.lnk')
} else {
    Write-Host '[watchers] tools\watch_zcode_mcp_sync.ps1 not found - skipping.' -ForegroundColor Yellow
}
if (Test-Path -LiteralPath $TaskbarWatcherScript) {
    Ensure-ResidentWatcher -Name 'Taskbar identity watcher' -ScriptPath $TaskbarWatcherScript `
        -MutexName 'ZcodeTaskbarIdentityWatcher' -AutostartLnk (Join-Path $StartupFolder 'ZCode taskbar identity.lnk')
} else {
    Write-Host '[watchers] tools\watch_zcode_taskbar.ps1 not found - skipping.' -ForegroundColor Yellow
}

# 2f) Per-clone Task Manager identity (2026-11-11): ensure the ZCode-<Color>.exe
#     copy in the install dir is present and fresh, then launch THIS clone from
#     the copy. Task Manager renders background-process groups from the
#     executable IMAGE itself (embedded icon + VERSIONINFO FileDescription), so
#     every instance on the stock ZCode.exe renders as an identical stock
#     "ZCode (N)" row no matter what the taskbar/shortcut/window stack does.
#     The copy carries the clone's branding icon + "ZCode <Color>" name
#     (tools\patch_zcode_exe_identity.ps1 builds, verifies and drift-heals it;
#     the marker fast-check makes a fresh copy cost ~nothing per launch).
#     The Primary keeps the stock exe. Best-effort by contract: any failure
#     falls back to the stock exe with a loud warning - never blocks the launch.
$ExeIdentityTool = Join-Path $PSScriptRoot '..\..\tools\patch_zcode_exe_identity.ps1'
$LaunchExe = $ZCodeExe
$CloneExe = Join-Path (Split-Path -Parent $ZCodeExe) $cfg.ExeName
Write-Host ''
Write-Host 'Step 2f) Task Manager identity - per-color exe copy'
if (Test-Path -LiteralPath $ExeIdentityTool) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ExeIdentityTool -Target $Instance -InstallDir (Split-Path -Parent $ZCodeExe)
    if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $CloneExe)) {
        $LaunchExe = $CloneExe
        Write-Host "[launch] $($cfg.DisplayName) starts from $($cfg.ExeName) (colored Task Manager group)." -ForegroundColor Green
    } else {
        Write-Host "[launch] exe copy unavailable (tool exit $LASTEXITCODE) - starting from the stock ZCode.exe; Task Manager keeps the stock row." -ForegroundColor Yellow
    }
} else {
    Write-Host '[launch] tools\patch_zcode_exe_identity.ps1 not found - starting from the stock ZCode.exe.' -ForegroundColor Yellow
}

# 3) Launch the clone detached from THIS console.
# Why: ZCode.exe attaches to the parent console (AttachConsole) for its stdout
# logging. A plain Start-Process keeps this window as that console, so ZCode
# floods it with [pid:*] logs forever and closing the window risks killing
# ZCode with it. Routing through `cmd /c start ""` gives it an intermediate
# parent that exits immediately, leaving no console to hijack. Env vars are
# still inherited through the chain (powershell -> cmd -> ZCode).
$env:ZCODE_DATA_BASE_DIR = $CloneHome
$env:ZCODE_DESKTOP_USER_DATA_DIR = $CloneUserData
$env:ZCODE_DESKTOP_SESSION_DATA_DIR = $CloneSession
$env:ZCODE_DESKTOP_HOME_DIR = $CloneHome
$env:HOME = $CloneHome

# 3b) Per-clone branding (window/tray icon + separate taskbar button + in-app
# accent). Icons are seeded from the repo into <CloneHome>\branding so the
# instance stays self-contained even if the repo moves later.
$BrandingDir  = Join-Path $CloneHome 'branding'
$BrandingSeed = Join-Path $PSScriptRoot "..\..\tools\$($cfg.BrandingRepo)"
$brandingIcon = Join-Path $BrandingDir 'icon_windows.png'
$brandingTray = Join-Path $BrandingDir 'tray_icon.ico'
$seedIcon = Join-Path $BrandingSeed 'icon_windows.png'
$seedTray = Join-Path $BrandingSeed 'tray_icon.ico'
if (((-not (Test-Path -LiteralPath $brandingIcon)) -or (-not (Test-Path -LiteralPath $brandingTray))) -and
    ((Test-Path -LiteralPath $seedIcon)) -and (Test-Path -LiteralPath $seedTray)) {
    New-Item -ItemType Directory -Path $BrandingDir -Force | Out-Null
    try {
        Copy-Item -LiteralPath $seedIcon -Destination $BrandingDir -Force
        Copy-Item -LiteralPath $seedTray -Destination $BrandingDir -Force
        Write-Host "[branding] Seeded $($cfg.DisplayName) icons -> $($cfg.Home)\branding" -ForegroundColor Green
    } catch {
        # A failed icon seed must not abort the launch: the icon-gating block
        # below already degrades gracefully and the AUMID stays applied.
        Write-Host "[branding] Icon seed copy FAILED ($($_.Exception.Message)) - SEPARATE taskbar identity still applied." -ForegroundColor Yellow
    }
}
# AUMID suffix is UNCONDITIONAL: it is the clone's taskbar identity, not a
# cosmetic. Gating it on the branding files (as an earlier revision did) meant a
# missing icon file silently launched the clone under the Primary's AUMID -
# both windows merged into one taskbar button while data isolation still worked
# (different accounts, same button - the hardest state to diagnose).
$env:ZCODE_AUMID_SUFFIX = $cfg.AumidSuffix
# Accent + title name are unconditional too: the patched app only consumes them
# when ZCODE_ICON_DIR drives --zcode-blue=1, so an unpatched app ignores them.
$env:ZCODE_ACCENT_HEX = $cfg.AccentHex
$env:ZCODE_INSTANCE_NAME = $cfg.DisplayName
if ((Test-Path -LiteralPath $brandingIcon) -and (Test-Path -LiteralPath $brandingTray)) {
    $env:ZCODE_ICON_DIR = $BrandingDir
    Write-Host "[launch] ICON_DIR=$($env:ZCODE_ICON_DIR) AUMID_SUFFIX=$($env:ZCODE_AUMID_SUFFIX) ACCENT=$($env:ZCODE_ACCENT_HEX) TITLE=$($env:ZCODE_INSTANCE_NAME)"
} else {
    Write-Host "[branding] $($cfg.DisplayName) icons unavailable - launching with default icon but" -ForegroundColor Yellow
    Write-Host '           SEPARATE taskbar identity (AUMID_SUFFIX still applied).' -ForegroundColor Yellow
}
# The icon env vars only work after the one-time app.asar patch; warn when absent.
$AsarMarker = Join-Path (Split-Path -Parent $ZCodeExe) 'resources\zcode-icon-patch.marker.json'
if (-not (Test-Path -LiteralPath $AsarMarker)) {
    Write-Host '[branding] NOTE: installed app.asar is not patched yet.' -ForegroundColor Yellow
    Write-Host '        Close ZCode and run once: tools\patch_zcode_icon_override.ps1' -ForegroundColor Yellow
}

Write-Host "[launch] DATA_BASE_DIR=$($env:ZCODE_DATA_BASE_DIR)"
Write-Host "[launch] USER_DATA_DIR=$($env:ZCODE_DESKTOP_USER_DATA_DIR)"
Write-Host "[launch] SESSION_DIR=$($env:ZCODE_DESKTOP_SESSION_DATA_DIR)"

$beforeMains = @(Get-CimInstance Win32_Process -Filter $script:ZcodeFamilyWmiFilter -ErrorAction SilentlyContinue | Where-Object {
    # Empty CommandLine is a known WMI race on fresh mains: keep as candidate.
    Test-ZcodeMainCmdline ([string]$_.CommandLine)
} | Select-Object -ExpandProperty ProcessId)
$exeArgs = @('/c', 'start', '""', "`"$LaunchExe`"")
if ($LowRam) {
    $exeArgs += '--disable-gpu'
    Write-Host '[launch] -LowRam: --disable-gpu passed (saves the per-instance GPU process; software rendering).' -ForegroundColor Yellow
}
$null = Start-Process -FilePath "$env:ComSpec" -ArgumentList $exeArgs -WindowStyle Hidden
# Best-effort PID discovery: a fresh bare-exe main appears within seconds.
# Re-launch while already running just focuses the window and exits instead.
$newPid = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $nowMains = @(Get-CimInstance Win32_Process -Filter $script:ZcodeFamilyWmiFilter -ErrorAction SilentlyContinue | Where-Object {
            # (empty CommandLine = WMI race; keep as candidate)
            Test-ZcodeMainCmdline ([string]$_.CommandLine)
        } | Select-Object -ExpandProperty ProcessId)
    $diff = @($nowMains | Where-Object { $beforeMains -notcontains $_ })
    if ($diff.Count -gt 0) { $newPid = $diff[0]; break }
}
if ($newPid) { Write-Host "[launch] $($cfg.DisplayName) ZCode PID=$newPid. $($cfg.DisplayName)-branded window should now appear with its own taskbar button." }
else { Write-Host "[launch] Launched (already running: existing window focused). $($cfg.DisplayName) branding = this instance, unbranded = Primary." }
Write-Host '[verify] If the window is NOT brand-colored, the installed app.asar needs the one-time patch:'
Write-Host '        close ZCode, run tools\patch_zcode_icon_override.ps1, then relaunch.'

# 4) Stamp the taskbar identity onto the instance's main WINDOW.
# Why: the process-explicit app.setAppUserModelId (patched into app.asar) proved
# unreliable per-instance - verified 2026-09-24: Primary + Second merged into one
# taskbar button even with a correct env block (ZCODE_AUMID_SUFFIX=2 read back
# from the live process) and a correct patched expression, while Third/Fourth
# separated. The shell honors System.AppUserModel.ID on a window's property
# store with TOP precedence and re-groups live, so the launcher stamps it
# directly and verifies by read-back (never silent-success). The launcher must
# run at the same or higher integrity level as the clone (UIPI).
$wantAumid = "dev.zcode.app.$($cfg.AumidSuffix)"   # base in sync with install_zcode_second_shortcuts.ps1
# Add-Type guard: an in-session re-run (e.g. after Start-Process) must not
# throw "type already exists" - compile only when the type is not loaded.
if (-not ('ZcodeWindowAumid' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class ZcodeWindowAumid {
    [StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
        [FieldOffset(8)] public long longValue;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }
    [DllImport("shell32.dll")] public static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    // oleaut32 dropped this export in Win10 19041.7548 (2026-07 CU) - ole32 keeps it
    [DllImport("ole32.dll")] public static extern int PropVariantClear(ref PROPVARIANT pv);
    public static readonly PROPERTYKEY PKEY_AUMID = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    static Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    // Stamp + read back; returns what the store actually holds.
    public static string Stamp(IntPtr hwnd, string aumid) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        IntPtr pStr = Marshal.StringToCoTaskMemUni(aumid);
        try {
            PROPVARIANT pv = new PROPVARIANT();
            pv.vt = 31; // VT_LPWSTR
            pv.pointerValue = pStr;
            var key = PKEY_AUMID;
            store.SetValue(ref key, ref pv);
            store.Commit();
        } finally { Marshal.FreeCoTaskMem(pStr); }
        return Read(hwnd);
    }
    public static string Read(IntPtr hwnd) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        PROPVARIANT back;
        var key = PKEY_AUMID;
        store.GetValue(ref key, out back);
        // VT_LPWSTR is CoTaskMem-allocated by the property store: copy the
        // string out first, then free the variant, or the resident watcher
        // leaks on every 5 s read.
        string result;
        if (back.vt == 31) result = Marshal.PtrToStringUni(back.pointerValue);
        else if (back.vt == 0) result = "<EMPTY>";
        else result = "<readback vt=" + back.vt + ">";
        PropVariantClear(ref back);
        return result;
    }
}
"@
}
# Resolve the instance's main window: the v6 title "ZCode <Name>" is the source
# of truth - it survives splash->main window swaps and never matches the
# transient relauncher process that the single-instance focus path spawns.
# Title-resolve is the ONLY selector: the old fresh-PID fallback was removed
# (2026-11-15) - $newPid comes from a bare PID diff that adopts ANY new main
# (a sibling clone's, or the transient relauncher's), and AGENTS.md forbids
# stamping by the fresh PID alone.
$wantTitle = "ZCode $($cfg.DisplayName)"
function Resolve-InstanceWindow {
    $p = Get-Process -Name 'ZCode*' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq $wantTitle } |
        Select-Object -First 1
    return $p
}
# Up to 60s: a slow cold start keeps the v6 title hidden during the splash
# phase, and expiring here left identity to the process-level AUMID - the
# unreliable mechanism this window-level stamp exists to replace
# (verified 2026-09-24: green clone launched alone held <EMPTY> identity).
$targetProc = $null
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    $targetProc = Resolve-InstanceWindow
    if ($targetProc) { break }
}
if ($targetProc) {
    # Re-stamp whenever the main-window handle changes (splash -> real window
    # swap, transient relauncher dying, etc.); re-resolve every tick. 30s
    # covers slow splash -> window swaps on cold starts.
    $last = [Int64]0
    $got = ''
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $p = Resolve-InstanceWindow
        if (-not $p) { continue }
        $cur = [Int64]$p.MainWindowHandle
        if ($cur -ne 0 -and $cur -ne $last) {
            $last = $cur
            $got = [ZcodeWindowAumid]::Stamp($p.MainWindowHandle, $wantAumid)
            Write-Host "[taskbar] stamped pid $($p.Id) hwnd 0x$('{0:X}' -f $cur) -> read-back '$got'"
        }
    }
    # Final verify: read the identity from a FRESH window resolve - a stamp on a
    # window that has since exited must not count as success.
    $finalGot = ''
    for ($i = 0; $i -lt 6; $i++) {
        $final = Resolve-InstanceWindow
        if ($final) {
            $finalGot = [ZcodeWindowAumid]::Read($final.MainWindowHandle)
            if ($finalGot -eq $wantAumid) { break }
        }
        Start-Sleep -Milliseconds 500
    }
    if ($finalGot -eq $wantAumid) {
        Write-Host "[taskbar] window identity pinned: $wantAumid (pid $($final.Id))" -ForegroundColor Green
        # Kick the shell group once after pinning: the taskbar group may have
        # formed during the splash phase with a stale icon resolution, and a
        # plain stamp on a pre-grouped window does not rebuild it (verified
        # 2026-09-26: a green clone kept the Primary's icon until an Explorer
        # refresh). Brief .kick identity, then the final one, verified by
        # re-read; the resident watcher re-stamps if the window dies mid-kick.
        [void][ZcodeWindowAumid]::Stamp($final.MainWindowHandle, "$wantAumid.kick")
        Start-Sleep -Milliseconds 300
        $kickGot = [ZcodeWindowAumid]::Stamp($final.MainWindowHandle, $wantAumid)
        if ($kickGot -eq $wantAumid) {
            Write-Host "[taskbar] shell group rebuilt: $wantAumid (stale-icon guard)"
        } else {
            Write-Host "[taskbar] FAILED - post-kick read-back '$kickGot' != '$wantAumid'. Run the launcher at the same integrity level as the clone." -ForegroundColor Red
        }
    } else {
        Write-Host "[taskbar] FAILED - instance window holds '$finalGot', wanted '$wantAumid'. Run the launcher at the same integrity level as the clone." -ForegroundColor Red
    }
} else {
    Write-Host "[taskbar] no window found - identity left to the app's process-level AUMID." -ForegroundColor Yellow
}

Stop-LaunchLog
