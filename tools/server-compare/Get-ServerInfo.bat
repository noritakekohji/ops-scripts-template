@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo.
echo ================================================
echo  Get Server Info - Windows
echo ================================================
echo.
echo Categories: all, os, network, services, packages,
echo             users, filesystem, environment, security
echo.

set /p "CATEGORY=Categories    [Enter for 'all'          ]: "
if "!CATEGORY!"=="" set "CATEGORY=all"

set /p "OUTPUT=Output JSON path [Enter for auto-named file]: "

echo.
echo Running...
echo.

set "PSARGS=-Category !CATEGORY!"
if not "!OUTPUT!"=="" set "PSARGS=!PSARGS! -OutputPath "!OUTPUT!""

powershell.exe -ExecutionPolicy Bypass -NoLogo ^
    -File "%~dp0Get-ServerInfo.ps1" !PSARGS!

echo.
pause
endlocal
