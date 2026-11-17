#Requires -Version 5.1
<#
.SYNOPSIS
  Resident suite taskbar-identity watcher - the ZCode watcher
  (tools\watch_zcode_taskbar.ps1) mechanics generalized to the AutoClaw2 and
  OpenCode clone suites. Re-stamps System.AppUserModel.ID on RUNNING windows
  that lost or carry wrong identity, and periodically heals a hijacked
  Primary .lnk. Cline is deliberately NOT a suite here (its plan forbids a
  resident watcher - the launcher's one-time stamp covers it; CS-2).

.CLASSIFICATION (per window, first match wins)
  1. Per-color exe copy on the root command line (AutoClaw2-<Color>.exe /
     OpenCode-<Color>.exe; deterministic even mid-splash - the 2026-11-11
     ZCode copy-family lesson).
  2. Command-line markers across the window's process tree:
       opencode  -> "--opencode-clone-home=...\OpenCodeClonesHome\cN"
       autoclaw2 -> (none - the launcher passes env, not argv)
  3. Title map (opencode only: the identity patch titles windows
     "OpenCode <Color>").
  4. Anything unmarked = the suite's Primary (bare-launch rule) - stamped
     with the BASE AUMID only when the store is empty/wrong.

  HONEST LIMIT (documented, not hidden): an AutoClaw2 clone on the STOCK exe
  has no argv markers and a shared window title, so it is UNCLASSIFIABLE
  externally; such windows are logged once (cooldown) and skipped. They keep
  identity through the in-app env-driven patch (gid 78) + the launcher kick;
  build the per-color exe copies (gid 105) for watcher coverage.

  For AutoClaw2 windows with copies present: the in-app patch stamps the
  process AUMID - a window-level stamp still wins per-window (the ZCode
  2026-09-24 lesson), so the watcher's re-stamp is the backstop.

.PRIMARY LNK HIJACK GUARD
  Every 60 passes (~5 min): the suite's Primary shortcut(s) on the Desktop +
  Start menu are read (Shell ExtendedProperty); an AUMID equal to a CLONE's
  (ai.opencode.desktop.cN / com.zhipuai.autoclaw2.cN) = hijack - repaired by
  shelling out to the suite's own installer -RepairPrimaryAumid (console-less
  child, 120s cap, verify-after re-read). ZCode's richer predicate (target/
  icon drift) stays in its dedicated lib.

.Usage
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_suite_taskbar.ps1 -Suite opencode [-RunOnce] [-IntervalSeconds 5]
        [-InstallAutostart | -RemoveAutostart]

  GHOST.bat: AutoClaw2 [23] (gid 114) and OpenCode [23] (gid 115).
  Logs: %LOCALAPPDATA%\watch-<suite>-taskbar\taskbar.log

.Notes
  - Single instance per suite: named mutex <Suite>TaskbarIdentityWatcher +
    startup process scan (the pre-mutex-copy lesson).
  - The writer needs the same or higher integrity level as the windows
    (UIPI): a non-elevated watcher cannot stamp an elevated window and logs
    FAILED with the reason.
  - Get-Process exposes one main window per process; extra windows inside
    one instance are out of scope.
  - No admin needed. Never elevated on purpose.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('autoclaw2', 'opencode')]
    [string]$Suite,
    [switch]$RunOnce,
    [int]$IntervalSeconds = 5,
    [string]$LogFile = '',
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart
)

$ErrorActionPreference = 'Continue'

