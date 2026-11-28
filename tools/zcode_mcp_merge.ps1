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

  The helper trio (ConvertTo-DeepHashtable / Test-DeepEqual / Write-JsonNoBom)
  lives in the shared tools\json_merge_lib.ps1 since 2026-11-28 (deduped from
  the formerly-inline copies; this file dot-sources it, so dot-sourcing THIS
  file still defines all three).
#>

# Shared deep-compare/write helpers - the single copy lives in the lib.
. (Join-Path $PSScriptRoot "json_merge_lib.ps1")

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
