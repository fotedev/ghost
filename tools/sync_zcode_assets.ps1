#Requires -Version 5.1
<#
.SYNOPSIS
  Sync user-scope assets (MCP server definitions, skills, plugin cache) from
  the Primary ZCode profile into the clone homes (Second/Third/Fourth/Fifth/Sixth).

.DESCRIPTION
  Every clone resolves its OWN user-scope config at <CloneHome>\.zcode\cli\config.json:
  the HOME/ZCODE_* env overrides reach the app's config resolution, unlike the
  shared CLI session store at %USERPROFILE%\.zcode\cli\db\db.sqlite (verified
  2026-10-17). The launcher's one-time seed copies the Primary profile exactly
  once, so every MCP/plugin/skill change made after that day lives only in the
  Primary and the clones drift (as of 2026-10-17: every clone still ran the
  broken npx supabase entry and lacked sentry; their plugin caches missed newer
  plugin versions; their skills were stale copies).

  What gets synced (the Primary is only ever READ):

  1. MCP server definitions (mcp.servers in <CloneHome>\.zcode\cli\config.json).
     The full definition (command/args/env/type/timeoutMs/url/headers/...) is
     copied from the Primary EXCEPT the per-server 'enabled' toggle:
       - a server the clone already has keeps its LOCAL on/off state,
       - a server new to the clone carries the Primary's enabled value,
       - clone-only servers are never removed,
       - 'plugins' and 'hooks' stay fully local.
  2. Skills. The stale copy dir <CloneHome>\.zcode\skills is moved aside
     (skills.pre-sync-<ts>) so it stops shadowing discovery (skills discovery
     reads .zcode\skills BEFORE .agents\skills), and <CloneHome>\.agents is
     junctioned to %USERPROFILE%\.agents (junctions need no elevation). All
     instances then share one live skill set - the Primary's own profile
     already works this way (.zcode\skills holds links into .agents\skills).
  3. Plugin cache. robocopy /MIR of cli\plugins\cache + cli\plugins\marketplaces
     + known_marketplaces.json, only when the <marketplace>\<plugin>\<version>
     set or the marketplaces file drifts. plugins\data and cli\agents stay
     per-instance (runtime state, like the session store).

  Guards:
    - a RUNNING instance (process markers = its home/roaming dir names, same
      rule as the launcher/watcher) is SKIPPED with a warning: skills/plugin
      mirroring (junction swaps, robocopy /MIR) must not race a live app -
      close the instance and re-run, or use -McpOnly. MCP-only sync does NOT
      need that skip: verified 2026-10-27 (app.asar code + all six instances'
      logs) the app holds no handle on config.json, NEVER rewrites it on
      exit (its own writes are event-driven, atomic tmp+rename), and reads
      mcp.servers at every app-server spawn (one per new session) - a synced
      definition lands on the instance's next chat without a restart.
      Without -McpOnly the default (all areas) keeps the old skip.
    - an unseeded clone home (no .zcode) is SKIPPED with a note: the launcher
      seeds it on first launch from the current Primary, after which this
      script verifies,
    - if the WMI process scan fails the guard is blind - a loud warning says
      so (never the case for -McpOnly, which skips the scan entirely).

  Never silent-success: every write is followed by a re-read + deep compare;
  any mismatch => FAILED + backup restored + audit record + exit 1.

  Audit: JSONL appended to <CloneHome>\.zcode\asset-sync-audit.jsonl
  Log:   tools\logs\sync_zcode_assets.log

  Invoke as a child process only (uses exit codes; do NOT dot-source):
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_zcode_assets.ps1
        [-Target Second|Third|Fourth|Fifth|Sixth|All] [-DryRun] [-McpOnly]

  -McpOnly syncs ONLY the MCP definitions and is safe against RUNNING
  instances (see Guards). It is also invoked on every Primary config change
  by tools\watch_zcode_mcp_sync.ps1.

  GHOST.bat ZCode submenu [17] (all areas, stopped instances) and [18]
  (MCP-only, live); also invoked per-launch by
  src\windows\launch_zcode_second_instance.ps1 (step 2d, pre-launch).
