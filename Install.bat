@echo off
REM ================================================================
REM  NDEV Driver Bundle - double-click launcher.
REM  Self-elevates to Administrator, then runs the install script.
REM ================================================================

REM Are we already admin?
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM We are admin. Run the install script.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-NDEV-Drivers.ps1"

echo.
echo Press any key to close this window.
pause >nul
