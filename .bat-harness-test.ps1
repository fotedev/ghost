# Harness: exercises GHOST.bat menu input handling on a TEST COPY.
# Runs locally and in CI (ci.yml windows job, "GHOST.bat menu harness");
# derives the repo root from its own location so it works on any checkout.
# stdin redirection is unusable here (the launcher's ESC-capture powershell
# child drains redirected stdin, starving every set /p), so the copy reads
# answers from %TESTINPUT% line-by-line via a for /f counter instead.
# Answers: one per line, CRLF; no empty lines (for /f skips them; the
# interactive bare-Enter path is covered by the 'if not defined choice'
# guards and a space-only answer exercises the tokenless-input path).
# NOTE: some cmd builds reject skip=0 inside for /f options with a parse
# error ("delims= was unexpected"), so paging goes through `more +N`
# (which accepts +0) instead of `skip=N`.
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$work = Join-Path $env:TEMP 'ghost-bat-harness'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

# --- build the test copy -------------------------------------------------------
$src = [System.IO.File]::ReadAllText("$repo\GHOST.bat")
$count = ([regex]::Matches($src, [regex]::Escape('set /p choice=%PROMPT_TEXT%'))).Count
# Floor 5 = main + the four hand-written submenus; generated clone suites
# (tools\new_clone_suite.ps1) add one prompt per new submenu and the global
# rewrite below covers every occurrence, so the check guards the floor only.
if ($count -lt 5) { throw "expected at least 5 set /p sites in GHOST.bat (main + 4 submenus), found $count" }
$copy = $src.Replace('set /p choice=%PROMPT_TEXT%', 'call :TestNextInput choice')
$sub = @'

:TestNextInput
rem === HARNESS-ONLY: next answer comes from %TESTINPUT% (TESTIDX = next line, 0-based).
rem skip=0 is a parse error on this cmd build, so page with more +N and keep
rem the first line; the read cap stops an exhausted-input runaway loop.
if not defined TESTIDX set "TESTIDX=0"
set /a TESTREADS=TESTREADS+1
if %TESTREADS% GTR 200 (
    echo HARNESS: read cap hit - input exhausted in a loop
    exit 9
)
set "TESTANSWER="
for /f "usebackq delims=" %%a in (`more +%TESTIDX% "%TESTINPUT%"`) do (
    if not defined TESTANSWER set "TESTANSWER=%%a"
)
set /a TESTIDX=TESTIDX+1
set "%~1=%TESTANSWER%"
goto :eof
'@
$copy = $copy + ($sub -replace "`n", "`r`n")
$testCopy = Join-Path $work 'TestGhost.bat'
[System.IO.File]::WriteAllText($testCopy, $copy, [System.Text.Encoding]::ASCII)

function New-Input([string]$Name, [string[]]$Lines) {
    $p = Join-Path $work "$Name.in.txt"
    [System.IO.File]::WriteAllText($p, (($Lines | ForEach-Object { $_ + "`r`n" }) -join ''))
    return $p
}

function Invoke-Scenario([string]$Name, [string[]]$Lines) {
    $inFile = New-Input $Name $Lines
    $outFile = Join-Path $work "$Name.out.txt"
    $env:TESTINPUT = $inFile
    $env:TESTIDX = '0'
    $env:TESTREADS = '0'
    cmd /c "`"$testCopy`" > `"$outFile`" 2>&1"
    Remove-Item Env:TESTINPUT -ErrorAction SilentlyContinue
    Remove-Item Env:TESTIDX -ErrorAction SilentlyContinue
    Remove-Item Env:TESTREADS -ErrorAction SilentlyContinue
    return (Get-Content $outFile -Raw)
}

$failures = @()

# A) plain exit at main menu -> Done, zero Unknown task, zero literal junk
$out = Invoke-Scenario 'A_plain_exit' @('0')
if ($out -match 'Unknown task')            { $failures += 'A: Unknown task on plain exit' }
if ($out -match '%choice|%PENDING_CHAIN%') { $failures += 'A: literal variable text leaked' }
if ($out -notmatch 'Done\.')               { $failures += 'A: never reached exit' }

# B) open ZCode submenu (PENDING_CHAIN undefined), back, exit -> no bogus line
$out = Invoke-Scenario 'B_submenu_render' @('2', '0', '0')
if ($out -match 'Unknown task')            { $failures += 'B: Unknown task on plain submenu render' }
if ($out -match '%PENDING_CHAIN%')         { $failures += 'B: literal %PENDING_CHAIN% leaked' }
if ($out -notmatch 'ZCode Multi-Instance') { $failures += 'B: ZCode submenu not shown' }