#>

[CmdletBinding()]
param(
    [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
    [string]$Target = 'All',
    [switch]$DryRun,
    # MCP-definitions-only sync: skips skills/plugins AND the running-instance
    # skip (safe per the 2026-10-27 verification - see the Guards header).
    [switch]$McpOnly
)

$ErrorActionPreference = 'Stop'

# Shared merge core (pure functions; the only copy of the merge logic lives
# there - ConvertTo-DeepHashtable / Test-DeepEqual / Write-JsonNoBom /
# Invoke-McpMerge - unit-tested by tests\zcode_mcp_merge.Tests.ps1).
. (Join-Path $PSScriptRoot 'zcode_mcp_merge.ps1')

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }

$PrimaryZCode  = Join-Path $UserProfile '.zcode'
$PrimaryCli    = Join-Path $PrimaryZCode 'cli'
$PrimaryConfig = Join-Path $PrimaryCli 'config.json'
$PrimaryAgents = Join-Path $UserProfile '.agents'

$LogDir  = Join-Path $PSScriptRoot 'logs'
$LogFile = Join-Path $LogDir 'sync_zcode_assets.log'

# Per-clone layout - mirrors launch_zcode_second_instance.ps1 ($InstanceMap)
# and refresh_zcode_second_chats.ps1 ($InstanceDefs): classification is by
# process markers (home/roaming dir names in the command line), never titles.
$InstanceDefs = @(
    @{ Name = 'Second'; HomeRel = 'ZCodeSecondHome'; Markers = @('ZCode-Second',  'ZCodeSecondHome') }
    @{ Name = 'Third';  HomeRel = 'ZCodeThirdHome';  Markers = @('ZCode-Third',   'ZCodeThirdHome')  }
    @{ Name = 'Fourth'; HomeRel = 'ZCodeFourthHome'; Markers = @('ZCode-Fourth',  'ZCodeFourthHome') }
    @{ Name = 'Fifth';  HomeRel = 'ZCodeFifthHome';  Markers = @('ZCode-Fifth',   'ZCodeFifthHome')  }
    @{ Name = 'Sixth';  HomeRel = 'ZCodeSixthHome';  Markers = @('ZCode-Sixth',   'ZCodeSixthHome')  }
)

