# SPDX-License-Identifier: Apache-2.0
#Requires -Version 5.1
<#
.SYNOPSIS
  Sync ZCode clone memory stores onto the Primary's shared store: every clone
  adopts cli\memories as a junction to %USERPROFILE%\.zcode\cli\memories, so
  all instances (Primary + Blue..Orange) literally share one memory set.

.DESCRIPTION
  WHY: each clone's .zcode\cli\memories is a private copy created at seed
  time; memory saved in one instance never reaches the others and the copies
  drift (2026-11-21 live measurement: five clone stores of 233 markdown files
  each vs 957 on the Primary, MEMORY.md index pointers diverged by hundreds
  of lines). The skills area already solves the same drift class via a
  junction on the shared ~\.agents store; this tool applies the identical
  pattern to the per-project memory stores, with the Primary's own profile as
  the canonical copy.

  Per clone (Second..Sixth), in order:
  1. Guards: an unseeded home is skipped; an already-junctioned store is
     verified + idempotent-skipped; a RUNNING instance is skipped with a
     warning unless -AllowRunning is passed (junction swaps must not race a
     live app by default; memory md files are only touched by the harness on
     demand, so the override is low-risk but stays opt-in).
  2. Newer-wins merge clone -> Primary: robocopy /E /XO, so a file the clone
     holds NEWER than the Primary lands in the Primary first and the Primary
     is never downgraded. Junk dirs (_backup-merge-*, memories.pre-sync-*)
     are excluded everywhere and never propagate.
  3. MEMORY.md index union clone -> Primary via tools\zcode_memory_merge.ps1
     (explicit no-BOM UTF-8 read/write + mojibake peel; the 2026-11-21
     incident showed PS 5.1 Get-Content ANSI defaults re-appending UTF-8
     lines as layered mojibake - this tool never touches those APIs).
  4. The clone's store is moved aside whole (memories.pre-sync-<ts>) and
     cli\memories is junctioned to the Primary store (junctions need no
     elevation - same mechanics as the skills sync).
  5. Verify-after: junction LinkType + resolved target + a project-dir probe
     through the junction; every index write is re-read and deep-compared.

  The move-aside backup covers every clone file (the dir is retired whole,
  never deleted). Files the Primary overwrites on the way in are only ever
  superseded by a strictly newer clone version (robocopy /XO) - same
  backup semantics as the plugin-cache mirror in sync_zcode_assets.ps1.

  Never silent-success: any FAILED target => exit 1 with the target list.
  Audit: JSONL appended to <CloneHome>\.zcode\memory-sync-audit.jsonl
  Log:   tools\logs\sync_zcode_memories.log

  Derived from the 2026-11-21 live all-with-all sync performed on the owner's
  machine (junction pattern mirrors Sync-SkillsJunction; the merge + peel are
  fixture-tested). Live acceptance on a fresh multi-clone machine is pending.
#>

param(
    [ValidateSet('Second', 'Third', 'Fourth', 'Fifth', 'Sixth', 'All')]
    [string]$Target = 'All',
    [switch]$DryRun,
    # Owner override: proceed on a RUNNING instance. Default skips it - a
    # junction swap + robocopy merge must not race a live app.
    [switch]$AllowRunning
)

$ErrorActionPreference = 'Stop'

# Pure merge core (no main body, no side effects; the only copy of the
# index-union + mojibake-peel logic lives there).
. (Join-Path $PSScriptRoot 'zcode_memory_merge.ps1')

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }

$PrimaryMem = Join-Path $UserProfile '.zcode\cli\memories'
$PrimaryZ   = Join-Path $UserProfile '.zcode'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'

$LogDir  = Join-Path $PSScriptRoot 'logs'
$LogFile = Join-Path $LogDir 'sync_zcode_memories.log'

# Per-clone layout - mirrors sync_zcode_assets.ps1 ($InstanceDefs):
# classification is by process markers (home/roaming dir names in the command
# line), never titles.
$InstanceDefs = @(
    @{ Name = 'Second'; HomeRel = 'ZCodeSecondHome'; Color = 'Blue';   ExeName = 'ZCode-Blue.exe';   Markers = @('ZCode-Second',  'ZCodeSecondHome') }
    @{ Name = 'Third';  HomeRel = 'ZCodeThirdHome';  Color = 'Yellow'; ExeName = 'ZCode-Yellow.exe'; Markers = @('ZCode-Third',   'ZCodeThirdHome')  }
    @{ Name = 'Fourth'; HomeRel = 'ZCodeFourthHome'; Color = 'Green';  ExeName = 'ZCode-Green.exe';  Markers = @('ZCode-Fourth',  'ZCodeFourthHome')  }
    @{ Name = 'Fifth';  HomeRel = 'ZCodeFifthHome';  Color = 'Red';    ExeName = 'ZCode-Red.exe';    Markers = @('ZCode-Fifth',   'ZCodeFifthHome')  }
    @{ Name = 'Sixth';  HomeRel = 'ZCodeSixthHome';  Color = 'Orange'; ExeName = 'ZCode-Orange.exe'; Markers = @('ZCode-Sixth',   'ZCodeSixthHome')  }
)

