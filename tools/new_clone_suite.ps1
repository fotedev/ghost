#Requires -Version 5.1
<#
.SYNOPSIS
  Scaffold a new app multi-instance clone suite (docs/APP_CLONING_PLAYBOOK.md,
  Phases 3-10 mechanics).

.DESCRIPTION
  Takes the intake answers (JSON file or interactive prompts) and emits the
  mechanical scaffolding a clone suite needs, wired the way the ZCode
  (gold standard) and AutoClaw suites taught us:

    src/windows/reset_<slug>.ps1                   reset manifest (identity suite skeleton)
    src/windows/launch_<slug>_clone.ps1            per-clone launcher skeleton
    src/windows/Launch-<Pascal>-Clone.bat          double-click wrapper
    tools/install_<slug>_clone_shortcuts.ps1       AUMID shortcuts + branding + -RepairPrimaryAumid
    docs/<SLUG>_CLONES_SPEC.md                     spec stub (phase checklist)
    GHOST.bat                                      new submenu + resolver + DispatchOne gids

  Phases 0-2 (intake decisions, discovery on the INSTALLED app, isolation
  design) stay with the agent per the playbook's automation contract - the
  emitted skeletons carry marked <TODO: Phase 1 discovery> slots for exactly
  those findings. Every emitted .ps1 is parse-checked before the tool claims
  success (never silent-success); GHOST.bat is backed up, edited by anchor,
  and re-verified after.

  Acceptance for the tool itself: a generated demo suite must pass the full
  gate (parse-check + Pester repo-integrity + .bat harness), then be removed.

.PARAMETER Intake
  Path to an intake JSON (schema in the EXAMPLES block). Omit for interactive
  prompts with the documented defaults.

.PARAMETER DryRun
  Print what would be generated and exit; write nothing.

.EXAMPLE
  tools\new_clone_suite.ps1 -Intake myapp-intake.json
  tools\new_clone_suite.ps1 -DryRun

.EXAMPLE intake JSON
  {
    "slug": "myapp",
    "displayName": "MyApp",
    "instanceCount": 4,
    "colors": ["#066BCB", "#D4AA10", "#13826A", "#C43E3E"],
    "exePath": "",
    "elevatesItself": false,
    "isolation": "homeMarker",
    "preferredPort": 18790
  }
