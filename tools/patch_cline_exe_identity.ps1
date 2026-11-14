#requires -Version 5.1
<#
.SYNOPSIS
  Builds per-clone Cline.exe copies ("Cline-Blue.exe" ... "Cline-Orange.exe")
  in the install dir and patches their embedded icon + FileDescription, so
  Windows Task Manager renders one colored, named group per clone instead of
  five identical stock rows.

.DESCRIPTION
  The generic Task-Manager exe identity core (tools\exe_identity_lib.ps1,
  live-verified on the ZCode suite 2026-11-11) applied to Cline (the Tauri
  app is cline-app.exe - small exe, so the 5 copies cost little disk). Built
  REPO-ONLY and OPT-IN: nothing in this suite's launcher auto-wires it and no
  copies were built on the dev host. The webview children (msedgewebview2)
  are unaffected - Task Manager groups them separately either way; this
  patch targets the main-app group.

  Same contract as the ZCode patcher: freshness marker "<exe>.ghost-id.json",
  running gate (skip-running), copy + one Win32 update transaction + full
  re-read verify-after + JSONL audit at %LOCALAPPDATA%\ghost-cline-exe-identity.

  Menu: Cline Maintenance [10] (gid 106).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_cline_exe_identity.ps1 -Target All -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_cline_exe_identity.ps1 -Target c2
#>
[CmdletBinding()]
param(
  [ValidateSet('c1', 'c2', 'c3', 'c4', 'c5', 'All')]
  [string]$Target = 'All',
  [string]$InstallDir,
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'exe_identity_lib.ps1')

$script:EngineVersion = 1
$script:ClineAuditDir = Join-Path $env:LOCALAPPDATA 'ghost-cline-exe-identity'

function Get-ClineInstanceIdentityMap {
  # Per-clone exe-identity alias map (frozen cN keys; Blue..Orange display).
  return @{
    'c1' = @{ ExeName = 'Cline-Blue.exe';   DisplayName = 'Blue';   BrandingRepo = 'cline-blue-branding' }
    'c2' = @{ ExeName = 'Cline-Yellow.exe'; DisplayName = 'Yellow'; BrandingRepo = 'cline-yellow-branding' }
    'c3' = @{ ExeName = 'Cline-Green.exe';  DisplayName = 'Green';  BrandingRepo = 'cline-green-branding' }
    'c4' = @{ ExeName = 'Cline-Red.exe';    DisplayName = 'Red';    BrandingRepo = 'cline-red-branding' }
    'c5' = @{ ExeName = 'Cline-Orange.exe'; DisplayName = 'Orange'; BrandingRepo = 'cline-orange-branding' }
  }
}

function Resolve-ClineInstallDir {
  # Same ladder as the launcher's $ExePath. Requires the stock cline-app.exe.
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA 'Cline')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'cline-app.exe'))) {
      return $c
    }
  }
  throw 'Cline install not found. Pass -InstallDir <path> explicitly.'
}

function Invoke-ExeIdentityPatch {
  param([string]$InstallPath, [hashtable]$Cfg, [switch]$DryRun, [switch]$Force)
  return Invoke-GhostExeIdentityPatch `
    -SourceExe (Join-Path $InstallPath 'cline-app.exe') `
    -TargetExe (Join-Path $InstallPath $Cfg.ExeName) `
    -IcoPath (Join-Path (Join-Path $PSScriptRoot $Cfg.BrandingRepo) 'tray_icon.ico') `
    -FileDescription ("Cline " + $Cfg.DisplayName) `
    -ExeLabel $Cfg.ExeName `
    -TargetName $Target `
    -EngineVersion $script:EngineVersion `
    -SuiteProcessFamily 'Cline*' `
    -AuditDir $script:ClineAuditDir `
    -DryRun:$DryRun -Force:$Force
}

# ---- main ----------------------------------------------------------------

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$installPath = Resolve-ClineInstallDir -Override $InstallDir
$sourceExe = Join-Path $installPath 'cline-app.exe'
$srcItem = Get-Item -LiteralPath $sourceExe
Write-Host "install = $installPath"
Write-Host "source  = $sourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB, engine $script:EngineVersion)"
Write-Host 'NOTE   : repo-only + opt-in - no launcher wiring, no copies built automatically.'
if ($DryRun) { Write-Host 'mode    = DRY RUN (no writes)' -ForegroundColor Cyan }

$targets = @($Target)
if ($Target -eq 'All') { $targets = @('c1', 'c2', 'c3', 'c4', 'c5') }
$map = Get-ClineInstanceIdentityMap

$summary = @{ built = 0; fresh = 0; skipped = 0; dryrun = 0; failed = 0 }
foreach ($t in $targets) {
  $cfg = $map[$t]
  try {
    $result = Invoke-ExeIdentityPatch -InstallPath $installPath -Cfg $cfg -DryRun:$DryRun -Force:$Force
    if ($result -eq 'built') { $summary.built++ }
    elseif ($result -eq 'fresh') { $summary.fresh++ }
    elseif ($result -eq 'skip-running') { $summary.skipped++ }
    elseif ($result -eq 'dryrun') { $summary.dryrun++ }
  } catch {
    $summary.failed++
    Write-Host "[FAIL] $t ($($cfg.ExeName)): $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
    Write-GhostExeAuditLine -AuditDir $script:ClineAuditDir -Entry @{ target = $Target; exe = $cfg.ExeName; action = 'patch'; ok = 0; detail = $_.Exception.Message }
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host "dry run: $($summary.dryrun) target(s) would be rebuilt. Re-run without -DryRun to apply."
} else {
  Write-Host "summary: $($summary.built) built, $($summary.fresh) already fresh, $($summary.skipped) skipped (running), $($summary.failed) failed"
}
if ($summary.failed -gt 0) { exit 1 }
exit 0
