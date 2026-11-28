#Requires -Version 5.1
<#
.SYNOPSIS
  Shared OpenCode per-clone service-port seeding (CS-11) - the ONE frozen
  port map + the seed/merge helper used by BOTH OpenCode launchers
  (src\windows\launch_opencode_clone.ps1 step [2d/5] and the light worker's
  default run path in src\windows\launch_opencode_cli_light.ps1).

.DESCRIPTION
  OpenCode v2.4.2 computes the background-service port default from the app
  version (a win32 remap yields 28894 for 2.4.2) and the service REFUSES to
  start on collision ("Managed service port 28894 on 127.0.0.1 is already in
  use by another process"). Two instances can therefore only coexist when
  each has its own port. The port is per-clone-reachable: the spawned
  `opencode-cli.exe serve --service` child reads `join(<configHome>,
  "opencode", "service.json")` - keys `{password, port}` - and the launchers
  already XDG-preempt <configHome> to the clone (the desktop app itself never
  touches this file; the password is pre-shared once present and generated +
  persisted by the CLI when absent, so the seed never fabricates auth).

  Initialize-GhostOpenCodeServicePort:
    - a VALID existing port (integer 1..65535) = Status 'skipped' (the file
      wins; a hand-tuned port is never overwritten),
    - otherwise MERGE: preserve every existing key (notably `password`), set
      `port` from the frozen map, write atomically via the shared
      tools\json_merge_lib.ps1 Write-JsonNoBom (never a bare Set-Content:
      PS 5.1 UTF8 emits a BOM the CLI reader may choke on), verify-after by
      re-read. Failures are loud but non-fatal (Status 'failed') - the
      launchers print the outcome and continue (the house best-effort
      contract); a failed seed reproduces the CS-10-acceptance collision on
      the next service spawn, which the log names explicitly.

  The frozen map only needs MUTUAL DISTINCTNESS (the Primary keeps its
  version-default port). House rule: any OpenCode process enumeration that
  accompanies this feature must match the whole per-color copy family
  (OpenCode-*.exe), not bare OpenCode.exe.
#>

# The frozen per-clone service-port map (CS-11, 2026-11-28). MUST stay in
# sync with $InstanceDefs in launch_opencode_clone.ps1 (c1..c5) and with the
# spec port table in docs/OPENCODE_CLONES_SPEC.md 3.8.1 - a Pester pin
# asserts the mutual distinctness and the c1 baseline.
$script:GhostOpenCodeServicePorts = @{
    c1 = 28901
    c2 = 28902
    c3 = 28903
    c4 = 28904
    c5 = 28905
}

# The shared JSON deep-compare/write helpers (atomic Write-JsonNoBom) live in
# tools\json_merge_lib.ps1 - TWO levels up from src\windows (the repo's
# src\windows climb).
. (Join-Path $PSScriptRoot "..\..\tools\json_merge_lib.ps1")

function Initialize-GhostOpenCodeServicePort {
    <#
    .SYNOPSIS
      Seed the clone's per-clone service port into
      <CloneHome>\config\opencode\service.json (CS-11). Best-effort: returns
      a result object, never throws for ordinary conditions.
    .OUTPUTS
      pscustomobject { Status = 'skipped'|'seeded'|'failed'; Port = int;
                       Path = string; Note = string }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CloneHome,
        [Parameter(Mandatory = $true)][ValidateSet('c1', 'c2', 'c3', 'c4', 'c5')][string]$Instance
    )
    $result = [pscustomobject]@{ Status = 'failed'; Port = $null; Path = $null; Note = '' }
    $port = $script:GhostOpenCodeServicePorts[$Instance]
    if (-not $port) {
        $result.Note = "no frozen port for instance '$Instance'"
        return $result
    }
    $result.Port = $port
    $svcDir = Join-Path $CloneHome "config\opencode"
    $svcPath = Join-Path $svcDir "service.json"
    $result.Path = $svcPath

    $existing = $null
    if (Test-Path -LiteralPath $svcPath) {
        try {
            $existing = ConvertTo-DeepHashtable (Get-Content -LiteralPath $svcPath -Raw | ConvertFrom-Json)
        } catch {
            $result.Note = "existing service.json is not valid JSON - refusing to overwrite it blindly"
            return $result
        }
        if ($existing -is [System.Collections.IDictionary] -and $existing.ContainsKey('port')) {
            $cur = $existing['port']
            # Type-agnostic numeric check: PS 5.1's ConvertFrom-Json yields
            # Int32, PS 7 yields Int64, and a hand-edited file may carry a
            # numeric STRING - parse instead of -is checks (the CI pwsh lane
            # caught the Int32-only shape live: the skip path fell through to
            # a re-seed).
            $curNum = $null
            try { $curNum = [int]::Parse("$cur", [System.Globalization.CultureInfo]::InvariantCulture) } catch { $curNum = $null }
            if ($null -ne $curNum -and $curNum -ge 1 -and $curNum -le 65535) {
                $result.Status = 'skipped'
                $result.Port = $curNum
                $result.Note = "already carries a valid port $curNum"
                return $result
            }
            $result.Note = "existing port value '$cur' is not a valid port - replacing it with the frozen map port"
        }
    }

    if (-not (Test-Path -LiteralPath $svcDir)) {
        try { New-Item -ItemType Directory -Path $svcDir -Force | Out-Null } catch {
            $result.Note = "could not create $svcDir"
            return $result
        }
    }

    # Merge: preserve every existing key (notably the pre-shared password),
    # set the frozen port. A hashtable copy avoids mutating the parsed input.
    $doc = @{}
    if ($existing -is [System.Collections.IDictionary]) {
        foreach ($k in $existing.Keys) { $doc[$k] = $existing[$k] }
    }
    $doc['port'] = $port
    try {
        Write-JsonNoBom -Path $svcPath -Object ([pscustomobject]$doc)
    } catch {
        $result.Note = "atomic write failed: $($_.Exception.Message)"
        return $result
    }

    # verify-after: re-read and deep-compare the written document
    try {
        $back = ConvertTo-DeepHashtable (Get-Content -LiteralPath $svcPath -Raw | ConvertFrom-Json)
        if (-not (Test-DeepEqual $back ([hashtable]$doc.Clone()))) {
            $result.Note = "verify-after FAILED: the written file does not round-trip"
            return $result
        }
    } catch {
        $result.Note = "verify-after FAILED: the written file does not parse"
        return $result
    }

    $result.Status = 'seeded'
    $result.Note = "seeded port $port (frozen CS-11 map)"
    return $result
}
