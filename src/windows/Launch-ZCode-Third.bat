@echo off
chcp 65001 >nul
title ZCode Third Instance Launcher
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch_zcode_second_instance.ps1" -Instance Third
pause