# C) tokenless input inside ZCode submenu -> silent re-render, then back, exit
$out = Invoke-Scenario 'C_space_submenu' @('2', ' ', '0', '0')
if ($out -match 'Unknown task')            { $failures += 'C: Unknown task on tokenless submenu input' }
if ($out -notmatch 'ZCode Multi-Instance') { $failures += 'C: ZCode submenu not shown' }

# D) invalid main-menu id -> exactly one legit Unknown task "99"
$out = Invoke-Scenario 'D_invalid_main' @('99', '0')
$hits = ([regex]::Matches($out, 'Unknown task "99"')).Count
if ($hits -ne 1)                           { $failures += "D: expected 1 legit Unknown task, got $hits" }

# E) main sub-path "2 99" -> chain reaches ZCodeOne, exactly one legit
#    Unknown task, and the PENDING_CHAIN literal never appears
$out = Invoke-Scenario 'E_subpath_chain' @('2 99', '0', '0')
$hits = ([regex]::Matches($out, 'Unknown task "99"')).Count
if ($hits -ne 1)                           { $failures += "E: expected 1 Unknown task from chain, got $hits" }
if ($out -match '%PENDING_CHAIN%')         { $failures += 'E: literal %PENDING_CHAIN% leaked' }
if ($out -notmatch 'ZCode Multi-Instance') { $failures += 'E: ZCode submenu not reached via sub-path' }

# F) new ZCode submenu entry renders: [17] Freeze diagnostic is listed
$out = Invoke-Scenario 'F_new_entry_render' @('2', '0', '0')
if ($out -notmatch '\[17\].*Freeze diagnostic') { $failures += 'F: ZCode submenu [17] Freeze diagnostic not rendered' }

# G) invalid ZCode submenu id -> exactly one legit Unknown task "42"
$out = Invoke-Scenario 'G_invalid_zcode' @('2', '42', '0', '0')
$hits = ([regex]::Matches($out, 'Unknown task "42"')).Count
if ($hits -ne 1)                           { $failures += "G: expected 1 Unknown task from ZCode submenu, got $hits" }

# H) open AutoClaw submenu (PENDING_CHAIN undefined), back, exit -> clean render
$out = Invoke-Scenario 'H_autoclaw_render' @('4', '0', '0')
if ($out -match 'Unknown task')               { $failures += 'H: Unknown task on AutoClaw submenu render' }
if ($out -match '%PENDING_CHAIN%')            { $failures += 'H: literal %PENDING_CHAIN% leaked' }
if ($out -notmatch 'AutoClaw Multi-Instance') { $failures += 'H: AutoClaw submenu not shown' }

# I) invalid AutoClaw chain id "4 42" -> exactly one legit Unknown task "42"
$out = Invoke-Scenario 'I_invalid_autoclaw' @('4 42', '0', '0')
$hits = ([regex]::Matches($out, 'Unknown task "42"')).Count
if ($hits -ne 1)                           { $failures += "I: expected 1 Unknown task from AutoClaw chain, got $hits" }
if ($out -match '%PENDING_CHAIN%')         { $failures += 'I: literal %PENDING_CHAIN% leaked' }

# J) hostile main-menu input - :ValidateChoice must reject (never execute)
#    the injected command, show the hint, re-prompt, then exit cleanly
$out = Invoke-Scenario 'J_hostile_main' @('1 & calc', '0')
if ($out -match 'calc')               { $failures += 'J: injection attempt leaked through main prompt' }
if ($out -notmatch 'Invalid input')   { $failures += 'J: rejection hint missing' }

# K) hostile main-menu input with parens - PWNED must never execute
$out = Invoke-Scenario 'K_hostile_parens' @('2 ) & echo PWNED', '0')
if ($out -match 'PWNED')              { $failures += 'K: paren-amp injection executed' }

# L) hostile ZCode submenu input - rejected at the submenu prompt
$out = Invoke-Scenario 'L_hostile_zcode' @('2', '1 & calc', '0', '0')
if ($out -match 'calc')               { $failures += 'L: injection attempt leaked through ZCode prompt' }
if ($out -notmatch 'Invalid input')   { $failures += 'L: rejection hint missing' }

if ($failures.Count -gt 0) {
    Write-Output 'HARNESS FAIL:'
    $failures | ForEach-Object { Write-Output "  - $_" }
    exit 1
}
Write-Output 'HARNESS PASS: all 12 scenarios clean'
# Explicit exit: pwsh -File propagates the last native \$LASTEXITCODE, and the
# scenarios' cmd exit code inherits GHOST.bat's `timeout` calls, which fail on
# CI consoles (no interactive stdin) AFTER the PASS line was already printed.
exit 0
