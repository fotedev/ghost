#Requires -Version 5.1
<#
.SYNOPSIS
  Pure merge core for Cline MCP definition syncing - no audit, no exit codes,
  no process state. Shared by tools\sync_cline_mcp.ps1 (which owns the
  backup / write / verify / audit orchestration) and unit-tested by
  tests\cline_mcp_merge.Tests.ps1.

.DESCRIPTION
  Store: <profile>\data\settings\cline_mcp_settings.json, container
  "mcpServers" (Claude-Desktop format). Verified on the dev host 2026-11-17:
  the Primary's file exists as exactly {"mcpServers": {}} (23 bytes) - the
  container is auth-free, which is why the sync may CREATE it for a clone
  that lacks it (the OpenCode sync skips a config-less clone; the Cline MCP
  store is NOT the login state - secrets.json + providers.json are).

  Merge invariant (the zcode_mcp_merge invariant adapted to Cline's flag
  shape - Cline uses per-server "disabled": true|false, not "enabled"):
    - the full definition (command/args/env/type/url/headers/timeout/
      autoApprove/...) of every server defined in the Primary is copied onto
      the clone, EXCEPT the per-server 'disabled' toggle:
        * a server the clone already has keeps its LOCAL disabled state,
        * a server new to the clone carries the Primary's disabled value
          (absent on both sides = enabled, the app default),
    - clone-only servers are never removed (the loop only iterates the
      Primary's set),
    - the Primary side is never mutated.

  Invoke-ClineMcpMerge mutates the CLONE servers PSCustomObject in place and
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
            if (-not (Test-DeepEqual $ea[$i] $B[$i])) { return $false }
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

function Invoke-ClineMcpMerge {
    <#
    .SYNOPSIS
      Merge the Primary's mcpServers definitions onto a clone's mcpServers map.
    .PARAMETER PrimaryServers
      The Primary's `mcpServers` PSCustomObject (never mutated).
    .PARAMETER CloneServers
      The clone's `mcpServers` PSCustomObject (mutated in place).
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
        # Deep copy of the Primary definition, 'disabled' stripped first.
        $newDef = $prop.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        $primaryDisabled = $null
        $hadDisabled = $false
        if ($newDef.PSObject.Properties['disabled']) {
            $primaryDisabled = $newDef.disabled
            $hadDisabled = $true
            $newDef.PSObject.Properties.Remove('disabled')
        }

        $cProp = $CloneServers.PSObject.Properties[$sName]
        if ($null -ne $cProp) {
            # Existing server: keep the clone's LOCAL disabled toggle.
            if ($cProp.Value.PSObject.Properties['disabled']) {
                $localDisabled = $cProp.Value.disabled
                if ($newDef.PSObject.Properties['disabled']) { $newDef.disabled = $localDisabled }
                else { $newDef | Add-Member -NotePropertyName disabled -NotePropertyValue $localDisabled }
            }
        } else {
            # New server: carry the Primary's disabled value (if it had one).
            if ($hadDisabled) { $newDef | Add-Member -NotePropertyName disabled -NotePropertyValue $primaryDisabled }
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
