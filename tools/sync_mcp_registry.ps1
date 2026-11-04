<#
.SYNOPSIS
  Machine-level MCP registry importer: tools\mcp\master-mcp.json -> every app's own config.

.DESCRIPTION
  The registry (tools\mcp\master-mcp.json, Claude-Desktop "mcpServers" format) is the single
  source of truth for MCP server DEFINITIONS. This script merges it into each app's native
  config with the SAME invariant pinned by tools\zcode_mcp_merge.ps1 (dot-sourced here — the
  one copy of the merge logic):
      - registry definitions win (replaced wholesale on the target),
      - app-local on/off state survives (enabled / disabled / autoApprove),
      - app-only servers are kept (never auto-deleted),
      - every write: backup -> write -> verify-after full-file re-read -> JSONL audit.
  Never silent-success: a verify mismatch is a FAILED result and a non-zero exit.

  SECRETS NEVER TRAVEL THROUGH THE REGISTRY. env/headers maps are merged PER KEY: the
  registry carries key names with ${PLACEHOLDER} values; when a placeholder cannot be
  resolved from the process environment and the app already has that key locally, the
  LOCAL VALUE IS KEPT. Local-only keys survive. A brand-new app gets the key name with an
  empty value plus a loud WARN (fill it once in that app, or set the env var machine-wide).
  ${VAR}, ${VAR:-default} and ${env:VAR} are all accepted.

  Per-entry scoping keys (stripped before writing):
      "only": ["minimax", ...]   - sync this server ONLY to the listed apps
      "apps": { "<target>": { ...definition overrides... } }  - per-app definition override

  v1 targets (paths verified on this machine / vendor docs — docs\MCP_CENTRAL_REGISTRY_PLAN.md):
    cursor    %USERPROFILE%\.cursor\mcp.json                 container mcpServers
              (adds "type":"stdio"/"http"; docs.cursor.com/context/mcp). Created only if
              %USERPROFILE%\.cursor already exists (Cursor installed).
    windsurf  %USERPROFILE%\.codeium\windsurf\mcp_config.json container mcpServers;
              remote entries use "serverUrl" (verified live 2026-11-03), NOT "url".
    vscode    %APPDATA%\Code\User\mcp.json                   container "servers"
              (type stdio/http; code.visualstudio.com MCP docs 2026-09; the user profile dir
              exists on this box, the mcp.json file is created on first sync).
    zcode     %USERPROFILE%\.zcode\cli\config.json           container mcp.servers
              (pass-through; clones converge via sync_zcode_assets.ps1 -McpOnly /
              watch_zcode_mcp_sync.ps1 — this script touches the Primary only).
    opencode  %USERPROFILE%\OpenCodeClonesHome\c*\config\opencode\opencode.json(c) — clones
              only (command is an ARRAY + "environment" per opencode.ai/docs/mcp-servers).
              The Primary's ~\.config\opencode\opencode.jsonc is EXCLUDED on purpose: it
              holds live provider API keys and may be JSONC with comments (CS-1 rule).
    minimax   %USERPROFILE%\.minimax\mcp\mcp.json            container mcpServers
              (verified live 2026-11-03: command/args/env + url with type "streamable-http").

  NOT wired yet (paths unverified / app not installed — documented as pending):
    Qoder (~\.qoder\mcp.json — absent; .qoder holds only skills/), Trae (no mcp.json found),
    Cline desktop (no mcp settings file in ClineClonesHome\cN\data), AutoClaw2 (no client
    MCP config located).

  PS 5.1 rules honored: no ternary, no $Input, ConvertTo-Json -InputObject (never piped),
  PSCustomObject/ConvertFrom-Json semantics, UTF8-no-BOM writes.

.PARAMETER Target
  cursor, windsurf, vscode, zcode, opencode, minimax, all (default: all).

.PARAMETER DryRun
  Compute and print the plan per target; write nothing (no file, no backup, no audit).

.PARAMETER RegistryPath
  Override the registry file (default: <repo>\tools\mcp\master-mcp.json).

.PARAMETER LocalOverridesPath
  Override the secrets/overrides overlay (default: <repo>\tools\mcp\master-mcp.local.json,
  optional — gitignored, skipped silently when missing).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_mcp_registry.ps1 -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_mcp_registry.ps1 -Target zcode,windsurf
