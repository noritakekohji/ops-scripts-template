@echo off
:: DEPRECATED: Use server_snapshot.bat
set "TARGET=%~dp0..\server-snapshot\server_snapshot.bat"
if not exist "%TARGET%" (
    echo [ERROR] server_snapshot.bat not found: %TARGET%
    exit /b 10
)
set "MODE=%~1"
if "%MODE%"=="" (
    echo Usage: Change-Detect.bat ^<before^|after^|compare^> [options]
    exit /b 1
)
echo [WARN] Change-Detect.bat is deprecated. Use: server_snapshot.bat %MODE% >&2
call "%TARGET%" %MODE% %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%
