#Requires -Version 5.1
<#
.SYNOPSIS
  Cross-instance chat refresh for ZCode: one-shot (menu [15]) or
  error-triggered watcher (menu [22]).

  All ZCode instances share ONE session store at
  %USERPROFILE%\.zcode\cli\db\db.sqlite -- the CLI resolves it via the real
  user profile and ignores the HOME override on Windows (verified 2026-09-23,
  see docs\ZCODE_CHAT_SYNC_WATCHER_PLAN.md). Only the sidebar index
  (.zcode\v2\tasks-index.sqlite) is per-instance, and the app-server seeds its
  index baseline at spawn with NO snapshot backfill afterwards. So a chat
  created (or failed) in one instance stays invisible to every other running
  instance until that instance's app-server restarts.

  One-shot mode (default -Target Second = menu [15]):
    1. finds chats present in the shared store but missing from the target's
       tasks-index,
    2. waits out any in-flight chat turn (multi-signal hot-activity guard:
       db commit recency + uncompleted assistant steps + running tools +
       app-server CPU sampling, up to ~90s, -Force bypasses),
    3. recycles the target's workspace app-server process(es) -- the
       process manager auto-respawns them in ~3s and sessions resume,
    4. verifies afterwards that the missing chats reached the index.

  Watch mode (-Watch, menu [22], best with -Target All):
    tails the agent runtime JSONL logs (~/.zcode/cli/log/zcode-*.jsonl) for
    terminal failure events:
      - captcha stall: "Captcha instance timed out" / "captcha verify failed"
      - quota / rate-limit exhaustion: terminal turn.failed with
        rate_limited / 529 / 1305 / 3009 / model_rate_limited cause chain
        (same signatures as tools\watch_zcode_captcha.ps1) or
        quota/insufficient/captcha wording
    On a fresh failure it refreshes every RUNNING instance. Instances that
    are not installed, not running, or have no workspace open are skipped --
    they seed their chat list automatically on next launch. If the
    hot-activity guard sees a live turn anywhere, the refresh is deferred
    and retried on later polls (never recycles mid-turn).

  The file name is historical (Second-only v1); -Target now covers all
  instances. Supersedes tools\test_live_inject.py (obsolete spike -- the
  clone's own db.sqlite copy is dead storage, nothing reads it).
#>
[CmdletBinding()]
param(
  [ValidateSet('Primary','Second','Third','Fourth','All')]
  [string]$Target = 'Second',
  [switch]$Watch,                     # continuous: refresh running instances on quota/captcha failures
  [int]$PollSeconds = 20,             # watch: log poll cadence
  [int]$CooldownSeconds = 300,        # watch: minimum seconds between refresh runs
  [int]$InitialLookbackSeconds = 300, # watch: also trigger on errors this old at startup
  [switch]$RunOnce,                   # watch: single scan + refresh pass, then exit (testing)
  [switch]$DryRun,                    # detect + report only, never kill
  [switch]$Force                      # bypass the hot-activity guard
)

$ErrorActionPreference = 'Stop'

$SharedDb    = Join-Path $env:USERPROFILE '.zcode\cli\db\db.sqlite'
$AgentLogDir = Join-Path $env:USERPROFILE '.zcode\cli\log'
$LogDir      = Join-Path $PSScriptRoot 'logs'
$LogFile     = Join-Path $LogDir 'refresh_zcode_second_chats.log'

# Window titles come from tools\patch_zcode_icon_override.ps1 (branding patch):
# the Primary keeps the plain "ZCode" title, clones carry their color.
$InstanceDefs = @(
  @{ Name = 'Primary'; HomeRel = '';                Title = 'ZCode';        Exclude = @('Blue', 'Yellow', 'Green') }
  @{ Name = 'Second';  HomeRel = 'ZCodeSecondHome'; Title = 'ZCode Blue';   Exclude = @() }
  @{ Name = 'Third';   HomeRel = 'ZCodeThirdHome';  Title = 'ZCode Yellow'; Exclude = @() }
  @{ Name = 'Fourth';  HomeRel = 'ZCodeFourthHome'; Title = 'ZCode Green';  Exclude = @() }
)

function Write-RunLog([string]$line) {
  if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Add-Content -Path $LogFile -Value "$stamp $line" -Encoding UTF8
}

function Stop-WithError([string]$msg) {
  Write-Host "[FAIL] $msg" -ForegroundColor Red
  Write-RunLog "FAIL $msg"
  exit 1
}

if (-not (Test-Path $SharedDb)) { Stop-WithError "shared session store not found: $SharedDb" }

# --- Python detection (sqlite access), per repo convention: Get-Command, never a hardcoded path ---
$Py = $null
foreach ($cand in @('python', 'python3')) {
  $c = Get-Command $cand -ErrorAction SilentlyContinue
  if ($c) { $Py = $c.Source; break }
}

# --- temp helper .py in $env:TEMP (never next to the databases) ---
$PyFile = Join-Path $env:TEMP 'zcode_chat_sync_check.py'
$PySrc = @'
import sqlite3, sys, time, json

def ro(p):
    return sqlite3.connect('file:' + p.replace('\\', '/') + '?mode=ro', uri=True, timeout=10)

mode = sys.argv[1]
if mode == 'missing':
    db = ro(sys.argv[2])
    rows = db.execute("SELECT id, title, time_updated FROM session "
                      "WHERE time_archived IS NULL "
                      "AND task_type IN ('interactive','fork','workflow_parent')").fetchall()
    db.close()
    tdb = ro(sys.argv[3])
    have = set(r[0] for r in tdb.execute('SELECT task_id FROM tasks'))
    tdb.close()
    miss = sorted((r for r in rows if r[0] not in have), key=lambda r: r[2] or 0, reverse=True)
    print('COUNT:%d' % len(miss))
    for r in miss:
        print('MISSING:%s|%s' % (r[0], (r[1] or '').replace('|', ' ')[:80]))
elif mode == 'hot':
    db = ro(sys.argv[2])
    now_ms = int(time.time() * 1000)
    # A: global commit activity (commits happen at step/tool boundaries)
    mx = 0
    for t in ('session', 'message', 'part'):
        v = db.execute('SELECT COALESCE(MAX(time_updated),0) FROM %s' % t).fetchone()[0]
        if v and v > mx:
            mx = v
    print('AGE_MS:%d' % (now_ms - mx))
    # B: youngest in-flight assistant step. The row is CREATED when a step
    # starts and data.time.completed is filled when it ends, so an
    # uncompleted recent row == a turn is streaming right now (covers long
    # "Thought" phases that produce no commits). Killed turns orphan such
    # rows, hence the hard 125s recency window.
    msg_age = -1
    rows = db.execute('SELECT time_created, data FROM message WHERE time_created > ? '
                      'ORDER BY time_created DESC LIMIT 40', (now_ms - 125000,)).fetchall()
    for created, data in rows:
        try:
            d = json.loads(data)
        except Exception:
            continue
        if d.get('role') != 'assistant':
            continue
        if not (d.get('time') or {}).get('completed'):
            a = now_ms - (created or 0)
            if msg_age < 0 or a < msg_age:
                msg_age = a
    print('INFLIGHT_MSG_AGE_MS:%d' % msg_age)
    # C: youngest running tool (row committed at tool START; covers long
    # tool executions with no other db writes). Orphans expire after 305s.
    tool_age = -1
    tool_name = ''
    rows = db.execute("SELECT tool_name, started_at FROM tool_usage "
                      "WHERE (completed_at IS NULL OR completed_at = 0) AND started_at > ? "
                      "ORDER BY started_at DESC LIMIT 5", (now_ms - 305000,)).fetchall()
    for name, started in rows:
        a = now_ms - (started or 0)
        if tool_age < 0 or a < tool_age:
            tool_age = a
            tool_name = name or ''
    print('INFLIGHT_TOOL_AGE_MS:%d' % tool_age)
    print('INFLIGHT_TOOL_NAME:%s' % tool_name.replace('|', ' ')[:40])
    db.close()
else:
    print('UNKNOWN-MODE')
    sys.exit(2)
'@
Set-Content -Path $PyFile -Value $PySrc -Encoding ASCII

if (-not $Py) { Stop-WithError 'Python not found on PATH (needed for sqlite access)' }

# --- per-instance helpers -----------------------------------------------------
function Get-TasksIndexPath([hashtable]$def) {
  $base = $env:USERPROFILE
  if ($def.HomeRel -ne '') { $base = Join-Path $base $def.HomeRel }
  return Join-Path $base '.zcode\v2\tasks-index.sqlite'
}

function Get-DescendantProcesses([int[]]$rootIds) {
  $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, CommandLine)
  $byParent = @{}
  foreach ($p in $all) {
    $key = [int]$p.ParentProcessId
    if (-not $byParent.ContainsKey($key)) { $byParent[$key] = New-Object System.Collections.ArrayList }
    [void]$byParent[$key].Add($p)
  }
  $result = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  foreach ($r in $rootIds) { $queue.Enqueue([int]$r) }
  $seen = @{}
  while ($queue.Count -gt 0) {
    $cur = [int]$queue.Dequeue()
    $kids = $byParent[$cur]
    if ($null -eq $kids) { continue }
    foreach ($k in $kids) {
      $kidId = [int]$k.ProcessId
      if ($seen.ContainsKey($kidId)) { continue }
      $seen[$kidId] = $true
      [void]$result.Add($k)
      $queue.Enqueue($kidId)
    }
  }
  return $result
}

