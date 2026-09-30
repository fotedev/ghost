#requires -Version 5.1
<#
.SYNOPSIS
  Checks GitHub for GHOST repo updates and (optionally) applies them.
  GHOST.bat main menu [U] / Maintenance [2]. Per-user, no admin rights needed.

.DESCRIPTION
  Four situations, gated in this order:

  1. Git missing + a GHOST folder copy (Download ZIP)  -> direct-download
     update without Git: fetch the latest GitHub archive, extract it, and
     replace the GHOST program files in place. Add/overwrite only - nothing
     is ever deleted - every replaced file is backed up first to
     %TEMP%\ghost-backup-<ts> and verify-after compared by SHA256.
  2. Git missing otherwise -> guidance (winget / git-scm.com / manual ZIP)
     and exit 1.
  3. Git present + not a git work tree (Download ZIP) -> offer an in-place
     conversion into a real git clone: git init + symbolic-ref main +
     core.longpaths/autocrlf=false + remote add origin (-OriginUrl) + fetch +
     reset --mixed to detect real local edits (EOL-only noise is ignored via
     --ignore-cr-at-eol; the committed .gitattributes governs the rest) +
     reset --hard. A failed fetch, a setup failure or a declined overwrite
     removes the temporary .git again, leaving the ZIP folder untouched.
     Verify-after re-reads HEAD == origin before the normal update flow runs.
  4. Git present + a git clone -> the classic flow: fetch origin
     (--tags --prune), compare HEAD with the remote default branch, list the
     new commits; without -CheckOnly ask before a git pull --ff-only.

  Refuses to update when a non-default or detached branch, or local commits,
  would block the fast-forward. A dirty working tree gets an interactive
  offer: stash -u -> pull -> stash pop; a failed pop KEEPS the stash (nothing
  is lost) and prints how to reapply. Ignored files (archive/, .envlocal,
  *.lnk, ID_Backups/) are never touched by the stash or by the ZIP sync.

  Verify-after is mandatory (never silent-success) on every path. A failed
  fetch (offline) is a warning, not a failure. -CheckOnly never writes: on a
  ZIP copy it reports only. -Convert answers the interactive confirmation
  prompts non-interactively (the local-edits overwrite prompt still aborts
  safely with the file list).

.PARAM CheckOnly
  Report only, write nothing.

.PARAM Convert
  Non-interactive affirmative for the conversion / direct-download prompt.

.PARAM OriginUrl
  Remote URL used by the in-place conversion (point it at your fork).

.PARAM ZipUrl
  Archive URL for the direct-download path; also accepts a local
  file:///... path (used for offline testing, since Invoke-WebRequest on
  PS 5.1 rejects the file:// scheme).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\update_ghost.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\update_ghost.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
  [switch]$CheckOnly,
  [switch]$Convert,
  [string]$OriginUrl = 'https://github.com/fotedev/ghost.git',
  [string]$ZipUrl = 'https://github.com/fotedev/ghost/archive/refs/heads/main.zip'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$script:Failed = $false

