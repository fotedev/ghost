#requires -Version 5.1
<#
.SYNOPSIS
  Window-level taskbar identity patch for the AutoClaw2 (zwork) clone suite
  - colored, per-clone taskbar buttons for the RUNNING windows.

.DESCRIPTION
  AutoClaw2 4.0.0 ships UNPACKED: the whole main process is the plain-text
  resources\app\dist\main.cjs (no app.asar; the bootstrap does a bare
  require() of it, and dist\installer\payload-verify.cjs is an
  existence-only check the app never spawns - verified 2026-11-06). This
  patch therefore does NOT need the asar-surgery route: it splices THREE
  unique byte-level anchors (each verified to occur EXACTLY once in the
  4.0.0 bundle) so the AppUserModelID and the window icon become
  env-driven, following the app's own ZWORK_* env convention (the app
  never parses arbitrary argv flags):

    1.  setAppUserModelId(Kqn)
          -> setAppUserModelId(process.env.ZWORK_AUMID||Kqn)
        (process-level AUMID; also covers transient windows like the
        migration splash)

    2.  appId:Kqn,appIconPath:e,
          -> appId:process.env.ZWORK_AUMID||Kqn,
             appIconPath:process.env.ZWORK_CLONE_ICON||e,
        (inside the per-window setAppDetails helper - the taskbar
        identity of the main window. The relaunchCommand template literal
        that follows in the same function is NEVER touched, so the
        relaunch command keeps pointing at AutoClaw2.exe exactly like
        stock.)

    3.  Uf.app.isPackaged&&Xqn(l,process.execPath)
          -> Uf.app.isPackaged&&(
               process.env.ZWORK_CLONE_ICON&&l.setIcon(process.env.ZWORK_CLONE_ICON),
               Xqn(l,process.execPath))
        (window icon for the main window's title bar / taskbar)

  The launcher (launch_autoclaw2_clone.ps1) then sets, per clone:
    ZWORK_AUMID      = com.zhipuai.autoclaw2.cN   (matches the SHORTCUT
                       AUMIDs the installer already writes, so pins and
                       running windows group together)
    ZWORK_CLONE_ICON = tools\autoclaw2-<color>-branding\tray_icon.ico
  With no env vars set (the Primary, bare launches) the patched bundle is
  behaviourally identical to stock.

  Mechanics: idempotent (the done-anchors ARE the replacements),
  timestamped sibling backup main.cjs.bak-zwork-identity-<stamp>, marker
  resources\app\autoclaw2-identity-patch.marker.json (sha256 before/after),
  a node --check gate through the app's own vendor node BEFORE the swap,
  verify-after re-read (done-anchors present, originals absent, sha256
  match) with auto-restore on failure, and -Restore. After an app update
  wipes the patch the script detects the stock bundle and re-applies with
  a FRESH backup of the new file.

  Exit codes: 0 = applied or already applied
              2 = main.cjs not found
              3 = anchor drift / mixed state (bundle changed - review)
              4 = node syntax check failed (original untouched)
              5 = post-patch verification failed (auto-restored)
              6 = restore failed

.PARAMETER Restore
  Restore the backup recorded in the marker and remove the marker.

.PARAMETER Force
  When the patch reports already applied, re-record the marker instead of
  exiting early.

.PARAMETER WaitForClose
  When AutoClaw2 copies are running, instruct-and-poll until every
  AutoClaw2.exe under the install dir has exited (2 consecutive clear
  probes) instead of refusing. Direct runs WITHOUT the switch throw.

.PARAMETER WaitTimeoutMinutes
  Deadline for -WaitForClose. Default 30.

.PARAMETER InstallRoot
  AutoClaw2 install directory. Default: %LOCALAPPDATA%\Programs\AutoClaw2

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_autoclaw2_identity.ps1 -WaitForClose
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\patch_autoclaw2_identity.ps1 -Restore
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$Force,
    [switch]$WaitForClose,
    [int]$WaitTimeoutMinutes = 30,
    [string]$InstallRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\AutoClaw2')
)

$ErrorActionPreference = 'Stop'
$script:PatchVersion = 1

# Byte-level anchors verified unique in the 4.0.0 bundle (main.cjs, 2026-11-06:
# each occurs exactly once; grep counts 1/1/1 across 14,293,768 bytes). Plain
# ASCII, no backticks, no single quotes - safe as PS single-quoted literals.
# The relaunchCommand:`"${e}"` template literal lives INSIDE the same Xqn
# function but is deliberately not part of any anchor.
$script:Anchors = @(
    @{ Name = 'process-aumid';    Find = 'setAppUserModelId(Kqn)'; Replace = 'setAppUserModelId(process.env.ZWORK_AUMID||Kqn)' },
    @{ Name = 'window-details';   Find = 'appId:Kqn,appIconPath:e,'; Replace = 'appId:process.env.ZWORK_AUMID||Kqn,appIconPath:process.env.ZWORK_CLONE_ICON||e,' },
    @{ Name = 'main-window-icon'; Find = 'Uf.app.isPackaged&&Xqn(l,process.execPath)'; Replace = 'Uf.app.isPackaged&&(process.env.ZWORK_CLONE_ICON&&l.setIcon(process.env.ZWORK_CLONE_ICON),Xqn(l,process.execPath))' }
)

