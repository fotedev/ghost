#Requires -Version 5.1
<#
.SYNOPSIS
  Patches the installed OpenCode desktop app.asar (engine v3): clone-home
  multi-instance isolation + per-clone taskbar identity.

.DESCRIPTION
  One-time app.asar patch (marker + -Restore + backup), mirroring the
  earlier AutoClaw v1.20 asar-patch machinery (removed 2026-10-31 with the
  v1.20 sunset — git history / archive/autoclaw-v1.20/). See
  docs/OPENCODE_CLONES_SPEC.md:
    clone-home      the app's packaged bootstrap hardcodes
                    userData = %APPDATA%\ai.opencode.desktop; the patch gives
                    it the TEST_ROOT-equivalent via an argv scan of
                    --opencode-clone-home=<dir> at the app's own test-root
                    read (the `ue()` bootstrap fn in 2.2.5.0 - was the `ye()`
                    ternary tail in 2.0.32), so userData/sessionData + the
                    XDG_* CLI-state homes all become per-clone. No flag =
                    bit-for-bit stock behavior.
    clone-identity  the single setAppUserModelId site is wrapped to append
                    ".<aumidSuffix>" and an app-level browser-window-created
                    listener stamps every window's AUMID/icon/title from
                    <cloneHome>\desktop\.opencode-clone-identity.json
                    (written by launch_opencode_clone.ps1).

  App-update recovery (2026-10-24 pattern): the updater replaces app.asar
  wholesale; the script byte-probes for the engine's signature strings
  BEFORE the marker gate and re-patches automatically (fresh backup of the
  new pristine asar) when they are missing.

  With -WaitForClose (GHOST.bat OpenCode [8] passes it) a running OpenCode no
  longer aborts the run: the script prints which processes are up and polls
  until every OpenCode.exe from the install dir has exited, then continues
  into the patch.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_opencode_clone_home.ps1
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$Force,
  [switch]$WaitForClose,
  [int]$WaitTimeoutMinutes = 30,
  [string]$InstallDir
)

$ErrorActionPreference = "Stop"

