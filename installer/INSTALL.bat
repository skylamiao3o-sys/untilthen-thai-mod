@echo off
setlocal DisableDelayedExpansion
title Until Then - Thai Mod - Low Memory Installer
echo ================================================
echo    Until Then - Thai Mod  [LOW MEMORY]
echo ================================================
echo Save and close the game first. Steam will be asked to exit.
echo If Steam cannot close within 30 seconds, the installer will stop.
echo Extract the WHOLE zip first. Keep all files together.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_low_memory.ps1" %*
set "INSTALL_RESULT=%ERRORLEVEL%"
echo.
if not "%INSTALL_RESULT%"=="0" echo Installation did not complete. See the message above and debug.log.
echo.
pause
exit /b %INSTALL_RESULT%