#>
param(
    [string[]]$Target = @('all'),
    [switch]$DryRun,
    [string]$RegistryPath,
    [string]$LocalOverridesPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Merge core (single copy lives in zcode_mcp_merge.ps1 — unit-tested)
# ---------------------------------------------------------------------------
$mergeCore = Join-Path $PSScriptRoot 'zcode_mcp_merge.ps1'
if (-not (Test-Path -LiteralPath $mergeCore)) {
    throw "merge core not found: $mergeCore"
}
. $mergeCore

if (-not $RegistryPath)       { $RegistryPath       = Join-Path $PSScriptRoot 'mcp\master-mcp.json' }
if (-not $LocalOverridesPath) { $LocalOverridesPath = Join-Path $PSScriptRoot 'mcp\master-mcp.local.json' }

$script:LocalStateFields = @('enabled', 'disabled', 'autoApprove', 'description', 'builtin', 'configured', 'timeout')
$script:LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
if ([string]::IsNullOrEmpty($script:LocalAppData)) { $script:LocalAppData = Join-Path $env:USERPROFILE 'AppData\Local' }
$script:AuditDir  = Join-Path $script:LocalAppData 'mcp-registry-sync'
$script:AuditFile = Join-Path $script:AuditDir 'mcp-sync-audit.jsonl'
$script:AppData   = [Environment]::GetFolderPath('ApplicationData')

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
function DeepCopy-Json($obj) {
    if ($null -eq $obj) { return $null }
    return (ConvertTo-Json -InputObject $obj -Depth 100 | ConvertFrom-Json)
}

function Set-OrAddProp($obj, [string]$name, $value) {
    $p = $obj.PSObject.Properties[$name]
    if ($null -ne $p) { $p.Value = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Remove-PropIfExists($obj, [string]$name) {
    $p = $obj.PSObject.Properties[$name]
    if ($null -ne $p) { $obj.PSObject.Properties.Remove($name) }
}

function Write-JsonFileNoBom([string]$path, $rootObject) {
    $json = ConvertTo-Json -InputObject $rootObject -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $json + [Environment]::NewLine, $utf8NoBom)
}

function ConvertFrom-JsoncText([string]$text) {
    # Minimal JSONC -> JSON: strip /* */ blocks and // line comments (not "x://y" URLs).
    # Parse failure afterwards is surfaced as FAILED by the caller (no partial writes).
    $noBlock = [regex]::Replace($text, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $noLine  = [regex]::Replace($noBlock, '(?m)(?<!:)//[^\r\n]*', '')
    return ($noLine | ConvertFrom-Json)
}

function Read-AppConfig([string]$path, [bool]$isJsonc) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    if ($isJsonc) { return (ConvertFrom-JsoncText $raw) }
    return ($raw | ConvertFrom-Json)
}

function Get-ServerContainer($root, [string[]]$containerPath, [switch]$Create) {
    $node = $root
    for ($i = 0; $i -lt ($containerPath.Count - 1); $i++) {
        $p = $node.PSObject.Properties[$containerPath[$i]]
        if ($null -eq $p) {
            if (-not $Create) { return $null }
            $node | Add-Member -NotePropertyName $containerPath[$i] -NotePropertyValue (New-Object PSObject)
            $p = $node.PSObject.Properties[$containerPath[$i]]
        }
        $node = $p.Value
    }
    $last = $containerPath[$containerPath.Count - 1]
    $prop = $node.PSObject.Properties[$last]
    if ($null -eq $prop) {
        if (-not $Create) { return $null }
        $node | Add-Member -NotePropertyName $last -NotePropertyValue (New-Object PSObject)
        return $node.PSObject.Properties[$last].Value
    }
    if ($prop.Value -is [System.Management.Automation.PSCustomObject]) { return $prop.Value }
    throw "container '$($containerPath -join '.')' exists but is not a JSON object"
}

function Add-AuditLine([string]$target, [string]$file, [string]$server, [string]$action, [bool]$ok, [string]$note) {
    if ($DryRun) { return }
    if (-not (Test-Path -LiteralPath $script:AuditDir)) { New-Item -ItemType Directory -Path $script:AuditDir -Force | Out-Null }
    $rec = New-Object PSObject
    $rec | Add-Member -NotePropertyName ts     -NotePropertyValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    $rec | Add-Member -NotePropertyName target -NotePropertyValue $target
    $rec | Add-Member -NotePropertyName file   -NotePropertyValue $file
    $rec | Add-Member -NotePropertyName server -NotePropertyValue $server
    $rec | Add-Member -NotePropertyName action -NotePropertyValue $action
    $rec | Add-Member -NotePropertyName ok     -NotePropertyValue $ok
    $rec | Add-Member -NotePropertyName note   -NotePropertyValue $note
    $json = ConvertTo-Json -InputObject $rec -Depth 10 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($script:AuditFile, $json + [Environment]::NewLine, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# Placeholder expansion with tracking (unresolved names reported, never silent)
# ---------------------------------------------------------------------------
function Expand-ValueWithTracking([string]$value) {
    if ([string]::IsNullOrEmpty($value)) { return @{ Text = $value; Unresolved = @(); UsedDefault = $false } }
    $unresolved = @()
    $usedDefault = $false
    $out = New-Object System.Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($value, '\$\{(?:env:)?([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}')) {
        [void]$out.Append($value.Substring($pos, $m.Index - $pos))
        $name   = $m.Groups[1].Value
        $envVal = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrEmpty($envVal)) {
            if ($m.Groups[2].Success) { [void]$out.Append($m.Groups[2].Value); $usedDefault = $true }
            else { $unresolved += $name }
        }
        else { [void]$out.Append($envVal) }
        $pos = $m.Index + $m.Length
    }
    [void]$out.Append($value.Substring($pos))
    return @{ Text = $out.ToString(); Unresolved = $unresolved; UsedDefault = $usedDefault }
}

function Merge-SecretMap($registryMap, $localMap, [string]$targetName, [string]$serverName, [string]$what) {
    # Per-key merge for env/headers: registry key names win, secrets stay local.
    $result = New-Object PSObject
    if ($null -ne $localMap) {
        foreach ($p in @($localMap.PSObject.Properties)) { Set-OrAddProp $result $p.Name $p.Value }
    }
    if ($null -ne $registryMap) {
        foreach ($p in @($registryMap.PSObject.Properties)) {
            $exp = Expand-ValueWithTracking ([string]$p.Value)
            $val = $exp.Text
            $lp = $null
            if ($null -ne $localMap) { $lp = $localMap.PSObject.Properties[$p.Name] }
            if ($exp.Unresolved.Count -gt 0) {
                if ($null -ne $lp) { $val = $lp.Value }
                else {
                    # Never write a placeholder/empty value: OMIT the key and say so loudly.
                    Write-Host ("    [env-guard] WARN: {0}/{1} {2}.{3} unresolved ({4}) and no local value - key OMITTED; fill it once in the app (or set the env var machine-wide)." -f $targetName, $serverName, $what, $p.Name, ($exp.Unresolved -join ',')) -ForegroundColor Yellow
                    continue
                }
            }
            elseif ($exp.UsedDefault -and $null -ne $lp) {
                # A concrete env var ALWAYS wins; a mere default never overwrites a live local value.
                $val = $lp.Value
            }
            Set-OrAddProp $result $p.Name $val
        }
    }
    if (@($result.PSObject.Properties).Count -eq 0) { return $null }
    return $result}

function Merge-RegistryOverlay($base, $overlay) {
    if ($null -eq $overlay) { return $base }
    if ($null -eq $base)    { return (DeepCopy-Json $overlay) }
    if ($base -is [System.Management.Automation.PSCustomObject] -and $overlay -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in @($overlay.PSObject.Properties)) {
            $bProp = $base.PSObject.Properties[$p.Name]
            if ($null -ne $bProp -and $bProp.Value -is [System.Management.Automation.PSCustomObject] -and $p.Value -is [System.Management.Automation.PSCustomObject]) {
                $bProp.Value = Merge-RegistryOverlay $bProp.Value $p.Value
            }
            elseif ($null -ne $bProp) { $bProp.Value = DeepCopy-Json $p.Value }
            else { $base | Add-Member -NotePropertyName $p.Name -NotePropertyValue (DeepCopy-Json $p.Value) }
        }
        return $base
    }
    return (DeepCopy-Json $overlay)
}

# ---------------------------------------------------------------------------
# Registry loading: base + local overlay (deep merge, local wins)
# ---------------------------------------------------------------------------
function Get-RegistryServers {
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        throw "registry not found: $RegistryPath (this file is the source of truth - create it first)"
    }
    $raw = [System.IO.File]::ReadAllText($RegistryPath)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "registry is empty: $RegistryPath" }
    $base = $raw | ConvertFrom-Json
    if (Test-Path -LiteralPath $LocalOverridesPath) {
        $oRaw = [System.IO.File]::ReadAllText($LocalOverridesPath)
        if (-not [string]::IsNullOrWhiteSpace($oRaw)) {
            $overlay = $oRaw | ConvertFrom-Json
            $base = Merge-RegistryOverlay $base $overlay
            Write-Host "[registry] overlay applied: $LocalOverridesPath" -ForegroundColor DarkGray
        }
    }
    $servers = Get-ServerContainer $base @('mcpServers')
    if ($null -eq $servers -or @($servers.PSObject.Properties).Count -eq 0) {
        Write-Host '[registry] no mcpServers entries - nothing to sync.' -ForegroundColor Green
        return $null
    }
    $clean = New-Object PSObject
    foreach ($p in @($servers.PSObject.Properties)) {
        $e = $p.Value
        $hasCmd = ($null -ne $e.PSObject.Properties['command'])
        $hasUrl = ($null -ne $e.PSObject.Properties['url'])
        if (-not $hasCmd -and -not $hasUrl) {
            Write-Host ("[registry] WARN: '{0}' has neither command nor url - SKIPPED (fix the registry entry)" -f $p.Name) -ForegroundColor Yellow
            Add-AuditLine -target 'registry' -file $RegistryPath -server $p.Name -action 'validate' -ok:$false -note 'entry has neither command nor url'
            continue
        }
        if ($hasCmd -and $hasUrl) {
            Write-Host ("[registry] WARN: '{0}' has BOTH command and url - the url (remote) wins" -f $p.Name) -ForegroundColor Yellow
            Remove-PropIfExists $e 'command'
            Remove-PropIfExists $e 'args'
        }
        $clean | Add-Member -NotePropertyName $p.Name -NotePropertyValue $e
    }
    return $clean
}

