#Requires -Version 5.1
<#
  watch_zcode_captcha.ps1
  --------------------------------------------------------------------
  Unattended watchdog for the ZCode Aliyun-CAPTCHA stall:
    "Captcha instance timed out after 10000ms" (+ follow-up
    "captcha verify failed" / 3007).

  Why this exists
  ---------------
  On free-tier plans the agent runtime periodically enters a CAPTCHA
  challenge whose Aliyun SDK instance never becomes interactive (no
  slider/popup appears) and times out after 10s. Worse, the failed
  instance sticks: every later request keeps timing out until the app
  restarts (upstream: zai-org/feedback#349, open). A human watching the
  screen cannot fix it either -- there is nothing to solve.

  What it does
  ------------
  Tails the agent runtime JSONL logs (~/.zcode/cli/log/zcode-*.jsonl)
  for two failure classes (captcha stall, capacity overload). On fresh
  captcha hits it restarts ZCode (which clears the stuck instance) and
  logs the event. If failures keep coming inside the escalation window
  it raises an audible alert and, when configured, a Telegram message --
  so you only step in for the stubborn cases.

  Two failure classes
  --------------------
  - Captcha stall ("Captcha instance timed out" / verify failed): restart
    the app to clear the stuck instance, then resume the failed sessions.
  - Capacity overload (terminal turn.failed with rate_limited / 529 /
    1305 / 3009 / model_rate_limited cause chain): NEVER restart (server-side, restart only destroys session
    state). Resume the dead sessions after -RateLimitResumeDelayMinutes
    (default 10). Per-attempt retry lines are ignored so the app's own
    retry loop plays out first.
  - If a restart kills the app but the relaunch fails, the next passes
    retry the relaunch (up to -RestartAttempts) while the kill is still
    inside -RelaunchWindowMinutes. Outside that window an absent app is
    treated as "user closed it" and left alone (-NoAutoRelaunch disables
    all of this).
  - After a restart, the failed sessions are resumed headlessly in place
    (`zcode --resume <sess> --prompt <msg>`), so the conversation
    continues without you (-NoAutoContinue disables; capped per session
    per hour via -MaxAutoContinuesPerHour). The CLI needs two provider-
    config files via environment; the script resolves them from the
    desktop's runtime cache automatically (newest zcode-builtin.json).

  It NEVER touches identity, auth, or config files. Monitoring is
  read-only; the only write actions are: its own state/log files,
  restarting the ZCode process, and (optionally) a Telegram API call.

  Usage
  -----
    # Foreground (test run, single pass, no restart):
    powershell -ExecutionPolicy Bypass -File tools\watch_zcode_captcha.ps1 -RunOnce -DryRun

    # Persistent watch (leave the window open):
    powershell -ExecutionPolicy Bypass -File tools\watch_zcode_captcha.ps1

    # With Telegram escalation (both required):
    powershell -ExecutionPolicy Bypass -File tools\watch_zcode_captcha.ps1 `
      -TelegramBotToken "123:ABC" -TelegramChatId "456"

    # ...or drop them in .envlocal at the repo root (git-ignored) and the
    # script picks them up automatically:
    #   TELEGRAM_BOT_TOKEN=123:ABC
    #   TELEGRAM_CHAT_ID=456
    # Explicit parameters win over .envlocal values.

  Logging
  -------
  watch.log under the state dir always gets every line (rotated at 5MB,
  one backup generation). The console shows milestones only
  (detections, restarts, escalations, failures, warnings) unless
  -Verbose (DryRun implies verbose). Relaunched ZCode output goes to
  per-run relaunch_*.log files instead of our console. Per-run
  resume/relaunch logs older than -LogRetentionDays (default 7, 0 to
  keep) are deleted automatically; state.json is never deleted.

  No admin rights needed (runs as the logged-in user). No Python needed.
  PowerShell 5.1 compatible (no ternary, no $Input variable).
#>

param(
    [int]$PollSeconds = 15,
    [int]$EscalateThreshold = 3,
    [int]$EscalateWindowMinutes = 10,
    [int]$NotifyCooldownMinutes = 15,
    [int]$RestartCooldownMinutes = 3,
    [int]$RelaunchWindowMinutes = 10,
    [int]$RestartAttempts = 3,
    [switch]$NoAutoRelaunch,
    [switch]$NoAutoContinue,
    [string]$ResumeMessage = "continue",
    [int]$ResumeDelaySeconds = 60,
    [int]$MaxAutoContinuesPerHour = 3,
    [int]$RateLimitResumeDelayMinutes = 10,
    [int]$RateLimitEscalateThreshold = 2,
    [switch]$Verbose,
    [int]$LogRetentionDays = 7,
    [string]$LogDir = "",
    [string]$StateDir = "",
    [string]$TelegramBotToken = "",
    [string]$TelegramChatId = "",
    [switch]$DryRun,
    [switch]$RunOnce
)

$ErrorActionPreference = "Stop"

# ---------- Resolve paths ----------
if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $env:USERPROFILE ".zcode\cli\log"
}
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    # LOCALAPPDATA is user-writable: no elevation needed to run the watch.
    $StateDir = Join-Path $env:LOCALAPPDATA "watch-zcode-captcha"
}
$ZCodeExe = Join-Path $env:LOCALAPPDATA "Programs\ZCode\ZCode.exe"
$StatePath = Join-Path $StateDir "state.json"
$WatchLogPath = Join-Path $StateDir "watch.log"

function Read-EnvLocalValue {
    # Reads one KEY from <repo-root>/.envlocal (KEY=VALUE lines, # comments,
    # optional surrounding quotes). Returns "" when missing/unreadable.
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ToolsDir
    )
    $envFile = Join-Path (Split-Path -Parent $ToolsDir) ".envlocal"
    if (-not (Test-Path -LiteralPath $envFile)) { return "" }
    foreach ($raw in (Get-Content -LiteralPath $envFile)) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { continue }
        $eq = $line.IndexOf("=")
        if ($eq -lt 1) { continue }
        if ($line.Substring(0, $eq).Trim() -ceq $Key) {
            return $line.Substring($eq + 1).Trim().Trim('"').Trim("'")
        }
    }
    return ""
}

# Explicit parameters win; .envlocal fills the gaps; empty stays disabled.
$ToolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($TelegramBotToken)) {
    $TelegramBotToken = Read-EnvLocalValue -Key "TELEGRAM_BOT_TOKEN" -ToolsDir $ToolsDir
}
if ([string]::IsNullOrWhiteSpace($TelegramChatId)) {
    $TelegramChatId = Read-EnvLocalValue -Key "TELEGRAM_CHAT_ID" -ToolsDir $ToolsDir
}

$SigTimeout = "Captcha instance timed out"
$SigVerifyFailed = "captcha verify failed"
$SigTurnFailedEvent = "turn.failed"
$SigTurnFailedMsg = "Turn failed"

# ---------- Helpers ----------
function Write-NoBomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    # No-BOM UTF-8 (repo convention): a BOM trips JSON parsers on re-read.
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Write-WatchLog {
    # The file always gets everything; the console gets milestones unless
    # -Verbose (DryRun forces full console so tests show the whole story).
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Milestone
    )
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $logFile = Get-Item -LiteralPath $WatchLogPath -ErrorAction SilentlyContinue
    if ($logFile -and ($logFile.Length -gt 5242880)) {
        # 5MB rotation: keep one backup generation.
        $rolled = $WatchLogPath + ".1"
        if (Test-Path -LiteralPath $rolled) {
            Remove-Item -LiteralPath $rolled -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $WatchLogPath -Destination $rolled -Force -ErrorAction SilentlyContinue
    }
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $WatchLogPath -Value $line -Encoding UTF8
    if ($Milestone -or $Verbose -or $DryRun) {
        Write-Host $line
    }
}

function Load-WatchState {
    if (Test-Path -LiteralPath $StatePath) {
        try {
            return Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        }
        catch {
            Write-WatchLog "WARN: state file unreadable, starting fresh" -Milestone
        }
    }
    return [pscustomobject]@{
        file             = ""
        offset           = 0
        hits             = @()
        rateHits         = @()
        lastNotify       = ""
        restarts         = 0
        lastKill         = ""
        lastAttempt      = ""
        relaunchAttempts = 0
        continues        = @()
        pendingSessions  = @()
    }
}

function Save-WatchState {
    param([Parameter(Mandatory = $true)]$State)
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    Write-NoBomText -Path $StatePath -Content ($State | ConvertTo-Json -Depth 6)
}

function Get-TodayLogFile {
    $name = "zcode-" + (Get-Date -Format "yyyy-MM-dd") + ".jsonl"
    $full = Join-Path $LogDir $name
    if (Test-Path -LiteralPath $full) { return $full }
    return $null
}

function Read-NewLogLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Offset
    )
    # Open with ReadWrite sharing: the agent holds the file for append.
    $stream = [System.IO.File]::Open($Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    try {
        if ($Offset -gt $stream.Length) { $Offset = 0 }  # truncated/rotated
        $null = $stream.Seek($Offset, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $reader.Close()
        $newOffset = (Get-Item -LiteralPath $Path).Length
        $lines = @($text -split "`r?`n" | Where-Object { $_ -ne "" })
        return @{ Lines = $lines; Offset = $newOffset }
    }
    finally {
        $stream.Close()
    }
}

function Send-TelegramAlert {
    # Returns "sent", "failed", or "disabled" (creds missing).
    param([Parameter(Mandatory = $true)][string]$Text)
    if ([string]::IsNullOrWhiteSpace($TelegramBotToken) -or
        [string]::IsNullOrWhiteSpace($TelegramChatId)) {
        return "disabled"
    }
    try {
        $uri = "https://api.telegram.org/bot{0}/sendMessage" -f $TelegramBotToken
        $body = @{ chat_id = $TelegramChatId; text = $Text }
        Invoke-RestMethod -Uri $uri -Method Post -Body $body -TimeoutSec 20 | Out-Null
        return "sent"
    }
    catch {
        Write-WatchLog ("WARN: Telegram send failed: " + $_.Exception.Message) -Milestone
        return "failed"
    }
}

function Invoke-AlertSound {
    # Three attention beeps (Console.Beep works in console + ISE hosts).
    try {
        for ($i = 0; $i -lt 3; $i++) {
            [Console]::Beep(880, 300)
            Start-Sleep -Milliseconds 200
        }
    }
    catch {
        Write-WatchLog "WARN: could not play alert sound"
    }
}

function Get-ZCodeProcesses {
    return @(Get-Process -Name "ZCode*" -ErrorAction SilentlyContinue)
}

function Stop-ZCodeProcesses {
    # Two-phase stop: graceful close, force kill, then a tree-kill hammer.
    # Returns $true when no ZCode process remains.
    $procs = Get-ZCodeProcesses
    if ($procs.Count -eq 0) { return $true }
    $pids = (($procs | ForEach-Object { $_.Id }) -join ",")
    Write-WatchLog ("stopping ZCode processes (pids: " + $pids + ")")
    foreach ($p in $procs) {
        try { $null = $p.CloseMainWindow() } catch { }
    }
    Start-Sleep -Seconds 5
    $procs = Get-ZCodeProcesses
    foreach ($p in $procs) {
        try { Stop-Process -InputObject $p -Force -ErrorAction SilentlyContinue } catch { }
    }
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        if ((Get-ZCodeProcesses).Count -eq 0) { return $true }
    }
    # Final hammer: tree kill (catches wedged children, e.g. crash handlers).
    try { & taskkill /F /T /IM ZCode.exe 2>$null | Out-Null } catch { }
    for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 2
        if ((Get-ZCodeProcesses).Count -eq 0) { return $true }
    }
    $left = ((Get-ZCodeProcesses | ForEach-Object { $_.Id }) -join ",")
    Write-WatchLog ("FAILED: ZCode processes would not exit (left pids: " + $left + ")") -Milestone
    return $false
}

function Start-ZCodeApp {
    # Launches ZCode (its own GUI window) with stdout/stderr redirected to
    # per-relaunch files, so the app's verbose Electron logs never flood our
    # console. Waits up to 60s for a process. Returns $true/$false.
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $ZCodeExe)) {
        Write-WatchLog ("FAILED: ZCode exe not found: " + $ZCodeExe) -Milestone
        return $false
    }
    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outLog = Join-Path $StateDir ("relaunch_" + $stamp + ".out.log")
    $errLog = Join-Path $StateDir ("relaunch_" + $stamp + ".err.log")
    try {
        Start-Process -FilePath $ZCodeExe -RedirectStandardOutput $outLog -RedirectStandardError $errLog -ErrorAction Stop
        Write-WatchLog ("relaunch output captured to: " + $outLog)
    }
    catch {
        Write-WatchLog ("FAILED: relaunch threw: " + $_.Exception.Message) -Milestone
        return $false
    }
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if ((Get-ZCodeProcesses).Count -gt 0) { return $true }
    }
    Write-WatchLog "FAILED: relaunch issued but no ZCode process appeared within 60s" -Milestone
    return $false
}

function Restart-ZCodeApp {
    # Returns "restarted", "skipped-not-running", or "failed".
    if ((Get-ZCodeProcesses).Count -eq 0) {
        Write-WatchLog "restart skipped: ZCode not running (left alone by design)"
        return "skipped-not-running"
    }
    if (-not (Stop-ZCodeProcesses)) { return "failed" }
    if (Start-ZCodeApp) {
        Write-WatchLog "ZCode restarted and process verified" -Milestone
        return "restarted"
    }
    return "failed"
}

function Invoke-LivenessCheck {
    # The app is gone but WE killed it recently (inside the relaunch window)
    # and still have attempts left: retry the relaunch instead of leaving it
    # dead. Outside the window the user probably closed it -> hands off.
    # Returns "restarted", "failed", "waiting" (cooldown), or "hands-off".
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][datetime]$Now
    )
    if ($NoAutoRelaunch) { return "hands-off" }
    $lastKill = $null
    if ($State.lastKill) {
        try { $lastKill = [datetime]$State.lastKill } catch { }
    }
    if ($null -eq $lastKill) {
        Write-WatchLog "liveness: ZCode not running, no recent watchdog kill on record - left alone"
        return "hands-off"
    }
    if (($Now - $lastKill).TotalMinutes -gt $RelaunchWindowMinutes) {
        Write-WatchLog "liveness: ZCode not running, last watchdog kill outside window - left alone"
        return "hands-off"
    }
    if ([int]$State.relaunchAttempts -ge $RestartAttempts) {
        return "hands-off"  # cap reached; the failure was already escalated
    }
    $lastAttempt = $null
    if ($State.lastAttempt) {
        try { $lastAttempt = [datetime]$State.lastAttempt } catch { }
    }
    if (($null -ne $lastAttempt) -and (($Now - $lastAttempt).TotalMinutes -lt $RestartCooldownMinutes)) {
        return "waiting"
    }
    $n = [int]$State.relaunchAttempts + 1
    Write-WatchLog ("liveness: relaunch attempt " + $n + " of " + $RestartAttempts)
    $State.lastAttempt = $Now.ToUniversalTime().ToString("o")
    if (Start-ZCodeApp) {
        $State.restarts++
        $State.relaunchAttempts = 0
        $State.lastRestart = $Now.ToUniversalTime().ToString("o")
        Write-WatchLog "liveness: ZCode is back up" -Milestone
        return "restarted"
    }
    $State.relaunchAttempts = $n
    return "failed"
}

function Test-NotifyDue {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][datetime]$Now
    )
    $lastNotify = $null
    if ($State.lastNotify) {
        try { $lastNotify = [datetime]$State.lastNotify } catch { }
    }
    return (($null -eq $lastNotify) -or (($Now - $lastNotify).TotalMinutes -ge $NotifyCooldownMinutes))
}

function Update-WatchTitle {
    # Proof-of-life in the window titlebar (no log spam). Guarded: some
    # hosts (jobs,ISE) have no settable console title.
    try {
        $Host.UI.RawUI.WindowTitle =
            "ZCode captcha watch | last check " + (Get-Date -Format "HH:mm:ss")
    }
    catch { }
}

function Resolve-ProviderConfig {
    # The headless CLI needs two provider-config files via environment
    # (the desktop Electron process prepares these itself; plain node gets
    # "Unable to locate CLI ZCode Built-in Provider Config" without them).
    # The builtin path embeds app-version/endpoint-hash segments, so resolve
    # the newest copy dynamically. Returns @{Builtin;Personal} or $null.
    $personal = Join-Path $env:USERPROFILE ".zcode\v2\provider_config.json"
    $root = Join-Path $env:USERPROFILE ".zcode\v2\runtime\provider"
    $builtin = Get-ChildItem -LiteralPath $root -Filter "zcode-builtin.json" -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ([string]::IsNullOrWhiteSpace($builtin) -or (-not (Test-Path -LiteralPath $builtin))) { return $null }
    if (-not (Test-Path -LiteralPath $personal)) { return $null }
    return @{ Builtin = $builtin; Personal = $personal }
}

function Test-ContinueAllowed {
    # Per-session hourly cap against runaway resume loops.
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][datetime]$Now
    )
    if ($NoAutoContinue) { return $false }
    $cut = $Now.AddHours(-1)
    $recent = 0
    foreach ($c in @($State.continues)) {
        try {
            $parts = ([string]$c).Split("|")
            if (($parts[0] -ceq $Session) -and ([datetime]$parts[1] -ge $cut)) {
                $recent++
            }
        }
        catch { }
    }
    return ($recent -lt $MaxAutoContinuesPerHour)
}

function Invoke-SessionContinue {
    # Fire-and-forget headless resume of the failed sessions: sends the
    # resume message as a NEW user message in the same session (the failed
    # turn itself is dead / retryable=false, so it cannot be retried).
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][datetime]$Now
    )
    if ($NoAutoContinue) {
        if (@($State.pendingSessions).Count -gt 0) {
            Write-WatchLog ("auto-continue disabled, dropping " + @($State.pendingSessions).Count + " pending session(s)")
        }
        $State.pendingSessions = @()
        return
    }
    if (@($State.pendingSessions).Count -eq 0) { return }
    $node = $null
    try { $node = (Get-Command node -ErrorAction Stop).Source } catch { }
    $cli = Join-Path (Split-Path -Parent $ZCodeExe) "resources\glm\zcode.cjs"
    if ([string]::IsNullOrWhiteSpace($node) -or (-not (Test-Path -LiteralPath $cli))) {
        Write-WatchLog "auto-continue skipped: node or zcode.cjs not found" -Milestone
        $State.pendingSessions = @()
        return
    }
    $prov = Resolve-ProviderConfig
    if ($null -eq $prov) {
        Write-WatchLog "auto-continue skipped: provider config files not found (retry on later passes)"
        return  # keep pending; the 2h stale-drop bounds retries
    }
    # Child processes inherit these: the exact env the CLI needs.
    $env:ZCODE_BUILTIN_PROVIDER_CONFIG_FILE = $prov.Builtin
    $env:ZCODE_PERSONAL_PROVIDER_CONFIG_FILE = $prov.Personal
    if ((Get-ZCodeProcesses).Count -gt 0 -and ($ResumeDelaySeconds -gt 0)) {
        Write-WatchLog ("auto-continue: waiting " + $ResumeDelaySeconds + "s for app to settle")
        Start-Sleep -Seconds $ResumeDelaySeconds
        if ((Get-ZCodeProcesses).Count -eq 0) {
            Write-WatchLog "auto-continue aborted: app died during settle wait" -Milestone
            return  # keep pending for the next successful start
        }
    }
    $cutoff = $Now.AddMinutes(-120)
    $fresh = @()
    foreach ($p in @($State.pendingSessions)) {
        $okAge = $true
        try { $okAge = ([datetime]$p.seen -ge $cutoff) } catch { }
        if ($okAge) { $fresh += $p }
        else { Write-WatchLog ("auto-continue: dropping stale session " + $p.session) }
    }
    $done = @()
    $keep = @()
    foreach ($p in $fresh) {
        if ($done -contains $p.session) { continue }
        $dueOk = $true
        try { $dueOk = ([datetime]$p.due -le $Now) } catch { }
        if (-not $dueOk) {
            Write-WatchLog ("auto-continue: resume for " + $p.session + " not due until " + $p.due + ", keeping")
            $keep += $p
            $done += $p.session
            continue
        }
        $done += $p.session
        if (-not (Test-ContinueAllowed -State $State -Session $p.session -Now $Now)) {
            Write-WatchLog ("auto-continue: hourly cap reached for " + $p.session + ", skipping (escalated)") -Milestone
            continue
        }
        $argList = @("`"$cli`"", "--resume", $p.session, "--prompt", $ResumeMessage, "--surface", "desktop")
        $stamp = $Now.ToString("yyyyMMdd_HHmmss")
        $outLog = Join-Path $StateDir ("resume_" + $stamp + ".out.log")
        $errLog = Join-Path $StateDir ("resume_" + $stamp + ".err.log")
        if ($DryRun) {
            Write-WatchLog ("DryRun: would resume " + $p.session + " via: node " + ($argList -join " "))
            Write-WatchLog ("DryRun: provider config builtin=" + $prov.Builtin)
        }
        else {
            $workDir = $ToolsDir
            if ($p.workspace -and (Test-Path -LiteralPath $p.workspace)) {
                $workDir = $p.workspace
            }
            try {
                $proc = Start-Process -FilePath $node -ArgumentList $argList -WorkingDirectory $workDir -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru -ErrorAction Stop
                Write-WatchLog ("auto-continue: resumed " + $p.session + " (pid " + $proc.Id + ", out: " + $outLog + ")") -Milestone
                $State.continues += ($p.session + "|" + $Now.ToUniversalTime().ToString("o"))
            }
            catch {
                Write-WatchLog ("auto-continue FAILED for " + $p.session + ": " + $_.Exception.Message) -Milestone
            }
        }
    }
    $State.pendingSessions = $keep
}

