#Requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY per-suite instance pressure report for the AutoClaw2, Cline and
  OpenCode clone suites - the portable half of the ZCode diagnostics
  (tools\diagnose_zcode_freeze.ps1 [3] + tools\status_zcode_instances.ps1)
  generalized. ZCode keeps its dedicated tools (its log/crash formats are
  app-specific and already covered).

.DESCRIPTION
  [1] Instance table: SOURCED FROM THE SHARED LIB (tools\suite_status_lib.ps1,
      Get-GhostSuiteInstanceState — TA-2 dedup, 2026-11-28): the standing
      rules live there now (copy-exe-first, subtree-marker walk, lockfile
      probes, title maps, the light-worker column, honest labeling — anything
      unlabeled is reported 'unknown / no' with an UNCLASSIFIABLE note, never
      guessed). This tool snapshots the suite's process family + main windows
      ONCE and injects them into the lib, then renders the lib's rows plus
      its own memory/commit and log-scan sections.
  [2] Live memory / commit pressure (right now) - the exact block that
      caught the 2026-09-25 renderer-OOM commit-limit freeze: physical,
      commit used/limit/pct (>=90% = renderer-OOM territory), pagefiles,
      per-suite family totals.
  [3] Optional Electron log scan (-Days N, default 3): counts
      render-process-gone / child-process-gone lines in each suite's log
      dirs THAT EXIST; a dir that does not resolve prints a loud skip.
      DERIVED layouts (the apps own their log trees): autoclaw2
      %APPDATA%\AutoClaw2\logs + clone homes, opencode Primary
      %APPDATA%\ai.opencode.desktop\logs + <home>\desktop\logs, cline
      ~\.cline\data\logs + <home>\data\logs. ZCode's dedicated
      tools\diagnose_zcode_freeze.ps1 / diagnose_zcode_throttle.ps1 remain
      the authoritative ZCode diagnostics.

.Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\diagnose_suite_pressure.ps1 -Suite opencode [-Days 3]

  GHOST.bat: AutoClaw2 [24] (gid 116), Cline [20] (gid 117), OpenCode [24]
  (gid 118). Writes NOTHING (except nothing - fully read-only).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('autoclaw2', 'cline', 'opencode')]
    [string]$Suite,
    [ValidateRange(1, 30)]
    [int]$Days = 3
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$Colors = @('Blue', 'Yellow', 'Green', 'Red', 'Orange')

