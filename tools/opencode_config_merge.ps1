#Requires -Version 5.1
<#
.SYNOPSIS
  Pure merge core for the OpenCode definitions-only Primary -> clone config
  sync (CS-1) - no audit, no exit codes, no process state. Consumed by
  tools\sync_opencode_config.ps1 (which owns the backup / write / verify /
  audit orchestration and the launcher pre-launch call) and unit-tested by
  tests\opencode_config_merge.Tests.ps1.

.DESCRIPTION
  Merge invariant (docs\OPENCODE_CONFIG_SYNC_PLAN.md section 2; the zcode
  precedent in tools\zcode_mcp_merge.ps1):
    - every entry defined in the PRIMARY's `mcp` and `provider` blocks is
      copied onto the clone (Primary definitions win),
    - EXCEPT per-entry 'enabled' toggles: an entry the clone already has
      keeps its LOCAL on/off state; an entry new to the clone carries the
      Primary's enabled value,
    - clone-only entries are never removed (the loop only iterates the
      Primary's set),
    - SECRET-SCRUB (decision D2 = the plan's default): inside `provider`
      blocks, keys named apiKey / api_key / apikey (case-insensitive) coming
      from the PRIMARY are REMOVED - a provider is synced WITHOUT its secret
      plus a scrub note the caller turns into the loud
      "fill the API key once in this clone" WARN. A SECRET THE CLONE ALREADY
      HAS survives (clone-local state, same rule as the enabled toggles).
      No placeholder string is ever written. MCP definitions copy their env
      wholesale (the ZCode-sync precedent: the registry keeps secrets as
      ${VAR} env-name references there).
    - the Primary side is never mutated (the caller passes a deep copy).

  Invoke-OcConfigMerge mutates the CLONE config PSCustomObject in place and
  returns @{ Changed = string[]; Scrubbed = string[] } so the caller can
  decide whether anything needs writing (both empty = already in sync).

  ConvertFrom-JsoncText mirrors the minimal JSONC reader in
  tools\sync_mcp_registry.ps1 (strip /* */ and // comments, not "x://y"
  URLs). The helper trio (ConvertTo-DeepHashtable / Test-DeepEqual /
  Write-JsonNoBom - the ATOMIC writer shape) lives in the shared
  tools\json_merge_lib.ps1 since 2026-11-28 (deduped from the
  formerly-inline copies; this file dot-sources it, so dot-sourcing THIS
  file still defines all three).
#>

# Shared deep-compare/write helpers - the single copy lives in the lib.
. (Join-Path $PSScriptRoot "json_merge_lib.ps1")

function ConvertFrom-JsoncText {
    # Minimal JSONC -> JSON: strip /* */ blocks and // line comments (not
    # "x://y" URLs). Parse failure afterwards surfaces as FAILED by the
    # caller (no partial writes).
    param([string]$Text)
    $noBlock = [regex]::Replace($Text, '/\*.*?\*/', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $noLine  = [regex]::Replace($noBlock, '(?m)(?<!:)//[^\r\n]*', '')
    return ($noLine | ConvertFrom-Json)
}

function Test-SecretKeyName {
    # The scrub predicate (plan section 2 hard rule): any provider key whose
    # NAME is apiKey-shaped carries the Primary's credential - never synced.
    param([string]$Name)
    return ($Name -match '^(?i)api[-_]?key$')
}

function Remove-SecretKeysDeep {
    # Deep-scrub: drop apiKey-shaped keys at ANY depth (the real OpenCode
    # shape is provider.<id>.options.apiKey - a top-level-only scan would
    # miss it and the secret would cross). Returns $true when anything was
    # dropped. Mutates PSCustomObject nodes in place (in-memory only - no
    # system state, hence the ShouldProcess suppression).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Node)
    $dropped = $false
    foreach ($p in @($Node.PSObject.Properties)) {
        if (Test-SecretKeyName -Name $p.Name) {
            $Node.PSObject.Properties.Remove($p.Name)
            $dropped = $true
            continue
        }
        if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
            if (Remove-SecretKeysDeep -Node $p.Value) { $dropped = $true }
        }
    }
    return $dropped
}

function Copy-SecretValuesDeep {
    # Re-attach the secret-keyed values found anywhere in $From onto the same
    # paths in $To - the CLONE's own credentials survive the definition
    # overwrite (same survival rule as the enabled toggles).
    param($From, $To)
    foreach ($p in @($From.PSObject.Properties)) {
        if (Test-SecretKeyName -Name $p.Name) {
            if ($To.PSObject.Properties[$p.Name]) { $To.($p.Name) = $p.Value }
            else { $To | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
            continue
        }
        if ($p.Value -is [System.Management.Automation.PSCustomObject] -and
            $To.PSObject.Properties[$p.Name] -and
            $To.($p.Name) -is [System.Management.Automation.PSCustomObject]) {
            Copy-SecretValuesDeep -From $p.Value -To $To.($p.Name)
        }
    }
}

function Invoke-OcConfigMerge {
    <#
    .SYNOPSIS
      Merge the Primary's mcp + provider definitions onto a clone config.
    .PARAMETER PrimaryConfig
      The Primary's parsed config PSCustomObject (never mutated).
    .PARAMETER CloneConfig
      The clone's parsed config PSCustomObject (mutated in place).
    .OUTPUTS
      hashtable @{ Changed = string[]; Scrubbed = string[] } - the entry
      names whose definition changed on the clone, and the provider names
      whose PRIMARY secret keys were dropped (empty = nothing to report /
      already in sync). The mutated CloneConfig object is the caller's
      handle; write it or not based on the Changed list.
    #>
    param(
        [Parameter(Mandatory = $true)] $PrimaryConfig,
        [Parameter(Mandatory = $true)] $CloneConfig
    )
    $changed = @()
    $scrubbed = @()

    # The REAL app shape (live-verified 2026-11-22, Primary + clone homes):
    # servers nest under `mcp.servers` (the v1-era flat `mcp.<name>` shape
    # never shipped), and the Primary can also carry DIRECT mcp entries
    # alongside the nested block (observed: `mcp.codeagentswarm-tasks` +
    # `mcp.servers.{...}`). Walking flat `mcp` alone treated the WHOLE
    # `servers` block as one entry and let the Primary's copy silently drop
    # clone-only servers inside it - the CS-7-wave bug this container list
    # fixes. 'servers' is excluded from the flat walk because the nested
    # walk owns it.
    $containers = @(
        @{ Path = @('mcp', 'servers'); Label = 'mcp.servers'; Exclude = @() },
        @{ Path = @('provider');       Label = 'provider';      Exclude = @() },
        @{ Path = @('mcp');            Label = 'mcp';           Exclude = @('servers') }
    )

    foreach ($container in $containers) {
        # Resolve the dotted container on BOTH sides (missing intermediate
        # objects = the container is absent for that side).
        $pSec = $PrimaryConfig
        foreach ($seg in $container.Path) {
            if ($null -eq $pSec) { break }
            $pp = $pSec.PSObject.Properties[$seg]
            $pSec = if ($pp) { $pp.Value } else { $null }
        }
        if ($null -eq $pSec) { continue }

        # Ensure the clone has the container (auto-create intermediates).
        $cSec = $CloneConfig
        foreach ($seg in $container.Path) {
            $cp = $cSec.PSObject.Properties[$seg]
            if ($null -eq $cp) {
                $cSec | Add-Member -NotePropertyName $seg -NotePropertyValue (New-Object PSObject)
                $cp = $cSec.PSObject.Properties[$seg]
            }
            $cSec = $cp.Value
        }
        $section = $container.Label

        foreach ($prop in @($pSec.PSObject.Properties)) {
            $eName = $prop.Name
            if ($container.Exclude -contains $eName) { continue }
            # Deep copy of the Primary definition.
            $newDef = $prop.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json

            # Per-entry 'enabled' toggle: Primary's stripped first.
            $primaryEnabled = $null
            $hadEnabled = $false
            if ($newDef.PSObject.Properties['enabled']) {
                $primaryEnabled = $newDef.enabled
                $hadEnabled = $true
                $newDef.PSObject.Properties.Remove('enabled')
            }

            # Secret keys coming from the PRIMARY: scrub BEFORE the clone's
            # own values are considered (D2) - deep, because the real shape
            # is provider.<id>.options.apiKey.
            $droppedSecrets = Remove-SecretKeysDeep -Node $newDef

            $cProp = $cSec.PSObject.Properties[$eName]
            if ($null -ne $cProp) {
                # Existing entry: keep the clone's LOCAL on/off toggle...
                if ($cProp.Value.PSObject.Properties['enabled']) {
                    $localEnabled = $cProp.Value.enabled
                    if ($newDef.PSObject.Properties['enabled']) { $newDef.enabled = $localEnabled }
                    else { $newDef | Add-Member -NotePropertyName enabled -NotePropertyValue $localEnabled }
                }
                # ...and its LOCAL secrets (the clone may already be filled in).
                Copy-SecretValuesDeep -From $cProp.Value -To $newDef
            } else {
                # New entry: carry the Primary's enabled value (if it had one).
                if ($hadEnabled) { $newDef | Add-Member -NotePropertyName enabled -NotePropertyValue $primaryEnabled }
            }

            $currentHash = $null
            if ($null -ne $cProp) { $currentHash = ConvertTo-DeepHashtable $cProp.Value }
            if (-not (Test-DeepEqual $currentHash (ConvertTo-DeepHashtable $newDef))) {
                if ($null -ne $cProp) { $cProp.Value = $newDef }
                else { $cSec | Add-Member -NotePropertyName $eName -NotePropertyValue $newDef }
                $changed += ("$section.$eName")
            }
            if ($droppedSecrets) { $scrubbed += ("$section.$eName") }
        }
    }

    return @{ Changed = @($changed); Scrubbed = @($scrubbed) }
}
