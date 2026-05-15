@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  Change Detection Tool
echo ================================================
echo.
echo  Modes:
echo    before  - Take snapshot BEFORE a change
echo    after   - Take snapshot AFTER a change and compare
echo    compare - Compare two existing snapshot files
echo.

set /p "MODE=Mode (before / after / compare): "
if "!MODE!"=="" (
    echo Mode is required.
    pause
    exit /b 1
)

set /p "LABEL=Label (e.g. deploy-v1.2.3) [Enter to skip]: "

set /p "CATEGORY=Categories [Enter for 'all']: "
if "!CATEGORY!"=="" set "CATEGORY=all"

set "PSARGS=-Mode "!MODE!" -Category "!CATEGORY!""
if not "!LABEL!"=="" set "PSARGS=!PSARGS! -Label "!LABEL!""

if /i "!MODE!"=="compare" (
    set /p "BEFORE=Before snapshot path: "
    set /p "AFTER=After  snapshot path: "
    if "!BEFORE!"=="" ( echo Before path is required. & pause & exit /b 1 )
    if "!AFTER!"==""  ( echo After  path is required. & pause & exit /b 1 )
    set "PSARGS=!PSARGS! -BeforePath "!BEFORE!" -AfterPath "!AFTER!""
)

set /p "HTML=HTML report path [Enter to skip]: "
if not "!HTML!"=="" set "PSARGS=!PSARGS! -HtmlReport "!HTML!""

echo.
echo Running...
echo.

for /f %%t in ('powershell -NoLogo -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "TIMESTAMP=%%t"
set "OPS_LOG_FILE=%~dpn0_!TIMESTAMP!.log"

powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Change-Detect.ps1" !PSARGS!

echo.
pause
endlocal