function Get-InstanceState([hashtable]$def) {
  # Snapshot of one instance: installed? running? workspace open? index in sync?
  $st = @{ Def = $def; Status = 'ok'; ErrText = ''; Mains = @(); Servers = @()
           TasksIndex = (Get-TasksIndexPath $def); MissingCount = 0; MissingLines = @() }
  if (-not (Test-Path $st.TasksIndex)) { $st.Status = 'not-installed'; return $st }
  $mains = @(Get-Process -Name ZCode -ErrorAction SilentlyContinue | Where-Object {
      if ($_.MainWindowHandle -eq 0) { $false }
      else {
        $t = [string]$_.MainWindowTitle
        $ok = ($t -like ($def.Title + '*'))
        if ($ok) { foreach ($x in $def.Exclude) { if ($t -like ('*' + $x + '*')) { $ok = $false } } }
        $ok
      }
    })
  $st.Mains = $mains
  if ($mains.Count -eq 0) { $st.Status = 'not-running'; return $st }
  $desc = @(Get-DescendantProcesses ($mains | ForEach-Object { [int]$_.Id }))
  $st.Servers = @($desc | Where-Object { $_.CommandLine -like '*app-server*' })
  if ($st.Servers.Count -eq 0) { $st.Status = 'no-appserver'; return $st }
  $out = @(& $Py $PyFile 'missing' $SharedDb $st.TasksIndex 2>&1)
  $countLine = $out | Where-Object { $_ -like 'COUNT:*' } | Select-Object -First 1
  if (($LASTEXITCODE -ne 0) -or (-not $countLine)) {
    $st.Status = 'error'
    $st.ErrText = ($out | Select-Object -Last 2) -join ' '
    return $st
  }
  $st.MissingCount = [int]$countLine.Substring(6)
  $st.MissingLines = @($out | Where-Object { $_ -like 'MISSING:*' })
  if ($st.MissingCount -eq 0) { $st.Status = 'in-sync' }
  return $st
}