# Must match ENGINE_VERSION in patch_opencode_clone_home.mjs.
# v3 (2026-11-01): re-derived for the 2.2.5.0 bundle (the updater replaced
# app.asar wholesale on 2026-10-31; the v2 clone-home byte anchor - the 2.0.32
# `isPackaged?void 0:...` ternary tail - has zero sites in the new bundle).
# v4 (2026-11-03): asar surgery via tools/asar_surgery.mjs - the extract/repack
#     pipeline (npx extract to %TEMP%, full repack, one npx spawn per
#     patched-file verify) is replaced by one node process: ranged reads of
#     only the text entries, in-memory transforms, node --check in-engine,
#     single-pass candidate rebuild + full header/region/content verify. The
#     sidecar app.asar.unpacked is never touched (swap runs with
#     -SkipUnpackedSwap). Patch anchors and output bytes unchanged from v3.
$script:EngineVersion = 4
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
  # Scoped to the install dir being patched: replacing app.asar under a running
  # exe from THAT dir is what corrupts things. Same-user processes expose .Path;
  # inaccessible/null paths belong to other contexts and cannot hold this dir open.
  param([string]$InstallPath)
  $allProcs = @(Get-Process -Name "OpenCode" -ErrorAction SilentlyContinue)
  $procs = @($allProcs |
    Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
  # Guard-strength (bug sweep 15): a process whose .Path is unreadable cannot
  # be classified - warn instead of silently skipping it.
  $unclassified = @($allProcs | Where-Object { -not $_.Path })
  if ($unclassified.Count -gt 0) {
    Write-Warning ("{0} OpenCode process(es) exposed no readable path and were NOT checked (PID(s): {1}). If the asar swap fails with the file in use, close every OpenCode instance and re-run." -f
      $unclassified.Count, (($unclassified | Select-Object -First 5 -ExpandProperty Id) -join ", "))
  }
  if ($procs.Count -eq 0) { return }

  $pidList = (($procs | Select-Object -First 5 -ExpandProperty Id) -join ", ")
  if (-not $script:WaitForClose) {
    throw ("OpenCode.exe from this install dir is running (PID(s): {0}). Close all its windows and try again." -f $pidList)
  }

  # -WaitForClose (GHOST.bat OpenCode [8]): the operator is routinely working
  # INSIDE an OpenCode instance, so refuse-and-rerun blocks the patch indefinitely.
  # Instruct once, poll until every instance has exited, then continue straight
  # into the patch. Two consecutive clear probes defeat an exit-time helper
  # respawn race; the deadline keeps an abandoned console from waiting forever.
  # No per-iteration unclassified warnings - .Path is transiently unreadable
  # while a process exits.
  Write-Host ""
  Write-Host ("OpenCode.exe from this install dir is running (PID(s): {0})." -f $pidList)
  Write-Host "Close ALL OpenCode windows and instances now - the patch starts automatically once every one has exited."
  Write-Host ("Waiting up to {0} minutes - Ctrl+C to abort." -f $script:WaitTimeoutMinutes)
  $deadline = (Get-Date).AddMinutes($script:WaitTimeoutMinutes)
  $clearStreak = 0
  $lastStatus = Get-Date
  while ($true) {
    Start-Sleep -Seconds 2
    $remaining = @(Get-Process -Name "OpenCode" -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
    if ($remaining.Count -eq 0) {
      $clearStreak++
      if ($clearStreak -ge 2) {
        Write-Host "All OpenCode instances closed - continuing."
        return
      }
    } else {
      $clearStreak = 0
      if (((Get-Date) - $lastStatus).TotalSeconds -ge 30) {
        $lastStatus = Get-Date
        Write-Host ("      still waiting - {0} OpenCode.exe process(es) from this install dir (PID(s): {1})" -f
          $remaining.Count, (($remaining | Select-Object -First 5 -ExpandProperty Id) -join ", "))
      }
    }
    if ((Get-Date) -gt $deadline) {
      throw ("Timed out after {0} minutes waiting for OpenCode.exe to exit. Close all OpenCode instances and run this again." -f $script:WaitTimeoutMinutes)
    }
  }
}

function Find-OpenCodeTool {
  param([string]$Name, [string]$MissingMessage)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw $MissingMessage }
  return $cmd.Source
}

