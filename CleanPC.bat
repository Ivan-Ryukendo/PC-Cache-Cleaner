@echo off
REM ============================================================
REM  CleanPC.bat - one-click launcher for Clean-PC-Cache.ps1
REM  Self-elevates to Administrator so it can also clear
REM  Windows\Temp and the Windows Update cache.
REM ============================================================
title Windows Cache ^& Temp Cleaner

REM --- check for admin; if not elevated, relaunch elevated ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator permission...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM --- launch the GUI (scan -> tick what to delete -> Clean Selected) ---
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0CleanPC-GUI.ps1"

REM (No-UI alternative for scripting / friends who prefer the console:)
REM powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-PC-Cache.ps1"
