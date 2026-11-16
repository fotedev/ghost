#Requires -Version 5.1
<#
.SYNOPSIS
  READ-ONLY per-suite instance pressure report for the AutoClaw2, Cline and
  OpenCode clone suites - the portable half of the ZCode diagnostics
  (tools\diagnose_zcode_freeze.ps1 [3] + tools\status_zcode_instances.ps1)
  generalized. ZCode keeps its dedicated tools (its log/crash formats are
  app-specific and already covered).

.DESCRIPTION
  [1] Instance table: per-clone running signals, HONESTLY labeled:
        - exe-copy match  (AutoClaw2-<Color>.exe / OpenCode-<Color>.exe /
          Cline-<Color>.exe on a live process command line) = definitive,
        - lockfile probe  (opencode <home>\desktop\lockfile, cline hub lock,
          autoclaw2 - the launcher's own probe shape) = held = running,
        - window title    (opencode clones are titled "OpenCode <Color>").
      A stock-exe AutoClaw2/Cline clone without a held lock is reported as
      UNKNOWN, never guessed (no argv markers; titles are shared).
  [2] Live memory / commit pressure (right now) - the exact block that
      caught the 2026-09-25 renderer-OOM commit-limit freeze: physical,
      commit used/limit/pct (>=90% = renderer-OOM territory), pagefiles,
      per-suite family totals.
  [3] Optional Electron log scan (-Days N, default 3): counts
      render-process-gone / child-process-gone lines in each suite's log
      dirs THAT EXIST; a dir that does not resolve prints a loud skip.
      DERIVED layouts (the apps own their log trees): autoclaw2
      %APPDATA%\AutoClaw2\logs + clone homes, opencode Primary
      %APPDATA%\ai.opencode.desktop\logs + <home>\desktop\logs, cline
      ~\.cline\data\logs + <home>\data\logs. ZCode's dedicated
      tools\diagnose_zcode_freeze.ps1 / diagnose_zcode_throttle.ps1 remain
      the authoritative ZCode diagnostics.

.Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\diagnose_suite_pressure.ps1 -Suite opencode [-Days 3]

  GHOST.bat: AutoClaw2 [24] (gid 116), Cline [20] (gid 117), OpenCode [24]
  (gid 118). Writes NOTHING (except nothing - fully read-only).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('autoclaw2', 'cline', 'opencode')]
    [string]$Suite,
    [ValidateRange(1, 30)]
    [int]$Days = 3
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$UserProfile = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserProfile)) { $UserProfile = [Environment]::GetFolderPath('UserProfile') }
$Colors = @('Blue', 'Yellow', 'Green', 'Red', 'Orange')

