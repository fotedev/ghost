#Requires -Version 5.1
<#
.SYNOPSIS
  Shared helper trio for the three pure merge cores (tools\zcode_mcp_merge.ps1,
  tools\opencode_config_merge.ps1, tools\cline_mcp_merge.ps1) - the ONE copy of
  ConvertTo-DeepHashtable / Test-DeepEqual / Write-JsonNoBom, deduped
  2026-11-28. (CS-1 v1 had deliberately duplicated the trio per tool file with
  the dedup recorded as a follow-up; by then the cline copy had already drifted
  a real bug into Test-DeepEqual's array branch - `$B[$i]` instead of
  `$eb[$i]`, which diverges for non-IList enumerables.)

.DESCRIPTION
  - ConvertTo-DeepHashtable: PSCustomObject/arrays -> plain hashtables so
    deep compares are order-insensitive (key order in JSON files is
    meaningless).
  - Test-DeepEqual: order-insensitive for objects/maps, order-significant
    for arrays.
  - Write-JsonNoBom: the ATOMIC writer (the CS-7 hardening shape, 2026-11-22):
    temp file + [System.IO.File]::Replace (+ Move fallback when the
    destination does not exist yet, temp cleanup on failure). A live-watching
    service (the OpenCode desktop config directory watcher) must never be
    handed a torn file. PS 5.1's utf8 encoding emits a BOM; the app's JSON
    readers choke on it - the output is no-BOM UTF-8 everywhere.

  The consumers dot-source THIS file (transitively through their tool file),
  so tests that dot-source a tool file and assert Get-Command on the trio
  keep passing unchanged. The merge VERBS stay per-tool (siblings with
  different toggle shapes, not duplicates).
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
    # The write is ATOMIC (temp file + File.Replace, Move fallback when the
    # destination does not exist yet) - a live-watching service must never be
    # handed a torn file. Same no-BOM output as the old simple writers.
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, $Object)
    $json = $Object | ConvertTo-Json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    if ($PSCmdlet.ShouldProcess($Path, 'Write JSON (no BOM, atomic replace)')) {
        $tmp = "$Path.ghost-tmp"
        [System.IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, $utf8NoBom)
        try {
            if (Test-Path -LiteralPath $Path) {
                # [NullString]::Value, NOT $null: PS 5.1 marshals a bare $null
                # into an empty string for .NET string parameters and
                # File.Replace rejects "" as "not of a legal form".
                [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
            } else {
                [System.IO.File]::Move($tmp, $Path)
            }
        } catch {
            # Never leave the temp file behind on a failed swap.
            try { [System.IO.File]::Delete($tmp) } catch { }
            throw
        }
    }
}
