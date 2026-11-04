#requires -Version 5.1
<#
.SYNOPSIS
  Patches the installed ZCode desktop app so the SECONDARY instance can show its own
  blue icon and get a separate taskbar button, driven by env vars the launcher sets.

.DESCRIPTION
  Adds two runtime overrides to the packaged app.asar (no rebuild needed):
    - ZCODE_ICON_DIR      : if set, window + tray icons are read from this directory
                            (icon_windows.png / tray_icon.ico) instead of resources\
    - ZCODE_AUMID_SUFFIX  : if set, the Windows AppUserModelID gets ".<suffix>" appended,
                            which fully separates the secondary's taskbar button
  Primary ZCode never sets these vars, so it is untouched behaviorally.

  Idempotent: re-running after a patch is a no-op unless -Force. Every write is
  verified (no silent success). Engine v9 applies the patch set with asar
  surgery (tools/asar_surgery.mjs) - no extract/repack; the candidate is
  verified by header walk + full payload-region byte compare + patched-content
  compare inside one node process. A backup of app.asar and app.asar.unpacked
  is taken before any change; -Restore rolls back.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_icon_override.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_icon_override.ps1 -Force
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_icon_override.ps1 -Restore

  With -WaitForClose (GHOST.bat ZCode [27] passes it) a running ZCode no longer
  aborts the run: the script prints which processes are up and polls until every
  ZCode.exe from the install dir has exited, then continues into the patch.
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

# Must match ENGINE_VERSION in patch_zcode_icon_override.mjs. The marker carries
# the applied version; a marker older than this triggers an automatic re-patch.
# v4: repairs the v3 main-args bug (dropped template-literal backtick ->
# "SyntaxError: Unexpected identifier 'blocked'" crash on launch).
# v5: fixes v4's repair placing the backtick before the interpolation's closing
# brace instead of after it -> "SyntaxError: Missing } in template expression".
# v6: multi-instance accents - main-args forwards ZCODE_ACCENT_HEX /
# ZCODE_INSTANCE_NAME as --zcode-accent/--zcode-title, preload exposes
# __ZCODE_ACCENT__/__ZCODE_TITLE__, splash/sidebar/badge read the accent
# (fallback #066BCB), window title becomes "ZCode <name>". Upgrades v5 trees
# in place; no accent env -> exact v5 blue behavior.
# v7: bidi auto-direction - preload injects a <style id="zcode-bidi-auto-style">
# making chat text blocks auto-detect direction per paragraph (Arabic RTL /
# English LTR; code blocks stay LTR) and stamps dir="auto" for alignment.
# Renderer reads ZCODE_BIDI_OFF=1 to opt out; no launcher changes. Upgrades
# v6 trees in place.
# App-update recovery (2026-10-24): the app's auto-updater replaces app.asar
# but leaves the marker file in resources, so the old "marker exists" gate
# silently skipped re-patching after every update (taskbar icons survived
# via shortcut IconLocation; in-app window + tray icons stayed default).
# The script now byte-probes app.asar for the engine's signature strings
# before the gate: marker + signatures present -> already-patched early exit;
# signatures missing (update-wiped asar) -> automatic re-patch without -Force
# and a FRESH backup of the new pristine asar (reusing the original backup
# would let a later -Restore downgrade the app). Still-patched re-patches
# keep the original-backup reuse.
# v8 (2026-10-24): updater-secondary anchor tolerance for app 3.16.3+ - the
#     updater gate grew a second conjunction (enabled:<x>==="production"&&<flag>),
#     which made the v7 exact anchor find zero sites and abort the patch.
#     Engine v8 matches both shapes; marker carries patchVersion 8 so older
#     markers auto-upgrade on the next run.
# v9 (2026-11-03): asar surgery - the extract/repack pipeline (npx @electron/asar
#     extract of the ~340 MB/~32k-file archive to %TEMP%, up to 4 repacks in a
#     sidecar-convergence loop, one npx spawn per patched-file verify) is
#     replaced by tools/asar_surgery.mjs: the engine ranges-reads only the text
#     entries, patches them in memory, and rebuilds the candidate asar in one
#     streaming pass (untouched payload region copied byte-for-byte, patched
#     contents appended at the tail, only patched header entries rewritten,
#     integrity recomputed). Full verification stays: header walk + whole-region
#     byte compare + patched-content compare, all in the single node process.
#     v9 also fixed a pre-existing perf bug found while measuring: preload-blue's
#     per-position regex backtracking cost ~290s across the bundle (the silent
#     bulk of the old [3/7] step); it now uses a literal indexOf + backward
#     receiver scan, byte-identical output (proven against the v8-patched live
#     asar). The sidecar app.asar.unpacked is never touched by surgery, so the
#     swap runs with -SkipUnpackedSwap and the pack-convergence machinery is
#     gone. Patch time drops from minutes to seconds.
$script:EngineVersion = 9

