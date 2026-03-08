@echo off
:: Write Protection Toggle for DFIR USB Drive
:: Sets/clears the disk-level readonly attribute (requires admin)

set "DRIVE=%~d0"
set "UPDATERDIR=%~dp0"

echo.
echo  ============================================
echo   DFIR Drive - Write Protection Toggle
echo  ============================================
echo.

:: Check for administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo  Administrator privileges required for disk write protection.
    echo  Requesting elevation...
    echo.
    powershell -NoProfile -Command "Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','%UPDATERDIR%Write-Protect.ps1','-DriveLetter','%DRIVE:~0,1%' -Verb RunAs -Wait"
    exit /b
)

:: Already admin - run directly
powershell -NoProfile -ExecutionPolicy Bypass -File "%UPDATERDIR%Write-Protect.ps1" -DriveLetter "%DRIVE:~0,1%"
