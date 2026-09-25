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
call :Opt 1 "IDE Resets" "- device ID + 7 IDE suites"
if defined ESC (echo %ESC%[92m[ 2] %ESC%[97mZCode Multi-Instance ^& Clones %ESC%[90m- launchers, resets, sync%ESC%[0m) else echo [ 2] ZCode Multi-Instance ^& Clones - launchers, resets, sync
if defined ESC (echo %ESC%[92m[ 3] %ESC%[97mSystem ^& GHOST Maintenance %ESC%[90m- shortcuts, watchers, updates%ESC%[0m) else echo [ 3] System ^& GHOST Maintenance - shortcuts, watchers, updates
echo.
call :Opt U "Check for updates / update GHOST" "- from GitHub"
call :Opt 0 "Exit" ""
if defined ESC (echo %ESC%[90mTip: You can run multiple options at once by separating them with commas ^(e.g. %ESC%[96m1, 3, 4%ESC%[90m^)%ESC%[0m) else echo Tip: You can run multiple options at once by separating them with commas ^(e.g. 1, 3, 4^)
echo.
set "choice="
set /p choice=%PROMPT_TEXT%
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
if "%first%"=="1" if "%rest%"=="" goto RESETS
if "%first%"=="2" if "%rest%"=="" goto ZCODE
if "%first%"=="3" if "%rest%"=="" goto MAINT
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
call :Opt 1 "Change Device ID" "(machine-wide: ALL instances + Qoder)"
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
set "chain=%PENDING_CHAIN%"
set "PENDING_CHAIN="
call :RunChain %chain%
set "choice="
set /p choice=%PROMPT_TEXT%
if "%choice%"=="0" goto MAIN
set "chain=%choice:,= %"
call :RunChain %chain%
goto RESETS

:ZCODE
cls
if defined ESC (echo %ESC%[96mGHOST / ZCode Multi-Instance ^& Clones%ESC%[0m) else echo GHOST / ZCode Multi-Instance ^& Clones
echo.
call :Div "Launch Clones"
call :Opt 1 "Launch Second instance" "- Blue branding (independent window)"
call :Opt 2 "Install clone shortcuts" "- all 3 - Desktop + Start menu"
call :Opt 3 "Launch Third instance" "- Yellow branding (independent window)"
call :Opt 4 "Launch Fourth instance" "- Green branding (independent window)"
call :Opt 5 "Launch ALL clones" "- Second + Third + Fourth"
echo.
call :Div "Reset Clones"
call :Opt 6 "Reset Second instance" "(survivor kept running)"
call :Opt 7 "Reset Second + Primary" "(independent IDs)"
call :Opt 8 "Reset Third instance - Yellow" "(survivors kept running)"
call :Opt 9 "Reset Fourth instance - Green" "(survivors kept running)"
call :Opt 10 "Reset ALL FOUR instances" "(independent IDs)"
echo.
if defined ESC (echo %ESC%[90m  -- Sync ^& Watchers --%ESC%[0m) else echo   -- Sync ^& Watchers --
call :Opt 11 "Captcha watchdog" "(unattended, separate window)"
call :Opt 12 "Re-apply icon patch - v6, all clone colors" "(after app update)"
call :Opt 13 "Refresh Second chats" "- show Primary chats without app restart"
call :Opt 14 "Watch errors" "- auto-refresh chats on quota or captcha failure"
call :Opt 15 "Refresh chats - ALL instances" "- re-index every running sidebar"
call :Opt 16 "Taskbar identity watcher" "- auto-fix taskbar merges (separate window)"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
set "chain=%PENDING_CHAIN%"
set "PENDING_CHAIN="
for %%t in (%chain%) do call :ZCodeOne %%t
set "choice="
set /p choice=%PROMPT_TEXT%
if "%choice%"=="0" goto MAIN
set "chain=%choice:,= %"
for %%t in (%chain%) do call :ZCodeOne %%t
goto ZCODE

:MAINT
cls
if defined ESC (echo %ESC%[96mGHOST / System ^& GHOST Maintenance%ESC%[0m) else echo GHOST / System ^& GHOST Maintenance
echo.
call :Opt 1 "Install or repair the GHOST shortcut" "- Desktop + repo folder"
call :Opt 2 "Check for updates / update GHOST" "- from GitHub"
echo.
call :Opt 0 "Back to Main Menu" ""
echo.
set "chain=%PENDING_CHAIN%"
set "PENDING_CHAIN="
for %%t in (%chain%) do call :MaintOne %%t
set "choice="
set /p choice=%PROMPT_TEXT%
if "%choice%"=="0" goto MAIN
set "chain=%choice:,= %"
for %%t in (%chain%) do call :MaintOne %%t
goto MAINT

:UnknownTask
rem Red "not found" message for a bad task id (shared by all resolvers).
if defined ESC echo %ESC%[91mUnknown task "%~1" - check the menu and try again.%ESC%[0m
if not defined ESC echo Unknown task "%~1" - check the menu and try again.
exit /b

:ZCodeOne
rem Resolves a ZCode submenu-local id to its global task id and runs it.
set "RESOLVED="
if "%~1"=="1"  set "RESOLVED=10"
if "%~1"=="2"  set "RESOLVED=14"
if "%~1"=="3"  set "RESOLVED=16"
if "%~1"=="4"  set "RESOLVED=17"
if "%~1"=="5"  set "RESOLVED=18"
if "%~1"=="6"  set "RESOLVED=11"
if "%~1"=="7"  set "RESOLVED=12"
if "%~1"=="8"  set "RESOLVED=19"
if "%~1"=="9"  set "RESOLVED=20"
if "%~1"=="10" set "RESOLVED=21"
if "%~1"=="11" set "RESOLVED=9"
if "%~1"=="12" set "RESOLVED=13"
if "%~1"=="13" set "RESOLVED=15"
if "%~1"=="14" set "RESOLVED=22"
if "%~1"=="15" set "RESOLVED=23"
if "%~1"=="16" set "RESOLVED=25"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:MaintOne
rem Resolves a Maintenance submenu-local id to its global task id and runs it.
set "RESOLVED="
if "%~1"=="1" set "RESOLVED=24"
if "%~1"=="2" set "RESOLVED=26"
if not defined RESOLVED call :UnknownTask "%~1"
if not defined RESOLVED exit /b
call :DispatchOne %RESOLVED%
exit /b

:DispatchOne
rem Runs one task by global id (1-26). Unknown ids print an error. Returns to caller.
if "%~1"=="1"  (call :Run "src\windows\change_device_id.ps1" & exit /b)
if "%~1"=="2"  (call :Run "src\windows\reset_cursor.ps1" & exit /b)
if "%~1"=="3"  (call :Run "src\windows\reset_devin.ps1" & exit /b)
if "%~1"=="4"  (call :Run "src\windows\reset_trae.ps1" & exit /b)
if "%~1"=="5"  (call :Run "src\windows\reset_qoder.ps1" & exit /b)
if "%~1"=="6"  (call :Run "src\windows\reset_qoderwork.ps1" & exit /b)
if "%~1"=="7"  (call :Run "src\windows\reset_zcode.ps1" -Target Primary & exit /b)
if "%~1"=="8"  (call :Run "src\windows\reset_minimax_opencode.ps1" & exit /b)
if "%~1"=="9"  (call :Detached "ZCode captcha watch" "-NoExit -NoProfile" "tools\watch_zcode_captcha.ps1" "" "Watchdog launched in a separate window - leave it open." "To verify it runs: check %LOCALAPPDATA%\watch-zcode-captcha\watch.log" & exit /b)
if "%~1"=="10" (call :Detached "ZCode Second Instance" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="11" (call :Run "src\windows\reset_zcode.ps1" -Target Secondary & exit /b)
if "%~1"=="12" (call :Run "src\windows\reset_zcode.ps1" -Target Both & exit /b)
if "%~1"=="13" (call :RunWith "tools\patch_zcode_icon_override.ps1" "Patch finished - if it reported ZCode.exe running, close ALL ZCode instances and run this option again." & exit /b)
if "%~1"=="14" (call :RunWith "tools\install_zcode_second_shortcuts.ps1" "Look for the new ZCode Second, ZCode Third and ZCode Fourth shortcuts on your Desktop and in the Start menu." & exit /b)
if "%~1"=="15" (call :RunWith "tools\refresh_zcode_second_chats.ps1" "The blue Secondary window refreshes its chat list by itself in a few seconds." & exit /b)
if "%~1"=="16" (call :Detached "ZCode Third Instance" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Third" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="17" (call :Detached "ZCode Fourth Instance" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fourth" "Launcher opened in a separate window - it closes automatically when done." & exit /b)
if "%~1"=="18" (
    call :StartClone "ZCode Second Instance" "src\windows\launch_zcode_second_instance.ps1"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Third Instance" "src\windows\launch_zcode_second_instance.ps1" "-Instance Third"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Fourth Instance" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fourth"
    echo Three launcher windows opened - each closes automatically when done.
    echo First runs clone the Primary profile, so expect a short delay per clone.
    pause
    exit /b
)
if "%~1"=="19" (call :Run "src\windows\reset_zcode.ps1" -Target Third & exit /b)
if "%~1"=="20" (call :Run "src\windows\reset_zcode.ps1" -Target Fourth & exit /b)
if "%~1"=="21" (call :Run "src\windows\reset_zcode.ps1" -Target All & exit /b)
if "%~1"=="22" (call :Detached "ZCode error chat refresh" "-NoExit -NoProfile" "tools\refresh_zcode_second_chats.ps1" "-Target All -Watch" "Error watcher launched in a separate window - leave it open." "On quota, captcha or rate-limit failures it refreshes chats in every running ZCode instance." & exit /b)
if "%~1"=="23" (call :Run "tools\refresh_zcode_second_chats.ps1" -Target All & exit /b)
if "%~1"=="24" (call :RunWith "tools\install_ghost_shortcut.ps1" "Check your Desktop for the GHOST shortcut - re-run this after moving this repo folder." & exit /b)
if "%~1"=="25" (call :Detached "ZCode taskbar identity" "-NoProfile" "tools\watch_zcode_taskbar.ps1" "" "Taskbar identity watcher launched in a separate window - leave it open." "It re-stamps any ZCode window that loses its taskbar identity within seconds." & exit /b)
if "%~1"=="26" (call :Run "tools\update_ghost.ps1" & exit /b)
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
rem Runs a script inline (up to 3 extra args), then returns to the caller.
rem Usage: call :Run <script> [args...]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1" %2 %3 %4
pause
exit /b

:RunWith
rem Runs a script inline (no extra args), prints a follow-up note, then returns to the caller.
rem Usage: call :RunWith <script> <note>
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1"
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
