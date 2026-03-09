@echo off
setlocal EnableDelayedExpansion

:: ============================================================
::  DFIR Drive Updater - Portable Launcher
::  Auto-detects drive letter and launches the PowerShell GUI
:: ============================================================

title DFIR Drive Updater

:: ---- Forensic Mode Notice ----
if exist "%~d0\FORENSIC_MODE" (
    echo  [!] Forensic Mode is active. Updates are disabled.
    echo      You can toggle it from the GUI.
    echo.
)

:: ---- Derive paths from this script's location ----
set "DRIVE=%~d0"
set "SCRIPT_DIR=%~dp0"
set "GUI_SCRIPT=%SCRIPT_DIR%DFIR-Updater-GUI.ps1"
set "SETUP_SCRIPT=%SCRIPT_DIR%Setup-AutoLaunch.ps1"

:: ---- Header ----
echo.
echo  ============================================================
echo   DFIR Drive Updater - Portable Launcher
echo  ============================================================
echo   Drive : %DRIVE%
echo   Path  : %SCRIPT_DIR%
echo  ------------------------------------------------------------
echo.

:: ---- Check that PowerShell is available ----
where powershell.exe >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo  [ERROR] PowerShell is not available on this system.
    echo          Please install PowerShell 5.1 or later.
    echo.
    pause
    exit /b 1
)

:: ---- Check that the GUI script exists ----
if not exist "%GUI_SCRIPT%" (
    echo  [ERROR] GUI script not found:
    echo          %GUI_SCRIPT%
    echo.
    pause
    exit /b 1
)

:: ---- Check if auto-launch task is registered ----
powershell.exe -ExecutionPolicy Bypass -NoProfile -Command ^
    "if (Get-ScheduledTask -TaskName 'DFIR-Drive-Updater' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"

if %ERRORLEVEL% neq 0 (
    echo  [INFO] Auto-launch is not configured on this computer.
    echo.
    set /p "SETUP_CHOICE=  Set it up now? (Y/N): "
    echo.
    if /i "!SETUP_CHOICE!"=="Y" (
        if exist "%SETUP_SCRIPT%" (
            echo  [INFO] Running auto-launch setup...
            echo.
            powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%SETUP_SCRIPT%"
            echo.
        ) else (
            echo  [WARN] Setup script not found: %SETUP_SCRIPT%
            echo         Skipping auto-launch configuration.
            echo.
        )
    ) else (
        echo  [INFO] Skipping auto-launch setup.
        echo         You can set it up later by running Setup-AutoLaunch.ps1
        echo.
    )
) else (
    echo  [OK] Auto-launch task is already registered.
    echo.
)

:: ---- Launch the GUI ----
echo  [INFO] Launching DFIR Drive Updater GUI...
echo.
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%GUI_SCRIPT%"

endlocal
