#Requires -Version 5.1
<#
.SYNOPSIS
  Resident watcher: whenever the Primary ZCode MCP config changes
  (~\.zcode\cli\config.json), immediately merge it into every clone's own
  user-scope config - INCLUDING RUNNING instances.

.WHY THIS EXISTS (verified 2026-10-27)
  Every clone resolves its OWN <CloneHome>\.zcode\cli\config.json, so MCP
  servers added on the Primary never reach the clones and the seed copies
  drift. The old belief that "a live app may rewrite its config on exit" is
  FALSE: app.asar code + all six instances' logs show the app holds no
  handle on config.json, never rewrites it on exit (its own writes are
  event-driven, atomic tmp+rename), and reads mcp.servers at every
  app-server spawn - one per NEW session (6-41 bootstraps/day/instance).
  So a config write under a running instance is safe, and the synced
  definitions land on the instance's next chat without a restart.

.HOW
  The watcher writes NOTHING itself: every change triggers
  tools\sync_zcode_assets.ps1 -McpOnly (backup + atomic no-BOM write +
  deep-compare verify-after + JSONL audit live there), invoked as a child
  process. The Primary config is only ever READ (stat + parse-guard; a
  torn/invalid file skips the pass, never syncs).

  - Sync pass: first pass on start converges the drift; afterwards only on
    Primary signature change (mtime+size, debounced ~1s); a deep re-verify
    runs every 60 passes (~5 min at the default interval).
  - -ApplyLive (opt-in; GHOST.bat ZCode [26] uses it one-shot): after a
    sync, recycle the app-server(s) of every RUNNING target instance so the
    new definitions load immediately. Same mechanics as
    refresh_zcode_second_chats.ps1: idle-guarded (never mid-turn, never
    -Force), kill app-server children, the app's process manager
    auto-respawns ~3s and re-reads config at spawn.

.Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_zcode_mcp_sync.ps1
        [-RunOnce] [-DryRun] [-IntervalSeconds 5] [-ApplyLive]
        [-Target Second|Third|Fourth|Fifth|Sixth|All]
        [-InstallAutostart | -RemoveAutostart]

  GHOST.bat ZCode submenu [25] (resident) and [26] (one-shot sync + live
  apply). Log: %LOCALAPPDATA%\watch-zcode-mcp-sync\mcp-sync.log

.Notes
  - Single instance: named mutex ZcodeMcpSyncWatcher + a startup process
    scan that catches stale pre-mutex copies (same pattern as the taskbar
    watcher). -RunOnce one-shots bypass the guard by design.
  - Per-clone on/off toggles stay clone-local (the merge invariant); the
    Primary's definitions win; clone-only servers are never removed.
  - No admin needed. Never elevated on purpose.
#>
[CmdletBinding()]
param(
    [switch]$RunOnce,
    [switch]$DryRun,
    [int]$IntervalSeconds = 5,
    [switch]$ApplyLive,
    [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
    [string]$Target = 'All',
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'watch-zcode-mcp-sync\mcp-sync.log'),
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart
)

$ErrorActionPreference = 'Stop'

$UserProfile   = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$PrimaryConfig = Join-Path $UserProfile '.zcode\cli\config.json'
$SyncScript    = Join-Path $PSScriptRoot 'sync_zcode_assets.ps1'
$GhostCli      = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\python\ghost_cli.py'
$SharedDb      = Join-Path $UserProfile '.zcode\cli\db\db.sqlite'
$PsExe         = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Full six-instance table (Primary included for -ApplyLive classification;
# the sync child only ever targets the five clones). Markers = home/roaming
# dir names in the subtree command lines - the launcher/watcher rule.
$InstanceDefs = @(
    @{ Name = 'Primary'; Title = 'ZCode';        Markers = @() }
    @{ Name = 'Second';  Title = 'ZCode Blue';   Markers = @('ZCode-Second', 'ZCodeSecondHome') }
    @{ Name = 'Third';   Title = 'ZCode Yellow'; Markers = @('ZCode-Third',  'ZCodeThirdHome') }
    @{ Name = 'Fourth';  Title = 'ZCode Green';  Markers = @('ZCode-Fourth', 'ZCodeFourthHome') }
    @{ Name = 'Fifth';   Title = 'ZCode Red';    Markers = @('ZCode-Fifth',  'ZCodeFifthHome') }
    @{ Name = 'Sixth';   Title = 'ZCode Orange'; Markers = @('ZCode-Sixth',  'ZCodeSixthHome') }
)

function Write-WatchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length -gt 5MB)) {
            $bak = "$LogFile.1"
            if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
            Move-Item -LiteralPath $LogFile -Destination $bak -Force
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        # Log writes must never unwind the resident loop.
        Write-Host "[LOG-FAIL] $line" -ForegroundColor Yellow
    }
    # Console is milestone-gated: the file always gets everything.
    if ($Level -eq 'FAIL') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'SYNC') { Write-Host $line -ForegroundColor Cyan }
    elseif ($Level -eq 'CHILD') { } # child detail: file only, unless FAIL
    else { Write-Host $line }
}

