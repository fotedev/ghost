#Requires -Version 5.1
# Shared 3-way concurrency launch guard for the GHOST multi-instance launchers
# (ZCode / AutoClaw2 / Cline / OpenCode).
#
# Why (2026-10-28, ZCode origin): several concurrent Electron instances
# exhausted the Windows commit limit once (renderer-OOM freeze, verified
# 2026-09-25 - RAM + pagefile ceiling, NOT an app leak). This lib generalizes
# the soft guard that launch_zcode_second_instance.ps1 carried since then:
# count the suite's running mains; at/over -MaxConcurrent print live commit
# numbers and route the ask by entry point:
#   - -NonInteractive / -NeverAsk or redirected stdin (watchdog relaunch,
#     test harness): warn and continue - never blocks an unattended caller.
#   - visible console (GHOST.bat rows, double-click stubs, manual runs):
#     Read-Host prompt in that console.
#   - hidden console (Desktop/Start-menu shortcuts run powershell with
#     -WindowStyle Hidden; hidden stdin is NOT redirected, so a plain
#     Read-Host would hang invisibly and the launch would look dead):
#     Yes/No dialog instead. Default button No mirrors the console y/N.
#
# Mains counting (EC-K01): a main is ONLY a bare-exe process (CommandLine ==
# the exe path, quoted or not, no args). Helpers (--type=*, WebView2
# children, node sidecars, hub daemons) carry extra args and must NOT be
# counted - the --type filter alone misclassifies them (caught in the ZCode
# v1.4 pre-release dry-run). An empty CommandLine is a known WMI race on
# fresh mains: keep as a candidate.
#
# The caller keeps its suite-specific already-running check (relaunch-focus /
# single-instance guards run BEFORE this lib is invoked) and decides what
# "cancel" means. Every function here is pure orchestration - no writes, no
# elevation.
#
# PS 5.1 COMPAT: no ternary, no $Input variable.

function Test-GhostConsoleVisible {
    # True when this process has a console window the user can actually see.
    # Any probe failure counts as not visible -> the dialog path is the safe
    # default (a blocked invisible prompt is the worst outcome).
    try {
        if (-not ('GhostNative.Console' -as [type])) {
            Add-Type -Namespace GhostNative -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
'@
        }
        $hwnd = [GhostNative.Console]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return $false }
        return [bool][GhostNative.Console]::IsWindowVisible($hwnd)
    } catch {
        return $false
    }
}

function Get-GhostStdinRedirected {
    try { return [bool][Console]::IsInputRedirected } catch { return $false }
}

function Show-GhostLaunchGuardDialog {
    # Yes/No dialog for hidden-console (shortcut) launches. Default button is
    # No to mirror the console prompt's y/N; returns $true only on Yes.
    param(
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Title
    )
    try { Add-Type -AssemblyName System.Windows.Forms } catch { }
    $text = $Body + "`n`nLaunch anyway?"
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show($text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2,
            [System.Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
        return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        try {
            $answer = [System.Windows.Forms.MessageBox]::Show($text, $Title,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
            return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
        } catch {
            # No dialog possible (no interactive desktop): never start an
            # instance the user could not consent to - cancel like "N".
            return $false
        }
    }
}

function Get-GhostSuiteMainIds {
    # Bare-exe main PIDs for one suite family (see the EC-K01 note above).
    param([Parameter(Mandatory = $true)][string]$WmiFamilyFilter)
    return @(Get-CimInstance Win32_Process -Filter $WmiFamilyFilter -ErrorAction SilentlyContinue | Where-Object {
        $cmd = [string]$_.CommandLine
        if ($cmd -match '--type=') { return $false }
        $name = [string]$_.Name
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        # Empty CommandLine = WMI race on a fresh main: keep as candidate.
        if ([string]::IsNullOrWhiteSpace($cmd)) { return $true }
        $bare = '^\s*"?[^"]*\\' + [regex]::Escape($name) + '"?\s*$'
        return ($cmd -match $bare)
    } | Select-Object -ExpandProperty ProcessId)
}

function Get-GhostSuiteCommitMb {
    # Live commit pressure of one suite's process family (Get-Process name
    # pattern, e.g. 'ZCode*' / 'AutoClaw2*').
    param([Parameter(Mandatory = $true)][string]$ProcessFamily)
    $procs = @(Get-Process -Name $ProcessFamily -ErrorAction SilentlyContinue)
    $sum = ($procs | Measure-Object -Property PrivateMemorySize64 -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return ($sum / 1MB)
}

function Invoke-GhostLaunchGuard {
    # The 3-way ask. Returns $true = proceed (consented, unattended-continue,
    # or under the limit - the caller checks the limit), $false = cancel.
    param(
        [Parameter(Mandatory = $true)][int]$RunningMains,
        [Parameter(Mandatory = $true)][int]$MaxConcurrent,
        [Parameter(Mandatory = $true)][string]$SuiteName,
        [Parameter(Mandatory = $true)][string]$WmiFamilyFilter,
        [Parameter(Mandatory = $true)][string]$ProcessFamily,
        [Parameter(Mandatory = $true)][string]$RiskLine,
        [string]$LighterHint = '',
        [switch]$NonInteractive,
        [switch]$NeverAsk
    )
    $suiteCommit = Get-GhostSuiteCommitMb -ProcessFamily $ProcessFamily
    $osCommit = Get-CimInstance Win32_OperatingSystem
    $guardLines = @(
        ("[ram-guard] {0} {1} instance(s) already running - soft limit is {2}." -f $RunningMains, $SuiteName, $MaxConcurrent),
        ("[ram-guard] Live pressure: {0} {1:N0} MB commit; OS {2:N0} / {3:N0} MB commit limit." -f $SuiteName, $suiteCommit, (($osCommit.TotalVirtualMemorySize - $osCommit.FreeVirtualMemory) / 1KB), ($osCommit.TotalVirtualMemorySize / 1KB)),
        $RiskLine
    )
    if ($LighterHint) { $guardLines += $LighterHint }
    Write-Host $guardLines[0] -ForegroundColor Yellow
    Write-Host $guardLines[1] -ForegroundColor Yellow
    for ($i = 2; $i -lt $guardLines.Count; $i++) { Write-Host $guardLines[$i] }

    if ($NeverAsk -or $NonInteractive -or (Get-GhostStdinRedirected)) {
        Write-Host '[ram-guard] Non-interactive session - continuing so watchdog/harness callers never hang.' -ForegroundColor Yellow
        return $true
    }
    if (Test-GhostConsoleVisible) {
        # Visible console: prompt here.
        $guardAnswer = Read-Host '[ram-guard] Launch anyway? (y/N)'
        if ($guardAnswer -notmatch '^[Yy]') {
            Write-Host '[ram-guard] Launch cancelled - nothing was started.'
            return $false
        }
        return $true
    }
    # Hidden console (Desktop/Start-menu shortcut): the prompt would be
    # invisible and hang the launch forever - ask via a dialog instead.
    if (-not (Show-GhostLaunchGuardDialog -Body ($guardLines -join "`n") -Title ('GHOST - {0} RAM guard' -f $SuiteName))) {
        Write-Host '[ram-guard] Launch cancelled - nothing was started.'
        return $false
    }
    return $true
}
