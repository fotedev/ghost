#Requires -Version 5.1
<#
watch_zcode_taskbar.ps1 - keep every ZCode window's taskbar identity stamped.

Why this exists (verified 2026-09-24): the app's process-explicit
app.setAppUserModelId (patched into app.asar) is unreliable per-instance -
Primary merged with Second, then later with Third, despite a correct env
block and a correct patched expression. The shell honors
System.AppUserModel.ID on a window's property store with TOP precedence and
re-groups live, so this watcher reads each main window's identity and
re-stamps it whenever it is missing or wrong. It covers ALL instances
including Primary (which no launcher owns) and heals windows that get
recreated (splash swap, close/reopen) within one polling interval.

Every stamp is a KICK (brief .kick-suffixed identity, then the final one):
the shell does not always rebuild an existing group when a stamp lands on a
window it already grouped, leaving a stale icon behind (verified 2026-09-26:
a freshly launched green clone kept the Primary's icon until an Explorer
refresh). First-seen windows get one kick even when their store is already
correct - the group may predate this watcher session.

The recurring Start-menu ZCode.lnk hijack (a Windows pin from a splash-phase
clone window rewrites the Primary shortcut with a clone AUMID - and can also
empty its icon field, verified 2026-09-28) is self-healed too: a read-only
AUMID check on every 60th pass triggers the existing shortcut repair tool
(AUMID suffix stripping plus icon restore) only when a hijack is present,
then logs REPAIR or FAIL after re-checking.

Classification is by PROCESS MARKERS first: one Win32_Process snapshot per
pass, each window's process tree walked to its root ZCode.exe and the clone
markers (roaming/home dir names embedded in child --user-data-dir command
lines - same markers as the launcher) matched across the subtree. Why: a
clone's window is titled plain "ZCode" during the splash phase, and the old
title-only Primary row claimed it whenever the clone launched while no other
instance was running (verified 2026-09-24: the green clone got stamped
dev.zcode.app at 04:50:17; combined with the launcher's 15s stamp loop
expiring on slow cold starts, the taskbar button was left on the default
icon). Marker classification stamps the correct clone identity even
mid-splash. The v6 titles ("ZCode", "ZCode Blue/Yellow/Green") remain only
as the fallback when WMI is unavailable; with the app.asar patch missing all
clones share the "ZCode" title there and stamping is skipped as ambiguous
rather than guessed.

Usage:
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_zcode_taskbar.ps1            # resident watcher
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_zcode_taskbar.ps1 -RunOnce   # single pass, exit
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\watch_zcode_taskbar.ps1 -RunOnce -CheckPrimaryHijack  # single pass, also repair a Primary-shortcut hijack
  ... -InstallAutostart   # hidden shortcut in the Startup folder (survives reboots)
  ... -RemoveAutostart    # remove that shortcut

Notes:
  - The resident loop is guarded by a named mutex AND a startup process scan:
    a second copy exits at once. The scan also catches a stale copy of an
    older script version whose mutex name differs (2026-09-26: two watcher
    consoles ran at once - one was a pre-mutex-era copy behind an old window
    title no current launcher produces). -RunOnce always runs.
  - The console titles itself "ZCode Taskbar Watcher (pid N)" on start, so an
    unknown console can be identified at a glance regardless of how it was
    launched (menu, startup shortcut, manual).
  - The writer needs the same or higher integrity level as the ZCode windows
    (UIPI): a non-elevated watcher cannot stamp an elevated window and logs
    FAILED with the reason.
  - Get-Process exposes one main window per process; extra windows inside one
    instance are out of scope.
#>
param(
    [switch]$RunOnce,
    [switch]$CheckPrimaryHijack,
    [int]$IntervalSeconds = 5,
    [string]$LogFile = (Join-Path $env:LOCALAPPDATA 'watch-zcode-taskbar\taskbar.log'),
    [switch]$InstallAutostart,
    [switch]$RemoveAutostart
)

$ErrorActionPreference = 'Continue'

