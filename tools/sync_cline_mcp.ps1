#Requires -Version 5.1
<#
.SYNOPSIS
  Cline MCP Primary -> clone settings sync. Syncs the mcpServers DEFINITIONS
  from the Primary's ~\.cline\data\settings\cline_mcp_settings.json onto each
  clone's <ClineClonesHome>\cN\data\settings\cline_mcp_settings.json.

.DESCRIPTION
  Per-clone flow: clone home missing -> SKIP (never launched); hub lock
  held = RUNNING -> SKIP + WARN (the launcher's pre-launch step covers it
  next launch); settings file missing -> CREATE (deliberate deviation from
  the OpenCode config-less SKIP: this store is auth-free - verified on the
  dev host 2026-11-17, the Primary's file is exactly {"mcpServers": {}} -
  and the app only creates it on first MCP-panel use, so waiting would
  mean definitions never reach a fresh clone); backup
  cline_mcp_settings-pre-sync-<ts>.json next to the file before any
  overwrite; merge via tools\cline_mcp_merge.ps1 (Primary definitions win,
  the clone's local `disabled` toggle survives, clone-only servers kept);
  verify-after re-read + deep-compare; JSONL audit at
  <CloneHome>\mcp-sync-audit.jsonl (paths + server NAMES only - never
  values, so no secret can leak into the audit even though this store is
  auth-free by design). The Primary is opened READ-ONLY and its file hash
  is re-checked after every run.

  Placement: launcher pre-launch step in src\windows\launch_cline_clone.ps1
  (the primary path - runs BEFORE the clone starts, so there is no
  running-instance race there) plus this manual one-shot (-Instance/-Target).
  A failed sync warns and never blocks the launch (the launcher ignores the
  child exit code beyond a warning line).

  -DryRun prints the would-apply list and writes nothing.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_cline_mcp.ps1 -Instance c1
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_cline_mcp.ps1 -Target All
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_cline_mcp.ps1 -Target All -DryRun
#>
param(
    [ValidatePattern('^c[1-5]$')]
    [string]$Instance,

    [ValidateSet('All')]
    [string]$Target,

    # Launcher path: suppress the per-clone chatter (a [sync] line + warnings
    # still print; the GHOST.bat window is transient so keep it short).
    [switch]$Quiet,

    [switch]$DryRun,

    # Fixture-testing overrides (the test suite points these at %TEMP%).
    [string]$PrimarySettings,
    [string]$ClonesRoot
)
$ErrorActionPreference = 'Stop'

try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { [void]$_ }

$RepoRoot = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
. (Join-Path $RepoRoot 'tools\cline_mcp_merge.ps1')

function Write-SyncLine([string]$Message, [string]$Color = 'Gray') {
    if ($Quiet) { return }
    Write-Host $Message -ForegroundColor $Color
}

# --- Resolve inputs -----------------------------------------------------------
if (-not $PrimarySettings) {
    $PrimarySettings = Join-Path $env:USERPROFILE '.cline\data\settings\cline_mcp_settings.json'
}
if (-not $ClonesRoot) { $ClonesRoot = Join-Path $env:USERPROFILE 'ClineClonesHome' }

if (-not (Test-Path -LiteralPath $PrimarySettings)) {
    Write-SyncLine "[skip] no Primary MCP settings at $PrimarySettings - nothing to sync." 'Yellow'
    exit 0
}
if (-not (Test-Path -LiteralPath $ClonesRoot)) {
    Write-SyncLine "[skip] no clones home at $ClonesRoot - nothing to sync." 'Yellow'
    exit 0
}

$instances = @()
if ($Instance) { $instances = @($Instance) }
elseif ($Target -eq 'All') {
    $instances = @(Get-ChildItem -LiteralPath $ClonesRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^c[1-5]$' } | ForEach-Object { $_.Name } | Sort-Object)
}
if ($instances.Count -eq 0) {
    Write-SyncLine "[skip] no clone homes under $ClonesRoot - nothing to sync." 'Yellow'
    exit 0
}

# Primary: parsed ONCE, READ-ONLY. Hash is re-checked at the end.
$primaryBytes = [System.IO.File]::ReadAllBytes($PrimarySettings)
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $primaryHashBefore = ($sha.ComputeHash($primaryBytes) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha.Dispose() }
$primaryRaw = [System.Text.Encoding]::UTF8.GetString($primaryBytes)
if ([string]::IsNullOrWhiteSpace($primaryRaw)) { $primaryRaw = '{}' }
try { $primaryCfg = $primaryRaw | ConvertFrom-Json } catch {
    Write-Host "[FAILED] Primary MCP settings do not parse: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
if (-not $primaryCfg.PSObject.Properties['mcpServers']) {
    $primaryCfg | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
}
if (-not $primaryCfg.mcpServers) { $primaryCfg.mcpServers = [pscustomobject]@{} }
$primaryServerCount = @($primaryCfg.mcpServers.PSObject.Properties).Count

# --- Per-clone sync -----------------------------------------------------------
$exitCode = 0
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$anyChanged = $false
foreach ($inst in $instances) {
    $cloneHome = Join-Path $ClonesRoot $inst
    $settingsDir = Join-Path $cloneHome 'data\settings'
    $settingsPath = Join-Path $settingsDir 'cline_mcp_settings.json'
    $hubLock = Join-Path $cloneHome 'data\locks\hub\production.json.instance.lock'

    if (-not (Test-Path -LiteralPath $cloneHome)) { Write-SyncLine "[skip] $inst`: no clone home."; continue }

    # Running clone: the launcher's own per-clone hub lock (same probe shape
    # as launch_cline_clone.ps1's Test-HubLockHeld) - held = RUNNING -> SKIP.
    if (Test-Path -LiteralPath $hubLock) {
        $lockHeld = $false
        try {
            $fs = [System.IO.File]::Open($hubLock, 'Open', 'Read', 'None')
            $fs.Close()
        } catch { $lockHeld = $true }
        if ($lockHeld) {
            Write-Host "WARNING: $inst appears RUNNING (hub lock held) - SKIPPED (the launcher's pre-launch step covers it next launch)."
            continue
        }
    }

    $created = $false
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        # Deliberate CREATE (see header): the store is auth-free and the app
        # may never create it until an MCP panel is opened - waiting would
        # mean definitions never reach a fresh clone. The parent dir may not
        # exist on a never-launched-but-seeded clone home.
        if (-not (Test-Path -LiteralPath $settingsDir)) {
            New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        }
        $cloneCfg = [pscustomobject]@{ mcpServers = [pscustomobject]@{} }
        $created = $true
    } else {
        $cloneRaw = [System.IO.File]::ReadAllText($settingsPath)
        if ([string]::IsNullOrWhiteSpace($cloneRaw)) { $cloneRaw = '{}' }
        try { $cloneCfg = $cloneRaw | ConvertFrom-Json } catch {
            Write-Host "  [FAILED] clone MCP settings do not parse ($settingsPath): $($_.Exception.Message)" -ForegroundColor Red
            $exitCode = 1
            continue
        }
        if (-not $cloneCfg.PSObject.Properties['mcpServers']) {
            $cloneCfg | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{})
        }
        if (-not $cloneCfg.mcpServers) { $cloneCfg.mcpServers = [pscustomobject]@{} }
    }

    Write-SyncLine "[$inst] syncing $primaryServerCount Primary server definition(s) from $PrimarySettings"

    $result = Invoke-ClineMcpMerge -PrimaryServers $primaryCfg.mcpServers -CloneServers $cloneCfg.mcpServers

    if ($DryRun) {
        if ($created) { Write-SyncLine "  [dry-run] would CREATE $settingsPath and apply: $(@($result).Count) entr(y/ies): $(@($result) -join ', ')" 'Yellow' }
        else { Write-SyncLine "  [dry-run] would apply: $(@($result).Count) entr(y/ies): $(@($result) -join ', ')" 'Yellow' }
        continue
    }

    if (@($result).Count -eq 0) {
        Write-SyncLine "  [ok] already in sync."
        if ($created) {
            # Nothing to write even though the file was absent - persist the
            # empty container so the store exists for future syncs.
            Write-JsonNoBom -Path $settingsPath -Object $cloneCfg
        }
        continue
    }

    if (-not $created) {
        # Backup BEFORE the write (never silent success: backup, write, verify).
        $backupPath = Join-Path $settingsDir ("cline_mcp_settings-pre-sync-{0}.json" -f $stamp)
        [System.IO.File]::WriteAllText($backupPath, ([System.IO.File]::ReadAllText($settingsPath)), (New-Object System.Text.UTF8Encoding($false)))
    } else {
        $backupPath = ''
    }

    Write-JsonNoBom -Path $settingsPath -Object $cloneCfg

    # Verify-after: re-read + deep-compare against the merged object.
    $writtenRaw = [System.IO.File]::ReadAllText($settingsPath)
    $writtenCfg = $null
    try { $writtenCfg = $writtenRaw | ConvertFrom-Json } catch { $writtenCfg = $null }
    $verifyOk = $false
    if ($null -ne $writtenCfg) {
        $verifyOk = Test-DeepEqual (ConvertTo-DeepHashtable $writtenCfg) (ConvertTo-DeepHashtable $cloneCfg)
    }
    if ($verifyOk) {
        Write-SyncLine "  [ok] wrote + verified $(@($result).Count) entr(y/ies): $(@($result) -join ', ')"
    } else {
        Write-Host "  [FAILED] verify-after mismatch on $settingsPath$(if ($backupPath) { " - restore from $backupPath" })" -ForegroundColor Red
        $exitCode = 1
    }

    $audit = [ordered]@{
        ts       = (Get-Date).ToString('o')
        instance = $inst
        settings = $settingsPath
        backup   = $backupPath
        created  = $created
        changed  = @($result)
        verified = $verifyOk
    }
    $auditPath = Join-Path $cloneHome 'mcp-sync-audit.jsonl'
    [System.IO.File]::AppendAllText($auditPath, (($audit | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    $anyChanged = $true
}

if (-not $Quiet -or $anyChanged) {
    if ($DryRun) { Write-SyncLine "[dry-run] no writes performed." 'Yellow' }
}

# --- Primary untouched ----------------------------------------------------------
$primaryBytesAfter = [System.IO.File]::ReadAllBytes($PrimarySettings)
$sha2 = [System.Security.Cryptography.SHA256]::Create()
try { $primaryHashAfter = ($sha2.ComputeHash($primaryBytesAfter) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $sha2.Dispose() }
if ($primaryHashAfter -ne $primaryHashBefore) {
    Write-Host '[FAILED] the Primary MCP settings changed during the run - this tool must be read-only on the Primary!' -ForegroundColor Red
    exit 1
}

if (-not $Quiet) { Write-Host '[done] Cline MCP sync complete.' }
exit $exitCode
