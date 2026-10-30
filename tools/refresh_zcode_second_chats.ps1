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
  [ValidateSet('Primary','Second','Third','Fourth','Fifth','Sixth','All')]
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

# Instance classification is PROCESS-MARKER-first (the 2026-09-24/26 taskbar
# lesson applies verbatim): a clone's window is titled plain "ZCode" during
# the splash phase, so title-only rules claim it as Primary. Markers = the
# roaming/home dir names the same launcher/watcher rules use (visible in the
# subtree's WMI command lines); a clone's v6 color title overrides a spurious
# Primary marker read. Markers and titles come from
# tools\patch_zcode_icon_override.ps1 (the Primary keeps the plain title).
$InstanceDefs = @(
  @{ Name = 'Primary'; HomeRel = '';                Title = 'ZCode';        Markers = @() }
  @{ Name = 'Second';  HomeRel = 'ZCodeSecondHome'; Title = 'ZCode Blue';   Markers = @('ZCode-Second', 'ZCodeSecondHome') }
  @{ Name = 'Third';   HomeRel = 'ZCodeThirdHome';  Title = 'ZCode Yellow'; Markers = @('ZCode-Third', 'ZCodeThirdHome') }
  @{ Name = 'Fourth';  HomeRel = 'ZCodeFourthHome'; Title = 'ZCode Green';  Markers = @('ZCode-Fourth', 'ZCodeFourthHome') }
  @{ Name = 'Fifth';   HomeRel = 'ZCodeFifthHome';  Title = 'ZCode Red';    Markers = @('ZCode-Fifth', 'ZCodeFifthHome') }
  @{ Name = 'Sixth';   HomeRel = 'ZCodeSixthHome';  Title = 'ZCode Orange'; Markers = @('ZCode-Sixth', 'ZCodeSixthHome') }
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

# --- Python detection (sqlite access): functional probe -- a candidate is
# accepted only when `--version` exits 0 reporting "Python 3", so the
# Microsoft Store stubs (exit 9009 + Store ad), stale Python 2, and profile
# aliases never false-positive. Candidates: PATH python/python3/py plus
# per-user installs that may be missing from an elevated PATH.
function Resolve-GhostPython {
  $candidates = @()
  foreach ($name in @('python', 'python3', 'py')) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c -and $c.Source) { $candidates += $c.Source }
  }
  $perUser = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python') `
    -Filter 'python.exe' -Recurse -Depth 1 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty FullName
  if ($perUser) { $candidates += $perUser }
  foreach ($exe in ($candidates | Select-Object -Unique)) {
    try { $v = & $exe --version 2>&1 } catch { continue }
    if ($LASTEXITCODE -eq 0 -and (($v -join ' ') -match '^Python\s+3')) { return $exe }
  }
  return $null
}
$Py = Resolve-GhostPython

# PS 5.1 decodes native stdout with [Console]::OutputEncoding -- force UTF-8
# so chat titles (any language) survive the chat-check pipe.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

if (-not $Py) { Stop-WithError 'Python 3 not found (needed for sqlite access). Install it: winget install Python.Python.3.12' }

# --- shared Python core (src/python/ghost sqlite_keys.chat_check); no per-run temp .py ---
$GhostCli = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\python\ghost_cli.py'
if (-not (Test-Path $GhostCli)) { Stop-WithError "GHOST Python core not found: $GhostCli" }

# Runs chat-check with stderr merged into stdout WITHOUT the PS 5.1
# NativeCommandError trap: under $ErrorActionPreference='Stop' any stderr line
# from the child becomes a terminating error that bypasses exactly the failure
# paths below. The inner scriptblock relaxes EAP for the redirect only.
function Invoke-ChatCheck {
  param([Parameter(Mandatory = $true)][string[]]$CheckArgs)
  @(& { $ErrorActionPreference = 'Continue'; & $Py $GhostCli @CheckArgs 2>&1 })
}

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

# One WMI snapshot per classification, keyed by pid, with parent->children
# links (same shape as the taskbar watcher's Get-ZcodeProcessMap).
function Get-ZcodeProcessMap {
  $map = @{}
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='ZCode.exe'" -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
  foreach ($p in $procs) {
    $map[[int]$p.ProcessId] = @{ Parent = [int]$p.ParentProcessId; Cmdline = [string]$p.CommandLine; Children = @() }
  }
  foreach ($p in $procs) {
    $par = [int]$p.ParentProcessId
    if ($map.ContainsKey($par)) { $map[$par].Children = @($map[$par].Children) + [int]$p.ProcessId }
  }
  return $map
}

