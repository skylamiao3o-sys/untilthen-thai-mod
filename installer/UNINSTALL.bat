@echo off
setlocal DisableDelayedExpansion
title Until Then - Thai Mod Uninstaller
echo Save and close the game first. Steam will be asked to exit.
echo If Steam cannot close within 30 seconds, the uninstaller will stop.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_low_memory.ps1" -Restore %*
set "UNINSTALL_RESULT=%ERRORLEVEL%"
echo.
if not "%UNINSTALL_RESULT%"=="0" echo Restore did not complete. See the message above and uninstall_debug.log.
pause
exit /b %UNINSTALL_RESULT%
