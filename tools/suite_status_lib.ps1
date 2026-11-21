#Requires -Version 5.1
# GHOST suite status library - the ONE shared "is instance X running?"
# classifier, parameterized across the clone suites. Ported VERBATIM in its
# rules from the live-verified per-suite tools (this file does NOT replace
# them):
#   - EC-K01 bare-exe main rule + copy-exe-first + subtree-marker BFS walk:
#     tools\status_zcode_instances.ps1 Get-ZcodeInstanceMains (the
#     queue-walk fix for the PS slice-pop bug is preserved),
#   - lockfile probes + title map + the honest-labeling contract
#     (YES (exe copy) / YES (lockfile) / YES (title) / never guessed):
#     tools\diagnose_suite_pressure.ps1,
#   - light-worker PID markers: src\windows\ghost_light_marker.ps1.
#
# Consumers: tools\status_all_instances.ps1 (the unified cross-suite report,
# Maintenance [6]). The six per-suite tools keep their own inline copies
# until a dedicated dedup pass (TASK_BACKLOG follow-up) - they are
# live-verified and this lib must not change their behavior.
#
# Testability: every function accepts injectable process snapshots
# (-Procs / -Windows) so tests can drive the classifier with fake
# WMI/Get-Process-shaped objects instead of live processes.

# Light-worker marker reader (writer side lives in the launchers).
$script:GhostLightMarkerLib = Join-Path $PSScriptRoot '..\src\windows\ghost_light_marker.ps1'
if (Test-Path -LiteralPath $script:GhostLightMarkerLib) { . $script:GhostLightMarkerLib }

