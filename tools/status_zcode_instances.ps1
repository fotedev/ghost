#Requires -Version 5.1
<#
.SYNOPSIS
  Read-only status report for the six ZCode instances (Primary + Blue..Orange
  clones): running state per instance, profile dirs, device-id prefix and
  per-instance commit pressure. ZCode's parity row for the clone -Status the
  three newer suites' launchers already carry (2026-11-14).

.DESCRIPTION
  Classification is SOURCED FROM THE SHARED LIB (tools\suite_status_lib.ps1,
  Get-GhostSuiteInstanceState -Suite zcode — TA-2 dedup, 2026-11-28): the
  standing suite rules live there now (copy-family family filter, EC-K01
  bare-exe mains, copy-exe-first, subtree markers, honest labeling). This
  tool keeps what the lib does not model: the per-instance detail probes
  (roaming dir, clone home, telemetry deviceMid prefix) and the per-instance
  commit pressure over the attributed main pids.
  Reads are strictly read-only: process snapshots + profile-dir existence +
  the telemetry.machineId prefix from each roaming storage.json. No writes,
  no elevation needed. -All (default) covers all six; -Instance narrows.

.USAGE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\status_zcode_instances.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\status_zcode_instances.ps1 -Instance Third

  Menu: ZCode Maintenance [32] (gid 108).