# Instance map: expected AppUserModel.ID + the process-tree markers that
# identify each clone (clone children embed the roaming/user-data or home dir
# name in their command lines). Primary has none: an unmarked ZCode tree IS
# Primary (same rule as the launcher's bare-exe classification). Base kept in
# sync with install_zcode_second_shortcuts.ps1 / launch_zcode_second_instance.ps1.
$Instances = @(
    @{ Name = 'Primary'; Title = 'ZCode';        Aumid = 'dev.zcode.app';   Markers = @() },
    @{ Name = 'Second';  Title = 'ZCode Blue';   Aumid = 'dev.zcode.app.2'; Markers = @('ZCode-Second', 'ZCodeSecondHome') },
    @{ Name = 'Third';   Title = 'ZCode Yellow'; Aumid = 'dev.zcode.app.3'; Markers = @('ZCode-Third',  'ZCodeThirdHome') },
    @{ Name = 'Fourth';  Title = 'ZCode Green';  Aumid = 'dev.zcode.app.4'; Markers = @('ZCode-Fourth', 'ZCodeFourthHome') }
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class ZcodeWindowAumid {
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
    [DllImport("oleaut32.dll")] public static extern int PropVariantClear(ref PROPVARIANT pv);
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
    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile -ErrorAction SilentlyContinue).Length -gt 1MB)) {
        Remove-Item -LiteralPath $LogFile -Force
    }
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    if ($Level -eq 'FAIL') { Write-Host $line -ForegroundColor Red }
    elseif ($Level -eq 'WARN') { Write-Host $line -ForegroundColor Yellow }
    elseif ($Level -eq 'STAMP') { Write-Host $line -ForegroundColor Cyan }
    else { Write-Host $line }
}

# The shell does not reliably re-evaluate an existing taskbar group when a
# stamp lands on a window it already grouped: verified 2026-09-26 twice - a
# Primary+Second group held ~1h with both stores correct, and a freshly
# launched green clone kept the Primary's icon until an Explorer refresh.
# A KICK forces the rebuild: a brief .kick-suffixed identity, then the final
# one (the 300ms gap lets the shell observe the change). Final stamp is
# verified by re-read; if the kicker dies mid-toggle the next pass re-stamps.
function Invoke-IdentityKick {
    param($Win, $Inst, [string]$Cur)
    $hwnd = $Win.MainWindowHandle
    [void][ZcodeWindowAumid]::Stamp($hwnd, "$($Inst.Aumid).kick")
    Start-Sleep -Milliseconds 300
    $got = [ZcodeWindowAumid]::Stamp($hwnd, $Inst.Aumid)
    Write-WatchLog ('{0}: pid {1} hwnd 0x{2:X} title "{3}" identity "{4}" -> kicked via "{5}.kick" -> stamped "{6}"' -f $Inst.Name, $Win.Id, [Int64]$hwnd, $Win.MainWindowTitle, $Cur, $Inst.Aumid, $got) 'STAMP'
    if ($got -ne $Inst.Aumid) {
        Write-WatchLog ('{0}: FAILED - read-back "{1}" != "{2}". If this watcher runs at a lower integrity level than the ZCode window (UIPI), run it from the same level or higher.' -f $Inst.Name, $got, $Inst.Aumid) 'FAIL'
    }
}

function Set-WindowIdentity {
    param($Win, $Inst, [switch]$FirstSeen)
    $cur = [ZcodeWindowAumid]::Read($Win.MainWindowHandle)
    if ($cur -eq $Inst.Aumid -and -not $FirstSeen) { return }
    # Missing/wrong identity is kicked too: the group formed while identity
    # was empty, so a plain final stamp would not rebuild it.
    Invoke-IdentityKick -Win $Win -Inst $Inst -Cur $cur
}

# Windows this session has already processed: a first-seen window gets one
# identity kick even when its store is already correct (covers a stale group
# the launcher pinned before this watcher started; -RunOnce heals live
# windows the same way).
$SeenHwnds = @{}

# One WMI snapshot per pass, keyed by pid, with parent->children links so the
# subtree walks below never re-query.
function Get-ZcodeProcessMap {
    $map = @{}
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ZCode.exe'" -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    foreach ($p in $procs) {
        $map[[int]$p.ProcessId] = @{ Parent = [int]$p.ParentProcessId; Cmdline = [string]$p.CommandLine; Children = @() }
    }
    foreach ($p in $procs) {
        $par = [int]$p.ParentProcessId
        if ($map.ContainsKey($par)) { $map[$par].Children = @($map[$par].Children) + [int]$p.ProcessId }
    }
    return $map
}

# Classify a window's instance by walking its process tree to the root ZCode
# main and matching clone markers across the whole subtree's command lines
# (a clone main carries a bare exe command line; its children carry
# --user-data-dir=...\ZCode-Fourth\... etc). A just-spawned clone main can
# beat WMI (children not enumerated yet) and classify as Primary for one
# pass; the v6-title guard in Invoke-IdentityPass and the next pass's
# re-stamp both self-heal that within one interval.
function Get-WindowInstance {
    param($ProcMap, [int]$ProcessId)
    if (-not $ProcMap -or -not $ProcMap.ContainsKey($ProcessId)) { return $null }
    $root = $ProcessId
    $climbed = @{}
    while ($ProcMap.ContainsKey($root)) {
        if ($climbed.ContainsKey($root)) { break }
        $climbed[$root] = $true
        $par = [int]$ProcMap[$root].Parent
        if (-not $ProcMap.ContainsKey($par)) { break }
        $root = $par
    }
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
                    if ($cl -like ("*{0}*" -f $marker)) { return $inst }
                }
            }
        }
        foreach ($child in $node.Children) { $queue.Enqueue($child) }
    }
    # Whole tree unmarked: per the launcher's rule, unmatched mains are Primary.
    return $Instances[0]
}