$script:GhostSuites = @{
    'zcode' = @{
        DisplayName    = 'ZCode'
        WmiFamily      = "Name LIKE 'ZCode%'"
        ProcFamily     = 'ZCode*'
        ExePrefix      = 'ZCode'
        PrimaryLock    = ''                    # ZCode has no lockfile probe (status_zcode never used one)
        CloneLockProbe = $null
        TitleMap       = @{ 'Second' = 'ZCode Blue'; 'Third' = 'ZCode Yellow'; 'Fourth' = 'ZCode Green'; 'Fifth' = 'ZCode Red'; 'Sixth' = 'ZCode Orange' }
        Instances      = @(
            @{ Key = 'Second'; Color = 'Blue';   CopyExe = 'ZCode-Blue.exe';   CloneHomeRel = 'ZCodeSecondHome'; Markers = @('*ZCode-Second*', '*ZCodeSecondHome*');  LightWorker = $true },
            @{ Key = 'Third';  Color = 'Yellow'; CopyExe = 'ZCode-Yellow.exe'; CloneHomeRel = 'ZCodeThirdHome';  Markers = @('*ZCode-Third*', '*ZCodeThirdHome*');   LightWorker = $true },
            @{ Key = 'Fourth'; Color = 'Green';  CopyExe = 'ZCode-Green.exe';  CloneHomeRel = 'ZCodeFourthHome'; Markers = @('*ZCode-Fourth*', '*ZCodeFourthHome*'); LightWorker = $true },
            @{ Key = 'Fifth';  Color = 'Red';    CopyExe = 'ZCode-Red.exe';    CloneHomeRel = 'ZCodeFifthHome';  Markers = @('*ZCode-Fifth*', '*ZCodeFifthHome*');   LightWorker = $true },
            @{ Key = 'Sixth';  Color = 'Orange'; CopyExe = 'ZCode-Orange.exe'; CloneHomeRel = 'ZCodeSixthHome';  Markers = @('*ZCode-Sixth*', '*ZCodeSixthHome*');   LightWorker = $true }
        )
    }
    'autoclaw2' = @{
        DisplayName    = 'AutoClaw2'
        WmiFamily      = "Name LIKE 'AutoClaw2%'"
        ProcFamily     = 'AutoClaw2*'
        ExePrefix      = 'AutoClaw2'
        PrimaryLock    = ''                    # autoclaw2 leaves no lockfile (documented)
        CloneLockProbe = $null
        TitleMap       = @{}                   # shared "AutoClaw" title - no title signal
        Instances      = @(
            @{ Key = 'c1'; Color = 'Blue';   CopyExe = 'AutoClaw2-Blue.exe';   CloneHomeRel = 'AutoClaw2ClonesHome\c1'; Markers = @('*AutoClaw2ClonesHome\c1*'); LightWorker = $false },
            @{ Key = 'c2'; Color = 'Yellow'; CopyExe = 'AutoClaw2-Yellow.exe'; CloneHomeRel = 'AutoClaw2ClonesHome\c2'; Markers = @('*AutoClaw2ClonesHome\c2*'); LightWorker = $false },
            @{ Key = 'c3'; Color = 'Green';  CopyExe = 'AutoClaw2-Green.exe';  CloneHomeRel = 'AutoClaw2ClonesHome\c3'; Markers = @('*AutoClaw2ClonesHome\c3*'); LightWorker = $false },
            @{ Key = 'c4'; Color = 'Red';    CopyExe = 'AutoClaw2-Red.exe';    CloneHomeRel = 'AutoClaw2ClonesHome\c4'; Markers = @('*AutoClaw2ClonesHome\c4*'); LightWorker = $false },
            @{ Key = 'c5'; Color = 'Orange'; CopyExe = 'AutoClaw2-Orange.exe'; CloneHomeRel = 'AutoClaw2ClonesHome\c5'; Markers = @('*AutoClaw2ClonesHome\c5*'); LightWorker = $false }
        )
    }
    'cline' = @{
        DisplayName    = 'Cline'
        WmiFamily      = "Name LIKE 'Cline%'"
        ProcFamily     = 'Cline*'
        ExePrefix      = 'Cline'
        PrimaryLock    = (Join-Path $env:USERPROFILE '.cline\data\locks\hub\production.json.instance.lock')
        CloneLockProbe = { param($cloneHome) Join-Path $cloneHome 'data\locks\hub\production.json.instance.lock' }
        TitleMap       = @{}                   # shared "Cline vN" title - no title signal
        Instances      = @(
            @{ Key = 'c1'; Color = 'Blue';   CopyExe = 'Cline-Blue.exe';   CloneHomeRel = 'ClineClonesHome\c1'; Markers = @('*ClineClonesHome\c1*'); LightWorker = $true },
            @{ Key = 'c2'; Color = 'Yellow'; CopyExe = 'Cline-Yellow.exe'; CloneHomeRel = 'ClineClonesHome\c2'; Markers = @('*ClineClonesHome\c2*'); LightWorker = $true },
            @{ Key = 'c3'; Color = 'Green';  CopyExe = 'Cline-Green.exe';  CloneHomeRel = 'ClineClonesHome\c3'; Markers = @('*ClineClonesHome\c3*'); LightWorker = $true },
            @{ Key = 'c4'; Color = 'Red';    CopyExe = 'Cline-Red.exe';    CloneHomeRel = 'ClineClonesHome\c4'; Markers = @('*ClineClonesHome\c4*'); LightWorker = $true },
            @{ Key = 'c5'; Color = 'Orange'; CopyExe = 'Cline-Orange.exe'; CloneHomeRel = 'ClineClonesHome\c5'; Markers = @('*ClineClonesHome\c5*'); LightWorker = $true }
        )
    }
    'opencode' = @{
        DisplayName    = 'OpenCode'
        WmiFamily      = "Name LIKE 'OpenCode%'"
        ProcFamily     = 'OpenCode*'
        ExePrefix      = 'OpenCode'
        PrimaryLock    = (Join-Path $env:APPDATA 'ai.opencode.desktop\lockfile')
        CloneLockProbe = { param($cloneHome) Join-Path $cloneHome 'desktop\lockfile' }
        TitleMap       = @{ 'c1' = 'OpenCode Blue'; 'c2' = 'OpenCode Yellow'; 'c3' = 'OpenCode Green'; 'c4' = 'OpenCode Red'; 'c5' = 'OpenCode Orange' }
        Instances      = @(
            @{ Key = 'c1'; Color = 'Blue';   CopyExe = 'OpenCode-Blue.exe';   CloneHomeRel = 'OpenCodeClonesHome\c1'; Markers = @('*OpenCodeClonesHome\c1*'); LightWorker = $true },
            @{ Key = 'c2'; Color = 'Yellow'; CopyExe = 'OpenCode-Yellow.exe'; CloneHomeRel = 'OpenCodeClonesHome\c2'; Markers = @('*OpenCodeClonesHome\c2*'); LightWorker = $true },
            @{ Key = 'c3'; Color = 'Green';  CopyExe = 'OpenCode-Green.exe';  CloneHomeRel = 'OpenCodeClonesHome\c3'; Markers = @('*OpenCodeClonesHome\c3*'); LightWorker = $true },
            @{ Key = 'c4'; Color = 'Red';    CopyExe = 'OpenCode-Red.exe';    CloneHomeRel = 'OpenCodeClonesHome\c4'; Markers = @('*OpenCodeClonesHome\c4*'); LightWorker = $true },
            @{ Key = 'c5'; Color = 'Orange'; CopyExe = 'OpenCode-Orange.exe'; CloneHomeRel = 'OpenCodeClonesHome\c5'; Markers = @('*OpenCodeClonesHome\c5*'); LightWorker = $true }
        )
    }
    # claude-code (the Terminal Agents pilot, 2026-11-21): a TERMINAL CLI with
    # NO desktop app and NO per-color exe copies. Its processes are node.exe
    # (npm shim) / claude.exe (native build), so the family filter is wide and
    # is narrowed by a command-line filter. Isolation is ENV-ONLY
    # (CLAUDE_CONFIG_DIR - never visible in a process command line), so clone
    # attribution rides the light-worker PID markers ALONE; unclaimed family
    # processes are the user's own default-profile claude usage (Primary,
    # honestly labeled, not GHOST-managed).
    'claudecode' = @{
        DisplayName        = 'Claude Code'
        WmiFamily          = "Name LIKE 'node%' OR Name LIKE 'claude%'"
        CmdlineFamilyFilter = '(?i)(@anthropic-ai[\\/]+claude-code)|(^|[\\/])claude(\.cmd|\.ps1|\.exe)?$'
        Attribution        = 'markers-only'
        PrimaryUsageWord   = 'claude'
        ProcFamily         = 'node*'
        ExePrefix          = 'claude'
        PrimaryLock        = ''
        CloneLockProbe     = $null
        TitleMap           = @{}
        Instances          = @(
            @{ Key = 'c1'; Color = 'Blue';   CopyExe = ''; CloneHomeRel = 'ClaudeCodeClonesHome\c1'; Markers = @(); LightWorker = $true },
            @{ Key = 'c2'; Color = 'Yellow'; CopyExe = ''; CloneHomeRel = 'ClaudeCodeClonesHome\c2'; Markers = @(); LightWorker = $true },
            @{ Key = 'c3'; Color = 'Green';  CopyExe = ''; CloneHomeRel = 'ClaudeCodeClonesHome\c3'; Markers = @(); LightWorker = $true },
            @{ Key = 'c4'; Color = 'Red';    CopyExe = ''; CloneHomeRel = 'ClaudeCodeClonesHome\c4'; Markers = @(); LightWorker = $true },
            @{ Key = 'c5'; Color = 'Orange'; CopyExe = ''; CloneHomeRel = 'ClaudeCodeClonesHome\c5'; Markers = @(); LightWorker = $true }
        )
    }
    # codex (the Terminal Agents second suite, 2026-11-21): the OpenAI Codex
    # CLI - a native Rust terminal binary reached through the npm shim
    # (codex.cmd -> node codex.js -> the vendored codex.exe). Same
    # markers-only attribution as claude-code: isolation is ENV-ONLY
    # (CODEX_HOME - never visible in a process command line; live-verified
    # 2026-11-21), so clone attribution rides the light-worker PID markers
    # ALONE; unclaimed family processes are the user's own default-profile
    # codex usage (Primary, honestly labeled, not GHOST-managed).
    'codex' = @{
        DisplayName        = 'Codex CLI'
        WmiFamily          = "Name LIKE 'node%' OR Name LIKE 'codex%'"
        CmdlineFamilyFilter = '(?i)(@openai[\\/]+codex)|(^|[\\/])codex(\.cmd|\.ps1|\.exe)?$'
        Attribution        = 'markers-only'
        PrimaryUsageWord   = 'codex'
        ProcFamily         = 'codex*'
        ExePrefix          = 'codex'
        PrimaryLock        = ''
        CloneLockProbe     = $null
        TitleMap           = @{}
        Instances          = @(
            @{ Key = 'c1'; Color = 'Blue';   CopyExe = ''; CloneHomeRel = 'CodexClonesHome\c1'; Markers = @(); LightWorker = $true },
            @{ Key = 'c2'; Color = 'Yellow'; CopyExe = ''; CloneHomeRel = 'CodexClonesHome\c2'; Markers = @(); LightWorker = $true },
            @{ Key = 'c3'; Color = 'Green';  CopyExe = ''; CloneHomeRel = 'CodexClonesHome\c3'; Markers = @(); LightWorker = $true },
            @{ Key = 'c4'; Color = 'Red';    CopyExe = ''; CloneHomeRel = 'CodexClonesHome\c4'; Markers = @(); LightWorker = $true },
            @{ Key = 'c5'; Color = 'Orange'; CopyExe = ''; CloneHomeRel = 'CodexClonesHome\c5'; Markers = @(); LightWorker = $true }
        )
    }
}