function Invoke-LogRetention {
    # Deletes our own per-run logs older than the retention window. Never
    # touches state.json, watch.log*, or anything else.
    if ($LogRetentionDays -le 0) { return }
    if (-not (Test-Path -LiteralPath $StateDir)) { return }
    $cut = (Get-Date).AddDays(-$LogRetentionDays)
    foreach ($pat in @("resume_*.out.log", "resume_*.err.log", "relaunch_*.out.log", "relaunch_*.err.log")) {
        Get-ChildItem -LiteralPath $StateDir -Filter $pat -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cut } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

function Get-FailedSessionEntry {
    # Extracts @{session,workspace} from a failure log line, or $null.
    param([Parameter(Mandatory = $true)][string]$Line)
    try {
        $o = $Line | ConvertFrom-Json
        if (-not $o.sessionId) { return $null }
        $ws = ""
        if ($o.context) {
            if ($o.context.workspacePath) { $ws = [string]$o.context.workspacePath }
            elseif ($o.context.workspaceKey) { $ws = [string]$o.context.workspaceKey }
        }
        if (($ws -eq "") -and $o.workspacePath) { $ws = [string]$o.workspacePath }
        return @{ session = [string]$o.sessionId; workspace = $ws }
    }
    catch { return $null }
}

function Test-RateLimitedTurn {
    # True only for the terminal turn.failed of a capacity-overload wave
    # (the app's own per-attempt retries already played out by then).
    param([Parameter(Mandatory = $true)][string]$Line)
    if (-not ($Line.Contains($SigTurnFailedEvent) -or $Line.Contains($SigTurnFailedMsg))) {
        return $false
    }
    try {
        $o = $Line | ConvertFrom-Json
        if ([string]$o.event -cne "turn.failed") { return $false }
        # Shape 1: flat context (provider 1305 / HTTP 529).
        $reason = ""
        $code = 0
        if ($o.context) {
            if ($o.context.reason) { $reason = [string]$o.context.reason }
            if ($o.context.statusCode) { $code = [int]$o.context.statusCode }
        }
        if (($reason -ceq "rate_limited") -or ($code -eq 529) -or ($Line.Contains("1305"))) {
            return $true
        }
        # Shape 2: nested error.cause chain (provider 3009 /
        # StartPlanBusyAutoRetryExhaustedError). The top-level code is a
        # useless UNKNOWN_ERROR, so the cause must be read instead.
        if ($o.error -and $o.error.cause) {
            $cause = $o.error.cause
            $ccode = ""
            $cname = ""
            if ($cause.code) { $ccode = [string]$cause.code }
            if ($cause.name) { $cname = [string]$cause.name }
            if (($ccode -ceq "model_rate_limited") -or ($cname -ceq "StartPlanBusyAutoRetryExhaustedError")) {
                return $true
            }
            if ($cause.context) {
                $creason = ""
                if ($cause.context.reason) { $creason = [string]$cause.context.reason }
                $pcode = ""
                if ($cause.context.providerCode) { $pcode = [string]$cause.context.providerCode }
                if (($creason -ceq "rate_limited") -or ($pcode -eq "1305") -or ($pcode -eq "3009")) {
                    return $true
                }
            }
        }
        return $false
    }
    catch { return $false }
}

# ---------- Single poll pass ----------
function Invoke-WatchPass {
    param([Parameter(Mandatory = $true)]$State)

    $now = Get-Date
    $restartResult = "none"

    Invoke-LogRetention

    # Liveness: app gone but recently killed by us -> retry relaunch.
    # (Never in DryRun: a dry run must not touch processes.)
    if (((Get-ZCodeProcesses).Count -eq 0) -and (-not $DryRun)) {
        $live = Invoke-LivenessCheck -State $State -Now $now
        if ($live -eq "restarted") {
            $restartResult = "restarted"
        }
        elseif ($live -eq "failed") {
            $restartResult = "failed"
            if (Test-NotifyDue -State $State -Now $now) {
                $msg = "ZCode is DOWN and auto-relaunch failed " + $State.relaunchAttempts + " time(s). Please start it manually."
                Write-WatchLog ("ESCALATE: " + $msg) -Milestone
                Invoke-AlertSound
                $tgStatus = Send-TelegramAlert -Text $msg
                Write-WatchLog ("Telegram escalation: " + $tgStatus) -Milestone
                $State.lastNotify = $now.ToUniversalTime().ToString("o")
            }
        }
    }

    $logFile = Get-TodayLogFile
    if ($null -eq $logFile) {
        Write-WatchLog ("no log file for today in " + $LogDir + " (agent idle?)")
        return $State
    }

    if ($State.file -ne $logFile) {
        # New day (or first run): never replay history, start at the tail.
        $State.file = $logFile
        $State.offset = (Get-Item -LiteralPath $logFile).Length
        Write-WatchLog ("tracking " + $logFile + " from tail (history skipped)")
        return $State
    }

    $tail = Read-NewLogLines -Path $logFile -Offset ([long]$State.offset)
    $State.offset = $tail.Offset

    $newHits = 0
    $newRateHits = 0
    $failedSessions = @()
    foreach ($line in $tail.Lines) {
        if ($line.Contains($SigTimeout) -or $line.Contains($SigVerifyFailed)) {
            $newHits++
            # Captcha stall: resume as soon as the app is back.
            $e = Get-FailedSessionEntry -Line $line
            if ($e) {
                $failedSessions += @{ session = $e.session; workspace = $e.workspace; due = $now.ToUniversalTime().ToString("o") }
            }
        }
        elseif (Test-RateLimitedTurn -Line $line) {
            # Capacity overload, terminal turn: NO restart (server-side),
            # resume after a backoff instead.
            $newRateHits++
            $e = Get-FailedSessionEntry -Line $line
            if ($e) {
                $failedSessions += @{ session = $e.session; workspace = $e.workspace; due = $now.AddMinutes($RateLimitResumeDelayMinutes).ToUniversalTime().ToString("o") }
            }
        }
    }
    if ($newRateHits -gt 0) {
        Write-WatchLog ("RATE-LIMITED {0} dead turn(s): no restart (server capacity), resume deferred {1} min" -f $newRateHits, $RateLimitResumeDelayMinutes) -Milestone
        $State.rateHits += $now.ToUniversalTime().ToString("o")
    }
    foreach ($s in $failedSessions) {
        $dup = @(@($State.pendingSessions) | Where-Object { $_.session -ceq $s.session })
        if ($dup.Count -eq 0) {
            $State.pendingSessions += [pscustomobject]@{
                session   = $s.session
                workspace = $s.workspace
                seen      = $now.ToUniversalTime().ToString("o")
                due       = $s.due
            }
            Write-WatchLog ("captured failed session for resume: " + $s.session + " (due " + $s.due + ")")
        }
    }

    # Deferred resumes must fire even on quiet passes (no new lines).
    $pendingDue = @(@($State.pendingSessions) | Where-Object {
        try { [datetime]$_.due -le $now } catch { $true }
    }).Count -gt 0

    if (($newHits -eq 0) -and ($newRateHits -eq 0) -and (-not $pendingDue)) {
        return $State
    }

    if ($newHits -gt 0) {
        Write-WatchLog ("DETECTED {0} new captcha-failure line(s)" -f $newHits) -Milestone
    }
    for ($i = 0; $i -lt $newHits; $i++) {
        $State.hits += $now.ToUniversalTime().ToString("o")
    }
    # Prune hits outside the escalation window.
    $cutoff = $now.AddMinutes(-$EscalateWindowMinutes)
    $State.hits = @($State.hits | Where-Object {
        try { [datetime]$_ -ge $cutoff } catch { $false }
    })

    # Captcha path only: restart the app. Rate-limit passes must NEVER
    # kill anything (server-side capacity problem).
    # ($restartResult may already hold a liveness outcome from above.)
    if ($newHits -gt 0) {
        if ($DryRun) {
            Write-WatchLog "DryRun: restart suppressed"
            $restartResult = "dry-run"
        }
        else {
        $lastRestart = $null
        if ($State.PSObject.Properties["lastRestart"] -and $State.lastRestart) {
            try { $lastRestart = [datetime]$State.lastRestart } catch { }
        }
        $restartDue = ($null -eq $lastRestart) -or
            (($now - $lastRestart).TotalMinutes -ge $RestartCooldownMinutes)
        if ($restartDue) {
            $restartResult = Restart-ZCodeApp
            if (($restartResult -eq "restarted") -or ($restartResult -eq "failed")) {
                # We killed the app (relaunch ok or not): own the recovery window.
                $State.lastKill = $now.ToUniversalTime().ToString("o")
                $State.lastAttempt = $State.lastKill
                $State.relaunchAttempts = 0
            }
            if ($restartResult -eq "restarted") {
                $State.restarts++
                $State | Add-Member -NotePropertyName "lastRestart" `
                    -NotePropertyValue $now.ToUniversalTime().ToString("o") -Force
            }
        }
        else {
            Write-WatchLog "restart on cooldown, counting toward escalation only"
            if ($restartResult -eq "none") { $restartResult = "cooldown" }
        }
    }
    }  # end: restart only on captcha passes

    # Resume trigger: fresh restart, headless-only case, dry-run preview,
    # a new rate-limit wave, or deferred sessions coming due on a quiet pass.
    # (Invoke-SessionContinue re-checks per-item due times internally.)
    if (($restartResult -eq "restarted") -or ($restartResult -eq "skipped-not-running") -or
        ($restartResult -eq "dry-run") -or ($newRateHits -gt 0) -or $pendingDue) {
        Invoke-SessionContinue -State $State -Now $now
    }

    # Escalation: threshold hits inside the window + notify cooldown elapsed.
    if ($State.hits.Count -ge $EscalateThreshold) {
        if (Test-NotifyDue -State $State -Now $now) {
            $msg = "ZCode captcha stall: {0} failures in {1} min (restart: {2}). Human check needed." -f `
                $State.hits.Count, $EscalateWindowMinutes, $restartResult
            Write-WatchLog ("ESCALATE: " + $msg) -Milestone
            Invoke-AlertSound
            $tgStatus = Send-TelegramAlert -Text $msg
            Write-WatchLog ("Telegram escalation: " + $tgStatus) -Milestone
            $State.lastNotify = $now.ToUniversalTime().ToString("o")
        }
    }

    # Rate-limit escalation (no restart is ever attempted for these).
    $rateCutoff = $now.AddMinutes(-$EscalateWindowMinutes)
    $State.rateHits = @(@($State.rateHits) | Where-Object {
        try { [datetime]$_ -ge $rateCutoff } catch { $false }
    })
    if ($State.rateHits.Count -ge $RateLimitEscalateThreshold) {
        if (Test-NotifyDue -State $State -Now $now) {
            $msg = "ZCode capacity overload (rate_limited): {0} dead turn(s) in {1} min, resume deferred {2} min. No restart (server-side)." -f `
                $State.rateHits.Count, $EscalateWindowMinutes, $RateLimitResumeDelayMinutes
            Write-WatchLog ("ESCALATE: " + $msg) -Milestone
            Invoke-AlertSound
            $tgStatus = Send-TelegramAlert -Text $msg
            Write-WatchLog ("Telegram escalation: " + $tgStatus) -Milestone
            $State.lastNotify = $now.ToUniversalTime().ToString("o")
        }
    }

    return $State
}

# ---------- Main ----------
Write-Host "=== ZCode captcha watchdog ===" -ForegroundColor Cyan
Write-Host "Leave this window OPEN (minimize it if you like). Closing it stops the watch." -ForegroundColor Yellow
Write-Host ("LogDir : " + $LogDir) -ForegroundColor Gray
Write-Host ("State  : " + $StatePath) -ForegroundColor Gray
if ([string]::IsNullOrWhiteSpace($TelegramBotToken) -or
    [string]::IsNullOrWhiteSpace($TelegramChatId)) {
    Write-Host "Telegram: disabled (set TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID in .envlocal)" -ForegroundColor Yellow
}
else {
    Write-Host "Telegram: escalation enabled" -ForegroundColor Gray
}
if ($NoAutoRelaunch) {
    Write-Host "AutoRelaunch: disabled (-NoAutoRelaunch)" -ForegroundColor Yellow
}
else {
    Write-Host ("AutoRelaunch: enabled (window " + $RelaunchWindowMinutes + "m, attempts " + $RestartAttempts + ")") -ForegroundColor Gray
}
if ($NoAutoContinue) {
    Write-Host "AutoContinue: disabled (-NoAutoContinue)" -ForegroundColor Yellow
}
else {
    Write-Host ("AutoContinue: enabled (msg='" + $ResumeMessage + "', cap " + $MaxAutoContinuesPerHour + "/h per session)") -ForegroundColor Gray
}
Write-Host ("RateLimit: dead turns resume deferred " + $RateLimitResumeDelayMinutes + "m, no restart (escalate at " + $RateLimitEscalateThreshold + ")") -ForegroundColor Gray
if ($DryRun) { Write-Host "Mode   : DRY-RUN (no restarts)" -ForegroundColor Yellow }
if ($Verbose -or $DryRun) {
    Write-Host "Console: verbose (everything)" -ForegroundColor Gray
}
else {
    Write-Host "Console: milestones only (-Verbose for full detail)" -ForegroundColor Gray
}

$state = Load-WatchState

# Repair: state files written by older versions lack the newer fields.
foreach ($kv in @{ lastKill = ""; lastAttempt = ""; relaunchAttempts = 0 }.GetEnumerator()) {    if (-not $state.PSObject.Properties[$kv.Key]) {
        $state | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value
    }
}
if (-not $state.PSObject.Properties["continues"]) {
    $state | Add-Member -NotePropertyName "continues" -NotePropertyValue @()
}
if (-not $state.PSObject.Properties["rateHits"]) {
    $state | Add-Member -NotePropertyName "rateHits" -NotePropertyValue @()
}
if (-not $state.PSObject.Properties["pendingSessions"]) {
    $state | Add-Member -NotePropertyName "pendingSessions" -NotePropertyValue @()
}
if ($null -eq $state.continues) { $state.continues = @() }
if ($null -eq $state.rateHits) { $state.rateHits = @() }
if ($null -eq $state.pendingSessions) { $state.pendingSessions = @() }

if ($RunOnce) {
    $state = Invoke-WatchPass -State $state
    Save-WatchState -State $state
    Update-WatchTitle
    Write-Host ("done. hits-in-window={0} restarts={1}" -f $state.hits.Count, $state.restarts) -ForegroundColor Gray
    exit 0
}

try {
    while ($true) {
        $state = Invoke-WatchPass -State $state
        Save-WatchState -State $state
        Update-WatchTitle
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    Save-WatchState -State $state
}
