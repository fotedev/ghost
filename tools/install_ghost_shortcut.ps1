#requires -Version 5.1
<#
.SYNOPSIS
  Installs (or removes) the GHOST launcher shortcuts (Desktop + repo root).
  Prefers the desktop launcher GHOST.exe when it has been built
  (tools\build_ghost_exe.ps1 - the exe carries its own icon + UAC manifest);
  otherwise falls back to GHOST.bat, whose custom Explorer icon ships via
  these .lnk shortcuts with IconLocation set to assets\ghost.ico (generated
  by tools\make_ghost_icon.ps1 - .bat files cannot carry an icon).

.DESCRIPTION
  Per-user locations only -> NO admin rights needed:
    Desktop   : [Environment]::GetFolderPath('Desktop')
    Repo root : <repo>\GHOST.lnk (local convenience, gitignored)

  Every write is re-read and compared (no silent-success).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_ghost_shortcut.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_ghost_shortcut.ps1 -DesktopOnly
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_ghost_shortcut.ps1 -RepoOnly
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\install_ghost_shortcut.ps1 -Remove
#>
[CmdletBinding()]
param(
  [switch]$Remove,
  [switch]$DesktopOnly,
  [switch]$RepoOnly
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$IcoPath = Join-Path $RepoRoot 'assets\ghost.ico'
$script:Failed = $false

if ($DesktopOnly -and $RepoOnly) { $DesktopOnly = $false; $RepoOnly = $false }

# Resolve the launcher's on-disk case (GHOST.bat vs Ghost.bat) so the shortcut
# and its display name match what git tracks.
$batFile = Get-ChildItem -LiteralPath $RepoRoot -Filter '*.bat' |
  Where-Object { $_.Name -ieq 'ghost.bat' } | Select-Object -First 1
if (-not $batFile) { throw "Launcher not found in repo root: *ghost.bat (expected GHOST.bat)" }
$BatPath = $batFile.FullName
$ShortcutName = $batFile.BaseName + '.lnk'

function Get-ShortcutTargets {
  $targets = @()
  if (-not $RepoOnly) {
    $targets += Join-Path ([Environment]::GetFolderPath('Desktop')) $ShortcutName
  }
  if (-not $DesktopOnly) {
    $targets += Join-Path $RepoRoot $ShortcutName
  }
  return $targets
}

function Assert-Value {
  param([string]$Name, [string]$Expected, [string]$Actual)
  if ($Actual -ieq $Expected) {
    Write-Host "      [ok] $Name" -ForegroundColor Green
  } else {
    Write-Host "      [FAILED] $Name : expected '$Expected' but read '$Actual'" -ForegroundColor Red
    $script:Failed = $true
  }
}

if ($Remove) {
  Write-Host '[1/2] Removing GHOST shortcuts...'
  foreach ($t in (Get-ShortcutTargets)) {
    if (Test-Path -LiteralPath $t) {
      Remove-Item -LiteralPath $t -Force
      if (Test-Path -LiteralPath $t) {
        Write-Host "  [FAILED] still present after delete: $t" -ForegroundColor Red
        $script:Failed = $true
      } else {
        Write-Host "  [ok] removed $t" -ForegroundColor Green
      }
    } else {
      Write-Host "  [skip] not present: $t"
    }
  }
  if ($script:Failed) { Write-Host 'FAILED - see lines above.' -ForegroundColor Red; exit 1 }
  Write-Host 'SUCCESS - shortcuts removed.' -ForegroundColor Green
  exit 0
}

Write-Host '[1/3] Resolving paths...'
$ExePath = Join-Path $RepoRoot 'GHOST.exe'
$UseExe = Test-Path -LiteralPath $ExePath
if ($UseExe) {
  $TargetPath = $ExePath
  $IconLocation = "$ExePath,0"
  $haveIcon = $true
  $Description = 'GHOST - Guided Hardware and OS Scrubbing Toolkit (desktop app)'
  Write-Host '  [ok] target: GHOST.exe (desktop launcher - carries its own icon)' -ForegroundColor Green
} else {
  $TargetPath = $BatPath
  $Description = 'GHOST - Guided Hardware and OS Scrubbing Toolkit (interactive menu)'
  $haveIcon = Test-Path -LiteralPath $IcoPath
  $IconLocation = "$IcoPath,0"
  if (-not $haveIcon) {
    Write-Host "  [warn] icon not found: $IcoPath - shortcuts will use the default icon." -ForegroundColor Yellow
    Write-Host "         Generate it first: tools\make_ghost_icon.ps1" -ForegroundColor Yellow
  }
  Write-Host '  [ok] target: GHOST.bat (console menu - no GHOST.exe built yet; run Maintenance [5] for the desktop app)'
}
$targets = @(Get-ShortcutTargets)
$targets | ForEach-Object { Write-Host "  target: $_" }

Write-Host '[2/3] Creating shortcuts (verify-after)...'
$ws = New-Object -ComObject WScript.Shell
foreach ($t in $targets) {
  Write-Host "  -> $t"
  $sc = $ws.CreateShortcut($t)
  $sc.TargetPath = $TargetPath
  $sc.WorkingDirectory = $RepoRoot
  if ($haveIcon) { $sc.IconLocation = $IconLocation }
  $sc.Description = $Description
  $sc.Save()
  if (-not (Test-Path -LiteralPath $t)) {
    Write-Host "  [FAILED] .lnk not written: $t" -ForegroundColor Red
    $script:Failed = $true
    continue
  }
  $chk = $ws.CreateShortcut($t)
  Assert-Value 'TargetPath'       $TargetPath   $chk.TargetPath
  Assert-Value 'WorkingDirectory' $RepoRoot     $chk.WorkingDirectory
  if ($haveIcon) { Assert-Value 'IconLocation' $IconLocation $chk.IconLocation }
  Assert-Value 'Description'      $Description  $chk.Description
}

Write-Host '[3/3] Summary...'
if ($script:Failed) { Write-Host 'FAILED - see lines above.' -ForegroundColor Red; exit 1 }
Write-Host ("SUCCESS - {0} shortcut(s) installed: {1}" -f $targets.Count, ($targets -join ' | ')) -ForegroundColor Green
