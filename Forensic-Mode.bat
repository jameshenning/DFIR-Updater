@echo off
:: Forensic Mode Toggle for DFIR Drive Updater
:: Enables/disables forensic mode AND write protection together

set "DRIVE=%~d0"
set "FLAG=%DRIVE%\FORENSIC_MODE"
set "UPDATERDIR=%~dp0"

echo.
echo  ============================================
echo   DFIR Drive - Forensic Mode Toggle
echo  ============================================
echo.
echo   Forensic Mode combines:
echo     - FORENSIC_MODE flag (blocks the updater)
echo     - Disk write protection (read-only)
echo.

if exist "%FLAG%" (
    echo  Current state: ON (protected)
    echo.
    echo  Disabling Forensic Mode...

    :: Check for admin (needed for write protection)
    net session >nul 2>&1
    if %errorlevel% neq 0 (
        echo  Administrator privileges required for write protection.
        echo  Requesting elevation...
        echo.
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Start-Process cmd -ArgumentList '/c','cd /d \"%UPDATERDIR%\"','&&','\"%~f0\"' -Verb RunAs"
        exit /b
    )

    :: Remove write protection first
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$dl='%DRIVE:~0,1%'; try { $p=Get-Partition -DriveLetter $dl -EA Stop; Set-Disk -Number $p.DiskNumber -IsReadOnly $false -EA Stop; Write-Host '  [OK] Write protection removed.' } catch { Write-Host '  [WARN] Could not remove write protection via Set-Disk.' }"

    :: Then remove the flag file
    del "%FLAG%" 2>nul
    if not exist "%FLAG%" (
        echo  [OFF] Forensic Mode: OFF
        echo        Updater is enabled. Drive is writable.
    ) else (
        echo  [WARN] Could not delete flag file.
    )
) else (
    echo  Current state: OFF (unprotected)
    echo.
    echo  Enabling Forensic Mode...

    :: Check for admin (needed for write protection)
    net session >nul 2>&1
    if %errorlevel% neq 0 (
        echo  Administrator privileges required for write protection.
        echo  Requesting elevation...
        echo.
        powershell -NoProfile -ExecutionPolicy Bypass -Command ^
            "Start-Process cmd -ArgumentList '/c','cd /d \"%UPDATERDIR%\"','&&','\"%~f0\"' -Verb RunAs"
        exit /b
    )

    :: Create the flag file first (while drive is writable)
    echo Forensic Mode enabled > "%FLAG%"

    :: Then enable write protection
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$dl='%DRIVE:~0,1%'; try { $p=Get-Partition -DriveLetter $dl -EA Stop; Set-Disk -Number $p.DiskNumber -IsReadOnly $true -EA Stop; Write-Host '  [OK] Write protection enabled.' } catch { Write-Host '  [WARN] Could not set write protection via Set-Disk.' }"

    if exist "%FLAG%" (
        echo  [ON]  Forensic Mode: ON
        echo        Updater is blocked. Drive is read-only.
    ) else (
        echo  [WARN] Flag file was not created (drive may already be read-only).
    )
)

echo.
pause