# --- Python probe + chat-check (idle guard signal A-C; fail-safe when absent)
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

$script:Py = Resolve-GhostPython
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Invoke-ChatCheck {
    param([Parameter(Mandatory = $true)][string[]]$CheckArgs)
    # stderr merged WITHOUT the PS 5.1 NativeCommandError trap (see
    # refresh_zcode_second_chats.ps1 Invoke-ChatCheck).
    @(& { $ErrorActionPreference = 'Continue'; & $script:Py $GhostCli @CheckArgs 2>&1 })
}

# --- process helpers (verbatim mechanics from refresh_zcode_second_chats.ps1)
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

function Get-LiveInstanceState([hashtable]$def) {
    # Snapshot for -ApplyLive: is this instance running with an app-server?
    $st = @{ Status = 'not-running'; Mains = @(); Servers = @() }
    $wins = @(Get-Process -Name ZCode -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($wins.Count -eq 0) { return $st }
    $procMap = Get-ZcodeProcessMap
    $mains = @($wins | Where-Object { (Resolve-WindowInstance -ProcMap $procMap -Win $_).Name -eq $def.Name })
    if ($mains.Count -eq 0) { return $st }
    $desc = @(Get-DescendantProcesses ($mains | ForEach-Object { [int]$_.Id }))
    $servers = @($desc | Where-Object { $_.CommandLine -like '*app-server*' })
    if ($servers.Count -eq 0) { $st.Status = 'no-appserver'; return $st }
    $st.Mains = $mains
    $st.Servers = $servers
    $st.Status = 'recyclable'
    return $st
}

# --- hot-activity guard (signals A-D; idle needs two consecutive cold passes;
# waives nothing - there is deliberately no -Force on the automated path)
$script:GuardWhy = ''
function Wait-ForIdleGuard([array]$Servers) {
    if (-not $script:Py) { $script:GuardWhy = 'Python 3 not found - db signals unknown (treated hot)' }
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
        $reasons = New-Object System.Collections.Generic.List[string]
        if (-not $script:Py) {
            $reasons.Add($script:GuardWhy) | Out-Null
        } else {
            $hot = Invoke-ChatCheck @('chat-check', 'hot', $SharedDb)
            if ($LASTEXITCODE -ne 0) {
                # Probe failed (locked db, schema drift): activity state
                # unknown - treat as hot so the guard waits it out.
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
        }
        if ($cpuBusy) { $reasons.Add('app-server CPU active - streaming') | Out-Null }

        if ($reasons.Count -eq 0) {
            $coldPasses++
            if ($coldPasses -ge 2) {
                if ($waited -gt 0) { Write-WatchLog "chat idle on two consecutive checks - proceeding after ~${waited}s wait" }
                return $true
            }
            Start-Sleep -Seconds 4
            $waited += 7
            continue
        }
        $coldPasses = 0
        $script:GuardWhy = ($reasons | Select-Object -First 3) -join '; '
        if ($waited -ge 90) { return $false }
        Write-WatchLog "live-apply waiting for the turn to settle (waited ~${waited}s): $script:GuardWhy" 'WARN'
        Start-Sleep -Seconds 4
        $waited += 7
    }
}

# --- sync child (the ONLY writer: sync_zcode_assets.ps1 -McpOnly)
# Returns 'changed' | 'insync' | 'failed'.
function Invoke-SyncChild {
    if (-not (Test-Path -LiteralPath $SyncScript)) {
        Write-WatchLog "sync script missing: $SyncScript" 'FAIL'
        return 'failed'
    }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $SyncScript, '-Target', $Target, '-McpOnly')
    if ($DryRun) { $childArgs += '-DryRun' }
    $out = ''
    try { $out = & $PsExe @childArgs 2>&1 | Out-String } catch {
        Write-WatchLog ("sync child threw: {0}" -f $_.Exception.Message) 'FAIL'
        return 'failed'
    }
    $code = $LASTEXITCODE
    foreach ($line in ($out -split "`r?`n")) {
        $t = $line.Trim()
        if ($t) { Write-WatchLog ('child| ' + $t) 'CHILD' }
    }
    if (($code -ne 0) -or ($out -match 'FAILED')) {
        Write-WatchLog ("sync child FAILED (exit {0}) - see child| lines in {1}" -f $code, $LogFile) 'FAIL'
        return 'failed'
    }
    if ($out -match 'synced \+ verified') {
        Write-WatchLog 'sync child OK - definitions merged + verified' 'SYNC'
        return 'changed'
    }
    Write-WatchLog 'sync child OK - all clones already in sync'
    return 'insync'
}