function Write-Hdr([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}

# --- Suite maps -----------------------------------------------------------------
# (TA-2 dedup 2026-11-28: the classification inputs - lock probes, title maps,
#  copy-exe rules, markers - live in tools\suite_status_lib.ps1 now; this map
#  keeps only what THIS tool's own sections consume: the process family for
#  the pressure totals and the log dirs for [3].)
$SuiteDefs = @{
    'autoclaw2' = @{
        ProcFamily  = 'AutoClaw2*'
        WmiFamily   = "Name LIKE 'AutoClaw2%'"
        ExePrefix   = 'AutoClaw2'
        LogDirs     = @(
            @{ Label = 'Primary logs';    Path = Join-Path $env:APPDATA 'AutoClaw2\logs';   Provenance = 'DERIVED' }
            @{ Label = 'work logs';       Path = Join-Path $UserProfile 'AutoClaw2ClonesHome'; Provenance = 'DERIVED' }
        )
    }
    'cline' = @{
        ProcFamily  = 'Cline*'
        WmiFamily   = "Name LIKE 'Cline%'"
        ExePrefix   = 'Cline'
        LogDirs     = @(
            @{ Label = 'Primary logs';    Path = Join-Path $UserProfile '.cline\data\logs'; Provenance = 'VERIFIED (reset_cline sweeps it)' }
            @{ Label = 'clone logs';      Path = Join-Path $UserProfile 'ClineClonesHome'; Provenance = 'DERIVED' }
        )
    }
    'opencode' = @{
        ProcFamily  = 'OpenCode*'
        WmiFamily   = "Name LIKE 'OpenCode%'"
        ExePrefix   = 'OpenCode'
        LogDirs     = @(
            @{ Label = 'Primary logs';    Path = Join-Path $env:APPDATA 'ai.opencode.desktop\logs'; Provenance = 'DERIVED' }
            @{ Label = 'clone logs';      Path = Join-Path $UserProfile 'OpenCodeClonesHome'; Provenance = 'DERIVED' }
        )
    }
}
$Sd = $SuiteDefs[$Suite]

# --- [1] instance table (the SHARED suite-status lib; TA-2 dedup) ------------------
Write-Hdr ("[1] {0} instance table (read-only signals, honestly labeled - shared classifier)" -f $Suite)
$famProcs = @(Get-CimInstance Win32_Process -Filter $Sd.WmiFamily -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
$wins = @(Get-Process -Name $Sd.ProcFamily -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
. (Join-Path $PSScriptRoot 'suite_status_lib.ps1')
$state = Get-GhostSuiteInstanceState -Suite $Suite -Procs $famProcs -Windows $wins
$rows = @($state.Rows | ForEach-Object {
    [pscustomobject]@{
        Instance    = $_.Instance
        Color       = $(if ($_.Color) { $_.Color } else { '-' })
        State       = $_.State
        Signal      = $_.Signal
        Lock        = $_.Lock
        Window      = $_.Windows
        LightWorker = $_.LightWorker
        Note        = $_.Note
    }
})
$rows | Format-Table Instance, Color, State, Signal, Lock, Window, LightWorker, Note -AutoSize | Out-String -Width 220 | Write-Host
Write-Host ("   family total: {0} {1} process(es), {2} with a main window" -f $famProcs.Count, $Sd.ExePrefix, $wins.Count)

# --- [2] live memory / commit pressure ---------------------------------------------
Write-Hdr '[2] Live memory / commit pressure (right now)'
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
    $pagefiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    if ($pagefiles.Count -eq 0) {
        Write-Host '   pagefile : NONE CONFIGURED (commit limit = RAM only - primary OOM trigger)' -ForegroundColor Yellow
    } else {
        foreach ($pf in $pagefiles) {
            Write-Host ('   pagefile : ' + $pf.Name + ' - allocated ' + $pf.AllocatedBaseSize + ' MB, in use ' + $pf.CurrentUsage + ' MB, peak ' + $pf.PeakUsage + ' MB')
        }
    }
    $suiteProcs = @(Get-Process -Name $Sd.ProcFamily -ErrorAction SilentlyContinue)
    if ($suiteProcs.Count -gt 0) {
        $wsMB = [math]::Round(($suiteProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB, 0)
        Write-Host ('   ' + $Sd.ExePrefix + '    : ' + $suiteProcs.Count + ' ' + $Sd.ProcFamily + ' process(es) running, ~' + $wsMB + ' MB working set total')
    } else {
        Write-Host ('   ' + $Sd.ExePrefix + '    : no ' + $Sd.ProcFamily + ' processes running right now')
    }
} else {
    Write-Host '   WMI/CIM query unavailable - skipped'
}

# --- [3] optional Electron log scan --------------------------------------------------
Write-Hdr ("[3] Electron log scan - last {0} day(s) (render/child-process-gone)" -f $Days)
foreach ($ld in $Sd.LogDirs) {
    $p = $ld.Path
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("   {0}: {1} - ABSENT (skipped loudly; {2})" -f $ld.Label, $p, $ld.Provenance)
        continue
    }
    $cutoff = (Get-Date).AddDays(-$Days)
    # Client-side extension filter: -Include is unreliable against a bare
    # -LiteralPath dir on PS 5.1 (it swept .sqlite blobs into the scan once);
    # -Depth bounds the clone-home trees.
    $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff -and $_.Extension -in '.log', '.txt' })
    $gone = 0
    $samples = @()
    foreach ($f in $files) {
        try {
            $hits = @(Select-String -LiteralPath $f.FullName -Pattern 'render-process-gone|child-process-gone' -ErrorAction SilentlyContinue)
            $gone += $hits.Count
            foreach ($h in ($hits | Select-Object -First 2)) { $samples += ($f.Name + ': ' + $h.Line.Trim().Substring(0, [Math]::Min(140, $h.Line.Trim().Length))) }
        } catch { }
    }
    Write-Host ("   {0}: {1} - {2} recent file(s), {3} gone-event line(s) ({4})" -f $ld.Label, $p, $files.Count, $gone, $ld.Provenance)
    foreach ($s in ($samples | Select-Object -First 4)) { Write-Host ('     ' + $s) }
}

Write-Host ''
Write-Host 'read-only report complete. For ZCode use its dedicated tools (diagnose_zcode_freeze / diagnose_zcode_throttle).' -ForegroundColor Gray