# --- shared probe helpers ----------------------------------------------------------

function Test-GhostLockState {
    # Same probe shape as diagnose_suite_pressure.ps1: an exclusive-open
    # failure = HELD = the owning instance is running.
    param([string]$LockPath)
    if (-not $LockPath -or -not (Test-Path -LiteralPath $LockPath)) { return 'absent' }
    $held = $false
    try { $fs = [System.IO.File]::Open($LockPath, 'Open', 'Read', 'None'); $fs.Close() } catch { $held = $true }
    return $(if ($held) { 'HELD' } else { 'free' })
}

function Test-GhostSubtreeMarkers {
    # BFS over the process tree by ParentProcessId; a match on ANY marker
    # pattern in ANY command line of the subtree claims the tree. Queue-based
    # walk (the 2026-11-14 fix: a PS array-slice "pop" does NOT shrink a
    # 1-element array and spins forever on leaves).
    param(
        [Parameter(Mandatory = $true)]$Proc,
        [Parameter(Mandatory = $true)][hashtable]$ByParent,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Markers
    )
    if ($Markers.Count -eq 0) { return $false }
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Proc)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($null -eq $cur -or $seen.ContainsKey([int]$cur.ProcessId)) { continue }
        $seen[[int]$cur.ProcessId] = $true
        $cmd = [string]$cur.CommandLine
        foreach ($mk in $Markers) {
            if ($cmd -like $mk) { return $true }
        }
        $kids = $ByParent[[int]$cur.ProcessId]
        if ($kids) { foreach ($k in $kids) { $queue.Enqueue($k) } }
    }
    return $false
}