# --- Suite maps (AUMIDs in sync with the installers + launchers) --------------
$SuiteDefs = @{
    'autoclaw2' = @{
        BaseAumid       = 'com.zhipuai.autoclaw2'
        WmiFamily       = "Name LIKE 'AutoClaw2%'"
        ProcFamily      = 'AutoClaw2*'
        LogSubDir       = 'watch-autoclaw2-taskbar'
        Mutex           = 'Autoclaw2TaskbarIdentityWatcher'
        AutostartLnk    = 'AutoClaw2 taskbar identity.lnk'
        RepairScript    = 'install_autoclaw2_clone_shortcuts.ps1'
        PrimaryLnkNames = @('AutoClaw2.lnk')
        # Windows titled "AutoClaw" for EVERY instance (patch does not touch
        # titles) - no title map; classification = exe copies only.
        TitleMap        = @{}
    }
    'opencode' = @{
        BaseAumid       = 'ai.opencode.desktop'
        WmiFamily       = "Name LIKE 'OpenCode%'"
        ProcFamily      = 'OpenCode*'
        LogSubDir        = 'watch-opencode-taskbar'
        Mutex           = 'OpencodeTaskbarIdentityWatcher'
        AutostartLnk    = 'OpenCode taskbar identity.lnk'
        RepairScript    = 'install_opencode_clone_shortcuts.ps1'
        PrimaryLnkNames = @('OpenCode.lnk')
        # The identity patch titles windows "OpenCode <Color>" - unique,
        # title classification is unambiguous for single hits.
        TitleMap        = @{ 'OpenCode Blue' = 'c1'; 'OpenCode Yellow' = 'c2'; 'OpenCode Green' = 'c3'; 'OpenCode Red' = 'c4'; 'OpenCode Orange' = 'c5' }
    }
}
$Sd = $SuiteDefs[$Suite]
if (-not $LogFile) { $LogFile = Join-Path $env:LOCALAPPDATA (Join-Path $Sd.LogSubDir 'taskbar.log') }

$Colors = @('Blue', 'Yellow', 'Green', 'Red', 'Orange')
$Instances = @(
    @{ Name = 'Primary'; Aumid = $Sd.BaseAumid; ExeName = $null; Markers = @() }
)
for ($i = 1; $i -le 5; $i++) {
    $color = $Colors[$i - 1]
    # argv markers exist ONLY for opencode (the --opencode-clone-home flag);
    # autoclaw2 passes env, not argv, so classification there = exe copies.
    $markers = @()
    if ($Suite -eq 'opencode') { $markers = @("OpenCodeClonesHome\c$i") }
    $Instances += @{
        Name    = "c$i"
        Aumid   = "$($Sd.BaseAumid).c$i"
        ExeName = "$($Sd.ProcFamily.TrimEnd('*'))-$color.exe"
        Markers = $markers
    }
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class SuiteWindowAumid {
    [StructLayout(LayoutKind.Sequential)] public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit)]
    public struct PROPVARIANT {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;
        [FieldOffset(8)] public long longValue;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PROPERTYKEY pkey);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT pv);
        void Commit();
    }
    [DllImport("shell32.dll")] public static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    // oleaut32 dropped this export in Win10 19041.7548 (2026-07 CU) - ole32 keeps it
    [DllImport("ole32.dll")] public static extern int PropVariantClear(ref PROPVARIANT pv);
    public static readonly PROPERTYKEY PKEY_AUMID = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    static Guid IID_IPropertyStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    // Stamp + read back; returns what the store actually holds.
    public static string Stamp(IntPtr hwnd, string aumid) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        IntPtr pStr = Marshal.StringToCoTaskMemUni(aumid);
        try {
            PROPVARIANT pv = new PROPVARIANT();
            pv.vt = 31; // VT_LPWSTR
            pv.pointerValue = pStr;
            var key = PKEY_AUMID;
            store.SetValue(ref key, ref pv);
            store.Commit();
        } finally { Marshal.FreeCoTaskMem(pStr); }
        return Read(hwnd);
    }
    public static string Read(IntPtr hwnd) {
        IPropertyStore store;
        int hr = SHGetPropertyStoreForWindow(hwnd, ref IID_IPropertyStore, out store);
        if (hr != 0) return "<hr=0x" + hr.ToString("X") + ">";
        PROPVARIANT back;
        var key = PKEY_AUMID;
        store.GetValue(ref key, out back);
        // VT_LPWSTR is CoTaskMem-allocated by the property store: copy the
        // string out first, then free the variant, or the resident watcher
        // leaks on every 5 s read.
        string result;
        if (back.vt == 31) result = Marshal.PtrToStringUni(back.pointerValue);
        else if (back.vt == 0) result = "<EMPTY>";
        else result = "<readback vt=" + back.vt + ">";
        PropVariantClear(ref back);
        return result;
    }
}
"@

