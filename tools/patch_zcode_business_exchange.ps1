#requires -Version 5.1
<#
SYNOPSIS
  patch_zcode_business_exchange.ps1 - hardens the ZCode desktop OAuth
  business-token exchange (out/host/index.js):
    1. ZaiBusinessTokenResolver timeout 10s -> 60s (`zLe=1e4` -> `zLe=6e4`).
    2. One automatic retry after a 3s backoff inside resolve() (covers the
       intermittent "fetch failed" timeout AND transient server-envelope
       rejections that produced `zai_oauth_required` on 2026-11-11).
  Built on tools/asar_surgery.mjs (in-place asar surgery, no extract/repack).
  Entry-scoped: touches ONLY out/host/index.js - coexists with the
  icon-override patch (which owns out/main/index.js / preload / renderer).

NOTES
  - Run with ALL ZCode instances closed (or pass -WaitForClose).
  - After an APP UPDATE the asar is replaced wholesale: re-run this tool
    (-Status reports "pristine (needs patch)"). The icon-override patch
    re-applies itself; this one is manual by design.
  - -Restore reverts out/host/index.js to the pre-patch bytes recorded in
    the marker (safe only while the bundle is unchanged since the patch).

PARAMS
  -InstallDir          ZCode install dir (auto-detected by default).
  -Status              report patched/pristine without writing.
  -Restore             revert the entry to the marker's pre-patch bytes.
  -WaitForClose        instruct-and-poll instead of throwing when instances run.
  -WaitTimeoutMinutes  poll ceiling for -WaitForClose (default 30).
  -NonInteractive      never prompt (watchdog/test callers).
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [switch]$Restore,
    [switch]$Status,
    [switch]$WaitForClose,
    [int]$WaitTimeoutMinutes = 30,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# Env can be stripped in headless/service sessions - derive paths defensively
# (same pattern as launch_zcode_second_instance.ps1).
$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$AppData = $env:APPDATA
if ([string]::IsNullOrWhiteSpace($AppData)) { $AppData = Join-Path $UserProfile 'AppData\Roaming' }
$LocalAppData = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($LocalAppData)) { $LocalAppData = Join-Path $UserProfile 'AppData\Local' }

if (-not $InstallDir) {
    $candidates = @(
        (Join-Path $LocalAppData 'Programs\ZCode'),
        'C:\Program Files\ZCode',
        'C:\Program Files (x86)\ZCode'
    )
    $InstallDir = $candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'resources\app.asar') } | Select-Object -First 1
}
if (-not $InstallDir) { throw 'ZCode install dir not found (checked %LOCALAPPDATA%\Programs\ZCode and Program Files).' }
$asar       = Join-Path $InstallDir 'resources\app.asar'
$engine     = Join-Path $PSScriptRoot 'patch_zcode_business_exchange.mjs'
$markerPath = Join-Path $InstallDir 'resources\zcode-business-exchange.marker.json'
if (-not (Test-Path -LiteralPath $asar))   { throw "app.asar not found: $asar" }
if (-not (Test-Path -LiteralPath $engine)) { throw "engine not found: $engine" }

function Get-ZcodeRunningCount {
    return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction SilentlyContinue).Count
}

