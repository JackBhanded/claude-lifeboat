@echo off
title Install Claude Lifeboat
REM Double-click me to install Claude Lifeboat. I'll ask Windows for the
REM administrator rights needed to set up your automatic backups, then run the
REM installer for you - no PowerShell wrangling required.

net session >nul 2>&1
if %errorlevel%==0 goto run

echo.
echo   Asking Windows for permission (needed to schedule your backups)...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
echo.
echo   You can close this window now.
pause
