@echo off
chcp 65001 >nul 2>&1
title ChronoTide - Push to GitHub

echo.
echo ========================================================
echo   ChronoTide Open Source - GitHub Update Tool
echo ========================================================
echo.

cd /d "%~dp0"

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0push_to_github.ps1" %*

echo.
echo ========================================================
echo.
pause
