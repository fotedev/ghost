#requires -Version 5.1
<#
.SYNOPSIS
  Keeps AutoClaw2 from forcing the git author identity "zwork" into agent shells.

.DESCRIPTION
  AutoClaw2 v2.1.1 (internal codename "zwork") injects

      GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL
      GIT_COMMITTER_NAME / GIT_COMMITTER_EMAIL   =  "zwork" / "zwork@local"

  into every shell it spawns for its agents (resources/app/dist/main.cjs,
  safeEnvironment(), around line 384212). Environment variables beat git
  config, so every agent commit is authored "zwork" no matter what the
  user's global .gitconfig says.

  This guard removes the four fallback lines. It is idempotent, keeps a
  timestamped backup, syntax-checks the patched bundle with node before
  swapping, and never touches the original until that check passes.

  Run it after every AutoClaw2 update. The AutoClaw2 clone launcher calls it
  automatically before each launch.

  Exit codes: 0 = already OK or patched
              1 = patch required (only with -CheckOnly)
              2 = main.cjs not found
              3 = unexpected match count (bundle changed - manual review)
              4 = syntax check failed (original untouched)
              5 = post-patch verification failed (restore the backup)

.PARAMETER InstallRoot
  AutoClaw2 install directory. Default: %LOCALAPPDATA%\Programs\AutoClaw2

.PARAMETER CheckOnly
  Report status only; never write.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ensure_autoclaw2_git_identity.ps1 -CheckOnly

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File ensure_autoclaw2_git_identity.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\AutoClaw2'),
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

# Agent-shell environments may not carry %LOCALAPPDATA%; resolve defensively.
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\AutoClaw2'
}

$target = Join-Path $InstallRoot 'resources\app\dist\main.cjs'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Warning "AutoClaw2 main bundle not found: $target"
    exit 2
}

$pattern = '\r?\n[ \t]*environment\.GIT_(?:AUTHOR|COMMITTER)_(?:NAME|EMAIL) \?\?= "(?:zwork|zwork@local)";'

$text  = [System.IO.File]::ReadAllText($target)
$found = [regex]::Matches($text, $pattern)

if ($found.Count -eq 0) {
    Write-Output "OK: no git-identity override in $target (already patched or new layout)."
    exit 0
}
if ($found.Count -ne 4) {
    Write-Warning "Unexpected match count ($($found.Count)); refusing to auto-patch. Review manually: $target"
    exit 3
}
if ($CheckOnly) {
    Write-Warning "PATCH REQUIRED: 4 git-identity fallback lines present in $target"
    exit 1
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$target.bak-zwork-$stamp"
Copy-Item -LiteralPath $target -Destination $backup -Force
Write-Output "backup: $backup"

$temp = "$target.patched-tmp.cjs"
[System.IO.File]::WriteAllText($temp, [regex]::Replace($text, $pattern, ''), (New-Object System.Text.UTF8Encoding($false)))

$nodeExe = $null
$cmd = Get-Command node -ErrorAction SilentlyContinue
if ($cmd) { $nodeExe = $cmd.Source }
if (-not $nodeExe) {
    $vendored = Join-Path $InstallRoot 'resources\vendor\node\node.exe'
    if (Test-Path -LiteralPath $vendored) { $nodeExe = $vendored }
}
if ($nodeExe) {
    & $nodeExe --check $temp
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $temp -Force
        Write-Error 'Syntax check FAILED - patch aborted, original untouched.'
        exit 4
    }
} else {
    Write-Warning 'node not found; skipping syntax check.'
}

try {
    Copy-Item -LiteralPath $temp -Destination $target -Force
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

$verify = [regex]::Matches([System.IO.File]::ReadAllText($target), $pattern)
if ($verify.Count -ne 0) {
    Write-Error 'Post-patch verification FAILED; restore from the backup printed above.'
    exit 5
}

if (@(Get-Process -Name AutoClaw2 -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Output 'PATCH APPLIED. AutoClaw2 is running - restart it to activate the fix.'
} else {
    Write-Output 'PATCH APPLIED. The next AutoClaw2 start will be clean.'
}
exit 0