# --- hot-activity guard: never recycle while a turn is streaming anywhere -----
# The session store is shared by ALL instances, so a live turn in any window
# blocks every recycle. Four independent signals (ANY one hot = wait):
#   A) shared-store commit activity < 15s (session/message/part time_updated)
#   B) an assistant step started < 120s ago and not completed yet (the row is
#      created at step start, completed filled at step end -- covers long
#      "Thought" phases that produce NO db commits)
#   C) a tool call started < 300s ago and still running (orphans from killed
#      turns expire via the recency window)
#   D) CPU delta > 0.25s over a 3s sample on the app-server(s) we would kill
#      (SSE token streaming burns CPU with zero db writes)
# Idle requires TWO consecutive all-cold passes. Waits up to ~90s.
# Returns $true when idle (or -Force), $false on timeout (reason in $script:GuardWhy).
$script:GuardWhy = ''
function Wait-ForIdleGuard([array]$Servers) {
  $waited = 0
  $coldPasses = 0
  while ($true) {
    # signal D first: 3s CPU sample on the target app-server(s)
    $cpuBefore = @{}
    foreach ($s in $Servers) {
      $pr = Get-Process -Id ([int]$s.ProcessId) -ErrorAction SilentlyContinue
      if ($pr) { $cpuBefore[[int]$s.ProcessId] = $pr.CPU }
    }
    Start-Sleep -Seconds 3
    $cpuBusy = $false
    foreach ($pidKey in @($cpuBefore.Keys)) {
      $pr = Get-Process -Id $pidKey -ErrorAction SilentlyContinue
      if ($pr -and ($pr.CPU - $cpuBefore[$pidKey]) -gt 0.25) { $cpuBusy = $true }
    }
    # signals A-C from the shared store
    $hot = @(& $Py $PyFile 'hot' $SharedDb 2>&1)
    $reasons = New-Object System.Collections.Generic.List[string]
    foreach ($line in $hot) {
      if ($line -like 'AGE_MS:*') {
        $ageMs = [int64]$line.Substring(7)
        if ($ageMs -lt 15000) { $reasons.Add("db write $([math]::Round($ageMs / 1000))s ago") | Out-Null }
      } elseif ($line -like 'INFLIGHT_MSG_AGE_MS:*') {
        $msgAge = [int64]$line.Substring(20)
        if ($msgAge -ge 0 -and $msgAge -lt 120000) { $reasons.Add("assistant step started $([math]::Round($msgAge / 1000))s ago, not finished") | Out-Null }
      } elseif ($line -like 'INFLIGHT_TOOL_AGE_MS:*') {
        $toolAge = [int64]$line.Substring(21)
        if ($toolAge -ge 0 -and $toolAge -lt 300000) { $reasons.Add("tool still running (started $([math]::Round($toolAge / 1000))s ago)") | Out-Null }
      }
    }
    if ($cpuBusy) { $reasons.Add('app-server CPU active - streaming') | Out-Null }

    if ($reasons.Count -eq 0) {
      $coldPasses++
      if ($coldPasses -ge 2) {
        if ($waited -gt 0) { Write-Host "  chat idle on two consecutive checks -- proceeding after ~${waited}s wait" }
        return $true
      }
      Start-Sleep -Seconds 4
      $waited += 7
      continue
    }
    $coldPasses = 0
    $script:GuardWhy = ($reasons | Select-Object -First 3) -join '; '
    if ($Force) {
      Write-Host "  [FORCE] $script:GuardWhy -- bypassing hot-activity guard" -ForegroundColor Yellow
      return $true
    }
    if ($waited -ge 90) { return $false }
    Write-Host "  $script:GuardWhy -- waiting for the turn to settle (waited ~${waited}s)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 4
    $waited += 7
  }
}




