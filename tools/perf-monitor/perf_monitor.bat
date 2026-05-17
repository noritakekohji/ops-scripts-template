@echo off
:: ============================================================================
:: perf_monitor.bat  -  Performance Monitor launcher (Windows)
::   Thin wrapper around PerfMonitor.ps1.
::
:: Usage:
::   perf_monitor.bat start  [-Interval sec] [-Duration sec] [-OutputDir dir]
::                           [-Prefix name]  [-Config file]
::   perf_monitor.bat stop   [session_dir]
::   perf_monitor.bat report <session_dir>  [-Config file]
::   perf_monitor.bat status [session_dir]
::   perf_monitor.bat list
::
:: Examples:
::   perf_monitor.bat start
::   perf_monitor.bat start -Interval 10 -Duration 1800 -OutputDir C:\results
::   perf_monitor.bat stop
::   perf_monitor.bat stop   .\perf_20260517-100000
::   perf_monitor.bat report .\perf_20260517-100000
::   perf_monitor.bat status
::   perf_monitor.bat list
::
:: Requirements: PowerShell 5.1+ (python3 optional; PS-native renderer is used if absent)
:: Exit codes  : forwarded from PerfMonitor.ps1
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve PerfMonitor.ps1 path
:: ---------------------------------------------------------------------------
set "PS1=%~dp0PerfMonitor.ps1"
if not exist "%PS1%" (
    echo [ERROR] PerfMonitor.ps1 not found: %PS1%
    exit /b 1
)

:: ---------------------------------------------------------------------------
:: Get command (default: status)
:: ---------------------------------------------------------------------------
set "CMD=%~1"
if "%CMD%"=="" set "CMD=status"

if /i "%CMD%"=="start"  goto :cmd_start
if /i "%CMD%"=="stop"   goto :cmd_stop
if /i "%CMD%"=="report" goto :cmd_report
if /i "%CMD%"=="status" goto :cmd_status
if /i "%CMD%"=="list"   goto :cmd_list
if /i "%CMD%"=="-h"     goto :cmd_help
if /i "%CMD%"=="--help" goto :cmd_help
if /i "%CMD%"=="-?"     goto :cmd_help

echo [ERROR] Unknown command: %CMD%
echo.
goto :cmd_help

:: ---------------------------------------------------------------------------
:: start  -  begin metric collection
::   Pass all options after "start" directly to PerfMonitor.ps1
::   -Interval, -Duration, -OutputDir, -Prefix, -Config are accepted
:: ---------------------------------------------------------------------------
:cmd_start
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" start ^
    %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: stop  -  stop metric collection
::   Optional second argument: session directory path
:: ---------------------------------------------------------------------------
:cmd_stop
if "%~2"=="" (
    powershell.exe -ExecutionPolicy Bypass -File "%PS1%" stop
) else (
    powershell.exe -ExecutionPolicy Bypass -File "%PS1%" stop ^
        -SessionDir "%~2" %3 %4 %5 %6 %7 %8
)
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: report  -  generate HTML report from collected data
::   Second argument (session directory) is required
:: ---------------------------------------------------------------------------
:cmd_report
if "%~2"=="" (
    echo [ERROR] Session directory is required for report.
    echo   Example: perf_monitor.bat report .\perf_20260517-100000
    exit /b 1
)
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" report ^
    -SessionDir "%~2" %3 %4 %5 %6 %7 %8
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: status  -  show current state and latest metrics
::   Optional second argument: session directory path
:: ---------------------------------------------------------------------------
:cmd_status
if "%~2"=="" (
    powershell.exe -ExecutionPolicy Bypass -File "%PS1%" status
) else (
    powershell.exe -ExecutionPolicy Bypass -File "%PS1%" status ^
        -SessionDir "%~2" %3 %4 %5 %6 %7
)
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: list  -  list all sessions
:: ---------------------------------------------------------------------------
:cmd_list
powershell.exe -ExecutionPolicy Bypass -File "%PS1%" list
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: help
:: ---------------------------------------------------------------------------
:cmd_help
echo.
echo  Usage: perf_monitor.bat ^<command^> [options]
echo.
echo  Commands:
echo    start  [-Interval sec] [-Duration sec] [-OutputDir dir] [-Prefix name]
echo           Start collecting metrics (default: 5s interval, run until stop)
echo.
echo    stop   [session_dir]
echo           Stop collection (omit to auto-detect latest session)
echo.
echo    report ^<session_dir^> [-Config file]
echo           Generate HTML report (python3 optional; PS-native fallback)
echo.
echo    status [session_dir]
echo           Show collection state and latest metric snapshot
echo.
echo    list   List all sessions
echo.
echo  Examples:
echo    perf_monitor.bat start
echo    perf_monitor.bat start -Interval 10 -Duration 1800 -OutputDir C:\results
echo    perf_monitor.bat stop
echo    perf_monitor.bat stop   .\perf_20260517-100000
echo    perf_monitor.bat report .\perf_20260517-100000
echo    perf_monitor.bat status
echo    perf_monitor.bat list
echo.
exit /b 0
