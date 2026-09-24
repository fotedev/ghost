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
echo [1] Change Device ID [MACHINE-WIDE: affects BOTH ZCode instances + Qoder]
echo [2] Reset Cursor
echo [3] Reset Windsurf\Devin
echo [4] Reset Trae
echo [5] Reset Qoder
echo [6] Reset QoderWork
echo [7] Reset ZCode Primary instance
echo [8] Reset MiniMax/OpenCode
echo [9] Watch ZCode captcha (unattended watchdog, separate window)
echo [10] Launch ZCode second instance (independent window)
echo [11] Reset ZCode Secondary instance (survivor kept running)
echo [12] Reset BOTH ZCode instances (independent IDs)
echo [0] Exit
echo.

set /p choice=Enter your choice: 

if "%choice%"=="1" (
    powershell -ExecutionPolicy Bypass -File "src\windows\change_device_id.ps1"
    pause
    goto MENU
)
if "%choice%"=="2" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_cursor.ps1"
    pause
    goto MENU
)
if "%choice%"=="3" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_devin.ps1"
    pause
    goto MENU
)
if "%choice%"=="4" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_trae.ps1"
    pause
    goto MENU
)
if "%choice%"=="5" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_qoder.ps1"
    pause
    goto MENU
)
if "%choice%"=="6" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_qoderwork.ps1"
    pause
    goto MENU
)
if "%choice%"=="7" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Primary
    pause
    goto MENU
)
if "%choice%"=="8" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_minimax_opencode.ps1"
    pause
    goto MENU
)
if "%choice%"=="9" (
    start "ZCode captcha watch" powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\watch_zcode_captcha.ps1"
    echo Watchdog launched in a separate window - leave it open.
    echo To verify it runs: check %%LOCALAPPDATA%%\watch-zcode-captcha\watch.log
    pause
    goto MENU
)
if "%choice%"=="10" (
    start "ZCode Second Instance" powershell -NoProfile -ExecutionPolicy Bypass -File "src\windows\launch_zcode_second_instance.ps1"
    echo Launcher opened in a separate window - it closes automatically when done.
    pause
    goto MENU
)
if "%choice%"=="11" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Secondary
    pause
    goto MENU
)
if "%choice%"=="12" (
    powershell -ExecutionPolicy Bypass -File "src\windows\reset_zcode.ps1" -Target Both
    pause
    goto MENU
)
if "%choice%"=="0" (
    echo Done.
    timeout /t 1 >nul
    exit
)

echo Invalid choice. Please try again.
pause
goto MENU
