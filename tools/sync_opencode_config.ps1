#Requires -Version 5.1
<#
.SYNOPSIS
  OpenCode definitions-only Primary -> clone config sync (CS-1,
  docs\OPENCODE_CONFIG_SYNC_PLAN.md). Syncs MCP server DEFINITIONS and the
  NON-SECRET shape of provider entries from the Primary's
  ~\.config\opencode\opencode.jsonc onto each clone's
  <ClonesHome>\cN\config\opencode\opencode.jsonc. Live API keys NEVER cross
  (decision D2 = the plan's default): a Primary provider block syncs WITHOUT
  its apiKey plus one loud WARN per clone ("fill the API key once in this
  clone" - the suite's ONE-manual-login-per-clone rule); a secret the clone
  already has survives.

.DESCRIPTION
  Per-clone flow: lockfile-held = RUNNING -> SKIP + WARN; config file
  missing -> SKIP (first run - the clone starts anonymous by design, the
  sync never creates one); backup config-pre-sync-<ts>.json into the clone
  home; merge via tools\opencode_config_merge.ps1; verify-after re-read +
  deep-compare; JSONL audit at <CloneHome>\config-sync-audit.jsonl (paths +
  key NAMES only - never values, so no secret can leak into the audit).
  The Primary is opened READ-ONLY and its file hash is re-checked after
  every run (plan acceptance 5).

  Placement: launcher pre-launch step in src\windows\launch_opencode_clone.ps1
  (the primary path - runs BEFORE the clone starts, so there is no
  running-instance race there) plus this manual one-shot (-Instance/-Target).
  A failed sync warns and never blocks the launch (the launcher ignores the
  child exit code beyond a warning line).

  -DryRun prints the would-apply entry list and writes nothing.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_config.ps1 -Instance c1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_config.ps1 -Target All
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_opencode_config.ps1 -Target All -DryRun
#>
param(
    [ValidatePattern('^c[1-5]$')]
    [string]$Instance,

    [ValidateSet('All')]
    [string]$Target,

    [switch]$DryRun,

    # Fixture-testing overrides (the probe suite points these at %TEMP%).
    [string]$PrimaryConfig,
    [string]$ClonesRoot
)
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { [void]$_ }

$RepoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
. (Join-Path $RepoRoot 'tools\opencode_config_merge.ps1')

# --- Resolve inputs -----------------------------------------------------------
if (-not $PrimaryConfig) {
    $PrimaryConfig = Join-Path $env:USERPROFILE '.config\opencode\opencode.jsonc'
    if (-not (Test-Path -LiteralPath $PrimaryConfig)) {
        $alt = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
        if (Test-Path -LiteralPath $alt) { $PrimaryConfig = $alt }
    }
}
if (-not $ClonesRoot) { $ClonesRoot = Join-Path $env:USERPROFILE 'OpenCodeClonesHome' }

if (-not (Test-Path -LiteralPath $PrimaryConfig)) {
    Write-Host "[skip] no Primary config at $PrimaryConfig - nothing to sync."
    exit 0
}
if (-not (Test-Path -LiteralPath $ClonesRoot)) {
    Write-Host "[skip] no clones home at $ClonesRoot - nothing to sync."
    exit 0
}

$instances = @()
if ($Instance) { $instances = @($Instance) }
elseif ($Target -eq 'All') {
    $instances = @(Get-ChildItem -LiteralPath $ClonesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^c[1-5]$' } | ForEach-Object { $_.Name } | Sort-Object)
}
if ($instances.Count -eq 0) {
    Write-Host "[skip] no clone homes under $ClonesRoot - nothing to sync."
    exit 0
}

# Primary: parsed ONCE, READ-ONLY. Hash is re-checked at the end (acceptance 5).
$primaryBytes = [System.IO.File]::ReadAllBytes($PrimaryConfig)
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $primaryHashBefore = ($sha.ComputeHash($primaryBytes) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() }
$primaryRaw = [System.Text.Encoding]::UTF8.GetString($primaryBytes)
if ([string]::IsNullOrWhiteSpace($primaryRaw)) {
    Write-Host "[skip] Primary config is empty - nothing to sync."
    exit 0
}
try { $primaryCfg = ConvertFrom-JsoncText -Text $primaryRaw } catch {
    Write-Host "[FAILED] Primary config does not parse: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$primaryHashAfter = $null

# --- Per-clone sync -----------------------------------------------------------
$exitCode = 0
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
foreach ($inst in $instances) {
    $cloneHome = Join-Path $ClonesRoot $inst
    $lockfile = Join-Path $cloneHome 'desktop\lockfile'
    $cfgDir = Join-Path $cloneHome 'config\opencode'
    $cfgPath = Join-Path $cfgDir 'opencode.jsonc'
    if (-not (Test-Path -LiteralPath $cfgPath)) {
        $jsonAlt = Join-Path $cfgDir 'opencode.json'
        if (Test-Path -LiteralPath $jsonAlt) { $cfgPath = $jsonAlt } else { $cfgPath = $null }
    }

    if (-not (Test-Path -LiteralPath $cloneHome)) { Write-Host "[skip] $inst`: no clone home."; continue }

    # Running clone: the per-clone single-instance lockfile (same probe shape
    # as the launcher's Test-LockfileHeld) - held = RUNNING -> SKIP + WARN.
    if (Test-Path -LiteralPath $lockfile) {
        $lockHeld = $false
        try {
            $fs = [System.IO.File]::Open($lockfile, 'Open', 'Read', 'None')
            $fs.Close()
        } catch { $lockHeld = $true }
        if ($lockHeld) {
            Write-Warning "$inst appears RUNNING (lockfile held) - SKIPPED (mirroring sync_zcode_assets semantics; the launcher's pre-launch step covers it next launch)."
            continue
        }
    }

    if (-not $cfgPath) {
        # Plan section 4: skip when the clone has no config yet - the clone
        # starts anonymous by design; creating one from nothing is not this
        # tool's job.
        Write-Host "[skip] $inst`: no config\opencode config yet (first run pending - the sync never creates one)."
        continue
    }

    Write-Host "[$inst] syncing definitions from $PrimaryConfig"

    $cloneRaw = [System.IO.File]::ReadAllText($cfgPath)
    if ([string]::IsNullOrWhiteSpace($cloneRaw)) { $cloneRaw = '{}' }
    try { $cloneCfg = ConvertFrom-JsoncText -Text $cloneRaw } catch {
        Write-Host "  [FAILED] clone config does not parse ($cfgPath): $($_.Exception.Message)" -ForegroundColor Red
        $exitCode = 1
        continue
    }

    $result = Invoke-OcConfigMerge -PrimaryConfig $primaryCfg -CloneConfig $cloneCfg

    if ($DryRun) {
        Write-Host "  [dry-run] would apply: $(@($result.Changed).Count) entr(y/ies): $(@($result.Changed) -join ', ')"
        foreach ($s in $result.Scrubbed) { Write-Host "  [dry-run] provider '$s' would sync WITHOUT its apiKey" -ForegroundColor Yellow }
        continue
    }

    if (@($result.Changed).Count -eq 0) {
        Write-Host "  [ok] already in sync."
        foreach ($s in $result.Scrubbed) { Write-Warning "$inst`: provider '$s' has NO apiKey on the clone - fill the API key once in this clone." }
    } else {
        # Backup BEFORE the write (never silent success: backup, write, verify).
        $backupPath = Join-Path $cloneHome ("config-pre-sync-{0}.json" -f $stamp)
        [System.IO.File]::WriteAllText($backupPath, $cloneRaw, (New-Object System.Text.UTF8Encoding($false)))

        Write-JsonNoBom -Path $cfgPath -Object $cloneCfg

        # Verify-after: re-read + deep-compare against the merged object.
        $writtenRaw = [System.IO.File]::ReadAllText($cfgPath)
        $writtenCfg = $null
        try { $writtenCfg = $writtenRaw | ConvertFrom-Json } catch { $writtenCfg = $null }
        $verifyOk = $false
        if ($null -ne $writtenCfg) {
            $verifyOk = Test-DeepEqual (ConvertTo-DeepHashtable $writtenCfg) (ConvertTo-DeepHashtable $cloneCfg)
        }
        if ($verifyOk) {
            Write-Host "  [ok] wrote + verified $(@($result.Changed).Count) entr(y/ies): $(@($result.Changed) -join ', ')"
        } else {
            Write-Host "  [FAILED] verify-after mismatch on $cfgPath - restore from $backupPath" -ForegroundColor Red
            $exitCode = 1
        }

        $audit = [ordered]@{
            ts        = (Get-Date).ToString('o')
            instance  = $inst
            config    = $cfgPath
            backup    = $backupPath
            changed   = @($result.Changed)
            scrubbed  = @($result.Scrubbed)   # key NAMES only - never values
            verified  = $verifyOk
        }
        $auditPath = Join-Path $cloneHome 'config-sync-audit.jsonl'
        [System.IO.File]::AppendAllText($auditPath, (($audit | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    }

    foreach ($s in $result.Scrubbed) {
        Write-Warning "$inst`: provider '$s' synced WITHOUT its apiKey - fill the API key once in this clone."
    }
}

# --- Primary untouched (acceptance 5) ------------------------------------------
$primaryBytesAfter = [System.IO.File]::ReadAllBytes($PrimaryConfig)
$sha2 = [System.Security.Cryptography.SHA256]::Create()
try { $primaryHashAfter = ($sha2.ComputeHash($primaryBytesAfter) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha2.Dispose() }
if ($primaryHashAfter -ne $primaryHashBefore) {
    Write-Host '[FAILED] the Primary config changed during the run - this tool must be read-only on the Primary!' -ForegroundColor Red
    exit 1
}

if ($exitCode -eq 0) { Write-Host '[done] OpenCode config sync complete.' }
exit $exitCode
