#Requires -Version 5.1
<#
diagnose_zcode_freeze.ps1 - explain a "frozen" ZCode window from the app's own telemetry.

Verified root cause (2026-09-25): a window that still drags but shows dead
content is NOT a hanging renderer - the renderer process DIED
(render-process-gone reason "oom") while the main process kept the frame
alive. Primary and Second died in the same second that day, Fourth in the
morning, and the archived dump carries v8-oom-last-os-error 1455 =
ERROR_COMMITMENT_LIMIT: the OS commit limit (RAM + pagefile) was exhausted
with 4 instances running - not an app leak. The splash-then-close relaunch
loop is the app's documented post-crash quit path (it discards the dead
window, creates a new one, then "all windows closed after preparation,
exiting app"); launching again afterwards is safe.

This tool is strictly read-only. It scans each instance's own v2 logs and
crash archive (they live under the HOME dir's .zcode, same instance map as
watch_zcode_taskbar.ps1), then prints the live RAM/commit/pagefile pressure.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\diagnose_zcode_freeze.ps1          # last 2 days
  ... -Days 7                                                                                  # wider window
#>
param(
    [ValidateRange(1, 30)]
    [int]$Days = 2
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Same instance map as watch_zcode_taskbar.ps1: per-instance app data lives in
# the HOME dir's .zcode (Primary uses the real profile, clones their ZCode*Home).
$Instances = @(
    @{ Name = 'Primary'; Home = $env:USERPROFILE },
    @{ Name = 'Second';  Home = (Join-Path $env:USERPROFILE 'ZCodeSecondHome') },
    @{ Name = 'Third';   Home = (Join-Path $env:USERPROFILE 'ZCodeThirdHome') },
    @{ Name = 'Fourth';  Home = (Join-Path $env:USERPROFILE 'ZCodeFourthHome') }
)

function Write-Hdr([string]$Text) {
    Write-Output ''
    Write-Output ('==== ' + $Text + ' ====')
}

# Flatten a parsed dump annotation json into "key = value" leaf strings.
function Get-JsonLeaves {
    param($Node, [string]$Prefix)
    if ($null -eq $Node -or $Node -is [System.Array]) { return @() }
    if (-not ($Node -is [System.Management.Automation.PSCustomObject])) {
        return @(($Prefix + ' = ' + $Node))
    }
    $out = @()
    foreach ($p in $Node.PSObject.Properties) {
        $key = $p.Name
        if ($Prefix) { $key = $Prefix + '.' + $key }
        $val = $p.Value
        if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) { continue }
        if ($val -is [System.Management.Automation.PSCustomObject]) {
            $out += @(Get-JsonLeaves $val $key)
        } else {
            $text = [string]$val
            if ($text.Length -gt 110) { $text = $text.Substring(0, 110) + '...' }
            $out += ($key + ' = ' + $text)
        }
    }
    return $out
}

$Dates = @(0..($Days - 1) | ForEach-Object { (Get-Date).Date.AddDays(-$_).ToString('yyyy-MM-dd') })
$Events = @()   # objects: Instance, Ts, Pid, Kind, Reason
$script:OomOsError1455 = $false