function Invoke-IdentitySplice {
    # Pure splice core (extracted for tests/autoclaw2_identity_patch.Tests.ps1):
    # consumes the bundle text, returns the patched text or a typed failure.
    param([Parameter(Mandatory = $true)][string]$Text)
    $result = [pscustomobject]@{ Ok = $false; AlreadyApplied = $false; Text = $Text; Message = ''; Applied = @() }
    $doneHits = 0
    foreach ($a in $script:Anchors) {
        if ([regex]::Matches($Text, [regex]::Escape($a.Replace)).Count -ge 1) { $doneHits++ }
    }
    if ($doneHits -eq $script:Anchors.Count) {
        $result.Ok = $true
        $result.AlreadyApplied = $true
        $result.Message = 'all identity anchors already patched'
        return $result
    }
    $out = $Text
    foreach ($a in $script:Anchors) {
        $n = [regex]::Matches($out, [regex]::Escape($a.Find)).Count
        if ($n -ne 1) {
            # 0 + some done-anchors present = partially patched (mixed state);
            # anything else = the bundle layout changed (app update).
            $result.Message = "anchor drift: '$($a.Name)' occurs $n time(s) (expected exactly 1) - the bundle changed or is in a mixed state; review manually (a -Restore may be needed first)"
            return $result
        }
        $out = $out.Replace($a.Find, $a.Replace)
        $result.Applied += $a.Name
    }
    $result.Ok = $true
    $result.Text = $out
    return $result
}

function Get-InstallScopedAutoClaw2 {
    # Only AutoClaw2.exe copies FROM THIS INSTALL are gating candidates.
    param([string]$Root)
    $scoped = @()
    foreach ($p in (Get-Process -Name AutoClaw2 -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if (-not $path) {
            Write-Warning "cannot read the image path of AutoClaw2 pid $($p.Id) - treating as in-scope (refusing to patch under a possibly-running copy)"
            $scoped += $p
            continue
        }
        if ($path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) { $scoped += $p }
    }
    return $scoped
}

function Write-Sha256 {
    param([string]$LiteralPath)
    (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash
}

# --- Paths -------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\AutoClaw2'
}
$target     = Join-Path $InstallRoot 'resources\app\dist\main.cjs'
$markerPath = Join-Path $InstallRoot 'resources\app\autoclaw2-identity-patch.marker.json'
if (-not (Test-Path -LiteralPath $target)) {
    Write-Warning "AutoClaw2 main bundle not found: $target"
    exit 2
}

# --- Running-instance gate ----------------------------------------------------
$running = @(Get-InstallScopedAutoClaw2 -Root $InstallRoot)
if ($running.Count -gt 0) {
    $pidList = ($running | ForEach-Object { $_.Id }) -join ', '
    if (-not $WaitForClose) {
        throw "$($running.Count) AutoClaw2 copy(ies) running (pids: $pidList). Close them first, or re-run with -WaitForClose."
    }
    Write-Host "AutoClaw2 is running (pids: $pidList) - close the copies; this patch waits (deadline ${WaitTimeoutMinutes}min) ..."
    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    $clearStreak = 0
    while ($true) {
        if (@(Get-InstallScopedAutoClaw2 -Root $InstallRoot).Count -eq 0) { $clearStreak++ } else { $clearStreak = 0 }
        if ($clearStreak -ge 2) { break }
        if ((Get-Date) -gt $deadline) { throw "timed out after $WaitTimeoutMinutes minute(s) - AutoClaw2 copies are still running" }
        Start-Sleep -Seconds 2
    }
    Write-Host "all AutoClaw2 copies closed - continuing."
}

# --- Encoding probe (preserve the original BOM state) --------------------------
$fs = [System.IO.File]::OpenRead($target)
$b0 = $fs.ReadByte(); $b1 = $fs.ReadByte(); $b2 = $fs.ReadByte()
$fs.Close()
$hasBom = ($b0 -eq 0xEF -and $b1 -eq 0xBB -and $b2 -eq 0xBF)

# --- Restore -------------------------------------------------------------------
if ($Restore) {
    if (-not (Test-Path -LiteralPath $markerPath)) {
        Write-Output "no identity-patch marker at $markerPath - nothing to restore."
        exit 0
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    $backup = $marker.backupPath
    if ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup)) {
        Write-Error "marker exists but its backup is missing ('$backup') - cannot restore"
        exit 6
    }
    $shaNow = Write-Sha256 -LiteralPath $target
    if ($shaNow -ne $marker.sha256After) {
        Write-Warning "current main.cjs sha256 does not match the marker's post-patch hash (the app may have been updated after patching) - restoring anyway."
    }
    Copy-Item -LiteralPath $backup -Destination $target -Force
    $restoredText = [System.IO.File]::ReadAllText($target)
    $doneLeft = 0
    foreach ($a in $script:Anchors) {
        $doneLeft += [regex]::Matches($restoredText, [regex]::Escape($a.Replace)).Count
    }
    $shaBack = Write-Sha256 -LiteralPath $target
    if ($doneLeft -gt 0 -or $shaBack -ne $marker.sha256Before) {
        Write-Error "restore verification FAILED (done-anchors left: $doneLeft) - inspect $target manually"
        exit 6
    }
    Remove-Item -LiteralPath $markerPath -Force
    Write-Host "restored the stock main.cjs (sha256 matches the pre-patch hash) - marker removed." -ForegroundColor Green
    exit 0
}