#>
[CmdletBinding()]
param(
    [ValidateSet('Primary', 'Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
    [string]$Target = 'All'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# Instance table: frozen keys + display vocabulary + the same markers the
# launcher / reset / watcher classify by.
$script:Instances = @(
    @{ Key = 'Primary'; Color = $null;    Roaming = 'ZCode';         Home = $null;              CopyExe = $null;             AumidSuffix = $null },
    @{ Key = 'Second';  Color = 'Blue';   Roaming = 'ZCode-Second';  Home = 'ZCodeSecondHome';  CopyExe = 'ZCode-Blue.exe';  AumidSuffix = '2' },
    @{ Key = 'Third';   Color = 'Yellow'; Roaming = 'ZCode-Third';   Home = 'ZCodeThirdHome';   CopyExe = 'ZCode-Yellow.exe'; AumidSuffix = '3' },
    @{ Key = 'Fourth';  Color = 'Green';  Roaming = 'ZCode-Fourth';  Home = 'ZCodeFourthHome';  CopyExe = 'ZCode-Green.exe'; AumidSuffix = '4' },
    @{ Key = 'Fifth';   Color = 'Red';    Roaming = 'ZCode-Fifth';   Home = 'ZCodeFifthHome';   CopyExe = 'ZCode-Red.exe';   AumidSuffix = '5' },
    @{ Key = 'Sixth';   Color = 'Orange'; Roaming = 'ZCode-Sixth';   Home = 'ZCodeSixthHome';   CopyExe = 'ZCode-Orange.exe'; AumidSuffix = '6' }
)

function Get-ZcodeInstanceDisplay {
    param([hashtable]$Inst)
    if ($inst.Color) { return ('{0} ({1})' -f $inst.Color, $inst.Key) }
    return 'Primary'
}

# --- classification (the SHARED suite-status lib; TA-2 dedup 2026-11-28) ------
# The EC-K01 bare-exe mains + copy-exe-first + subtree-marker rules live in
# tools\suite_status_lib.ps1 now (this tool's former inline copy was the seed
# the lib was extracted from). Returns the lib's state object; the render
# loop below maps Rows -> the per-instance detail probes.
. (Join-Path $PSScriptRoot 'suite_status_lib.ps1')
function Get-ZcodeInstanceStateFromLib {
    return (Get-GhostSuiteInstanceState -Suite zcode)
}

# --- read-only probes -----------------------------------------------------------
function Get-ZcodeDeviceMidPrefix {
    # Per-clone device identity lives in <home>\.zcode\v2\telemetry-state.json
    # -> deviceMid (the reset's "telemetry-state deviceMid" step target), NOT
    # in the roaming Electron userData. The Primary reads ~\.zcode\v2\.
    param([hashtable]$Inst)
    $zroot = if ($inst.Home) { Join-Path (Join-Path $env:USERPROFILE $inst.Home) '.zcode' }
             else { Join-Path $env:USERPROFILE '.zcode' }
    $ts = Join-Path (Join-Path $zroot 'v2') 'telemetry-state.json'
    if (-not (Test-Path -LiteralPath $ts -PathType Leaf)) { return $null }
    try {
        $json = Get-Content -LiteralPath $ts -Raw -Encoding UTF8 | ConvertFrom-Json
        $mid = $json.deviceMid
        if ($mid) { return ([string]$mid).Substring(0, [Math]::Min(8, ([string]$mid).Length)) }
    } catch { }
    return $null
}

# --- main -------------------------------------------------------------------------
$targets = @($Target)
if ($Target -eq 'All') {
    $targets = @($script:Instances | ForEach-Object { $_.Key })
}
$state = Get-ZcodeInstanceStateFromLib
$rowByInstance = @{}
foreach ($r in @($state.Rows)) { $rowByInstance[$r.Instance] = $r }
$osCommit = Get-CimInstance Win32_OperatingSystem
$osUsed = ($osCommit.TotalVirtualMemorySize - $osCommit.FreeVirtualMemory) / 1KB
$osLimit = $osCommit.TotalVirtualMemorySize / 1KB

Write-Host "=== ZCode instances status ===" -ForegroundColor Cyan
Write-Host ("OS commit: {0:N0} / {1:N0} MB" -f $osUsed, $osLimit)
Write-Host ''
$anyRunning = 0
foreach ($key in $targets) {
    $inst = @($script:Instances | Where-Object { $_.Key -eq $key })[0]
    $display = Get-ZcodeInstanceDisplay -Inst $inst
    $row = $rowByInstance[$key]
    $pids = @(if ($row) { $row.Pids } else { @() })
    $running = $pids.Count -gt 0
    if ($running) { $anyRunning++ }

    $roamingDir = Join-Path $env:APPDATA $inst.Roaming
    $roamingOk = Test-Path -LiteralPath $roamingDir -PathType Container
    $homeDir = $null
    $homeOk = $null
    if ($inst.Home) {
        $homeDir = Join-Path (Join-Path $env:USERPROFILE $inst.Home) '.zcode'
        $homeOk = Test-Path -LiteralPath $homeDir -PathType Container
    }

    $commitMb = 0
    $commitNote = '-'
    if ($running) {
        $famProcs = @(Get-Process -Id $pids -ErrorAction SilentlyContinue)
        $sum = ($famProcs | Measure-Object -Property PrivateMemorySize64 -Sum).Sum
        if ($sum) { $commitMb = [int]($sum / 1MB) }
        $commitNote = ('{0} MB commit ({1} proc(s))' -f $commitMb, $famProcs.Count)
    }

    $state = if ($running) { 'RUNNING ' } else { 'stopped' }
    $stateColor = if ($running) { 'Green' } else { 'DarkGray' }
    Write-Host ("{0,-15} {1}  pids: {2}" -f $display, $state, $(if ($pids) { $pids -join ',' } else { '-' })) -ForegroundColor $stateColor
    Write-Host ("  roaming    : {0} ({1})" -f $roamingDir, $(if ($roamingOk) { 'present' } else { 'MISSING' }))
    if ($inst.Home) {
        Write-Host ("  clone home : {0} ({1})" -f $homeDir, $(if ($homeOk) { 'present' } else { 'MISSING' }))
    }
    $mid = Get-ZcodeDeviceMidPrefix -Inst $inst
    Write-Host ("  deviceMid  : {0}" -f $(if ($mid) { $mid + '...' } else { 'unreadable (no v2 telemetry-state yet)' }))
    if ($running) { Write-Host ("  pressure   : {0}" -f $commitNote) }
    Write-Host ''
}

if ($Target -eq 'All') {
    Write-Host ("{0} instance(s) running." -f $anyRunning) -ForegroundColor Cyan
    Write-Host 'NOTE: Task Manager shows the colored exe copies (ZCode-Blue.exe .. ZCode-Orange.exe) - this report is the process-truth view.'
}
exit 0
