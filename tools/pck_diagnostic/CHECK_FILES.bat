@echo off
setlocal DisableDelayedExpansion
title Until Then - Read Only File Check
echo Extract the whole ZIP first, then run CHECK_FILES.bat.
echo Save and close Until Then before checking.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_files.ps1" %*
set "CHECK_RESULT=%ERRORLEVEL%"
echo.
echo Send diagnostic.log from this folder to the mod maintainer.
pause
exit /b %CHECK_RESULT%
