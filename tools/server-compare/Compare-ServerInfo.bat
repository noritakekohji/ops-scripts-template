@echo off
:: DEPRECATED: Use server_snapshot.bat compare
set "TARGET=%~dp0..\server-snapshot\server_snapshot.bat"
if not exist "%TARGET%" (
    echo [ERROR] server_snapshot.bat not found: %TARGET%
    exit /b 10
)
echo [WARN] Compare-ServerInfo.bat is deprecated. Use: server_snapshot.bat compare >&2
call "%TARGET%" compare %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%