# --- one refresh pass over the resolved targets -------------------------------
# Returns 'recycled' | 'nothing' | 'deferred'.
# -Strict (one-shot): a missing single target hard-fails like the original
# Second-only script did; watch mode skips and retries instead.
function Invoke-RefreshPass {
  param([string]$tgt, [switch]$Strict)

  $defs = @($InstanceDefs | Where-Object { ($tgt -eq 'All') -or ($_.Name -eq $tgt) })
  $strictSingle = ($Strict -and $defs.Count -eq 1)
  Write-Host '[1/3] Scanning instance state...'
  $work = @()
  $anyRunning = $false
  foreach ($def in $defs) {
    $st = Get-InstanceState $def
    $label = $def.Name + ' (' + $def.Title + ')'
    if ($st.Status -eq 'not-installed') {
      if ($strictSingle) { Stop-WithError "$label tasks-index not found: $($st.TasksIndex) -- launch that instance once first" }
      Write-Host "  ${label}: skipped - never launched on this machine"
      continue
    }
    if ($st.Status -eq 'not-running') {
      if ($strictSingle) {
        if ($def.Name -eq 'Primary') { Stop-WithError "no window titled `"$($def.Title)`" found -- launch the Primary ZCode first" }
        $anyZ = @(Get-Process -Name ZCode -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
        if ($anyZ.Count -eq 0) { Stop-WithError "no ZCode window found at all -- launch $($def.Title) via the menu first" }
        Stop-WithError "no window titled `"$($def.Title)`" found -- cannot tell instances apart (branding patch lost after an app update?). Re-run menu [13], then retry. Refusing to guess."
      }
      Write-Host "  ${label}: skipped - not running (it seeds its chat list on next launch)"
      continue
    }
    $anyRunning = $true
    if ($st.Status -eq 'error') {
      if ($strictSingle) { Stop-WithError "sqlite check failed for ${label}: $($st.ErrText)" }
      Write-Host "  ${label}: [FAIL] sqlite check failed: $($st.ErrText)" -ForegroundColor Red
      continue
    }
    if ($st.Status -eq 'no-appserver') {
      Write-Host "  ${label}: running, no workspace open - nothing to recycle"
      Write-Host '     (every app-server seeds from scratch at spawn, so the chats appear on next folder open)'
      continue
    }
    if ($st.Status -eq 'in-sync') {
      Write-Host "  ${label}: sidebar index already in sync"
      continue
    }
    Write-Host "  ${label}: $($st.MissingCount) chat(s) missing from its sidebar index" -ForegroundColor Yellow
    $st.MissingLines | Select-Object -First 3 | ForEach-Object { Write-Host ('    - ' + $_.Substring(8)) }
    $work += $st
  }

  if ($work.Count -eq 0) {
    if ($Strict -and (-not $anyRunning)) { Stop-WithError 'no target ZCode instance is running' }
    return 'nothing'
  }

  if ($DryRun) {
    foreach ($w in $work) {
      Write-Host "  $($w.Def.Name): [DRY-RUN] would recycle $($w.Servers.Count) app-server process(es); no action taken." -ForegroundColor Cyan
      Write-RunLog "DRYRUN target=$($w.Def.Name) missing=$($w.MissingCount) servers=$($w.Servers.Count)"
    }
    return 'nothing'
  }


  # hot-activity guard across every app-server we would kill
  $allServers = @($work | ForEach-Object { $_.Servers })
  Write-Host '[2/3] Hot-activity guard (never recycle mid-turn)...'
  if (-not (Wait-ForIdleGuard $allServers)) {
    if ($Strict) { Stop-WithError "chat still active after ~90s of waiting ($script:GuardWhy) -- a turn is streaming. Retry later, or re-run with -Force" }
    Write-Host "  deferred: $script:GuardWhy" -ForegroundColor Yellow
    return 'deferred'
  }

  Write-Host '[3/3] Recycling app-server(s) + verifying (auto-respawn expected)...'
  $recycledAny = $false
  foreach ($w in $work) {
    $label = $w.Def.Name + ' (' + $w.Def.Title + ')'
    # re-collect: PIDs may have changed if an app-server respawned during the wait
    $desc = @(Get-DescendantProcesses ($w.Mains | ForEach-Object { [int]$_.Id }))
    $servers = @($desc | Where-Object { $_.CommandLine -like '*app-server*' })
    if ($servers.Count -eq 0) {
      Write-Host "  ${label}: app-server went away while waiting - nothing to recycle (seeds on next folder open)" -ForegroundColor Green
      Write-RunLog "OK appserver-gone-after-wait target=$($w.Def.Name) missing=$($w.MissingCount)"
      continue
    }
    $oldIds = @($servers | ForEach-Object { [int]$_.ProcessId })
    foreach ($targetId in $oldIds) { Stop-Process -Id $targetId -Force -ErrorAction SilentlyContinue }
    Write-RunLog "RECYCLE target=$($w.Def.Name) killed=$($oldIds -join ',') missing-before=$($w.MissingCount)"
    $respawned = $false
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 1
      $descNow = @(Get-DescendantProcesses ($w.Mains | ForEach-Object { [int]$_.Id }))
      $fresh = @($descNow | Where-Object { $_.CommandLine -like '*app-server*' -and $oldIds -notcontains [int]$_.ProcessId })
      if ($fresh.Count -gt 0) { $respawned = $true; break }
    }
    if (-not $respawned) {
      if ($Strict) { Stop-WithError "$label app-server did not respawn within 30s -- check the window; a manual window reload may be needed" }
      Write-Host "  ${label}: [FAIL] app-server did not respawn within 30s" -ForegroundColor Red
      Write-RunLog "FAIL respawn target=$($w.Def.Name)"
      continue
    }
    Write-Host "  ${label}: app-server respawned after ~$($i + 1)s"
    # verify-after (never silent-success): missing chats must reach the index
    $synced = $false
    $c2 = ''
    for ($i = 0; $i -lt 22; $i++) {
      Start-Sleep -Seconds 2
      $out2 = @(& $Py $PyFile 'missing' $SharedDb $w.TasksIndex 2>&1)
      $c2 = $out2 | Where-Object { $_ -like 'COUNT:*' } | Select-Object -First 1
      if ($c2 -eq 'COUNT:0') { $synced = $true; break }
    }
    if (-not $synced) {
      $left = 'unknown'
      if ($c2 -like 'COUNT:*') { $left = $c2.Substring(6) }
      if ($Strict) { Stop-WithError "verify-after failed for ${label}: $left chat(s) still missing 45s after recycle" }
      Write-Host "  ${label}: [FAIL] verify-after: $left chat(s) still missing 45s after recycle" -ForegroundColor Red
      Write-RunLog "FAIL verify target=$($w.Def.Name) left=$left"
      continue
    }
    Write-Host "  ${label}: in sync - chat list updates by itself, no restart needed" -ForegroundColor Green
    Write-RunLog "OK synced target=$($w.Def.Name) missing-before=$($w.MissingCount)"
    $recycledAny = $true
  }
  if ($recycledAny) { return 'recycled' }
  return 'nothing'
}