function Write-WatchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path -Parent $LogFile
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length -gt 1MB)) {
            Remove-Item -LiteralPath $LogFile -Force
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch {
        Write-Host "[LOG-FAIL] $line" -ForegroundColor Yellow
    }
    if ($Level -eq 'FAIL') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'STAMP') { Write-Host $line -ForegroundColor Cyan }
    else { Write-Host $line }
}

# The shell does not reliably re-evaluate an existing taskbar group when a
# stamp lands on a window it already grouped (the ZCode 2026-09-26 lesson):
# a brief .kick-suffixed identity, then the final one; final stamp verified
# by re-read.
function Invoke-IdentityKick {
    param($Win, $Inst, [string]$Cur)
    $hwnd = $Win.MainWindowHandle
    [void][SuiteWindowAumid]::Stamp($hwnd, "$($Inst.Aumid).kick")
    Start-Sleep -Milliseconds 300
    $got = [SuiteWindowAumid]::Stamp($hwnd, $Inst.Aumid)
    Write-WatchLog ('{0}: pid {1} hwnd 0x{2:X} title "{3}" identity "{4}" -> kicked -> stamped "{5}"' -f $Inst.Name, $Win.Id, [Int64]$hwnd, $Win.MainWindowTitle, $Cur, $got) 'STAMP'
    if ($got -ne $Inst.Aumid) {
        Write-WatchLog ('{0}: FAILED - read-back "{1}" != "{2}". If this watcher runs at a lower integrity level than the window (UIPI), run it from the same level or higher.' -f $Inst.Name, $got, $Inst.Aumid) 'FAIL'
    }
}

function Set-WindowIdentity {
    param($Win, $Inst, [switch]$FirstSeen)
    $cur = [SuiteWindowAumid]::Read($Win.MainWindowHandle)
    if ($cur -eq $Inst.Aumid -and -not $FirstSeen) { return }
    Invoke-IdentityKick -Win $Win -Inst $Inst -Cur $cur
}

$SeenHwnds = @{}
$WarnedUnclassifiable = @{}

function Get-SuiteProcessMap {
    # Whole copy family (stock exe + per-color copies).
    $map = @{}
    $procs = @(Get-CimInstance Win32_Process -Filter $Sd.WmiFamily -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    foreach ($p in $procs) {
        $map[[int]$p.ProcessId] = @{ Parent = [int]$p.ParentProcessId; Cmdline = [string]$p.CommandLine; Children = @() }
    }
    foreach ($p in $procs) {
        $par = [int]$p.ParentProcessId
        if ($map.ContainsKey($par)) { $map[$par].Children = @($map[$par].Children) + [int]$p.ProcessId }
    }
    return $map
}

function Get-WindowInstance {
    param($ProcMap, [int]$ProcessId)
    if (-not $ProcMap -or -not $ProcMap.ContainsKey($ProcessId)) { return 'unknown' }
    $root = $ProcessId
    $climbed = @{}
    while ($ProcMap.ContainsKey($root)) {
        if ($climbed.ContainsKey($root)) { break }
        $climbed[$root] = $true
        $par = [int]$ProcMap[$root].Parent
        if (-not $ProcMap.ContainsKey($par)) { break }
        $root = $par
    }
    # Copy-exe identity FIRST (deterministic even mid-splash).
    if ($ProcMap.ContainsKey($root)) {
        $rootCl = $ProcMap[$root].Cmdline
        if ($rootCl) {
            foreach ($inst in $Instances) {
                if ($inst.ExeName -and ($rootCl -match ('(?i)' + [regex]::Escape($inst.ExeName)))) { return $inst }
            }
        }
    }
    # Marker walk across the whole subtree (opencode: --opencode-clone-home).
    $seen = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        $node = $ProcMap[$cur]
        if (-not $node) { continue }
        $cl = $node.Cmdline
        if ($cl) {
            foreach ($inst in $Instances) {
                foreach ($marker in $inst.Markers) {
                    if ($marker -and ($cl -like ("*{0}*" -f $marker))) { return $inst }
                }
            }
        }
        foreach ($child in $node.Children) { $queue.Enqueue($child) }
    }
    # Whole tree unmarked: bare-launch rule = the suite Primary.
    return $Instances[0]
}

