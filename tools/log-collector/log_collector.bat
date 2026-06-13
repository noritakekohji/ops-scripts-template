@echo off
:: ============================================================================
:: log_collector.bat  -  Evidence Log Collector launcher (Windows)
::   Thin wrapper around LogCollector.ps1.
::
:: Usage:
::   log_collector.bat -Target <presets> [-ConfigFile <path>] [-Since <duration>]
::                     [-From <datetime>] [-To <datetime>] [-OutputDir <dir>]
::                     [-MaxSizeMB <MB>]
::
:: Examples:
::   log_collector.bat -Target tomcat,os
::   log_collector.bat -Target nginx -Since 48h
::   log_collector.bat -Target tomcat,postgresql -From "2026-06-01 00:00" -To "2026-06-02 00:00"
::   log_collector.bat -Target os -OutputDir C:\evidence -MaxSizeMB 1000
::
:: Requirements: PowerShell 5.1+
:: Exit codes  : forwarded from LogCollector.ps1
::   0  = Success
::   1  = Argument error
::   2  = No files collected
::   10 = Prerequisite missing
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve LogCollector.ps1 path
:: ---------------------------------------------------------------------------
set "PS1=%~dp0LogCollector.ps1"
if not exist "%PS1%" (
    echo [ERROR] LogCollector.ps1 not found: %PS1%
    exit /b 10
)

:: ---------------------------------------------------------------------------
:: Forward all arguments to PowerShell
:: ---------------------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