# --- live apply: recycle app-server(s) of running targets so the freshly
# synced mcp.servers load NOW (opt-in; menu one-shot or -ApplyLive resident)
function Invoke-ApplyLivePass {
    if ($DryRun) { Write-WatchLog '[DRY] would recycle app-server(s) of running target instances (idle-guarded).' 'WARN'; return }
    $defs = @($InstanceDefs | Where-Object { ($Target -eq 'All') -or ($_.Name -eq $Target) })
    foreach ($def in $defs) {
        try {
            $st = Get-LiveInstanceState $def
            if ($st.Status -eq 'not-running') {
                Write-WatchLog ("live-apply {0}: not running - config applies on next launch." -f $def.Name)
                continue
            }
            if ($st.Status -eq 'no-appserver') {
                Write-WatchLog ("live-apply {0}: running, no workspace open - picks up at next spawn." -f $def.Name)
                continue
            }
            if (-not (Wait-ForIdleGuard $st.Servers)) {
                Write-WatchLog ("live-apply {0}: deferred - chat still active after ~90s ({1})." -f $def.Name, $script:GuardWhy) 'WARN'
                continue
            }
            # re-collect: PIDs may have changed during the guard wait
            $desc = @(Get-DescendantProcesses ($st.Mains | ForEach-Object { [int]$_.Id }))
            $servers = @($desc | Where-Object { $_.CommandLine -like '*app-server*' })
            if ($servers.Count -eq 0) {
                Write-WatchLog ("live-apply {0}: app-server went away while waiting - picks up at next spawn." -f $def.Name)
                continue
            }
            $oldIds = @($servers | ForEach-Object { [int]$_.ProcessId })
            foreach ($targetId in $oldIds) { Stop-Process -Id $targetId -Force -ErrorAction SilentlyContinue }
            Write-WatchLog ("live-apply {0}: recycled app-server pid(s) {1} - waiting for respawn..." -f $def.Name, ($oldIds -join ',')) 'SYNC'
            $respawned = $false
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Seconds 1
                $descNow = @(Get-DescendantProcesses ($st.Mains | ForEach-Object { [int]$_.Id }))
                $fresh = @($descNow | Where-Object { $_.CommandLine -like '*app-server*' -and $oldIds -notcontains [int]$_.ProcessId })
                if ($fresh.Count -gt 0) { $respawned = $true; break }
            }
            if ($respawned) { Write-WatchLog ("live-apply {0}: app-server respawned after ~{1}s - new MCP definitions are live." -f $def.Name, ($i + 1)) 'SYNC' }
            else { Write-WatchLog ("live-apply {0}: [FAIL] app-server did not respawn within 30s - check the window." -f $def.Name) 'FAIL' }
        } catch {
            Write-WatchLog ("live-apply {0} FAILED: {1}" -f $def.Name, $_.Exception.Message) 'FAIL'
        }
    }
}

# --- Primary signature + debounced sync pass ---------------------------------
$script:LastSig      = $null
$script:PendingSig   = $null
$script:PendingSince = $null
$script:PassCount    = 0

