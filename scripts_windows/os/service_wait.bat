@echo off
:: ============================================================================
:: service_wait.bat  -  Service-readiness wait launcher (Windows)
::   Thin wrapper around ServiceWait.ps1.
::
:: Usage:
::   service_wait.bat -TargetList <file> [-TimeoutSec sec] [-IntervalSec sec]
::                    [-RequiredOk n]
::
:: Examples:
::   service_wait.bat -TargetList targets.lst
::   service_wait.bat -TargetList targets.lst -TimeoutSec 300 -IntervalSec 5
::
:: Requirements: PowerShell 5.1+
:: Exit codes  : forwarded from ServiceWait.ps1
::   0  = Success
::   1  = Usage / argument error
::   2  = Target list parse error
::   3  = Timeout
::   10 = Prerequisite missing
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve ServiceWait.ps1 path
:: ---------------------------------------------------------------------------
set "PS1=%~dp0ServiceWait.ps1"
if not exist "%PS1%" (
    echo [ERROR] ServiceWait.ps1 not found: %PS1%
    exit /b 10
)

:: ---------------------------------------------------------------------------
:: Forward all arguments to PowerShell
:: ---------------------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
