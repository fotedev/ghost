#requires -Version 5.1
<#
.SYNOPSIS
  Builds per-clone ZCode.exe copies ("ZCode-Blue.exe" ... "ZCode-Orange.exe")
  in the install dir and patches their embedded icon + FileDescription, so
  Windows Task Manager renders one colored, named group per clone instead of
  six identical stock "ZCode (N)" rows.

.DESCRIPTION
  Task Manager's background-process groups take their display name and icon
  from the executable IMAGE itself (VERSIONINFO FileDescription + embedded
  icon resource) - not from AUMID shortcuts or window properties. All six
  instances run the same ZCode.exe, so the taskbar identity stack (per-clone
  AUMIDs, colored shortcuts, window stamping, ZCODE_ICON_DIR window/tray
  icons) colors the taskbar and the app rows but leaves every background
  group identical. This tool closes that gap:

    1. copies the stock ZCode.exe -> "ZCode-<Color>.exe" (same install dir, so
       all sibling support files resolve exactly like the stock exe),
    2. replaces the RT_GROUP_ICON + RT_ICON resources with the frames of
       tools\<color>-branding\tray_icon.ico (Win32 UpdateResource via P/Invoke,
       PS 5.1-safe),
    3. re-serializes the VERSIONINFO resource with FileDescription
       "ZCode <Color>",
    4. verifies AFTER writing: group bytes re-read from the file must equal the
       built blob, new RT_ICONs must exist, old RT_ICONs must be gone,
       FileDescription must read back exactly and ProductName/FileVersion must
       be unchanged. Any miss = loud FAILED + audit entry + exit 1 - never
       silent success.

  Since 2026-11-14 ALL of steps 2-4 (plus the freshness gate, running gate,
  copy, sidecar marker and JSONL audit) live in the GENERIC core
  tools\exe_identity_lib.ps1 (Invoke-GhostExeIdentityPatch) shared by the
  AutoClaw2 / Cline / OpenCode patchers; this wrapper supplies only the ZCode
  instance map, install-dir resolution and engine version. Behavior is
  byte-identical to the pre-extraction live-verified flow (the pure core is
  test-pinned by tests\zcode_exe_identity.Tests.ps1, which exercises the
  generic lib transitively through tools\zcode_exe_identity_lib.ps1).

  Drift / self-heal: a sidecar "<exe>.ghost-id.json" marker carries the source
  exe size + mtime + SHA256 and the branding-ico SHA256. The launcher's
  pre-launch step (launch_zcode_second_instance.ps1 step 2f) fast-checks the
  marker and re-invokes this tool on drift (app update replaced ZCode.exe, or
  the branding icon changed, or the engine version bumped).

  The stock ZCode.exe is NEVER touched, so the Primary keeps its stock Task
  Manager identity. Copies lose their Authenticode validity (resource edits
  invalidate the signature hash) - on AV-protected machines SmartScreen may
  prompt on first launch; this dev box runs no AV (see the docs note).

  Exit codes: 0 = every target fresh, patched, dry-run or skipped-because-
  running; 1 = any hard failure (verify miss, patch failure, missing input).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_exe_identity.ps1 -Target Fourth
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_exe_identity.ps1 -Target All -DryRun
#>
[CmdletBinding()]
param(
  [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
  [string]$Target = 'All',
  [string]$InstallDir,
  [switch]$DryRun,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'zcode_exe_identity_lib.ps1')

# Engine version: bump to force a rebuild of every copy on the next run/launch.
# v1 (2026-11-11): initial icon-group replacement + FileDescription patch.
$script:EngineVersion = 1

$script:ZcodeAuditDir = Join-Path $env:LOCALAPPDATA 'ghost-zcode-exe-identity'

function Set-GhostConsoleUtf8 {
  # PS 5.1 decodes native stdout with the console encoding; make it UTF-8 so
  # colored output and paths survive. (Same helper name as identity_utils.ps1.)
  try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
  } catch { }
}

function Resolve-ZcodeInstallDir {
  # Same candidate ladder as patch_zcode_icon_override.ps1 so both tools agree
  # on the install dir. Requires the stock ZCode.exe (the copy source).
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA 'Programs\ZCode'),
    'C:\Program Files\ZCode',
    'C:\Program Files (x86)\ZCode'
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath (Join-Path $c 'ZCode.exe'))) {
      return $c
    }
  }
  throw 'ZCode install not found. Pass -InstallDir <path> explicitly.'
}

function Invoke-ExeIdentityPatch {
  # One clone target: a thin forwarder onto the generic core - the suite
  # supplies only the paths, description, process family and audit dir.
  param([string]$InstallPath, [hashtable]$Cfg, [switch]$DryRun, [switch]$Force)

  return Invoke-GhostExeIdentityPatch `
    -SourceExe (Join-Path $InstallPath 'ZCode.exe') `
    -TargetExe (Join-Path $InstallPath $Cfg.ExeName) `
    -IcoPath (Join-Path (Join-Path $PSScriptRoot $Cfg.BrandingRepo) 'tray_icon.ico') `
    -FileDescription ("ZCode " + $Cfg.DisplayName) `
    -ExeLabel $Cfg.ExeName `
    -TargetName $Target `
    -EngineVersion $script:EngineVersion `
    -SuiteProcessFamily 'ZCode*' `
    -AuditDir $script:ZcodeAuditDir `
    -DryRun:$DryRun -Force:$Force
}

# ---- main ----------------------------------------------------------------

Set-GhostConsoleUtf8 | Out-Null

$installPath = Resolve-ZcodeInstallDir -Override $InstallDir
$sourceExe = Join-Path $installPath 'ZCode.exe'
$srcItem = Get-Item -LiteralPath $sourceExe
Write-Host "install = $installPath"
Write-Host "source  = $sourceExe ($([Math]::Round($srcItem.Length / 1MB, 1)) MB, engine $script:EngineVersion)"
if ($DryRun) { Write-Host 'mode    = DRY RUN (no writes)' -ForegroundColor Cyan }

$targets = @($Target)
if ($Target -eq 'All') { $targets = @('Second', 'Third', 'Fourth', 'Fifth', 'Sixth') }
$map = Get-ZcodeInstanceIdentityMap

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
    Write-GhostExeAuditLine -AuditDir $script:ZcodeAuditDir -Entry @{ target = $Target; exe = $cfg.ExeName; action = 'patch'; ok = 0; detail = $_.Exception.Message }
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
