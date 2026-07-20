@echo off
setlocal EnableDelayedExpansion
title Until Then - Thai Language Mod Installer
cd /d "%~dp0"

set "LOG=%~dp0debug.log"
> "%LOG%" echo === Until Then Thai Mod - install log ===
>>"%LOG%" echo when    : %date% %time%
>>"%LOG%" echo folder  : %~dp0
>>"%LOG%" echo os      : %OS%  %PROCESSOR_ARCHITECTURE%
>>"%LOG%" echo.

echo ================================================
echo    Until Then - Thai Language Mod  [Installer]
echo ================================================
echo.

REM ---- locate game folder (auto-detect across all Steam libraries) ----
call :step "Looking for the game..."
set "GAME="
for /f "delims=" %%G in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0detect_game.ps1" 2^>^>"%LOG%"') do set "GAME=%%G"
if not defined GAME set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Until Then"
>>"%LOG%" echo game(detected): %GAME%
if not exist "%GAME%\UntilThen.pck" if not exist "%GAME%\UntilThen.pck.bak" (
  echo [X] Could not auto-detect "Until Then".
  echo     ^(Steam -^> right-click Until Then -^> Manage -^> Browse local files^)
  echo.
  set /p "GAME=Type the full path to the Until Then folder and press Enter: "
)
>>"%LOG%" echo game(final)   : !GAME!
if not exist "!GAME!\UntilThen.pck" if not exist "!GAME!\UntilThen.pck.bak" (
  call :fail "Cannot find UntilThen.pck in: !GAME!"
  goto :end
)
call :ok "Game folder: !GAME!"

REM ---- find Steam.exe (to close gracefully + reopen) ----
set "STEAMEXE="
for /f "tokens=2,*" %%A in ('reg query "HKCU\Software\Valve\Steam" /v SteamExe 2^>nul') do set "STEAMEXE=%%B"
if defined STEAMEXE set "STEAMEXE=!STEAMEXE:/=\!"
>>"%LOG%" echo steam.exe    : !STEAMEXE!
set "REOPEN="

REM ---- close Steam if running (it locks the pck) ----
tasklist /fi "imagename eq steam.exe" 2>nul | find /i "steam.exe" >nul
if not errorlevel 1 (
  set "REOPEN=1"
  if defined STEAMEXE (
    call :step "Closing Steam gracefully (will reopen when done)..."
    start "" "!STEAMEXE!" -shutdown
  ) else (
    echo [!] Please FULLY EXIT Steam ^(tray -^> Exit^), then press a key...
    pause >nul
  )
)
set /a _w=0
:waitsteam
tasklist /fi "imagename eq steam.exe" 2>nul | find /i "steam.exe" >nul
if not errorlevel 1 (
  set /a _w+=1
  if !_w! gtr 20 ( echo [!] Steam still running - exit it then press a key... & pause >nul & set /a _w=0 ) else ( ping -n 3 127.0.0.1 >nul )
  goto :waitsteam
)
>>"%LOG%" echo steam closed after !_w! checks

set "TOOL=%~dp0tools\GodotPCKExplorer.Console.exe"
set "PAYLOAD=%~dp0payload"
set "PCK=!GAME!\UntilThen.pck"
set "BAK=!GAME!\UntilThen.pck.bak"
set "TMP=!GAME!\UntilThen.thmod.tmp.pck"
if exist "!TOOL!" (>>"%LOG%" echo tool exists: YES) else (>>"%LOG%" echo tool exists: NO - antivirus may have removed it)
if exist "!PAYLOAD!" (>>"%LOG%" echo payload   : YES) else (>>"%LOG%" echo payload   : NO)
if not exist "!TOOL!"    ( call :fail "Missing pck tool (antivirus may have deleted it): !TOOL!" & goto :end )
if not exist "!PAYLOAD!" ( call :fail "Missing payload folder: !PAYLOAD!" & goto :end )

