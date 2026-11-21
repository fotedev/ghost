#Requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY cross-suite "who's running" report: one table per suite covering
  EVERY instance (Primary + clones) of ZCode, AutoClaw2, Cline and OpenCode -
  desktop windows AND headless light workers - in one invocation.

.DESCRIPTION
  Classification rides tools\suite_status_lib.ps1 (the shared port of the
  live-verified per-suite rules: EC-K01 bare-exe mains, copy-exe-first,
  subtree markers, lockfile probes, title maps) plus the light-worker
  PID-marker contract (<clone-home>\.ghost-light-worker.json written by the
  light-worker launchers, pid-liveness validated on read).

  Honest-labeling contract (never guessed):
    Signal: exe copy | markers | lockfile | title | bare main | no
    LightWorker: its own column - a light worker and its desktop clone may
    run on the SAME clone home (one store) legitimately.
    A stock-exe AutoClaw2 clone (env markers not externally readable, shared
    title, no lockfile) is reported UNCLASSIFIABLE, never guessed.

  This is the FLEET VIEW. The deep per-suite tools remain authoritative for
  detail: tools\status_zcode_instances.ps1 (ZCode [32]: deviceMid, roaming
  dirs, per-instance commit), the per-suite pressure reports (AutoClaw2 [24]
  / Cline [20] / OpenCode [24]: log scans), the launcher -Status rows, and
  the taskbar watchers.

.USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\status_all_instances.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\status_all_instances.ps1 -Suites zcode,opencode

  Menu: Maintenance [6] (gid 126). Writes NOTHING - fully read-only.
#>
[CmdletBinding()]
param(
    # Comma-separated or repeated; default = every suite.
    [ValidateSet('zcode', 'autoclaw2', 'cline', 'opencode', 'claudecode', 'codex')]
    [string[]]$Suites = @('zcode', 'autoclaw2', 'cline', 'opencode', 'claudecode', 'codex')
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

. (Join-Path $PSScriptRoot 'suite_status_lib.ps1')

# Accept "zcode,opencode" as well as repeated params / GHOST.bat args.
$Suites = @($Suites | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

Write-Host '=== GHOST all-suites instance status ===' -ForegroundColor Cyan

# OS commit/RAM header - the block that caught the 2026-09-25 renderer-OOM
# freeze (>=90% commit = renderer-OOM territory).
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freePhysGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $limitGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    $usedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
    $usedPct = 0
    if ([double]$os.TotalVirtualMemorySize -gt 0) {
        $usedPct = [math]::Round(100 * ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize, 1)
    }
    Write-Host ('   physical : ' + $totalGB + ' GB total, ' + $freePhysGB + ' GB free')
    Write-Host ('   commit   : ' + $usedGB + ' GB used of ' + $limitGB + ' GB limit (' + $usedPct + '%)')
    if ($usedPct -ge 90) {
        Write-Host '              ^^^ commit pressure is HIGH right now - renderer OOM territory' -ForegroundColor Yellow
        Write-Host '              (the ZCode-verified 2026-09-25 freeze class; fix = bigger pagefile and/or fewer instances)'
    }
} else {
    Write-Host '   WMI/CIM unavailable - skipping the OS pressure header' -ForegroundColor Yellow
}

foreach ($suite in $Suites) {
    Write-Host ''
    Write-Host ("--- {0} ---" -f $suite) -ForegroundColor Cyan
    $state = Get-GhostSuiteInstanceState -Suite $suite
    $state.Rows | Format-Table Instance, Color, State, Signal, LightWorker, Lock, Windows, Note -AutoSize |
        Out-String -Width 220 | Write-Host

    $running = @($state.Rows | Where-Object { $_.State -eq 'RUNNING' })
    $light = @($state.Rows | Where-Object { $_.LightWorker -like 'YES*' })
    Write-Host ("   {0}/{1} running (signals: exe copy / markers / lockfile / title / bare main); {2} light-worker marker(s) live; family snapshot {3} process(es)" -f `
            $running.Count, $state.Rows.Count, $light.Count, $state.FamilyCount)
}

Write-Host ''
Write-Host 'deep views: ZCode [32] status_zcode_instances | AutoClaw2 [24] / Cline [20] / OpenCode [24] pressure | launcher -Status rows | taskbar watchers' -ForegroundColor Gray
Write-Host 'headless workers show via their PID markers (.ghost-light-worker.json in each clone home; stale = pid dead).' -ForegroundColor Gray
exit 0