function Invoke-IdentityPass {
    $wins = @(Get-Process -Name ZCode -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($wins.Count -eq 0) { return }
    $procMap = Get-ZcodeProcessMap
    $classified = @()
    $unknownWins = @()
    foreach ($w in $wins) {
        $inst = Get-WindowInstance -ProcMap $procMap -ProcessId $w.Id
        if ($inst) {
            $firstSeen = -not $SeenHwnds.ContainsKey([Int64]$w.MainWindowHandle)
            $SeenHwnds[[Int64]$w.MainWindowHandle] = $true
            # WMI race guard: a just-spawned clone tree can classify as Primary
            # before its children exist, but a window already carrying a clone's
            # v6 title can never be Primary - the title wins there.
            if ($inst.Name -eq 'Primary') {
                foreach ($cand in $Instances) {
                    if ($cand.Name -ne 'Primary' -and $cand.Title -eq $w.MainWindowTitle) {
                        Write-WatchLog ("{0}: pid {1} markers said Primary but title is '{2}' - trusting title" -f $cand.Name, $w.Id, $w.MainWindowTitle) 'WARN'
                        $inst = $cand
                        break
                    }
                }
            }
            $classified += ,@($w, $inst, $firstSeen)
        } else {
            $unknownWins += $w
        }
    }
    foreach ($pair in $classified) {
        Set-WindowIdentity -Win $pair[0] -Inst $pair[1] -FirstSeen:$pair[2]
    }
    # WMI unavailable for these pids: v6-title fallback (ambiguous -> skip
    # loudly, never guessed).
    foreach ($inst in $Instances) {
        $hits = @($unknownWins | Where-Object { $_.MainWindowTitle -eq $inst.Title })
        if ($hits.Count -eq 0) { continue }
        if ($hits.Count -gt 1) {
            Write-WatchLog ("{0}: {1} windows titled '{2}' - ambiguous (app.asar patch missing?), stamping skipped" -f $inst.Name, $hits.Count, $inst.Title) 'WARN'
            continue
        }
        $firstSeen = -not $SeenHwnds.ContainsKey([Int64]$hits[0].MainWindowHandle)
        $SeenHwnds[[Int64]$hits[0].MainWindowHandle] = $true
        Set-WindowIdentity -Win $hits[0] -Inst $inst -FirstSeen:$firstSeen
    }
}

$script:HijackCheckPass = 0

# Read-only check for the recurring Primary-shortcut hijack: every per-user
# ZCode.lnk whose AUMID ends in ".<N>" hands the clone's icon resolution to a
# foreign shortcut (verified 2026-09-28: green-alone showed the Primary icon
# while its window identity was already correct).
function Get-PrimaryLnkHijack {
    $paths = @(
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ZCode.lnk'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk'),
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk')
    )
    $shell = $null
    try { $shell = New-Object -ComObject Shell.Application } catch { return @() }
    $hijacked = @()
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $ns = $shell.Namespace((Split-Path -Parent $p))
        if (-not $ns) { continue }
        $item = $ns.ParseName((Split-Path -Leaf $p))
        if (-not $item) { continue }
        $id = [string]$item.ExtendedProperty('System.AppUserModel.ID')
        if ($id -match '\.\d+$') {
            $hijacked += [pscustomobject]@{ Path = $p; Aumid = $id }
        }
    }
    return $hijacked
}

