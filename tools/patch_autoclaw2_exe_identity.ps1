#requires -Version 5.1
<#
.SYNOPSIS
  Builds per-clone AutoClaw2.exe copies ("AutoClaw2-Blue.exe" ...
  "AutoClaw2-Orange.exe") in the install dir and patches their embedded icon +
  FileDescription, so Windows Task Manager renders one colored, named group
  per clone instead of five identical stock "AutoClaw2 (N)" rows.

.DESCRIPTION
  The generic Task-Manager exe identity core (tools\exe_identity_lib.ps1,
  live-verified on the ZCode suite 2026-11-11) applied to AutoClaw2.
  Built REPO-ONLY and OPT-IN: nothing in this suite's launcher auto-wires it
  and no copies were built on the dev host - run this tool explicitly (or the
  AutoClaw2 submenu row) when Task-Manager identity is wanted on this suite.
  ~1.2 GB disk for the 5 copies (disk-only cost, no runtime overhead); the
  Primary keeps the stock exe; copies lose Authenticode validity.

  Same contract as the ZCode patcher: freshness marker
  "<exe>.ghost-id.json", running gate (skip-running), copy + one Win32
  update transaction + full re-read verify-after + JSONL audit at
  %LOCALAPPDATA%\ghost-autoclaw2-exe-identity. NEVER launched automatically:
  a copy only takes effect when a shortcut or the user starts it - the
  launcher is deliberately NOT wired to prefer the copies here.

  Menu: AutoClaw2 Maintenance [15] (gid 105).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_autoclaw2_exe_identity.ps1 -Target All -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_autoclaw2_exe_identity.ps1 -Target c1
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
$script:Ac2AuditDir = Join-Path $env:LOCALAPPDATA 'ghost-autoclaw2-exe-identity'

function Get-Ac2InstanceIdentityMap {
  # Per-clone exe-identity alias map (frozen cN keys; Blue..Orange display).
  # BrandingRepo must match tools\make_clone_icon.ps1 output dirs.
  return @{
    'c1' = @{ ExeName = 'AutoClaw2-Blue.exe';   DisplayName = 'Blue';   BrandingRepo = 'autoclaw2-blue-branding' }
    'c2' = @{ ExeName = 'AutoClaw2-Yellow.exe'; DisplayName = 'Yellow'; BrandingRepo = 'autoclaw2-yellow-branding' }
    'c3' = @{ ExeName = 'AutoClaw2-Green.exe';  DisplayName = 'Green';  BrandingRepo = 'autoclaw2-green-branding' }
    'c4' = @{ ExeName = 'AutoClaw2-Red.exe';    DisplayName = 'Red';    BrandingRepo = 'autoclaw2-red-branding' }
    'c5' = @{ ExeName = 'AutoClaw2-Orange.exe'; DisplayName = 'Orange'; BrandingRepo = 'autoclaw2-orange-branding' }
  }
}

function Resolve-Ac2InstallDir {
  # Same ladder as the launcher's $ExePath. Requires the stock AutoClaw2.exe.
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA 'Programs\AutoClaw2')
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'AutoClaw2.exe'))) {
      return $c
    }
  }
  throw 'AutoClaw2 install not found. Pass -InstallDir <path> explicitly.'
}

function Invoke-ExeIdentityPatch {
  param([string]$InstallPath, [hashtable]$Cfg, [switch]$DryRun, [switch]$Force)
  return Invoke-GhostExeIdentityPatch `
    -SourceExe (Join-Path $InstallPath 'AutoClaw2.exe') `
    -TargetExe (Join-Path $InstallPath $Cfg.ExeName) `
    -IcoPath (Join-Path (Join-Path $PSScriptRoot $Cfg.BrandingRepo) 'tray_icon.ico') `
    -FileDescription ("AutoClaw2 " + $Cfg.DisplayName) `
    -ExeLabel $Cfg.ExeName `
    -TargetName $Target `
    -EngineVersion $script:EngineVersion `
    -SuiteProcessFamily 'AutoClaw2*' `
    -AuditDir $script:Ac2AuditDir `
    -DryRun:$DryRun -Force:$Force
}

# ---- main ----------------------------------------------------------------

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

$installPath = Resolve-Ac2InstallDir -Override $InstallDir
$sourceExe = Join-Path $installPath 'AutoClaw2.exe'
$srcItem = Get-Item -LiteralPath $sourceExe
Write-Host "install = $installPath"
Write-Host "source  = $sourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB, engine $script:EngineVersion)"
Write-Host 'NOTE   : repo-only + opt-in - no launcher wiring, no copies built automatically.'
if ($DryRun) { Write-Host 'mode    = DRY RUN (no writes)' -ForegroundColor Cyan }

$targets = @($Target)
if ($Target -eq 'All') { $targets = @('c1', 'c2', 'c3', 'c4', 'c5') }
$map = Get-Ac2InstanceIdentityMap

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
    Write-GhostExeAuditLine -AuditDir $script:Ac2AuditDir -Entry @{ target = $Target; exe = $cfg.ExeName; action = 'patch'; ok = 0; detail = $_.Exception.Message }
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
