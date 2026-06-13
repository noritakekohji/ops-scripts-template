@echo off
:: ============================================================================
:: server_snapshot.bat  -  Server Snapshot launcher (Windows)
::   Thin wrapper around ServerSnapshot.ps1.
::
:: Usage:
::   server_snapshot.bat collect  [-Category cats] [-OutputPath file] [-Label name]
::   server_snapshot.bat before   [-Category cats] [-OutputPath file] [-Label name]
::   server_snapshot.bat after    [-Category cats] [-Label name]
::                                [-BeforePath file] [-HtmlReport file]
::   server_snapshot.bat compare  -BeforePath before.json -AfterPath after.json
::                                [-HtmlReport file] [-DiffOnly]
::   server_snapshot.bat list
::
:: Examples:
::   server_snapshot.bat collect
::   server_snapshot.bat before -Label deploy-v1
::   server_snapshot.bat after  -Label deploy-v1 -HtmlReport report.html
::   server_snapshot.bat compare -BeforePath before.json -AfterPath after.json
::   server_snapshot.bat list
::
:: Requirements: PowerShell 5.1+
:: Exit codes  : forwarded from ServerSnapshot.ps1
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve ServerSnapshot.ps1 path
:: ---------------------------------------------------------------------------
set "PS1=%~dp0ServerSnapshot.ps1"
if not exist "%PS1%" (
    echo [ERROR] ServerSnapshot.ps1 not found: %PS1%
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Get command (default: collect)
:: ---------------------------------------------------------------------------
set "CMD=%~1"
if "%CMD%"=="" set "CMD=collect"

if /i "%CMD%"=="collect" goto :cmd_collect
if /i "%CMD%"=="before"  goto :cmd_before
if /i "%CMD%"=="after"   goto :cmd_after
if /i "%CMD%"=="compare" goto :cmd_compare
if /i "%CMD%"=="list"    goto :cmd_list
if /i "%CMD%"=="-h"      goto :cmd_help
if /i "%CMD%"=="--help"  goto :cmd_help
if /i "%CMD%"=="-?"      goto :cmd_help

echo [ERROR] Unknown command: %CMD%
echo.
goto :cmd_help

:: ---------------------------------------------------------------------------
:: collect  -  collect server configuration snapshot as JSON
::   Pass all options after "collect" directly to ServerSnapshot.ps1
::   -Category, -OutputPath, -Label are accepted
:: ---------------------------------------------------------------------------
:cmd_collect
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" collect ^
    %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: before  -  collect labeled "before" snapshot (pre-change)
::   -Category, -OutputPath, -Label are accepted
:: ---------------------------------------------------------------------------
:cmd_before
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" before ^
    %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: after  -  collect "after" snapshot + auto-compare with latest before
::   -Category, -Label, -BeforePath, -HtmlReport are accepted
:: ---------------------------------------------------------------------------
:cmd_after
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" after ^
    %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: compare  -  compare two existing snapshot JSON files
::   -BeforePath, -AfterPath are required; -HtmlReport, -DiffOnly optional
:: ---------------------------------------------------------------------------
:cmd_compare
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" compare ^
    %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: list  -  list stored snapshots in current directory
:: ---------------------------------------------------------------------------
:cmd_list
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" list
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: help
:: ---------------------------------------------------------------------------
:cmd_help
echo.
echo  Usage: server_snapshot.bat ^<command^> [options]
echo.
echo  Commands:
echo    collect  [-Category cats] [-OutputPath file] [-Label name]
echo             Collect server configuration snapshot as JSON
echo.
echo    before   [-Category cats] [-OutputPath file] [-Label name]
echo             Collect labeled "before" snapshot (pre-change)
echo.
echo    after    [-Category cats] [-Label name] [-BeforePath file] [-HtmlReport file]
echo             Collect "after" snapshot + auto-compare with latest before
echo.
echo    compare  -BeforePath before.json -AfterPath after.json [-HtmlReport file] [-DiffOnly]
echo             Compare two existing snapshot JSON files
echo.
echo    list     List stored snapshots in current directory
echo.
echo  Examples:
echo    server_snapshot.bat collect
echo    server_snapshot.bat before -Label deploy-v1
echo    server_snapshot.bat after  -Label deploy-v1 -HtmlReport report.html
echo    server_snapshot.bat compare -BeforePath before.json -AfterPath after.json
echo    server_snapshot.bat list
echo.
exit /b 0