function Invoke-IdentityPass {
    $wins = @(Get-Process -Name $Sd.ProcFamily -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($wins.Count -eq 0) {
        if ($SeenHwnds.Count -gt 0) { $SeenHwnds.Clear() }
        return
    }
    $procMap = Get-SuiteProcessMap
    $classified = @()
    $unknownWins = @()
    foreach ($w in $wins) {
        $inst = Get-WindowInstance -ProcMap $procMap -ProcessId $w.Id
        if ($inst -eq 'unknown') { $unknownWins += $w; continue }
        # Marker/title said Primary but this is really an unclassifiable clone?
        # A Primary with an EMPTY store is normal (apps self-stamp base) - the
        # stamp below only fires when the store is wrong. AutoClaw2 clones on
        # the stock exe classify as Primary (no markers, shared title) - the
        # honesty rule: if the store reads a CLONE AUMID, the Primary verdict
        # is wrong; log and skip (never re-stamp a probable clone to base).
        if ($inst.Name -eq 'Primary') {
            $cur = [SuiteWindowAumid]::Read($w.MainWindowHandle)
            $cloneAumids = @($Instances | Where-Object { $_.Name -ne 'Primary' } | ForEach-Object { $_.Aumid })
            if ($cloneAumids -contains $cur) {
                if (-not $WarnedUnclassifiable.ContainsKey([Int64]$w.MainWindowHandle)) {
                    $WarnedUnclassifiable[[Int64]$w.MainWindowHandle] = $true
                    Write-WatchLog ("pid {0} hwnd 0x{1:X} carries clone identity '{2}' but classifies as Primary (stock-exe AutoClaw2 clone: no argv markers, shared title) - left alone (run gid {3} copies for watcher coverage)" -f $w.Id, [Int64]$w.MainWindowHandle, $cur, $(if ($Suite -eq 'autoclaw2') { 105 } else { 107 })) 'WARN'
                }
                continue
            }
        }
        $firstSeen = -not $SeenHwnds.ContainsKey([Int64]$w.MainWindowHandle)
        $SeenHwnds[[Int64]$w.MainWindowHandle] = $true
        # Title-map race guard (opencode): markers said Primary but the window
        # carries a clone title - the title wins.
        if ($inst.Name -eq 'Primary' -and $Sd.TitleMap.Count -gt 0) {
            foreach ($title in $Sd.TitleMap.Keys) {
                if ($w.MainWindowTitle -eq $title) {
                    $cand = $Instances | Where-Object { $_.Name -eq ($Sd.TitleMap[$title] -replace '^c', 'c') } | Select-Object -First 1
                    if ($cand) {
                        Write-WatchLog ("{0}: pid {1} markers said Primary but title is '{2}' - trusting title" -f $cand.Name, $w.Id, $title) 'WARN'
                        $inst = $cand
                    }
                    break
                }
            }
        }
        $classified += ,@($w, $inst, $firstSeen)
    }
    foreach ($pair in $classified) {
        Set-WindowIdentity -Win $pair[0] -Inst $pair[1] -FirstSeen:$pair[2]
    }
    # WMI unavailable for these pids: title-map fallback (opencode only;
    # ambiguous -> skip loudly, never guessed).
    foreach ($entry in $Sd.TitleMap.GetEnumerator()) {
        $inst = $Instances | Where-Object { $_.Name -eq $entry.Value } | Select-Object -First 1
        if (-not $inst) { continue }
        $hits = @($unknownWins | Where-Object { $_.MainWindowTitle -eq $entry.Key })
        if ($hits.Count -eq 0) { continue }
        if ($hits.Count -gt 1) {
            Write-WatchLog ("{0}: {1} windows titled '{2}' - ambiguous (identity patch missing?), stamping skipped" -f $inst.Name, $hits.Count, $entry.Key) 'WARN'
            continue
        }
        $firstSeen = -not $SeenHwnds.ContainsKey([Int64]$hits[0].MainWindowHandle)
        $SeenHwnds[[Int64]$hits[0].MainWindowHandle] = $true
        Set-WindowIdentity -Win $hits[0] -Inst $inst -FirstSeen:$firstSeen
    }
    # Prune seen-hwnd bookkeeping to live windows (hwnd value reuse).
    $liveHwnds = @{}
    foreach ($w in $wins) { $liveHwnds[[Int64]$w.MainWindowHandle] = $true }
    foreach ($h in @($SeenHwnds.Keys)) {
        if (-not $liveHwnds.ContainsKey([Int64]$h)) { $SeenHwnds.Remove($h) }
        if (-not $liveHwnds.ContainsKey([Int64]$h)) { $WarnedUnclassifiable.Remove($h) }
    }
}

# ---- Primary .lnk hijack guard ------------------------------------------------
$script:HijackCheckPass = 0
$RepairScriptPath = Join-Path $PSScriptRoot $Sd.RepairScript
if (-not (Test-Path -LiteralPath $RepairScriptPath)) { throw "repair script not found: $RepairScriptPath" }

function Get-SuitePrimaryLnkHijack {
    $shell = $null
    try { $shell = New-Object -ComObject Shell.Application } catch { return @() }
    $dirs = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('Programs'),
        [Environment]::GetFolderPath('CommonPrograms')
    )
    $cloneAumids = @($Instances | Where-Object { $_.Name -ne 'Primary' } | ForEach-Object { $_.Aumid })
    $hijacked = @()
    foreach ($dir in $dirs) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($name in $Sd.PrimaryLnkNames) {
            $p = Join-Path $dir $name
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $ns = $shell.Namespace($dir)
            if (-not $ns) { continue }
            $item = $ns.ParseName($name)
            if (-not $item) { continue }
            $id = [string]$item.ExtendedProperty('System.AppUserModel.ID')
            if ($cloneAumids -contains $id) {
                $hijacked += [pscustomobject]@{ Path = $p; Aumid = $id; Reason = "AUMID is a clone identity ($id)" }
            }
        }
    }
    return $hijacked
}

