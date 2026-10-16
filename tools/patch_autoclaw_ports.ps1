#Requires -Version 5.1
<#
.SYNOPSIS
  Widens the installed AutoClaw app MCP candidate ports from 4 to 8 slots.

.DESCRIPTION
  One-time app.asar patch (marker + -Restore + backup). See
  docs/AUTOCLAW_CLONES_SPEC.md sections 5.1 and 7.3.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_autoclaw_ports.ps1
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$Force,
  [string]$InstallDir
)

$ErrorActionPreference = "Stop"

# Must match ENGINE_VERSION in patch_autoclaw_ports.mjs.
$script:EngineVersion = 10
$script:NpxExe = $null
function Resolve-AutoClawInstallDir {
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    "C:\Program Files\AutoClaw",
    "C:\Program Files (x86)\AutoClaw"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c "AutoClaw.exe")) -and (Test-Path (Join-Path $c "resources\app.asar"))) {
      return $c
    }
  }
  throw "AutoClaw install not found. Pass -InstallDir <path> explicitly."
}

function Assert-AutoClawClosed {
  param([string]$InstallPath)
  $procs = @(Get-Process -Name "AutoClaw" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
  if ($procs.Count -gt 0) {
    throw ("AutoClaw.exe from this install dir is running (PID(s): {0}). Close all its windows and try again." -f
      (($procs | Select-Object -First 5 -ExpandProperty Id) -join ", "))
  }
}

function Find-AutoClawTool {
  param([string]$Name, [string]$MissingMessage)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw $MissingMessage }
  return $cmd.Source
}

function Invoke-AutoClawAsar {
  param([string[]]$NpxArgs)
  & $script:NpxExe @NpxArgs
  if ($LASTEXITCODE -ne 0) {
    throw ("asar command failed (exit {0}): npx {1}" -f $LASTEXITCODE, ($NpxArgs -join " "))
  }
}