$Script:FailedTargets = @()
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-SyncLog([string]$line) {
    # Log writes must never unwind a run that may already have rewritten the
    # clone config ($ErrorActionPreference = 'Stop'): fall back to the
    # console, loudly, and keep going.
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Add-Content -LiteralPath $LogFile -Value "$stamp $line" -Encoding UTF8
    } catch {
        Write-Host "[LOG-FAIL] $line" -ForegroundColor Yellow
        Write-Host ("[LOG-FAIL] could not append to {0}: {1}" -f $LogFile, $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Write-Tag([string]$Tag, [string]$Msg, [string]$Color = 'Gray') {
    Write-Host "[$Tag] $Msg" -ForegroundColor $Color
    Write-SyncLog "[$Tag] $Msg"
}

function Add-Audit([string]$CloneZ, [string]$Area, [string]$Action, [bool]$Ok, [string]$Detail) {
    if ($DryRun) { return }
    $rec = [ordered]@{
        ts     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        area   = $Area
        action = $Action
        ok     = $Ok
        detail = $Detail
    }
    $json = $rec | ConvertTo-Json -Compress
    try {
        Add-Content -LiteralPath (Join-Path $CloneZ 'asset-sync-audit.jsonl') -Value $json -Encoding UTF8
    } catch {
        # Same rule as Write-SyncLog: audit failures surface on the console,
        # never abort the run.
        Write-Host "[AUDIT-FAIL] $json" -ForegroundColor Yellow
        Write-Host ("[AUDIT-FAIL] could not append to {0}: {1}" -f (Join-Path $CloneZ 'asset-sync-audit.jsonl'), $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Read-JsonFile([string]$Path) {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return (ConvertFrom-Json $raw)
}

function Test-LinkIs([string]$Path, [string]$ExpectedTarget) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -ne 'Junction') { return $false }
    $tgt = [string]$item.Target
    if ([string]::IsNullOrWhiteSpace($tgt)) { return $false }
    $a = [System.IO.Path]::GetFullPath($tgt).TrimEnd('\')
    $b = [System.IO.Path]::GetFullPath($ExpectedTarget).TrimEnd('\')
    return ($a -ieq $b)
}

function New-DirJunction([string]$LinkPath, [string]$TargetPath) {
    try {
        New-Item -ItemType Junction -Path $LinkPath -Value $TargetPath -ErrorAction Stop | Out-Null
        return $true
    } catch {
        # Fallback: mklink /J needs no elevation either.
        & cmd.exe /c mklink /J "$LinkPath" "$TargetPath" | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        return $true
    }
}

# Relative plugin-version set "marketplace\plugin\version" under a cache root.
function Get-PluginRelSet([string]$CacheRoot) {
    $rels = @()
    if (-not (Test-Path -LiteralPath $CacheRoot)) { return ,$rels }
    foreach ($mp in (Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction SilentlyContinue)) {
        foreach ($plg in (Get-ChildItem -LiteralPath $mp.FullName -Directory -ErrorAction SilentlyContinue)) {
            foreach ($ver in (Get-ChildItem -LiteralPath $plg.FullName -Directory -ErrorAction SilentlyContinue)) {
                $rels += ($mp.Name + '\' + $plg.Name + '\' + $ver.Name)
            }
        }
    }
    return ,($rels | Sort-Object -Unique)
}

# Top-level entry-name set under a root (marketplaces tripwire: the /MIR must
# converge the first level; deeper file-level drift needs a re-run to see).
function Get-TopLevelSet([string]$Root) {
    $names = @()
    if (-not (Test-Path -LiteralPath $Root)) { return ,$names }
    foreach ($e in @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue)) { $names += $e.Name }
    return ,($names | Sort-Object -Unique)
}

function Sync-McpDefinitions([string]$Name, [string]$CloneZ, [string]$CloneConfig) {
    $area = 'mcp'
    try {
        $primaryCfg = Read-JsonFile $PrimaryConfig
        $cloneCfg   = Read-JsonFile $CloneConfig
    } catch {
        Write-Tag "FAILED:$Name" ("config.json unreadable: {0}" -f $_.Exception.Message) 'Red'
        Add-Audit $CloneZ $area 'load' $false $_.Exception.Message
        return $false
    }
    if ($null -eq $primaryCfg -or $null -eq $cloneCfg) {
        Write-Tag "FAILED:$Name" 'config.json parsed empty.' 'Red'
        Add-Audit $CloneZ $area 'load' $false 'parsed empty'
        return $false
    }
    if ($null -eq $primaryCfg.mcp -or $null -eq $primaryCfg.mcp.servers) {
        # A Primary with zero MCP servers is a legitimate state (fresh box /
        # every definition deleted): the merge would iterate an empty set --
        # clone-only servers stay, nothing is written. OK/empty, not a layout
        # failure (FAILED stays reserved for unreadable config).
        Write-Tag "OK:$Name" 'Primary has no mcp.servers - nothing to sync (clone-only servers kept).' 'Green'
        Add-Audit $CloneZ $area 'load' $true 'primary mcp.servers empty'
        return $true
    }

    # Ensure the clone has mcp.servers containers to merge into.
    if ($null -eq $cloneCfg.mcp) { $cloneCfg | Add-Member -NotePropertyName mcp -NotePropertyValue (New-Object PSObject) }
    if ($null -eq $cloneCfg.mcp.servers) { $cloneCfg.mcp | Add-Member -NotePropertyName servers -NotePropertyValue (New-Object PSObject) }

    $pServers = $primaryCfg.mcp.servers
    $cServers = $cloneCfg.mcp.servers

    $changed = Invoke-McpMerge -PrimaryServers $pServers -CloneServers $cServers

    if ($changed.Count -eq 0) {
        Write-Tag "OK:$Name" 'MCP server definitions already match the Primary.' 'Green'
        Add-Audit $CloneZ $area 'verify' $true 'already in sync'
        return $true
    }

    Write-Tag "INFO:$Name" ("MCP definition drift on: {0}" -f ($changed -join ', ')) 'Cyan'
    if ($DryRun) {
        Write-Tag "DRY:$Name" 'would backup config.json then merge + verify (no write in DryRun).' 'Cyan'
        return $true
    }

    $bak = "$CloneConfig.bak-$Stamp"
    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
    Copy-Item -LiteralPath $CloneConfig -Destination $bak -Force
    Add-Audit $CloneZ $area 'backup' $true (Split-Path -Leaf $bak)

    Write-JsonNoBom $CloneConfig $cloneCfg
    Add-Audit $CloneZ $area 'write' $true ('merged: ' + ($changed -join ', '))

    # Verify-after (never silent-success): the rewrite replaced the WHOLE
    # config.json from PS objects, so the re-read is deep-compared against
    # the FULL merged object -- not just mcp.servers (a >100-deep nesting
    # degrades silently to $null in ConvertTo-Json and is caught here).
    $verify = $null
    try { $verify = Read-JsonFile $CloneConfig } catch { $verify = $null }
    $bad = @()
    if ($null -eq $verify) {
        $bad += 're-read failed'
    } elseif (-not (Test-DeepEqual (ConvertTo-DeepHashtable $cloneCfg) (ConvertTo-DeepHashtable $verify))) {
        $bad += 'full-file round-trip mismatch'
        if ($null -eq $verify.mcp -or $null -eq $verify.mcp.servers) {
            $bad += 'mcp.servers lost in the rewrite'
        } else {
            $expectedNames = @($cServers.PSObject.Properties | ForEach-Object { $_.Name })
            $actualNames   = @($verify.mcp.servers.PSObject.Properties | ForEach-Object { $_.Name })
            $missing = @($expectedNames | Where-Object { $actualNames -notcontains $_ })
            if ($missing.Count -gt 0) { $bad += ('mcp.servers missing: ' + ($missing -join ',')) }
        }
    }
    if ($bad.Count -gt 0) {
        Write-Tag "FAILED:$Name" ("verify-after mismatch ({0}) - config restored from backup." -f ($bad -join ', ')) 'Red'
        Copy-Item -LiteralPath $bak -Destination $CloneConfig -Force
        Add-Audit $CloneZ $area 'verify' $false ('mismatch: ' + ($bad -join ', '))
        return $false
    }
    Write-Tag "OK:$Name" ("MCP definitions synced + verified ({0}); backup: {1}" -f ($changed -join ', '), (Split-Path -Leaf $bak)) 'Green'
    return $true
}

function Sync-SkillsJunction([string]$Name, [string]$CloneZ, [string]$CloneHome) {
    if (-not (Test-Path -LiteralPath $PrimaryAgents)) {
        Write-Tag "WARN:$Name" ("shared skills store {0} not found - skills sync skipped." -f $PrimaryAgents) 'Yellow'
        Add-Audit $CloneZ 'skills' 'junction' $false 'primary .agents missing'
        return $true
    }

    # 2a) Retire the stale skills COPY so it stops shadowing .agents\skills.
    $staleSkills = Join-Path $CloneZ 'skills'
    if (Test-Path -LiteralPath $staleSkills) {
        $item = Get-Item -LiteralPath $staleSkills -Force
        if ([string]::IsNullOrEmpty($item.LinkType)) {
            $dest = Join-Path $CloneZ ("skills.pre-sync-" + $Stamp)
            if ($DryRun) {
                Write-Tag "DRY:$Name" ("would move stale skills copy aside -> {0}" -f (Split-Path -Leaf $dest)) 'Cyan'
            } else {
                Move-Item -LiteralPath $staleSkills -Destination $dest -Force
                if (Test-Path -LiteralPath $staleSkills) {
                    Write-Tag "FAILED:$Name" 'stale skills dir still present after the move.' 'Red'
                    Add-Audit $CloneZ 'skills' 'retire-copy' $false 'move failed'
                    return $false
                }
                Write-Tag "OK:$Name" ("stale skills copy moved aside -> {0}" -f (Split-Path -Leaf $dest)) 'Green'
                Add-Audit $CloneZ 'skills' 'retire-copy' $true (Split-Path -Leaf $dest)
            }
        } else {
            Write-Tag "OK:$Name" '.zcode\skills is already a link - left untouched.' 'Green'
        }
    }

    # 2b) Junction <CloneHome>\.agents -> the shared store (no elevation needed).
    $cloneAgents = Join-Path $CloneHome '.agents'
    $needCreate = $true
    $movedAside = $null
    if (Test-Path -LiteralPath $cloneAgents) {
        if (Test-LinkIs $cloneAgents $PrimaryAgents) {
            Write-Tag "OK:$Name" '.agents junction already points at the shared store.' 'Green'
            $needCreate = $false
        } else {
            $dest = "$cloneAgents.pre-sync-$Stamp"
            if ($DryRun) {
                Write-Tag "DRY:$Name" ("would move existing .agents aside -> {0}" -f (Split-Path -Leaf $dest)) 'Cyan'
            } else {
                Move-Item -LiteralPath $cloneAgents -Destination $dest -Force
                $movedAside = $dest
                Add-Audit $CloneZ 'skills' 'move-aside' $true (Split-Path -Leaf $dest)
            }
        }
    }
    if ($needCreate) {
        if ($DryRun) {
            Write-Tag "DRY:$Name" ("would junction {0} -> {1}" -f $cloneAgents, $PrimaryAgents) 'Cyan'
        } else {
            if (-not (New-DirJunction $cloneAgents $PrimaryAgents)) {
                Write-Tag "FAILED:$Name" ("could not create .agents junction -> {0}" -f $PrimaryAgents) 'Red'
                Add-Audit $CloneZ 'skills' 'junction' $false 'create failed'
                # Rollback: without it the clone is stranded -- its original
                # .agents renamed aside and NO link in place (skill discovery
                # broken for every instance sharing this home).
                if ($movedAside) {
                    try {
                        if (Test-Path -LiteralPath $cloneAgents) {
                            Write-Tag "FAILED:$Name" ("rollback skipped - a link still occupies {0}; the original is kept at {1}" -f $cloneAgents, $movedAside) 'Red'
                            Add-Audit $CloneZ 'skills' 'rollback' $false 'path occupied'
                        } else {
                            Move-Item -LiteralPath $movedAside -Destination $cloneAgents -Force
                            Write-Tag "INFO:$Name" ("original .agents restored from {0}" -f $movedAside) 'Yellow'
                            Add-Audit $CloneZ 'skills' 'rollback' $true (Split-Path -Leaf $movedAside)
                        }
                    } catch {
                        Write-Tag "FAILED:$Name" ("rollback of the original .agents failed: {0} - restore manually from {1}" -f $_.Exception.Message, $movedAside) 'Red'
                        Add-Audit $CloneZ 'skills' 'rollback' $false $_.Exception.Message
                    }
                }
                return $false
            }
        }
    }

    if ($DryRun) { return $true }

    # Verify-after: junction intact + skills actually reachable through it.
    if (-not (Test-LinkIs $cloneAgents $PrimaryAgents)) {
        Write-Tag "FAILED:$Name" '.agents is not a correct junction after the sync.' 'Red'
        Add-Audit $CloneZ 'skills' 'verify' $false 'junction verify failed'
        return $false
    }
    $cnt = 0
    $skillsThrough = Join-Path $cloneAgents 'skills'
    if (Test-Path -LiteralPath $skillsThrough) {
        $cnt = @(Get-ChildItem -LiteralPath $skillsThrough -ErrorAction SilentlyContinue).Count
    }
    if ($cnt -lt 1) {
        if (Test-Path -LiteralPath $PrimaryAgents) {
            # The junction is correct and the shared store exists: an empty
            # skills set is a legitimate fresh-box state (no skills yet).
            # This script auto-runs as launcher step 2d, so a hard FAIL here
            # would flag every clone launch. Aligns with the "primary .agents
            # missing" WARN path earlier in this function.
            Write-Tag "WARN:$Name" ("junction correct, but {0} skill(s) visible through it - the shared store has no skills yet." -f $cnt) 'Yellow'
            Add-Audit $CloneZ 'skills' 'verify' $true ("junction ok, $cnt skills visible (empty shared store)")
            return $true
        }
        Write-Tag "FAILED:$Name" 'no skills visible through the .agents junction and the shared store is gone.' 'Red'
        Add-Audit $CloneZ 'skills' 'verify' $false '0 skills visible, shared store missing'
        return $false
    }
    Write-Tag "OK:$Name" (".agents junction verified - {0} skills visible through it." -f $cnt) 'Green'
    Add-Audit $CloneZ 'skills' 'junction' $true "$cnt skills visible"
    return $true
}

function Sync-PluginCache([string]$Name, [string]$CloneZ, [string]$CloneCli) {
    $pCache = Join-Path $PrimaryCli 'plugins\cache'
    $cCache = Join-Path $CloneCli 'plugins\cache'
    $pMkt   = Join-Path $PrimaryCli 'plugins\marketplaces'
    $cMkt   = Join-Path $CloneCli 'plugins\marketplaces'
    $pKnown = Join-Path $PrimaryCli 'plugins\known_marketplaces.json'
    $cKnown = Join-Path $CloneCli 'plugins\known_marketplaces.json'

    $pSet = Get-PluginRelSet $pCache
    $cSet = Get-PluginRelSet $cCache
    $diff = @(Compare-Object -ReferenceObject $pSet -DifferenceObject $cSet)

    $knownDrift = $false
    if ((Test-Path -LiteralPath $pKnown) -and (Test-Path -LiteralPath $cKnown)) {
        $ph = (Get-FileHash -LiteralPath $pKnown -Algorithm SHA256).Hash
        $ch = (Get-FileHash -LiteralPath $cKnown -Algorithm SHA256).Hash
        $knownDrift = ($ph -ne $ch)
    } else {
        $knownDrift = ((Test-Path -LiteralPath $pKnown) -ne (Test-Path -LiteralPath $cKnown))
    }

    if (($diff.Count -eq 0) -and (-not $knownDrift)) {
        Write-Tag "OK:$Name" ("plugin cache already in sync ({0} plugin versions)." -f $pSet.Count) 'Green'
        Add-Audit $CloneZ 'plugins' 'verify' $true 'already in sync'
        return $true
    }

    if ($DryRun) {
        Write-Tag "DRY:$Name" ("would robocopy /MIR plugin cache + marketplaces ({0} differing entries)." -f $diff.Count) 'Cyan'
        return $true
    }

    $fail = $false
    $suspect = @()
    foreach ($pair in @(@($pCache, $cCache), @($pMkt, $cMkt))) {
        if (-not (Test-Path -LiteralPath $pair[0])) { continue }
        $null = & robocopy.exe $pair[0] $pair[1] /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) {
            Write-Tag "FAIL:$Name" ("robocopy exited {0} for {1}" -f $LASTEXITCODE, $pair[0]) 'Red'
            $fail = $true
        } elseif ($LASTEXITCODE -ge 4) {
            # Exit 4-7 = mismatches: locked/AV-held files can survive /R:1.
            # Not a hard failure (the verify-after below still runs), but the
            # mirror is suspect and must be named in the verify result.
            Write-Tag "WARN:$Name" ("robocopy exited {0} for {1} - some files may not have copied (mismatch)." -f $LASTEXITCODE, (Split-Path -Leaf $pair[0])) 'Yellow'
            $suspect += ("robocopy exit {0} on {1}" -f $LASTEXITCODE, (Split-Path -Leaf $pair[0]))
        }
    }
    if (Test-Path -LiteralPath $pKnown) {
        [System.IO.File]::Copy($pKnown, $cKnown, $true)
    } elseif (Test-Path -LiteralPath $cKnown) {
        # Existence drift the copy cannot resolve (the Primary is read-only):
        # a known_marketplaces.json the Primary does not have is stale clone
        # state -- delete it explicitly so the sets converge, never silently OK.
        try {
            Remove-Item -LiteralPath $cKnown -Force
            Write-Tag "INFO:$Name" 'stale clone known_marketplaces.json deleted (the Primary has none).' 'Cyan'
            Add-Audit $CloneZ 'plugins' 'mirror' $true 'stale clone known_marketplaces.json deleted'
        } catch {
            Write-Tag "FAILED:$Name" ("could not delete the stale clone known_marketplaces.json: {0}" -f $_.Exception.Message) 'Red'
            Add-Audit $CloneZ 'plugins' 'mirror' $false $_.Exception.Message
            $fail = $true
        }
    }

    # Verify-after: the clone's version set must equal the Primary's now, the
    # marketplaces first level must have converged, and known_marketplaces.json
    # must agree (existence + content).
    $bad = @()
    $vSet = Get-PluginRelSet $cCache
    $diff2 = @(Compare-Object -ReferenceObject $pSet -DifferenceObject $vSet)
    if ($diff2.Count -gt 0) { $bad += ("{0} cache version entries differ" -f $diff2.Count) }
    if (Test-Path -LiteralPath $pMkt) {
        $mdiff = @(Compare-Object -ReferenceObject (Get-TopLevelSet $pMkt) -DifferenceObject (Get-TopLevelSet $cMkt))
        if ($mdiff.Count -gt 0) { $bad += ("{0} marketplace entries differ" -f $mdiff.Count) }
    } elseif (Test-Path -LiteralPath $cMkt) {
        # Same read-only-Primary shape as the known file, but deleting a whole
        # marketplace dir is destructive -- warn loudly instead of mirroring
        # to empty.
        Write-Tag "WARN:$Name" ("the Primary has no marketplaces dir - the clone's copy was left as-is (Primary is read-only).") 'Yellow'
        Add-Audit $CloneZ 'plugins' 'mirror' $true 'clone-only marketplaces dir left in place'
    }
    $pKnownNow = Test-Path -LiteralPath $pKnown
    $cKnownNow = Test-Path -LiteralPath $cKnown
    if ($pKnownNow -ne $cKnownNow) {
        $bad += 'known_marketplaces.json existence mismatch'
    } elseif ($pKnownNow) {
        $ph = (Get-FileHash -LiteralPath $pKnown -Algorithm SHA256).Hash
        $ch = (Get-FileHash -LiteralPath $cKnown -Algorithm SHA256).Hash
        if ($ph -ne $ch) { $bad += 'known_marketplaces.json hash mismatch' }
    }
    $detail = (@($bad) + @($suspect) | Where-Object { $_ }) -join '; '
    if (($bad.Count -gt 0) -or $fail) {
        Write-Tag "FAILED:$Name" ("plugin cache verify-after mismatch ({0}) - re-run after closing the instances." -f $detail) 'Red'
        Add-Audit $CloneZ 'plugins' 'mirror' $false ("mismatch: " + $detail)
        return $false
    }
    Write-Tag "OK:$Name" ("plugin cache mirrored + verified ({0} plugin versions)." -f $vSet.Count) 'Green'
    $okDetail = "$($vSet.Count) versions"
    if ($suspect.Count -gt 0) { $okDetail += '; robocopy mismatch warnings: ' + ($suspect -join '; ') }
    Add-Audit $CloneZ 'plugins' 'mirror' $true $okDetail
    return $true
}

function Invoke-InstanceSync([hashtable]$Def) {
    $name      = $Def.Name
    $cloneHome = Join-Path $UserProfile $Def.HomeRel
    $cloneZ    = Join-Path $cloneHome '.zcode'
    $cloneCli  = Join-Path $cloneZ 'cli'

    Write-Host ''
    Write-Host "=== $name ($($Def.HomeRel)) ===" -ForegroundColor White

    if (-not (Test-Path -LiteralPath $cloneZ)) {
        Write-Tag "SKIP:$name" 'not seeded yet - first launch copies the Primary profile (launcher step 2); this sync verifies afterwards.' 'Yellow'
        return $true
    }
    if ($RunningNames.ContainsKey($name)) {
        if ($McpOnly) {
            # Verified 2026-10-27 (app.asar code + all six instances' logs):
            # the app holds no handle on config.json, never rewrites it on
            # exit, and reads mcp.servers at every app-server spawn (one per
            # new session). Writing under a running instance is safe; the
            # synced definitions land on its next chat without a restart.
            Write-Tag "INFO:$name" 'instance is RUNNING - MCP merge proceeds (no exit-time rewrite; applies at next session).' 'Cyan'
        } else {
            Write-Tag "SKIP:$name" 'instance is RUNNING - skills/plugin mirroring must not race a live app; close it and re-run, or use -McpOnly.' 'Yellow'
            return $true
        }
    }
    if (-not (Test-Path -LiteralPath $cloneCli)) {
        Write-Tag "WARN:$name" '.zcode exists but .zcode\cli is missing - unexpected layout, skipping.' 'Yellow'
        return $true
    }
    $cloneConfig = Join-Path $cloneCli 'config.json'
    if (-not (Test-Path -LiteralPath $cloneConfig)) {
        Write-Tag "WARN:$name" 'clone config.json missing - run the clone launcher once to seed, then re-run.' 'Yellow'
        return $true
    }

    $ok = $true
    if (-not (Sync-McpDefinitions -Name $name -CloneZ $cloneZ -CloneConfig $cloneConfig)) { $ok = $false }
    if (-not $McpOnly) {
        if (-not (Sync-SkillsJunction -Name $name -CloneZ $cloneZ -CloneHome $cloneHome)) { $ok = $false }
        if (-not (Sync-PluginCache  -Name $name -CloneZ $cloneZ -CloneCli $cloneCli))     { $ok = $false }
    }
    return $ok
}

# ---------------- driver ----------------

if ($McpOnly) { Write-Host 'GHOST - ZCode MCP definitions sync (MCP only; safe against RUNNING instances)' }
else          { Write-Host 'GHOST - ZCode clone asset sync (MCP definitions + skills + plugin cache)' }
if ($DryRun) { Write-Host 'DRY RUN - nothing will be written.' -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $PrimaryConfig)) {
    Write-Tag 'FAILED' ("Primary config not found: {0}" -f $PrimaryConfig) 'Red'
    exit 1
}

# One WMI snapshot for the running-instance guard (markers = home/roaming dir
# names in the command line; same classification rule as launcher + watcher).
# -McpOnly never consults it (the MCP merge is safe against running instances)
# and skips the query entirely.
$RunningNames = @{}
if (-not $McpOnly) {
    try {
        $zprocs = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ZCode.exe'" -ErrorAction Stop
        foreach ($p in $zprocs) {
            foreach ($d in $InstanceDefs) {
                foreach ($m in $d.Markers) {
                    if ($p.CommandLine -and ($p.CommandLine.IndexOf($m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                        $RunningNames[$d.Name] = $true
                    }
                }
            }
        }
    } catch {
        Write-Tag 'WARN' ("WMI process scan failed ({0}) - the running-instance guard is blind; close every ZCode instance if unsure." -f $_.Exception.Message) 'Yellow'
    }
}

$targets = @($InstanceDefs | Where-Object { $Target -eq 'All' -or $_.Name -eq $Target })

$results = @()
foreach ($def in $targets) {
    $r = Invoke-InstanceSync -Def $def
    $results += [pscustomobject]@{ Name = $def.Name; Ok = [bool]$r }
}

Write-Host ''
Write-Host '--- Summary ---'
foreach ($r in $results) {
    if ($r.Ok) { Write-Host ("[{0}] OK" -f $r.Name) -ForegroundColor Green }
    else {
        Write-Host ("[{0}] FAILED" -f $r.Name) -ForegroundColor Red
        $Script:FailedTargets += $r.Name
    }
}

if ($Script:FailedTargets.Count -gt 0) {
    Write-Host ("FAILED targets: {0} - details in {1}" -f ($Script:FailedTargets -join ', '), $LogFile) -ForegroundColor Red
    exit 1
}
Write-Host ("All targets OK. Log: {0}" -f $LogFile) -ForegroundColor Green
exit 0