function Invoke-PrimaryHijackGuard {
    param([int]$EveryPasses = 60)
    $script:HijackCheckPass++
    if (($script:HijackCheckPass % $EveryPasses) -ne 0) { return }
    $hits = @(Get-SuitePrimaryLnkHijack)
    if ($hits.Count -eq 0) { return }
    foreach ($hit in $hits) { Write-WatchLog ("Primary lnk hijacked: {0} ({1}) - invoking the installer repair" -f $hit.Path, $hit.Reason) 'WARN' }
    if ($RunOnce) { return }
    $PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $PsExe
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $RepairScriptPath + '" -RepairPrimaryAumid'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit(120000)) {
            try { $proc.Kill() } catch { }
            Write-WatchLog 'hijack repair child timed out after 120s - killed' 'FAIL'
        }
        # Verify-after re-read (never silent-success).
        $still = @(Get-SuitePrimaryLnkHijack)
        if ($still.Count -eq 0) {
            Write-WatchLog 'Primary shortcut hijack repaired (AUMID). An Explorer/icon refresh may still be required once.' 'REPAIR'
        } else {
            foreach ($hit in $still) { Write-WatchLog ('hijack repair FAILED - {0} still: {1}' -f $hit.Path, $hit.Reason) 'FAIL' }
        }
    } catch {
        Write-WatchLog ('hijack repair launch FAILED: {0}' -f $_.Exception.Message) 'FAIL'
    }
}