function Get-PrimarySignature {
    $fi = Get-Item -LiteralPath $PrimaryConfig -ErrorAction Stop
    $parseOk = $true
    try { $null = Get-Content -LiteralPath $PrimaryConfig -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $parseOk = $false }
    return @{ Sig = ('{0}|{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length); ParseOk = $parseOk }
}

function Invoke-SyncPass([switch]$Force) {
    # Returns 'changed' | 'insync' | 'failed' | 'skipped'.
    if (-not (Test-Path -LiteralPath $PrimaryConfig)) {
        Write-WatchLog "Primary config missing: $PrimaryConfig" 'WARN'
        return 'skipped'
    }
    $sig = Get-PrimarySignature
    if (-not $sig.ParseOk) {
        # Never sync FROM a torn/invalid file: skip and wait for it to settle
        # (the app itself writes atomically, so this is a transient race at worst).
        Write-WatchLog 'Primary config.json failed to parse - skipping this pass (no sync from an invalid file).' 'WARN'
        return 'skipped'
    }
    if (-not $Force) {
        if ($sig.Sig -eq $script:LastSig) {
            if ($script:PendingSig) { $script:PendingSig = $null; $script:PendingSince = $null } # change reverted
            return 'insync'
        }
        if ($script:PendingSig -ne $sig.Sig) {
            $script:PendingSig = $sig.Sig
            $script:PendingSince = Get-Date
            return 'skipped'
        }
        if (((Get-Date) - $script:PendingSince).TotalMilliseconds -lt 800) { return 'skipped' }
    }
    if (-not $DryRun) { Write-WatchLog 'Primary MCP config changed (or startup converge) - syncing clones...' 'SYNC' }
    $res = Invoke-SyncChild
    $script:LastSig = $sig.Sig
    $script:PendingSig = $null
    $script:PendingSince = $null
    return $res
}

function Invoke-WatchPass {
    $script:PassCount++
    $first = ($script:PassCount -eq 1)                    # startup converge
    $deep  = (($script:PassCount % 60) -eq 0)             # deep re-verify ~5 min
    try {
        return Invoke-SyncPass -Force:($first -or $deep)
    } catch {
        Write-WatchLog ("watch pass FAILED: {0}" -f $_.Exception.Message) 'FAIL'
        return 'failed'
    }
}

# ---- Autostart management (Startup-folder shortcut, no registry) ------------
if ($InstallAutostart -or $RemoveAutostart) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'ZCode MCP sync watcher.lnk'
    if ($RemoveAutostart) {
        if (Test-Path -LiteralPath $lnkPath) {
            Remove-Item -LiteralPath $lnkPath -Force
            if (Test-Path -LiteralPath $lnkPath) { Write-WatchLog "autostart REMOVE FAILED - $lnkPath still exists" 'FAIL' }
            else { Write-WatchLog "autostart removed: $lnkPath" }
        } else {
            Write-WatchLog "autostart already absent: $lnkPath" 'WARN'
        }
        exit 0
    }
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = $PsExe
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    $sc.WorkingDirectory = Split-Path -Parent $PSCommandPath
    $sc.Description = 'Syncs MCP definitions from the Primary ZCode config to every clone (live, running instances included)'
    $sc.Save()
    # verify-after re-read (never silent-success)
    $chk = $shell.CreateShortcut($lnkPath)
    if ($chk.TargetPath -eq $sc.TargetPath -and $chk.Arguments -eq $sc.Arguments) {
        Write-WatchLog "autostart installed: $lnkPath"
    } else {
        Write-WatchLog "autostart INSTALL FAILED - read-back mismatch on $lnkPath" 'FAIL'
    }
    exit 0
}

# ---- One-shot / resident ----------------------------------------------------
if ($RunOnce) {
    Write-WatchLog ("one-shot pass starting (target {0}, DryRun {1}, ApplyLive {2})" -f $Target, [bool]$DryRun, [bool]$ApplyLive)
    $status = Invoke-WatchPass
    if ($ApplyLive) { Invoke-ApplyLivePass }
    Write-WatchLog ("single pass complete (-RunOnce, status {0})" -f $status)
    exit 0
}

# Resident console title: self-identifying no matter how it was launched.
try { $Host.UI.RawUI.WindowTitle = 'ZCode MCP Sync Watcher (pid {0})' -f $PID } catch { }

# Process scan on top of the mutex: the mutex only serializes copies of THIS
# script version - a stale older copy would co-run silently. Matched by
# script leaf name so relative and absolute -File paths both hit; own pid and
# -RunOnce one-shots excluded.
function Get-OtherWatcherPids {
    $leaf = (Split-Path -Leaf $PSCommandPath).ToLowerInvariant()
    $found = @()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        $cl = ""
        if ($p.CommandLine) { $cl = $p.CommandLine.ToLowerInvariant() }
        if (-not $cl.Contains($leaf)) { continue }
        if ($cl.Contains("-runonce")) { continue }
        $found += [int]$p.ProcessId
    }
    return $found
}

if (-not (Test-Path -LiteralPath $SyncScript)) {
    Write-WatchLog "sync script missing: $SyncScript - nothing to invoke; exiting." 'FAIL'
    exit 1
}

$others = Get-OtherWatcherPids
if ($others.Count -gt 0) {
    Write-WatchLog ('watcher already running (pid {0}) - exiting. Close that console or stop the pid first.' -f ($others -join ', ')) 'WARN'
    exit 0
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ZcodeMcpSyncWatcher', [ref]$created)
if (-not $created) {
    $holder = Get-OtherWatcherPids
    $who = ''
    if ($holder.Count -gt 0) { $who = ' by pid ' + ($holder -join ', ') }
    Write-WatchLog ('watcher already running (mutex held{0}) - exiting. Check the log or Task Manager.' -f $who) 'WARN'
    $mutex.Close()
    exit 0
}
Write-WatchLog ('watcher started (pid {0}, interval {1}s, target {2}, ApplyLive {3}, script {4})' -f $PID, $IntervalSeconds, $Target, [bool]$ApplyLive, $PSCommandPath)
try {
    while ($true) {
        $status = Invoke-WatchPass
        # Resident -ApplyLive is opt-in: recycle only right after a real change.
        if ($ApplyLive -and $status -eq 'changed') { Invoke-ApplyLivePass }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Close()
    Write-WatchLog 'watcher stopped'
}