# ---------------------------------------------------------------------------
# Per-app shape transforms (registry canonical -> app native entry)
# ---------------------------------------------------------------------------
function ConvertTo-AppEntry($canonicalEntry, [string]$mode) {
    $isRemote = ($null -ne $canonicalEntry.PSObject.Properties['url'])

    if ($mode -eq 'passthrough' -or $mode -eq 'zcode') { return $canonicalEntry }

    if ($mode -eq 'windsurf') {
        # Verified live 2026-11-03: Windsurf remote entries use "serverUrl" and no "type".
        Remove-PropIfExists $canonicalEntry 'type'
        if ($isRemote) {
            $u = [string]$canonicalEntry.url
            Remove-PropIfExists $canonicalEntry 'url'
            Set-OrAddProp $canonicalEntry 'serverUrl' $u
        }
        return $canonicalEntry
    }

    if ($mode -eq 'minimax') {
        # Verified live 2026-11-03: MiniMax stdio entries carry NO "type"; remote entries
        # use "streamable-http".
        if ($isRemote) {
            $t = $canonicalEntry.PSObject.Properties['type']
            if ($null -ne $t -and [string]$t.Value -eq 'http') { Set-OrAddProp $canonicalEntry 'type' 'streamable-http' }
            elseif ($null -eq $t) { Set-OrAddProp $canonicalEntry 'type' 'streamable-http' }
        }
        else {
            Remove-PropIfExists $canonicalEntry 'type'
        }
        return $canonicalEntry
    }

    if ($mode -eq 'cursor' -or $mode -eq 'vscode') {
        if ($isRemote) { Set-OrAddProp $canonicalEntry 'type' 'http' }
        else           { Set-OrAddProp $canonicalEntry 'type' 'stdio' }
        return $canonicalEntry
    }

    if ($mode -eq 'opencode') {
        if ($isRemote) {
            $v = New-Object PSObject
            Set-OrAddProp $v 'type' 'remote'
            Set-OrAddProp $v 'url' $canonicalEntry.url
            $h = $canonicalEntry.PSObject.Properties['headers']
            if ($null -ne $h) { Set-OrAddProp $v 'headers' $h.Value }
            $t = $canonicalEntry.PSObject.Properties['timeoutMs']
            if ($null -ne $t) { Set-OrAddProp $v 'timeout' $t.Value }
            $en = $canonicalEntry.PSObject.Properties['enabled']
            if ($null -ne $en) { Set-OrAddProp $v 'enabled' $en.Value }
            return $v
        }
        else {
            $cmdList = @()
            $cmdList += [string]$canonicalEntry.command
            $a = $canonicalEntry.PSObject.Properties['args']
            if ($null -ne $a) { $cmdList += @($a.Value) }
            $v = New-Object PSObject
            Set-OrAddProp $v 'type' 'local'
            Set-OrAddProp $v 'command' $cmdList
            $envP = $canonicalEntry.PSObject.Properties['env']
            if ($null -ne $envP) { Set-OrAddProp $v 'environment' $envP.Value }
            $t = $canonicalEntry.PSObject.Properties['timeoutMs']
            if ($null -ne $t) { Set-OrAddProp $v 'timeout' $t.Value }
            $en = $canonicalEntry.PSObject.Properties['enabled']
            if ($null -ne $en) { Set-OrAddProp $v 'enabled' $en.Value }
            return $v
        }
    }
    throw "unknown mode: $mode"
}

