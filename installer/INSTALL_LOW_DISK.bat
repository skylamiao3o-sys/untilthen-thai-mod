@echo off
setlocal DisableDelayedExpansion
title Until Then - Thai Mod - Low Disk Installer
echo ================================================
echo    Until Then - Thai Mod  [LOW DISK + LOW MEMORY]
echo ================================================
echo Save and close Until Then first. You manage Steam yourself.
echo This mode keeps NO full game backup.
echo It removes an old .bak and recognized temporary packs ONLY
echo after the live game passes full verification.
echo To remove the mod later, use Steam - Verify integrity of game files.
echo About 3.5 GB must be free after space recovery to build safely.
echo Extract the WHOLE zip first. Keep all files together.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_low_memory.ps1" -LowDisk %*
set "INSTALL_RESULT=%ERRORLEVEL%"
echo.
if not "%INSTALL_RESULT%"=="0" echo Installation did not complete. See the message above and debug.log.
pause
exit /b %INSTALL_RESULT%
