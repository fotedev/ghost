#requires -Version 5.1
<#
.SYNOPSIS
  Builds per-clone OpenCode.exe copies ("OpenCode-Blue.exe" ...
  "OpenCode-Orange.exe") in the install dir and patches their embedded icon +
  FileDescription, so Windows Task Manager renders one colored, named group
  per clone instead of five identical stock "OpenCode (N)" rows.

.DESCRIPTION
  The generic Task-Manager exe identity core (tools\exe_identity_lib.ps1,
  live-verified on the ZCode suite 2026-11-11) applied to the OpenCode
  desktop app. Built REPO-ONLY and OPT-IN: nothing in this suite's launcher
  auto-wires it and no copies were built on the dev host.

  Same contract as the ZCode patcher: freshness marker "<exe>.ghost-id.json",
  running gate (skip-running), copy + one Win32 update transaction + full
  re-read verify-after + JSONL audit at
  %LOCALAPPDATA%\ghost-opencode-exe-identity. Install-dir ladder matches the
  launcher's $ExeCandidates.

  Menu: OpenCode Maintenance [13] (gid 107).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_opencode_exe_identity.ps1 -Target All -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_opencode_exe_identity.ps1 -Target c3
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
$script:OcAuditDir = Join-Path $env:LOCALAPPDATA 'ghost-opencode-exe-identity'

function Get-OpenCodeInstanceIdentityMap {
  # Per-clone exe-identity alias map (frozen cN keys; Blue..Orange display).
  return @{
    'c1' = @{ ExeName = 'OpenCode-Blue.exe';   DisplayName = 'Blue';   BrandingRepo = 'opencode-blue-branding' }
    'c2' = @{ ExeName = 'OpenCode-Yellow.exe'; DisplayName = 'Yellow'; BrandingRepo = 'opencode-yellow-branding' }
    'c3' = @{ ExeName = 'OpenCode-Green.exe';  DisplayName = 'Green';  BrandingRepo = 'opencode-green-branding' }
    'c4' = @{ ExeName = 'OpenCode-Red.exe';    DisplayName = 'Red';    BrandingRepo = 'opencode-red-branding' }
    'c5' = @{ ExeName = 'OpenCode-Orange.exe'; DisplayName = 'Orange'; BrandingRepo = 'opencode-orange-branding' }
  }
}

function Resolve-OpenCodeInstallDir {
  # Same candidate ladder as the launcher's $ExeCandidates. Requires the
  # stock OpenCode.exe.
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA 'Programs\@opencode-aidesktop'),
    (Join-Path $env:LOCALAPPDATA 'Programs\opencode')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'OpenCode.exe'))) {
      return $c
    }
  }
  throw 'OpenCode install not found. Pass -InstallDir <path> explicitly.'
}

function Invoke-ExeIdentityPatch {
  param([string]$InstallPath, [hashtable]$Cfg, [switch]$DryRun, [switch]$Force)
  return Invoke-GhostExeIdentityPatch `
    -SourceExe (Join-Path $InstallPath 'OpenCode.exe') `
    -TargetExe (Join-Path $InstallPath $Cfg.ExeName) `
    -IcoPath (Join-Path (Join-Path $PSScriptRoot $Cfg.BrandingRepo) 'tray_icon.ico') `
    -FileDescription ("OpenCode " + $Cfg.DisplayName) `
    -ExeLabel $Cfg.ExeName `
    -TargetName $Target `
    -EngineVersion $script:EngineVersion `
    -SuiteProcessFamily 'OpenCode*' `
    -AuditDir $script:OcAuditDir `
    -DryRun:$DryRun -Force:$Force
}

# ---- main ----------------------------------------------------------------

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$installPath = Resolve-OpenCodeInstallDir -Override $InstallDir
$sourceExe = Join-Path $installPath 'OpenCode.exe'
$srcItem = Get-Item -LiteralPath $sourceExe
Write-Host "install = $installPath"
Write-Host "source  = $sourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB, engine $script:EngineVersion)"
Write-Host 'NOTE   : repo-only + opt-in - no launcher wiring, no copies built automatically.'
if ($DryRun) { Write-Host 'mode    = DRY RUN (no writes)' -ForegroundColor Cyan }

$targets = @($Target)
if ($Target -eq 'All') { $targets = @('c1', 'c2', 'c3', 'c4', 'c5') }
$map = Get-OpenCodeInstanceIdentityMap

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
    Write-GhostExeAuditLine -AuditDir $script:OcAuditDir -Entry @{ target = $Target; exe = $cfg.ExeName; action = 'patch'; ok = 0; detail = $_.Exception.Message }
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