function Get-GhostSuiteMains {
    <#
    .SYNOPSIS
      EC-K01 main-process selection for one suite family: empty cmdline = WMI
      race candidate; '--type=' = Electron/Tauri helper; a bare-exe command
      line (no args) = a main. Returns the main objects.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Procs,
        [Parameter(Mandatory = $true)][string]$WmiFamily
    )
    $mains = @()
    foreach ($p in $Procs) {
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { $mains += $p; continue }   # WMI race: candidate
        if ($cmd -match '--type=') { continue }
        $bare = '^\s*"?[^"]*\\' + [regex]::Escape([string]$p.Name) + '"?\s*$'
        if ($cmd -match $bare) { $mains += $p }
    }
    # NOTE: no array-wrap on the return - callers already @() the call, and a
    # wrapped return makes pipeline $_ a nested ARRAY whose member enumeration
    # yields arrays (the [int] casts then explode - caught on the first live run).
    return $mains
}

function Get-GhostMarkersOnlyState {
    <#
    .SYNOPSIS
      Attribution for suites whose clone marker is ENV-ONLY (claude-code:
      CLAUDE_CONFIG_DIR never appears in a command line). Clone rows are
      claimed by their light-worker PID marker ALONE, and the marker's
      launcher pid claims its process-tree descendants in the family
      snapshot (the CLI children spawned under that launcher) - the
      attribution stays definitive without any command-line marker.
      Unclaimed family processes are the user's own default-profile usage
      (Primary, honestly labeled - not GHOST-managed).
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Sd,
        [Parameter(Mandatory = $true)][string]$Suite,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Procs,
        [Parameter(Mandatory = $true)][string]$UserProfile
    )
    # child -> parent map for the ancestor climb
    $parentOf = @{}
    foreach ($p in $Procs) {
        if ($null -ne $p.ProcessId) { $parentOf[[int]$p.ProcessId] = [int]$p.ParentProcessId }
    }
    function Test-AncestorPid {
        param([int]$StartPid, [int]$WantPid, [hashtable]$ParentMap)
        $seen = @{}
        $cur = $StartPid
        while ($ParentMap.ContainsKey($cur) -and -not $seen.ContainsKey($cur)) {
            $seen[$cur] = $true
            if ($ParentMap[$cur] -eq $WantPid) { return $true }
            $cur = $ParentMap[$cur]
        }
        return $false
    }

    $rows = @()
    $claimed = @{}
    foreach ($inst in $Sd.Instances) {
        $signal = 'no'
        $pids = @()
        $lightWorker = '-'
        if ($inst.LightWorker) {
            $markerPath = Join-Path (Join-Path $UserProfile $inst.CloneHomeRel) '.ghost-light-worker.json'
            $lw = if (Get-Command Get-GhostLightWorkerState -ErrorAction SilentlyContinue) { Get-GhostLightWorkerState -Path $markerPath } else { $null }
            if ($lw -and $lw.Alive) {
                $lightWorker = ('YES (pid {0}, {1})' -f $lw.Pid, $lw.Mode)
                # claim the launcher's family descendants (the actual CLI
                # processes) - the launcher pid itself is not in this snapshot
                $pids = @($Procs | Where-Object { Test-AncestorPid -StartPid ([int]$_.ProcessId) -WantPid $lw.Pid -ParentMap $parentOf } |
                    ForEach-Object { [int]$_.ProcessId })
                if ($pids.Count -gt 0) { $signal = 'light worker' }
            } elseif ($lw) { $lightWorker = 'stale marker' }
        }
        foreach ($p in $pids) { $claimed[$p] = $true }
        $rows += [pscustomobject]@{
            Suite       = $Suite
            Instance    = $inst.Key
            Color       = $inst.Color
            State       = $(if ($signal -ne 'no') { 'RUNNING' } else { 'stopped' })
            Signal      = $signal
            Pids        = @($pids)
            LightWorker = $lightWorker
            Lock        = '-'
            Windows     = 0
            Note        = ''
        }
    }

    # Primary = the user's own default-profile claude usage (env isolation
    # means clones are ONLY attributable through markers)
    $unclaimed = @($Procs | Where-Object { -not $claimed.ContainsKey([int]$_.ProcessId) } | ForEach-Object { [int]$_.ProcessId })
    $rows = @([pscustomobject]@{
        Suite       = $Suite
        Instance    = 'Primary'
        Color       = ''
        State       = $(if ($unclaimed.Count -gt 0) { 'RUNNING' } else { 'stopped' })
        Signal      = $(if ($unclaimed.Count -gt 0) { 'bare main' } else { 'no' })
        Pids        = @($unclaimed)
        LightWorker = '-'
        Lock        = '-'
        Windows     = 0
        Note        = ('default-profile {0} usage (not GHOST-managed); clone attribution is light-worker-marker only' -f $(if ($Sd.PrimaryUsageWord) { $Sd.PrimaryUsageWord } else { 'app' }))
    }) + $rows

    return [pscustomobject]@{
        Suite       = $Suite
        DisplayName = $Sd.DisplayName
        Rows        = @($rows)
        FamilyCount = $Procs.Count
        MainsCount  = $Procs.Count
        WmiFamily   = $Sd.WmiFamily
        ProcFamily  = $Sd.ProcFamily
    }
}