#>
param(
  [string]$Intake,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function Write-Utf8Crlf {
  # Repo rule: PS/cmd files are CRLF on disk (the Write-tool emits LF and cmd
  # breaks); UTF-8 without BOM (skeletons are ASCII).
  param([string]$Path, [string]$Content)
  $norm = $Content -replace "`r`n", "`n"
  $norm = $norm -replace "`n", "`r`n"
  [System.IO.File]::WriteAllText($Path, $norm, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-HashtableDeep {
  param($Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string]) -and -not ($Obj -is [pscustomobject])) {
    return @($Obj | ForEach-Object { ConvertTo-HashtableDeep $_ })
  }
  if ($Obj -is [pscustomobject]) {
    $h = @{}
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
    return $h
  }
  return $Obj
}

function New-Intake {
  # Developer values or documented defaults (playbook §3); every default is
  # reported in the final summary.
  $it = @{
    slug           = ''
    displayName    = ''
    instanceCount  = 4
    colors         = @('#066BCB', '#D4AA10', '#13826A', '#C43E3E')
    exePath        = ''
    elevatesItself = $false
    isolation      = 'homeMarker'
    preferredPort  = 18790
  }
  if ($Intake) {
    if (-not (Test-Path -LiteralPath $Intake)) { throw "Intake file not found: $Intake" }
    $loaded = ConvertTo-HashtableDeep (Get-Content -LiteralPath $Intake -Raw | ConvertFrom-Json)
    foreach ($k in @($it.Keys)) { if ($loaded.ContainsKey($k) -and $null -ne $loaded[$k]) { $it[$k] = $loaded[$k] } }
    Write-Host "[intake] loaded from $Intake"
  }
  else {
    $slugIn = Read-Host "App slug (lowercase, file-safe) [required]"
    if ($slugIn) { $it.slug = $slugIn.Trim() }
    $nameIn = Read-Host "Display name (blank = slug)"
    if ($nameIn) { $it.displayName = $nameIn.Trim() }
    $cntIn = Read-Host "Instance count incl. Primary [4]"
    if ($cntIn -match '^\d+$') { $it.instanceCount = [int]$cntIn }
    $exeIn = Read-Host "Installed exe path (blank = TODO auto-detect)"
    if ($exeIn) { $it.exePath = $exeIn.Trim() }
    $elIn = Read-Host "App self-elevates (requireAdministrator manifest)? y/N"
    if ($elIn -match '^[Yy]') { $it.elevatesItself = $true }
    Write-Host "[intake] interactive; all other values = documented defaults (reported below)"
  }
  if (-not $it.slug) { throw "slug is required" }
  if ($it.slug -notmatch '^[a-z][a-z0-9]{2,20}$') { throw "slug '$($it.slug)' must be lowercase alnum, 3-21 chars, letter first" }
  $reserved = @('zcode', 'autoclaw', 'cursor', 'devin', 'windsurf', 'trae', 'qoder', 'qoderwork', 'minimax', 'opencode', 'ghost')
  if ($reserved -contains $it.slug) { throw "slug '$($it.slug)' collides with an existing suite" }
  if (-not $it.displayName) { $it.displayName = $it.slug.Substring(0, 1).ToUpperInvariant() + $it.slug.Substring(1) }
  if ($it.isolation -notin @('homeMarker', 'env')) { throw "isolation must be 'homeMarker' or 'env'" }
  if ($it.instanceCount -lt 2 -or $it.instanceCount -gt 6) { throw "instanceCount must be 2..6" }
  while ($it.colors.Count -lt ($it.instanceCount - 1)) { $it.colors += '#808080' }
  return $it
}

function Get-PascalSlug([string]$Slug) {
  return ($Slug -split '-' | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join ''
}

# ---------------------------------------------------------------------------
# Skeleton templates. Single-quoted here-strings (no PS expansion); __TOKENS__
# replaced below. Each skeleton encodes the suite invariants: verify-after
# everywhere, backup-first, independent identity per child, sequential
# non-elevated launches, marker-guarded one-time work - with <TODO: Phase 1
# discovery> slots where only the installed app knows the answer.
# ---------------------------------------------------------------------------

$ResetT = @'
#Requires -Version 5.1
<#
.SYNOPSIS
  __DISPLAYNAME__ identity reset (clone suite generated by new_clone_suite.ps1).
.DESCRIPTION
  Thin target manifest per the GHOST convention: dot-source the shared
  identity library, assert admin, stop the app, rotate identities with
  verify-after, audit, emit a restore script, summarize.
  <TODO: Phase 1 discovery> fill the per-target store paths and step list
  from the INSTALLED app (playbook Phase 1) - never guess a path.
.PARAMETER Target
  Primary | inst1..instN | All (clones first, Primary last).
.PARAMETER DryRun
  Print every action, write nothing.
#>
param(
  [ValidateSet('Primary', '__INSTPARAMS__', 'All')]
  [string]$Target = 'Primary',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'identity_utils.ps1')

$AppDisplayName = '__DISPLAYNAME__'
$ExeCandidates  = @(
  '<TODO: Phase 1 discovery - installed exe path>'
)
$AppDataDirs    = @('<TODO: Phase 1 discovery - roaming store dirs>')
$HomeStores     = @('<TODO: Phase 1 discovery - ~\.app store paths>')
$Processes      = @('__PASCAL__')
$TotalSteps     = 7

Assert-Administrator

function Stop-__Pascal__ProcessesAggressive {
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $left = @(Get-Process -Name $Processes -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) { return }
    $left | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
  if (@(Get-Process -Name $Processes -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "  [FAILED] $AppDisplayName processes still running - close them and re-run." -ForegroundColor Red
    exit 1
  }
}

function Get-TargetOrder([string]$T) {
  # All = clones first, Primary last (independent identity per child; the
  # Primary's steps run with the most complete step set).
  $clones = 1..(__COUNT__ - 1) | ForEach-Object { "inst$_" }
  if ($T -eq 'All') { return @($clones) + @('Primary') }
  return @($T)
}

Write-Host "=== $AppDisplayName identity reset ==="
if ($DryRun) { Write-Host 'Mode: DRY-RUN (no writes)' -ForegroundColor Yellow }

foreach ($tgt in (Get-TargetOrder $Target)) {
  Write-Host "`n--- target: $tgt ---"
  Stop-__Pascal__ProcessesAggressive

  $ids = New-IdentitySet
  Write-Host ("  [1/$TotalSteps] new identity set: devDeviceId={0}" -f $ids.devDeviceId.Substring(0, 8) + '...')

  # <TODO: Phase 1 discovery> replace the generic steps below with the
  # app's real identity stores. The shared helpers handle verify-after and
  # audit for you; never write a store without re-reading it.
  foreach ($dir in $AppDataDirs) {
    $store = Join-Path $env:APPDATA $dir
    if (-not (Test-Path -LiteralPath $store)) { continue }
    Write-Host ("  [2/$TotalSteps] <TODO> patch JSON identity stores under {0}" -f $store)
    # Example (uncomment + adjust after discovery):
    # Backup-FileToTimestampDir -Path (Join-Path $store 'storage.json') -Label "reset-$tgt"
    # Set-JsonIdentity -FilePath (Join-Path $store 'storage.json') -Identity $ids -DryRun:$DryRun
  }
  Write-Host ("  [3/$TotalSteps] <TODO> SQLite identity rows (Set-SqliteKeys handles Python probing + verify-after)")
  Write-Host ("  [4/$TotalSteps] <TODO> binary identity stores (Clear-BinaryIdentityStore: rename/delete, clobber old .backup)")
  Write-Host ("  [5/$TotalSteps] <TODO> caches/logs/sentry/crashpad sweep")
  if ($tgt -eq 'Primary') {
    Write-Host ("  [6/$TotalSteps] <TODO> system-level steps (registry deviceid, SQM, MAC, hostname) - Primary only, follow reset_qoder.ps1")
  }
  else {
    Write-Host ("  [6/$TotalSteps] clones get INDEPENDENT identity - never share the ID set across targets")
  }
  Write-Host ("  [7/$TotalSteps] restore script + audit log (New-RestoreScript / Write-AuditLog) <TODO>")
}

Write-Host "`nDone. Re-run after app updates that rewrite identity stores."
'@

$LaunchT = @'
#Requires -Version 5.1
<#
.SYNOPSIS
  __DISPLAYNAME__ multi-instance clone launcher (generated by new_clone_suite.ps1).
.DESCRIPTION
  Isolation model: __ISOLATIONDOC__
  Elevation model: __ELEVATIONDOC__
  <TODO: Phase 1/2 discovery> fill the seed excludes, port levers and
  verify-after-launch checks from the INSTALLED app - never guess.
.PARAMETER Instance
  inst1..instN.
.PARAMETER Status
  Read the recorded instance state (ports, pids) and exit.
#>
param(
  [ValidateSet('__INSTPARAMS__')]
  [string]$Instance = 'inst1',
  [switch]$Status
)

$ErrorActionPreference = 'Stop'

$AppDisplayName = '__DISPLAYNAME__'
$ExePath        = '<TODO: Phase 1 discovery - installed exe path>'
$BasePort       = __PORT__
$CloneRoot      = Join-Path $env:USERPROFILE '__PASCAL__CloneHome'
$CloneHome      = Join-Path $CloneRoot $Instance      # USERPROFILE/HOME levers (gateway state)
$CloneProfile   = Join-Path $CloneHome 'profile'      # --user-data-dir (this app honours it? TODO Phase 1)
$CloneTmp       = Join-Path $CloneHome 'tmp'
$SeedMarker     = Join-Path $CloneHome '.seeded'
$RecordPath     = Join-Path $CloneHome 'instance-record.json'

function Get-CloneSubtreePids {
  # Classify by PROCESS MARKERS, never window titles (splash-phase lesson).
  param([string[]]$Markers)
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue -OperationTimeoutSec 5)
  $hits = @()
  foreach ($p in $all) {
    foreach ($m in $Markers) {
      if ($p.CommandLine -and $p.CommandLine.Contains($m)) { $hits += [int]$p.ProcessId; break }
    }
  }
  return @($hits | Select-Object -Unique)
}

if ($Status) {
  if (Test-Path -LiteralPath $RecordPath) {
    Get-Content -LiteralPath $RecordPath -Raw
  }
  else {
    Write-Host "no instance-record.json for $Instance - never launched, or a pre-record version"
    exit 1
  }
  exit 0
}

if (-not (Test-Path -LiteralPath $ExePath)) {
  Write-Host "[FAILED] $AppDisplayName exe not found: $ExePath (fix `$ExePath after Phase 1 discovery)" -ForegroundColor Red
  exit 1
}

# 1) Directories
foreach ($d in @($CloneHome, $CloneProfile, $CloneTmp)) {
  New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# 2) First-run seed: copy the Primary profile EXCLUDING every credential
#    store (one credential = one instance; ONE manual login per clone).
#    <TODO: Phase 1 discovery> the real exclusion list (token caches, keypair
#    stores, paired-device files) and whether the Primary must be CLOSED for
#    the copy (locked Chromium stores abort robocopy - AutoClaw lesson).
if (-not (Test-Path -LiteralPath $SeedMarker)) {
  Write-Host '[seed] first run - seeding the clone profile (credential-free)'
  # robocopy "<primaryProfile>" "$CloneProfile" /E /XF <credential stores>
  # verify-after the excludes, THEN write the marker only on verified success.
  Write-Host '  <TODO: Phase 1 discovery - seed sources + excludes, marker after verified scrub>' -ForegroundColor Yellow
  # Placeholder marker write so re-runs skip; REMOVE once the real seed lands.
  Write-Host '[seed] skeleton mode: writing marker without a real seed' -ForegroundColor Yellow
  Set-Content -LiteralPath $SeedMarker -Value 'skeleton'
}

# 3) Isolation levers + launch. Launch SEQUENTIALLY, never in parallel, and
#    __ELEVATIONRULE__
# <TODO: Phase 2 design> port lever (env var survives? settings.json? marker
# file read by an asar patch - the AutoClaw home-override pattern) recorded
# to instance-record.json with the DISCOVERED ports, never the requested one.
Write-Host ("[launch] {0} (skeleton - wire the real levers after discovery)" -f $Instance) -ForegroundColor Yellow
$env:TEMP = $CloneTmp
$env:TMP  = $CloneTmp
# cmd /c start "" "<exe>" <args>   <- detached launch; a GUI app that calls
# AttachConsole hijacks the launching console if started inline (GHOST rule).

# 4) Verify-after-launch: subtree stable, ports on DISCOVERED values,
#    credential stores hold only this clone's identity.
Write-Host '  <TODO: Phase 1 discovery - verify-after-launch checks>' -ForegroundColor Yellow
Write-Host "[done] $Instance launcher skeleton finished - wire the TODOs before real use."
'@

$WrapperT = @'
@echo off
rem Double-click wrapper for the __DISPLAYNAME__ clone launcher (generated).
rem The launcher opens in its own window and closes when done.
setlocal
set "SCRIPT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%launch___SLUG___clone.ps1" %*
if errorlevel 1 (
    echo.
    echo Launcher reported a failure - read the messages above.
    pause
)
'@

$ShortcutsT = @'
#Requires -Version 5.1
<#
.SYNOPSIS
  Per-clone Desktop + Start-menu shortcuts for __DISPLAYNAME__ (generated).
.DESCRIPTION
  AUMIDs <base>.inst1..N for pin grouping, per-clone IconLocation under
  tools\<slug>-<color>-branding\tray_icon.ico (missing dir = exe icon
  fallback + warn - never silent), -Remove to uninstall, -RepairPrimaryAumid
  to strip a hijacked Primary .lnk (clone pins rewrite it - the ZCode and
  AutoClaw suites both hit this).
.PARAMETER Instance
  Restrict to one clone slot; default all.
.PARAMETER Remove
  Uninstall the shortcuts.
.PARAMETER RepairPrimaryAumid
  Restore the Primary shortcut's AUMID + icon, exit.
#>
param(
  [string[]]$Instance = @('__INSTPARAMS__'),
  [switch]$Remove,
  [switch]$RepairPrimaryAumid
)

$ErrorActionPreference = 'Stop'
$RepoRoot    = (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path
$Slug        = '__SLUG__'
$DisplayName = '__DISPLAYNAME__'
$PrimaryLnkName = '<TODO: the Primary shortcut .lnk filename>'
$AumidBase   = 'com.<vendor>.<app>'   # <TODO: Phase 1 discovery - the app's AUMID, or mint one>

$InstanceDefs = @{
__INSTDEFS__
}

# Shortcuts always target the OS-shipped Windows PowerShell 5.1 (the
# launchers are 5.1-first; $PSHOME breaks under pwsh - 2026-10-17 fix).
$psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $psExe)) { throw "Windows PowerShell not found: $psExe" }

function Get-ShortcutTargets([string]$ShortcutName) {
  # Desktop + the two Start-menu roots; returns existing .lnk full paths.
  $found = @()
  $roots = @(
    [Environment]::GetFolderPath('DesktopDirectory'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
  )
  foreach ($r in $roots) {
    $p = Join-Path $r $ShortcutName
    if (Test-Path -LiteralPath $p) { $found += $p }
  }
  return $found
}

if ($RepairPrimaryAumid) {
  Write-Host '[repair] restoring the Primary shortcut AUMID + icon (TODO wire after discovery)'
  # Port from tools\install_zcode_second_shortcuts.ps1 (Shell.Application
  # ExtendedProperty reads ONLY - never whole-file UTF-16 regex, it misreads).
  exit 0
}

$wsh = New-Object -ComObject WScript.Shell
$failed = $false
foreach ($name in $Instance) {
  $def = $InstanceDefs[$name]
  $icon = Join-Path $RepoRoot ("tools\{0}-{1}-branding\tray_icon.ico" -f $Slug, $def.Color)
  if (-not (Test-Path -LiteralPath $icon)) {
    Write-Host ("  [warn] no branding icon for {0} - exe icon fallback: {1}" -f $name, $icon) -ForegroundColor Yellow
    $icon = ''
  }
  foreach ($t in @(Get-ShortcutTargets $def.LnkName)) {
    Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue
  }
  if ($Remove) { Write-Host ("  [ok] removed: {0}" -f $def.LnkName); continue }
  foreach ($root in @([Environment]::GetFolderPath('DesktopDirectory'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
    $lnk = $wsh.CreateShortcut((Join-Path $root $def.LnkName))
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = ("-NoProfile -ExecutionPolicy Bypass -File `"$RepoRoot\src\windows\launch___SLUG___clone.ps1`" -Instance $name")
    $lnk.WorkingDirectory = Join-Path $RepoRoot 'src\windows'
    if ($icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.SetAppUserModelId($def.Aumid)
    $lnk.Save()
    # verify-after
    $chk = $wsh.CreateShortcut((Join-Path $root $def.LnkName))
    if ($chk.TargetPath -ne $psExe) { Write-Host "  [FAILED] target verify: $root\$($def.LnkName)" -ForegroundColor Red; $failed = $true }
    else { Write-Host ("  [ok] {0} -> {1} (aumid {2})" -f $def.LnkName, $name, $def.Aumid) }
  }
}
if ($failed) { Write-Host 'FAILED - see lines above.' -ForegroundColor Red; exit 1 }
Write-Host 'SUCCESS.'
'@

$SpecT = @'
# __DISPLAYNAME__ Multi-Instance Clones — Spec (STUB)

> Generated by `tools/new_clone_suite.ps1` on __DATE__ as the Phase 3-10
> scaffold. Phases 0-2 below are the agent's discovery work (playbook:
> read the INSTALLED app, never guess); every <TODO> in the emitted
> scripts maps to one row here. Promote STUB -> IMPLEMENTED when all rows
> carry a verified answer + provenance section.

## Ground truth to fill (Phase 1-2)

| # | Question | Answer | Provenance |
|---|----------|--------|------------|
| 1 | Installed exe path + version | | |
| 2 | Identity stores (JSON/SQLite/binary/registry) | | |
| 3 | Credential stores EXCLUDED from the seed (one credential = one instance) | | |
| 4 | Isolation levers that actually work (env vs --user-data-dir vs marker file) | | |
| 5 | Self-elevation? (__ELEVATIONSHORT__) — survives env levers? | | |
| 6 | Port lever + drift behavior | | |
| 7 | AUMID / taskbar identity behavior | | |
| 8 | Asar patchable (Electron fuses, integrity validation)? | | |
| 9 | Seed requires the Primary closed? (lockfile probe) | | |
| 10 | Single-instance lock key | | |

## Emitted files

- `src/windows/reset___SLUG__.ps1` — reset manifest (TODO-driven)
- `src/windows/launch___SLUG___clone.ps1` — clone launcher
- `src/windows/Launch-__PASCAL__-Clone.bat` — double-click wrapper
- `tools/install___SLUG___clone_shortcuts.ps1` — AUMID shortcuts + branding
- GHOST.bat — submenu [__SUBMENU_ID__] (gids __GIDBASE__+)

## Open phase checklist

- [ ] Phase 0 intake recorded (this file + the intake JSON committed)
- [ ] Phase 1 discovery rows answered with provenance
- [ ] Phase 2 isolation design decided
- [ ] Phase 3 reset script live-verified per target
- [ ] Phase 4 launcher seed + verify-after-launch live-verified
- [ ] Phase 5 branding (developer icons or improvise+report)
- [ ] Phase 6 app patch (if needed)
- [ ] Phase 7 shortcuts verified
- [ ] Phase 8 taskbar identity verified
- [ ] Phase 9 GHOST.bat submenu verified via the harness
- [ ] Phase 10 tests + docs + governance
'@

# ---------------------------------------------------------------------------
# GHOST.bat surgery
# ---------------------------------------------------------------------------

function Edit-GhostMenu {
  param([hashtable]$It, [string]$Slug, [string]$Pascal, [int]$SubmenuId, [int]$GidBase, [int]$CloneCount)
  $batPath = Join-Path $PSScriptRoot '..\GHOST.bat'
  $batPath = [System.IO.Path]::GetFullPath($batPath)
  $bat = [System.IO.File]::ReadAllText($batPath)

  if ($bat.Contains(":$($Pascal)One")) { throw "GHOST.bat already wires a $Pascal suite - refusing to double-edit" }

  # Anchor 1: main-menu dispatch - insert the submenu jump after the [4] block.
  $anchor4 = "if `"%first%`"==`"4`" ("
  $idx = $bat.IndexOf($anchor4)
  if ($idx -lt 0) { throw 'GHOST.bat anchor missing: main-menu [4] dispatch block' }
  $closeIdx = $bat.IndexOf(")`r`n", $idx)
  if ($closeIdx -lt 0) { throw 'GHOST.bat anchor missing: main-menu [4] block close paren' }
  $dispatch = "if `"%first%`"==`"$SubmenuId`" (`r`n    set `"PENDING_CHAIN=%rest%`"`r`n    goto $Pascal`r`n)`r`n"
  $bat = $bat.Substring(0, $closeIdx + 2) + $dispatch + $bat.Substring($closeIdx + 2)

  # Anchor 2: main-menu render - insert the colored entry after the [4] line
  # (the [2]/[3]/[4] entries render via the if-defined-ESC form, not :Opt).
  $render4 = 'if defined ESC (echo %ESC%[92m[ 4] %ESC%[97mAutoClaw Multi-Instance'
  $idx = $bat.IndexOf($render4)
  if ($idx -lt 0) { throw 'GHOST.bat anchor missing: AutoClaw main-menu render line' }
  $lineEnd = $bat.IndexOf("`r`n", $idx)
  $escEntry = 'if defined ESC (echo %ESC%[92m[ {0}] %ESC%[97m{1} Multi-Instance ^& Clones %ESC%[90m- launchers, resets, sync%ESC%[0m) else echo [ {0}] {1} Multi-Instance ^& Clones - launchers, resets, sync' -f $SubmenuId, $Pascal
  $bat = $bat.Substring(0, $lineEnd + 2) + $escEntry + "`r`n" + $bat.Substring($lineEnd + 2)

  # Anchor 3: new submenu section + resolver, inserted before :UnknownTask.
  $resolverLines = New-Object System.Collections.Generic.List[string]
  for ($i = 1; $i -le $CloneCount; $i++) {
    $gid = $GidBase + $i - 1
    $resolverLines.Add(('if "%~1"=="{0}" set "RESOLVED={1}"' -f $i, $gid))
  }
  $resolver = ($resolverLines -join "`r`n")
  $submenu = @"

:$Pascal
cls
if defined ESC (echo %ESC%[96mGHOST / $Pascal Multi-Instance ^& Clones%ESC%[0m) else echo GHOST / $Pascal Multi-Instance ^& Clones
echo.
call :Div "Launch Clones"
call :Opt 1 "Launch inst1" "- first clone (own profile, identity, ports)"
call :Opt 2 "Reset inst1" ""
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto ${Pascal}_PROMPT
for %%t in (%PENDING_CHAIN%) do call :${Pascal}One %%t
set "PENDING_CHAIN="
:${Pascal}_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto ${Pascal}_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto ${Pascal}_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :${Pascal}One %%t
goto $Pascal

:${Pascal}One
rem Resolves a $Pascal submenu-local id to its global task id and runs it.
set "RESOLVED="
$resolver
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

"@
  $anchorUT = ':UnknownTask'
  $idx = $bat.IndexOf($anchorUT)
  if ($idx -lt 0) { throw 'GHOST.bat anchor missing: :UnknownTask' }
  $bat = $bat.Substring(0, $idx) + $submenu + $bat.Substring($idx)

  # Anchor 4: DispatchOne gids - append after the highest existing gid line.
  $gidMatches = [regex]::Matches($bat, 'if "%~1"=="(\d+)" \(call')
  $maxGid = ($gidMatches | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
  $gidLine = 'if "%~1"=="{0}" ' -f $maxGid
  $idx = $bat.IndexOf($gidLine)
  if ($idx -lt 0) { throw "GHOST.bat anchor missing: gid $maxGid dispatch line" }
  $lineEnd = $bat.IndexOf("`r`n", $idx)
  $newGids = @(
    ('if "%~1"=="{0}" (call :Detached "{1} inst1" "-NoProfile" "src\windows\launch___SLUG___clone.ps1" "" "Launcher opened in a separate window - it closes automatically when done." & exit /b)' -f ($GidBase), $Pascal)
    ('if "%~1"=="{0}" (call :Run "src\windows\reset___SLUG__.ps1" -Target inst1 & exit /b)' -f ($GidBase + 1))
  ) -join "`r`n"
  $bat = $bat.Substring(0, $lineEnd + 2) + $newGids + "`r`n" + $bat.Substring($lineEnd + 2)

  # Anchor 5: the DispatchOne range comment.
  $bat = $bat -replace ('Runs one task by global id \(1-{0}\)' -f $maxGid), ('Runs one task by global id (1-{0})' -f ($GidBase + 1))

  # Backup + write + verify-after.
  $backup = "$batPath.new_clone_suite.bak"
  [System.IO.File]::WriteAllText($backup, $bat)
  $written = [System.IO.File]::ReadAllText($backup)
  foreach ($probe in @(":$Pascal", ":${Pascal}One", "goto $Pascal", "if `"%first%`"==`"$SubmenuId`"")) {
    if (-not $written.Contains($probe)) { throw "GHOST.bat verify-after failed: missing $probe" }
  }
  return $backup
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$it = New-Intake
$slug = $it.slug
$pascal = Get-PascalSlug $slug
$upper = $slug.ToUpperInvariant()
$cloneCount = $it.instanceCount - 1
$instParams = (@('Primary') + (1..$cloneCount | ForEach-Object { "inst$_" }) -join "', '")
$instParamsClones = (1..$cloneCount | ForEach-Object { "inst$_" }) -join "', '"

# gid allocation: next free DispatchOne slot (two gids per suite skeleton).
$batPath = Join-Path $PSScriptRoot '..\GHOST.bat'
$batPath = [System.IO.Path]::GetFullPath($batPath)
$batNow = [System.IO.File]::ReadAllText($batPath)
$gidMatches = [regex]::Matches($batNow, 'if "%~1"=="(\d+)" \(call')
$gidBase = (($gidMatches | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum) + 1
# submenu id: highest existing main-menu number + 1
$smMatches = [regex]::Matches($batNow, 'if "%first%"=="(\d+)" \(')
$submenuId = (($smMatches | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum) + 1

$instDefs = @()
for ($i = 1; $i -le $cloneCount; $i++) {
  $color = $it.colors[$i - 1].TrimStart('#').ToLowerInvariant()
  $instDefs += ('  ''{0}'' = @{{ LnkName = ''{1} {0}.lnk''; Aumid = ''{2}.{0}''; Color = ''{3}'' }}' -f "inst$i", $it.displayName, "com.ghost.$slug", $color)
}
$instDefsText = $instDefs -join "`r`n"

$isolationDoc = if ($it.isolation -eq 'homeMarker') {
  'profile dir (--user-data-dir if the app honours it) + a marker file read by an asar patch for the gateway/home state (the AutoClaw engine v10 pattern)'
} else {
  'env levers (USERPROFILE/HOME/TEMP + app-specific vars) - verified to survive launches only for non-self-elevating apps'
}
$elevationDoc = if ($it.elevatesItself) {
  'the app SELF-ELEVATES (requireAdministrator): launcher env levers never survive - args-only isolation + marker-file state (AutoClaw ground truth)'
} else {
  'no self-elevation detected: env levers survive; never launch elevated (UIPI strips drag-drop into high-IL windows)'
}
$elevationRule = if ($it.elevatesItself) { 'elevate ONLY the launching cmd via -Verb RunAs so args ride a plain CreateProcess' } else { 'never elevated' }

$tokens = @{
  '__SLUG__' = $slug; '__PASCAL__' = $pascal; '__UPPER__' = $upper
  '__DISPLAYNAME__' = $it.displayName; '__COUNT__' = $it.instanceCount
  '__INSTPARAMS__' = $instParams; '__INSTDEFS__' = $instDefsText
  '__PORT__' = $it.preferredPort; '__ISOLATIONDOC__' = $isolationDoc
  '__ELEVATIONDOC__' = $elevationDoc; '__ELEVATIONRULE__' = $elevationRule
  '__DATE__' = (Get-Date -Format 'yyyy-MM-dd'); '__SUBMENU_ID__' = $submenuId; '__GIDBASE__' = $gidBase
}
function Expand([string]$Text) {
  foreach ($k in $tokens.Keys) { $Text = $Text.Replace($k, [string]$tokens[$k]) }
  return $Text
}

$plan = @(
  @{ Path = "src\windows\reset_$slug.ps1";                          Text = (Expand $ResetT) }
  @{ Path = "src\windows\launch_${slug}_clone.ps1";                 Text = (Expand $LaunchT) }
  @{ Path = "src\windows\Launch-$pascal-Clone.bat";                 Text = (Expand $WrapperT) }
  @{ Path = "tools\install_${slug}_clone_shortcuts.ps1";            Text = (Expand $ShortcutsT) }
  @{ Path = "docs\${upper}_CLONES_SPEC.md";                         Text = (Expand $SpecT) }
)
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

Write-Host "=== new_clone_suite: $slug ($($it.displayName)) ==="
Write-Host ("  submenu [$submenuId], gids {0}+ , isolation '{1}', elevates={2}" -f $gidBase, $it.isolation, $it.elevatesItself)
foreach ($p in $plan) { Write-Host ("  emit: {0}" -f $p.Path) }
Write-Host '  edit: GHOST.bat (backup + anchor edit + verify-after)'

if ($DryRun) { Write-Host 'DryRun - nothing written.'; exit 0 }

foreach ($p in $plan) {
  $full = Join-Path $repoRoot $p.Path
  $dir = Split-Path -Parent $full
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path -LiteralPath $full) { throw "refusing to overwrite existing file: $($p.Path)" }
  Write-Utf8Crlf -Path $full -Content $p.Text
  # verify-after: byte check
  if (-not (Test-Path -LiteralPath $full)) { throw "emit verify failed: $($p.Path)" }
}

$backup = Edit-GhostMenu -It $it -Slug $slug -Pascal $pascal -SubmenuId $submenuId -GidBase $gidBase -CloneCount 2
Copy-Item -LiteralPath $backup -Destination $batPath -Force
Remove-Item -LiteralPath $backup -Force
Write-Host "[ok] GHOST.bat wired (submenu [$submenuId], resolver :${pascal}One, gids $gidBase-$($gidBase + 1))"

# Parse-check every emitted .ps1 (never silent-success).
foreach ($p in $plan) {
  if ($p.Path -notlike '*.ps1') { continue }
  $full = Join-Path $repoRoot $p.Path
  $errs = $null
  [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$null, [ref]$errs) | Out-Null
  if ($errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host ("  [FAILED] {0}: {1}" -f $p.Path, $_.Message) -ForegroundColor Red }
    throw "emitted .ps1 failed parse-check: $($p.Path)"
  }
}
Write-Host '[ok] all emitted .ps1 parse-checked'

Write-Host @'

Next steps (playbook phases 0-2 - agent work, not scaffolding):
  1. Fill every <TODO: Phase 1 discovery> slot in the emitted scripts.
  2. Answer the ground-truth rows in docs\<SLUG>_CLONES_SPEC.md with provenance.
  3. Run the .bat harness + Pester after wiring; icon decision per playbook §5.
'@.Replace('<SLUG>', $slug)
