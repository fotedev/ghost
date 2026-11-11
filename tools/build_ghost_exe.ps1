#requires -Version 5.1
<#
.SYNOPSIS
  Builds GHOST.exe - the desktop launcher (WinForms hub) - from source using
  the in-box .NET Framework C# compiler. No SDK, no NuGet, nothing to install.

.DESCRIPTION
  Compiles src\desktop\GhostHub.cs + a generated AssemblyInfo (version stamped
  from the first released ## [X.Y.Z] section in CHANGELOG.md - the same source
  release.yml gates tags on) with C:\Windows\Microsoft.NET\Framework64\
  v4.0.30319\csc.exe, embedding assets\ghost.ico and the
  src\desktop\app.manifest requireAdministrator manifest.

  The exe is a LAUNCHER over the repo tree, not a self-contained bundle - it
  must live next to GHOST.bat (default: repo root) and reads
  src\desktop\menu.json at runtime, so menu edits land without a rebuild.

  Verify-after everywhere (never silent-success): compile exit code, exe
  exists + MZ magic + size floor, stamped ProductVersion == CHANGELOG
  version, SHA256 printed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_ghost_exe.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_ghost_exe.ps1 -OutDir "$env:TEMP\ghost-exe-check"   # CI compile check
#>
[CmdletBinding()]
param(
  # Output directory for GHOST.exe. Defaults to the repo root (the exe's
  # expected home: next to GHOST.bat). CI uses -OutDir to keep the check out
  # of the checkout.
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Failed = $false

function Assert-Step {
  param([string]$Name, [bool]$Condition, [string]$Detail)
  if ($Condition) {
    Write-Host "  [ok] $Name" -ForegroundColor Green
  } else {
    Write-Host "  [FAILED] $Name : $Detail" -ForegroundColor Red
    $script:Failed = $true
  }
}

Write-Host '[1/5] Resolving toolchain...'
$cscCandidates = @(
  (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
  (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)
$Csc = $cscCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $Csc) {
  Write-Host '  [FAILED] no in-box C# compiler found (expected either of:' -ForegroundColor Red
  $cscCandidates | ForEach-Object { Write-Host "           $_" -ForegroundColor Red }
  Write-Host '  Enable .NET Framework 4.x (Windows Features) and retry - nothing needs downloading.' -ForegroundColor Red
  exit 1
}
Write-Host "  [ok] csc.exe: $Csc"

Write-Host '[2/5] Resolving inputs...'
$Sources = @(
  (Join-Path $RepoRoot 'src\desktop\GhostHub.cs'),
  (Join-Path $RepoRoot 'src\desktop\app.manifest'),
  (Join-Path $RepoRoot 'src\desktop\menu.json'),
  (Join-Path $RepoRoot 'assets\ghost.ico')
)
foreach ($s in $Sources) {
  if (-not (Test-Path -LiteralPath $s)) {
    Write-Host "  [FAILED] missing build input: $s" -ForegroundColor Red
    exit 1
  }
}
Write-Host '  [ok] GhostHub.cs + app.manifest + menu.json + ghost.ico present'

$Changelog = Join-Path $RepoRoot 'CHANGELOG.md'
$ChangelogText = Get-Content -LiteralPath $Changelog -Raw
$VersionMatch = [regex]::Match($ChangelogText, '(?m)^## \[(\d+\.\d+\.\d+)\]')
if (-not $VersionMatch.Success) {
  Write-Host '  [FAILED] no released "## [X.Y.Z]" section found in CHANGELOG.md' -ForegroundColor Red
  exit 1
}
$Version = $VersionMatch.Groups[1].Value
Write-Host "  [ok] version stamp: $Version (first released CHANGELOG section)"

if (-not $OutDir) { $OutDir = $RepoRoot }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$ExePath = Join-Path $OutDir 'GHOST.exe'

Write-Host '[3/5] Generating AssemblyInfo...'
$VersionCs = Join-Path $env:TEMP ("ghost-hub-version-{0}.cs" -f [guid]::NewGuid().ToString('N'))
@(
  'using System.Reflection;'
  "[assembly: AssemblyTitle(""GHOST"")]"
  "[assembly: AssemblyProduct(""GHOST - Guided Hardware and OS Scrubbing Toolkit"")]"
  "[assembly: AssemblyVersion(""$Version.0"")]"
  "[assembly: AssemblyFileVersion(""$Version.0"")]"
  "[assembly: AssemblyInformationalVersion(""$Version"")]"
) | Set-Content -LiteralPath $VersionCs -Encoding ASCII
Write-Host "  [ok] $VersionCs"

Write-Host '[4/5] Compiling...'
# Clobber the old exe first (repo rule) - csc refuses nothing here, but an
# AV-locked or running exe fails the write with a cryptic CS error, so check
# writability up front and say what to close.
if (Test-Path -LiteralPath $ExePath) {
  try {
    $probe = [System.IO.File]::Open($ExePath, 'Open', 'ReadWrite', 'None')
    $probe.Close()
    Remove-Item -LiteralPath $ExePath -Force
    Write-Host '  [ok] old GHOST.exe removed'
  } catch {
    Write-Host "  [FAILED] cannot replace $ExePath - close the running GHOST.exe (or an antivirus holding it) and retry." -ForegroundColor Red
    Remove-Item -LiteralPath $VersionCs -Force -ErrorAction SilentlyContinue
    exit 1
  }
}

& $Csc /nologo /target:winexe /platform:anycpu /out:$ExePath `
  /win32icon:"$RepoRoot\assets\ghost.ico" `
  /win32manifest:"$RepoRoot\src\desktop\app.manifest" `
  /r:System.Web.Extensions.dll `
  "$RepoRoot\src\desktop\GhostHub.cs" $VersionCs
$CscExit = $LASTEXITCODE
Remove-Item -LiteralPath $VersionCs -Force -ErrorAction SilentlyContinue
if ($CscExit -ne 0) {
  Write-Host "  [FAILED] csc.exe exited $CscExit - compiler errors printed above." -ForegroundColor Red
  exit 1
}
Write-Host '  [ok] csc.exe exited 0'

Write-Host '[5/5] Verify-after...'
if (-not (Test-Path -LiteralPath $ExePath)) {
  Write-Host "  [FAILED] exe not written: $ExePath" -ForegroundColor Red
  exit 1
}
$bytes = [System.IO.File]::ReadAllBytes($ExePath)
Assert-Step 'exe size above floor' ($bytes.Length -gt 10KB) ("only $($bytes.Length) bytes")
Assert-Step 'PE magic (MZ)' ($bytes.Length -ge 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) 'missing DOS header'
$vi = (Get-Item -LiteralPath $ExePath).VersionInfo
Assert-Step 'stamped version matches CHANGELOG' ($vi.ProductVersion -eq $Version) "exe says '$($vi.ProductVersion)', CHANGELOG says '$Version'"
# The Win32 RT_MANIFEST resource is stored as plain UTF-8 text inside the exe,
# so the elevation level is verifiable with a raw byte scan.
$raw = [System.Text.Encoding]::ASCII.GetString($bytes)
Assert-Step 'requireAdministrator manifest baked in' ($raw.Contains('requireAdministrator')) 'manifest text not found in exe bytes'

if ($script:Failed) {
  Write-Host 'FAILED - see [FAILED] lines above.' -ForegroundColor Red
  exit 1
}
$hash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash
Write-Host "  [ok] SHA256: $hash"
Write-Host "SUCCESS - $ExePath (v$Version, $($bytes.Length) bytes)" -ForegroundColor Green
Write-Host 'Double-click GHOST.exe (UAC asks first) - it must stay next to GHOST.bat; menu edits in src\desktop\menu.json need no rebuild.'
exit 0