function Wait-ZcodeClosed {
    # Two consecutive clear probes = closed (mirrors the icon-patch pattern).
    Write-Host '[business-exchange] Close every ZCode window (this patch replaces app.asar).' -ForegroundColor Cyan
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    $clearStreak = 0
    while ((Get-Date) -lt $deadline) {
        $count = Get-ZcodeRunningCount
        if ($count -eq 0) {
            $clearStreak++
            if ($clearStreak -ge 2) { return $true }
        } else {
            $clearStreak = 0
            Write-Host ("[business-exchange] waiting: {0} ZCode process(es) still running..." -f $count) -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-Engine {
    param([string]$Mode, [string]$Out, [string]$EntryBackup, [string]$ExpectPatchedSha)
    $args = @($engine, $Mode, '--asar', $asar)
    if ($Out)          { $args += @('--out', $Out) }
    if ($EntryBackup)  { $args += @('--entry-backup', $EntryBackup) }
    if ($ExpectPatchedSha) { $args += @('--expect-patched-sha', $ExpectPatchedSha) }
    $raw = & node @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("engine {0} failed (exit {1}): {2}" -f $Mode, $LASTEXITCODE, ($raw -join "`n"))
    }
    return ($raw | Where-Object { $_ -match '^\{' } | Select-Object -First 1 | ConvertFrom-Json)
}

if ($Status) {
    $st = Invoke-Engine -Mode 'status'
    Write-Host ('[business-exchange] entry state: ' + $st.state) -ForegroundColor Cyan
    Write-Host ('[business-exchange] entry sha256: ' + $st.entrySha256)
    return
}

if (Get-ZcodeRunningCount -gt 0) {
    if ($WaitForClose) {
        $closed = Wait-ZcodeClosed
        if (-not $closed) { throw "ZCode instances still running after $WaitTimeoutMinutes minutes - aborting." }
    } else {
        throw 'ZCode instances are running - close them first or pass -WaitForClose.'
    }
}

$backupDir = Join-Path $InstallDir ('resources\ID_Backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '\business-exchange')
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

if ($Restore) {
    if (-not (Test-Path -LiteralPath $markerPath)) { throw 'marker not found - nothing to restore.' }
    $marker = Get-Content $markerPath -Raw | ConvertFrom-Json
    $entryBackup = Join-Path $marker.backupDir 'host-index-pristine.js'
    if (-not (Test-Path -LiteralPath $entryBackup)) { throw "pristine entry backup missing: $entryBackup" }
    $candidate = Join-Path $InstallDir 'resources\app.asar.business-exchange-restore-tmp'
    $res = Invoke-Engine -Mode 'restore' -Out $candidate -EntryBackup $entryBackup -ExpectPatchedSha $marker.entryShaAfter
    Move-Item -LiteralPath $candidate -Destination $asar -Force
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Write-Host '[business-exchange] RESTORED - out/host/index.js reverted to pre-patch bytes.' -ForegroundColor Green
    return
}

# ---- patch mode ----
$entryBackup = Join-Path $backupDir 'host-index-pristine.js'
$candidate   = Join-Path $InstallDir 'resources\app.asar.business-exchange-tmp'
$res = Invoke-Engine -Mode 'patch' -Out $candidate -EntryBackup $entryBackup
if ($res.state -eq 'already-patched') {
    Write-Host '[business-exchange] already patched - nothing to do.' -ForegroundColor Yellow
    return
}

# Full-file backup BEFORE the swap (the restore path uses the entry backup;
# the full copy is the belt-and-suspenders fallback for the whole asar).
Copy-Item -LiteralPath $asar -Destination (Join-Path $backupDir 'app.asar') -Force
$backupAsarSha = (Get-FileHash -LiteralPath (Join-Path $backupDir 'app.asar') -Algorithm SHA256).Hash

Move-Item -LiteralPath $candidate -Destination $asar -Force

# Verify-after: re-read the swapped bundle through the engine.
$st = Invoke-Engine -Mode 'status'
if ($st.state -ne 'patched') { throw 'post-swap verify FAILED - swapped asar does not report patched. Restore: ' + $backupDir }

$entryShaAfter = $res.entryShaAfter
$marker = [ordered]@{
    tool              = 'tools/patch_zcode_business_exchange.ps1'
    patchVersion      = 1
    appliedAt         = (Get-Date).ToString('o')
    installDir        = $InstallDir
    asarSha256        = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
    entryShaBefore    = $res.entryShaBefore
    entryShaAfter     = $entryShaAfter
    backupDir         = $backupDir
    backupAsarSha256  = $backupAsarSha
    patches           = @(
        @{ anchor = 'zLe=1e4'; replacement = 'zLe=6e4'; what = 'ZaiBusinessTokenResolver timeout 10s -> 60s' },
        @{ anchor = '(this.cachedToken=null,this.exchangeBusinessToken(n))'; what = 'resolve() one-shot retry after 3s backoff' }
    )
}
$marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding UTF8

Write-Host '[business-exchange] PATCHED - timeout 10s -> 60s + one retry (3s backoff) in ZaiBusinessTokenResolver.' -ForegroundColor Green
Write-Host ('[business-exchange] backup: ' + $backupDir) -ForegroundColor DarkGray
Write-Host ('[business-exchange] marker:  ' + $markerPath) -ForegroundColor DarkGray
Write-Host '[business-exchange] NOTE: re-run this tool after any ZCode app update (-Status reports pristine).' -ForegroundColor Yellow
