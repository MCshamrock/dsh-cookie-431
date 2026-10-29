@echo off
chcp 65001 >nul
setlocal
title DSH login cookie fix

echo ================================================
echo   DSH login-cookie cleanup (dsh-auth-* / HTTP 431)
echo ================================================
echo.
echo Close DSH completely first (tray icon too).
echo If DSH is still running, this script refuses and changes nothing.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-cookie-fix.ps1" -Restart %*

set RC=%ERRORLEVEL%
echo.
echo ------------------------------------------------
echo exit code: %RC%
if "%RC%"=="0"  echo OK.
if "%RC%"=="2"  echo DSH is still running: nothing changed. Close it and run again.
if "%RC%"=="3"  echo python not found.
if "%RC%"=="4"  echo cookie DB unreadable.
if "%RC%"=="5"  echo delete failed.
if "%RC%"=="99" echo script crashed - see the red text above and the log.
echo log: %~dp0dsh-cookie-fix.log
echo ------------------------------------------------
echo.
pause