# Repair check throttled by pass count (60 passes ~5 minutes at the default
# 5s interval). Writes happen only after a read finds a hijack; the canonical
# shortcut tool performs and verify-afters the repair (AUMID plus icon).
function Invoke-PrimaryHijackGuard {
    param([int]$EveryPasses = 60, [switch]$Repair)
    $script:HijackCheckPass++
    if ($EveryPasses -gt 1 -and (($script:HijackCheckPass % $EveryPasses) -ne 0)) { return }
    $hits = @(Get-PrimaryLnkHijack)
    if ($hits.Count -eq 0) { return }
    foreach ($hit in $hits) {
        Write-WatchLog ('Primary shortcut hijack detected: {0} carries "{1}"' -f $hit.Path, $hit.Aumid) 'WARN'
    }
    if (-not $Repair) {
        Write-WatchLog 'hijack check only (no -Repair): run -RunOnce -CheckPrimaryHijack or keep the resident watcher running to self-heal it' 'WARN'
        return
    }
    try {
        $repair = Join-Path $PSScriptRoot 'install_zcode_second_shortcuts.ps1'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $repair -RepairPrimaryAumid 2>&1 | Out-String
        if (-not [string]::IsNullOrWhiteSpace($out)) {
            $repairDir = Split-Path -Parent $LogFile
            if (-not (Test-Path -LiteralPath $repairDir)) { New-Item -ItemType Directory -Path $repairDir -Force | Out-Null }
            Add-Content -LiteralPath $LogFile -Value ($out.Trim()) -Encoding UTF8
        }
    } catch {
        Write-WatchLog ('hijack repair launch FAILED: {0}' -f $_.Exception.Message) 'FAIL'
        return
    }
    $still = @(Get-PrimaryLnkHijack)
    if ($still.Count -eq 0) {
        Write-WatchLog 'Primary shortcut hijack repaired (AUMID plus icon). Re-check the taskbar buttons; an Explorer/icon refresh may still be required once.' 'REPAIR'
    } else {
        foreach ($hit in $still) {
            Write-WatchLog ('hijack repair FAILED - {0} still carries "{1}"' -f $hit.Path, $hit.Aumid) 'FAIL'
        }
    }
}

# ---- Autostart management (Startup-folder shortcut, no registry) ----
if ($InstallAutostart -or $RemoveAutostart) {
    $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'ZCode taskbar identity.lnk'
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
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    $sc.WorkingDirectory = Split-Path -Parent $PSCommandPath
    $sc.Description = 'Keeps ZCode window taskbar identities stamped (anti-merge watcher)'
    $sc.Save()
    # verify-after re-read (never silent-success)
    $chk = $shell.CreateShortcut($lnkPath)
    if ($chk.TargetPath -eq $sc.TargetPath -and $chk.Arguments -eq $sc.Arguments) {
        Write-WatchLog "autostart installed: $lnkPath"
    } else {
        Write-WatchLog "autostart INSTALL FAILED - read-back mismatch on $lnkPath" 'FAIL'
    }
    exit 0
}

# ---- Resident / one-shot loop ----
if ($RunOnce) {
    Invoke-IdentityPass
    Invoke-PrimaryHijackGuard -EveryPasses 1 -Repair:$CheckPrimaryHijack
    Write-WatchLog 'single pass complete (-RunOnce)'
    exit 0
}

# Resident console title: makes the window self-identifying no matter how it
# was launched - the stale second copy on 2026-09-26 hid behind an old
# launcher title that no current script or shortcut produces.
try { $Host.UI.RawUI.WindowTitle = 'ZCode Taskbar Watcher (pid {0})' -f $PID } catch { }

# Process scan on top of the mutex: the mutex only serializes copies of THIS
# script version - a stale older copy (different or absent mutex name) would
# co-run silently forever. Matched by script file name so relative and
# absolute -File paths both hit; own pid excluded.
function Get-OtherWatcherPids {
    $leaf = (Split-Path -Leaf $PSCommandPath).ToLowerInvariant()
    $found = @()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
    foreach ($p in $procs) {
        if ([int]$p.ProcessId -eq $PID) { continue }
        if ($p.CommandLine -and $p.CommandLine.ToLowerInvariant().Contains($leaf)) { $found += [int]$p.ProcessId }
    }
    return $found
}

$others = Get-OtherWatcherPids
if ($others.Count -gt 0) {
    Write-WatchLog ('watcher already running (pid {0}) - exiting. Close that console or stop the pid first.' -f ($others -join ', ')) 'WARN'
    exit 0
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ZcodeTaskbarIdentityWatcher', [ref]$created)
if (-not $created) {
    $holder = Get-OtherWatcherPids
    $who = ''
    if ($holder.Count -gt 0) { $who = ' by pid ' + ($holder -join ', ') }
    Write-WatchLog ('watcher already running (mutex held{0}) - exiting. Check the log or Task Manager.' -f $who) 'WARN'
    $mutex.Close()
    exit 0
}
Write-WatchLog ('watcher started (pid {0}, interval {1}s, script {2})' -f $PID, $IntervalSeconds, $PSCommandPath)
try {
    while ($true) {
        Invoke-IdentityPass
        Invoke-PrimaryHijackGuard -Repair
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Close()
    Write-WatchLog 'watcher stopped'
}