# ---- [1] per-instance crash events from the v2 logs -------------------------
# Only the event lines carry a json payload ("...-gone: {"); the follow-up
# "archived N dump(s) source=..." lines repeat the keyword and are skipped.
Write-Hdr ('[1] Renderer/child crash + freeze events, last ' + $Days + ' day(s)')
foreach ($inst in $Instances) {
    $logDir = Join-Path $inst.Home '.zcode\v2\logs'
    Write-Output ''
    Write-Output ('-- ' + $inst.Name + '  (' + $logDir + ')')
    if (-not (Test-Path $logDir)) {
        Write-Output '   no v2 log dir - this instance never ran here'
        continue
    }
    $scanned = 0
    $raw = @()
    foreach ($date in $Dates) {
        $logFile = Join-Path $logDir ($date + '.log')
        if (-not (Test-Path $logFile)) { continue }
        $scanned++
        try {
            $hits = @(Select-String -LiteralPath $logFile -Pattern 'render-process-gone: \{|child-process-gone: \{|perf_freeze|unresponsive' -ErrorAction SilentlyContinue)
        } catch {
            Write-Output ('   log unreadable (in use?): ' + $date + '.log')
            continue
        }
        foreach ($hit in $hits) {
            $line = $hit.Line
            $ts = ''; $pid2 = ''
            if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?:\.\d+)?)\]') { $ts = $Matches[1] }
            if ($line -match '\[pid:(\d+)\]') { $pid2 = $Matches[1] }
            $kind = ''; $reason = ''
            if ($line -match 'render-process-gone: \{') {
                $kind = 'renderer gone'
                if ($line -match '"reason":"([a-z\-]+)"') { $reason = $Matches[1] }
            } elseif ($line -match 'child-process-gone: \{') {
                $kind = 'child process gone'
                if ($line -match '"reason":"([a-z\-]+)"') { $reason = $Matches[1] }
            } elseif ($line -match 'perf_freeze') {
                $kind = 'window freeze >30s'
            } elseif ($line -match 'unresponsive') {
                $kind = 'window unresponsive >5s'
            }
            if ($kind -eq '') { continue }
            $raw += [pscustomobject]@{ Ts = $ts; Pid = $pid2; Kind = $kind; Reason = $reason }
            $Events += [pscustomobject]@{ Instance = $inst.Name; Ts = $ts; Pid = $pid2; Kind = $kind; Reason = $reason }
        }
    }
    if ($scanned -eq 0) {
        Write-Output ('   no log files for the scanned dates (' + ($Dates -join ', ') + ')')
    } elseif ($raw.Count -eq 0) {
        Write-Output ('   clean - no crash/freeze events in ' + $scanned + ' log file(s)')
    } else {
        # Collapse bursts (an instance shutdown cascades dozens of child-gone
        # within one second) into one counted line per second+event kind.
        # Group on the second only - millisecond timestamps differ per event.
        $buckets = @{}
        foreach ($e in $raw) {
            $sec = $e.Ts
            if ($sec.Length -ge 19) { $sec = $sec.Substring(0, 19) }
            $key = $sec + '|' + $e.Pid + '|' + $e.Kind + '|' + $e.Reason
            if (-not $buckets.ContainsKey($key)) {
                $buckets[$key] = @{ E = $e; Count = 0 }
            }
            $buckets[$key].Count++
        }
        foreach ($b in ($buckets.Values | Sort-Object { $_.E.Ts })) {
            $e = $b.E
            $suffix = ''
            if ($b.Count -gt 1) { $suffix = '   (x' + $b.Count + ' within the same second)' }
            $line2 = '   ' + $e.Ts + '  pid ' + $e.Pid + '  ' + $e.Kind
            if ($e.Reason) { $line2 += ': ' + $e.Reason }
            Write-Output ($line2 + $suffix)
        }
    }
}