function Assert-OpenCodeDiskFreeFor {
  # Preflight for the big sequential writes (backup copy, candidate asar,
  # restore staging): abort cleanly BEFORE anything is written when the
  # target volume is short. Skips silently when the drive cannot be queried
  # (not ready / unusual path) - never block the patch on a measurement.
  # RequiredBytes should carry margin (callers pass ~1.25x the asar size:
  # the candidate can be slightly LARGER than the source because patched
  # content is appended while the original bytes stay in place).
  param([string]$TargetPath, [long]$RequiredBytes, [string]$Purpose)
  $free = $null
  $root = $null
  try {
    $root = (Split-Path -Qualifier $TargetPath) + "\"
    $drive = New-Object System.IO.DriveInfo($root)
    if ($drive.IsReady) { $free = $drive.AvailableFreeSpace }
  } catch { $free = $null }
  if ($null -ne $free -and $free -lt $RequiredBytes) {
    throw ("Not enough free disk space for {0}: {1:N0} MB free on {2}, need ~{3:N0} MB. Free up space and re-run - nothing was written yet." -f `
      $Purpose, ($free / 1MB), $root, ($RequiredBytes / 1MB))
  }
}

function Test-OpenCodeSwapRetryableException {
  # True when a swap failure is worth retrying: plain IO errors (sharing
  # violations, briefly locked files) AND Access-denied - antivirus commonly
  # throws either while scanning a just-written file. Cmdlets can wrap the
  # real exception, so the InnerException chain is walked too.
  param($ErrorRecord)
  $ex = $ErrorRecord.Exception
  while ($ex) {
    if ($ex -is [System.IO.IOException] -or $ex -is [System.UnauthorizedAccessException]) { return $true }
    $ex = $ex.InnerException
  }
  return $false
}

function Invoke-OpenCodeAsarSwap {
  # -SkipUnpackedSwap (engine v4 asar surgery): the candidate has no sidecar
  # because surgery never touches app.asar.unpacked - the whole unpacked-dir
  # swap/keep-verify block is skipped and the live sidecar stays in place.
  param(
    [string]$ResourcesDir,
    [string]$CandidateAsar,
    [string]$CandidateUnpacked,
    [long]$MinAsarBytes,
    [string]$BackupDir,
    [switch]$SkipUnpackedSwap
  )
  $asar = Join-Path $ResourcesDir "app.asar"
  $unpacked = Join-Path $ResourcesDir "app.asar.unpacked"

  # asar swap. Delete+move is the clean path; when another process holds the
  # asar WITHOUT share-delete (indexers/AV do this - observed live: the host
  # IDE's file indexer kept a read handle for minutes), delete is impossible
  # but WRITE access may still be shared - then an in-place overwrite of the
  # live file is used, allowed ONLY with a verified pristine backup on disk
  # (the fallback never runs backup-less; the backup is the rollback).
  # Before the fallback engages, the swap is retried up to 6 times (300 ms
  # apart): antivirus scanning the freshly written ~340 MB candidate holds it
  # only briefly, so the plain path usually succeeds on retry 2-3.
  try {
    $swapDone = $false
    for ($swapTry = 1; $swapTry -le 6; $swapTry++) {
      try {
        if (Test-Path $asar) { Remove-Item $asar -Force -ErrorAction Stop }
        Move-Item $CandidateAsar $asar -ErrorAction Stop
        $swapDone = $true
        break
      } catch {
        if (-not (Test-OpenCodeSwapRetryableException $_)) { throw }
        if ($swapTry -lt 6) {
          Write-Host ("      app.asar swap blocked (likely AV scanning the fresh candidate) - retry {0}/6 in 300 ms..." -f $swapTry)
          Start-Sleep -Milliseconds 300
        }
      }
    }
    if (-not $swapDone) {
      # Re-throw as IOException so the fallback dispatch below runs (the
      # persistent-lock case the in-place overwrite was built for).
      throw (New-Object System.IO.IOException("app.asar swap still blocked after 6 retries (persistent file lock)"))
    }
  } catch {
    if (-not (Test-OpenCodeSwapRetryableException $_)) { throw }
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
  # -SkipUnpackedSwap bypasses the whole block: surgery leaves the sidecar
  # byte-identical, and renaming it away would only add a failure surface.
  $oldUnpacked = Join-Path $ResourcesDir "app.asar.unpacked.old"
  $unpackedKept = $false
  if (-not $SkipUnpackedSwap) {
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
  }

  if (-not $SkipUnpackedSwap) {
    if (-not (Test-Path $asar) -or -not (Test-Path $unpacked)) { throw "post-swap verify FAILED: targets missing" }
  } else {
    if (-not (Test-Path $asar)) { throw "post-swap verify FAILED: app.asar missing" }
    if (-not (Test-Path $unpacked)) {
      Write-Warning "post-swap note: app.asar.unpacked is absent - surgery never touches the sidecar, so it was already absent before this run."
    }
  }
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
  $backupLen = (Get-Item (Join-Path $backup.FullName "app.asar")).Length
  $restoreFloor = [long]($backupLen / 2)
  Write-Host "[1/2] Restoring app.asar + app.asar.unpacked from $($backup.Name) (staged copy)"
  # Peak-disk preflight for -Restore: the staged copy (~1.25x) lands in
  # %TEMP%; the swap then moves it into resources - a pure rename when the
  # volumes match, but a cross-volume move-in copy (~1.0x) on the install
  # volume when they differ.
  $OcTempRoot = (Split-Path -Qualifier $env:TEMP) + "\"
  $OcInstallRoot = (Split-Path -Qualifier $OcResources) + "\"
  if ($OcTempRoot -ieq $OcInstallRoot) {
    Assert-OpenCodeDiskFreeFor -TargetPath $env:TEMP -RequiredBytes ([long]($backupLen * 1.3)) -Purpose "the -Restore staged copy"
  } else {
    Assert-OpenCodeDiskFreeFor -TargetPath $env:TEMP -RequiredBytes ([long]($backupLen * 1.3)) -Purpose "the -Restore staged copy (temp)"
    Assert-OpenCodeDiskFreeFor -TargetPath $OcResources -RequiredBytes ([long]($backupLen * 1.1)) -Purpose "the -Restore move-in copy (install volume)"
  }
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
$OcAsarLen = (Get-Item $OcAsar).Length
# Total wall clock for the mutating part (excludes -WaitForClose polling).
$OcSwTotal = [System.Diagnostics.Stopwatch]::StartNew()
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
  Write-Host "[1/5] Reusing original backup at $OcBackupDir"
}
if (-not $OcReuseBackup) {
  if ($OcCorePatched) { Write-Host "WARNING: patched tree but no usable marker backup - the new backup captures the CURRENT (patched) asar; -Restore will return here, not to the vendor asar." }
  Write-Host "[1/5] Backup to $OcBackupDir"
  # Peak-disk preflight (single check, before anything is written). The peak
  # has TWO coexisting files - the backup copy and the engine's candidate:
  #   - install volume == %TEMP% volume: backup (1.25x) + candidate (1.25x)
  #     coexist and the swap is a pure rename -> require ~2.6x in total;
  #   - different volumes: the install volume holds the backup (1.25x) PLUS
  #     the cross-volume candidate move-in copy (~1.0x) at swap time -> ~2.3x
  #     there, and the candidate alone (~1.3x) on the TEMP volume.
  $OcTempRoot = (Split-Path -Qualifier $env:TEMP) + "\"
  $OcInstallRoot = (Split-Path -Qualifier $OcBackupDir) + "\"
  if ($OcTempRoot -ieq $OcInstallRoot) {
    Assert-OpenCodeDiskFreeFor -TargetPath $OcBackupDir -RequiredBytes ([long]($OcAsarLen * 2.6)) -Purpose "backup + patched candidate (same volume as temp)"
  } else {
    Assert-OpenCodeDiskFreeFor -TargetPath $OcBackupDir -RequiredBytes ([long]($OcAsarLen * 2.3)) -Purpose "backup + candidate swap-in copy (install volume)"
    Assert-OpenCodeDiskFreeFor -TargetPath $env:TEMP -RequiredBytes ([long]($OcAsarLen * 1.3)) -Purpose "the patched candidate asar (temp)"
  }
  $OcSwBackup = [System.Diagnostics.Stopwatch]::StartNew()
  New-Item -ItemType Directory -Path $OcBackupDir -Force | Out-Null
  Copy-Item $OcAsar (Join-Path $OcBackupDir "app.asar")
  if (Test-Path $OcUnpacked) {
    Copy-Item $OcUnpacked (Join-Path $OcBackupDir "app.asar.unpacked") -Recurse
  }
  if (-not (Test-Path (Join-Path $OcBackupDir "app.asar"))) { throw "backup verify FAILED: app.asar not copied" }
  $OcSwBackup.Stop()
  Write-Host ("      backup done in {0:N1}s" -f $OcSwBackup.Elapsed.TotalSeconds)
}


$OcWork = Join-Path $env:TEMP ("opencode-clone-home-patch-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$OcCandidate = Join-Path $OcWork "app.asar.candidate"
$OcChecksDir = Join-Path $OcWork "checks"

try {
  New-Item -ItemType Directory -Path $OcWork -Force | Out-Null
  # A rebuild of an ALREADY-PATCHED tree (engine upgrade via the marker, or
  # -Force) must read the PRISTINE backup, never the live asar: the engine
  # treats already-patched anchors as done, so reading the live (already-
  # patched) file would keep the OLD injected code forever (caught live
  # 2026-10-24: the v1->v2 upgrade extracted the live tree, the engine
  # reported -1/-1 and the post-swap probe failed). After an app update the
  # live asar is the new pristine version and must be the surgery source (the
  # backup would roll the app back a version).
  $extractSource = $OcAsar
  if ($OcCorePatched -and $existingMarker -and $existingMarker.backupDir) {
    $backupAsar = Join-Path $existingMarker.backupDir "app.asar"
    if (Test-Path $backupAsar) {
      $extractSource = $backupAsar
      Write-Host "[2/5] Rebuilding from the PRISTINE backup asar (live file is already engine-patched)..."
    } else {
      Write-Host "WARNING: marker's original backup is missing - reading the live (patched) asar; the engine's done-anchors will skip already-patched sites."
    }
  }

  # [2/5] asar surgery (engine v4): ranged reads of only the text entries,
  # in-memory transforms, node --check in-engine, single-pass candidate
  # rebuild + full header/region/content verify. No extract-to-disk, no
  # repack, no npx - one node process, a few seconds.
  # (Candidate disk space was covered by the combined peak preflight above.)
  Write-Host "[2/5] Patching asar in memory + rebuilding candidate (asar surgery)..."
  $engineOut = & $NodeExe $OcEngine $extractSource $OcCandidate $OcChecksDir
  $engineJson = $null
  try { $engineJson = ($engineOut -join "`n") | ConvertFrom-Json } catch {
    throw ("patch engine returned invalid JSON: {0}" -f ($engineOut -join "`n"))
  }
  if (-not $engineJson.ok) {
    throw ("patch engine FAILED: {0} | totals: {1}" -f $engineJson.error, ($engineJson.totals | ConvertTo-Json -Compress))
  }
  if ($OcCorePatched -and $extractSource -ne $OcAsar) {
    # Pristine-backup rebuild: BOTH families must have applied fresh. All-done
    # (-1) results here mean the surgery source was not actually pristine.
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
  if ($engineJson.timings) {
    Write-Host ("      engine: patch {0}ms, node --check {1}ms, rebuild {2}ms, verify {3}ms" -f `
      $engineJson.timings.readPatchMs, $engineJson.timings.syntaxMs, $engineJson.timings.rebuildMs, $engineJson.timings.verifyMs)
  }

  Write-Host "[3/5] Swapping patched asar into install..."
  $patchFloor = [long]((Get-Item $OcAsar).Length / 2)
  $OcSwSwap = [System.Diagnostics.Stopwatch]::StartNew()
  Invoke-OpenCodeAsarSwap -ResourcesDir $OcResources -CandidateAsar $OcCandidate -MinAsarBytes $patchFloor -BackupDir $OcBackupDir -SkipUnpackedSwap
  $OcSwSwap.Stop()
  Write-Host ("      swap done in {0:N1}s" -f $OcSwSwap.Elapsed.TotalSeconds)
  # verify-after-swap: the live file must carry every signature (covers the
  # in-place fallback path as well as the plain delete+move).
  $SwapProbeOut = & $NodeExe -e "const fs=require('fs');try{const b=fs.readFileSync(process.argv[1]);const need=['__opencodeCloneHome','__opencodeCloneIdentity','--opencode-clone-home','--opencode-clone-id'];const missing=need.filter(s=>!b.includes(s));if(missing.length){console.log('MISSING '+missing.join(','));process.exit(1)}console.log('OK all-present');process.exit(0)}catch(e){console.error('PROBE_ERROR '+String((e&&e.message)||e));process.exit(3)}" $OcAsar
  $SwapProbeText = ($SwapProbeOut -join " ")
  if ($LASTEXITCODE -ne 0 -or $SwapProbeText -notmatch 'OK all-present') {
    throw ("post-swap verify FAILED: signatures not present in the live asar ({0}) - run with -Restore." -f $SwapProbeText)
  }
  Write-Host "      live asar carries all patch signatures."
  Write-Host "[4/5] Writing marker..."
  $marker = [ordered]@{
    appliedAt    = (Get-Date -Format "o")
    patchVersion = [int]$engineJson.engineVersion
    installDir   = $OcInstall
    backupDir    = $OcBackupDir
    patchedFiles = @($engineJson.results | ForEach-Object { $_.file })
    totals       = $engineJson.totals
    timings      = $engineJson.timings
  }
  $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $OcMarker -Encoding UTF8
  if (-not (Test-Path $OcMarker)) { throw "marker verify FAILED: not written" }
  $OcSwTotal.Stop()
  Write-Host ("      marker written - patch completed in {0:N1}s total" -f $OcSwTotal.Elapsed.TotalSeconds)
} finally {
  if (Test-Path $OcWork) { Remove-Item $OcWork -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host "SUCCESS - OpenCode desktop patched (engine v$script:EngineVersion): per-clone clone-home isolation + taskbar identity."
