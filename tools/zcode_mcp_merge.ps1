#Requires -Version 5.1
<#
.SYNOPSIS
  Pure merge core for ZCode MCP definition syncing - no audit, no exit codes,
  no process state. Shared by tools\sync_zcode_assets.ps1 (which owns the
  backup / write / verify / audit orchestration) and unit-tested by
  tests\zcode_mcp_merge.Tests.ps1.

.DESCRIPTION
  Merge invariant (live-proven 2026-10-17, unchanged since):
    - the full definition (command/args/env/type/timeoutMs/url/headers/...)
      of every server defined in the Primary is copied onto the clone,
      EXCEPT the per-server 'enabled' toggle:
        * a server the clone already has keeps its LOCAL on/off state,
        * a server new to the clone carries the Primary's enabled value,
    - clone-only servers are never removed (the loop only iterates the
      Primary's set),
    - the Primary side is never mutated.

  Invoke-McpMerge mutates the CLONE servers PSCustomObject in place and
  returns the list of changed server names so the caller can decide whether
  anything needs writing (empty list = already in sync).

  A Primary with zero servers is a legitimate state for the CALLER to handle
  (this module only sees the two servers maps).
#>

function ConvertTo-DeepHashtable {
    # PSCustomObject/arrays -> plain hashtables so deep compares are
    # order-insensitive (key order in JSON files is meaningless).
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $Obj.Keys) { $h[$k] = ConvertTo-DeepHashtable $Obj[$k] }
        return ,$h
    }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-DeepHashtable $p.Value }
        return ,$h
    }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        $list = @()
        foreach ($i in $Obj) { $list += ,(ConvertTo-DeepHashtable $i) }
        return ,$list
    }
    return $Obj
}

function Test-DeepEqual {
    # Order-insensitive for objects/maps, order-significant for arrays.
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return (($null -eq $A) -and ($null -eq $B)) }
    if ($A -is [System.Collections.IDictionary] -and $B -is [System.Collections.IDictionary]) {
        if ($A.Count -ne $B.Count) { return $false }
        foreach ($k in $A.Keys) {
            if (-not $B.ContainsKey($k)) { return $false }
            if (-not (Test-DeepEqual $A[$k] $B[$k])) { return $false }
        }
        return $true
    }
    if ($A -is [System.Collections.IEnumerable] -and $A -isnot [string] -and
        $B -is [System.Collections.IEnumerable] -and $B -isnot [string]) {
        $ea = @($A); $eb = @($B)
        if ($ea.Count -ne $eb.Count) { return $false }
        for ($i = 0; $i -lt $ea.Count; $i++) {
            if (-not (Test-DeepEqual $ea[$i] $eb[$i])) { return $false }
        }
        return $true
    }
    return ([string]$A -eq [string]$B)
}

function Write-JsonNoBom {
    # PS 5.1's utf8 encoding emits a BOM; the app's JSON readers choke on it.
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Invoke-McpMerge {
    <#
    .SYNOPSIS
      Merge the Primary's mcp.servers definitions onto a clone's servers map.
    .PARAMETER PrimaryServers
      The Primary's `mcp.servers` PSCustomObject (never mutated).
    .PARAMETER CloneServers
      The clone's `mcp.servers` PSCustomObject (mutated in place).
    .OUTPUTS
      string[] - names of servers whose definition changed on the clone
      (empty = already in sync). The mutated CloneServers object is the
      caller's handle; write it or not based on the returned list.
    #>
    param(
        [Parameter(Mandatory = $true)] $PrimaryServers,
        [Parameter(Mandatory = $true)] $CloneServers
    )
    $changed = @()
    foreach ($prop in @($PrimaryServers.PSObject.Properties)) {
        $sName = $prop.Name
        # Deep copy of the Primary definition, 'enabled' stripped first.
        $newDef = $prop.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $primaryEnabled = $null
        $hadEnabled = $false
        if ($newDef.PSObject.Properties['enabled']) {
            $primaryEnabled = $newDef.enabled
            $hadEnabled = $true
            $newDef.PSObject.Properties.Remove('enabled')
        }

        $cProp = $CloneServers.PSObject.Properties[$sName]
        if ($null -ne $cProp) {
            # Existing server: keep the clone's LOCAL on/off toggle.
            if ($cProp.Value.PSObject.Properties['enabled']) {
                $localEnabled = $cProp.Value.enabled
                if ($newDef.PSObject.Properties['enabled']) { $newDef.enabled = $localEnabled }
                else { $newDef | Add-Member -NotePropertyName enabled -NotePropertyValue $localEnabled }
            }
        } else {
            # New server: carry the Primary's enabled value (if it had one).
            if ($hadEnabled) { $newDef | Add-Member -NotePropertyName enabled -NotePropertyValue $primaryEnabled }
        }

        $currentHash = $null
        if ($null -ne $cProp) { $currentHash = ConvertTo-DeepHashtable $cProp.Value }
        if (-not (Test-DeepEqual $currentHash (ConvertTo-DeepHashtable $newDef))) {
            if ($null -ne $cProp) { $cProp.Value = $newDef }
            else { $CloneServers | Add-Member -NotePropertyName $sName -NotePropertyValue $newDef }
            $changed += $sName
        }
    }
    return ,$changed
}