function Get-GhostSuiteInstanceState {
    <#
    .SYNOPSIS
      The unified per-suite instance state. Honest-labeling contract:
        Signal = 'exe copy' (definitive) | 'markers' (definitive, when the
        cmdline carries clone-home/argv markers) | 'lockfile' | 'title' |
        'light worker' (definitive, markers-only suites) | 'bare main'
        (Primary only) | 'no'; anything unlabeled is reported 'unknown / no'
        with an UNCLASSIFIABLE note - never guessed.
      LightWorker is reported as its own column (a light worker and its
      desktop clone can legitimately run on the SAME clone home - one store).
    .PARAMETER Procs
      Injectable WMI-like snapshot (ProcessId/ParentProcessId/Name/CommandLine).
      Default: live Win32_Process query with the suite's family filter.
    .PARAMETER Windows
      Injectable Get-Process-like snapshot with MainWindowTitle/MainWindowHandle.
      Default: live Get-Process on the suite's process family.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('zcode', 'autoclaw2', 'cline', 'opencode', 'claudecode', 'codex')]
        [string]$Suite,
        [object[]]$Procs,
        [object[]]$Windows,
        # Test seam: override the USERPROFILE the clone homes resolve under.
        [string]$UserProfileOverride = ''
    )
    $sd = $script:GhostSuites[$Suite]
    $userProfile = if ($UserProfileOverride) { $UserProfileOverride } else {
        $up = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($up)) { $up = [Environment]::GetFolderPath('UserProfile') }
        $up
    }

    if (-not $PSBoundParameters.ContainsKey('Procs') -or $null -eq $Procs) {
        $Procs = @(Get-CimInstance Win32_Process -Filter $sd.WmiFamily -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    }
    $Procs = @($Procs)
    if (-not $PSBoundParameters.ContainsKey('Windows') -or $null -eq $Windows) {
        $Windows = @(Get-Process -Name $sd.ProcFamily -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    }
    $Windows = @($Windows)

    # Wide family filters (node.exe serves many apps) are narrowed by a
    # command-line filter BEFORE any attribution runs.
    if ($sd.CmdlineFamilyFilter) {
        $Procs = @($Procs | Where-Object {
            $n = [string]$_.Name
            $c = [string]$_.CommandLine
            (($n -and $n -match $sd.CmdlineFamilyFilter) -or ($c -and $c -match $sd.CmdlineFamilyFilter))
        })
    }

    # Env-only attribution suites (claude-code): markers own clone claims.
    if ($sd.Attribution -eq 'markers-only') {
        return Get-GhostMarkersOnlyState -Sd $sd -Suite $Suite -Procs $Procs -UserProfile $userProfile
    }

    # parent index for the marker walks
    $byParent = @{}
    foreach ($p in $Procs) {
        if ($null -eq $p.ProcessId) { continue }
        $ppid = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($ppid)) { $byParent[$ppid] = @() }
        $byParent[$ppid] += $p
    }

    $mains = @(Get-GhostSuiteMains -Procs $Procs -WmiFamily $sd.WmiFamily)

    $rows = @()
    $claimedMainIds = @{}

    # --- clone rows (copy-exe-first, then markers, then the passive signals)
    foreach ($inst in $sd.Instances) {
        $pids = @()
        $signal = 'no'
        $note = ''

        # 1) strongest: a main running FROM the clone's exe copy IS that clone
        $copyMains = @($mains | Where-Object { $_.Name -ieq $inst.CopyExe })
        if ($copyMains.Count -gt 0) {
            $pids = @($copyMains | ForEach-Object { [int]$_.ProcessId })
            $signal = 'exe copy'
        } else {
            # any family process carrying the copy exe on its command line
            # (helper-level copy evidence - still the clone's own processes)
            $copyCarriers = @($Procs | Where-Object {
                $c = [string]$_.CommandLine
                $c -and ($c -match ('(?i)' + [regex]::Escape($inst.CopyExe)))
            })
            if ($copyCarriers.Count -gt 0) {
                $pids = @($copyCarriers | ForEach-Object { [int]$_.ProcessId })
                $signal = 'exe copy'
            }
        }

        # 2) subtree markers for stock-exe mains (roaming/home/argv markers)
        if ($signal -eq 'no') {
            $matched = @($mains | Where-Object {
                -not $claimedMainIds.ContainsKey([int]$_.ProcessId) -and
                (Test-GhostSubtreeMarkers -Proc $_ -ByParent $byParent -Markers $inst.Markers)
            })
            if ($matched.Count -gt 0) {
                $pids = @($matched | ForEach-Object { [int]$_.ProcessId })
                $signal = 'markers'
            }
        }

        # 3) lockfile probe (clone)
        $lockState = '-'
        if ($sd.CloneLockProbe) {
            $cloneHome = Join-Path $userProfile $inst.CloneHomeRel
            if (Test-Path -LiteralPath $cloneHome) {
                $lockState = Test-GhostLockState -LockPath (& $sd.CloneLockProbe $cloneHome)
            } else {
                $lockState = 'absent (no clone home)'
            }
            if ($signal -eq 'no' -and $lockState -eq 'HELD') {
                $signal = 'lockfile'
            }
        }

        # 4) window title map (weak signal, only where a map exists)
        $winCount = 0
        if ($sd.TitleMap.ContainsKey($inst.Key)) {
            $wantTitle = $sd.TitleMap[$inst.Key]
            $winCount = @($Windows | Where-Object { $_.MainWindowTitle -eq $wantTitle }).Count
            if ($signal -eq 'no' -and $winCount -gt 0) { $signal = 'title' }
        }

        # honesty note: a suite with NO externally readable markers (autoclaw2
        # passes env, not argv; shared title; no lockfile) can hide a running
        # stock-exe clone - say so instead of guessing.
        if ($signal -eq 'no' -and $inst.Markers.Count -gt 0 -and $sd.TitleMap.Count -eq 0 -and -not $sd.CloneLockProbe) {
            $note = 'stock exe + no lock signal = UNCLASSIFIABLE externally'
        }

        # light-worker marker (its own column - same-home concurrency is legal)
        $lightWorker = '-'
        if ($inst.LightWorker) {
            $markerPath = Join-Path (Join-Path $userProfile $inst.CloneHomeRel) '.ghost-light-worker.json'
            $lw = if (Get-Command Get-GhostLightWorkerState -ErrorAction SilentlyContinue) { Get-GhostLightWorkerState -Path $markerPath } else { $null }
            if ($lw -and $lw.Alive) { $lightWorker = ('YES (pid {0}, {1})' -f $lw.Pid, $lw.Mode) }
            elseif ($lw) { $lightWorker = 'stale marker' }
        }

        foreach ($pid_ in $pids) { $claimedMainIds[$pid_] = $true }

        $rows += [pscustomobject]@{
            Suite       = $Suite
            Instance    = $inst.Key
            Color       = $inst.Color
            State       = $(if ($signal -ne 'no') { 'RUNNING' } else { 'stopped' })
            Signal      = $signal
            Pids        = @($pids)
            LightWorker = $lightWorker
            Lock        = $lockState
            Windows     = $winCount
            Note        = $note
        }
    }

    # --- Primary row: unmatched mains are the default-profile Primary
    $primaryPids = @($mains | Where-Object { -not $claimedMainIds.ContainsKey([int]$_.ProcessId) } | ForEach-Object { [int]$_.ProcessId })
    $primarySignal = 'no'
    $primaryNote = ''
    if ($primaryPids.Count -gt 0) {
        $primarySignal = 'bare main'
        if ($Suite -eq 'autoclaw2') {
            # env-passed clone markers are not externally readable: a bare
            # stock-exe main may be the Primary OR a clone
            $primaryNote = 'unclassified main(s) may be Primary or stock-exe clones (env-only markers)'
        }
    } elseif ($sd.PrimaryLock) {
        $pl = Test-GhostLockState -LockPath $sd.PrimaryLock
        if ($pl -eq 'HELD') { $primarySignal = 'lockfile' }
    }
    $primaryWin = 0
    if ($sd.TitleMap.Count -eq 0) {
        # suites without a clone title map: any titled window with the bare
        # app title is Primary-shaped (diagnose_suite_pressure's Primary rule)
        $primaryWin = @($Windows | Where-Object { $_.MainWindowTitle -eq $sd.ExePrefix }).Count
        if ($primarySignal -eq 'no' -and $primaryWin -gt 0) { $primarySignal = 'title' }
    }
    $rows = @([pscustomobject]@{
        Suite       = $Suite
        Instance    = 'Primary'
        Color       = ''
        State       = $(if ($primarySignal -ne 'no') { 'RUNNING' } else { 'stopped' })
        Signal      = $primarySignal
        Pids        = @($primaryPids)
        LightWorker = '-'
        Lock        = $(if ($sd.PrimaryLock) { Test-GhostLockState -LockPath $sd.PrimaryLock } else { '-' })
        Windows     = $primaryWin
        Note        = $primaryNote
    }) + $rows

    return [pscustomobject]@{
        Suite        = $Suite
        DisplayName  = $sd.DisplayName
        Rows         = @($rows)
        FamilyCount  = $Procs.Count
        MainsCount   = $mains.Count
        WmiFamily    = $sd.WmiFamily
        ProcFamily   = $sd.ProcFamily
    }
}

function Get-GhostSuiteNames {
    return @($script:GhostSuites.Keys | Sort-Object)
}