# --- Apply ----------------------------------------------------------------------
$text   = [System.IO.File]::ReadAllText($target)
$splice = Invoke-IdentitySplice -Text $text
if (-not $splice.Ok) {
    Write-Warning $splice.Message
    exit 3
}
if ($splice.AlreadyApplied) {
    if ((Test-Path -LiteralPath $markerPath) -and -not $Force) {
        Write-Output "already applied (patch v$($script:PatchVersion)) - nothing to do. Use -Force to re-record the marker."
        exit 0
    }
    Write-Warning "patch already present but the marker is being (re-)recorded without a pristine backup reference - a -Restore will not be possible until the next fresh apply."
    $marker = [ordered]@{
        appliedAt    = (Get-Date).ToUniversalTime().ToString('o')
        patchVersion = $script:PatchVersion
        installRoot  = $InstallRoot
        targetFile   = $target
        backupPath   = ''
        sha256Before = ''
        sha256After  = (Write-Sha256 -LiteralPath $target)
        anchors      = @($script:Anchors | ForEach-Object { $_.Name })
    }
    [System.IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "marker re-recorded: $markerPath"
    exit 0
}

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = "$target.bak-zwork-identity-$stamp"
Copy-Item -LiteralPath $target -Destination $backup -Force
$shaBefore = Write-Sha256 -LiteralPath $target
Write-Output "backup: $backup"

# Candidate + node --check gate BEFORE touching the original.
$candidate = "$target.identity-patch-tmp.cjs"
$enc = New-Object System.Text.UTF8Encoding($hasBom)
[System.IO.File]::WriteAllText($candidate, $splice.Text, $enc)

$nodeExe = $null
$cmd = Get-Command node -ErrorAction SilentlyContinue
if ($cmd) { $nodeExe = $cmd.Source }
if (-not $nodeExe) {
    $vendored = Join-Path $InstallRoot 'resources\vendor\node\node.exe'
    if (Test-Path -LiteralPath $vendored) { $nodeExe = $vendored }
}
if ($nodeExe) {
    & $nodeExe --check $candidate
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        Write-Error 'node --check FAILED on the patched candidate - patch aborted, original untouched.'
        exit 4
    }
    Write-Output "node --check: OK ($nodeExe)"
} else {
    Write-Warning 'node not found; skipping the syntax gate.'
}

# Swap (retry for AV scans), then verify-after: done-anchors in, originals out,
# sha256 equals the candidate's hash. Any failure auto-restores the backup.
$swapped = $false
for ($i = 0; $i -lt 3 -and -not $swapped; $i++) {
    try { Copy-Item -LiteralPath $candidate -Destination $target -Force; $swapped = $true }
    catch { Start-Sleep -Milliseconds 300 }
}
Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
if (-not $swapped) {
    Write-Error "could not write $target after 3 attempts (file locked?) - original untouched"
    exit 5
}

$finalText = [System.IO.File]::ReadAllText($target)
$final     = Invoke-IdentitySplice -Text $finalText
$shaAfter  = Write-Sha256 -LiteralPath $target
$shaExpected = [BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::Create().ComputeHash($enc.GetBytes($splice.Text))
).Replace('-', '')
if (-not ($final.AlreadyApplied) -or $shaAfter -cne $shaExpected) {
    Copy-Item -LiteralPath $backup -Destination $target -Force
    Write-Error "post-patch verification FAILED (alreadyApplied=$($final.AlreadyApplied), sha match=$($shaAfter -ceq $shaExpected)) - the original was restored from the backup."
    exit 5
}

$marker = [ordered]@{
    appliedAt    = (Get-Date).ToUniversalTime().ToString('o')
    patchVersion = $script:PatchVersion
    installRoot  = $InstallRoot
    targetFile   = $target
    backupPath   = $backup
    sha256Before = $shaBefore
    sha256After  = $shaAfter
    anchors      = @($script:Anchors | ForEach-Object { $_.Name })
}
[System.IO.File]::WriteAllText($markerPath, ($marker | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "IDENTITY PATCH APPLIED (v$($script:PatchVersion)): 3 anchors spliced into main.cjs" -ForegroundColor Green
Write-Host "  marker : $markerPath"
Write-Host "  next   : launch the clones via their AutoClaw2 shortcuts - each window now"
Write-Host "           carries com.zhipuai.autoclaw2.cN + its colored tray_icon.ico."
Write-Host "           Bare launches (the Primary) stay stock."
exit 0
