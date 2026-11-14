@echo off
chcp 65001 >nul
title GHOST - Guided Hardware and OS Scrubbing Toolkit
cd /d "%~dp0"

rem Enable ANSI VT on this console (session-local, no registry writes) and capture the ESC char.
for /f "delims=" %%a in ('powershell -NoProfile -Command "$d='[DllImport(\"kernel32.dll\")]public static extern IntPtr GetStdHandle(int h);[DllImport(\"kernel32.dll\")]public static extern bool SetConsoleMode(IntPtr h,int m);'; Add-Type -MemberDefinition $d -Name Con -Namespace W; [void][W.Con]::SetConsoleMode([W.Con]::GetStdHandle(-11),7); [Console]::Out.Write([string][char]27)"') do set "ESC=%%a"
set "PROMPT_TEXT=Enter your choice: "
if defined ESC set "PROMPT_TEXT=%ESC%[93mEnter your choice: %ESC%[0m"

:MAIN
cls
call :Banner
call :Hdr " ---- GHOST main menu ----"
echo.
call :Opt 1 "IDE Resets" "- device ID + 8 IDE suites"
if defined ESC (echo %ESC%[92m[ 2] %ESC%[97mZCode Multi-Instance ^& Clones %ESC%[90m- launchers, resets, sync%ESC%[0m) else echo [ 2] ZCode Multi-Instance ^& Clones - launchers, resets, sync
if defined ESC (echo %ESC%[92m[ 3] %ESC%[97mSystem ^& GHOST Maintenance %ESC%[90m- shortcuts, watchers, updates%ESC%[0m) else echo [ 3] System ^& GHOST Maintenance - shortcuts, watchers, updates
if defined ESC (echo %ESC%[92m[ 4] %ESC%[97mAutoClaw2 Multi-Instance ^& Clones %ESC%[90m- launchers, shortcuts%ESC%[0m) else echo [ 4] AutoClaw2 Multi-Instance ^& Clones - launchers, shortcuts
if defined ESC (echo %ESC%[92m[ 5] %ESC%[97mCline Multi-Instance ^& Clones %ESC%[90m- launchers, clone status%ESC%[0m) else echo [ 5] Cline Multi-Instance ^& Clones - launchers, clone status
if defined ESC (echo %ESC%[92m[ 6] %ESC%[97mOpenCode Multi-Instance ^& Clones %ESC%[90m- launchers, clone-home patch%ESC%[0m) else echo [ 6] OpenCode Multi-Instance ^& Clones - launchers, clone-home patch
echo.
call :Opt U "Check for updates / update GHOST" "- from GitHub"
call :Opt 0 "Exit" ""
if defined ESC (echo %ESC%[90mTip: You can run multiple options at once by separating them with commas ^(e.g. %ESC%[96m1, 3, 4%ESC%[90m^)%ESC%[0m) else echo Tip: You can run multiple options at once by separating them with commas ^(e.g. 1, 3, 4^)
echo.
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto MAIN
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    timeout /t 2 >nul
    goto MAIN
)
if "%choice%"=="0" (
    echo Done.
    timeout /t 1 >nul
    exit
)
set "chain=%choice:,= %"
set "first="
set "rest="
for /f "tokens=1,*" %%a in ("%chain%") do (
    set "first=%%a"
    set "rest=%%b"
)
if "%first%"=="1" (
    set "PENDING_CHAIN=%rest%"
    goto RESETS
)
if "%first%"=="2" (
    set "PENDING_CHAIN=%rest%"
    goto ZCODE
)
if "%first%"=="3" (
    set "PENDING_CHAIN=%rest%"
    goto MAINT
)
if "%first%"=="4" (
    set "PENDING_CHAIN=%rest%"
    goto AUTOCLAW
)
if "%first%"=="5" (
    set "PENDING_CHAIN=%rest%"
    goto CLINE
)
if "%first%"=="6" (
    set "PENDING_CHAIN=%rest%"
    goto OPENCODE
)
if /i "%first%"=="U" if "%rest%"=="" (
    call :Run "tools\update_ghost.ps1"
    goto MAIN
)
call :RunChain %chain%
goto MAIN

:RESETS
cls
call :Crumb "IDE Resets"
echo.
call :Opt 1 "Change Device ID" "- machine-wide: ALL instances + Qoder - reboot required"
call :Opt 2 "Reset Cursor" ""
call :Opt 3 "Reset Windsurf\Devin" ""
call :Opt 4 "Reset Trae" ""
call :Opt 5 "Reset Qoder" ""
call :Opt 6 "Reset QoderWork" ""
call :Opt 7 "Reset ZCode Primary instance" ""
call :Opt 8 "Reset MiniMax/OpenCode" ""
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto RESETS_PROMPT
for %%t in (%PENDING_CHAIN%) do call :ResetsOne %%t
set "PENDING_CHAIN="
:RESETS_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto RESETS_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto RESETS_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :ResetsOne %%t
goto RESETS

:ZCODE
cls
if defined ESC (echo %ESC%[96mGHOST / ZCode Multi-Instance ^& Clones%ESC%[0m) else echo GHOST / ZCode Multi-Instance ^& Clones
echo.
call :Div "Launch Clones"
call :Opt 1 "Launch Blue clone" "- independent window"
call :Opt 2 "Launch Yellow clone" "- independent window"
call :Opt 3 "Launch Green clone" "- independent window"
call :Opt 4 "Launch Red clone" "- independent window"
call :Opt 5 "Launch Orange clone" "- independent window"
call :Opt 6 "Launch ALL clones" "- Blue..Orange, one after another"
call :Opt 7 "Launch light headless worker" "- run a clone account with no desktop window - low RAM"
call :Opt 8 "Install clone shortcuts" "- all 5 - Desktop + Start menu"
call :Opt 9 "Launch ZCode Primary" "- non-elevated - Primary profile"
echo.
call :Div "Reset Clones"
call :Opt 10 "Reset Blue clone" "- survivors kept running"
call :Opt 11 "Reset Yellow clone" "- survivors kept running"
call :Opt 12 "Reset Green clone" "- survivors kept running"
call :Opt 13 "Reset Red clone" "- survivors kept running"
call :Opt 14 "Reset Orange clone" "- survivors kept running"
call :Opt 15 "Reset ZCode Primary instance" "- Primary profile - chats kept"
call :Opt 16 "Reset Blue + Primary" "(independent IDs)"
call :Opt 17 "Reset ALL SIX instances" "(independent IDs)"
echo.
call :Div "Sync + Chat Refresh"
call :Opt 18 "Sync clone assets" "- MCPs + skills + plugins from Primary"
call :Opt 19 "Sync MCPs to all clones" "- live - running instances included"
call :Opt 20 "MCP sync watcher" "- auto-sync on Primary change (separate window)"
call :Opt 21 "Sync MCPs + apply live now" "- recycles running instances - idle-guarded"
call :Opt 22 "Refresh Blue chats" "- show Primary chats without app restart"
call :Opt 23 "Refresh ALL chats" "- re-index every running sidebar"
call :Opt 24 "Watch errors" "- auto-refresh chats on quota or captcha failure"
echo.
call :Div "Watchers + Diagnostics"
call :Opt 25 "Captcha watchdog" "(unattended, separate window)"
call :Opt 26 "Taskbar identity watcher" "- auto-fix taskbar merges (separate window)"
call :Opt 27 "Freeze diagnostic" "- dead windows, renderer OOM, commit pressure"
echo.
call :Div "Maintenance"
call :Opt 28 "Re-apply app patch" "- v9, icons + bidi auto (after app update)"
call :Opt 29 "Login clone account" "- one-time plan setup (light workers + T3 bridge)"
call :Opt 30 "Remove clone shortcuts" "- Desktop + Start menu"
call :Opt 31 "Rebuild clone Task Manager icons" "- colored rows in Task Manager - run after app updates"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto ZCODE_PROMPT
for %%t in (%PENDING_CHAIN%) do call :ZCodeOne %%t
set "PENDING_CHAIN="
:ZCODE_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto ZCODE_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto ZCODE_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :ZCodeOne %%t
goto ZCODE

:MAINT
cls
if defined ESC (echo %ESC%[96mGHOST / System ^& GHOST Maintenance%ESC%[0m) else echo GHOST / System ^& GHOST Maintenance
echo.
call :Opt 1 "Install or repair the GHOST shortcut" "- Desktop + repo folder"
call :Opt 2 "Check for updates / update GHOST" "- from GitHub"
call :Opt 3 "Spoof WMI hardware serials" "- BIOS, motherboard, disk, RAM + Bluetooth MAC"
call :Opt 4 "Sync MCP registry to apps" "- ZCode, Windsurf, VS Code + MiniMax"
call :Opt 5 "Build GHOST desktop app" "- GHOST.exe in the repo root"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto MAINT_PROMPT
for %%t in (%PENDING_CHAIN%) do call :MaintOne %%t
set "PENDING_CHAIN="
:MAINT_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto MAINT_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto MAINT_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :MaintOne %%t
goto MAINT

:AUTOCLAW
cls
if defined ESC (echo %ESC%[96mGHOST / AutoClaw2 Multi-Instance ^& Clones%ESC%[0m) else echo GHOST / AutoClaw2 Multi-Instance ^& Clones
echo.
call :Div "Launch Clones"
call :Opt 1 "Launch Blue clone" "- own profile, identity, sign-in"
call :Opt 2 "Launch Yellow clone" ""
call :Opt 3 "Launch Green clone" ""
call :Opt 4 "Launch Red clone" ""
call :Opt 5 "Launch Orange clone" ""
call :Opt 6 "Launch ALL clones" "- Blue..Orange, one after another"
call :Opt 7 "Install clone shortcuts" "- all 5 - Desktop + Start menu"
echo.
call :Div "Sync + Chat Import"
call :Opt 8 "Import MCPs to clones" "- from the central master manifest"
call :Opt 9 "Chat inventory" "- read-only cross-profile report"
call :Opt 10 "Import chats to clones" "- every missing Primary chat - one-way - clone windows must be closed"
echo.
call :Div "Maintenance"
call :Opt 11 "Clone status" "- all 5 - locks, device-id, sign-in state"
call :Opt 12 "Remove clone shortcuts" "- Desktop + Start menu"
call :Opt 13 "Apply clone identity patch" "- colored taskbar buttons - waits for AutoClaw2 to close"
echo.
call :Div "Identity Resets"
call :Opt 14 "Reset Blue clone" "- chats + work kept"
call :Opt 15 "Reset Yellow clone" "- chats + work kept"
call :Opt 16 "Reset Green clone" "- chats + work kept"
call :Opt 17 "Reset Red clone" "- chats + work kept"
call :Opt 18 "Reset Orange clone" "- chats + work kept"
call :Opt 19 "Reset Primary" "- default profile - chats + work kept"
call :Opt 20 "Reset ALL profiles" "- Blue..Orange + Primary - asks first"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto AUTOCLAW_PROMPT
for %%t in (%PENDING_CHAIN%) do call :AutoClawOne %%t
set "PENDING_CHAIN="
:AUTOCLAW_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto AUTOCLAW_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto AUTOCLAW_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :AutoClawOne %%t
goto AUTOCLAW

:CLINE
cls
if defined ESC (echo %ESC%[96mGHOST / Cline Multi-Instance ^& Clones%ESC%[0m) else echo GHOST / Cline Multi-Instance ^& Clones
echo.
call :Div "Launch Clones"
call :Opt 1 "Launch Blue clone" "- own state, web login, ports"
call :Opt 2 "Launch Yellow clone" ""
call :Opt 3 "Launch Green clone" ""
call :Opt 4 "Launch Red clone" ""
call :Opt 5 "Launch Orange clone" ""
call :Opt 6 "Launch ALL clones" "- Blue..Orange, one after another"
call :Opt 7 "Install clone shortcuts" "- all 5 - Desktop + Start menu"
echo.
call :Div "Maintenance"
call :Opt 8 "Clone status" "- all 5 - locks, ports, sign-in state"
call :Opt 9 "Remove clone shortcuts" "- Desktop + Start menu"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto CLINE_PROMPT
for %%t in (%PENDING_CHAIN%) do call :ClineOne %%t
set "PENDING_CHAIN="
:CLINE_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto CLINE_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto CLINE_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :ClineOne %%t
goto CLINE

:OPENCODE
cls
if defined ESC (echo %ESC%[96mGHOST / OpenCode Multi-Instance ^& Clones%ESC%[0m) else echo GHOST / OpenCode Multi-Instance ^& Clones
echo.
call :Div "Launch Clones"
call :Opt 1 "Launch Blue clone" "- own clone home, login, identity"
call :Opt 2 "Launch Yellow clone" ""
call :Opt 3 "Launch Green clone" ""
call :Opt 4 "Launch Red clone" ""
call :Opt 5 "Launch Orange clone" ""
call :Opt 6 "Launch ALL clones" "- Blue..Orange, one after another"
call :Opt 7 "Launch light headless worker" "- CLI only - no desktop window - low RAM"
call :Opt 8 "Login clone account" "- one-time setup for the light worker"
call :Opt 9 "Install clone shortcuts" "- all 5 - Desktop + Start menu"
echo.
call :Div "Maintenance"
call :Opt 10 "Apply clone-home patch" "- required once - waits until OpenCode closes"
call :Opt 11 "Clone status" "- all 5 - locks, identity, sign-in state"
call :Opt 12 "Remove clone shortcuts" "- Desktop + Start menu"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
if not defined PENDING_CHAIN goto OPENCODE_PROMPT
for %%t in (%PENDING_CHAIN%) do call :OpenCodeOne %%t
set "PENDING_CHAIN="
:OPENCODE_PROMPT
set "choice="
set /p choice=%PROMPT_TEXT%
if not defined choice goto OPENCODE_PROMPT
call :ValidateChoice choice
if errorlevel 1 (
    echo   Invalid input - menu numbers only, separated by spaces or commas.
    goto OPENCODE_PROMPT
)
if "%choice%"=="0" goto MAIN
for %%t in (%choice:,= %) do call :OpenCodeOne %%t
goto OPENCODE

:UnknownTask
rem Red "not found" message for a bad task id (shared by all resolvers).
if defined ESC echo %ESC%[91mUnknown task "%~1" - check the menu and try again.%ESC%[0m
if not defined ESC echo Unknown task "%~1" - check the menu and try again.
exit /b

:ValidateChoice
rem %1 = NAME of the variable holding raw user input. errorlevel 1 = reject.
rem Allowlist: digits, spaces, commas, U/u - menu ids, chain separators and
rem the update shortcut. Everything else (quotes, ampersands, parens, carets,
rem percent signs, non-ASCII) is rejected BEFORE any expansion uses the value,
rem so the unquoted %%chain%% / %%choice%% expansions downstream can never
rem split tokens or inject commands (self-input hardening, 2026-10-17).
rem The probe runs in an isolated delayed-expansion scope: !var! values are
rem post-parse DATA, so hostile characters cannot break out of the probe
rem itself. ('!' in the raw value vanishes inside the probe and is inert to
rem %-expansion, so a value carrying it can safely pass the allowlist.)
setlocal EnableDelayedExpansion EnableExtensions
set "VC_VAL=!%~1!"
if not defined VC_VAL ( endlocal & exit /b 1 )
rem Space must be the LAST delim char (for /f splits option groups at spaces
rem and commas - a mid-string space breaks the options parse). eol=; is the
rem default and stays: a value starting with ';' skips the probe but ';' is
rem inert to cmd expansion, so the residual risk is an Unknown-task token.
for /f "eol=; delims=0123456789,Uu " %%z in ("!VC_VAL!") do ( endlocal & exit /b 1 )
endlocal & exit /b 0

:ResetsOne
rem Resolves an IDE Resets submenu-local id to its global task id and runs it.
rem Local ids 1-8 equal the global ids. The old [9] Reset AutoClaw - gid 28 -
rem was retired 2026-10-29 with the v1.20 app; gid 28 is the AutoClaw2 c1 launch.
set "RESOLVED="
if "%~1"=="1" set "RESOLVED=1"
if "%~1"=="2" set "RESOLVED=2"
if "%~1"=="3" set "RESOLVED=3"
if "%~1"=="4" set "RESOLVED=4"
if "%~1"=="5" set "RESOLVED=5"
if "%~1"=="6" set "RESOLVED=6"
if "%~1"=="7" set "RESOLVED=7"
if "%~1"=="8" set "RESOLVED=8"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:ZCodeOne
rem Resolves a ZCode submenu-local id to its global task id and runs it.
rem Renumbered 2026-10-29: local ids follow display order (1-29 ascending,
rem grouped Launch / Reset / Sync + Chat Refresh / Watchers + Diagnostics /
rem Maintenance [27]-[29]). Gids unchanged - old local -> gid map in
rem CHANGELOG 2026-10-29; [29] Remove = gid 72 (2026-10-31).
rem Renumbered 2026-11-10: "Launch ZCode Primary" (gid 82) inserted as local
rem [9]; locals 9-29 shifted to 10-30. Gids unchanged - old->new map:
rem 9-29 -> 10-30 (CHANGELOG 2026-11-10).
rem Added 2026-11-11: [31] Rebuild clone Task Manager icons = gid 83 (new,
rem appended in display order - no renumber, gids never move).
set "RESOLVED="
if "%~1"=="1"  set "RESOLVED=10"
if "%~1"=="2"  set "RESOLVED=16"
if "%~1"=="3"  set "RESOLVED=17"
if "%~1"=="4"  set "RESOLVED=41"
if "%~1"=="5"  set "RESOLVED=64"
if "%~1"=="6"  set "RESOLVED=18"
if "%~1"=="7"  set "RESOLVED=70"
if "%~1"=="8"  set "RESOLVED=14"
if "%~1"=="9"  set "RESOLVED=82"
if "%~1"=="10" set "RESOLVED=11"
if "%~1"=="11" set "RESOLVED=19"
if "%~1"=="12" set "RESOLVED=20"
if "%~1"=="13" set "RESOLVED=42"
if "%~1"=="14" set "RESOLVED=65"
if "%~1"=="15" set "RESOLVED=7"
if "%~1"=="16" set "RESOLVED=12"
if "%~1"=="17" set "RESOLVED=21"
if "%~1"=="18" set "RESOLVED=43"
if "%~1"=="19" set "RESOLVED=67"
if "%~1"=="20" set "RESOLVED=68"
if "%~1"=="21" set "RESOLVED=69"
if "%~1"=="22" set "RESOLVED=15"
if "%~1"=="23" set "RESOLVED=23"
if "%~1"=="24" set "RESOLVED=22"
if "%~1"=="25" set "RESOLVED=9"
if "%~1"=="26" set "RESOLVED=25"
if "%~1"=="27" set "RESOLVED=27"
if "%~1"=="28" set "RESOLVED=13"
if "%~1"=="29" set "RESOLVED=71"
if "%~1"=="30" set "RESOLVED=72"
if "%~1"=="31" set "RESOLVED=83"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:MaintOne
rem Resolves a Maintenance submenu-local id to its global task id and runs it.
set "RESOLVED="
if "%~1"=="1" set "RESOLVED=24"
if "%~1"=="2" set "RESOLVED=26"
if "%~1"=="3" set "RESOLVED=66"
if "%~1"=="4" set "RESOLVED=77"
if "%~1"=="5" set "RESOLVED=81"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:AutoClawOne
rem Resolves an AutoClaw2 submenu-local id to its global task id and runs it.
rem Rewired 2026-10-29 to the AutoClaw2 (zwork) suite: the v1.20 app was
rem uninstalled from the host, so its launch/reset/patch/status items left the
rem menu and dispatch cases 37-40 + 71 were retired; local ids 1-9 map to the
rem reused gids 28-36. Old v1.20 map: CHANGELOG 2026-10-29. 2026-11-04:
rem locals 8-10 are the new Sync + Chat Import section (gids 73/75/76; the
rem MCP watcher row is deferred and keeps gid 74), Maintenance moved to 11-12.
rem 2026-11-06: local 13 = the window identity patch (gid 78) - colored
rem taskbar buttons for the running clone windows.
rem 2026-11-14: locals 14-20 = the Identity Resets section (gids 84-90;
rem reset_autoclaw2.ps1 -Target c1..c5|Primary|All; the ALL row is gated).
set "RESOLVED="
if "%~1"=="1" set "RESOLVED=28"
if "%~1"=="2" set "RESOLVED=29"
if "%~1"=="3" set "RESOLVED=30"
if "%~1"=="4" set "RESOLVED=31"
if "%~1"=="5" set "RESOLVED=32"
if "%~1"=="6" set "RESOLVED=33"
if "%~1"=="7" set "RESOLVED=34"
if "%~1"=="8" set "RESOLVED=73"
if "%~1"=="9" set "RESOLVED=75"
if "%~1"=="10" set "RESOLVED=76"
if "%~1"=="11" set "RESOLVED=35"
if "%~1"=="12" set "RESOLVED=36"
if "%~1"=="13" set "RESOLVED=78"
if "%~1"=="14" set "RESOLVED=84"
if "%~1"=="15" set "RESOLVED=85"
if "%~1"=="16" set "RESOLVED=86"
if "%~1"=="17" set "RESOLVED=87"
if "%~1"=="18" set "RESOLVED=88"
if "%~1"=="19" set "RESOLVED=89"
if "%~1"=="20" set "RESOLVED=90"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:ClineOne
rem Resolves a Cline submenu-local id to its global task id and runs it.
rem Renumbered 2026-10-29: display order (1-9 ascending, c4/c5 before ALL +
rem shortcuts). Gids unchanged - old local -> gid map in CHANGELOG 2026-10-29.
set "RESOLVED="
if "%~1"=="1" set "RESOLVED=44"
if "%~1"=="2" set "RESOLVED=46"
if "%~1"=="3" set "RESOLVED=47"
if "%~1"=="4" set "RESOLVED=49"
if "%~1"=="5" set "RESOLVED=50"
if "%~1"=="6" set "RESOLVED=48"
if "%~1"=="7" set "RESOLVED=45"
if "%~1"=="8" set "RESOLVED=51"
if "%~1"=="9" set "RESOLVED=52"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:OpenCodeOne
rem Resolves an OpenCode submenu-local id to its global task id and runs it.
rem 2026-11-07: light worker [7] (gid 79) + login [8] (gid 80) added to Launch
rem Clones on the ZCode LIGHT pattern; shortcuts/patch/status/remove shifted
rem to [9]-[12]. Local ids renumbered, gids 53-62 unchanged (gids NEVER move).
set "RESOLVED="
if "%~1"=="1" set "RESOLVED=53"
if "%~1"=="2" set "RESOLVED=54"
if "%~1"=="3" set "RESOLVED=55"
if "%~1"=="4" set "RESOLVED=56"
if "%~1"=="5" set "RESOLVED=57"
if "%~1"=="6" set "RESOLVED=58"
if "%~1"=="7" set "RESOLVED=79"
if "%~1"=="8" set "RESOLVED=80"
if "%~1"=="9" set "RESOLVED=60"
if "%~1"=="10" set "RESOLVED=59"
if "%~1"=="11" set "RESOLVED=61"
if "%~1"=="12" set "RESOLVED=62"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:DispatchOne
rem Runs one task by global id (1-90; 63 unused; 74 reserved for the deferred
rem AutoClaw2 MCP watcher; 78 = the AutoClaw2 identity patch; 79/80 = the
rem OpenCode light worker + clone login; 81 = the desktop-app builder;
rem 82 = the ZCode Primary launcher; 83 = the clone Task Manager exe identity;
rem 84-90 = the AutoClaw2 identity resets, appended 2026-11-14).
rem Unknown ids
rem print an error. Returns to caller.
rem gid 1 (2026-11-10): the bare :Run dispatched the script's DEFAULT mode
rem (-Mode Fingerprint), a READ-ONLY self-test that printed JSON and changed
rem nothing - the menu row never reset anything. It now runs the actual reset
rem (-Mode LegacyReset) behind the :ConfirmRun gate.
if "%~1"=="1"  (call :ConfirmRun "Change Device ID - machine-wide identity reset" "src\windows\change_device_id.ps1" "This rewrites MachineGuid, SQM DeviceId, ProductId, RegisteredOwner, per-user session IDs + renames the PC to a DESKTOP-style name. A reboot is required. Registry backups + a restore script are generated first." -Mode LegacyReset & exit /b)
if "%~1"=="2"  (call :Run "src\windows\reset_cursor.ps1" & exit /b)
if "%~1"=="3"  (call :Run "src\windows\reset_devin.ps1" & exit /b)
if "%~1"=="4"  (call :Run "src\windows\reset_trae.ps1" & exit /b)
if "%~1"=="5"  (call :Run "src\windows\reset_qoder.ps1" & exit /b)
if "%~1"=="6"  (call :Run "src\windows\reset_qoderwork.ps1" & exit /b)
if "%~1"=="7"  (call :RunZcodeReset "src\windows\reset_zcode.ps1" -Target Primary & exit /b)
if "%~1"=="8"  (call :Run "src\windows\reset_minimax_opencode.ps1" & exit /b)
if "%~1"=="9"  (call :Detached "ZCode captcha watch" "-NoExit -NoProfile" "tools\watch_zcode_captcha.ps1" "" "Watchdog launched in a separate window - leave it open." "To verify it runs: check %LOCALAPPDATA%\watch-zcode-captcha\watch.log" & exit /b)
if "%~1"=="10" (call :Detached "ZCode Blue" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="11" (call :RunZcodeReset "src\windows\reset_zcode.ps1" -Target Secondary & exit /b)
if "%~1"=="12" (call :ConfirmReset "Reset Blue + Primary - independent IDs" "src\windows\reset_zcode.ps1" "-Target Both" & exit /b)
if "%~1"=="13" (call :RunWith "tools\patch_zcode_icon_override.ps1" "Patch finished - relaunch instances via their ZCode shortcuts - a bare ZCode.exe opens the PRIMARY profile." -WaitForClose & exit /b)
if "%~1"=="14" (call :RunWith "tools\install_zcode_second_shortcuts.ps1" "Look for the new ZCode Blue, ZCode Yellow, ZCode Green, ZCode Red and ZCode Orange shortcuts on your Desktop and in the Start menu." & exit /b)
if "%~1"=="15" (call :RunWith "tools\refresh_zcode_second_chats.ps1" "The Blue clone window refreshes its chat list by itself in a few seconds." & exit /b)
if "%~1"=="16" (call :Detached "ZCode Yellow" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Third" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="17" (call :Detached "ZCode Green" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fourth" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="18" (
    call :StartClone "ZCode Blue" "src\windows\launch_zcode_second_instance.ps1"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Yellow" "src\windows\launch_zcode_second_instance.ps1" "-Instance Third"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Green" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fourth"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Red" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fifth"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Orange" "src\windows\launch_zcode_second_instance.ps1" "-Instance Sixth"
    echo Five launcher windows opened - each closes automatically when done.
    echo First runs clone the Primary profile, so expect a short delay per clone.
    echo Launch logs: tools\logs - one launch_zcode log file per clone.
    pause
    exit /b
)
if "%~1"=="19" (call :RunZcodeReset "src\windows\reset_zcode.ps1" -Target Third & exit /b)
if "%~1"=="20" (call :RunZcodeReset "src\windows\reset_zcode.ps1" -Target Fourth & exit /b)
if "%~1"=="21" (call :ConfirmReset "Reset ALL SIX instances - independent IDs" "src\windows\reset_zcode.ps1" "-Target All" & exit /b)
if "%~1"=="22" (call :Detached "ZCode error chat refresh" "-NoExit -NoProfile" "tools\refresh_zcode_second_chats.ps1" "-Target All -Watch" "Error watcher launched in a separate window - leave it open." "On quota, captcha or rate-limit failures it refreshes chats in every running ZCode instance." & exit /b)
if "%~1"=="23" (call :Run "tools\refresh_zcode_second_chats.ps1" -Target All & exit /b)
if "%~1"=="24" (call :RunWith "tools\install_ghost_shortcut.ps1" "Check your Desktop for the GHOST shortcut - re-run this after moving this repo folder." & exit /b)
if "%~1"=="25" (call :Detached "ZCode taskbar identity" "-NoProfile" "tools\watch_zcode_taskbar.ps1" "" "Taskbar identity watcher launched in a separate window - leave it open." "It re-stamps any ZCode window that loses its taskbar identity within seconds." & exit /b)
if "%~1"=="26" (call :Run "tools\update_ghost.ps1" & exit /b)
if "%~1"=="27" (call :Run "tools\diagnose_zcode_freeze.ps1" & exit /b)
if "%~1"=="28" (call :Detached "AutoClaw2 Blue" "-NoProfile" "src\windows\launch_autoclaw2_clone.ps1" "" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="29" (call :Detached "AutoClaw2 Yellow" "-NoProfile" "src\windows\launch_autoclaw2_clone.ps1" "-Instance c2" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="30" (call :Detached "AutoClaw2 Green" "-NoProfile" "src\windows\launch_autoclaw2_clone.ps1" "-Instance c3" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="31" (call :Detached "AutoClaw2 Red" "-NoProfile" "src\windows\launch_autoclaw2_clone.ps1" "-Instance c4" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="32" (call :Detached "AutoClaw2 Orange" "-NoProfile" "src\windows\launch_autoclaw2_clone.ps1" "-Instance c5" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="33" (call :Detached "AutoClaw2 all clones" "-NoProfile" "src\windows\launch_autoclaw2_clones_all.ps1" "" "Sequential all-five launcher opened in a separate window - it closes when done." "Clones launch one at a time with a pause between each - do not launch them in parallel." & exit /b)
if "%~1"=="34" (call :RunWith "tools\install_autoclaw2_clone_shortcuts.ps1" "Look for the new AutoClaw2 Blue..Orange shortcuts on your Desktop and in the Start menu." & exit /b)
if "%~1"=="35" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c1 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c2 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c3 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c4 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_autoclaw2_clone.ps1" -Instance c5 -Status
    pause
    exit /b
)
if "%~1"=="36" (call :Run "tools\install_autoclaw2_clone_shortcuts.ps1" -Remove & exit /b)
if "%~1"=="41" (call :Detached "ZCode Red" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fifth" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="42" (call :RunZcodeReset "src\windows\reset_zcode.ps1" -Target Fifth & exit /b)
if "%~1"=="43" (call :Run "tools\sync_zcode_assets.ps1" & exit /b)
if "%~1"=="64" (call :Detached "ZCode Orange" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Sixth" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="65" (call :RunZcodeReset "src\windows\reset_zcode.ps1" -Target Sixth & exit /b)
if "%~1"=="67" (call :Run "tools\sync_zcode_assets.ps1" -McpOnly -Target All & exit /b)
if "%~1"=="68" (call :Detached "ZCode MCP Sync Watcher" "-NoProfile" "tools\watch_zcode_mcp_sync.ps1" "" "Watcher launched in a separate window - leave it open. It syncs MCPs from the Primary on every change - running instances included; a synced definition lands on each instance's next chat." "Log: %LOCALAPPDATA%\watch-zcode-mcp-sync\mcp-sync.log" & exit /b)
if "%~1"=="69" (call :Run "tools\watch_zcode_mcp_sync.ps1" -RunOnce -ApplyLive -Target All & exit /b)
if "%~1"=="70" (call :Detached "ZCode Light Worker" "-NoProfile" "src\windows\launch_zcode_cli_light.ps1" "" "Light worker opened in a separate window - type tasks there, empty input exits." "Headless: about a quarter of the RAM of a full instance. Read the model note it prints on first run." & exit /b)
if "%~1"=="71" (call :Detached "ZCode Clone Login" "-NoProfile" "src\windows\launch_zcode_cli_light.ps1" "-Login" "Login window opened - a browser will ask you to sign in with THIS clone's account." "One-time per clone home: it routes light workers and the T3 bridge to the Start Plan instead of the free model." & exit /b)
if "%~1"=="72" (call :Run "tools\install_zcode_second_shortcuts.ps1" -Remove & exit /b)
if "%~1"=="73" (call :Run "tools\sync_autoclaw2_mcp.ps1" -Target All & exit /b)
if "%~1"=="75" (call :Run "tools\sync_autoclaw2_chats.ps1" -Mode Inventory -Target All & exit /b)
if "%~1"=="76" (call :Run "tools\sync_autoclaw2_chats.ps1" -Mode Import -Apply -AllMissing -Target All & exit /b)
if "%~1"=="77" (call :Run "tools\sync_mcp_registry.ps1" & exit /b)
if "%~1"=="78" (call :RunWith "tools\patch_autoclaw2_identity.ps1" "Patch finished - relaunch the clones via their AutoClaw2 shortcuts for colored taskbar buttons." -WaitForClose & exit /b)
if "%~1"=="84" (call :RunAc2Reset "src\windows\reset_autoclaw2.ps1" -Target c1 & exit /b)
if "%~1"=="85" (call :RunAc2Reset "src\windows\reset_autoclaw2.ps1" -Target c2 & exit /b)
if "%~1"=="86" (call :RunAc2Reset "src\windows\reset_autoclaw2.ps1" -Target c3 & exit /b)
if "%~1"=="87" (call :RunAc2Reset "src\windows\reset_autoclaw2.ps1" -Target c4 & exit /b)
if "%~1"=="88" (call :RunAc2Reset "src\windows\reset_autoclaw2.ps1" -Target c5 & exit /b)
if "%~1"=="89" (call :RunAc2Reset "src\windows\reset_autoclaw2.ps1" -Target Primary & exit /b)
if "%~1"=="90" (call :ConfirmAc2Reset "Reset ALL profiles" "src\windows\reset_autoclaw2.ps1" "-Target All" & exit /b)
if "%~1"=="81" (call :RunWith "tools\build_ghost_exe.ps1" "Look for GHOST.exe in the repo root - double-click it to open the desktop launcher. Rebuild it after updates or after moving this repo folder." & exit /b)
if "%~1"=="44" (call :Detached "Cline Blue" "-NoProfile" "src\windows\launch_cline_clone.ps1" "" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="45" (call :RunWith "tools\install_cline_clone_shortcuts.ps1" "Look for the new Cline Blue..Orange shortcuts on your Desktop and in the Start menu." & exit /b)
if "%~1"=="46" (call :Detached "Cline Yellow" "-NoProfile" "src\windows\launch_cline_clone.ps1" "-Instance c2" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="47" (call :Detached "Cline Green" "-NoProfile" "src\windows\launch_cline_clone.ps1" "-Instance c3" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="48" (call :Detached "Cline all clones" "-NoProfile" "src\windows\launch_cline_clones_all.ps1" "" "Sequential all-five launcher opened in a separate window - it closes when done." "Clones launch one at a time with a pause between each - do not launch them in parallel." & exit /b)
if "%~1"=="49" (call :Detached "Cline Red" "-NoProfile" "src\windows\launch_cline_clone.ps1" "-Instance c4" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="50" (call :Detached "Cline Orange" "-NoProfile" "src\windows\launch_cline_clone.ps1" "-Instance c5" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="51" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c1 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c2 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c3 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c4 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_cline_clone.ps1" -Instance c5 -Status
    pause
    exit /b
)
if "%~1"=="52" (call :Run "tools\install_cline_clone_shortcuts.ps1" -Remove & exit /b)
if "%~1"=="53" (call :Detached "OpenCode Blue" "-NoProfile" "src\windows\launch_opencode_clone.ps1" "" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="54" (call :Detached "OpenCode Yellow" "-NoProfile" "src\windows\launch_opencode_clone.ps1" "-Instance c2" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="55" (call :Detached "OpenCode Green" "-NoProfile" "src\windows\launch_opencode_clone.ps1" "-Instance c3" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="56" (call :Detached "OpenCode Red" "-NoProfile" "src\windows\launch_opencode_clone.ps1" "-Instance c4" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="57" (call :Detached "OpenCode Orange" "-NoProfile" "src\windows\launch_opencode_clone.ps1" "-Instance c5" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="58" (call :Detached "OpenCode all clones" "-NoProfile" "src\windows\launch_opencode_clones_all.ps1" "" "Sequential all-five launcher opened in a separate window - it closes when done." "Clones launch one at a time with a pause between each - do not launch them in parallel." & exit /b)
if "%~1"=="59" (call :RunWith "tools\patch_opencode_clone_home.ps1" "Patch finished - relaunch clones via their OpenCode shortcuts - a bare OpenCode.exe opens the PRIMARY profile." -WaitForClose & exit /b)
if "%~1"=="60" (call :RunWith "tools\install_opencode_clone_shortcuts.ps1" "Look for the new OpenCode Blue..Orange shortcuts on your Desktop and in the Start menu." & exit /b)
if "%~1"=="61" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c1 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c2 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c3 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c4 -Status
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_opencode_clone.ps1" -Instance c5 -Status
    pause
    exit /b
)
if "%~1"=="62" (call :Run "tools\install_opencode_clone_shortcuts.ps1" -Remove & exit /b)
if "%~1"=="79" (call :Detached "OpenCode Light Worker" "-NoProfile" "src\windows\launch_opencode_cli_light.ps1" "" "Light worker opened in a separate window - type tasks there, empty input exits." "Headless CLI on the clone's own state. A fresh clone runs the FREE model - the Login row attaches its account." & exit /b)
if "%~1"=="80" (call :Detached "OpenCode Clone Login" "-NoProfile" "src\windows\launch_opencode_cli_light.ps1" "-Login" "Login window opened - follow the interactive flow for THIS clone's account." "One-time per clone home: it writes the clone's own auth.json instead of running on the free model." & exit /b)
if "%~1"=="66" (call :ConfirmRun "Spoof WMI hardware serials - BIOS, motherboard, disk, RAM + Bluetooth MAC" "src\windows\spoof_wmi_serials.ps1" "This changes system-wide hardware identity data. A WMI repository backup + restore script are generated first." & exit /b)
if "%~1"=="82" (call :Detached "ZCode Primary" "-NoProfile" "src\windows\launch_zcode_primary.ps1" "" "Launcher opened in a separate window - it closes automatically when done." "Launches the Primary non-elevated - drag-drop breaks into elevated instances." & exit /b)
if "%~1"=="83" (call :Run "tools\patch_zcode_exe_identity.ps1" -Target All & exit /b)
call :UnknownTask "%~1"
exit /b

:RunChain
rem Runs each task id in the chain sequentially, no menu between tasks. Returns to caller.
if "%~1"=="" exit /b
for %%t in (%*) do call :DispatchOne %%t
exit /b

:Crumb
rem One-line breadcrumb for submenus (the full banner stays on the main menu only).
if not defined ESC goto CrumbPlain
echo %ESC%[96mGHOST / %~1%ESC%[0m
exit /b
:CrumbPlain
echo GHOST / %~1
exit /b

:Banner
if not defined ESC goto BannerPlain
echo %ESC%[96m
echo.
echo   ____ _   _  ___  ____ _____
echo  / ___^| ^| ^| ^|/ _ \/ ___^|_   _^|
echo ^| ^|  _^| ^|_^| ^| ^| ^| \___ \ ^| ^|
echo ^| ^|_^| ^|  _  ^| ^|_^| ^|___) ^|^| ^|
echo  \____^|_^| ^|_^|\___/^|____/ ^|_^|
echo.
echo        GHOST - Guided Hardware ^& OS Scrubbing Toolkit%ESC%[0m
echo.
exit /b
:BannerPlain
echo.
echo   ____ _   _  ___  ____ _____
echo  / ___^| ^| ^| ^|/ _ \/ ___^|_   _^|
echo ^| ^|  _^| ^|_^| ^| ^| ^| \___ \ ^| ^|
echo ^| ^|_^| ^|  _  ^| ^|_^| ^|___) ^|^| ^|
echo  \____^|_^| ^|_^|\___/^|____/ ^|_^|
echo.
echo        GHOST - Guided Hardware ^& OS Scrubbing Toolkit
echo.
exit /b

:Hdr
if not defined ESC goto HdrPlain
echo %ESC%[96m%~1%ESC%[0m
exit /b
:HdrPlain
echo %~1
exit /b

:Div
if not defined ESC goto DivPlain
echo %ESC%[90m  -- %~1 --%ESC%[0m
exit /b
:DivPlain
echo   -- %~1 --
exit /b

:Opt
rem Option line: padded id, label, optional gray tail. Three-tone when ANSI is on.
set "OID= %~1"
set "OID=%OID:~-2%"
if not defined ESC goto OptPlain
if "%~3"=="" goto OptNoTail
echo %ESC%[92m[%OID%] %ESC%[97m%~2 %ESC%[90m%~3%ESC%[0m
exit /b
:OptNoTail
echo %ESC%[92m[%OID%] %ESC%[97m%~2%ESC%[0m
exit /b
:OptPlain
if "%~3"=="" echo [%OID%] %~2
if not "%~3"=="" echo [%OID%] %~2 %~3
exit /b

:Run
rem Runs a script inline (up to 8 extra args), then returns to the caller.
rem Usage: call :Run <script> [args...]
rem 2026-11-09 widened from 3 args: gid 75 lost "All" (-Target with no value)
rem and gid 76 lost -Target All, so both AutoClaw2 chat rows never worked.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1" %2 %3 %4 %5 %6 %7 %8 %9
pause
exit /b

:RunZcodeReset
rem ZCode reset wrapper: runs reset_zcode.ps1 with args, then prints the
rem relaunch-safety note (bare ZCode.exe = Primary profile). Keeps the note
rem next to the summary instead of inside the script.
rem Usage: call :RunZcodeReset <script> [args...]
echo Tip: don't press Ctrl+Break during the reset - if a console ever shows [DBG]:, type q then Enter and re-run the menu item.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1" %2 %3 %4
echo.
echo NOTE: relaunch clones via their ZCode Blue/Yellow/Green/Red/Orange shortcuts or the launcher - a bare ZCode.exe opens the PRIMARY profile.
pause
exit /b

:RunAc2Reset
rem AutoClaw2 reset wrapper (gids 84-89): runs reset_autoclaw2.ps1 with args,
rem then prints the relaunch-safety note (a bare AutoClaw2.exe opens the
rem PRIMARY profile). Same shape as :RunZcodeReset.
rem Usage: call :RunAc2Reset <script> [args...]
echo Tip: don't press Ctrl+Break during the reset - if a console ever shows [DBG]:, type q then Enter and re-run the menu item.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1" %2 %3 %4
echo.
echo NOTE: relaunch profiles via their AutoClaw2 Blue/Yellow/Green/Red/Orange shortcuts or the launcher - a bare AutoClaw2.exe opens the PRIMARY profile.
pause
exit /b

:ConfirmAc2Reset
rem Confirmation gate for the destructive AutoClaw2 all-profiles reset (gid 90).
rem choice reads the CONSOLE - not stdin - so menu chains and the .bat harness
rem stay unaffected.
rem Usage: call :ConfirmAc2Reset <label> <script> <args>
echo About to run: %~1
echo This tree-kills the affected profiles and rewrites their identity stores.
choice /C YN /N /M "Continue with the reset? Y = run, N = cancel: "
if errorlevel 2 goto ConfirmAc2ResetNo
call :RunAc2Reset "%~2" %~3
exit /b
:ConfirmAc2ResetNo
echo Cancelled - nothing was run.
pause
exit /b

:ConfirmReset
rem Confirmation gate for the destructive multi-instance resets (gid 12 Both,
rem gid 21 All-six). choice reads the CONSOLE - not stdin - so menu chains and
rem the .bat harness stay unaffected.
rem Usage: call :ConfirmReset <label> <script> <args>
echo About to run: %~1
echo This tree-kills the affected instances and rewrites their identity stores.
choice /C YN /N /M "Continue with the reset? Y = run, N = cancel: "
if errorlevel 2 goto ConfirmResetNo
call :RunZcodeReset "%~2" %~3
exit /b
:ConfirmResetNo
echo Cancelled - nothing was run.
pause
exit /b

:ConfirmRun
rem Confirmation gate for system-level actions (gid 66 WMI serial spoof,
rem gid 1 device-ID reset). choice reads the CONSOLE - not stdin - so menu
rem chains and the .bat harness stay unaffected. 2026-11-10: the confirm text
rem moved into the call site (%~3) so each action describes itself; script
rem args start at %~4 (forwarded to :Run, max 6).
rem Usage: call :ConfirmRun <label> <script> <confirm-text> [args]
echo About to run: %~1
echo %~3
choice /C YN /N /M "Continue? Y = run, N = cancel: "
if errorlevel 2 goto ConfirmRunNo
call :Run "%~2" %4 %5 %6 %7 %8 %9
exit /b
:ConfirmRunNo
echo Cancelled - nothing was run.
pause
exit /b

:RunWith
rem Runs a script inline (optional extra args in %~3), prints a follow-up note, then returns to the caller.
rem Usage: call :RunWith <script> <note> [extra-args]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1" %~3
echo.
echo %~2
pause
exit /b

:Detached
rem Launches a script in a new window via start, prints status notes, then returns to the caller.
rem Usage: call :Detached <window title> <powershell flags> <script> [script args] <note> [extra note]
start "%~1" powershell %~2 -ExecutionPolicy Bypass -File "%~3" %~4
echo.
echo %~5
if not "%~6"=="" echo %~6
pause
exit /b

:StartClone
rem Launches a clone window only; the caller prints notes and pauses. Returns to caller.
rem Usage: call :StartClone <window title> <script> [script args]
start "%~1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~2" %~3
exit /b
