@echo off
:: ============================================================================
:: service_wait.bat  -  Service-readiness wait launcher (Windows)
::   Thin wrapper around ServiceWait.ps1.
::
:: Usage:
::   service_wait.bat <targets-list-file>
::
:: Behavior parameters (initial_wait_sec, interval_sec, success_threshold,
:: timeout_sec, per_check_timeout_sec) come from
:: config/<env>/service_wait.conf via OPS_ENV.
::
:: Per-target overrides (per_check_timeout_sec=N) can be appended to each
:: line in the targets list file.
::
:: Requirements: PowerShell 5.1+
:: Exit codes  : forwarded from ServiceWait.ps1
::   0  = Success (success_threshold consecutive rounds all OK)
::   1  = Usage / argument error
::   2  = Target list parse error
::   3  = Timeout
::   10 = Prerequisite missing
:: ============================================================================
setlocal

set "PS1=%~dp0ServiceWait.ps1"
if not exist "%PS1%" (
    echo [ERROR] ServiceWait.ps1 not found: %PS1%
    exit /b 10
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
