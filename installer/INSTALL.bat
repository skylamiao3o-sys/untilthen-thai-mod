@echo off
setlocal DisableDelayedExpansion
title Until Then - Thai Mod - Low Memory Installer
echo ================================================
echo    Until Then - Thai Mod  [LOW MEMORY]
echo ================================================
echo Save and close Until Then first. You manage Steam yourself.
echo Steam may stay open if the game files are not locked.
echo Extract the WHOLE zip first. Keep all files together.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_low_memory.ps1" %*
set "INSTALL_RESULT=%ERRORLEVEL%"
echo.
if not "%INSTALL_RESULT%"=="0" echo Installation did not complete. See the message above and debug.log.
echo.
pause
exit /b %INSTALL_RESULT%
