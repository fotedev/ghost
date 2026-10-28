#Requires -Version 5.1
<#
.SYNOPSIS
  Patches the installed AutoClaw app.asar (engine v11): MCP candidate ports
  4 -> 8 slots, home-override state-dir isolation, and per-clone taskbar
  identity (AUMID suffix + window icon + forced "AutoClaw <Color>" title).

.DESCRIPTION
  One-time app.asar patch (marker + -Restore + backup). The taskbar identity
  families read <userData>\.autoclaw-identity.json / .autoclaw-icon.ico,
  written by launch_autoclaw_clone.ps1 step 4c. See
  docs/AUTOCLAW_CLONES_SPEC.md sections 5.1, 5.3, 5.8 and 7.3c.

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
# App-update recovery (2026-10-24): the AutoClaw updater replaces app.asar and
# may also remove the marker/backups under resources\ID_Backups. The old
# "marker exists" gate therefore silently skipped re-patching after an update
# (clones kept stock window/tray identity; inst4 lost its widened MCP port and
# could not start a gateway). The script now byte-probes app.asar for the
# engine's signature strings BEFORE the gate, re-patches automatically when
# they are missing (no -Force needed) and takes a FRESH backup of the new
# pristine asar instead of reusing a pre-update backup.
$script:EngineVersion = 12
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
  $allProcs = @(Get-Process -Name "AutoClaw" -ErrorAction SilentlyContinue)
  $procs = @($allProcs |
    Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
  # Guard-strength (bug sweep 15): a process whose .Path is unreadable cannot
  # be classified - warn instead of silently skipping it.
  $unclassified = @($allProcs | Where-Object { -not $_.Path })
  if ($unclassified.Count -gt 0) {
    Write-Warning ("{0} AutoClaw process(es) exposed no readable path and were NOT checked (PID(s): {1}). If the asar swap fails with the file in use, close every AutoClaw instance and re-run." -f
      $unclassified.Count, (($unclassified | Select-Object -First 5 -ExpandProperty Id) -join ", "))
  }
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
    [long]$MinAsarBytes,
    [string]$BackupAsar
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
    # Roll the unpacked sidecar back first, then make sure app.asar itself
    # exists again: a failed Move-Item after a successful Remove-Item used to
    # leave the install with NO app.asar (hard brick until a manual -Restore;
    # bug sweep 15 HIGH).
    Remove-Item $unpacked -Recurse -Force
    Rename-Item $oldUnpacked "app.asar.unpacked"
    if (-not (Test-Path $asar)) {
      if ($BackupAsar -and (Test-Path $BackupAsar)) {
        try {
          Copy-Item $BackupAsar $asar -Force
          if (Test-Path $asar) {
            Write-Warning ("asar swap failed after the old app.asar was deleted; it was restored from backup '{0}'. Review the error above and run -Restore for a full rollback." -f $BackupAsar)
          } else {
            Write-Warning ("asar swap failed and the backup restore could not be verified - {0} may be MISSING. Restore it manually from '{1}'." -f $asar, $BackupAsar)
          }
        } catch {
          Write-Warning ("asar swap failed and the backup restore FAILED - {0} may be MISSING. Restore it manually from '{1}' ({2})." -f $asar, $BackupAsar, $_.Exception.Message)
        }
      } else {
        Write-Warning ("asar swap failed after the old app.asar was deleted and no backup asar was passed to restore from - {0} may be MISSING. Run -Restore." -f $asar)
      }
    }
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

$AutoClawInstall = Resolve-AutoClawInstallDir -Override $InstallDir
$AutoClawResources = Join-Path $AutoClawInstall "resources"
# node resolution (bug sweep 15): PATH first, then the app-bundled runtime -
# AutoClaw ships resources\node\node.exe (the same fallback reset_autoclaw.ps1
# uses for the ed25519 keygen). The bundled node can run the probe and the
# patch engine, but it cannot drive npx/@electron/asar, so a missing npx still
# aborts loudly below.
$bundledNode = Join-Path $AutoClawResources "node\node.exe"
$nodeCmd = Get-Command "node" -ErrorAction SilentlyContinue
if ($nodeCmd) {
  $NodeExe = $nodeCmd.Source
} elseif (Test-Path $bundledNode) {
  $NodeExe = $bundledNode
  Write-Host "node not on PATH - using the app-bundled runtime: $bundledNode"
} else {
  throw "node not found on PATH (needed to run the patch engine) and no app-bundled node at $bundledNode."
}
$script:NpxExe = Find-AutoClawTool "npx.cmd" "npx not found on PATH (needed for @electron/asar). The app-bundled node cannot substitute for it (npx needs its own npm install)."
$AutoClawAsar = Join-Path $AutoClawResources "app.asar"
$AutoClawMarker = Join-Path $AutoClawResources "autoclaw-ports-patch.marker.json"
$AutoClawBackups = Join-Path $AutoClawResources "ID_Backups"
$AutoClawEngine = Join-Path $PSScriptRoot "patch_autoclaw_ports.mjs"

Write-Host "Install dir : $AutoClawInstall"


if ($Restore) {
  Assert-AutoClawClosed -InstallPath $AutoClawInstall
  # Prefer the marker's backupDir (the backup the last patch run verified
  # against); fall back to the newest folder only when the marker is absent,
  # unreadable, or its backup no longer holds an app.asar (bug sweep 15).
  $backup = $null
  if (Test-Path $AutoClawMarker) {
    try {
      $restoreMarker = Get-Content -LiteralPath $AutoClawMarker -Raw | ConvertFrom-Json
      if ($restoreMarker.backupDir -and (Test-Path (Join-Path $restoreMarker.backupDir "app.asar"))) {
        $backup = Get-Item -LiteralPath $restoreMarker.backupDir
      }
    } catch { Write-Host "Marker unreadable - falling back to the newest backup folder." }
  }
  if (-not $backup) {
    $backup = Get-ChildItem -LiteralPath $AutoClawBackups -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | Where-Object { Test-Path (Join-Path $_.FullName "app.asar") } |
      Select-Object -First 1
  }
  if (-not $backup) { throw "No backup found under $AutoClawBackups - nothing to restore." }
  $restoreFloor = [long]([IO.File]::ReadAllBytes((Join-Path $backup.FullName "app.asar")).Length / 2)
  Write-Host "[1/2] Restoring app.asar + app.asar.unpacked from $($backup.Name) (staged copy)"
  $stage = Copy-AutoClawBackupToStaging -BackupDir $backup.FullName
  try {
    Invoke-AutoClawAsarSwap -ResourcesDir $AutoClawResources `
      -CandidateAsar (Join-Path $stage "app.asar") `
      -CandidateUnpacked (Join-Path $stage "app.asar.unpacked") `
      -MinAsarBytes $restoreFloor `
      -BackupAsar (Join-Path $backup.FullName "app.asar")
  } finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path $AutoClawMarker) { Remove-Item $AutoClawMarker -Force }
  Write-Host "[2/2] Marker removed."
  Write-Host "SUCCESS - original app.asar restored from $($backup.FullName)"
  exit 0
}