# ---- [2] crash archive annotations ------------------------------------------
Write-Hdr '[2] Crash archive (newest dumps + annotations)'
foreach ($inst in $Instances) {
    $crashDir = Join-Path $inst.Home '.zcode\v2\crash\archive'
    Write-Output ''
    Write-Output ('-- ' + $inst.Name)
    if (-not (Test-Path $crashDir)) {
        Write-Output '   no crash archive'
        continue
    }
    $dumps = @(Get-ChildItem -LiteralPath $crashDir -Filter '*.dmp' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    if ($dumps.Count -eq 0) {
        Write-Output '   archive empty'
        continue
    }
    foreach ($dmp in $dumps) {
        $stamp = $dmp.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $jsonPath = $dmp.FullName + '.json'
        if (-not (Test-Path $jsonPath)) {
            Write-Output ('   ' + $stamp + '  ' + $dmp.Name + '  (no annotations json - capture itself was memory-starved)')
            continue
        }
        $leaves = @()
        try {
            $json = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $leaves = @(Get-JsonLeaves $json '')
        } catch {
            Write-Output ('   ' + $stamp + '  ' + $dmp.Name + '  (annotations json unreadable: ' + $_.Exception.Message + ')')
            continue
        }
        # Root cause first: the os-error / oomKind / cage-commit trio decides
        # whether this was OS commit exhaustion vs a renderer heap limit.
        $prio = @($leaves | Where-Object { $_ -match '(?i)last-os-error|oomKind|mainCageLastAllocStatus|process_type|renderer_foreground' } | Select-Object -First 6)
        $rest = @($leaves | Where-Object { $_ -notmatch '(?i)last-os-error|oomKind|mainCageLastAllocStatus|process_type|renderer_foreground|last-few-messages' } | Select-Object -First 3)
        Write-Output ('   ' + $stamp + '  ' + $dmp.Name)
        foreach ($one in @($prio + $rest)) {
            $out = '     ' + $one
            if ($one -match 'last-os-error\s*=\s*1455(?!\d)') {
                $script:OomOsError1455 = $true
                $out = $out + '   <-- ERROR_COMMITMENT_LIMIT: paging file too small'
            }
            Write-Output $out
        }
    }
}

# ---- [3] live memory / commit pressure --------------------------------------
Write-Hdr '[3] Live memory / commit pressure (right now)'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$usedPct = 0
if ($os) {
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freePhysGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $limitGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    $usedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
    if ([double]$os.TotalVirtualMemorySize -gt 0) {
        $usedPct = [math]::Round(100 * ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize, 1)
    }
    Write-Output ('   physical : ' + $totalGB + ' GB total, ' + $freePhysGB + ' GB free')
    Write-Output ('   commit   : ' + $usedGB + ' GB used of ' + $limitGB + ' GB limit (' + $usedPct + '%)')
    if ($usedPct -ge 90) {
        Write-Output '              ^^^ commit pressure is HIGH right now - renderer OOM territory'
    }
    $pagefiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    if ($pagefiles.Count -eq 0) {
        Write-Output '   pagefile : NONE CONFIGURED (commit limit = RAM only - primary OOM trigger)'
    } else {
        foreach ($pf in $pagefiles) {
            Write-Output ('   pagefile : ' + $pf.Name + ' - allocated ' + $pf.AllocatedBaseSize + ' MB, in use ' + $pf.CurrentUsage + ' MB, peak ' + $pf.PeakUsage + ' MB')
        }
    }
} else {
    Write-Output '   WMI/CIM query unavailable - skipped'
}
$zprocs = @(Get-Process -Name 'ZCode*' -ErrorAction SilentlyContinue)
if ($zprocs.Count -gt 0) {
    $wsMB = [math]::Round(($zprocs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB, 0)
    Write-Output ('   ZCode    : ' + $zprocs.Count + ' ZCode* process(es) running, ~' + $wsMB + ' MB working set total')
} else {
    Write-Output '   ZCode    : no ZCode* processes running right now'
}

# ---- [4] verdict --------------------------------------------------------------
Write-Hdr '[4] Verdict'
$oomEvents = @($Events | Where-Object { $_.Kind -like '*gone*' -and $_.Reason -eq 'oom' })
$goneEvents = @($Events | Where-Object { $_.Kind -like '*gone*' })
if ($oomEvents.Count -gt 0) {
    $tally = ($oomEvents | Group-Object Instance | ForEach-Object { $_.Name + ' x' + $_.Count }) -join ', '
    Write-Output ('   renderer OOM deaths found: ' + $tally)
    if ($script:OomOsError1455) {
        Write-Output '   dump annotation v8-oom-last-os-error 1455 = ERROR_COMMITMENT_LIMIT:'
        Write-Output '   the OS commit limit (RAM + pagefile) was exhausted - not an app leak.'
        Write-Output '   Fix: enlarge the pagefile (fixed ~1.5-2x RAM or system-managed) and/or'
        Write-Output '   run fewer instances concurrently.'
    } else {
        Write-Output '   no 1455 annotation captured; check [2] for oomKind (js_heap_exhausted ='
        Write-Output '   renderer heap, anything else with "failed to commit" = OS commit limit).'
    }
    Write-Output '   The window that drags but shows dead content is the leftover frame of the'
    Write-Output '   dead renderer; the splash-then-close relaunch is the app post-crash quit'
    Write-Output '   path - launching that instance again afterwards is safe.'
} elseif ($goneEvents.Count -gt 0) {
    Write-Output '   process deaths found but none with reason "oom" - see [1] for the reasons'
    Write-Output '   and [2] for dump annotations before blaming memory.'
} else {
    Write-Output ('   no renderer/child deaths in the scanned window (last ' + $Days + ' day(s)).')
    Write-Output '   If a window is dead RIGHT NOW: the event may be older than the window, or'
    Write-Output '   only perf_freeze/unresponsive entries exist (a hang, not a death).'
}
if ($usedPct -ge 90) {
    Write-Output '   Commit pressure right now is >= 90% - expect more OOM deaths until it drops.'
}
Write-Output ''