function Write-Hdr([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}

# --- Suite maps -----------------------------------------------------------------
$SuiteDefs = @{
    'autoclaw2' = @{
        ProcFamily  = 'AutoClaw2*'
        WmiFamily   = "Name LIKE 'AutoClaw2%'"
        ExePrefix   = 'AutoClaw2'
        CloneRoot   = Join-Path $UserProfile 'AutoClaw2ClonesHome'
        LockProbe   = { param($home_) $null }  # autoclaw2 leaves no lockfile (documented)
        PrimaryLock = ''
        TitleMap    = @{}                       # shared "AutoClaw" title - no title signal
        LogDirs     = @(
            @{ Label = 'Primary logs';    Path = Join-Path $env:APPDATA 'AutoClaw2\logs';   Provenance = 'DERIVED' }
            @{ Label = 'work logs';       Path = Join-Path $UserProfile 'AutoClaw2ClonesHome'; Provenance = 'DERIVED' }
        )
    }
    'cline' = @{
        ProcFamily  = 'Cline*'
        WmiFamily   = "Name LIKE 'Cline%'"
        ExePrefix   = 'Cline'
        CloneRoot   = Join-Path $UserProfile 'ClineClonesHome'
        LockProbe   = { param($home_) Join-Path $home_ 'data\locks\hub\production.json.instance.lock' }
        PrimaryLock = Join-Path $UserProfile '.cline\data\locks\hub\production.json.instance.lock'
        TitleMap    = @{}                       # shared "Cline vN" title - no title signal
        LogDirs     = @(
            @{ Label = 'Primary logs';    Path = Join-Path $UserProfile '.cline\data\logs'; Provenance = 'VERIFIED (reset_cline sweeps it)' }
            @{ Label = 'clone logs';      Path = Join-Path $UserProfile 'ClineClonesHome'; Provenance = 'DERIVED' }
        )
    }
    'opencode' = @{
        ProcFamily  = 'OpenCode*'
        WmiFamily   = "Name LIKE 'OpenCode%'"
        ExePrefix   = 'OpenCode'
        CloneRoot   = Join-Path $UserProfile 'OpenCodeClonesHome'
        LockProbe   = { param($home_) Join-Path $home_ 'desktop\lockfile' }
        PrimaryLock = Join-Path $env:APPDATA 'ai.opencode.desktop\lockfile'
        TitleMap    = @{ 'c1' = 'OpenCode Blue'; 'c2' = 'OpenCode Yellow'; 'c3' = 'OpenCode Green'; 'c4' = 'OpenCode Red'; 'c5' = 'OpenCode Orange' }
        LogDirs     = @(
            @{ Label = 'Primary logs';    Path = Join-Path $env:APPDATA 'ai.opencode.desktop\logs'; Provenance = 'DERIVED' }
            @{ Label = 'clone logs';      Path = Join-Path $UserProfile 'OpenCodeClonesHome'; Provenance = 'DERIVED' }
        )
    }
}
$Sd = $SuiteDefs[$Suite]

# --- [1] instance table -----------------------------------------------------------
Write-Hdr ("[1] {0} instance table (read-only signals, honestly labeled)" -f $Suite)
$famProcs = @(Get-CimInstance Win32_Process -Filter $Sd.WmiFamily -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
$wins = @(Get-Process -Name $Sd.ProcFamily -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
$copyProcs = @{}
foreach ($p in $famProcs) {
    if ($p.CommandLine) {
        foreach ($color in $Colors) {
            if ($p.CommandLine -match ('(?i)' + [regex]::Escape("$($Sd.ExePrefix)-$color.exe"))) { $copyProcs[$color] = $true }
        }
    }
}

function Test-LockState([string]$LockPath) {
    if (-not $LockPath -or -not (Test-Path -LiteralPath $LockPath)) { return 'absent' }
    $held = $false
    try { $fs = [System.IO.File]::Open($LockPath, 'Open', 'Read', 'None'); $fs.Close() } catch { $held = $true }
    return $(if ($held) { 'HELD' } else { 'free' })
}

$rows = @()
$rows += [pscustomobject]@{
    Instance = 'Primary'; Color = '-'
    ExeCopy  = '-'
    Lock     = (Test-LockState $Sd.PrimaryLock)
    Window   = $(@($wins | Where-Object { $_.MainWindowTitle -eq $Sd.ExePrefix }).Count)
    Note     = 'stock exe, base identity'
}
for ($i = 1; $i -le 5; $i++) {
    $color = $Colors[$i - 1]
    $cloneHome = Join-Path $Sd.CloneRoot "c$i"
    $lockState = '-'
    if ($Suite -eq 'autoclaw2') { $lockState = 'no lockfile (documented)' }
    elseif (Test-Path -LiteralPath $cloneHome) {
        $lp = $Sd.LockProbe.Invoke($cloneHome)
        $lockState = (Test-LockState $lp)
    }
    $winCount = 0
    if ($Sd.TitleMap.Count -gt 0) {
        $winCount = @($wins | Where-Object { $_.MainWindowTitle -eq $Sd.TitleMap["c$i"] }).Count
    }
    $running = if ($copyProcs.ContainsKey($color)) { 'YES (exe copy)' } elseif ($lockState -eq 'HELD') { 'YES (lockfile)' } elseif ($winCount -gt 0) { 'YES (title)' } else { 'unknown / no' }
    $note = if ($running -like 'YES*') { '' }
    elseif ($Suite -ne 'opencode' -and -not $copyProcs.ContainsKey($color)) { 'stock exe + no lock signal = UNCLASSIFIABLE externally' }
    else { '' }
    $rows += [pscustomobject]@{
        Instance = "c$i"; Color = $color
        ExeCopy  = $(if ($copyProcs.ContainsKey($color)) { 'live' } else { '-' })
        Lock     = $lockState
        Window   = $winCount
        Note     = $note
    }
}
$rows | Format-Table Instance, Color, ExeCopy, Lock, Window, Note -AutoSize | Out-String -Width 200 | Write-Host
Write-Host ("   family total: {0} {1} process(es), {2} with a main window" -f $famProcs.Count, $Sd.ExePrefix, $wins.Count)

# --- [2] live memory / commit pressure ---------------------------------------------
Write-Hdr '[2] Live memory / commit pressure (right now)'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    $totalGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freePhysGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $limitGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
    $usedGB = [math]::Round(($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB, 1)
    $usedPct = 0
    if ([double]$os.TotalVirtualMemorySize -gt 0) {
        $usedPct = [math]::Round(100 * ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize, 1)
    }
    Write-Host ('   physical : ' + $totalGB + ' GB total, ' + $freePhysGB + ' GB free')
    Write-Host ('   commit   : ' + $usedGB + ' GB used of ' + $limitGB + ' GB limit (' + $usedPct + '%)')
    if ($usedPct -ge 90) {
        Write-Host '              ^^^ commit pressure is HIGH right now - renderer OOM territory' -ForegroundColor Yellow
        Write-Host '              (the ZCode-verified 2026-09-25 freeze class; fix = bigger pagefile and/or fewer instances)'
    }
    $pagefiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    if ($pagefiles.Count -eq 0) {
        Write-Host '   pagefile : NONE CONFIGURED (commit limit = RAM only - primary OOM trigger)' -ForegroundColor Yellow
    } else {
        foreach ($pf in $pagefiles) {
            Write-Host ('   pagefile : ' + $pf.Name + ' - allocated ' + $pf.AllocatedBaseSize + ' MB, in use ' + $pf.CurrentUsage + ' MB, peak ' + $pf.PeakUsage + ' MB')
        }
    }
    $suiteProcs = @(Get-Process -Name $Sd.ProcFamily -ErrorAction SilentlyContinue)
    if ($suiteProcs.Count -gt 0) {
        $wsMB = [math]::Round(($suiteProcs | Measure-Object -Property WorkingSet64 -Sum).Sum / 1MB, 0)
        Write-Host ('   ' + $Sd.ExePrefix + '    : ' + $suiteProcs.Count + ' ' + $Sd.ProcFamily + ' process(es) running, ~' + $wsMB + ' MB working set total')
    } else {
        Write-Host ('   ' + $Sd.ExePrefix + '    : no ' + $Sd.ProcFamily + ' processes running right now')
    }
} else {
    Write-Host '   WMI/CIM query unavailable - skipped'
}

# --- [3] optional Electron log scan --------------------------------------------------
Write-Hdr ("[3] Electron log scan - last {0} day(s) (render/child-process-gone)" -f $Days)
foreach ($ld in $Sd.LogDirs) {
    $p = $ld.Path
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ("   {0}: {1} - ABSENT (skipped loudly; {2})" -f $ld.Label, $p, $ld.Provenance)
        continue
    }
    $cutoff = (Get-Date).AddDays(-$Days)
    # Client-side extension filter: -Include is unreliable against a bare
    # -LiteralPath dir on PS 5.1 (it swept .sqlite blobs into the scan once);
    # -Depth bounds the clone-home trees.
    $files = @(Get-ChildItem -LiteralPath $p -Recurse -File -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $cutoff -and $_.Extension -in '.log', '.txt' })
    $gone = 0
    $samples = @()
    foreach ($f in $files) {
        try {
            $hits = @(Select-String -LiteralPath $f.FullName -Pattern 'render-process-gone|child-process-gone' -ErrorAction SilentlyContinue)
            $gone += $hits.Count
            foreach ($h in ($hits | Select-Object -First 2)) { $samples += ($f.Name + ': ' + $h.Line.Trim().Substring(0, [Math]::Min(140, $h.Line.Trim().Length))) }
        } catch { }
    }
    Write-Host ("   {0}: {1} - {2} recent file(s), {3} gone-event line(s) ({4})" -f $ld.Label, $p, $files.Count, $gone, $ld.Provenance)
    foreach ($s in ($samples | Select-Object -First 4)) { Write-Host ('     ' + $s) }
}

Write-Host ''
Write-Host 'read-only report complete. For ZCode use its dedicated tools (diagnose_zcode_freeze / diagnose_zcode_throttle).' -ForegroundColor Gray