# ---- Autostart management (Startup-folder shortcut, no registry) ------------
if ($InstallAutostart -or $RemoveAutostart) {
    $PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) $Sd.AutostartLnk
    if ($RemoveAutostart) {
        if (Test-Path -LiteralPath $lnkPath) {
            Remove-Item -LiteralPath $lnkPath -Force
            if (Test-Path -LiteralPath $lnkPath) { Write-WatchLog "autostart REMOVE FAILED - $lnkPath still exists" 'FAIL' }
            else { Write-WatchLog "autostart removed: $lnkPath" }
        } else {
            Write-WatchLog "autostart already absent: $lnkPath" 'WARN'
        }
        exit 0
    }
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnkPath)
    $sc.TargetPath = $PsExe
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Suite {1}' -f $PSCommandPath, $Suite
    $sc.WorkingDirectory = Split-Path -Parent $PSCommandPath
    $sc.Description = "Resident $Suite taskbar-identity watcher (re-stamps window AUMIDs, heals Primary lnk hijacks)"
    $sc.Save()
    $chk = $shell.CreateShortcut($lnkPath)
    if ($chk.TargetPath -eq $sc.TargetPath -and $chk.Arguments -eq $sc.Arguments) {
        Write-WatchLog "autostart installed: $lnkPath"
    } else {
        Write-WatchLog "autostart INSTALL FAILED - read-back mismatch on $lnkPath" 'FAIL'
    }
    exit 0
}

# ---- One-shot / resident ----------------------------------------------------
if ($RunOnce) {
    Write-WatchLog ("one-shot identity pass starting (suite {0})" -f $Suite)
    Invoke-IdentityPass
    Invoke-PrimaryHijackGuard -EveryPasses 1
    Write-WatchLog 'single pass complete (-RunOnce)'
    exit 0
}

try { $Host.UI.RawUI.WindowTitle = '{0} Taskbar Watcher (pid {1})' -f $Sd.ProcFamily.TrimEnd('*'), $PID } catch { }

function Get-OtherWatcherPids {
    $leaf = (Split-Path -Leaf $PSCommandPath).ToLowerInvariant()
    $suiteArg = "-suite $Suite"
    $found = @()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        $cl = ""
        if ($p.CommandLine) { $cl = $p.CommandLine.ToLowerInvariant() }
        if (-not $cl.Contains($leaf)) { continue }
        if (-not $cl.Contains($suiteArg)) { continue }
        if ($cl.Contains("-runonce")) { continue }
        $found += [int]$p.ProcessId
    }
    return $found
}

$others = Get-OtherWatcherPids
if ($others.Count -gt 0) {
    Write-WatchLog ('watcher already running for this suite (pid {0}) - exiting. Close that console or stop the pid first.' -f ($others -join ', ')) 'WARN'
    exit 0
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, $Sd.Mutex, [ref]$created)
if (-not $created) {
    $holder = Get-OtherWatcherPids
    $who = ''
    if ($holder.Count -gt 0) { $who = ' by pid ' + ($holder -join ', ') }
    Write-WatchLog ('watcher already running (mutex held{0}) - exiting. Check the log or Task Manager.' -f $who) 'WARN'
    $mutex.Close()
    exit 0
}
Write-WatchLog ('watcher started (suite {0}, pid {1}, interval {2}s, script {3})' -f $Suite, $PID, $IntervalSeconds, $PSCommandPath)
try {
    while ($true) {
        try { Invoke-IdentityPass } catch { Write-WatchLog ("identity pass FAILED: {0}" -f $_.Exception.Message) 'FAIL' }
        try { Invoke-PrimaryHijackGuard } catch { Write-WatchLog ("hijack guard FAILED: {0}" -f $_.Exception.Message) 'FAIL' }
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Close()
    Write-WatchLog 'watcher stopped'
}