# ---------------------------------------------------------------------------
# Local-state snapshot / restore (enabled, disabled, autoApprove survive syncs)
# ---------------------------------------------------------------------------
function Get-LocalStateMap($container) {
    $map = @{}
    foreach ($p in @($container.PSObject.Properties)) {
        $st = New-Object PSObject
        foreach ($f in $script:LocalStateFields) {
            $fp = $p.Value.PSObject.Properties[$f]
            if ($null -ne $fp) { $st | Add-Member -NotePropertyName $f -NotePropertyValue $fp.Value }
        }
        if (@($st.PSObject.Properties).Count -gt 0) { $map[$p.Name] = $st }
    }
    return $map
}

function Strip-LocalState($container, $map) {
    # Remove local on/off fields BEFORE the merge comparison so a state-only difference
    # does not register as a definition change (Restore re-adds them afterwards).
    foreach ($p in @($container.PSObject.Properties)) {
        if ($map.ContainsKey($p.Name)) {
            foreach ($f in $script:LocalStateFields) {
                if ($null -ne $map[$p.Name].PSObject.Properties[$f]) { Remove-PropIfExists $p.Value $f }
            }
        }
    }
}

function Repair-ArrayFields($container, [string]$mode) {
    # PS 5.1 ConvertFrom-Json turns a single-element JSON array into a bare string.
    # args (and opencode's command) are ALWAYS arrays in the written file - wrap them back.
    # Idempotent: safe on any parsed tree, so both sides of every compare get the same shape.
    if ($null -eq $container) { return }
    foreach ($p in @($container.PSObject.Properties)) {
        $ap = $p.Value.PSObject.Properties['args']
        if ($null -ne $ap -and $ap.Value -is [string]) { $ap.Value = @($ap.Value) }
        if ($mode -eq 'opencode') {
            $cp = $p.Value.PSObject.Properties['command']
            if ($null -ne $cp -and $cp.Value -is [string]) { $cp.Value = @($cp.Value) }
        }
    }
}

