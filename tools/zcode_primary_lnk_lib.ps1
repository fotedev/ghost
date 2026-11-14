#requires -Version 5.1
# SPDX-License-Identifier: Apache-2.0
# Pure decision core for the recurring PRIMARY ZCode.lnk hijack, shared by
# tools/install_zcode_second_shortcuts.ps1 (-RepairPrimaryAumid) and the
# resident tools/watch_zcode_taskbar.ps1 hijack guard. Pure function library
# (no COM, no main body, no side effects), so it is dot-sourced and unit-tested
# by tests/zcode_primary_lnk_lib.Tests.ps1 against TestDrive fixtures - never
# a test-local re-implementation.
#
# Windows pin maintenance rewrites the Primary's ZCode.lnk with the last
# pinned clone's identity. Three verified hijack shapes:
#   1. AUMID stamped with the clone suffix "<base>.<N>" (verified 2026-09-24).
#   2. Icon field wiped to ",0" (verified 2026-09-28).
#   3. TARGET drifted onto a per-color exe copy (verified 2026-11-11: clones
#      launch from ZCode-<Color>.exe since the Task-Manager exe-identity work,
#      so a pinned clone window's process exe is now a colored copy; the old
#      repair kept the drifted target - "the lnk's own target wins" - and set
#      the icon FROM it, permanently blessing the clone's icon behind a clean
#      AUMID the AUMID-only guard could no longer see).
# The lib holds the single copy of: the primary-lnk path list, the stock-exe
# candidates, the clone-exe drift predicate and the combined hijack-state
# decision both the guard and the repair consume.

function Get-ZCodePrimaryLnkPaths {
    # Every per-user copy of the Primary shortcut a pin can rewrite: Desktop
    # plus both Start Menu locations. Roots are parameters so tests can inject
    # temp paths; defaults mirror the live user shell folders.
    param(
        [string]$DesktopPath = [Environment]::GetFolderPath('Desktop'),
        [string]$AppDataRoot = $env:APPDATA,
        [string]$ProgramDataRoot = $env:ProgramData
    )
    return @(
        (Join-Path $DesktopPath 'ZCode.lnk'),
        (Join-Path $AppDataRoot 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk'),
        (Join-Path $ProgramDataRoot 'Microsoft\Windows\Start Menu\Programs\ZCode.lnk')
    )
}

function Get-ZCodeExeCandidates {
    # The stock install locations, best-first (per-user install, then Program
    # Files). The per-color exe copies (ZCode-<Color>.exe) live in the SAME
    # directory - candidates always name the stock ZCode.exe, never a copy.
    param(
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [string]$ProgramFiles = $env:ProgramFiles,
        [string]$ProgramFilesX86 = ${env:ProgramFiles(x86)}
    )
    $cands = @()
    if (-not [string]::IsNullOrWhiteSpace($LocalAppData)) { $cands += (Join-Path $LocalAppData 'Programs\ZCode\ZCode.exe') }
    if (-not [string]::IsNullOrWhiteSpace($ProgramFiles)) { $cands += (Join-Path $ProgramFiles 'ZCode\ZCode.exe') }
    if (-not [string]::IsNullOrWhiteSpace($ProgramFilesX86)) { $cands += (Join-Path $ProgramFilesX86 'ZCode\ZCode.exe') }
    # Leading comma: a single surviving candidate would otherwise unwrap to a
    # bare string (.Count lies as 1, [0] returns the first CHARACTER).
    return ,$cands
}

function Resolve-StockZCodeExe {
    # First stock candidate that exists on disk, else $null. Test-Path based so
    # tests can inject temp-dir candidates.
    param([string[]]$Candidates)
    foreach ($c in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Test-ZCodeCloneExeTarget {
    # $true when a shortcut TargetPath names a per-color exe copy
    # (ZCode-<Color>.exe) - the pin-rewrite signature since 2026-11-11. Leaf
    # name match only; the directory does not matter (any target that is a
    # copy-family exe is a hijack).
    param([string]$TargetPath)
    if ([string]::IsNullOrWhiteSpace($TargetPath)) { return $false }
    $leaf = [System.IO.Path]::GetFileName(($TargetPath -replace '/', '\'))
    return ([bool]($leaf -imatch '^ZCode-.+\.exe$'))
}

function Test-PrimaryLnkHijackState {
    # The single hijack decision for one primary ZCode.lnk state snapshot.
    # Returns a reason string when the state is hijacked, $null when healthy.
    # The target and icon checks are gated on $StockExe: without a stock exe
    # to restore to, a drift is not repairable, and the resident watcher must
    # not spam a repair it cannot complete. The AUMID check stays
    # unconditional - stripping a clone suffix needs no exe.
    # $IconLocation is normalized before compare so any explicit index on the
    # stock exe counts as healthy; empty and ",0" (the verified 2026-09-28
    # wiped shape) count as hijacked.
    param(
        [string]$Aumid,
        [string]$TargetPath,
        [string]$IconLocation,
        [string]$StockExe
    )
    if (-not [string]::IsNullOrWhiteSpace($Aumid) -and ($Aumid -match '\.\d+$')) {
        return "AUMID '$Aumid' carries a clone suffix"
    }
    if (-not [string]::IsNullOrWhiteSpace($StockExe)) {
        if (Test-ZCodeCloneExeTarget -TargetPath $TargetPath) {
            return "target drifted onto a clone exe copy '$TargetPath'"
        }
        $iconNorm = ($IconLocation -replace ',\s*\d+\s*$', '')
        if ($iconNorm -ine $StockExe) {
            return "icon location '$IconLocation' expected '$StockExe,0'"
        }
    }
    return $null
}