REM ---- verify the mod files were extracted COMPLETELY (zip half-extracted / AV quarantined files) ----
if exist "%~dp0payload.manifest" (
  set /p EXPECT=<"%~dp0payload.manifest"
  set "ACTUAL=0"
  for /f %%C in ('powershell -NoProfile -Command "(Get-ChildItem -LiteralPath '%~dp0payload' -Recurse -File).Count" 2^>^>"%LOG%"') do set "ACTUAL=%%C"
  >>"%LOG%" echo payload files: !ACTUAL! / expected !EXPECT!
  if not "!ACTUAL!"=="!EXPECT!" (
    call :fail "Mod files are incomplete (!ACTUAL! of !EXPECT! files). Re-extract the whole .zip (Extract All), or your antivirus quarantined some files - restore them / add an exclusion, then retry."
    goto :end
  )
)

REM ---- auto-repair: if the CURRENT game file is damaged (e.g. by an older installer failing
REM      mid-install) but a healthy backup exists, put the original back first ----
if exist "!BAK!" if exist "!PCK!" (
  set "V0=MISSING"
  for /f "delims=" %%V in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0validate_pck.ps1" -Pck "!PCK!" -Base "!BAK!" 2^>^>"%LOG%"') do set "V0=%%V"
  >>"%LOG%" echo current pck validate: !V0!
  if not "!V0!"=="OK" (
    call :step "Current game file looks damaged - restoring the original from backup first..."
    copy /Y "!BAK!" "!PCK!" >>"%LOG%" 2>&1
    if errorlevel 1 ( call :fail "Cannot restore the backup. Close Steam fully and retry." & goto :end )
    call :ok "Original restored."
  )
)
if exist "!BAK!" if not exist "!PCK!" (
  call :step "Game file is missing - restoring the original from backup first..."
  copy /Y "!BAK!" "!PCK!" >>"%LOG%" 2>&1
)

REM ---- backup original (only once) ----
if not exist "!BAK!" (
  call :step "Backing up original -> UntilThen.pck.bak"
  copy /Y "!PCK!" "!BAK!" >>"%LOG%" 2>&1
  if errorlevel 1 ( call :fail "Cannot write to the game folder (try Run as administrator)" & goto :end )
  call :ok "Backup created."
)

REM ---- build Thai pck from backup + payload ----
call :step "Building Thai version (~3 GB, ~10-30s)..."
REM kill any stale tool process + sweep stale temp leftovers (files OR folders) from previous runs
taskkill /f /im GodotPCKExplorer.Console.exe >nul 2>&1
for /d %%D in ("!GAME!\UntilThen.thmod.*") do rd /s /q "%%D" >>"%LOG%" 2>&1
del /f /q "!GAME!\UntilThen.thmod.*" >>"%LOG%" 2>&1
if exist "!TMP!" (
  >>"%LOG%" echo WARN: old temp pck is locked, using a fresh name
  set "TMP=!GAME!\UntilThen.thmod.!RANDOM!.pck"
)
>>"%LOG%" echo --- free space on game drive ---
for /f "tokens=3" %%S in ('dir /-c "!GAME!" ^| find "bytes free"') do >>"%LOG%" echo   %%S bytes free
set "PLOG=%~dp0_pcktool.tmp"
set "PACK_OK="
set "_try=0"
:buildloop
set /a _try+=1
>>"%LOG%" echo --- pck pack attempt !_try! to: !TMP! ---
"!TOOL!" -pc "!BAK!" "!PAYLOAD!" "!TMP!" "2.4.1.4" > "!PLOG!" 2>&1
>>"%LOG%" echo pck tool exit: !errorlevel!
REM ** validate the built pck is COMPLETE (magic GDPC + size >= 95%% of original) **
REM    a partial/corrupt pck (disk full / AV lock) must NOT be installed - that breaks the game
set "VALID=MISSING"
for /f "delims=" %%V in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0validate_pck.ps1" -Pck "!TMP!" -Base "!BAK!" 2^>^>"%LOG%"') do set "VALID=%%V"
>>"%LOG%" echo pck validate: !VALID!
if "!VALID!"=="OK" ( set "PACK_OK=1" & goto :buildok )
REM invalid/incomplete -> clean up, then retry once building into %TEMP% (different drive / AV-safe)
taskkill /f /im GodotPCKExplorer.Console.exe >nul 2>&1
if exist "!TMP!" del /f /q "!TMP!" >>"%LOG%" 2>&1
if !_try! lss 2 (
  set "TMP=%TEMP%\UntilThen.thmod.!RANDOM!.pck"
  >>"%LOG%" echo retry: building into TEMP instead: !TMP!
  ping -n 3 127.0.0.1 >nul
  goto :buildloop
)
:buildok
>>"%LOG%" echo --- pck tool output (last 40 lines) ---
powershell -NoProfile -Command "try{ Get-Content -LiteralPath '!PLOG!' -Encoding Unicode -Tail 40 -EA Stop }catch{ Get-Content -LiteralPath '!PLOG!' -Tail 40 -EA SilentlyContinue }" >>"%LOG%" 2>&1
del /f /q "!PLOG!" 2>nul
if not defined PACK_OK ( call :fail "Build produced an incomplete/invalid .pck (the game was NOT changed). Most likely LOW DISK SPACE - you need about 4 GB free on the drive where the game is installed. Free up space (or add the 'Until Then' folder to your antivirus exclusions), then run this installer again." & goto :end )