# Asar content probe: an app update replaces app.asar wholesale (and may drop
# the marker/backups too), so a surviving marker cannot prove the patch is
# alive. Every signature string must be present to call this tree patched.
# Node also exits 1 on uncaught exceptions, so the probe's TEXT must
# corroborate its exit code - a crash must never masquerade as "update-wiped".
Write-Host "[0/7] Probing app.asar for patch signatures..."
$AutoClawProbeOut = & $NodeExe -e "const fs=require('fs');try{const b=fs.readFileSync(process.argv[1]);const need=['__autoclawWrapBW','.autoclaw-identity.json','__autoclawHomeOverride','19684, 19685'];const missing=need.filter(s=>!b.includes(s));if(missing.length){console.log('MISSING '+missing.join(','));process.exit(1)}console.log('OK all-present');process.exit(0)}catch(e){console.error('PROBE_ERROR '+String((e&&e.message)||e));process.exit(3)}" $AutoClawAsar
$AutoClawProbeText = ($AutoClawProbeOut -join " ")
if ($LASTEXITCODE -eq 0 -and $AutoClawProbeText -match 'OK all-present') {
  $AutoClawAsarPatched = $true
} elseif ($LASTEXITCODE -eq 1 -and $AutoClawProbeText -match 'MISSING') {
  $AutoClawAsarPatched = $false
} else {
  throw ("app.asar probe failed (node exit {0}): {1}" -f $LASTEXITCODE, $AutoClawProbeText)
}
Write-Host ("      probe: {0}" -f $(if ($AutoClawAsarPatched) { "patch signatures present" } else { "patch signatures MISSING (fresh or update-wiped asar)" }))

