#requires -Version 5.1
<#
.SYNOPSIS
  Sequential launcher for ALL FIVE AutoClaw2 clones (c1..c5).

.DESCRIPTION
  GHOST rule (v1.20 suite, same here): launch clones SEQUENTIALLY, never in
  parallel - each copy needs a clear run at profile initialization and lock
  acquisition. The inter-clone spacing is a FIXED delay ($PerCloneWaitSeconds,
  default 12s) - a best-effort gap, NOT a log-observed readiness wait: no zwork
  log is tailed and one slow clone may still be initializing when the next
  starts (per-profile locks keep that safe; confirm afterwards with -Status).
  Each child launcher's exit code is captured and this script exits non-zero if
  any clone launch failed (never-silent-success).

  Uses src\windows\launch_autoclaw2_clone.ps1 per instance. Never elevated.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launch_autoclaw2_clones_all.ps1
#>
param(
    [int]$PerCloneWaitSeconds = 12
)
$ErrorActionPreference = 'Stop'

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher  = Join-Path $here 'launch_autoclaw2_clone.ps1'
$cloneIds  = @('c1','c2','c3','c4','c5')

if (-not (Test-Path $launcher)) { Write-Error "launcher not found: $launcher"; exit 1 }

$results = @()
foreach ($id in $cloneIds) {
    Write-Host ""
    Write-Host "=== $id ===" -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Instance $id
    $results += [pscustomobject]@{ Clone = $id; ExitCode = $LASTEXITCODE }
    Start-Sleep -Seconds $PerCloneWaitSeconds
}

Write-Host ""
Write-Host "clone launch summary (per-clone launcher exit codes):"
$anyFail = $false
foreach ($r in $results) {
    if ($r.ExitCode -eq 0) {
        Write-Host ("  {0}: OK" -f $r.Clone) -ForegroundColor Green
    }
    else {
        Write-Host ("  {0}: FAILED (launcher exit {1})" -f $r.Clone, $r.ExitCode) -ForegroundColor Red
        $anyFail = $true
    }
}
if ($anyFail) {
    Write-Host "one or more clone launches FAILED - see the lines above." -ForegroundColor Red
    exit 1
}
Write-Host "all 5 clone launches issued (sequential); every launcher exited 0." -ForegroundColor Green
Write-Host "verify with: launch_autoclaw2_clone.ps1 -Instance c1..c5 -Status"