# ---------- watch mode: error-triggered refresh across all running instances --

# Incremental JSONL tail (offset-based; handles day rollover + truncation).
$script:TailFile = $null
$script:TailOffset = [int64]0

function Get-NewAgentLogLines {
  $f = Get-ChildItem (Join-Path $AgentLogDir 'zcode-*.jsonl') -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { return @() }
  if ($script:TailFile -ne $f.FullName) { $script:TailFile = $f.FullName; $script:TailOffset = [int64]0 }
  if ($f.Length -lt $script:TailOffset) { $script:TailOffset = [int64]0 }  # rotated
  if ($f.Length -eq $script:TailOffset) { return @() }
  $fs = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
  try {
    [void]$fs.Seek($script:TailOffset, 'Begin')
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    $text = $sr.ReadToEnd()
    $script:TailOffset = $fs.Position
    $sr.Dispose()
  }
  finally { $fs.Dispose() }
  if ([string]::IsNullOrEmpty($text)) { return @() }
  $lines = $text -split "`n"
  if (-not $text.EndsWith("`n")) {
    # keep the partial last line for the next poll
    $partial = $lines[$lines.Count - 1]
    $script:TailOffset -= [System.Text.Encoding]::UTF8.GetByteCount($partial)
    if ($lines.Count -gt 1) { $lines = $lines[0..($lines.Count - 2)] } else { $lines = @() }
  }
  return @($lines | Where-Object { $_.Trim() -ne '' })
}