# Display vocabulary (matches sync_zcode_assets.ps1): colors lead every
# user-visible tag/header; the frozen key follows after a slash.
function Get-SyncTargetDisplay([string]$Key) {
    $d = @($InstanceDefs | Where-Object { $_.Name -eq $Key })[0]
    if ($d) { '{0} / {1}' -f $d.Color, $d.Name } else { $Key }
}

$Script:FailedTargets = @()

function Write-SyncLog([string]$line) {
    # Log writes must never unwind a run that may already have junctioned a
    # clone ($ErrorActionPreference = 'Stop'): fall back to the console,
    # loudly, and keep going.
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
        Add-Content -LiteralPath (Join-Path $CloneZ 'memory-sync-audit.jsonl') -Value $json -Encoding UTF8
    } catch {
        # Same rule as Write-SyncLog: audit failures surface on the console,
        # never abort the run.
        Write-Host "[AUDIT-FAIL] $json" -ForegroundColor Yellow
        Write-Host ("[AUDIT-FAIL] could not append to {0}: {1}" -f (Join-Path $CloneZ 'memory-sync-audit.jsonl'), $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Get-JunkDirs([string]$Root) {
    # _backup-merge-* (older merge-tool leftovers) and memories.pre-sync-*
    # (this tool's own move-aside backups) are junk that must never
    # propagate into the shared store.
    return @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '_backup-merge-*' -or $_.Name -like 'memories.pre-sync-*' } |
        Select-Object -ExpandProperty FullName)
}

function Test-MemoriesJunction([string]$Path) {
    # True only when $Path is a junction resolving to the Primary store.
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.LinkType -ne 'Junction') { return $false }
    $tgt = @($item.Target)[0]
    if ([string]::IsNullOrWhiteSpace($tgt)) { return $false }
    try {
        $resolvedTgt = (Resolve-Path -LiteralPath $tgt).Path
        $resolvedPrimary = (Resolve-Path -LiteralPath $PrimaryMem).Path
        return ($resolvedTgt -ieq $resolvedPrimary)
    } catch { return $false }
}

function Probe-JunctionContent([string]$Path) {
    # Content reachable through the junction (project dirs present, files
    # counted) - a junction to a deleted/moved Primary would report 0.
    try {
        $projects = Join-Path $Path 'projects'
        if (-not (Test-Path -LiteralPath $projects)) { return 0 }
        # NOTE: @( ... | Measure-Object).Count is ALWAYS 1 (it counts the
        # single MeasureObject) - count the file objects directly.
        $count = @(Get-ChildItem -LiteralPath $projects -Recurse -File -ErrorAction SilentlyContinue).Count
        return $count
    } catch { return 0 }
}

function Invoke-NewerWinsMerge([string]$Name, [string]$CloneMem, [string]$AuditZ) {
    # robocopy /E /XO clone -> Primary: copies NEW + NEWER-or-CHANGED files
    # only, so the Primary is never downgraded by an older clone copy.
    # MEMORY.md is EXCLUDED from this pass (/XF): /XO would let a newer
    # (possibly less complete) clone index overwrite the Primary's index
    # BEFORE the line-union pass reads it - the union, not robocopy, must be
    # the only writer of index files. /L in DryRun lists without writing.
    # rc >= 8 is a robocopy failure (0-7 are success codes).
    $rcArgs = @($CloneMem, $PrimaryMem, '/E', '/XO', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/XF', 'MEMORY.md')
    if ($DryRun) { $rcArgs += '/L' }
    $junk = Get-JunkDirs $CloneMem
    if ($junk.Count -gt 0) { $rcArgs += (@('/XD') + $junk) }
    robocopy $rcArgs | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Write-Tag "FAILED:$(Get-SyncTargetDisplay $Name)" ("newer-wins merge robocopy failed (rc={0})." -f $rc) 'Red'
        Add-Audit $AuditZ 'memories' 'robocopy-merge' $false ("rc=" + $rc)
        return $false
    }
    Write-Tag "OK:$(Get-SyncTargetDisplay $Name)" ("newer-wins merge clone->Primary done (rc={0})." -f $rc) 'Green'
    Add-Audit $AuditZ 'memories' 'robocopy-merge' $true ("rc=" + $rc)
    return $true
}