# Classify a window's instance by walking its process tree to the root ZCode
# main and matching clone markers across the whole subtree's command lines.
# A clone main carries a bare exe command line; its children carry the clone
# home/roaming paths. Unmatched trees are Primary (the launcher's rule).
function Get-WindowMarkerInstance {
  param($ProcMap, [int]$ProcessId)
  if (-not $ProcMap -or -not $ProcMap.ContainsKey($ProcessId)) { return $null }
  $root = $ProcessId
  $climbed = @{}
  while ($ProcMap.ContainsKey($root)) {
    if ($climbed.ContainsKey($root)) { break }
    $climbed[$root] = $true
    $par = [int]$ProcMap[$root].Parent
    if (-not $ProcMap.ContainsKey($par)) { break }
    $root = $par
  }
  $seen = @{}
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue($root)
  while ($queue.Count -gt 0) {
    $cur = [int]$queue.Dequeue()
    if ($seen.ContainsKey($cur)) { continue }
    $seen[$cur] = $true
    $node = $ProcMap[$cur]
    if (-not $node) { continue }
    $cl = $node.Cmdline
    if ($cl) {
      foreach ($inst in $InstanceDefs) {
        foreach ($marker in $inst.Markers) {
          if ($cl -like ("*{0}*" -f $marker)) { return $inst }
        }
      }
    }
    foreach ($child in $node.Children) { $queue.Enqueue($child) }
  }
  return $InstanceDefs[0]
}

# Final classification: a clone's v6 color title is decisive when present
# (it overrides a spurious Primary marker read - WMI can miss a fresh clone's
# children for one snapshot); otherwise markers win over the splash-phase
# plain title; a plain "ZCode" title with an unmarked tree is the Primary.
# $null = ambiguous - the caller skips it loudly rather than guessing.
function Resolve-WindowInstance {
  param($ProcMap, $Win)
  $markerInst = Get-WindowMarkerInstance -ProcMap $ProcMap -ProcessId $Win.Id
  $t = [string]$Win.MainWindowTitle
  foreach ($cand in $InstanceDefs) {
    if ($cand.Name -ne 'Primary' -and $t -like ($cand.Title + '*')) { return $cand }
  }
  if ($markerInst -and $markerInst.Name -ne 'Primary') { return $markerInst }
  if ($t -like 'ZCode*' -and $markerInst -and $markerInst.Name -eq 'Primary') { return $markerInst }
  return $null
}

