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
  ... -InstallAutostart   # hidden shortcut in the Startup folder (survives reboots)
  ... -RemoveAutostart    # remove that shortcut

Notes:
  - The resident loop is guarded by a named mutex; a second copy exits at once
    (check the log / Task Manager for the running one). -RunOnce always runs.
  - The writer needs the same or higher integrity level as the ZCode windows
    (UIPI): a non-elevated watcher cannot stamp an elevated window and logs
    FAILED with the reason.
  - Get-Process exposes one main window per process; extra windows inside one
    instance are out of scope.
#>
param(
    [switch]$RunOnce,
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
        if (back.vt == 31) return Marshal.PtrToStringUni(back.pointerValue);
        if (back.vt == 0) return "<EMPTY>";
        return "<readback vt=" + back.vt + ">";
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

function Set-WindowIdentity {
    param($Win, $Inst)
    $cur = [ZcodeWindowAumid]::Read($Win.MainWindowHandle)
    if ($cur -eq $Inst.Aumid) { return }
    $got = [ZcodeWindowAumid]::Stamp($Win.MainWindowHandle, $Inst.Aumid)
    Write-WatchLog ('{0}: pid {1} hwnd 0x{2:X} title "{3}" identity was "{4}" -> stamped "{5}"' -f $Inst.Name, $Win.Id, [Int64]$Win.MainWindowHandle, $Win.MainWindowTitle, $cur, $got) 'STAMP'
    if ($got -ne $Inst.Aumid) {
        Write-WatchLog ('{0}: FAILED - read-back "{1}" != "{2}". If this watcher runs at a lower integrity level than the ZCode window (UIPI), run it from the same level or higher.' -f $Inst.Name, $got, $Inst.Aumid) 'FAIL'
    }
}

# One WMI snapshot per pass, keyed by pid, with parent->children links so the
# subtree walks below never re-query.
function Get-ZcodeProcessMap {
    $map = @{}
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='ZCode.exe'" -ErrorAction SilentlyContinue)
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
            $classified += ,@($w, $inst)
        } else {
            $unknownWins += $w
        }
    }
    foreach ($pair in $classified) {
        Set-WindowIdentity -Win $pair[0] -Inst $pair[1]
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
        Set-WindowIdentity -Win $hits[0] -Inst $inst
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
    Write-WatchLog 'single pass complete (-RunOnce)'
    exit 0
}

$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'ZcodeTaskbarIdentityWatcher', [ref]$created)
if (-not $created) {
    Write-WatchLog 'watcher already running (mutex held) - exiting. Check the log or Task Manager.' 'WARN'
    $mutex.Close()
    exit 0
}
Write-WatchLog ('watcher started (pid {0}, interval {1}s, script {2})' -f $PID, $IntervalSeconds, $PSCommandPath)
try {
    while ($true) {
        Invoke-IdentityPass
        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Close()
    Write-WatchLog 'watcher stopped'
}
