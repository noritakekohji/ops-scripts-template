@echo off
setlocal

:: Launch ReportSnapshot.ps1 with forwarded arguments.
:: Usage:
::   report_snapshot.bat <zipfile>
::   report_snapshot.bat <zipfile> -CompareWith <zipfile2>
::   report_snapshot.bat <zipfile> -OutputDir <dir>

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%ReportSnapshot.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %*

exit /b %ERRORLEVEL%
