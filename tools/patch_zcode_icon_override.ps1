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
  verified by re-read/re-extract (no silent success). A backup of app.asar and
  app.asar.unpacked is taken before any change; -Restore rolls back.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_icon_override.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_icon_override.ps1 -Force
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_zcode_icon_override.ps1 -Restore
#>
[CmdletBinding()]
param(
  [switch]$Restore,
  [switch]$Force,
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
$script:EngineVersion = 6

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
  $procs = @(Get-Process -Name "ZCode" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and ($_.Path -like "$InstallPath*") })
  if ($procs.Count -gt 0) {
    throw ("ZCode.exe from this install dir is running (PID(s): {0}). Close all its windows and try again." -f
      (($procs | Select-Object -First 5 -ExpandProperty Id) -join ", "))
  }
}

function Find-ToolCmd {
  param([string]$Name, [string]$MissingMessage)
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) { throw $MissingMessage }
  return $cmd.Source
}

function Invoke-AsarCli {
  # & npx with native PowerShell argument passing - no cmd.exe quoting pitfalls.
  param([string[]]$NpxArgs)
  & $script:NpxExe @NpxArgs
  if ($LASTEXITCODE -ne 0) {
    throw ("asar command failed (exit {0}): npx {1}" -f $LASTEXITCODE, ($NpxArgs -join " "))
  }
}