# Failure signatures mirror tools\watch_zcode_captcha.ps1 (proven in production).
function Get-LogLineErrorKind([string]$line) {
  if ($line.Contains('Captcha instance timed out') -or $line.Contains('captcha verify failed')) {
    return 'captcha-stall'
  }
  if (-not ($line.Contains('turn.failed') -or $line.Contains('Turn failed'))) { return $null }
  try { $o = $line | ConvertFrom-Json } catch { return $null }
  if ([string]$o.event -cne 'turn.failed') { return $null }
  # shape 1: flat context (provider 1305 / HTTP 529)
  $reason = ''
  $code = 0
  if ($o.context) {
    if ($o.context.reason) { $reason = [string]$o.context.reason }
    if ($o.context.statusCode) { $code = [int]$o.context.statusCode }
  }
  if (($reason -ceq 'rate_limited') -or ($code -eq 529) -or $line.Contains('1305')) { return 'quota/rate-limit' }
  # shape 2: nested error.cause chain (provider 3009 / StartPlanBusyAutoRetryExhaustedError)
  if ($o.error -and $o.error.cause) {
    $cause = $o.error.cause
    $ccode = ''
    $cname = ''
    if ($cause.code) { $ccode = [string]$cause.code }
    if ($cause.name) { $cname = [string]$cause.name }
    if (($ccode -ceq 'model_rate_limited') -or ($cname -ceq 'StartPlanBusyAutoRetryExhaustedError')) { return 'quota/rate-limit' }
    if ($cause.context) {
      $creason = ''
      $pcode = ''
      if ($cause.context.reason) { $creason = [string]$cause.context.reason }
      if ($cause.context.providerCode) { $pcode = [string]$cause.context.providerCode }
      if (($creason -ceq 'rate_limited') -or ($pcode -eq '1305') -or ($pcode -eq '3009')) { return 'quota/rate-limit' }
    }
  }
  # generic quota/captcha wording anywhere in the terminal failure line
  if ($line -match '(?i)quota|insufficient|captcha') { return 'quota/captcha' }
  return $null
}

