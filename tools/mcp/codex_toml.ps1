#Requires -Version 5.1
<#
.SYNOPSIS
  Pure TOML reader/writer for Codex CLI config.toml [mcp_servers.*] tables -
  no audit, no exit codes, no process state. Consumed by
  tools\sync_mcp_registry.ps1 (the 'codex' target) and unit-tested by
  tests\mcp_registry_sync.Tests.ps1.

.DESCRIPTION
  Line-based surgical parser (stdlib only, PS 5.1):
    - ConvertFrom-CodexTomlText: config.toml text -> synthetic JSON-shaped view
      (root.mcp_servers.<name> = entry PSCustomObject) so the registry merge
      pipeline can treat it like any other container. ONLY [mcp_servers.*]
      tables are represented; every other table, comment and blank line is
      ignored here and preserved verbatim by the writer.
    - Write-CodexTomlFile: strips every existing [mcp_servers.*] block from the
      original text and appends the merged sections; the original line ending
      is detected and preserved.
  Light value grammar: basic/literal strings, integers, booleans, flat string
  arrays. The only nested table handled is [mcp_servers.<n>.env].
  Never reads secret VALUES into anything but the merge pipeline's memory.

  PS 5.1 rules honored: no ternary, empty arrays returned via `return ,$out`
  (a bare `return @()` unwinds to $null).
#>

function ConvertFrom-TomlValue([string]$raw) {
    $t = $raw.Trim()
    if ($t -match '^"(.*)"$') { return (($Matches[1] -replace '\\\\', '\') -replace '\\"', '"') }
    if ($t -match "^'(.*)'$") { return $Matches[1] }
    if ($t -eq 'true')  { return $true }
    if ($t -eq 'false') { return $false }
    if ($t -match '^-?\d+$') { return ([long]$t) }
    if ($t -match '^\[(.*)\]$') {
        $out = @()
        foreach ($part in ($Matches[1] -split ',')) {
            $p = $part.Trim()
            if ($p -ne '') { $out += ,(ConvertFrom-TomlValue $p) }
        }
        return ,$out
    }
    return $t
}

function ConvertFrom-CodexTomlText([string]$text) {
    $root = New-Object PSObject
    $servers = New-Object PSObject
    $root | Add-Member -NotePropertyName 'mcp_servers' -NotePropertyValue $servers
    $cur = $null
    $envTarget = $null
    foreach ($line in ($text -split "\r?\n")) {
        if ($line -match '^\s*\[mcp_servers\.([^.\]]+)\]\s*(#.*)?$') {
            $cur = New-Object PSObject
            $servers | Add-Member -NotePropertyName $Matches[1] -NotePropertyValue $cur
            $envTarget = $null
        }
        elseif ($line -match '^\s*\[mcp_servers\.([^.\]]+)\.env\]\s*(#.*)?$') {
            # TOML defines intermediate tables implicitly: an [mcp_servers.b.env]
            # header without a prior [mcp_servers.b] still creates b.
            $name = $Matches[1]
            $pp = $servers.PSObject.Properties[$name]
            if ($null -eq $pp) {
                $cur = New-Object PSObject
                $servers | Add-Member -NotePropertyName $name -NotePropertyValue $cur
            }
            else { $cur = $pp.Value }
            $envTarget = New-Object PSObject
            $cur | Add-Member -NotePropertyName 'env' -NotePropertyValue $envTarget -Force
        }
        elseif ($line -match '^\s*\[') { $cur = $null; $envTarget = $null }
        elseif ($null -ne $cur -and $line -match '^\s*([A-Za-z0-9_\-]+)\s*=\s*(.+?)\s*(#.*)?$') {
            $val = ConvertFrom-TomlValue $Matches[2]
            $dest = $cur
            if ($null -ne $envTarget) { $dest = $envTarget }
            $dest | Add-Member -NotePropertyName $Matches[1] -NotePropertyValue $val -Force
        }
    }
    return $root
}

function ConvertTo-TomlLiteral([string]$v) {
    # Literal string first (keeps Windows backslashes intact), basic-string fallback.
    if ($v -notmatch "['\r\n]") { return "'" + $v + "'" }
    return '"' + (($v -replace '\\', '\\\\') -replace '"', '\"') + '"'
}

function ConvertTo-TomlValue($v) {
    if ($null -eq $v) { return "''" }
    if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
    if ($v -is [int] -or $v -is [long] -or $v -is [double]) { return ([string]$v) }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) {
        $parts = @()
        foreach ($e in @($v)) { $parts += (ConvertTo-TomlLiteral ([string]$e)) }
        return '[' + ($parts -join ', ') + ']'
    }
    return (ConvertTo-TomlLiteral ([string]$v))
}

function ConvertTo-CodexTomlSection([string]$name, $entry) {
    # Server names must be TOML bare keys; anything else is refused loudly.
    if ($name -notmatch '^[A-Za-z0-9_-]+$') { throw "codex target: server name '$name' is not a TOML bare key" }
    $lines = @()
    $lines += ('[mcp_servers.' + $name + ']')
    foreach ($p in @($entry.PSObject.Properties)) {
        if ($p.Name -eq 'env') { continue }
        $lines += ($p.Name + ' = ' + (ConvertTo-TomlValue $p.Value))
    }
    $envP = $entry.PSObject.Properties['env']
    if ($null -ne $envP -and $null -ne $envP.Value -and @($envP.Value.PSObject.Properties).Count -gt 0) {
        $lines += ''
        $lines += ('[mcp_servers.' + $name + '.env]')
        foreach ($p in @($envP.Value.PSObject.Properties)) {
            $lines += ($p.Name + ' = ' + (ConvertTo-TomlValue $p.Value))
        }
    }
    return ,$lines
}

function Write-CodexTomlFile([string]$path, $workRoot, [string]$originalText) {
    $nl = "`r`n"
    if ($originalText -notmatch "`r`n") { $nl = "`n" }
    $keep = New-Object System.Collections.Generic.List[string]
    $inMcp = $false
    foreach ($line in ($originalText -split "\r?\n")) {
        if ($line -match '^\s*\[mcp_servers\.') { $inMcp = $true; continue }
        elseif ($line -match '^\s*\[')          { $inMcp = $false }
        if (-not $inMcp) { [void]$keep.Add($line) }
    }
    while ($keep.Count -gt 0 -and $keep[$keep.Count - 1] -match '^\s*$') { $keep.RemoveAt($keep.Count - 1) }
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange($keep)
    $servers = $workRoot.PSObject.Properties['mcp_servers'].Value
    $first = $true
    foreach ($p in @($servers.PSObject.Properties)) {
        if (-not $first) { [void]$out.Add('') }
        $first = $false
        foreach ($l in (ConvertTo-CodexTomlSection $p.Name $p.Value)) { [void]$out.Add($l) }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, ([string]::Join($nl, $out)) + $nl, $utf8NoBom)
}