function Get-RelFilePaths {
  param([string]$Root)
  $full = (Resolve-Path $Root).Path.TrimEnd("\")
  $len = $full.Length + 1
  $set = New-Object "System.Collections.Generic.HashSet[string]"
  Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
    [void]$set.Add($_.FullName.Substring($len).Replace("\", "/"))
  }
  return $set
}

function Invoke-AsarSwap {
  # Move candidate asar+unpacked into the install resources dir; rollback on failure.
  # MinAsarBytes: sanity floor - candidate must keep at least half the original size,
  # so a truncated/corrupted swap is refused (recover afterwards with -Restore).
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
  # verify-after swap: targets exist, asar has a plausible size
  if (-not (Test-Path $asar) -or -not (Test-Path $unpacked)) { throw "post-swap verify FAILED: targets missing" }
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
$script:NpxExe = Find-ToolCmd "npx.cmd" "npx not found on PATH (needed for @electron/asar)."
$Install = Resolve-InstallDir -Override $InstallDir
$Resources = Join-Path $Install "resources"
$Asar = Join-Path $Resources "app.asar"
$MarkerPath = Join-Path $Resources "zcode-icon-patch.marker.json"
$BackupsRoot = Join-Path $Resources "ID_Backups"
$PatchEngine = Join-Path $PSScriptRoot "patch_zcode_icon_override.mjs"

Write-Host "Install dir : $Install"

if ($Restore) {
  Assert-ZCodeClosed -InstallPath $Install
  $backup = Get-ChildItem -LiteralPath $BackupsRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Where-Object { Test-Path (Join-Path $_.FullName "app.asar") } |
    Select-Object -First 1
  if (-not $backup) { throw "No backup found under $BackupsRoot - nothing to restore." }
  $restoreFloor = [long]([IO.File]::ReadAllBytes((Join-Path $backup.FullName "app.asar")).Length / 2)
  Write-Host "[1/2] Restoring app.asar + app.asar.unpacked from $($backup.Name) (staged copy)"
  $stage = Copy-BackupToStaging -BackupDir $backup.FullName
  try {
    Invoke-AsarSwap -ResourcesDir $Resources `
      -CandidateAsar (Join-Path $stage "app.asar") `
      -CandidateUnpacked (Join-Path $stage "app.asar.unpacked") `
      -MinAsarBytes $restoreFloor
  } finally {
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  }
  if (Test-Path $MarkerPath) { Remove-Item $MarkerPath -Force }
  Write-Host "[2/2] Marker removed."
  Write-Host "SUCCESS - original app.asar restored from $($backup.FullName)"
  exit 0
}

if (Test-Path $MarkerPath) {
  $markerEngineVersion = 1
  try {
    $existing = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
    if ($existing.patchVersion) { $markerEngineVersion = [int]$existing.patchVersion }
  } catch { Write-Host "Marker unreadable - will re-patch." }
  if ($markerEngineVersion -ge $script:EngineVersion -and -not $Force) {
    Write-Host "Already patched at engine v$markerEngineVersion (marker exists). Use -Force to re-patch."
    exit 0
  }
  if ($markerEngineVersion -lt $script:EngineVersion) {
    Write-Host "Marker is engine v$markerEngineVersion - upgrading to v$script:EngineVersion (re-patching)."
  }
}

Assert-ZCodeClosed -InstallPath $Install

$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$UnpackedDir = Join-Path $Resources "app.asar.unpacked"
# On re-patch (marker upgrade), keep pointing at the ORIGINAL backup captured by
# the first run so -Restore always returns to the pristine asar, not to an
# intermediate patched state.
$BackupDir = Join-Path $BackupsRoot $Stamp
if ($existing -and $existing.backupDir -and (Test-Path (Join-Path $existing.backupDir "app.asar"))) {
  $BackupDir = $existing.backupDir
  Write-Host "[1/7] Reusing original backup at $BackupDir"
} else {
  if ($existing) { Write-Host "Original backup missing - creating fresh backup of current state." }
  Write-Host "[1/7] Backup to $BackupDir"
  New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
  Copy-Item $Asar (Join-Path $BackupDir "app.asar")
  if (Test-Path $UnpackedDir) {
    Copy-Item $UnpackedDir (Join-Path $BackupDir "app.asar.unpacked") -Recurse
  }
  if (-not (Test-Path (Join-Path $BackupDir "app.asar"))) { throw "backup verify FAILED: app.asar not copied" }
}
$Work = Join-Path $env:TEMP ("zcode-icon-patch-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
$Extracted = Join-Path $Work "extracted"
$CandidateAsar = Join-Path $Work "app.asar.candidate"
$CandidateUnpacked = "$CandidateAsar.unpacked"

try {
  New-Item -ItemType Directory -Path $Work -Force | Out-Null

  Write-Host "[2/7] Extracting app.asar (~370 MB, takes a minute)..."
  Invoke-AsarCli @("--yes", "@electron/asar", "extract", $Asar, $Extracted)

  Write-Host "[3/7] Applying icon/AUMID overrides..."
  $engineOut = & $NodeExe $PatchEngine $Extracted
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

  # verify-after patch: re-read each patched file from the extracted tree and
  # require every marker the engine reported for that file
  foreach ($r in $engineJson.results) {
    if (-not $r.appliedMarkers -or @($r.appliedMarkers).Count -eq 0) { continue }
    $patchedFile = Join-Path $Extracted ($r.file -replace "/", "\")
    $content = [IO.File]::ReadAllText($patchedFile)
    foreach ($marker in $r.appliedMarkers) {
      if (-not $content.Contains($marker)) {
        throw ("patch verify FAILED after write: marker '{0}' missing in {1}" -f $marker, $r.file)
      }
    }
  }

  # Syntax gate: markers alone cannot catch a structurally broken bundle.
  # (v3 main-args bug dropped a template-literal backtick; every marker was
  # present yet the main process died with "Unexpected identifier 'blocked'".)
  foreach ($r in $engineJson.results) {
    if ($r.file -notmatch "\.(js|cjs|mjs)$") { continue }
    $syntaxFile = Join-Path $Extracted ($r.file -replace "/", "\")
    # cmd /c so node stderr can't trigger PS 5.1 NativeCommandError under EAP=Stop
    $checkOut = cmd /c "`"$NodeExe`" --check `"$syntaxFile`" 2>&1" | Out-String
    if ($LASTEXITCODE -ne 0) {
      throw ("patch verify FAILED: node --check rejected {0} - aborting before swap`n{1}" -f $r.file, $checkOut.Trim())
    }
    Write-Host ("      {0}: node --check OK" -f $r.file)
  }

  Write-Host "[4/7] Packing candidate asar..."
  $unpackGlobs = New-Object "System.Collections.Generic.List[string]"
  $unpackGlobs.Add("*.{node,dll,dylib,exe}")
  $unpackDirs = New-Object "System.Collections.Generic.List[string]"
  # mirror upstream repack: explicit prebuilds dirs present in the original sidecar
  $origUnpacked = if (Test-Path $UnpackedDir) { Get-RelFilePaths -Root $UnpackedDir } else {
    New-Object "System.Collections.Generic.HashSet[string]"
  }
  $origUnpacked | ForEach-Object {
    if ($_ -match "^(node_modules/[^/]+/prebuilds/[^/]+)/") {
      $d = $Matches[1]
      if (-not $unpackDirs.Contains($d)) { [void]$unpackDirs.Add($d) }
    }
  }

  $maxTries = 4
  for ($try = 1; $try -le $maxTries; $try++) {
    $packArgs = @("--yes", "@electron/asar", "pack", $Extracted, $CandidateAsar)
    foreach ($g in $unpackGlobs) { $packArgs += "--unpack"; $packArgs += $g }
    foreach ($d in $unpackDirs) { $packArgs += "--unpack-dir"; $packArgs += $d }
    Invoke-AsarCli $packArgs

    $candUnpackedSet = if (Test-Path $CandidateUnpacked) { Get-RelFilePaths -Root $CandidateUnpacked } else {
      New-Object "System.Collections.Generic.HashSet[string]"
    }
    $missing = @($origUnpacked | Where-Object { -not $candUnpackedSet.Contains($_) })
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
  $candCount = if (Test-Path $CandidateUnpacked) { (Get-RelFilePaths -Root $CandidateUnpacked).Count } else { 0 }
  Write-Host ("      unpacked sidecar files: {0} (original {1})" -f $candCount, $origUnpacked.Count)

  Write-Host "[5/7] Verifying candidate asar contents..."
  $VerifyDir = Join-Path $Work "verify"
  foreach ($r in $engineJson.results) {
    if (-not $r.appliedMarkers -or @($r.appliedMarkers).Count -eq 0) { continue }
    New-Item -ItemType Directory -Path $VerifyDir -Force | Out-Null
    Get-ChildItem -LiteralPath $VerifyDir -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    $relWin = $r.file -replace "/", "\"
    Push-Location $VerifyDir
    try {
      # NB: on Windows @electron/asar extract-file expects backslash archive paths.
      Invoke-AsarCli @("--yes", "@electron/asar", "extract-file", $CandidateAsar, $relWin)
    } finally { Pop-Location }
    $verifyFile = Get-ChildItem -LiteralPath $VerifyDir -Recurse -File |
      Where-Object { $_.Name -eq (Split-Path -Leaf $relWin) } | Select-Object -First 1
    if (-not $verifyFile) { throw "patch verify FAILED: could not extract $($r.file) from candidate" }
    $vc = [IO.File]::ReadAllText($verifyFile.FullName)
    foreach ($marker in $r.appliedMarkers) {
      if (-not $vc.Contains($marker)) {
        throw ("patch verify FAILED inside candidate asar: marker '{0}' missing in {1}" -f $marker, $r.file)
      }
    }
    Write-Host ("      {0}: {1} marker(s) verified" -f $r.file, @($r.appliedMarkers).Count)
  }

  Write-Host "[6/7] Swapping patched asar into install..."
  $patchFloor = [long]((Get-Item $Asar).Length / 2)
  Invoke-AsarSwap -ResourcesDir $Resources -CandidateAsar $CandidateAsar -CandidateUnpacked $CandidateUnpacked -MinAsarBytes $patchFloor

  Write-Host "[7/7] Writing marker..."
  $marker = [ordered]@{
    appliedAt    = (Get-Date -Format "o")
    patchVersion = [int]$engineJson.engineVersion
    installDir   = $Install
    backupDir    = $BackupDir
    patchedFiles = @($engineJson.results | ForEach-Object { $_.file })
    totals       = $engineJson.totals
  }
  $marker | ConvertTo-Json -Depth 4 | Set-Content -Path $MarkerPath -Encoding UTF8
  if (-not (Test-Path $MarkerPath)) { throw "marker verify FAILED: not written" }
} finally {
  if (Test-Path $Work) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "SUCCESS - ZCode patched. Clone instance env vars (set by the launcher):"
Write-Host "  ZCODE_ICON_DIR      -> dir containing icon_windows.png + tray_icon.ico for this clone"
Write-Host "  ZCODE_AUMID_SUFFIX  -> taskbar button suffix (2/3/4 per instance)"
Write-Host "  ZCODE_ACCENT_HEX    -> in-app accent color (splash/sidebar/badge)"
Write-Host "  ZCODE_INSTANCE_NAME -> window title suffix (Blue/Yellow/Green)"
Write-Host "Primary instance sets none of these -> unchanged behavior."