function Invoke-Git {
  # Runs git in the repo root, capturing stdout/stderr via temp files under
  # $env:TEMP so stderr noise (fetch progress, ref summaries) can never trip
  # ErrorActionPreference = Stop (a PS 5.1 NativeCommandError pitfall).
  param([string[]]$GitArguments)
  $outFile = Join-Path $env:TEMP ('ghost-upd-out-' + [Guid]::NewGuid().ToString('N') + '.txt')
  $errFile = Join-Path $env:TEMP ('ghost-upd-err-' + [Guid]::NewGuid().ToString('N') + '.txt')
  try {
    $proc = Start-Process -FilePath 'git' -ArgumentList $GitArguments -WorkingDirectory $RepoRoot `
      -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = @()
    $err = @()
    if (Test-Path -LiteralPath $outFile) { $out = @(Get-Content -LiteralPath $outFile -Encoding UTF8) }
    if (Test-Path -LiteralPath $errFile) { $err = @(Get-Content -LiteralPath $errFile -Encoding UTF8) }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = $out; StdErr = $err }
  }
  finally {
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Write-Refusal {
  param([string]$Message)
  Write-Host "  [refused] $Message" -ForegroundColor Red
}

function Get-StashCount {
  # rev-list on refs/stash fails when no stash exists yet -> treat as 0.
  $r = Invoke-Git 'rev-list','--count','refs/stash'
  if ($r.ExitCode -eq 0 -and $r.StdOut.Count -gt 0) { return [int]($r.StdOut[0].Trim()) }
  return 0
}

function Test-GhostShape {
  # Pins the ZIP-copy handling to a folder that actually contains the GHOST
  # launcher - random folders are never converted or overwritten.
  param([string]$Root)
  return (Test-Path -LiteralPath (Join-Path $Root 'GHOST.bat') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Root 'src') -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $Root 'tools\update_ghost.ps1') -PathType Leaf)
}

function Remove-GhostPathRobust {
  # Deletes a path this session created, surviving transient Windows locks
  # (a just-exited git.exe / credential helper) and read-only attributes.
  # Returns $true on success; the CALLER prints its own warning on $false.
  param([string]$Path)
  if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $true }
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try { $_.Attributes = [System.IO.FileAttributes]::Normal } catch { }
      }
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      return $true
    }
    catch {
      if ($attempt -lt 3) { Start-Sleep -Seconds 1 }
    }
  }
  return $false
}

function Show-GitInstallTip {
  Write-Host 'Tip: winget install --id Git.Git -e --source winget' -ForegroundColor Gray
  Write-Host '     or download from https://git-scm.com/download/win' -ForegroundColor Gray
  Write-Host ("     or grab the latest ZIP: {0}" -f $ZipUrl) -ForegroundColor Gray
}

function Update-GhostZipCopy {
  # No-git path: update a ZIP-extracted GHOST folder by downloading the
  # latest GitHub archive. Add/overwrite only - nothing is ever deleted;
  # every replaced file is backed up to %TEMP%\ghost-backup-<ts> first and
  # verify-after compared by SHA256. Returns 'updated', 'aborted' or 'failed'.
  if ($CheckOnly) {
    Write-Host '  [warn] this folder is a ZIP copy and Git is not installed - cannot check for updates here.' -ForegroundColor Yellow
    Write-Host '  Run again without -CheckOnly to update it by direct download.' -ForegroundColor Yellow
    return 'aborted'
  }
  Write-Host '  Git is not installed, but this ZIP copy can still be updated directly from GitHub:' -ForegroundColor Yellow
  Write-Host '    - download the latest archive and replace the GHOST program files in place'
  Write-Host '    - your local files (.envlocal, ID_Backups, shortcuts, anything you added) are kept'
  Write-Host '    - no file is ever deleted; every replaced file is backed up first'
  $answer = 'n'
  if ($Convert) { $answer = 'y' } else { $answer = Read-Host '  Update this ZIP copy via direct download (y/N)' }
  if ($answer -notmatch '^(y|yes)$') {
    Write-Host 'Aborted. Nothing was changed.' -ForegroundColor Yellow
    Show-GitInstallTip
    return 'aborted'
  }

  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $tmpZip = Join-Path $env:TEMP ("ghost-update-{0}.zip" -f $stamp)
  $tmpDir = Join-Path $env:TEMP ("ghost-update-{0}" -f $stamp)
  $backupDir = Join-Path $env:TEMP ("ghost-backup-{0}" -f $stamp)
  $cleanupPaths = @($tmpZip, $tmpDir)
  try {
    # ---- [1/4] Download -------------------------------------------------
    Write-Host '[1/4] Downloading the latest archive...'
    $localZip = $null
    if ($ZipUrl -like 'file://*') {
      $localZip = ([System.Uri]::new($ZipUrl)).LocalPath
    }
    elseif (Test-Path -LiteralPath $ZipUrl -PathType Leaf) {
      $localZip = $ZipUrl
    }
    if ($localZip) {
      # Local archive - copy instead of Invoke-WebRequest, which rejects the
      # file:// scheme on PS 5.1 ("The URI prefix is not recognized").
      Copy-Item -LiteralPath $localZip -Destination $tmpZip -Force
      Write-Host ("  [ok] local archive: {0}" -f $localZip) -ForegroundColor Green
    }
    else {
      try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $ZipUrl -OutFile $tmpZip -UseBasicParsing
      }
      catch {
        Write-Host '  [warn] could not reach GitHub - nothing was changed.' -ForegroundColor Yellow
        Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'Check the connection and run again.' -ForegroundColor Yellow
        return 'aborted'
      }
    }
    $zipItem = Get-Item -LiteralPath $tmpZip
    # 100KB floor catches an HTML error page from a web download; a local
    # archive (tests, fork mirrors) may be tiny - its layout is validated
    # by Test-GhostShape after extraction anyway.
    $minSize = 100KB
    if ($localZip) { $minSize = 1 }
    if ($zipItem.Length -lt $minSize) {
      Write-Host '  [FAILED] the download did not produce a valid archive.' -ForegroundColor Red
      return 'failed'
    }

    # ---- [2/4] Extract ----------------------------------------------------
    Write-Host '[2/4] Extracting...'
    Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmpDir -Force
    $tops = @(Get-ChildItem -LiteralPath $tmpDir -Force)
    $srcRoot = $tmpDir
    if ($tops.Count -eq 1 -and $tops[0].PSIsContainer) { $srcRoot = $tops[0].FullName }
    if (-not (Test-GhostShape -Root $srcRoot)) {
      Write-Host '  [FAILED] unexpected archive layout - no GHOST checkout inside.' -ForegroundColor Red
      return 'failed'
    }
    Write-Host ("  [ok] extracted: {0}" -f $srcRoot)

    # ---- [3/4] Sync (add/overwrite only, nothing is deleted) ---------------
    Write-Host '[3/4] Syncing into the folder (add/overwrite only, nothing is deleted)...'
    $batPath = Join-Path $RepoRoot 'GHOST.bat'
    $oldBatHash = $null
    if (Test-Path -LiteralPath $batPath -PathType Leaf) {
      $oldBatHash = (Get-FileHash -LiteralPath $batPath -Algorithm SHA256).Hash
    }
    $added = 0
    $updated = 0
    $identical = 0
    $failedFiles = @()
    $sourceFiles = @(Get-ChildItem -LiteralPath $srcRoot -Recurse -File -Force)
    foreach ($srcFile in $sourceFiles) {
      $rel = $srcFile.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
      if ($rel -eq '.git' -or $rel -like '.git\*' -or $rel -like '.git/*') {
        # defensive: never extract a .git tree from a custom archive
        continue
      }
      try {
        $dest = Join-Path $RepoRoot $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
          $null = New-Item -ItemType Directory -Path $destDir -Force
        }
        $srcHash = (Get-FileHash -LiteralPath $srcFile.FullName -Algorithm SHA256).Hash
        $destExists = Test-Path -LiteralPath $dest -PathType Leaf
        if ($destExists) {
          $destHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
          if ($destHash -eq $srcHash) { $identical++; continue }
          # backup first, then overwrite
          $backupDest = Join-Path $backupDir $rel
          $backupParent = Split-Path -Parent $backupDest
          if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $backupParent -Force
          }
          Copy-Item -LiteralPath $dest -Destination $backupDest -Force
        }
        Copy-Item -LiteralPath $srcFile.FullName -Destination $dest -Force
        $afterHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($afterHash -ne $srcHash) {
          $failedFiles += $rel
        }
        elseif ($destExists) { $updated++ }
        else { $added++ }
      }
      catch {
        $failedFiles += $rel
      }
    }

    # ---- [4/4] Verify-after (never silent-success) --------------------------
    Write-Host '[4/4] Verify-after...'
    if ($failedFiles.Count -gt 0) {
      Write-Host ("  [FAILED] {0} file(s) did not verify after copy:" -f $failedFiles.Count) -ForegroundColor Red
      $failedFiles | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
      if ($failedFiles.Count -gt 10) { Write-Host ("    ... and {0} more" -f ($failedFiles.Count - 10)) }
      if ($updated -gt 0 -or (Test-Path -LiteralPath $backupDir)) {
        Write-Host ("  Pre-update copies of replaced files: {0}" -f $backupDir) -ForegroundColor Yellow
      }
      return 'failed'
    }
    Write-Host ("  [ok] {0} file(s) updated, {1} added, {2} already identical, 0 deleted" -f $updated, $added, $identical) -ForegroundColor Green
    if ($updated -gt 0) {
      Write-Host ("  [ok] previous versions backed up: {0}" -f $backupDir) -ForegroundColor Green
    }
    $cl = Join-Path $srcRoot 'CHANGELOG.md'
    if (Test-Path -LiteralPath $cl -PathType Leaf) {
      $verLine = Get-Content -LiteralPath $cl -TotalCount 8 | Where-Object { $_ -match '^##\s' } | Select-Object -First 1
      if ($verLine) { Write-Host ("  latest version: {0}" -f ($verLine -replace '^#+\s*', '')) }
    }
    if ($oldBatHash) {
      $newBatHash = (Get-FileHash -LiteralPath $batPath -Algorithm SHA256).Hash
      if ($newBatHash -ne $oldBatHash) {
        # cmd.exe reads batch files incrementally - a replaced GHOST.bat can
        # confuse the still-running menu window.
        Write-Host '  note: the launcher was updated - close this window and relaunch GHOST.bat.' -ForegroundColor Yellow
      }
    }
    Write-Host 'SUCCESS - GHOST updated (direct download).' -ForegroundColor Green
    Write-Host 'Note: this folder is still a plain copy - install Git for full update support:' -ForegroundColor Gray
    Show-GitInstallTip
    return 'updated'
  }
  finally {
    foreach ($p in $cleanupPaths) {
      if (-not (Remove-GhostPathRobust -Path $p)) {
        Write-Host ("  [warn] could not remove the temporary item - delete it manually: {0}" -f $p) -ForegroundColor Yellow
      }
    }
  }
}

function Convert-GhostZipToClone {
  # In-place conversion of a ZIP-extracted folder into a real git clone.
  # Setup failures, a failed fetch and a declined overwrite remove the
  # temporary .git again (only when this run created it). Returns
  # 'converted', 'aborted' or 'failed'.
  if ($CheckOnly) {
    Write-Host '  [warn] this folder is a Download ZIP copy, not a git clone - nothing to compare here.' -ForegroundColor Yellow
    Write-Host '  Run again without -CheckOnly to convert it into a git clone.' -ForegroundColor Yellow
    return 'aborted'
  }
  $gitDir = Join-Path $RepoRoot '.git'
  $gitExistedBefore = Test-Path -LiteralPath $gitDir
  Write-Host ("  This folder is a Download ZIP copy. I can convert it in place into a git clone of {0}:" -f $OriginUrl) -ForegroundColor Yellow
  Write-Host '    - git init + fetch, then align the files to the latest GitHub version'
  Write-Host '    - your extra files (.envlocal, ID_Backups, shortcuts, anything untracked) are kept'
  Write-Host '    - any tracked file you edited by hand will be overwritten'
  $answer = 'n'
  if ($Convert) { $answer = 'y' } else { $answer = Read-Host '  Convert this folder into a git clone (y/N)' }
  if ($answer -notmatch '^(y|yes)$') {
    Write-Host 'Aborted. Nothing was changed. To update manually:' -ForegroundColor Yellow
    Write-Host ("  git clone {0}" -f $OriginUrl) -ForegroundColor Gray
    return 'aborted'
  }

  # Removes the .git created by THIS run (never one that existed before).
  $removeTempGit = {
    if (-not $gitExistedBefore -and (Test-Path -LiteralPath $gitDir)) {
      if (-not (Remove-GhostPathRobust -Path $gitDir)) {
        Write-Host ("  [warn] could not remove the temporary .git - delete it manually: {0}" -f $gitDir) -ForegroundColor Yellow
      }
    }
  }

  $batPath = Join-Path $RepoRoot 'GHOST.bat'
  $oldBatHash = $null
  if (Test-Path -LiteralPath $batPath -PathType Leaf) {
    $oldBatHash = (Get-FileHash -LiteralPath $batPath -Algorithm SHA256).Hash
  }

  # 1. init + deterministic branch name (independent of init.defaultBranch)
  $r = Invoke-Git 'init'
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [FAILED] git init failed - the folder is unchanged.' -ForegroundColor Red
    $r.StdErr | Select-Object -First 3 | ForEach-Object { Write-Host "         $_" }
    return 'failed'
  }
  $r = Invoke-Git 'symbolic-ref','HEAD','refs/heads/main'
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [FAILED] git setup failed - the folder is unchanged.' -ForegroundColor Red
    return 'failed'
  }
  # 2. local config: longpaths (nested Downloads paths can exceed MAX_PATH)
  #    and autocrlf=false so the committed .gitattributes alone governs EOLs.
  $r = Invoke-Git 'config','core.longpaths','true'
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [FAILED] git config failed - the folder is unchanged.' -ForegroundColor Red
    return 'failed'
  }
  $r = Invoke-Git 'config','core.autocrlf','false'
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [FAILED] git config failed - the folder is unchanged.' -ForegroundColor Red
    return 'failed'
  }
  # 3. remote + fetch
  $r = Invoke-Git 'remote','add','origin',$OriginUrl
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [FAILED] could not register the origin remote - the folder is unchanged.' -ForegroundColor Red
    return 'failed'
  }
  $r = Invoke-Git 'fetch','origin','--tags','--prune'
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [warn] could not reach the remote - conversion aborted, the folder is unchanged.' -ForegroundColor Yellow
    $r.StdErr | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" }
    Write-Host 'Check the connection and run again.' -ForegroundColor Yellow
    return 'aborted'
  }
  # 4. default branch of the remote
  $null = Invoke-Git 'remote','set-head','origin','-a'
  $convBranch = 'main'
  $oh = Invoke-Git 'rev-parse','--abbrev-ref','origin/HEAD'
  if ($oh.ExitCode -eq 0 -and $oh.StdOut.Count -gt 0 -and $oh.StdOut[0].Trim() -like 'origin/*') {
    $convBranch = $oh.StdOut[0].Trim().Substring(7)
  }
  $Target = 'origin/' + $convBranch
  $r = Invoke-Git 'rev-parse','--verify',$Target
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host ("  [FAILED] {0} not found after fetch - the folder is unchanged." -f $Target) -ForegroundColor Red
    return 'failed'
  }
  # 5. align branch/index WITHOUT touching the working tree, then detect real edits
  $r = Invoke-Git 'reset','--mixed',$Target
  if ($r.ExitCode -ne 0) {
    & $removeTempGit
    Write-Host '  [FAILED] git reset --mixed failed - the folder is unchanged.' -ForegroundColor Red
    $r.StdErr | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" }
    return 'failed'
  }
  $status = Invoke-Git 'status','--porcelain'
  $modified = @()
  if ($status.ExitCode -eq 0) {
    $modified = @($status.StdOut | Where-Object { $_ -ne '' -and $_ -match '^\s*M' })
  }
  if ($modified.Count -gt 0) {
    # Re-check ignoring CR-at-EOL so pure line-ending noise from the ZIP
    # extraction never triggers the overwrite prompt.
    $diff = Invoke-Git 'diff','--ignore-cr-at-eol','--name-only'
    $real = @()
    if ($diff.ExitCode -eq 0) { $real = @($diff.StdOut | Where-Object { $_ -ne '' }) }
    if ($real.Count -eq 0) {
      Write-Host '  [ok] line-ending differences only - ignored' -ForegroundColor Green
    }
    else {
      Write-Host '  [warn] this ZIP copy has local edits to tracked files:' -ForegroundColor Yellow
      $real | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
      if ($real.Count -gt 10) { Write-Host ("    ... and {0} more" -f ($real.Count - 10)) }
      if ($Convert) {
        # -Convert never bypasses the destructive overwrite decision.
        Write-Refusal 'local edits found - refusing to overwrite them in a non-interactive run.'
        & $removeTempGit
        Write-Host 'Aborted. Nothing was changed - the folder is still a plain ZIP copy.' -ForegroundColor Yellow
        return 'aborted'
      }
      $answer2 = Read-Host '  Overwrite these local edits with the GitHub version (y/N)'
      if ($answer2 -notmatch '^(y|yes)$') {
        & $removeTempGit
        Write-Host 'Aborted. Nothing was changed - the folder is still a plain ZIP copy.' -ForegroundColor Yellow
        return 'aborted'
      }
    }
  }
  # 6. hard align (tracked files rewritten per .gitattributes; untracked and
  #    ignored files such as .envlocal / ID_Backups / *.lnk survive)
  $r = Invoke-Git 'reset','--hard',$Target
  if ($r.ExitCode -ne 0) {
    Write-Host '  [FAILED] git reset --hard failed - inspect the folder with git status.' -ForegroundColor Red
    $r.StdErr | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" }
    return 'failed'
  }
  # 7. upstream (best effort - fetch/pull always name the branch explicitly)
  $r = Invoke-Git 'branch','--set-upstream-to',$Target,'main'
  if ($r.ExitCode -ne 0) {
    Write-Host ("  [warn] could not set upstream to {0} - updates still work." -f $Target) -ForegroundColor Yellow
  }
  # 8. verify-after (mandatory)
  $headR = Invoke-Git 'rev-parse','HEAD'
  $tgtR = Invoke-Git 'rev-parse',$Target
  if ($headR.ExitCode -ne 0 -or $tgtR.ExitCode -ne 0 -or $headR.StdOut.Count -eq 0 -or $tgtR.StdOut.Count -eq 0 -or
    $headR.StdOut[0].Trim() -ne $tgtR.StdOut[0].Trim()) {
    Write-Host '  [FAILED] HEAD does not match origin after the conversion - inspect with git status.' -ForegroundColor Red
    return 'failed'
  }
  $shortR = Invoke-Git 'rev-parse','--short','HEAD'
  $convShort = '?'
  if ($shortR.ExitCode -eq 0 -and $shortR.StdOut.Count -gt 0) { $convShort = $shortR.StdOut[0].Trim() }
  Write-Host ("  [ok] converted to a git clone: branch {0}, HEAD {1}, origin {2}" -f $convBranch, $convShort, $OriginUrl) -ForegroundColor Green
  if ($oldBatHash) {
    $newBatHash = (Get-FileHash -LiteralPath $batPath -Algorithm SHA256).Hash
    if ($newBatHash -ne $oldBatHash) {
      Write-Host '  note: the launcher was updated - close this window and relaunch GHOST.bat.' -ForegroundColor Yellow
    }
  }
  return 'converted'
}

try {
  Write-Host 'GHOST repo updater' -ForegroundColor Cyan
  Write-Host "repo: $RepoRoot"
  Write-Host ''

  # ---- [1/7] Preflight --------------------------------------------------
  Write-Host '[1/7] Preflight...'
  $gitMissing = $false
  try {
    $null = Get-Command git -ErrorAction Stop
  }
  catch {
    $gitMissing = $true
  }

  if ($gitMissing) {
    # Gatekeeper order: the no-git branch is decided BEFORE anything else.
    if (Test-GhostShape -Root $RepoRoot) {
      $zipResult = Update-GhostZipCopy
      if ($zipResult -eq 'failed') { exit 1 }
      exit 0
    }
    Write-Host '  [FAILED] Git is not installed or not found on PATH.' -ForegroundColor Red
    Show-GitInstallTip
    exit 1
  }
  Write-Host '  [ok] git on PATH' -ForegroundColor Green

  $inTree = Invoke-Git 'rev-parse','--is-inside-work-tree'
  if ($inTree.ExitCode -ne 0 -or $inTree.StdOut.Count -eq 0 -or $inTree.StdOut[0].Trim() -ne 'true') {
    if (-not (Test-GhostShape -Root $RepoRoot)) {
      Write-Host ("  [FAILED] {0} is not a git work tree - re-clone the repo:" -f $RepoRoot) -ForegroundColor Red
      Write-Host ("           git clone {0}" -f $OriginUrl) -ForegroundColor Gray
      exit 1
    }
    $convResult = Convert-GhostZipToClone
    if ($convResult -eq 'failed') { exit 1 }
    if ($convResult -eq 'aborted') { exit 0 }
    # 'converted' -> fall through into the normal update flow
  }
  else {
    Write-Host '  [ok] inside a git work tree' -ForegroundColor Green
  }

  $remote = Invoke-Git 'remote','get-url','origin'
  if ($remote.ExitCode -ne 0 -or $remote.StdOut.Count -eq 0) {
    Write-Host ("  [FAILED] no origin remote - re-add it: git remote add origin {0}" -f $OriginUrl) -ForegroundColor Red
    exit 1
  }
  Write-Host ("  [ok] origin = {0}" -f $remote.StdOut[0]) -ForegroundColor Green

  # ---- [2/7] Current position -------------------------------------------
  Write-Host '[2/7] Current position...'
  $branch = Invoke-Git 'rev-parse','--abbrev-ref','HEAD'
  $BranchName = 'unknown'
  if ($branch.ExitCode -eq 0 -and $branch.StdOut.Count -gt 0) { $BranchName = $branch.StdOut[0].Trim() }
  $head = Invoke-Git 'rev-parse','--short','HEAD'
  $HeadShort = 'unknown'
  if ($head.ExitCode -eq 0 -and $head.StdOut.Count -gt 0) { $HeadShort = $head.StdOut[0].Trim() }
  $descr = Invoke-Git 'describe','--tags','--always','--dirty'
  $Describe = $HeadShort
  if ($descr.ExitCode -eq 0 -and $descr.StdOut.Count -gt 0) { $Describe = $descr.StdOut[0].Trim() }
  Write-Host ("  branch: {0}   HEAD: {1}   version: {2}" -f $BranchName, $HeadShort, $Describe)

  # ---- [3/7] Fetch --------------------------------------------------------
  Write-Host '[3/7] Fetching from GitHub (origin --tags --prune)...'
  $fetch = Invoke-Git 'fetch','origin','--tags','--prune'
  if ($fetch.ExitCode -ne 0) {
    Write-Host '  [warn] could not reach GitHub - nothing was changed.' -ForegroundColor Yellow
    if ($fetch.StdErr.Count -gt 0) {
      $fetch.StdErr | Select-Object -First 5 | ForEach-Object { Write-Host "         $_" }
    }
    Write-Host 'Check the connection and run again.' -ForegroundColor Yellow
    exit 0
  }
  Write-Host '  [ok] fetch completed' -ForegroundColor Green

  # ---- [4/7] Compare ------------------------------------------------------
  Write-Host '[4/7] Comparing with origin...'
  $refHead = Invoke-Git 'rev-parse','--abbrev-ref','origin/HEAD'
  $DefaultBranch = 'main'
  if ($refHead.ExitCode -eq 0 -and $refHead.StdOut.Count -gt 0 -and $refHead.StdOut[0].Trim() -like 'origin/*') {
    $DefaultBranch = $refHead.StdOut[0].Trim().Substring(7)
  }
  $Target = 'origin/' + $DefaultBranch
  $verify = Invoke-Git 'rev-parse','--verify',$Target
  if ($verify.ExitCode -ne 0) {
    Write-Host ("  [FAILED] {0} not found - cannot compare." -f $Target) -ForegroundColor Red
    exit 1
  }
  Write-Host ("  remote default branch: {0}" -f $DefaultBranch)

  $behindR = Invoke-Git 'rev-list','--count',('HEAD..' + $Target)
  $aheadR = Invoke-Git 'rev-list','--count',($Target + '..HEAD')
  if ($behindR.ExitCode -ne 0 -or $aheadR.ExitCode -ne 0 -or $behindR.StdOut.Count -eq 0 -or $aheadR.StdOut.Count -eq 0) {
    Write-Host '  [FAILED] could not count commits vs origin (unusual git state).' -ForegroundColor Red
    exit 1
  }
  [int]$Behind = $behindR.StdOut[0].Trim()
  [int]$Ahead = $aheadR.StdOut[0].Trim()
  Write-Host ("  behind: {0} new commit(s)   ahead: {1} local commit(s)" -f $Behind, $Ahead)
  if ($Behind -gt 0) {
    Write-Host '  new commits:'
    $log = Invoke-Git 'log','--oneline','--no-decorate','-15',('HEAD..' + $Target)
    if ($log.ExitCode -eq 0) {
      foreach ($line in $log.StdOut) { Write-Host "    $line" }
      if ($Behind -gt 15) { Write-Host ("    ... and {0} more" -f ($Behind - 15)) }
    }
  }

  # ---- [5/7] Decide -------------------------------------------------------
  Write-Host '[5/7] Decision...'
  if ($Behind -eq 0) {
    Write-Host '  GHOST is up to date.' -ForegroundColor Green
    if ($Ahead -gt 0) {
      Write-Host ("  Note: {0} local commit(s) exist only here - push or rebase them." -f $Ahead) -ForegroundColor Yellow
    }
    Write-Host ("  version: {0}" -f $Describe) -ForegroundColor Green
    exit 0
  }
  if ($CheckOnly) {
    Write-Host '  -CheckOnly set - report only. Run again without it to update.' -ForegroundColor Yellow
    exit 0
  }
  if ($BranchName -eq 'HEAD' -or $BranchName -eq 'unknown') {
    Write-Refusal 'detached HEAD - run: git checkout main'
    exit 1
  }
  if ($BranchName -ne $DefaultBranch) {
    Write-Refusal ("on branch '{0}', not '{1}' - switch branches before updating." -f $BranchName, $DefaultBranch)
    exit 1
  }
  if ($Ahead -gt 0) {
    Write-Refusal ("{0} local commit(s) not on origin would block a fast-forward - push or rebase first." -f $Ahead)
    exit 1
  }

  $answer = Read-Host 'Update GHOST now (y/N)'
  if ($answer -notmatch '^(y|yes)$') {
    Write-Host 'Aborted. Nothing was changed.' -ForegroundColor Yellow
    exit 0
  }

  # ---- [6/7] Update (stash if needed, then pull) ---------------------------
  Write-Host '[6/7] Updating...'
  $status = Invoke-Git 'status','--porcelain'
  $dirty = @()
  if ($status.ExitCode -eq 0) { $dirty = @($status.StdOut | Where-Object { $_ -ne '' }) }
  $stashed = $false
  if ($dirty.Count -gt 0) {
    Write-Host ("  working tree has {0} uncommitted change(s):" -f $dirty.Count) -ForegroundColor Yellow
    $dirty | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
    if ($dirty.Count -gt 10) { Write-Host ("    ... and {0} more" -f ($dirty.Count - 10)) }
    $stashAnswer = Read-Host 'Stash changes, update, then restore (y/N)'
    if ($stashAnswer -notmatch '^(y|yes)$') {
      Write-Host 'Aborted. Nothing was changed.' -ForegroundColor Yellow
      exit 0
    }
    $stashBefore = Get-StashCount
    $stash = Invoke-Git 'stash','push','-u','-m','GHOST updater auto-stash (update_ghost.ps1)'
    if ($stash.ExitCode -ne 0) {
      Write-Refusal 'git stash push failed - update aborted, your changes are untouched.'
      exit 1
    }
    if ((Get-StashCount) -le $stashBefore) {
      Write-Host '  [warn] stash count did not increase - continuing; the pull refuses if blocked.' -ForegroundColor Yellow
    }
    else {
      Write-Host '  [ok] local changes stashed (ignored files were not touched)' -ForegroundColor Green
    }
    $stashed = $true
  }

  $pull = Invoke-Git 'pull','--ff-only','origin',$DefaultBranch
  if ($pull.ExitCode -ne 0) {
    Write-Host '  [FAILED] git pull did not complete.' -ForegroundColor Red
    if ($pull.StdErr.Count -gt 0) {
      $pull.StdErr | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" }
    }
    if ($stashed) {
      Write-Host '  Your changes are SAFE in the stash - restore with: git stash pop' -ForegroundColor Yellow
    }
    exit 1
  }
  $pull.StdOut | ForEach-Object { Write-Host "  $_" }

  # ---- [7/7] Verify-after (never silent-success) ----------------------------
  Write-Host '[7/7] Verify-after...'
  $newHead = Invoke-Git 'rev-parse','HEAD'
  $targetRef = Invoke-Git 'rev-parse',$Target
  $behindAfter = Invoke-Git 'rev-list','--count',('HEAD..' + $Target)
  $headMatches = ($newHead.ExitCode -eq 0 -and $targetRef.ExitCode -eq 0 -and
    $newHead.StdOut.Count -gt 0 -and $targetRef.StdOut.Count -gt 0 -and
    $newHead.StdOut[0].Trim() -eq $targetRef.StdOut[0].Trim())
  $behindZero = ($behindAfter.ExitCode -eq 0 -and $behindAfter.StdOut.Count -gt 0 -and
    [int]($behindAfter.StdOut[0].Trim()) -eq 0)
  if (-not ($headMatches -and $behindZero)) {
    Write-Host '  [FAILED] HEAD does not match origin after the pull - inspect with git status / git log.' -ForegroundColor Red
    if ($stashed) {
      Write-Host '  Your changes are SAFE in the stash - restore with: git stash pop' -ForegroundColor Yellow
    }
    exit 1
  }
  Write-Host ("  [ok] HEAD == {0}" -f $Target) -ForegroundColor Green
  Write-Host '  [ok] behind count = 0' -ForegroundColor Green

  if ($stashed) {
    Write-Host '  Restoring local changes (git stash pop)...'
    $pop = Invoke-Git 'stash','pop'
    if ($pop.ExitCode -ne 0) {
      Write-Host '  [FAILED] git stash pop did not apply cleanly - the stash is KEPT.' -ForegroundColor Red
      if ($pop.StdErr.Count -gt 0) {
        $pop.StdErr | Select-Object -First 8 | ForEach-Object { Write-Host "         $_" }
      }
      Write-Host '  Resolve, then reapply: git stash pop (or git stash apply)' -ForegroundColor Yellow
      Write-Host '  The update itself succeeded.' -ForegroundColor Yellow
      $script:Failed = $true
    }
    else {
      Write-Host '  [ok] local changes restored' -ForegroundColor Green
    }
  }

  $newDescr = Invoke-Git 'describe','--tags','--always','--dirty'
  $NewDescribe = '?'
  if ($newDescr.ExitCode -eq 0 -and $newDescr.StdOut.Count -gt 0) { $NewDescribe = $newDescr.StdOut[0].Trim() }

  if ($script:Failed) {
    Write-Host 'FAILED - update applied, but the restore had errors; see lines above.' -ForegroundColor Red
    exit 1
  }
  Write-Host ("SUCCESS - GHOST updated: {0} -> {1}   ({2} new commit(s))" -f $Describe, $NewDescribe, $Behind) -ForegroundColor Green
  Write-Host 'What changed: see CHANGELOG.md.' -ForegroundColor Gray
}
catch {
  Write-Host ("[FAILED] unexpected error: {0}" -f $_.Exception.Message) -ForegroundColor Red
  exit 1
}
