#requires -Version 5.1
<#
.SYNOPSIS
  Sequential launcher for ALL FIVE Cline clones (c1..c5).

.DESCRIPTION
  GHOST rule (ZCode/AutoClaw suites, same here): launch clones
  SEQUENTIALLY, never in parallel - each copy needs a clear run at
  profile initialization, hub lock acquisition and single-instance
  window neutralization (racing two launches can make one of them see
  the other's fresh hidden window and exit).

  Waits a FIXED delay (default 12s) between launches - no per-clone
  readiness detection - then prints the -Status hint. Uses
  src\windows\launch_cline_clone.ps1 per instance. Never elevated.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_cline_clones_all.ps1
#>
param(
    [int]$PerCloneWaitSeconds = 12
)
$ErrorActionPreference = 'Stop'

$here     = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $here 'launch_cline_clone.ps1'
$cloneIds = @('c1','c2','c3','c4','c5')

if (-not (Test-Path $launcher)) { Write-Error "launcher not found: $launcher"; exit 1 }

foreach ($id in $cloneIds) {
    Write-Host ""
    Write-Host "=== $id ===" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Instance $id
    Start-Sleep -Seconds $PerCloneWaitSeconds
}

Write-Host ""
Write-Host "all 5 clone launches issued (sequential)." -ForegroundColor Green
Write-Host "verify with: launch_cline_clone.ps1 -Instance c1..c5 -Status"
