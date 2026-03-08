@echo off
:: Forensic Mode Toggle for DFIR Drive Updater
:: Prevents the updater from running on target/evidence computers

set "FLAG=%~d0\FORENSIC_MODE"

echo.
echo  ============================================
echo   DFIR Drive Updater - Forensic Mode Toggle
echo  ============================================
echo.

if exist "%FLAG%" (
    del "%FLAG%"
    echo  [OFF] Forensic Mode: OFF — Updater is enabled.
) else (
    echo. > "%FLAG%"
    echo  [ON]  Forensic Mode: ON — Updater is blocked.
)

echo.
pause