function Get-AutoClawRelPaths {
  param([string]$Root)
  $full = (Resolve-Path $Root).Path.TrimEnd("\")
  $len = $full.Length + 1
  $set = New-Object "System.Collections.Generic.HashSet[string]"
  Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
    [void]$set.Add($_.FullName.Substring($len).Replace("\", "/"))
  }
  return $set
}
function Invoke-AutoClawAsarSwap {
  param(
    [string]$ResourcesDir,
    [string]$CandidateAsar,
    [string]$CandidateUnpacked,
    [long]$MinAsarBytes
  )
  $asar = Join-Path $ResourcesDir "app.asar"
  $unpacked = Join-Path $ResourcesDir "app.asar.unpacked"
  $oldUnpacked = Join-Path $ResourcesDir "app.asar.unpacked.old"
  if (Test-Path $oldUnpacked) { Remove-Item $oldUnpacked -Recurse -Force }
  if (Test-Path $unpacked) { Rename-Item $unpacked "app.asar.unpacked.old" }
  if (-not (Test-Path $CandidateUnpacked)) {
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
  } else {
    Move-Item $CandidateUnpacked $unpacked
  }
  try {
    Remove-Item $asar -Force
    Move-Item $CandidateAsar $asar
  } catch {
    Remove-Item $unpacked -Recurse -Force
    Rename-Item $oldUnpacked "app.asar.unpacked"
    throw
  }
  Remove-Item $oldUnpacked -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path $asar) -or -not (Test-Path $unpacked)) { throw "post-swap verify FAILED: targets missing" }
  if ((Get-Item $asar).Length -lt $MinAsarBytes) {
    throw "post-swap verify FAILED: app.asar suspiciously small. Run with -Restore."
  }
}
function Copy-AutoClawBackupToStaging {
  param([string]$BackupDir)
  $stage = Join-Path $env:TEMP ("autoclaw-ports-restore-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  Copy-Item (Join-Path $BackupDir "app.asar") (Join-Path $stage "app.asar")
  if (Test-Path (Join-Path $BackupDir "app.asar.unpacked")) {
    Copy-Item (Join-Path $BackupDir "app.asar.unpacked") (Join-Path $stage "app.asar.unpacked") -Recurse
  } else {
    New-Item -ItemType Directory -Path (Join-Path $stage "app.asar.unpacked") -Force | Out-Null
  }
  return $stage
}

$NodeExe = Find-AutoClawTool "node" "node not found on PATH (needed to run the patch engine)."
$script:NpxExe = Find-AutoClawTool "npx.cmd" "npx not found on PATH (needed for @electron/asar)."
$AutoClawInstall = Resolve-AutoClawInstallDir -Override $InstallDir
$AutoClawResources = Join-Path $AutoClawInstall "resources"
$AutoClawAsar = Join-Path $AutoClawResources "app.asar"
$AutoClawMarker = Join-Path $AutoClawResources "autoclaw-ports-patch.marker.json"
$AutoClawBackups = Join-Path $AutoClawResources "ID_Backups"
$AutoClawEngine = Join-Path $PSScriptRoot "patch_autoclaw_ports.mjs"

Write-Host "Install dir : $AutoClawInstall"


if ($Restore) {
  Assert-AutoClawClosed -InstallPath $AutoClawInstall
  $backup = Get-ChildItem -LiteralPath $AutoClawBackups -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Where-Object { Test-Path (Join-Path $_.FullName "app.asar") } |
    Select-Object -First 1
  if (-not $backup) { throw "No backup found under $AutoClawBackups - nothing to restore." }
  $restoreFloor = [long]([IO.File]::ReadAllBytes((Join-Path $backup.FullName "app.asar")).Length / 2)
  Write-Host "[1/2] Restoring app.asar + app.asar.unpacked from $($backup.Name) (staged copy)"
  $stage = Copy-AutoClawBackupToStaging -BackupDir $backup.FullName
  try {
    Invoke-AutoClawAsarSwap -ResourcesDir $AutoClawResources `
      -CandidateAsar (Join-Path $stage "app.asar") `
      -CandidateUnpacked (Join-Path $stage "app.asar.unpacked") `
      -MinAsarBytes $restoreFloor
  } finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path $AutoClawMarker) { Remove-Item $AutoClawMarker -Force }
  Write-Host "[2/2] Marker removed."
  Write-Host "SUCCESS - original app.asar restored from $($backup.FullName)"
  exit 0
}

$existingMarker = $null
if (Test-Path $AutoClawMarker) {
  $markerEngineVersion = 1
  try {
    $existingMarker = Get-Content -LiteralPath $AutoClawMarker -Raw | ConvertFrom-Json
    if ($existingMarker.patchVersion) { $markerEngineVersion = [int]$existingMarker.patchVersion }
  } catch { Write-Host "Marker unreadable - will re-patch." }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $Force) {
    Write-Host "Already patched at engine v$markerEngineVersion (marker exists). Use -Force to re-patch."
    exit 0
  }
}
Assert-AutoClawClosed -InstallPath $AutoClawInstall

$AutoClawStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$AutoClawUnpacked = Join-Path $AutoClawResources "app.asar.unpacked"
$AutoClawBackupDir = Join-Path $AutoClawBackups $AutoClawStamp
if ($existingMarker -and $existingMarker.backupDir -and (Test-Path (Join-Path $existingMarker.backupDir "app.asar"))) {
  $AutoClawBackupDir = $existingMarker.backupDir
  Write-Host "[1/7] Reusing original backup at $AutoClawBackupDir"
} else {
  Write-Host "[1/7] Backup to $AutoClawBackupDir"
  New-Item -ItemType Directory -Path $AutoClawBackupDir -Force | Out-Null
  Copy-Item $AutoClawAsar (Join-Path $AutoClawBackupDir "app.asar")
  if (Test-Path $AutoClawUnpacked) {
    Copy-Item $AutoClawUnpacked (Join-Path $AutoClawBackupDir "app.asar.unpacked") -Recurse
  }
  if (-not (Test-Path (Join-Path $AutoClawBackupDir "app.asar"))) { throw "backup verify FAILED: app.asar not copied" }
}


$AutoClawWork = Join-Path $env:TEMP ("autoclaw-ports-patch-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$AutoClawExtracted = Join-Path $AutoClawWork "extracted"
$AutoClawCandidate = Join-Path $AutoClawWork "app.asar.candidate"
$AutoClawCandidateUnpacked = "$AutoClawCandidate.unpacked"

try {
  New-Item -ItemType Directory -Path $AutoClawWork -Force | Out-Null
  Write-Host "[2/7] Extracting app.asar (takes a minute)..."
  Invoke-AutoClawAsar @("--yes", "@electron/asar", "extract", $AutoClawAsar, $AutoClawExtracted)
  Write-Host "[3/7] Widening MCP candidate ports 4 -> 8 slots..."
  $engineOut = & $NodeExe $AutoClawEngine $AutoClawExtracted
  $engineJson = $null
  try { $engineJson = ($engineOut -join "`n") | ConvertFrom-Json } catch {
    throw ("patch engine returned invalid JSON: {0}" -f ($engineOut -join "`n"))
  }
  if (-not $engineJson.ok) {
    throw ("patch engine FAILED: {0} | totals: {1}" -f $engineJson.error, ($engineJson.totals | ConvertTo-Json -Compress))
  }

  $engineJson.results | ForEach-Object {
    Write-Host ("      {0}: mcp-ports-8slot={1}" -f $_.file, $_.counts."mcp-ports-8slot")
  }
  foreach ($r in $engineJson.results) {
    if (-not $r.appliedMarkers -or @($r.appliedMarkers).Count -eq 0) { continue }
    $patchedFile = Join-Path $AutoClawExtracted ($r.file -replace "/", "\")
    $content = [IO.File]::ReadAllText($patchedFile)
    foreach ($marker in $r.appliedMarkers) {
      if (-not $content.Contains($marker)) {
        throw ("patch verify FAILED after write: marker '{0}' missing in {1}" -f $marker, $r.file)
      }
    }
  }
  foreach ($r in $engineJson.results) {
    if ($r.file -notmatch "\.(js|cjs|mjs)$") { continue }
    $syntaxFile = Join-Path $AutoClawExtracted ($r.file -replace "/", "\")
    $checkOut = cmd /c "`"$NodeExe`" --check `"$syntaxFile`" 2>&1" | Out-String
    if ($LASTEXITCODE -ne 0) {
      throw ("patch verify FAILED: node --check rejected {0}`n{1}" -f $r.file, $checkOut.Trim())
    }
    Write-Host ("      {0}: node --check OK" -f $r.file)
  }
  Write-Host "[4/7] Packing candidate asar..."
  $unpackGlobs = New-Object "System.Collections.Generic.List[string]"
  $unpackGlobs.Add("*.{node,dll,dylib,exe}")
  $origUnpackedSet = Get-AutoClawRelPaths -Root $AutoClawUnpacked
  for ($try = 1; $try -le 4; $try++) {
    $packArgs = @("--yes", "@electron/asar", "pack", $AutoClawExtracted, $AutoClawCandidate)
    foreach ($g in $unpackGlobs) { $packArgs += "--unpack"; $packArgs += $g }
    Invoke-AutoClawAsar $packArgs
    if (-not (Test-Path $AutoClawCandidate)) { throw "repack FAILED: candidate not written" }
    break
  }
  Write-Host "[5/7] Verifying candidate asar contents..."
  $AutoClawVerify = Join-Path $AutoClawWork "verify"
  foreach ($r in $engineJson.results) {
    if (-not $r.appliedMarkers -or @($r.appliedMarkers).Count -eq 0) { continue }
    New-Item -ItemType Directory -Path $AutoClawVerify -Force | Out-Null
    Get-ChildItem -LiteralPath $AutoClawVerify -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $relWin = $r.file -replace "/", "\"
    Push-Location $AutoClawVerify
    try {
      Invoke-AutoClawAsar @("--yes", "@electron/asar", "extract-file", $AutoClawCandidate, $relWin)
    } finally { Pop-Location }
    $verifyFile = Get-ChildItem -LiteralPath $AutoClawVerify -Recurse -File |
      Where-Object { $_.Name -eq (Split-Path -Leaf $relWin) } | Select-Object -First 1
    if (-not $verifyFile) { throw "patch verify FAILED: could not extract $($r.file) from candidate" }
    $vc = [IO.File]::ReadAllText($verifyFile.FullName)
    foreach ($marker in $r.appliedMarkers) {
      if (-not $vc.Contains($marker)) {
        throw ("patch verify FAILED inside candidate asar: marker '{0}' missing in {1}" -f $marker, $r.file)
      }
    }
    Write-Host ("      {0}: markers verified" -f $r.file)
  }
  Write-Host "[6/7] Swapping patched asar into install..."
  $patchFloor = [long]((Get-Item $AutoClawAsar).Length / 2)
  Invoke-AutoClawAsarSwap -ResourcesDir $AutoClawResources -CandidateAsar $AutoClawCandidate -CandidateUnpacked $AutoClawCandidateUnpacked -MinAsarBytes $patchFloor
  Write-Host "[7/7] Writing marker..."
  $marker = [ordered]@{
    appliedAt    = (Get-Date -Format "o")
    patchVersion = [int]$engineJson.engineVersion
    installDir   = $AutoClawInstall
    backupDir    = $AutoClawBackupDir
    patchedFiles = @($engineJson.results | ForEach-Object { $_.file })
    totals       = $engineJson.totals
  }
  $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $AutoClawMarker -Encoding UTF8
  if (-not (Test-Path $AutoClawMarker)) { throw "marker verify FAILED: not written" }
} finally {
  if (Test-Path $AutoClawWork) { Remove-Item $AutoClawWork -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "SUCCESS - AutoClaw MCP ports widened 4 -> 8 slots (19681..19688)."



