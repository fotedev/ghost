#requires -Version 5.1
<#
.SYNOPSIS
  Launches ALL FIVE OpenCode clones sequentially (c1..c5).

.DESCRIPTION
  Thin sequential wrapper over launch_opencode_clone.ps1: one clone at a
  time, each launcher's own verify-after acts as the stagger, plus a fixed
  10s settle between clones (Electron mains + their background-service
  children need a beat before the next boot; racing boots can make a later
  instance's lockfile probe misread). Do NOT launch clones in parallel.

  Each fresh clone needs ONE manual sign-in afterwards (never automated).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_opencode_clones_all.ps1
#>
param(
    [switch]$Status
)
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'launch_opencode_clone.ps1'
if (-not (Test-Path $launcher)) { throw "launcher not found: $launcher" }

$clones = @('c1', 'c2', 'c3', 'c4', 'c5')

if ($Status) {
    foreach ($c in $clones) {
        & $launcher -Instance $c -Status
        Write-Host ''
    }
    return
}

for ($i = 0; $i -lt $clones.Count; $i++) {
    $c = $clones[$i]
    Write-Host ''
    Write-Host ("=== OpenCode clone {0} of 5: {1} ===" -f ($i + 1), $c) -ForegroundColor Cyan
    & $launcher -Instance $c
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("clone {0} launch reported failure (exit {1}) - continuing with the remaining clones." -f $c, $LASTEXITCODE)
    }
    if ($i -lt $clones.Count - 1) {
        Start-Sleep -Seconds 10
    }
}
Write-Host ''
Write-Host 'All five clones processed. Remember: ONE manual sign-in per fresh clone.' -ForegroundColor Green