function Get-LogLineStampUtc([string]$line) {
  try {
    $o = $line | ConvertFrom-Json
    if ($o.timestamp) {
      return [datetime]::Parse([string]$o.timestamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }
  } catch { }
  return $null
}

function Find-FreshErrors([datetime]$sinceUtc) {
  $found = @()
  foreach ($line in (Get-NewAgentLogLines)) {
    $kind = Get-LogLineErrorKind $line
    if (-not $kind) { continue }
    $stamp = Get-LogLineStampUtc $line
    if (($null -ne $stamp) -and ($stamp -le $sinceUtc)) { continue }
    $found += @{ Kind = $kind; Stamp = $stamp }
  }
  return $found
}


if ($Watch) {
  Write-Host "Watching $AgentLogDir for quota / captcha / rate-limit failures."
  Write-Host 'On a fresh failure the chats refresh in every RUNNING ZCode instance'
  Write-Host '(not-running instances seed themselves on next launch).'
  Write-Host "Poll ${PollSeconds}s, cooldown ${CooldownSeconds}s between refreshes. Leave this window open; Ctrl+C to stop."
  Write-RunLog "WATCH-START poll=$PollSeconds cooldown=$CooldownSeconds lookback=$InitialLookbackSeconds"
  $since = (Get-Date).ToUniversalTime().AddSeconds(-1 * $InitialLookbackSeconds)
  $pending = $false
  $lastRun = [datetime]::MinValue
  while ($true) {
    $errs = @(Find-FreshErrors $since)
    $since = (Get-Date).ToUniversalTime()
    if ($errs.Count -gt 0) {
      $pending = $true
      $kinds = @($errs | ForEach-Object { $_.Kind } | Select-Object -Unique)
      $now = Get-Date -Format 'HH:mm:ss'
      Write-Host "[$now] $($errs.Count) failure event(s): $($kinds -join ', ')" -ForegroundColor Yellow
      Write-RunLog "WATCH-DETECT count=$($errs.Count) kinds=$($kinds -join ',')"
    }
    elseif ($RunOnce) {
      Write-Host 'No fresh failure events in the lookback window.'
    }
    if ($pending) {
      $elapsed = ((Get-Date).ToUniversalTime() - $lastRun).TotalSeconds
      if ($elapsed -ge $CooldownSeconds) {
        $r = Invoke-RefreshPass 'All'
        if ($r -eq 'deferred') {
          Write-Host "  -> deferred: a turn is still streaming ($script:GuardWhy); retrying on later polls" -ForegroundColor Yellow
          Write-RunLog "WATCH-DEFERRED $script:GuardWhy"
        }
        else {
          $pending = $false
          $lastRun = (Get-Date).ToUniversalTime()
          if ($DryRun) { Write-Host '  -> dry-run only; no processes were touched' -ForegroundColor Cyan }
          elseif ($r -eq 'recycled') { Write-Host '  -> chats refreshed in the running instances' -ForegroundColor Green }
          else { Write-Host '  -> nothing to refresh (running instances already in sync)' }
        }
      }
    }
    if ($RunOnce) { break }
    Start-Sleep -Seconds $PollSeconds
  }
  exit 0
}

# ---------- one-shot mode (menu [15]: default -Target Second) ----------
[void](Invoke-RefreshPass $Target -Strict)
exit 0

