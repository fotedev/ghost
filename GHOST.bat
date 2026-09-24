@echo off
chcp 65001 >nul
title GHOST - Guided Hardware and OS Scrubbing Toolkit
cd /d "%~dp0"

:MENU
cls
echo.
echo   ____ _   _  ___  ____ _____
echo  / ___^| ^| ^| ^|/ _ \/ ___^|_   _^|
echo ^| ^|  _^| ^|_^| ^| ^| ^| \___ \ ^| ^|
echo ^| ^|_^| ^|  _  ^| ^|_^| ^|___) ^|^| ^|
echo  \____^|_^| ^|_^|\___/^|____/ ^|_^|
echo.
echo        GHOST - Guided Hardware ^& OS Scrubbing Toolkit
echo.
echo  ---- IDE identity resets ----
echo [1] Change Device ID [MACHINE-WIDE: affects ALL ZCode instances + Qoder]
echo [2] Reset Cursor
echo [3] Reset Windsurf\Devin
echo [4] Reset Trae
echo [5] Reset Qoder
echo [6] Reset QoderWork
echo [7] Reset ZCode Primary instance
echo [8] Reset MiniMax/OpenCode
echo.
echo  ---- ZCode multi-instance ----
echo [9] Watch ZCode captcha (unattended watchdog, separate window)
echo [10] Launch ZCode Second instance - Blue branding (independent window)
echo [11] Reset ZCode Second instance (survivor kept running)
echo [12] Reset Second + Primary ZCode instances (independent IDs)
echo [13] Re-apply ZCode icon patch - v6, all clone colors (needed after app update)
echo [14] Install ZCode clone shortcuts - all 3 clones - Desktop + Start menu
echo [15] Refresh ZCode Second chats - show Primary chats without app restart
echo [16] Launch ZCode Third instance - Yellow branding (independent window)
echo [17] Launch ZCode Fourth instance - Green branding (independent window)
echo [18] Launch ALL ZCode clones - Second + Third + Fourth
echo [19] Reset ZCode Third instance - Yellow (survivors kept running)
echo [20] Reset ZCode Fourth instance - Green (survivors kept running)
echo [21] Reset ALL FOUR ZCode instances (independent IDs)
echo [22] Watch ZCode errors - auto-refresh chats in running instances on quota or captcha failure
echo [23] Refresh ZCode chats - ALL instances - re-index every running sidebar
echo [25] Watch ZCode taskbar identity - auto-fix taskbar merges (separate window)
echo.
echo  ---- GHOST launcher ----
echo [24] Install or repair the GHOST shortcut with ghost icon - Desktop + repo folder
echo [26] Check for updates / update GHOST from GitHub
echo.
echo [0] Exit
echo.

set "choice="
set /p choice=Enter your choice: 

