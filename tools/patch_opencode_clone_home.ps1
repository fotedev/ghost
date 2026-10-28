#Requires -Version 5.1
<#
.SYNOPSIS
  Patches the installed OpenCode desktop app.asar (engine v1): clone-home
  multi-instance isolation + per-clone taskbar identity.

.DESCRIPTION
  One-time app.asar patch (marker + -Restore + backup), mirroring
  patch_autoclaw_ports.ps1 machinery. See docs/OPENCODE_CLONES_SPEC.md:
    clone-home      the app's packaged bootstrap hardcodes
                    userData = %APPDATA%\ai.opencode.desktop; the patch gives
                    it the TEST_ROOT-equivalent via an argv scan of
                    --opencode-clone-home=<dir> at the app's own ye() branch,
                    so userData/sessionData + the XDG_* CLI-state homes all
                    become per-clone. No flag = bit-for-bit stock behavior.
    clone-identity  the single setAppUserModelId site is wrapped to append
                    ".<aumidSuffix>" and an app-level browser-window-created
                    listener stamps every window's AUMID/icon/title from
                    <cloneHome>\desktop\.opencode-clone-identity.json
                    (written by launch_opencode_clone.ps1).

  App-update recovery (2026-10-24 pattern): the updater replaces app.asar
  wholesale; the script byte-probes for the engine's signature strings
  BEFORE the marker gate and re-patches automatically (fresh backup of the
  new pristine asar) when they are missing.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_opencode_clone_home.ps1
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$Force,
  [string]$InstallDir
)

$ErrorActionPreference = "Stop"

# Must match ENGINE_VERSION in patch_opencode_clone_home.mjs.
$script:EngineVersion = 2
$script:NpxExe = $null
function Resolve-OpenCodeInstallDir {
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA "Programs\@opencode-aidesktop"),
    (Join-Path $env:LOCALAPPDATA "Programs\opencode")
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c "OpenCode.exe")) -and (Test-Path (Join-Path $c "resources\app.asar"))) {
      return $c
    }
  }
  throw "OpenCode install not found. Pass -InstallDir <path> explicitly."
}

function Assert-OpenCodeClosed {
  param([string]$InstallPath)
  $procs = @(Get-Process -Name "OpenCode" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
  if ($procs.Count -gt 0) {
    throw ("OpenCode.exe from this install dir is running (PID(s): {0}). Close all its windows and try again." -f
      (($procs | Select-Object -First 5 -ExpandProperty Id) -join ", "))
  }
}

function Find-OpenCodeTool {
  param([string]$Name, [string]$MissingMessage)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw $MissingMessage }
  return $cmd.Source
}

function Invoke-OpenCodeAsar {
  param([string[]]$NpxArgs)
  & $script:NpxExe @NpxArgs
  if ($LASTEXITCODE -ne 0) {
    throw ("asar command failed (exit {0}): npx {1}" -f $LASTEXITCODE, ($NpxArgs -join " "))
  }
}

