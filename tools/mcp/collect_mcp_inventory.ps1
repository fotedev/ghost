<#
.SYNOPSIS
  Harvest every MCP server definition found on this machine into one inventory file.

.DESCRIPTION
  The REVERSE direction of sync_mcp_registry.ps1: instead of pushing the registry into
  apps, this scans every known MCP config location (verified paths — see
  docs\MCP_CENTRAL_REGISTRY_PLAN.md §2/§11) and collects what each app actually has.

  NEVER reads secret VALUES: env/headers contribute key NAMES only; long token-shaped
  strings inside args are redacted. Output: tools\mcp\mcp-inventory.json + console table.

  Read-only: the only file written is the inventory (and never inside any app's config).

.PARAMETER OutPath
  Inventory output path (default: <repo>\tools\mcp\mcp-inventory.json).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\mcp\collect_mcp_inventory.ps1
#>
param(
    [string]$OutPath
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $OutPath) { $OutPath = Join-Path $PSScriptRoot 'mcp-inventory.json' }

$AD  = [Environment]::GetFolderPath('ApplicationData')
$LAD = [Environment]::GetFolderPath('LocalApplicationData')
$U   = $env:USERPROFILE

function Redact([string]$v) {
    if ([string]::IsNullOrEmpty($v)) { return $v }
    if ($v.Length -ge 32 -and $v -match '^[A-Za-z0-9_\-\.=+/]+$') { return '<REDACTED>' }
    return $v
}

function ConvertFrom-JsonLoose([string]$text) {
    try { return ($text | ConvertFrom-Json) } catch {}
    $nb = [regex]::Replace($text, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $nl = [regex]::Replace($nb, '(?m)(?<!:)//[^\r\n]*', '')
    try { return ($nl | ConvertFrom-Json) } catch { return $null }
}

function Get-EntrySummary($e) {
    $r = New-Object PSObject
    $kind = 'unknown'
    if     ($null -ne $e.PSObject.Properties['url'])      { $kind = 'remote' }
    elseif ($null -ne $e.PSObject.Properties['serverUrl']){ $kind = 'remote' }
    elseif ($null -ne $e.PSObject.Properties['command'])  { $kind = 'stdio' }
    $r | Add-Member -NotePropertyName kind -NotePropertyValue $kind
    foreach ($f in @('type', 'command')) {
        $p = $e.PSObject.Properties[$f]
        if ($null -ne $p) { $r | Add-Member -NotePropertyName $f -NotePropertyValue ([string]$p.Value) }
    }
    $p = $e.PSObject.Properties['args']
    if ($null -ne $p) {
        $arr = @($p.Value) | ForEach-Object { Redact ([string]$_) }
        $r | Add-Member -NotePropertyName args -NotePropertyValue $arr
    }
    foreach ($f in @('url', 'serverUrl')) {
        $p = $e.PSObject.Properties[$f]
        if ($null -ne $p) { $r | Add-Member -NotePropertyName $f -NotePropertyValue ([string]$p.Value) }
    }
    $p = $e.PSObject.Properties['env']
    if ($null -ne $p -and $null -ne $p.Value) {
        $r | Add-Member -NotePropertyName envKeys -NotePropertyValue (@($p.Value.PSObject.Properties.Name))
    }
    $p = $e.PSObject.Properties['headers']
    if ($null -ne $p -and $null -ne $p.Value) {
        $r | Add-Member -NotePropertyName headerKeys -NotePropertyValue (@($p.Value.PSObject.Properties.Name))
    }
    foreach ($f in @('enabled', 'disabled')) {
        $p = $e.PSObject.Properties[$f]
        if ($null -ne $p) { $r | Add-Member -NotePropertyName $f -NotePropertyValue ([bool]$p.Value) }
    }
    return $r
}

function Add-Location([string]$app, [string]$file, [string]$role, [string[]]$containerPath, [string]$note) {
    if (-not (Test-Path -LiteralPath $file)) {
        $script:Locations += (New-Object PSObject -Property @{ app = $app; file = $file; role = $role; status = 'missing'; note = $note; servers = @() })
        return
    }
    $raw = [System.IO.File]::ReadAllText($file)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $script:Locations += (New-Object PSObject -Property @{ app = $app; file = $file; role = $role; status = 'empty'; note = $note; servers = @() })
        return
    }
    $root = ConvertFrom-JsonLoose $raw
    if ($null -eq $root) {
        $script:Locations += (New-Object PSObject -Property @{ app = $app; file = $file; role = $role; status = 'parse-fail'; note = $note; servers = @() })
        return
    }
    $node = $root; $ok = $true
    foreach ($seg in $containerPath) {
        $p = $node.PSObject.Properties[$seg]
        if ($null -eq $p) { $ok = $false; break }
        $node = $p.Value
    }
    if (-not $ok -or $node -isnot [System.Management.Automation.PSCustomObject]) {
        $script:Locations += (New-Object PSObject -Property @{ app = $app; file = $file; role = $role; status = 'no-container'; note = $note; servers = @() })
        return
    }
    $servers = @()
    foreach ($pr in @($node.PSObject.Properties)) {
        $s = Get-EntrySummary $pr.Value
        $s | Add-Member -NotePropertyName name -NotePropertyValue $pr.Name
        $servers += $s
    }
    $script:Locations += (New-Object PSObject -Property @{ app = $app; file = $file; role = $role; status = 'ok'; note = $note; servers = $servers })
    return
}

function Add-NoteOnly([string]$app, [string]$note) {
    $script:Locations += (New-Object PSObject -Property @{ app = $app; file = ''; role = 'info'; status = 'note'; note = $note; servers = @() })
    return
}

# --- Hermes (YAML) — light block scan: names + transport + enabled only --------------
function Add-HermesYaml([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) {
        $script:Locations += (New-Object PSObject -Property @{ app = 'hermes'; file = $file; role = 'consumer (yaml - not a sync target)'; status = 'missing'; note = ''; servers = @() })
        return
    }
    $lines = [System.IO.File]::ReadAllLines($file)
    $startIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^mcp_servers:') { $startIdx = $i; break } }
    if ($startIdx -lt 0) {
        $script:Locations += (New-Object PSObject -Property @{ app = 'hermes'; file = $file; role = 'consumer (yaml - not a sync target)'; status = 'no-container'; note = ''; servers = @() })
        return
    }
    $servers = @()
    $current = $null
    for ($i = $startIdx + 1; $i -lt $lines.Count; $i++) {
        $L = $lines[$i]
        if ($L -match '^\S') { break }  # next top-level key -> mcp_servers block ended
        if ($L -match '^  ([A-Za-z0-9_\-\.]+):\s*$') {
            if ($null -ne $current) { $servers += $current }
            $current = New-Object PSObject
            $current | Add-Member -NotePropertyName name -NotePropertyValue $Matches[1]
            $current | Add-Member -NotePropertyName kind -NotePropertyValue 'unknown'
        }
        elseif ($null -ne $current) {
            if ($L -match '^\s+url:\s*(\S+)')            { $current.kind = 'remote'; $current | Add-Member -NotePropertyName url -NotePropertyValue $Matches[1] }
            elseif ($L -match '^\s+command:\s*(\S+)')     { $current.kind = 'stdio';  $current | Add-Member -NotePropertyName command -NotePropertyValue $Matches[1] }
            elseif ($L -match '^\s+enabled:\s*(\S+)')     { $current | Add-Member -NotePropertyName enabled -NotePropertyValue ($Matches[1] -eq 'true') }
            elseif ($L -match '^\s+auth:\s*(\S+)')        { $current | Add-Member -NotePropertyName auth -NotePropertyValue $Matches[1] }
            elseif ($L -match '^\s+env:')                 { $current | Add-Member -NotePropertyName envKeys -NotePropertyValue @('(see app config)') }
        }
    }
    if ($null -ne $current) { $servers += $current }
    $script:Locations += (New-Object PSObject -Property @{ app = 'hermes'; file = $file; role = 'consumer (yaml - not a sync target)'; status = 'ok'; note = 'light YAML scan'; servers = $servers })
    return
}

# ---------------------------------------------------------------------------
$script:Locations = @()

# ZCode Primary (+ clones as read-only mirrors of the existing sync machinery)
Add-Location 'zcode-primary' (Join-Path $U '.zcode\cli\config.json') 'target (sync)' @('mcp','servers') 'Primary; clones converge via sync_zcode_assets/watch_zcode_mcp_sync'
foreach ($d in @(Get-ChildItem $U -Directory -Filter 'ZCode*Home')) {
    $c = Join-Path $d.FullName '.zcode\cli\config.json'
    if (Test-Path -LiteralPath $c) { Add-Location ('zcode-' + $d.Name) $c 'mirror (existing machinery)' @('mcp','servers') 'kept in sync by sync_zcode_assets.ps1 - not a direct target' }
}
# Windsurf / VS Code / MiniMax / OpenCode clones
Add-Location 'windsurf' (Join-Path $U '.codeium\windsurf\mcp_config.json') 'target (sync)' @('mcpServers') 'remote entries use serverUrl'
Add-Location 'vscode'   (Join-Path $AD 'Code\User\mcp.json') 'target (sync)' @('servers') 'enable state stored outside the file'
Add-Location 'minimax'  (Join-Path $U '.minimax\mcp\mcp.json') 'target (sync)' @('mcpServers') 'remote type = streamable-http'
Get-ChildItem (Join-Path $U 'OpenCodeClonesHome') -Directory | ForEach-Object {
    foreach ($f in @('opencode.jsonc', 'opencode.json')) {
        $p = Join-Path $_.FullName ('config\opencode\' + $f)
        if (Test-Path -LiteralPath $p) { Add-Location ('opencode-' + $_.Name) $p 'target (sync, clones only)' @('mcp') 'command is an ARRAY; Primary excluded (live API keys)' }
    }
}
if (-not (Test-Path (Join-Path $U 'OpenCodeClonesHome'))) { Add-NoteOnly 'opencode' 'OpenCodeClonesHome missing' }
# Antigravity IDE: extension MCP settings (all expected empty) + native config unknown
foreach ($ext in @(@('kilo', 'kilocode.kilo-code\settings\mcp_settings.json'),
                   @('roo', 'rooveterinaryinc.roo-cline\settings\mcp_settings.json'),
                   @('cline-ext', 'saoudrizwan.claude-dev\settings\cline_mcp_settings.json'),
                   @('blackbox', 'blackboxapp.blackboxagent\settings\blackbox_mcp_settings.json'))) {
    Add-Location ('antigravity-' + $ext[0]) (Join-Path $AD ('Antigravity IDE\User\globalStorage\' + $ext[1])) 'not wired (extension store)' @('mcpServers') 'extension-level MCP store'
}
Add-NoteOnly 'antigravity-native' 'logs prove a native supabase MCP (mcpServer.mcp.config.ws0.supabase.log) but its config lives in app-internal state (no plain JSON found) - harvest not possible'
Add-Location 'vscode-kilo-ext' (Join-Path $AD 'Code\User\globalStorage\kilocode.kilo-code\settings\mcp_settings.json') 'not wired (extension store)' @('mcpServers') ''
# Hermes (YAML consumer)
Add-HermesYaml (Join-Path $LAD 'hermes\config.yaml')
# AutoClaw2: its own master file (separate suite machinery)
$ac2 = Join-Path (Split-Path -Parent $PSScriptRoot) 'autoclaw2-mcp.master.json'
if (Test-Path -LiteralPath $ac2) {
    $j = ConvertFrom-JsonLoose ([System.IO.File]::ReadAllText($ac2))
    $count = 0
    if ($null -ne $j -and $null -ne $j.servers) { $count = @($j.servers).Count }
    Add-NoteOnly 'autoclaw2' ("own suite machinery (tools\autoclaw2-mcp.master.json): servers array currently holds $count entr(ies); sync via sync_autoclaw2_mcp.ps1 / GHOST.bat AutoClaw2 [8]")
} else { Add-NoteOnly 'autoclaw2' 'master file missing' }
# Known-absent apps
if (-not (Test-Path (Join-Path $U '.cursor'))) { Add-NoteOnly 'cursor' 'app not installed (.cursor missing) - target auto-skips' }
Add-NoteOnly 'trae' 'no mcp.json found (.trae holds skills only)'
Add-NoteOnly 'qoder' 'no mcp.json found (.qoder holds skills only)'
Add-NoteOnly 'cline-desktop' 'no MCP settings file found in ClineClonesHome data trees (may live in app db)'

# ---------------------------------------------------------------------------
$out = New-Object PSObject
$out | Add-Member -NotePropertyName generated -NotePropertyValue (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
$out | Add-Member -NotePropertyName machine   -NotePropertyValue $env:COMPUTERNAME
$out | Add-Member -NotePropertyName locations -NotePropertyValue $script:Locations
$json = ConvertTo-Json -InputObject $out -Depth 8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($OutPath, $json + [Environment]::NewLine, $utf8NoBom)

# console summary
Write-Host '=== MCP inventory (harvest) ===' -ForegroundColor Magenta
$total = 0
foreach ($l in $script:Locations) {
    $tag = '[' + $l.status + ']'
    Write-Host ("{0} {1} ({2})" -f $tag, $l.app, $l.role) -ForegroundColor $(if ($l.status -eq 'ok') { 'Green' } elseif ($l.status -in @('missing','note')) { 'DarkGray' } else { 'Yellow' })
    if ($l.status -eq 'ok') {
        foreach ($s in $l.servers) {
            $total++
            $state = ''
            if ($null -ne $s.PSObject.Properties['enabled'])  { $state = ' enabled=' + $s.enabled }
            if ($null -ne $s.PSObject.Properties['disabled']) { $state = ' disabled=' + $s.disabled }
            $target = ''
            if ($null -ne $s.PSObject.Properties['url'])       { $target = [string]$s.url }
            elseif ($null -ne $s.PSObject.Properties['serverUrl']) { $target = [string]$s.serverUrl }
            elseif ($null -ne $s.PSObject.Properties['command'])    { $target = [string]$s.command }
            Write-Host ("    {0} [{1}]{2} -> {3}" -f $s.name, $s.kind, $state, $target) -ForegroundColor Gray
        }
    }
    elseif ($l.note) { Write-Host ('    ' + $l.note) -ForegroundColor DarkGray }
}
Write-Host ("=== {0} server definitions collected -> {1} ===" -f $total, $OutPath) -ForegroundColor Magenta
exit 0