function Get-InstanceState([hashtable]$def) {
  # Snapshot of one instance: installed? running? workspace open? index in sync?
  $st = @{ Def = $def; Status = 'ok'; ErrText = ''; Mains = @(); Servers = @()
           TasksIndex = (Get-TasksIndexPath $def); MissingCount = 0; MissingLines = @() }
  if (-not (Test-Path $st.TasksIndex)) { $st.Status = 'not-installed'; return $st }
  $wins = @(Get-Process -Name ZCode -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
  if ($wins.Count -gt 0) {
    $procMap = Get-ZcodeProcessMap
    $mains = @($wins | Where-Object { (Resolve-WindowInstance -ProcMap $procMap -Win $_).Name -eq $def.Name })
  }
  else {
    $mains = @()
  }
  $st.Mains = $mains
  if ($mains.Count -eq 0) { $st.Status = 'not-running'; return $st }
  $desc = @(Get-DescendantProcesses ($mains | ForEach-Object { [int]$_.Id }))
  $st.Servers = @($desc | Where-Object { $_.CommandLine -like '*app-server*' })
  if ($st.Servers.Count -eq 0) { $st.Status = 'no-appserver'; return $st }
  $out = Invoke-ChatCheck @('chat-check', 'missing', $SharedDb, $st.TasksIndex)
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
    $hot = Invoke-ChatCheck @('chat-check', 'hot', $SharedDb)
    $reasons = New-Object System.Collections.Generic.List[string]
    if ($LASTEXITCODE -ne 0) {
      # Probe itself failed (locked db, schema drift): activity state unknown --
      # treat as hot so the guard waits it out instead of recycling mid-turn.
      $reasons.Add("chat-check hot probe failed (exit $LASTEXITCODE)") | Out-Null
    }
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
      # never silent-success: the missing count was > 0 and nothing was
      # recycled, so one re-check logs the residual instead of an
      # unconditional OK (fine when the index was seeded elsewhere; a WARN
      # when it is still stale -- those chats seed on the next folder open).
      $resid = -1
      $outR = Invoke-ChatCheck @('chat-check', 'missing', $SharedDb, $w.TasksIndex)
      $countR = $outR | Where-Object { $_ -like 'COUNT:*' } | Select-Object -First 1
      if ($countR -like 'COUNT:*') { $resid = [int]$countR.Substring(6) }
      if ($resid -eq 0) {
        Write-Host "  ${label}: re-check: nothing missing anymore (index was seeded elsewhere)" -ForegroundColor Green
        Write-RunLog "OK appserver-gone-after-wait target=$($w.Def.Name) missing-before=$($w.MissingCount) residual=0"
      } elseif ($resid -gt 0) {
        Write-Host "  ${label}: re-check: $resid chat(s) still missing - they seed on the next folder open" -ForegroundColor Yellow
        Write-RunLog "WARN appserver-gone-after-wait target=$($w.Def.Name) missing-before=$($w.MissingCount) residual=$resid"
      } else {
        Write-Host "  ${label}: re-check failed - residual missing count unknown" -ForegroundColor Yellow
        Write-RunLog "WARN appserver-gone-after-wait target=$($w.Def.Name) missing-before=$($w.MissingCount) residual=unknown"
      }
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
    # verify-after (never silent-success): the ORIGINAL missing chats must
    # reach the index. Requiring global COUNT:0 false-FAILs whenever any
    # other instance creates a chat during the ~45s window -- the shared
    # store is written by every instance, and this index can only gain rows
    # at app-server respawn (which already happened). Chats created after
    # the recycle are expected to stay missing here; only the original set
    # must be gone.
    $origIds = @($w.MissingLines | ForEach-Object { $_.Substring(8).Split('|')[0] })
    $synced = $false
    $c2 = ''
    $leftIds = @()
    for ($i = 0; $i -lt 22; $i++) {
      Start-Sleep -Seconds 2
      $out2 = Invoke-ChatCheck @('chat-check', 'missing', $SharedDb, $w.TasksIndex)
      $c2 = $out2 | Where-Object { $_ -like 'COUNT:*' } | Select-Object -First 1
      $nowMissing = @($out2 | Where-Object { $_ -like 'MISSING:*' })
      $leftIds = @($nowMissing | Where-Object { $origIds -contains $_.Substring(8).Split('|')[0] })
      if ($origIds.Count -gt 0) {
        if ($leftIds.Count -eq 0) { $synced = $true; break }
      } elseif ($c2 -eq 'COUNT:0') {
        # defensive: the initial check gave no MISSING lines to match against
        $synced = $true; break
      }
    }
    if (-not $synced) {
      if ($leftIds.Count -gt 0) {
        $left = ($leftIds | ForEach-Object { $_.Substring(8).Split('|')[0] }) -join ','
      } elseif ($c2 -like 'COUNT:*') {
        $left = $c2.Substring(6)
      } else {
        $left = 'unknown'
      }
      if ($Strict) { Stop-WithError "verify-after failed for ${label}: still missing 45s after recycle: $left" }
      Write-Host "  ${label}: [FAIL] verify-after: still missing 45s after recycle: $left" -ForegroundColor Red
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
# Returns @{ Lines = <complete lines>; FromOffsetZero = <bool> } -- the flag
# marks a batch read from byte 0 (watch start, file switch, truncation) whose
# lines' ages are unknown; Find-FreshErrors uses it to bound the unstamped
# fallback. Consumption mirrors the proven watchdog pattern
# (tools\watch_zcode_captcha.ps1 Read-NewLogLines): byte-buffered read, and
# only up to the LAST complete newline BYTE is consumed -- a trailing partial
# line (possibly cut mid multi-byte char) stays unconsumed and is re-read
# complete on the next poll, so the offset can never drift the way a decoded
# char-count rewind does (U+FFFD replaces the cut sequence).
$script:TailFile = $null
$script:TailOffset = [int64]0

function Get-NewAgentLogLines {
  $f = Get-ChildItem (Join-Path $AgentLogDir 'zcode-*.jsonl') -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $f) { return @{ Lines = @(); FromOffsetZero = $false } }
  if ($script:TailFile -ne $f.FullName) { $script:TailFile = $f.FullName; $script:TailOffset = [int64]0 }
  if ($f.Length -lt $script:TailOffset) { $script:TailOffset = [int64]0 }  # rotated
  if ($f.Length -eq $script:TailOffset) { return @{ Lines = @(); FromOffsetZero = $false } }
  $fromZero = ($script:TailOffset -eq [int64]0)
  $stream = [System.IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite')
  try {
    $start = $script:TailOffset
    if ($start -gt $stream.Length) { $start = [int64]0; $script:TailOffset = [int64]0; $fromZero = $true }  # truncated
    $length = [int]($stream.Length - $start)
    if ($length -le 0) { return @{ Lines = @(); FromOffsetZero = $fromZero } }
    $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $length
    $read = $stream.Read($buf, 0, $length)
    if ($read -le 0) { return @{ Lines = @(); FromOffsetZero = $fromZero } }
    if ($start -eq 0 -and $read -ge 3 -and $buf[0] -eq 239 -and $buf[1] -eq 187 -and $buf[2] -eq 191) {
      # UTF-8 BOM: skip it so the first line stays parseable JSON.
      $start = 3
      $read = $read - 3
      $tail = New-Object byte[] $read
      [Array]::Copy($buf, 3, $tail, 0, $read)
      $buf = $tail
    }
    $lastNl = -1
    for ($i = $read - 1; $i -ge 0; $i--) {
      if ($buf[$i] -eq 10) { $lastNl = $i; break }
    }
    if ($lastNl -lt 0) { return @{ Lines = @(); FromOffsetZero = $fromZero } }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $lastNl + 1)
    $script:TailOffset = $start + $lastNl + 1
  }
  finally { $stream.Dispose() }
  $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
  return @{ Lines = $lines; FromOffsetZero = $fromZero }
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

# Freshness rule: a matched failure line counts only when it is provably
# newer than $sinceUtc. The agent JSONL carries a top-level ISO-8601
# `timestamp` field (read-only probe of a live ~/.zcode/cli/log record,
# 2026-10-24), so stamped lines are the normal path. When a stamp is missing
# or unparseable, the line's age is unknown -- treat it as fresh ONLY within
# a bounded window, mirroring the watchdog's no-timestamp design:
#   - incremental poll batch: the line arrived within the last poll interval
#     (bounded by the cadence itself) -> fresh;
#   - batch read from byte 0 (watch start / file switch / truncation): the
#     whole file is in view and no line can be aged -> NOT fresh. The old
#     behavior treated every unstamped line as fresh, so a day-old failure
#     fired a full All-refresh at every watch start. Skip + log loudly; a
#     RECURRING failure writes new lines that arrive via incremental polls.
function Find-FreshErrors([datetime]$sinceUtc) {
  $found = @()
  $batch = Get-NewAgentLogLines
  $unstamped = 0
  $unstampedKinds = @()
  foreach ($line in $batch.Lines) {
    $kind = Get-LogLineErrorKind $line
    if (-not $kind) { continue }
    $stamp = Get-LogLineStampUtc $line
    if (($null -ne $stamp) -and ($stamp -le $sinceUtc)) { continue }
    if ($null -eq $stamp -and $batch.FromOffsetZero) {
      $unstamped++
      if ($unstampedKinds -notcontains $kind) { $unstampedKinds += $kind }
      continue
    }
    $found += @{ Kind = $kind; Stamp = $stamp }
  }
  if ($unstamped -gt 0) {
    Write-Host ("  [WATCH-UNSTAMPED] {0} failure line(s) in a whole-file (byte-0) batch have no parseable timestamp - skipped so a stale event cannot fire the refresh (kinds: {1})." -f $unstamped, ($unstampedKinds -join ', ')) -ForegroundColor Yellow
    Write-RunLog ("WATCH-UNSTAMPED count={0} kinds={1}" -f $unstamped, ($unstampedKinds -join ','))
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
        # Stamp EVERY attempt, deferred included: $lastRun was previously
        # only stamped on a completed run, so each retry fired on the very
        # next poll and the watcher lived inside the ~90s hot-activity guard
        # instead of honoring -CooldownSeconds (anti-thrash, plan doc section 4).
        $lastRun = (Get-Date).ToUniversalTime()
        if ($r -eq 'deferred') {
          Write-Host "  -> deferred: a turn is still streaming ($script:GuardWhy); retrying after the cooldown" -ForegroundColor Yellow
          Write-RunLog "WATCH-DEFERRED $script:GuardWhy"
        }
        else {
          $pending = $false
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