function Resolve-InstallDir {
  param([string]$Override)
  $candidates = @()
  if ($Override) { $candidates += $Override }
  $candidates += @(
    (Join-Path $env:LOCALAPPDATA "Programs\ZCode"),
    "C:\Program Files\ZCode",
    "C:\Program Files (x86)\ZCode"
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c "ZCode.exe")) -and (Test-Path (Join-Path $c "resources\app.asar"))) {
      return $c
    }
  }
  throw "ZCode install not found. Pass -InstallDir <path> explicitly."
}

function Assert-ZCodeClosed {
  # Scoped to the install dir being patched: replacing app.asar under a running
  # exe from THAT dir is what corrupts things. Same-user processes expose .Path;
  # inaccessible/null paths belong to other contexts and cannot hold this dir open.
  param([string]$InstallPath)
  $allProcs = @(Get-Process -Name "ZCode" -ErrorAction SilentlyContinue)
  $procs = @($allProcs |
    Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
  # Guard-strength (bug sweep 15): a process whose .Path is unreadable cannot
  # be classified - warn instead of silently skipping it.
  $unclassified = @($allProcs | Where-Object { -not $_.Path })
  if ($unclassified.Count -gt 0) {
    Write-Warning ("{0} ZCode process(es) exposed no readable path and were NOT checked (PID(s): {1}). If the asar swap fails with the file in use, close every ZCode instance and re-run." -f
      $unclassified.Count, (($unclassified | Select-Object -First 5 -ExpandProperty Id) -join ", "))
  }
  if ($procs.Count -eq 0) { return }

  $pidList = (($procs | Select-Object -First 5 -ExpandProperty Id) -join ", ")
  if (-not $script:WaitForClose) {
    throw ("ZCode.exe from this install dir is running (PID(s): {0}). Close all its windows and try again." -f $pidList)
  }

  # -WaitForClose (GHOST.bat ZCode [27]): the operator is routinely working
  # INSIDE a ZCode instance, so refuse-and-rerun blocks the patch indefinitely.
  # Instruct once, poll until every instance has exited, then continue straight
  # into the patch. Two consecutive clear probes defeat an exit-time helper
  # respawn race; the deadline keeps an abandoned console from waiting forever.
  # No per-iteration unclassified warnings - .Path is transiently unreadable
  # while a process exits.
  Write-Host ""
  Write-Host ("ZCode.exe from this install dir is running (PID(s): {0})." -f $pidList)
  Write-Host "Close ALL ZCode windows and instances now - the patch starts automatically once every one has exited."
  Write-Host ("Waiting up to {0} minutes - Ctrl+C to abort." -f $script:WaitTimeoutMinutes)
  $deadline = (Get-Date).AddMinutes($script:WaitTimeoutMinutes)
  $clearStreak = 0
  $lastStatus = Get-Date
  while ($true) {
    Start-Sleep -Seconds 2
    $remaining = @(Get-Process -Name "ZCode" -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
    if ($remaining.Count -eq 0) {
      $clearStreak++
      if ($clearStreak -ge 2) {
        Write-Host "All ZCode instances closed - continuing."
        return
      }
    } else {
      $clearStreak = 0
      if (((Get-Date) - $lastStatus).TotalSeconds -ge 30) {
        $lastStatus = Get-Date
        Write-Host ("      still waiting - {0} ZCode.exe process(es) from this install dir (PID(s): {1})" -f
          $remaining.Count, (($remaining | Select-Object -First 5 -ExpandProperty Id) -join ", "))
      }
    }
    if ((Get-Date) -gt $deadline) {
      throw ("Timed out after {0} minutes waiting for ZCode.exe to exit. Close all ZCode instances and run this again." -f $script:WaitTimeoutMinutes)
    }
  }
}

function Find-ToolCmd {
  param([string]$Name, [string]$MissingMessage)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw $MissingMessage }
  return $cmd.Source
}

function Assert-DiskFreeFor {
  # Preflight for the big sequential writes (backup copy, candidate asar,
  # restore staging): abort cleanly BEFORE anything is written when the
  # target volume is short. Skips silently when the drive cannot be queried
  # (not ready / unusual path) - never block the patch on a measurement.
  # RequiredBytes should carry margin (the callers pass ~1.25x the asar size:
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

function Test-SwapRetryableException {
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

function Invoke-AsarSwap {
  # Move candidate asar (and, unless -SkipUnpackedSwap, the unpacked sidecar)
  # into the install resources dir; rollback on failure.
  # MinAsarBytes: sanity floor - candidate must keep at least half the original size,
  # so a truncated/corrupted swap is refused (recover afterwards with -Restore).
  # -SkipUnpackedSwap (engine v9 asar surgery): the candidate has no sidecar
  # because surgery never touches app.asar.unpacked - renaming the live sidecar
  # away would break native-module loading. The swap is asar-only; the rollback
  # and verify mirror that (the pre-existing sidecar is only warned about if
  # absent, since its absence cannot be caused by this swap).
  param(
    [string]$ResourcesDir,
    [string]$CandidateAsar,
    [string]$CandidateUnpacked,
    [long]$MinAsarBytes,
    [string]$BackupAsar,
    [switch]$SkipUnpackedSwap
  )
  $asar = Join-Path $ResourcesDir "app.asar"
  $oldAsar = Join-Path $ResourcesDir "app.asar.old"
  $unpacked = Join-Path $ResourcesDir "app.asar.unpacked"
  $oldUnpacked = Join-Path $ResourcesDir "app.asar.unpacked.old"

  if (-not $SkipUnpackedSwap) {
    if (Test-Path $oldUnpacked) { Remove-Item $oldUnpacked -Recurse -Force }
    if (Test-Path $unpacked) { Rename-Item $unpacked "app.asar.unpacked.old" }
    if (-not (Test-Path $CandidateUnpacked)) {
      New-Item -ItemType Directory -Path $unpacked -Force | Out-Null
    } else {
      Move-Item $CandidateUnpacked $unpacked
    }
  }
  # Precondition: never start mutating without a candidate to move in.
  if (-not (Test-Path $CandidateAsar)) { throw "candidate asar missing before swap: $CandidateAsar" }

  try {
    # Rename-based swap - the install is never left without an app.asar:
    #   1. rename the live asar aside to app.asar.old (same-volume rename;
    #      the original stays recoverable in place the whole time),
    #   2. move the candidate in (same volume = rename; cross-volume = copy,
    #      which is why the disk preflight carries the extra ~1x term),
    #   3. delete .old only after the move succeeded.
    # AV-protected machines: antivirus can hold the freshly written ~340 MB
    # candidate (or the just-renamed live file) for a few seconds - the whole
    # rename+move sequence is retried up to 6 times, 300 ms apart; the catch
    # below (rename .old back, then backup restore) stays the last resort.
    if (Test-Path $oldAsar) {
      # Leftover from a crashed earlier run; a locked one blocks the rename,
      # so fail with a clear message instead of a confusing Rename-Item error.
      try { Remove-Item $oldAsar -Force -ErrorAction Stop } catch {
        throw ("app.asar.old from an earlier run is locked and cannot be cleaned - close the locking process and re-run. ({0})" -f $_.Exception.Message)
      }
    }
    $swapDone = $false
    for ($swapTry = 1; $swapTry -le 6; $swapTry++) {
      try {
        if ((Test-Path $asar) -and (Test-Path $oldAsar)) {
          # partial cross-volume copy from a failed move attempt - discard it
          Remove-Item $asar -Force -ErrorAction Stop
        }
        if ((Test-Path $asar) -and -not (Test-Path $oldAsar)) {
          Rename-Item -LiteralPath $asar -NewName "app.asar.old" -ErrorAction Stop
        }
        Move-Item -Force $CandidateAsar $asar -ErrorAction Stop
        $swapDone = $true
        break
      } catch {
        if (-not (Test-SwapRetryableException $_)) { throw }
        if ($swapTry -lt 6) {
          Write-Host ("      app.asar swap blocked (likely AV scanning the fresh candidate) - retry {0}/6 in 300 ms..." -f $swapTry)
          Start-Sleep -Milliseconds 300
        }
      }
    }
    if (-not $swapDone) { throw "app.asar swap still blocked after 6 retries - run this again (or -Restore if the install is incomplete)." }
    # The swap itself succeeded; a still-locked .old is only wasted space, not
    # a failure - warn and move on (the next patch run cleans it up).
    try { Remove-Item $oldAsar -Force } catch {
      Write-Warning ("app.asar.old could not be deleted yet (still locked) - it will be cleaned up on the next patch run: {0}" -f $_.Exception.Message)
    }
  } catch {
    # Roll app.asar.old back FIRST: a failed move after a successful rename
    # must never leave the install without an app.asar (bug sweep 15 HIGH).
    if (-not (Test-Path $asar) -and (Test-Path $oldAsar)) {
      try { Rename-Item -LiteralPath $oldAsar -NewName "app.asar" } catch {
        Write-Warning ("could not rename app.asar.old back to app.asar: {0}" -f $_.Exception.Message)
      }
    }
    if (-not $SkipUnpackedSwap) {
      # Roll the unpacked sidecar back next (it was swapped before the asar),
      # then make sure app.asar itself exists again via the backup - the last
      # resort if the rename-back above could not run (bug sweep 15 HIGH).
      Remove-Item $unpacked -Recurse -Force
      Rename-Item $oldUnpacked "app.asar.unpacked"
    }
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
  if (-not $SkipUnpackedSwap) {
    Remove-Item $oldUnpacked -Recurse -Force -ErrorAction SilentlyContinue
    # verify-after swap: targets exist, asar has a plausible size
    if (-not (Test-Path $asar) -or -not (Test-Path $unpacked)) { throw "post-swap verify FAILED: targets missing" }
  } else {
    if (-not (Test-Path $asar)) { throw "post-swap verify FAILED: app.asar missing" }
    if (-not (Test-Path $unpacked)) {
      Write-Warning ("post-swap note: app.asar.unpacked is absent - surgery never touches the sidecar, so it was already absent before this run.")
    }
  }
  if ((Get-Item $asar).Length -lt $MinAsarBytes) {
    throw ("post-swap verify FAILED: app.asar suspiciously small ({0:N0} < {1:N0} bytes). Run this script with -Restore." -f (Get-Item $asar).Length, $MinAsarBytes)
  }
}

function Copy-BackupToStaging {
  # -Restore consumes backups by COPY so the backup itself stays intact.
  param([string]$BackupDir)
  $stage = Join-Path $env:TEMP ("zcode-icon-restore-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  Copy-Item (Join-Path $BackupDir "app.asar") (Join-Path $stage "app.asar")
  if (Test-Path (Join-Path $BackupDir "app.asar.unpacked")) {
    Copy-Item (Join-Path $BackupDir "app.asar.unpacked") (Join-Path $stage "app.asar.unpacked") -Recurse
  } else {
    New-Item -ItemType Directory -Path (Join-Path $stage "app.asar.unpacked") -Force | Out-Null
  }
  return $stage
}

# ── entry ──────────────────────────────────────────────────────────────────────
$NodeExe = Find-ToolCmd "node" "node not found on PATH (needed to run the patch engine)."
$Install = Resolve-InstallDir -Override $InstallDir
$Resources = Join-Path $Install "resources"
$Asar = Join-Path $Resources "app.asar"
$MarkerPath = Join-Path $Resources "zcode-icon-patch.marker.json"
$BackupsRoot = Join-Path $Resources "ID_Backups"
$PatchEngine = Join-Path $PSScriptRoot "patch_zcode_icon_override.mjs"

Write-Host "Install dir : $Install"

if ($Restore) {
  Assert-ZCodeClosed -InstallPath $Install
  # Prefer the marker's backupDir (the backup the last patch run verified
  # against); fall back to the newest folder only when the marker is absent,
  # unreadable, or its backup no longer holds an app.asar (bug sweep 15).
  $backup = $null
  if (Test-Path $MarkerPath) {
    try {
      $restoreMarker = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
      if ($restoreMarker.backupDir -and (Test-Path (Join-Path $restoreMarker.backupDir "app.asar"))) {
        $backup = Get-Item -LiteralPath $restoreMarker.backupDir
      }
    } catch { Write-Host "Marker unreadable - falling back to the newest backup folder." }
  }
  if (-not $backup) {
    $backup = Get-ChildItem -LiteralPath $BackupsRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | Where-Object { Test-Path (Join-Path $_.FullName "app.asar") } |
      Select-Object -First 1
  }
  if (-not $backup) { throw "No backup found under $BackupsRoot - nothing to restore." }
  $backupLen = (Get-Item (Join-Path $backup.FullName "app.asar")).Length
  $restoreFloor = [long]($backupLen / 2)
  Write-Host "[1/2] Restoring app.asar + app.asar.unpacked from $($backup.Name) (staged copy)"
  # Peak-disk preflight for -Restore: the staged copy (~1.25x) lands in
  # %TEMP%; the swap then moves it into resources - a pure rename when the
  # volumes match, but a cross-volume move-in copy (~1.0x) on the install
  # volume when they differ.
  $TempRoot = (Split-Path -Qualifier $env:TEMP) + "\"
  $InstallRoot = (Split-Path -Qualifier $Resources) + "\"
  if ($TempRoot -ieq $InstallRoot) {
    Assert-DiskFreeFor -TargetPath $env:TEMP -RequiredBytes ([long]($backupLen * 1.3)) -Purpose "the -Restore staged copy"
  } else {
    Assert-DiskFreeFor -TargetPath $env:TEMP -RequiredBytes ([long]($backupLen * 1.3)) -Purpose "the -Restore staged copy (temp)"
    Assert-DiskFreeFor -TargetPath $Resources -RequiredBytes ([long]($backupLen * 1.1)) -Purpose "the -Restore move-in copy (install volume)"
  }
  $stage = Copy-BackupToStaging -BackupDir $backup.FullName
  try {
    Invoke-AsarSwap -ResourcesDir $Resources `
      -CandidateAsar (Join-Path $stage "app.asar") `
      -CandidateUnpacked (Join-Path $stage "app.asar.unpacked") `
      -MinAsarBytes $restoreFloor `
      -BackupAsar (Join-Path $backup.FullName "app.asar")
  } finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path $MarkerPath) { Remove-Item $MarkerPath -Force }
  Write-Host "[2/2] Marker removed."
  Write-Host "SUCCESS - original app.asar restored from $($backup.FullName)"
  exit 0
}

# Asar content probe: the app auto-update replaces app.asar wholesale but
# leaves the marker file alone, so a surviving marker no longer proves the
# patch is alive. Scan the asar bytes for the engine's signature strings
# (cheap Buffer.includes pass; every string must be present to call it
# patched). Keep this list in sync with the engine's patch-site strings.
$AsarPatchedProbe = $null
if (-not $Restore) {
  Write-Host "[0/5] Probing app.asar for patch signatures..."
  $probeOut = & $NodeExe -e "const fs=require('fs');try{const b=fs.readFileSync(process.argv[1]);const need=['ZCODE_ICON_DIR','ZCODE_AUMID_SUFFIX','zcode-bidi-auto-style'];const missing=need.filter(s=>!b.includes(s));if(missing.length){console.log('MISSING '+missing.join(','));process.exit(1)}console.log('OK all-present');process.exit(0)}catch(e){console.error('PROBE_ERROR '+String((e&&e.message)||e));process.exit(3)}" $Asar
  # Exit codes alone are ambiguous (node also exits 1 on uncaught exceptions),
  # so the probe's text must corroborate the code before either branch is
  # trusted: 0+'OK' -> patched, 1+'MISSING' -> update-wiped, anything else ->
  # hard abort (a probe crash must never masquerade as an update-wiped asar,
  # which would take a fresh backup of a still-patched tree and shadow the
  # pristine one for -Restore).
  $probeText = ($probeOut -join " ")
  if ($LASTEXITCODE -eq 0 -and $probeText -match 'OK all-present') { $AsarPatchedProbe = $true }
  elseif ($LASTEXITCODE -eq 1 -and $probeText -match 'MISSING') { $AsarPatchedProbe = $false }
  else { throw ("app.asar probe failed (node exit {0}): {1}" -f $LASTEXITCODE, $probeText) }
  Write-Host ("      probe: {0}" -f $(if ($AsarPatchedProbe) { "patch signatures present" } else { "patch signatures MISSING (fresh or update-wiped asar)" }))
}

if (Test-Path $MarkerPath) {
  $markerEngineVersion = 1
  try {
    $existing = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
    if ($existing.patchVersion) { $markerEngineVersion = [int]$existing.patchVersion }
  } catch { Write-Host "Marker unreadable - will re-patch." }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $Force -and $AsarPatchedProbe) {
    Write-Host "Already patched at engine v$markerEngineVersion (marker + asar signatures verified). Use -Force to re-patch."
    exit 0
  }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $AsarPatchedProbe) {
    Write-Host "App update detected - patched asar replaced, marker stale - re-patching."
  }
  if ($markerEngineVersion -lt $script:EngineVersion) {
    Write-Host "Marker is engine v$markerEngineVersion - upgrading to v$script:EngineVersion (re-patching)."
  }
}

Assert-ZCodeClosed -InstallPath $Install

# Total wall clock for the mutating part (excludes -WaitForClose polling).
$SwTotal = [System.Diagnostics.Stopwatch]::StartNew()

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$UnpackedDir = Join-Path $Resources "app.asar.unpacked"
$AsarLen = (Get-Item $Asar).Length
# Backup selection. Re-patch of a STILL-PATCHED tree (engine upgrade, asar
# probe present): keep pointing at the ORIGINAL backup captured by the first
# run so -Restore always returns to the pristine asar, not to an intermediate
# patched state. Update-wiped tree (probe missing): the current asar is a NEW
# pristine version - never fold it onto the old backup (a later -Restore would
# downgrade the app), so capture a fresh timestamped backup and point the new
# marker at it instead.
$BackupDir = Join-Path $BackupsRoot $Stamp
$ReuseOriginalBackup = $false
if ($AsarPatchedProbe -and $existing -and $existing.backupDir -and (Test-Path (Join-Path $existing.backupDir "app.asar"))) {
  $ReuseOriginalBackup = $true
  $BackupDir = $existing.backupDir
  Write-Host "[1/5] Reusing original backup at $BackupDir"
}
if (-not $ReuseOriginalBackup) {
  if ($existing -and -not $AsarPatchedProbe) { Write-Host "App-update recovery - backing up the new pristine asar." }
  elseif ($existing) { Write-Host "Original backup missing - creating fresh backup of current state." }
  Write-Host "[1/5] Backup to $BackupDir"
  # Peak-disk preflight (single check, before anything is written). The peak
  # has TWO coexisting files - the backup copy and the engine's candidate:
  #   - install volume == %TEMP% volume: backup (1.25x) + candidate (1.25x)
  #     coexist and the swap is a pure rename -> require ~2.6x in total;
  #   - different volumes: the install volume holds the backup (1.25x) PLUS
  #     the cross-volume candidate move-in copy (~1.0x) at swap time -> ~2.3x
  #     there, and the candidate alone (~1.3x) on the TEMP volume.
  $TempRoot = (Split-Path -Qualifier $env:TEMP) + "\"
  $InstallRoot = (Split-Path -Qualifier $BackupDir) + "\"
  if ($TempRoot -ieq $InstallRoot) {
    Assert-DiskFreeFor -TargetPath $BackupDir -RequiredBytes ([long]($AsarLen * 2.6)) -Purpose "backup + patched candidate (same volume as temp)"
  } else {
    Assert-DiskFreeFor -TargetPath $BackupDir -RequiredBytes ([long]($AsarLen * 2.3)) -Purpose "backup + candidate swap-in copy (install volume)"
    Assert-DiskFreeFor -TargetPath $env:TEMP -RequiredBytes ([long]($AsarLen * 1.3)) -Purpose "the patched candidate asar (temp)"
  }
  $swBackup = [System.Diagnostics.Stopwatch]::StartNew()
  New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
  Copy-Item $Asar (Join-Path $BackupDir "app.asar")
  if (Test-Path $UnpackedDir) {
    Copy-Item $UnpackedDir (Join-Path $BackupDir "app.asar.unpacked") -Recurse
  }
  if (-not (Test-Path (Join-Path $BackupDir "app.asar"))) { throw "backup verify FAILED: app.asar not copied" }
  $swBackup.Stop()
  Write-Host ("      backup done in {0:N1}s" -f $swBackup.Elapsed.TotalSeconds)
}
$Work = Join-Path $env:TEMP ("zcode-icon-patch-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$CandidateAsar = Join-Path $Work "app.asar.candidate"
$ChecksDir = Join-Path $Work "checks"

try {
  New-Item -ItemType Directory -Path $Work -Force | Out-Null

  # -Force re-patch must rebuild from the PRISTINE backup, never the live
  # asar: the engine's done-anchors treat already-patched sites as done, so
  # reading the live (already-patched) file ships the OLD injected code
  # while still printing SUCCESS (2026-10-18 AutoClaw: two -Force runs shipped
  # no changes; bug sweep 15). Only rebuild from a backup when the LIVE asar
  # is still engine-patched; after an app update the live asar is the new
  # pristine version and must be the surgery source (the backup would roll
  # the app back a version).
  $extractSource = $Asar
  if ($Force -and $AsarPatchedProbe -and $existing -and $existing.backupDir) {
    $pristineAsar = Join-Path $existing.backupDir "app.asar"
    if (Test-Path $pristineAsar) {
      $extractSource = $pristineAsar
      Write-Host "[2/5] Rebuilding from the PRISTINE backup asar (live file is already engine-patched)..."
    } else {
      Write-Host "WARNING: marker's original backup is missing - reading the live (patched) asar; the engine's done-anchors will skip already-patched sites."
    }
  }

  # [2/5] asar surgery (engine v9): the engine ranges-reads only the text
  # entries of the source asar, applies the patch set in memory, writes the
  # patched js through node --check, rebuilds the candidate (untouched payload
  # region copied byte-for-byte, patched contents appended at the tail, only
  # patched header entries rewritten) and verifies it (header walk + whole-
  # region byte compare + patched-content compare). No extract-to-disk, no
  # repack, no npx - one node process, a few seconds.
  # (Candidate disk space was covered by the combined peak preflight above.)
  Write-Host "[2/5] Patching asar in memory + rebuilding candidate (asar surgery)..."
  $engineOut = & $NodeExe $PatchEngine $extractSource $CandidateAsar $ChecksDir
  $engineJson = $null
  try { $engineJson = ($engineOut -join "`n") | ConvertFrom-Json } catch {
    throw ("patch engine returned invalid JSON: {0}" -f ($engineOut -join "`n"))
  }
  if (-not $engineJson.ok) {
    throw ("patch engine FAILED: {0} | totals: {1}" -f $engineJson.error, ($engineJson.totals | ConvertTo-Json -Compress))
  }
  $engineJson.results | ForEach-Object {
    Write-Host ("      {0}: window={1} tray={2} aumid={3}" -f $_.file, $_.counts."icon-window", $_.counts."icon-tray", $_.counts."aumid-suffix")
  }
  if ($engineJson.timings) {
    Write-Host ("      engine: patch {0}ms, node --check {1}ms, rebuild {2}ms, verify {3}ms" -f `
      $engineJson.timings.readPatchMs, $engineJson.timings.syntaxMs, $engineJson.timings.rebuildMs, $engineJson.timings.verifyMs)
  }

  Write-Host "[3/5] Swapping patched asar into install..."
  $patchFloor = [long]((Get-Item $Asar).Length / 2)
  $swSwap = [System.Diagnostics.Stopwatch]::StartNew()
  Invoke-AsarSwap -ResourcesDir $Resources -CandidateAsar $CandidateAsar -MinAsarBytes $patchFloor -BackupAsar (Join-Path $BackupDir "app.asar") -SkipUnpackedSwap
  $swSwap.Stop()
  Write-Host ("      swap done in {0:N1}s" -f $swSwap.Elapsed.TotalSeconds)

  Write-Host "[4/5] Writing marker..."
  $marker = [ordered]@{
    appliedAt    = (Get-Date -Format "o")
    patchVersion = [int]$engineJson.engineVersion
    installDir   = $Install
    backupDir    = $BackupDir
    patchedFiles = @($engineJson.results | ForEach-Object { $_.file })
    totals       = $engineJson.totals
    timings      = $engineJson.timings
  }
  $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $MarkerPath -Encoding UTF8
  if (-not (Test-Path $MarkerPath)) { throw "marker verify FAILED: not written" }
  $SwTotal.Stop()
  Write-Host ("      marker written - patch completed in {0:N1}s total" -f $SwTotal.Elapsed.TotalSeconds)
} finally {
  if (Test-Path $Work) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "SUCCESS - ZCode patched. Clone instance env vars (set by the launcher):"
Write-Host "  ZCODE_ICON_DIR      -> dir containing icon_windows.png + tray_icon.ico for this clone"
Write-Host "  ZCODE_AUMID_SUFFIX  -> taskbar button suffix (2/3/4 per instance)"
Write-Host "  ZCODE_ACCENT_HEX    -> in-app accent color (splash/sidebar/badge)"
Write-Host "  ZCODE_INSTANCE_NAME -> window title suffix (Blue/Yellow/Green)"
Write-Host "Bidi auto-direction (v7) is ON for every instance; set ZCODE_BIDI_OFF=1 to disable."
Write-Host "Primary instance sets none of these -> unchanged behavior."
