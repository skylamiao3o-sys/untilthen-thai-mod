@echo off
setlocal DisableDelayedExpansion
title Until Then - Thai Mod Uninstaller
echo Save and close Until Then first. You manage Steam yourself.
echo Steam may stay open if the game files are not locked.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_low_memory.ps1" -Restore %*
set "UNINSTALL_RESULT=%ERRORLEVEL%"
echo.
if not "%UNINSTALL_RESULT%"=="0" echo Restore did not complete. See the message above and uninstall_debug.log.
pause
exit /b %UNINSTALL_RESULT%
