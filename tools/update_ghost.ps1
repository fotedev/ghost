#requires -Version 5.1
<#
.SYNOPSIS
  Checks GitHub for GHOST repo updates and (optionally) applies them.
  GHOST.bat menu [26]. Per-user, no admin rights needed.

.DESCRIPTION
  git fetch origin (--tags --prune), compares HEAD with the remote default
  branch, lists the new commits. Without -CheckOnly it asks before a
  git pull --ff-only.

  Refuses to update when a non-default or detached branch, or local commits,
  would block the fast-forward. A dirty working tree gets an interactive
  offer: stash -u -> pull -> stash pop; a failed pop KEEPS the stash (nothing
  is lost) and prints how to reapply. Ignored files (archive/, .envlocal,
  *.lnk, ID_Backups/) are never touched by the stash.

  Verify-after is mandatory (never silent-success): after the pull the script
  re-reads HEAD and the behind-count. A failed fetch (offline) is a warning,
  not a failure.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\update_ghost.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\update_ghost.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
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

try {
  Write-Host 'GHOST repo updater' -ForegroundColor Cyan
  Write-Host "repo: $RepoRoot"
  Write-Host ''

  # ---- [1/7] Preflight --------------------------------------------------
  Write-Host '[1/7] Preflight...'
  try {
    $null = Get-Command git -ErrorAction Stop
  }
  catch {
    Write-Host '  [FAILED] git not found on PATH - install Git for Windows first.' -ForegroundColor Red
    exit 1
  }
  Write-Host '  [ok] git on PATH' -ForegroundColor Green

  $inTree = Invoke-Git 'rev-parse','--is-inside-work-tree'
  if ($inTree.ExitCode -ne 0 -or $inTree.StdOut.Count -eq 0 -or $inTree.StdOut[0].Trim() -ne 'true') {
    Write-Host "  [FAILED] $RepoRoot is not a git work tree - re-clone the repo (see README)." -ForegroundColor Red
    exit 1
  }
  Write-Host '  [ok] inside a git work tree' -ForegroundColor Green

  $remote = Invoke-Git 'remote','get-url','origin'
  if ($remote.ExitCode -ne 0 -or $remote.StdOut.Count -eq 0) {
    Write-Host '  [FAILED] no origin remote - re-add it: git remote add origin https://github.com/fotedev/ghost.git' -ForegroundColor Red
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
    Write-Host '  -CheckOnly set - report only. Run again without it (or GHOST.bat menu [26]) to update.' -ForegroundColor Yellow
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