function Sync-MemoryIndexes([string]$Name, [string]$CloneMem, [string]$AuditZ) {
    # Line-union every clone MEMORY.md into the Primary's same-rel index.
    # This is the ONLY writer of index files (the robocopy pass excludes
    # them with /XF). No PS 5.1 Get-Content/Add-Content anywhere: the lib is
    # explicit no-BOM UTF-8 (the 2026-11-21 incident's root cause).
    $cloneIndexes = @(Get-ChildItem -LiteralPath $CloneMem -Recurse -Filter 'MEMORY.md' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '_backup-merge-|memories\.pre-sync-' })
    $ok = $true
    foreach ($ci in $cloneIndexes) {
        $rel        = $ci.FullName.Substring($CloneMem.Length).TrimStart('\')
        $primaryIdx = Join-Path $PrimaryMem $rel
        if (-not (Test-Path -LiteralPath $primaryIdx)) {
            # New index: verbatim byte copy (a round-trip would normalize
            # newlines for no benefit; the file is adopted exactly as-is).
            if ($DryRun) {
                Write-Tag "DRY:$(Get-SyncTargetDisplay $Name)" ("would copy new index {0}" -f $rel) 'Cyan'
                continue
            }
            try {
                New-Item -ItemType Directory -Path (Split-Path $primaryIdx) -Force | Out-Null
                Copy-Item -LiteralPath $ci.FullName -Destination $primaryIdx -Force
                if (-not (Test-Path -LiteralPath $primaryIdx)) { throw 'index missing after copy' }
                Write-Tag "OK:$(Get-SyncTargetDisplay $Name)" ("new index adopted: {0}" -f $rel) 'Green'
                Add-Audit $AuditZ 'memories' 'index-copy' $true $rel
            } catch {
                Write-Tag "FAILED:$(Get-SyncTargetDisplay $Name)" ("could not adopt index {0}: {1}" -f $rel, $_.Exception.Message) 'Red'
                Add-Audit $AuditZ 'memories' 'index-copy' $false $rel
                $ok = $false
            }
            continue
        }
        $primaryLines = Get-MemoryIndexLines -Path $primaryIdx
        $cloneLines   = Get-MemoryIndexLines -Path $ci.FullName
        $merged       = Merge-MemoryIndexLines -PrimaryLines $primaryLines -CloneLines $cloneLines
        $before       = ($primaryLines -join "`n")
        $after        = ($merged -join "`n")
        if ($before -eq $after) { continue }   # already in sync
        if ($DryRun) {
            Write-Tag "DRY:$(Get-SyncTargetDisplay $Name)" ("would union index {0}: {1} -> {2} lines" -f $rel, $primaryLines.Count, $merged.Count) 'Cyan'
            continue
        }
        try {
            # House backup rule: the superseded Primary index is kept outside
            # the store (never as a *.bak inside it - the harness indexes the
            # whole memories tree).
            $backupRoot = Join-Path $PrimaryZ ('memory-sync-backups\' + $Stamp)
            $backupPath = Join-Path $backupRoot $rel
            New-Item -ItemType Directory -Path (Split-Path $backupPath) -Force | Out-Null
            Copy-Item -LiteralPath $primaryIdx -Destination $backupPath -Force
            Write-MemoryIndexLines -Path $primaryIdx -Lines $merged
            # Verify-after: re-read + deep compare against the merged set.
            $reread = Get-MemoryIndexLines -Path $primaryIdx
            if (($reread -join "`n") -ne $after) { throw 're-read mismatch after index write' }
            Write-Tag "OK:$(Get-SyncTargetDisplay $Name)" ("index union {0}: {1} -> {2} lines (backup kept)" -f $rel, $primaryLines.Count, $merged.Count) 'Green'
            Add-Audit $AuditZ 'memories' 'index-union' $true ("{0}: {1}->{2}" -f $rel, $primaryLines.Count, $merged.Count)
        } catch {
            Write-Tag "FAILED:$(Get-SyncTargetDisplay $Name)" ("index union failed for {0}: {1}" -f $rel, $_.Exception.Message) 'Red'
            Add-Audit $AuditZ 'memories' 'index-union' $false $rel
            $ok = $false
        }
    }
    return $ok
}

function Invoke-InstanceSync([hashtable]$Def) {
    $name      = $Def.Name
    $cloneHome = Join-Path $UserProfile $Def.HomeRel
    $cloneZ    = Join-Path $cloneHome '.zcode'
    $cloneMem  = Join-Path $cloneZ 'cli\memories'

    Write-Host ''
    Write-Host "=== $($Def.Color) / $name ($($Def.HomeRel)) ===" -ForegroundColor White

    if (-not (Test-Path -LiteralPath $cloneZ)) {
        Write-Tag "SKIP:$(Get-SyncTargetDisplay $name)" 'not seeded yet - first launch copies the Primary profile (launcher step 2); re-run this sync afterwards.' 'Yellow'
        return $true
    }
    if (-not (Test-Path -LiteralPath $cloneMem)) {
        Write-Tag "SKIP:$(Get-SyncTargetDisplay $name)" ("no memory store at {0} - nothing to sync." -f $cloneMem) 'Yellow'
        return $true
    }
    if (Test-MemoriesJunction $cloneMem) {
        $probe = Probe-JunctionContent $cloneMem
        if ($probe -gt 0) {
            Write-Tag "OK:$(Get-SyncTargetDisplay $name)" ("already a junction to the Primary store ({0} files reachable) - nothing to do." -f $probe) 'Green'
            return $true
        }
        Write-Tag "FAILED:$(Get-SyncTargetDisplay $name)" 'memories is a junction but resolves to an empty target - repair the Primary store.' 'Red'
        return $false
    }
    if ($Script:RunningNames.ContainsKey($name) -and -not $AllowRunning) {
        Write-Tag "SKIP:$(Get-SyncTargetDisplay $name)" 'instance is RUNNING - a junction swap must not race a live app; close it and re-run, or pass -AllowRunning to override.' 'Yellow'
        return $true
    }
    if ($Script:RunningNames.ContainsKey($name) -and $AllowRunning) {
        Write-Tag "INFO:$(Get-SyncTargetDisplay $name)" 'instance is RUNNING and -AllowRunning was passed - proceeding (owner override).' 'Cyan'
    }

    if (-not (Invoke-NewerWinsMerge -Name $name -CloneMem $cloneMem -AuditZ $cloneZ)) { return $false }
    if (-not (Sync-MemoryIndexes -Name $name -CloneMem $cloneMem -AuditZ $cloneZ))    { return $false }

    if ($DryRun) {
        Write-Tag "DRY:$(Get-SyncTargetDisplay $name)" ("would move {0} aside -> memories.pre-sync-{1} and junction it -> {2}" -f $cloneMem, $Stamp, $PrimaryMem) 'Cyan'
        return $true
    }

    # Move-aside (whole-dir backup, never deleted) + junction + verify-after.
    $aside = Join-Path (Split-Path $cloneMem) ('memories.pre-sync-' + $Stamp)
    try {
        Move-Item -LiteralPath $cloneMem -Destination $aside -Force
    } catch {
        Write-Tag "FAILED:$(Get-SyncTargetDisplay $name)" ("could not move the store aside (a live handle may hold it): {0}" -f $_.Exception.Message) 'Red'
        Add-Audit $cloneZ 'memories' 'move-aside' $false 'move failed'
        return $false
    }
    Add-Audit $cloneZ 'memories' 'move-aside' $true (Split-Path -Leaf $aside)
    try {
        New-Item -ItemType Junction -Path $cloneMem -Value $PrimaryMem | Out-Null
    } catch {
        # The move-aside removed the active cli\memories path - leaving it
        # missing would make the next run report "no memory store" and
        # silently skip. RESTORE the store before reporting failure.
        Write-Tag "FAILED:$(Get-SyncTargetDisplay $name)" ("could not create the junction: {0}" -f $_.Exception.Message) 'Red'
        Add-Audit $cloneZ 'memories' 'junction' $false 'create failed'
        try {
            Move-Item -LiteralPath $aside -Destination $cloneMem -Force
            Write-Tag "OK:$(Get-SyncTargetDisplay $name)" ("store restored from {0} - nothing lost; fix the junction cause and re-run." -f (Split-Path -Leaf $aside)) 'Yellow'
            Add-Audit $cloneZ 'memories' 'restore' $true (Split-Path -Leaf $aside)
        } catch {
            Write-Tag "FAILED:$(Get-SyncTargetDisplay $name)" ("could not restore the store either - the backup STAYS at {0}: {1}" -f $aside, $_.Exception.Message) 'Red'
            Add-Audit $cloneZ 'memories' 'restore' $false (Split-Path -Leaf $aside)
        }
        return $false
    }
    $probe = Probe-JunctionContent $cloneMem
    if ((Test-MemoriesJunction $cloneMem) -and ($probe -gt 0)) {
        Write-Tag "OK:$(Get-SyncTargetDisplay $name)" ("junction -> {0} verified ({1} files reachable; backup: {2})" -f $PrimaryMem, $probe, (Split-Path -Leaf $aside)) 'Green'
        Add-Audit $cloneZ 'memories' 'junction' $true ("backup=" + (Split-Path -Leaf $aside))
        return $true
    }
    Write-Tag "FAILED:$(Get-SyncTargetDisplay $name)" ("junction verify failed (LinkType={0}, probe={1}) - backup stays at {2}" -f (Get-Item -LiteralPath $cloneMem -Force).LinkType, $probe, (Split-Path -Leaf $aside)) 'Red'
    Add-Audit $cloneZ 'memories' 'junction' $false 'verify failed'
    return $false
}

# ---------------- driver ----------------

if ($AllowRunning) { Write-Host 'GHOST - ZCode memory sync (junction clones onto the Primary store; RUNNING instances INCLUDED by override)' }
else               { Write-Host 'GHOST - ZCode memory sync (junction clones onto the Primary store)' }
if ($DryRun) { Write-Host 'DRY RUN - nothing will be written.' -ForegroundColor Cyan }

if (-not (Test-Path -LiteralPath $PrimaryMem)) {
    Write-Tag 'FAILED' ("Primary memory store not found: {0}" -f $PrimaryMem) 'Red'
    exit 1
}

# One WMI snapshot for the running-instance guard (markers = home/roaming dir
# names + per-color exe copies in the command line; same rule as
# sync_zcode_assets.ps1's guard).
$Script:RunningNames = @{}
try {
    # Filter covers the whole copy family (ZCode.exe + ZCode-<Color>.exe
    # clone copies - 2026-11-11 Task Manager identity).
    $zprocs = Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'ZCode%'" -ErrorAction Stop
    foreach ($p in $zprocs) {
        foreach ($d in $InstanceDefs) {
            foreach ($m in $d.Markers) {
                if ($p.CommandLine -and ($p.CommandLine.IndexOf($m, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
                    $Script:RunningNames[$d.Name] = $true
                }
            }
            # Copy-exe identity: a process running FROM the clone's exe copy
            # marks that clone running even mid-splash (no marker children yet).
            if ($d.ExeName -and $p.CommandLine -and ($p.CommandLine -match ('(?i)' + [regex]::Escape($d.ExeName)))) {
                $Script:RunningNames[$d.Name] = $true
            }
        }
    }
} catch {
    if (-not $DryRun -and -not $AllowRunning) {
        # A blind guard must never degrade to "no instances running": the
        # whole point of the default skip is not racing a live app. Abort
        # loudly instead of proceeding unprotected.
        Write-Tag 'FAILED' ("WMI process scan failed ({0}) - the running-instance guard is blind. Aborting (close every ZCode instance and re-run, or pass -AllowRunning to accept the risk)." -f $_.Exception.Message) 'Red'
        exit 1
    }
    Write-Tag 'WARN' ("WMI process scan failed ({0}) - the running-instance guard is blind; proceeding because {1} was passed." -f $_.Exception.Message, $(if ($DryRun) { '-DryRun (nothing is written)' } else { '-AllowRunning' })) 'Yellow'
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
    $rDisplay = Get-SyncTargetDisplay $r.Name
    if ($r.Ok) { Write-Host ("[{0}] OK" -f $rDisplay) -ForegroundColor Green }
    else {
        Write-Host ("[{0}] FAILED" -f $rDisplay) -ForegroundColor Red
        $Script:FailedTargets += $r.Name
    }
}

if ($Script:FailedTargets.Count -gt 0) {
    $failedDisplay = (@($Script:FailedTargets | ForEach-Object { Get-SyncTargetDisplay $_ }) -join ', ')
    Write-Host ("FAILED targets: {0} - details in {1}" -f $failedDisplay, $LogFile) -ForegroundColor Red
    exit 1
}
Write-Host ("All targets OK. Log: {0}" -f $LogFile) -ForegroundColor Green
exit 0
