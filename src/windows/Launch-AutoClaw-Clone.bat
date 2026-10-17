@echo off
chcp 65001 >nul
title AutoClaw Clone Launcher
:MENU
cls
echo  --- AutoClaw clone launcher ---
echo.
echo  [1] Launch inst1
echo  [2] Launch inst2
echo  [3] Launch inst3
echo  [4] Launch inst4
echo  [S] Status of all clones
echo  [0] Exit
echo.
set "choice="
set /p choice=Enter your choice:
if not defined choice goto MENU
if "%choice%"=="0" exit /b
if /i "%choice%"=="S" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_autoclaw_clone.ps1" -Status
    pause
    goto MENU
)
if "%choice%"=="1" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_autoclaw_clone.ps1" -Instance inst1
if "%choice%"=="2" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_autoclaw_clone.ps1" -Instance inst2
if "%choice%"=="3" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_autoclaw_clone.ps1" -Instance inst3
if "%choice%"=="4" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_autoclaw_clone.ps1" -Instance inst4
pause
goto MENU