function Restore-LocalState($container, $map) {
    foreach ($p in @($container.PSObject.Properties)) {
        if ($map.ContainsKey($p.Name)) {
            foreach ($f in $script:LocalStateFields) {
                $fp = $map[$p.Name].PSObject.Properties[$f]
                if ($null -ne $fp -and $null -eq $p.Value.PSObject.Properties[$f]) {
                    $p.Value | Add-Member -NotePropertyName $f -NotePropertyValue $fp.Value
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
function Get-TargetTable {
    $u = $env:USERPROFILE
    $t = [ordered]@{
        cursor   = @{ Mode = 'cursor';      Jsonc = $false; Container = @('mcpServers');
                      Files = @((Join-Path $u '.cursor\mcp.json'));
                      CreateIfMissing = (Test-Path -LiteralPath (Join-Path $u '.cursor')) }
        windsurf = @{ Mode = 'windsurf';    Jsonc = $false; Container = @('mcpServers');
                      Files = @((Join-Path $u '.codeium\windsurf\mcp_config.json')); CreateIfMissing = $true }
        vscode   = @{ Mode = 'vscode';      Jsonc = $false; Container = @('servers');
                      Files = @((Join-Path $script:AppData 'Code\User\mcp.json')); CreateIfMissing = $true }
        zcode    = @{ Mode = 'zcode';       Jsonc = $false; Container = @('mcp', 'servers');
                      Files = @((Join-Path $u '.zcode\cli\config.json')); CreateIfMissing = $false }
        minimax  = @{ Mode = 'minimax';     Jsonc = $false; Container = @('mcpServers');
                      Files = @((Join-Path $u '.minimax\mcp\mcp.json')); CreateIfMissing = $false }
        opencode = @{ Mode = 'opencode';    Jsonc = $true;  Container = @('mcp');
                      Files = @(); CreateIfMissing = $false; Glob = 'OpenCodeClonesHome' }
    }
    return $t
}

function Resolve-TargetFiles([string]$name, $spec) {
    if ($name -ne 'opencode') { return $spec.Files }
    $home_root = Join-Path $env:USERPROFILE $spec.Glob
    $found = @()
    if (Test-Path -LiteralPath $home_root) {
        $found = @(Get-ChildItem -LiteralPath $home_root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $jsonc = Join-Path $_.FullName 'config\opencode\opencode.jsonc'
            $json  = Join-Path $_.FullName 'config\opencode\opencode.json'
            if (Test-Path -LiteralPath $jsonc) { $jsonc }
            elseif (Test-Path -LiteralPath $json) { $json }
        } | Where-Object { $_ })
    }
    if ($found.Count -eq 0) {
        Write-Host '[OK:opencode] no clone configs found (nothing to sync - clones seed on first launch).' -ForegroundColor Green
    }
    return $found
}

# ---------------------------------------------------------------------------
# Build the per-target server view (scoping, per-app overrides, secret-safe merge)
# ---------------------------------------------------------------------------
function Build-TargetView($registryServers, $spec, [string]$targetName, $container) {
    $view = New-Object PSObject
    foreach ($p in @($registryServers.PSObject.Properties)) {
        $entry = DeepCopy-Json $p.Value

        $onlyProp = $entry.PSObject.Properties['only']
        if ($null -ne $onlyProp) {
            $onlyList = @($onlyProp.Value | ForEach-Object { ([string]$_).ToLowerInvariant() })
            Remove-PropIfExists $entry 'only'
            if ($onlyList -notcontains $targetName) { continue }
        }

        $appsProp = $entry.PSObject.Properties['apps']
        if ($null -ne $appsProp) {
            $ov = $appsProp.Value.PSObject.Properties[$targetName]
            if ($null -ne $ov) { $entry = Merge-RegistryOverlay $entry (DeepCopy-Json $ov.Value) }
            Remove-PropIfExists $entry 'apps'
        }
        # A per-app override that turns the entry remote wins over its stdio definition.
        if ($null -ne $entry.PSObject.Properties['url'] -and $null -ne $entry.PSObject.Properties['command']) {
            Remove-PropIfExists $entry 'command'
            Remove-PropIfExists $entry 'args'
        }

        $localEntry = $null
        if ($null -ne $container) {
            $lp = $container.PSObject.Properties[$p.Name]
            if ($null -ne $lp) { $localEntry = $lp.Value }
        }
        $localEnv = $null; $localHdr = $null
        if ($null -ne $localEntry) {
            $le = $localEntry.PSObject.Properties['env'];     if ($null -ne $le) { $localEnv = $le.Value }
            $lh = $localEntry.PSObject.Properties['headers']; if ($null -ne $lh) { $localHdr = $lh.Value }
        }

        $regEnv = $entry.PSObject.Properties['env']
        $regEnvVal = $null
        if ($null -ne $regEnv -and $regEnv.Value -is [System.Management.Automation.PSCustomObject]) { $regEnvVal = $regEnv.Value }
        if ($null -eq $regEnvVal -and $null -ne $localEnv) {
            # Registry says nothing about env -> leave the app's map untouched.
            Set-OrAddProp $entry 'env' $localEnv
        }
        else {
            $mergedEnv = Merge-SecretMap $regEnvVal $localEnv $targetName $p.Name 'env'
            if ($null -ne $mergedEnv) { Set-OrAddProp $entry 'env' $mergedEnv } else { Remove-PropIfExists $entry 'env' }
        }

        $regHdr = $entry.PSObject.Properties['headers']
        $regHdrVal = $null
        if ($null -ne $regHdr -and $regHdr.Value -is [System.Management.Automation.PSCustomObject]) { $regHdrVal = $regHdr.Value }
        if ($null -eq $regHdrVal -and $null -ne $localHdr) {
            Set-OrAddProp $entry 'headers' $localHdr
        }
        else {
            $mergedHdr = Merge-SecretMap $regHdrVal $localHdr $targetName $p.Name 'headers'
            if ($null -ne $mergedHdr) { Set-OrAddProp $entry 'headers' $mergedHdr } else { Remove-PropIfExists $entry 'headers' }
        }

        foreach ($f in @('command', 'url')) {
            $fp = $entry.PSObject.Properties[$f]
            if ($null -ne $fp) {
                $ex = Expand-ValueWithTracking ([string]$fp.Value)
                $fp.Value = $ex.Text
                foreach ($un in $ex.Unresolved) {
                    Write-Host ("    [scalar] WARN: {0}/{1} {2} placeholder '${3}' unresolved - expanded to empty." -f $targetName, $p.Name, $f, $un) -ForegroundColor Yellow
                }
            }
        }
        $ap = $entry.PSObject.Properties['args']
        if ($null -ne $ap -and $null -ne $ap.Value) {
            if ($ap.Value -is [string]) {
                # PS 5.1 parses a single-element JSON array as a bare string.
                $ex = Expand-ValueWithTracking ([string]$ap.Value)
                $ap.Value = @($ex.Text)
                foreach ($un in $ex.Unresolved) {
                    Write-Host ("    [scalar] WARN: {0}/{1} args placeholder '${2}' unresolved - expanded to empty." -f $targetName, $p.Name, $un) -ForegroundColor Yellow
                }
            }
            elseif ($ap.Value -is [System.Collections.IEnumerable]) {
                for ($i = 0; $i -lt $ap.Value.Count; $i++) {
                    $ex = Expand-ValueWithTracking ([string]$ap.Value[$i])
                    $ap.Value[$i] = $ex.Text
                    foreach ($un in $ex.Unresolved) {
                        Write-Host ("    [scalar] WARN: {0}/{1} args[{2}] placeholder '${3}' unresolved - expanded to empty." -f $targetName, $p.Name, $i, $un) -ForegroundColor Yellow
                    }
                }
            }
        }

        $view | Add-Member -NotePropertyName $p.Name -NotePropertyValue (ConvertTo-AppEntry $entry $spec.Mode)
    }
    return $view
}

# ---------------------------------------------------------------------------
# Per-file sync
# ---------------------------------------------------------------------------
function Sync-OneFile([string]$targetName, $spec, [string]$file, $registryServers) {
    $fileExists = Test-Path -LiteralPath $file
    if (-not $fileExists -and -not $spec.CreateIfMissing) {
        Write-Host ("[{0}] SKIP (config not created yet by the app): {1}" -f $targetName, $file) -ForegroundColor DarkYellow
        Add-AuditLine -target $targetName -file $file -server '-' -action 'skip' -ok:$true -note 'config missing'
        return 'skip'
    }

    try { $originalRoot = Read-AppConfig $file $spec.Jsonc }
    catch {
        Write-Host ("[FAILED:{0}] config exists but does not parse ({1}) - NOT touching it: {2}" -f $targetName, $_.Exception.Message, $file) -ForegroundColor Red
        Add-AuditLine -target $targetName -file $file -server '-' -action 'parse' -ok:$false -note $_.Exception.Message
        return 'failed'
    }
    if ($null -eq $originalRoot) {
        if (-not $spec.CreateIfMissing) {
            Write-Host ("[{0}] SKIP (empty config): {1}" -f $targetName, $file) -ForegroundColor DarkYellow
            return 'skip'
        }
        $originalRoot = New-Object PSObject
    }

    $workRoot = DeepCopy-Json $originalRoot
    $container = Get-ServerContainer $workRoot $spec.Container -Create

    # Frozen raw view of the app's own entries (authoritative change detection below).
    $rawSnapshot = $null
    if ($null -ne $originalRoot) {
        $rawSnapshot = Get-ServerContainer (DeepCopy-Json $originalRoot) $spec.Container
        if ($null -ne $rawSnapshot) { Repair-ArrayFields $rawSnapshot $spec.Mode }
    }

    $stateMap = Get-LocalStateMap $container
    Strip-LocalState $container $stateMap
    $view = Build-TargetView $registryServers $spec $targetName $container
    if (@($view.PSObject.Properties).Count -eq 0) {
        Write-Host ("[OK:{0}] registry has no servers scoped to this target - nothing to do." -f $targetName) -ForegroundColor Green
        return 'noop'
    }

    [void](Invoke-McpMerge -PrimaryServers $view -CloneServers $container)
    Repair-ArrayFields $container $spec.Mode
    Restore-LocalState $container $stateMap

    # Change detection = raw app entry before vs after (state fields were restored to their
    # own values, so only definition / secret-map differences can register here).
    $changed = @()
    foreach ($vp in @($view.PSObject.Properties)) {
        $cur = $container.PSObject.Properties[$vp.Name]
        if ($null -eq $cur) { continue }
        $old = $null
        if ($null -ne $rawSnapshot) { $old = $rawSnapshot.PSObject.Properties[$vp.Name] }
        if ($null -eq $old) { $changed += $vp.Name; continue }
        if (-not (Test-DeepEqual (ConvertTo-DeepHashtable $old.Value) (ConvertTo-DeepHashtable $cur.Value))) { $changed += $vp.Name }
    }
    if ($env:MCP_SYNC_DEBUG) {
        Write-Host ("  [debug] {0} ({1}) changed: {2}" -f $targetName, (Split-Path -Leaf $file), ($changed -join ',')) -ForegroundColor DarkGray
    }

    $localOnly = @($container.PSObject.Properties | Where-Object { $null -eq $view.PSObject.Properties[$_.Name] } | ForEach-Object { $_.Name })

    if ($changed.Count -eq 0) {
        Write-Host ("[OK:{0}] already in sync ({1} servers, {2} app-only kept{3})." -f $targetName, @($view.PSObject.Properties).Count, $localOnly.Count, $(if ($fileExists) { '' } else { ', file created' })) -ForegroundColor Green
        Add-AuditLine -target $targetName -file $file -server '-' -action 'noop' -ok:$true -note ('in sync; app-only: ' + ($localOnly -join ','))
        return 'noop'
    }

    if ($DryRun) {
        Write-Host ("[DRYRUN:{0}] would update {1} server(s) in {2}:" -f $targetName, $changed.Count, $file) -ForegroundColor Cyan
        $preCont = $null
        if ($null -ne $originalRoot) { $preCont = Get-ServerContainer $originalRoot $spec.Container }
        foreach ($n in $changed) {
            $isNew = ($null -eq $preCont) -or ($null -eq $preCont.PSObject.Properties[$n])
            Write-Host ("    - {0} ({1})" -f $n, $(if ($isNew) { 'add' } else { 'update' })) -ForegroundColor Cyan
        }
        if ($localOnly.Count -gt 0) { Write-Host ("    kept app-only: {0}" -f ($localOnly -join ', ')) -ForegroundColor DarkCyan }
        return 'dryrun'
    }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path (Split-Path -Parent $file) ("MCP_Backups\" + $ts)
    if ($fileExists) {
        if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
        Copy-Item -LiteralPath $file -Destination (Join-Path $backupDir (Split-Path -Leaf $file)) -Force
    }
    try {
        Write-JsonFileNoBom $file $workRoot
    }
    catch {
        Write-Host ("[FAILED:{0}] write failed: {1}" -f $targetName, $_.Exception.Message) -ForegroundColor Red
        Add-AuditLine -target $targetName -file $file -server '-' -action 'write' -ok:$false -note $_.Exception.Message
        return 'failed'
    }

    try { $reRead = Read-AppConfig $file $spec.Jsonc }
    catch { $reRead = $null }

    $equal = $false
    if ($null -ne $reRead) {
        $reCont = Get-ServerContainer $reRead $spec.Container
        if ($null -ne $reCont) { Repair-ArrayFields $reCont $spec.Mode }
        $equal = Test-DeepEqual (ConvertTo-DeepHashtable $reRead) (ConvertTo-DeepHashtable $workRoot)
    }
    if (-not $equal) {
        $bak = Join-Path $backupDir (Split-Path -Leaf $file)
        Write-Host ("[FAILED:{0}] verify-after mismatch - re-read does not match what was written. Backup: {1}" -f $targetName, $bak) -ForegroundColor Red
        Add-AuditLine -target $targetName -file $file -server '-' -action 'verify' -ok:$false -note 're-read mismatch'
        return 'failed'
    }

    $adds = @(); $updates = @()
    $preContainer = $null
    if ($null -ne $originalRoot) { $preContainer = Get-ServerContainer $originalRoot $spec.Container }
    foreach ($n in $changed) {
        if ($null -eq $preContainer -or $null -eq $preContainer.PSObject.Properties[$n]) { $adds += $n } else { $updates += $n }
    }
    Write-Host ("[OK:{0}] +{1} ~{2} (app-only kept: {3}) -> {4}" -f $targetName, $adds.Count, $updates.Count, $localOnly.Count, $file) -ForegroundColor Green
    foreach ($n in $adds)    { Add-AuditLine -target $targetName -file $file -server $n -action 'add'    -ok:$true -note '' }
    foreach ($n in $updates) { Add-AuditLine -target $targetName -file $file -server $n -action 'update' -ok:$true -note '' }
    if ($targetName -eq 'zcode') {
        Write-Host '    [zcode] clones converge on their next launch via sync_zcode_assets.ps1 / watch_zcode_mcp_sync.ps1 (unchanged machinery).' -ForegroundColor DarkGray
    }
    return 'ok'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$allTargets = Get-TargetTable
$wanted = @()
foreach ($t in $Target) {
    $k = $t.ToLowerInvariant()
    if ($k -eq 'all') { $wanted += @($allTargets.Keys); continue }
    if (-not $allTargets.Contains($k)) { throw "unknown target '$t' (valid: $($allTargets.Keys -join ', '), all)" }
    $wanted += $k
}
$wanted = @($wanted | Select-Object -Unique)

$modeNote = ''
if ($DryRun) { $modeNote = ' (DRY RUN - nothing will be written)' }
Write-Host ("=== GHOST MCP registry sync{0} ===" -f $modeNote) -ForegroundColor Magenta

$registryServers = Get-RegistryServers
if ($null -eq $registryServers) { Write-Host 'Nothing to do.' -ForegroundColor Green; exit 0 }
$regNames = @($registryServers.PSObject.Properties | ForEach-Object { $_.Name })
Write-Host ("[registry] {0} server(s): {1}" -f $regNames.Count, ($regNames -join ', ')) -ForegroundColor Gray

$results = @()
foreach ($name in $wanted) {
    $spec = $allTargets[$name]
    $files = Resolve-TargetFiles $name $spec
    foreach ($f in $files) {
        $r = Sync-OneFile $name $spec $f $registryServers
        if ($null -ne $r) { $results += [string]$r }
    }
}

$failed = @($results | Where-Object { $_ -eq 'failed' })
if ($failed.Count -gt 0) {
    Write-Host ("=== DONE with {0} FAILED target file(s) - see audit: {1} ===" -f $failed.Count, $script:AuditFile) -ForegroundColor Red
    exit 1
}
Write-Host '=== DONE (all targets OK) ===' -ForegroundColor Green
exit 0
