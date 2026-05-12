@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  Network Connectivity Check
echo ================================================
echo.

:: Default target list
set "DEFAULT_LIST="
if exist "%~dp0targets.lst" set "DEFAULT_LIST=targets.lst"

if defined DEFAULT_LIST (
    set /p "LIST=Target list file [Enter for '%DEFAULT_LIST%']: "
    if "!LIST!"=="" set "LIST=%DEFAULT_LIST%"
) else (
    set /p "LIST=Target list file: "
)

if "!LIST!"=="" (
    echo No target list specified.
    pause
    exit /b 1
)

set /p "HTML=HTML report path   [Enter to skip       ]: "

echo.
echo Running...
echo.

for /f %%t in ('powershell -NoLogo -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TIMESTAMP=%%t"
set "OPS_LOG_FILE=%~dpn0_!TIMESTAMP!.log"
set "PSARGS=-TargetList "!LIST!""
if not "!HTML!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML!""

powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Check-NetworkConnectivity.ps1" !PSARGS!

echo.
pause
endlocal