REM ---- replace the live pck ----
call :step "Installing..."
set "INSTOK="
if /i "!TMP:~0,2!"=="!PCK:~0,2!" (
  REM same drive: rename is near-atomic - no half-written file even if interrupted
  move /y "!TMP!" "!PCK!" >>"%LOG%" 2>&1
  if not errorlevel 1 set "INSTOK=1"
) else (
  copy /Y "!TMP!" "!PCK!" >>"%LOG%" 2>&1
  if not errorlevel 1 set "INSTOK=1"
)
if exist "!TMP!" del /f /q "!TMP!" >>"%LOG%" 2>&1
REM ** verify the LIVE game file after install (catches a copy that died half-way) **
set "VALID2=MISSING"
for /f "delims=" %%V in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0validate_pck.ps1" -Pck "!PCK!" -Base "!BAK!" 2^>^>"%LOG%"') do set "VALID2=%%V"
>>"%LOG%" echo installed pck validate: !VALID2!
if not "!VALID2!"=="OK" set "INSTOK="
if not defined INSTOK (
  >>"%LOG%" echo install failed - restoring backup over live pck
  call :step "Install failed - restoring the original game file from backup..."
  copy /Y "!BAK!" "!PCK!" >>"%LOG%" 2>&1
  call :fail "Could not install safely - the ORIGINAL game file was put back (the game still works, in English). Causes: Steam still running, low disk space (~4 GB free needed), or antivirus blocking writes - add the 'Until Then' folder to AV exclusions, then run this installer again."
  goto :end
)
REM final sweep: leave no UntilThen.thmod.* leftovers (files or folders) in the game folder
for /d %%D in ("!GAME!\UntilThen.thmod.*") do rd /s /q "%%D" >nul 2>&1
del /f /q "!GAME!\UntilThen.thmod.*" >nul 2>&1

call :ok "DONE - installed!"
echo.
echo ================================================
echo    DONE!  Open the game then:
echo    Settings -^> Language:
echo       "Thai"          = polite (kid-safe)
echo       "Thai (rough)"  = slangy teen style
echo ================================================
echo To uninstall: run UNINSTALL.bat
if defined REOPEN if defined STEAMEXE ( echo. & call :step "Reopening Steam..." & start "" "!STEAMEXE!" )
goto :end

REM ================= helpers =================
:step
echo [..] %~1
>>"%LOG%" echo [..] %~1
goto :eof
:ok
echo [OK] %~1
>>"%LOG%" echo [OK] %~1
goto :eof
:fail
echo.
echo [X] %~1
echo     ^(a debug.log was saved next to this installer - send it to the author^)
>>"%LOG%" echo [X] FAIL: %~1
goto :eof

:end
>>"%LOG%" echo === finished: %date% %time% ===
echo.
echo  (debug log: "%LOG%")
echo.
pause
exit /b