rem ---- Dispatch: one line per option; :Run/:RunWith/:Detached return to :MENU ----
if "%choice%"=="1"  call :Run "src\windows\change_device_id.ps1"
if "%choice%"=="2"  call :Run "src\windows\reset_cursor.ps1"
if "%choice%"=="3"  call :Run "src\windows\reset_devin.ps1"
if "%choice%"=="4"  call :Run "src\windows\reset_trae.ps1"
if "%choice%"=="5"  call :Run "src\windows\reset_qoder.ps1"
if "%choice%"=="6"  call :Run "src\windows\reset_qoderwork.ps1"
if "%choice%"=="7"  call :Run "src\windows\reset_zcode.ps1" -Target Primary
if "%choice%"=="8"  call :Run "src\windows\reset_minimax_opencode.ps1"
if "%choice%"=="9"  call :Detached "ZCode captcha watch" "-NoExit -NoProfile" "tools\watch_zcode_captcha.ps1" "" "Watchdog launched in a separate window - leave it open." "To verify it runs: check %LOCALAPPDATA%\watch-zcode-captcha\watch.log"
if "%choice%"=="10" call :Detached "ZCode Second Instance" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "" "Launcher opened in a separate window - it closes automatically when done."
if "%choice%"=="11" call :Run "src\windows\reset_zcode.ps1" -Target Secondary
if "%choice%"=="12" call :Run "src\windows\reset_zcode.ps1" -Target Both
if "%choice%"=="13" call :RunWith "tools\patch_zcode_icon_override.ps1" "Patch finished - if it reported ZCode.exe running, close ALL ZCode instances and run this option again."
if "%choice%"=="14" call :RunWith "tools\install_zcode_second_shortcuts.ps1" "Look for the new ZCode Second, ZCode Third and ZCode Fourth shortcuts on your Desktop and in the Start menu."
if "%choice%"=="15" call :RunWith "tools\refresh_zcode_second_chats.ps1" "The blue Secondary window refreshes its chat list by itself in a few seconds."
if "%choice%"=="16" call :Detached "ZCode Third Instance" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Third" "Launcher opened in a separate window - it closes automatically when done."
if "%choice%"=="17" call :Detached "ZCode Fourth Instance" "-NoProfile" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fourth" "Launcher opened in a separate window - it closes automatically when done."
if "%choice%"=="18" (
    call :StartClone "ZCode Second Instance" "src\windows\launch_zcode_second_instance.ps1"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Third Instance" "src\windows\launch_zcode_second_instance.ps1" "-Instance Third"
    timeout /t 3 /nobreak >nul
    call :StartClone "ZCode Fourth Instance" "src\windows\launch_zcode_second_instance.ps1" "-Instance Fourth"
    echo Three launcher windows opened - each closes automatically when done.
    echo First runs clone the Primary profile, so expect a short delay per clone.
    pause
    goto MENU
)
if "%choice%"=="19" call :Run "src\windows\reset_zcode.ps1" -Target Third
if "%choice%"=="20" call :Run "src\windows\reset_zcode.ps1" -Target Fourth
if "%choice%"=="21" call :Run "src\windows\reset_zcode.ps1" -Target All
if "%choice%"=="22" call :Detached "ZCode error chat refresh" "-NoExit -NoProfile" "tools\refresh_zcode_second_chats.ps1" "-Target All -Watch" "Error watcher launched in a separate window - leave it open." "On quota, captcha or rate-limit failures it refreshes chats in every running ZCode instance."
if "%choice%"=="23" call :Run "tools\refresh_zcode_second_chats.ps1" -Target All
if "%choice%"=="25" call :Detached "ZCode taskbar identity" "-NoProfile" "tools\watch_zcode_taskbar.ps1" "" "Taskbar identity watcher launched in a separate window - leave it open." "It re-stamps any ZCode window that loses its taskbar identity within seconds."
if "%choice%"=="24" call :RunWith "tools\install_ghost_shortcut.ps1" "Check your Desktop for the GHOST shortcut - re-run this after moving this repo folder."
if "%choice%"=="26" call :Run "tools\update_ghost.ps1"
if "%choice%"=="0" (
    echo Done.
    timeout /t 1 >nul
    exit
)

echo Invalid choice. Please try again.
pause
goto MENU

rem === Subroutines ===

:Run
rem Runs a script inline (up to 3 extra args), then back to the menu.
rem Usage: call :Run <script> [args...]
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1" %2 %3 %4
pause
goto MENU

:RunWith
rem Runs a script inline (no extra args), prints a follow-up note, then back to the menu.
rem Usage: call :RunWith <script> <note>
powershell -NoProfile -ExecutionPolicy Bypass -File "%~1"
echo.
echo %~2
pause
goto MENU

:Detached
rem Launches a script in a new window via start, prints status notes, then back to the menu.
rem Usage: call :Detached <window title> <powershell flags> <script> [script args] <note> [extra note]
start "%~1" powershell %~2 -ExecutionPolicy Bypass -File "%~3" %~4
echo.
echo %~5
if not "%~6"=="" echo %~6
pause
goto MENU

:StartClone
rem Launches a clone window only; the caller prints notes and pauses. Returns to caller.
rem Usage: call :StartClone <window title> <script> [script args]
start "%~1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~2" %~3
exit /b