function Get-OpenCodeRelPaths {
  param([string]$Root)
  $full = (Resolve-Path $Root).Path.TrimEnd("\")
  $len = $full.Length + 1
  $set = New-Object "System.Collections.Generic.HashSet[string]"
  Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
    [void]$set.Add($_.FullName.Substring($len).Replace("\", "/"))
  }
  return $set
}
function Invoke-OpenCodeAsarSwap {
  param(
    [string]$ResourcesDir,
    [string]$CandidateAsar,
    [string]$CandidateUnpacked,
    [long]$MinAsarBytes,
    [string]$BackupDir
  )
  $asar = Join-Path $ResourcesDir "app.asar"
  $unpacked = Join-Path $ResourcesDir "app.asar.unpacked"

  # asar swap. Delete+move is the clean path; when another process holds the
  # asar WITHOUT share-delete (indexers/AV do this - observed live: the host
  # IDE's file indexer kept a read handle for minutes), delete is impossible
  # but WRITE access may still be shared - then an in-place overwrite of the
  # live file is used, allowed ONLY with a verified pristine backup on disk
  # (the fallback never runs backup-less; the backup is the rollback).
  try {
    Remove-Item $asar -Force
    Move-Item $CandidateAsar $asar
  } catch {
    if ($_.Exception -isnot [System.IO.IOException]) { throw }
    if (-not (Test-Path $asar)) {
      # rare: delete succeeded, the move did not - retry the plain move
      Move-Item $CandidateAsar $asar
    } else {
      if (-not $BackupDir -or -not (Test-Path (Join-Path $BackupDir "app.asar"))) {
        throw "app.asar is locked by another process and no pristine backup exists to authorize the in-place fallback - resolve the lock and retry."
      }
      $liveLen = (Get-Item $asar).Length
      if ((Get-Item $CandidateAsar).Length -lt ($liveLen / 2)) {
        throw "candidate asar suspiciously small vs the live file - refusing the locked-asar in-place fallback."
      }
      Write-Host "      app.asar delete blocked (locked by another process) - overwriting IN PLACE (pristine backup verified: $BackupDir)"
      $srcStream = [IO.File]::OpenRead($CandidateAsar)
      $dstStream = [IO.File]::Open($asar, 'Open', 'Write', 'Read')
      try {
        $srcStream.CopyTo($dstStream)
        $dstStream.SetLength($srcStream.Length)
        $dstStream.Flush()
      } finally {
        $dstStream.Dispose()
        $srcStream.Dispose()
      }
    }
  }

  # unpacked dir swap; if the ORIGINAL is locked too, keeping it is correct
  # (this engine changes no unpacked-file bytes) - verify equality instead.
  $oldUnpacked = Join-Path $ResourcesDir "app.asar.unpacked.old"
  $unpackedKept = $false
  if (Test-Path $CandidateUnpacked) {
    try {
      if (Test-Path $oldUnpacked) { Remove-Item $oldUnpacked -Recurse -Force }
      if (Test-Path $unpacked) { Rename-Item $unpacked "app.asar.unpacked.old" }
      Move-Item $CandidateUnpacked $unpacked
      Remove-Item $oldUnpacked -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
      if ($_.Exception -isnot [System.IO.IOException]) { throw }
      if (-not (Test-Path $unpacked)) { throw }
      $unpackedKept = $true
      $orig = Get-ChildItem -LiteralPath $CandidateUnpacked -Recurse -File
      foreach ($f in $orig) {
        $rel = $f.FullName.Substring($CandidateUnpacked.Length).TrimStart("\")
        $live = Join-Path $unpacked $rel
        if (-not (Test-Path $live)) { throw "unpacked keep-verify FAILED: $rel missing from the live unpacked dir" }
        if ((Get-Item $live).Length -ne $f.Length) { throw "unpacked keep-verify FAILED: $rel size mismatch" }
      }
      Remove-Item $CandidateUnpacked -Recurse -Force -ErrorAction SilentlyContinue
      Write-Host "      unpacked dir locked too - original kept (engine changes no unpacked bytes; $($orig.Count) files size-verified)"
    }
  } elseif (-not (Test-Path $unpacked)) {
    New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
  }

  if (-not (Test-Path $asar) -or -not (Test-Path $unpacked)) { throw "post-swap verify FAILED: targets missing" }
  if ((Get-Item $asar).Length -lt $MinAsarBytes) {
    throw "post-swap verify FAILED: app.asar suspiciously small. Run with -Restore."
  }
}
function Copy-OpenCodeBackupToStaging {
  param([string]$BackupDir)
  $stage = Join-Path $env:TEMP ("opencode-clone-home-restore-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  Copy-Item (Join-Path $BackupDir "app.asar") (Join-Path $stage "app.asar")
  if (Test-Path (Join-Path $BackupDir "app.asar.unpacked")) {
    Copy-Item (Join-Path $BackupDir "app.asar.unpacked") (Join-Path $stage "app.asar.unpacked") -Recurse
  } else {
    New-Item -ItemType Directory -Path (Join-Path $stage "app.asar.unpacked") -Force | Out-Null
  }
  return $stage
}

$NodeExe = Find-OpenCodeTool "node" "node not found on PATH (needed to run the patch engine)."
$script:NpxExe = Find-OpenCodeTool "npx.cmd" "npx not found on PATH (needed for @electron/asar)."
$OcInstall = Resolve-OpenCodeInstallDir -Override $InstallDir
$OcResources = Join-Path $OcInstall "resources"
$OcAsar = Join-Path $OcResources "app.asar"
$OcMarker = Join-Path $OcResources "opencode-clone-home-patch.marker.json"
$OcBackups = Join-Path $OcResources "ID_Backups"
$OcEngine = Join-Path $PSScriptRoot "patch_opencode_clone_home.mjs"

Write-Host "Install dir : $OcInstall"


if ($Restore) {
  Assert-OpenCodeClosed -InstallPath $OcInstall
  $backup = Get-ChildItem -LiteralPath $OcBackups -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Where-Object { Test-Path (Join-Path $_.FullName "app.asar") } |
    Select-Object -First 1
  if (-not $backup) { throw "No backup found under $OcBackups - nothing to restore." }
  $restoreFloor = [long]([IO.File]::ReadAllBytes((Join-Path $backup.FullName "app.asar")).Length / 2)
  Write-Host "[1/2] Restoring app.asar + app.asar.unpacked from $($backup.Name) (staged copy)"
  $stage = Copy-OpenCodeBackupToStaging -BackupDir $backup.FullName
  try {
    Invoke-OpenCodeAsarSwap -ResourcesDir $OcResources `
      -CandidateAsar (Join-Path $stage "app.asar") `
      -CandidateUnpacked (Join-Path $stage "app.asar.unpacked") `
      -MinAsarBytes $restoreFloor `
      -BackupDir $backup.FullName
  } finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path $OcMarker) { Remove-Item $OcMarker -Force }
  Write-Host "[2/2] Marker removed."
  Write-Host "SUCCESS - original app.asar restored from $($backup.FullName)"
  exit 0
}

# Asar content probe (two tiers): an app update replaces app.asar wholesale
# (and may drop the marker/backups too), so a surviving marker cannot prove
# the patch is alive. CORE signatures are engine-STABLE (emitted by every
# engine version so far) - their presence means "patched at SOME engine";
# CURRENT signatures are this engine's additions - their presence upgrades
# that to "patched at THIS engine". The distinction decides the extract
# source for engine upgrades: a core-only tree is an OLD-ENGINE patch, not a
# pristine asar, and must be rebuilt from the marker's pristine backup
# (extracting the live tree would let the engine's done-anchors skip and
# ship no changes - caught live 2026-10-24).
$OcProbeOut = & $NodeExe -e "const fs=require('fs');try{const b=fs.readFileSync(process.argv[1]);const core=['__opencodeCloneHome','__opencodeCloneIdentity','--opencode-clone-home'];const cur=['--opencode-clone-id'];const cm=core.filter(s=>!b.includes(s));const km=cur.filter(s=>!b.includes(s));console.log('CORE='+(cm.length?'MISSING':'OK')+' CUR='+(km.length?'MISSING':'OK'));process.exit(0)}catch(e){console.error('PROBE_ERROR '+String((e&&e.message)||e));process.exit(3)}" $OcAsar
$OcProbeText = ($OcProbeOut -join " ")
if ($LASTEXITCODE -ne 0 -or $OcProbeText -notmatch 'CORE=\w+ CUR=\w+') {
  throw ("app.asar probe failed (node exit {0}): {1}" -f $LASTEXITCODE, $OcProbeText)
}
$OcCorePatched = ($OcProbeText -match 'CORE=OK')
$OcAsarPatched = ($OcProbeText -match 'CORE=OK CUR=OK')
$OcProbeNote = if ($OcAsarPatched) { "patched at engine v$script:EngineVersion" }
  elseif ($OcCorePatched) { "OLD-ENGINE patch (current engine signatures missing)" }
  else { "no engine signatures (fresh or update-wiped asar)" }
Write-Host ("      probe: {0}" -f $OcProbeNote)

$existingMarker = $null
$markerEngineVersion = 0
if (Test-Path $OcMarker) {
  $markerEngineVersion = 1
  try {
    $existingMarker = Get-Content -LiteralPath $OcMarker -Raw | ConvertFrom-Json
    if ($existingMarker.patchVersion) { $markerEngineVersion = [int]$existingMarker.patchVersion }
  } catch { Write-Host "Marker unreadable - will re-patch." }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $Force -and $OcAsarPatched) {
    Write-Host "Already patched at engine v$markerEngineVersion (marker + asar signatures verified). Use -Force to re-patch."
    exit 0
  }
  if ($OcCorePatched -and -not $OcAsarPatched) {
    Write-Host "Old-engine patch detected - upgrading to v$script:EngineVersion (rebuilding from the pristine backup)."
  }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $OcCorePatched) {
    Write-Host "App update detected - patched asar replaced, marker stale - re-patching."
  }
  if ($markerEngineVersion -lt $script:EngineVersion -and $OcCorePatched) {
    Write-Host "Marker is engine v$markerEngineVersion - upgrading to v$script:EngineVersion (re-patching)."
  }
} elseif ($OcCorePatched) {
  Write-Host "No marker but the asar carries engine signatures - treating as an old-engine patch (backup from the marker era is unknown; -Restore has nothing to return to)."
} else {
  Write-Host "No marker (fresh install or update-wiped) - patching."
}
Assert-OpenCodeClosed -InstallPath $OcInstall

$OcStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OcUnpacked = Join-Path $OcResources "app.asar.unpacked"
# Backup selection: a re-patch of a STILL-PATCHED tree (current OR old engine)
# keeps pointing at the ORIGINAL backup so -Restore returns to the pristine
# asar. An update-wiped tree is a NEW app version - it gets a fresh timestamped
# backup (folding it onto the old backup would let a later -Restore downgrade
# the app).
$OcBackupDir = Join-Path $OcBackups $OcStamp
$OcReuseBackup = $false
if ($OcCorePatched -and $existingMarker -and $existingMarker.backupDir -and (Test-Path (Join-Path $existingMarker.backupDir "app.asar"))) {
  $OcReuseBackup = $true
  $OcBackupDir = $existingMarker.backupDir
  Write-Host "[1/7] Reusing original backup at $OcBackupDir"
}
if (-not $OcReuseBackup) {
  if ($OcCorePatched) { Write-Host "WARNING: patched tree but no usable marker backup - the new backup captures the CURRENT (patched) asar; -Restore will return here, not to the vendor asar." }
  Write-Host "[1/7] Backup to $OcBackupDir"
  New-Item -ItemType Directory -Path $OcBackupDir -Force | Out-Null
  Copy-Item $OcAsar (Join-Path $OcBackupDir "app.asar")
  if (Test-Path $OcUnpacked) {
    Copy-Item $OcUnpacked (Join-Path $OcBackupDir "app.asar.unpacked") -Recurse
  }
  if (-not (Test-Path (Join-Path $OcBackupDir "app.asar"))) { throw "backup verify FAILED: app.asar not copied" }
}


$OcWork = Join-Path $env:TEMP ("opencode-clone-home-patch-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$OcExtracted = Join-Path $OcWork "extracted"
$OcCandidate = Join-Path $OcWork "app.asar.candidate"
$OcCandidateUnpacked = "$OcCandidate.unpacked"

try {
  New-Item -ItemType Directory -Path $OcWork -Force | Out-Null
  # A rebuild of an ALREADY-PATCHED tree (engine upgrade via the marker, or
  # -Force) must extract the PRISTINE backup, never the live asar: the engine
  # treats already-patched anchors as done, so extracting the live (already-
  # patched) file would keep the OLD injected code forever (caught live
  # 2026-10-24: the v1->v2 upgrade extracted the live tree, the engine
  # reported -1/-1 and the post-swap probe failed). After an app update the
  # live asar is the new pristine version and must be the extract source (the
  # backup would roll the app back a version).
  $extractSource = $OcAsar
  if ($OcCorePatched -and $existingMarker -and $existingMarker.backupDir) {
    $backupAsar = Join-Path $existingMarker.backupDir "app.asar"
    if (Test-Path $backupAsar) {
      $extractSource = $backupAsar
      Write-Host "[2/7] Extracting PRISTINE backup asar (live file is already engine-patched)..."
    } else {
      Write-Host "WARNING: marker's original backup is missing - extracting the live (patched) asar; the engine's done-anchors will skip already-patched sites."
    }
  }
  if ($extractSource -eq $OcAsar) {
    Write-Host "[2/7] Extracting app.asar (176 MB - takes a minute)..."
  }
  Invoke-OpenCodeAsar @("--yes", "@electron/asar", "extract", $extractSource, $OcExtracted)
  Write-Host "[3/7] Running patch engine (clone-home + clone-identity)..."
  $engineOut = & $NodeExe $OcEngine $OcExtracted
  $engineJson = $null
  try { $engineJson = ($engineOut -join "`n") | ConvertFrom-Json } catch {
    throw ("patch engine returned invalid JSON: {0}" -f ($engineOut -join "`n"))
  }
  if (-not $engineJson.ok) {
    throw ("patch engine FAILED: {0} | totals: {1}" -f $engineJson.error, ($engineJson.totals | ConvertTo-Json -Compress))
  }
  if ($OcCorePatched -and $extractSource -ne $OcAsar) {
    # Pristine-backup rebuild: BOTH families must have applied fresh. All-done
    # (-1) results here mean the extract source was not actually pristine.
    if (($engineJson.totals.'clone-home' -eq 0) -and ($engineJson.totals.'clone-identity' -eq 0)) {
      throw "engine reported no fresh changes on a pristine-backup rebuild - the backup is not pristine. Investigate the backups before retrying."
    }
  }

  $engineJson.results | ForEach-Object {
    $file = $_.file
    $counts = $_.counts
    $countsText = ($counts.PSObject.Properties | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join " "
    Write-Host ("      {0}: {1}" -f $file, $countsText)
  }
  foreach ($r in $engineJson.results) {
    if (-not $r.appliedMarkers -or @($r.appliedMarkers).Count -eq 0) { continue }
    $patchedFile = Join-Path $OcExtracted ($r.file -replace "/", "\")
    $content = [IO.File]::ReadAllText($patchedFile)
    foreach ($marker in $r.appliedMarkers) {
      if (-not $content.Contains($marker)) {
        throw ("patch verify FAILED after write: marker '{0}' missing in {1}" -f $marker, $r.file)
      }
    }
  }
  foreach ($r in $engineJson.results) {
    if ($r.file -notmatch "\.(js|cjs|mjs)$") { continue }
    $syntaxFile = Join-Path $OcExtracted ($r.file -replace "/", "\")
    $checkOut = cmd /c "`"$NodeExe`" --check `"$syntaxFile`" 2>&1" | Out-String
    if ($LASTEXITCODE -ne 0) {
      throw ("patch verify FAILED: node --check rejected {0}`n{1}" -f $r.file, $checkOut.Trim())
    }
    Write-Host ("      {0}: node --check OK" -f $r.file)
  }
  Write-Host "[4/7] Packing candidate asar..."
  $unpackGlobs = New-Object "System.Collections.Generic.List[string]"
  $unpackGlobs.Add("*.{node,dll,dylib,exe}")
  if (Test-Path $OcUnpacked) { $null = Get-OpenCodeRelPaths -Root $OcUnpacked }
  for ($try = 1; $try -le 4; $try++) {
    $packArgs = @("--yes", "@electron/asar", "pack", $OcExtracted, $OcCandidate)
    foreach ($g in $unpackGlobs) { $packArgs += "--unpack"; $packArgs += $g }
    Invoke-OpenCodeAsar $packArgs
    if (-not (Test-Path $OcCandidate)) { throw "repack FAILED: candidate not written" }
    break
  }
  Write-Host "[5/7] Verifying candidate asar contents..."
  $OcVerify = Join-Path $OcWork "verify"
  foreach ($r in $engineJson.results) {
    if (-not $r.appliedMarkers -or @($r.appliedMarkers).Count -eq 0) { continue }
    New-Item -ItemType Directory -Path $OcVerify -Force | Out-Null
    Get-ChildItem -LiteralPath $OcVerify -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $relWin = $r.file -replace "/", "\"
    Push-Location $OcVerify
    try {
      Invoke-OpenCodeAsar @("--yes", "@electron/asar", "extract-file", $OcCandidate, $relWin)
    } finally { Pop-Location }
    $verifyFile = Get-ChildItem -LiteralPath $OcVerify -Recurse -File |
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
  $patchFloor = [long]((Get-Item $OcAsar).Length / 2)
  Invoke-OpenCodeAsarSwap -ResourcesDir $OcResources -CandidateAsar $OcCandidate -CandidateUnpacked $OcCandidateUnpacked -MinAsarBytes $patchFloor -BackupDir $OcBackupDir
  # verify-after-swap: the live file must carry every signature (covers the
  # in-place fallback path as well as the plain delete+move).
  $SwapProbeOut = & $NodeExe -e "const fs=require('fs');try{const b=fs.readFileSync(process.argv[1]);const need=['__opencodeCloneHome','__opencodeCloneIdentity','--opencode-clone-home','--opencode-clone-id'];const missing=need.filter(s=>!b.includes(s));if(missing.length){console.log('MISSING '+missing.join(','));process.exit(1)}console.log('OK all-present');process.exit(0)}catch(e){console.error('PROBE_ERROR '+String((e&&e.message)||e));process.exit(3)}" $OcAsar
  $SwapProbeText = ($SwapProbeOut -join " ")
  if ($LASTEXITCODE -ne 0 -or $SwapProbeText -notmatch 'OK all-present') {
    throw ("post-swap verify FAILED: signatures not present in the live asar ({0}) - run with -Restore." -f $SwapProbeText)
  }
  Write-Host "      live asar carries all patch signatures."
  Write-Host "[7/7] Writing marker..."
  $marker = [ordered]@{
    appliedAt    = (Get-Date -Format "o")
    patchVersion = [int]$engineJson.engineVersion
    installDir   = $OcInstall
    backupDir    = $OcBackupDir
    patchedFiles = @($engineJson.results | ForEach-Object { $_.file })
    totals       = $engineJson.totals
  }
  $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $OcMarker -Encoding UTF8
  if (-not (Test-Path $OcMarker)) { throw "marker verify FAILED: not written" }
} finally {
  if (Test-Path $OcWork) { Remove-Item $OcWork -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "SUCCESS - OpenCode desktop patched (engine v$script:EngineVersion): per-clone clone-home isolation + taskbar identity."