$existingMarker = $null
$markerEngineVersion = 0
if (Test-Path $AutoClawMarker) {
  $markerEngineVersion = 1
  try {
    $existingMarker = Get-Content -LiteralPath $AutoClawMarker -Raw | ConvertFrom-Json
    if ($existingMarker.patchVersion) { $markerEngineVersion = [int]$existingMarker.patchVersion }
  } catch { Write-Host "Marker unreadable - will re-patch." }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $Force -and $AutoClawAsarPatched) {
    Write-Host "Already patched at engine v$markerEngineVersion (marker + asar signatures verified). Use -Force to re-patch."
    exit 0
  }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $AutoClawAsarPatched) {
    Write-Host "App update detected - patched asar replaced, marker stale - re-patching."
  }
  if ($markerEngineVersion -lt $script:EngineVersion) {
    Write-Host "Marker is engine v$markerEngineVersion - upgrading to v$script:EngineVersion (re-patching)."
  }
} else {
  Write-Host "No marker (fresh install or update-wiped) - patching."
}
Assert-AutoClawClosed -InstallPath $AutoClawInstall

$AutoClawStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$AutoClawUnpacked = Join-Path $AutoClawResources "app.asar.unpacked"
# Backup selection: a re-patch of a STILL-PATCHED tree (engine upgrade, probe
# present) keeps pointing at the ORIGINAL backup so -Restore returns to the
# pristine asar. An update-wiped tree (probe missing) is a NEW app version -
# folding it onto the old backup would let a later -Restore downgrade the app,
# so it gets a fresh timestamped backup and the marker points there.
$AutoClawBackupDir = Join-Path $AutoClawBackups $AutoClawStamp
$AutoClawReuseBackup = $false
if ($AutoClawAsarPatched -and $existingMarker -and $existingMarker.backupDir -and (Test-Path (Join-Path $existingMarker.backupDir "app.asar"))) {
  $AutoClawReuseBackup = $true
  $AutoClawBackupDir = $existingMarker.backupDir
  Write-Host "[1/7] Reusing original backup at $AutoClawBackupDir"
}
if (-not $AutoClawReuseBackup) {
  if (-not $AutoClawAsarPatched) { Write-Host "App-update recovery - backing up the new pristine asar." }
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
  # -Force re-patch must rebuild from the PRISTINE backup, never the live
  # asar: the engine treats already-wrapped BrowserWindow anchors as done,
  # so extracting the live (already-patched) file would keep the OLD
  # injected code forever (2026-10-18: two -Force runs shipped no changes).
  # Only rebuild from a backup when the LIVE asar is still engine-patched;
  # after an app update the live asar is the new pristine version and must be
  # the extract source (the backup would roll the app back a version).
  $extractSource = $AutoClawAsar
  if ($Force -and $AutoClawAsarPatched -and $existingMarker -and $existingMarker.backupDir) {
    $backupAsar = Join-Path $existingMarker.backupDir "app.asar"
    if (Test-Path $backupAsar) {
      $extractSource = $backupAsar
      Write-Host "[2/7] Extracting PRISTINE backup asar (live file is already engine-patched)..."
    } else {
      Write-Host "WARNING: marker's original backup is missing - extracting the live (patched) asar; the engine's done-anchors will skip already-patched sites."
    }
  }
  if ($extractSource -eq $AutoClawAsar) {
    Write-Host "[2/7] Extracting app.asar (takes a minute)..."
  }
  Invoke-AutoClawAsar @("--yes", "@electron/asar", "extract", $extractSource, $AutoClawExtracted)
  Write-Host "[3/7] Running patch engine (ports + home-override + taskbar identity)..."
  $engineOut = & $NodeExe $AutoClawEngine $AutoClawExtracted
  $engineJson = $null
  try { $engineJson = ($engineOut -join "`n") | ConvertFrom-Json } catch {
    throw ("patch engine returned invalid JSON: {0}" -f ($engineOut -join "`n"))
  }
  if (-not $engineJson.ok) {
    throw ("patch engine FAILED: {0} | totals: {1}" -f $engineJson.error, ($engineJson.totals | ConvertTo-Json -Compress))
  }

  $engineJson.results | ForEach-Object {
    $file = $_.file
    $counts = $_.counts
    $countsText = ($counts.PSObject.Properties | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join " "
    Write-Host ("      {0}: {1}" -f $file, $countsText)
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
  $unpackDirs = New-Object "System.Collections.Generic.List[string]"
  # mirror upstream repack: explicit prebuilds dirs present in the original sidecar
  $origUnpackedSet = if (Test-Path $AutoClawUnpacked) { Get-AutoClawRelPaths -Root $AutoClawUnpacked } else {
    New-Object "System.Collections.Generic.HashSet[string]"
  }
  $origUnpackedSet | ForEach-Object {
    if ($_ -match "^(node_modules/[^/]+/prebuilds/[^/]+)/") {
      $d = $Matches[1]
      if (-not $unpackDirs.Contains($d)) { [void]$unpackDirs.Add($d) }
    }
  }

  # Convergence loop (ported from patch_zcode_icon_override.ps1; bug sweep 15):
  # after each pack, every file of the ORIGINAL unpacked sidecar must exist in
  # the candidate sidecar; extensions still packed into the asar body are added
  # to the --unpack globs and the candidate is rebuilt (up to 4 tries). A file
  # that would silently vanish from the install aborts the patch on the last
  # try instead of passing the swap.
  $maxTries = 4
  for ($try = 1; $try -le $maxTries; $try++) {
    $packArgs = @("--yes", "@electron/asar", "pack", $AutoClawExtracted, $AutoClawCandidate)
    foreach ($g in $unpackGlobs) { $packArgs += "--unpack"; $packArgs += $g }
    foreach ($d in $unpackDirs) { $packArgs += "--unpack-dir"; $packArgs += $d }
    Invoke-AutoClawAsar $packArgs
    if (-not (Test-Path $AutoClawCandidate)) { throw "repack FAILED: candidate not written" }

    $candUnpackedSet = if (Test-Path $AutoClawCandidateUnpacked) { Get-AutoClawRelPaths -Root $AutoClawCandidateUnpacked } else {
      New-Object "System.Collections.Generic.HashSet[string]"
    }
    $missing = @($origUnpackedSet | Where-Object { -not $candUnpackedSet.Contains($_) })
    if ($missing.Count -eq 0) { break }
    if ($try -eq $maxTries) {
      throw ("repack verify FAILED: files missing from candidate unpacked sidecar: {0}" -f ($missing -join ", "))
    }
    # converge: unpack every extension the sidecar still lacks, then repack
    $newExts = @($missing | ForEach-Object { [IO.Path]::GetExtension($_).TrimStart(".") } | Sort-Object -Unique)
    foreach ($e in $newExts) {
      $glob = "*.$e"
      if (-not $unpackGlobs.Contains($glob)) { [void]$unpackGlobs.Add($glob) }
    }
    Write-Host ("      repack retry {0}: adding unpack for {1}" -f $try, ($newExts -join ","))
  }
  $candCount = if (Test-Path $AutoClawCandidateUnpacked) { (Get-AutoClawRelPaths -Root $AutoClawCandidateUnpacked).Count } else { 0 }
  Write-Host ("      unpacked sidecar files: {0} (original {1})" -f $candCount, $origUnpackedSet.Count)
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
  Invoke-AutoClawAsarSwap -ResourcesDir $AutoClawResources -CandidateAsar $AutoClawCandidate -CandidateUnpacked $AutoClawCandidateUnpacked -MinAsarBytes $patchFloor -BackupAsar (Join-Path $AutoClawBackupDir "app.asar")
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
Write-Host "SUCCESS - AutoClaw app patched (engine v$script:EngineVersion): MCP ports 8 slots + per-clone taskbar identity."



