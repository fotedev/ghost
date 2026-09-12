@echo off
chcp 65001 >nul
title Script Runner - By Ahmed
cd /d "%~dp0"

:MENU
cls
echo ================================
echo        🛠️ Script Launcher
echo ================================
echo [1] Change Device ID
echo [2] Reset Cursor
echo [3] Reset Windsurf
echo [4] Reset Trae
echo [5] Reset Qoder
echo [6] Reset QoderWork
echo [7] Reset ZCode
echo [8] Reset MiniMax/OpenCode
echo [0] Exit
echo.

set /p choice=Enter your choice: 

if "%choice%"=="1" (
    powershell -ExecutionPolicy Bypass -File "change_device_id.ps1"
    pause
    goto MENU
)
if "%choice%"=="2" (
    powershell -ExecutionPolicy Bypass -File "reset_cursor_windows-v0.2.ps1"
    pause
    goto MENU
)
if "%choice%"=="3" (
    powershell -ExecutionPolicy Bypass -File "reset_windsurf_windows-v0.2.ps1"
    pause
    goto MENU
)
if "%choice%"=="4" (
    powershell -ExecutionPolicy Bypass -File "reset_trae_windows-v0.2.ps1"
    pause
    goto MENU
)
if "%choice%"=="5" (
    powershell -ExecutionPolicy Bypass -File "reset_qoder_windows-v0.3.ps1"
    pause
    goto MENU
)
if "%choice%"=="6" (
    powershell -ExecutionPolicy Bypass -File "reset_qoderwork_windows-v0.1.ps1"
    pause
    goto MENU
)
if "%choice%"=="7" (
    powershell -ExecutionPolicy Bypass -File "reset_zcode_windows-v1.1.ps1"
    pause
    goto MENU
)
if "%choice%"=="8" (
    powershell -ExecutionPolicy Bypass -File "reset_minimax_opencode_windows-v1.0.ps1"
    pause
    goto MENU
)
if "%choice%"=="0" (
    echo See you later, Ahmed 👋
    timeout /t 1 >nul
    exit
)

echo Invalid choice. Please try again.
pause
goto MENU
