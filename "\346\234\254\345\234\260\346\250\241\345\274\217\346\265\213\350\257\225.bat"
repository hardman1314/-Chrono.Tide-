@echo off
chcp 65001 >nul 2>&1
title ChronoTide - Local Mode Test

echo.
echo ========================================================
echo   ChronoTide Open Source - Local Mode Test
echo ========================================================
echo.

cd /d "%~dp0"

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0test_local_mode.ps1" %*

echo.
echo ========================================================
echo.
pause
