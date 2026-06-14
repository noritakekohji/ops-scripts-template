@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  Network Connectivity Check
echo ================================================
echo.

:: ---------------------------------------------------------------------------
:: Target list resolution
::   1) %1 if supplied
::   2) DEFAULT_LIST set below (targets.lst alongside this bat)
:: ---------------------------------------------------------------------------
set "DEFAULT_LIST=%~dp0targets.lst"

if not "%~1"=="" (
    set "LIST=%~1"
) else (
    set "LIST=%DEFAULT_LIST%"
)

if not exist "!LIST!" (
    echo [ERROR] Target list not found: !LIST!
    echo Usage: %~nx0 [target-list-file]
    pause
    exit /b 2
)

echo Target list: !LIST!
echo.

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
