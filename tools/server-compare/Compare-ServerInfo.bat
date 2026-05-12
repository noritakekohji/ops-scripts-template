@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  Compare Server Info
echo ================================================
echo.

set /p "BEFORE=Before JSON file (old server): "
if "!BEFORE!"=="" (
    echo Before file is required.
    pause
    exit /b 1
)

set /p "AFTER=After  JSON file (new server): "
if "!AFTER!"=="" (
    echo After file is required.
    pause
    exit /b 1
)

set /p "HTML=HTML report path [Enter to skip       ]: "

echo.
echo Running...
echo.

for /f %%t in ('powershell -NoLogo -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TIMESTAMP=%%t"
set "OPS_LOG_FILE=%~dpn0_!TIMESTAMP!.log"
set "PSARGS=-Before "!BEFORE!" -After "!AFTER!""
if not "!HTML!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML!""

powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Compare-ServerInfo.ps1" !PSARGS!

echo.
pause
endlocal
