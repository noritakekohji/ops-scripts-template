@echo off
:: ============================================================================
:: cert_check.bat  -  TLS Certificate Expiry Checker launcher (Windows)
::   Thin wrapper around CertCheck.ps1.
::
:: Usage:
::   cert_check.bat -TargetList <file> [-TimeoutSec sec] [-HtmlReport file]
::                  [-Json] [-FailOnly]
::   cert_check.bat -FromJson <saved.json> [-HtmlReport file] [-Json] [-FailOnly]
::
:: Examples:
::   cert_check.bat -TargetList cert_targets.lst
::   cert_check.bat -TargetList cert_targets.lst -HtmlReport report.html
::   cert_check.bat -TargetList cert_targets.lst -Json
::   cert_check.bat -TargetList cert_targets.lst -FailOnly
::
:: Requirements: PowerShell 5.1+
:: Exit codes  : forwarded from CertCheck.ps1
::   0  = All OK (no WARN, no NG)
::   1  = NG or WARN found
::   2  = Target list not found
::   10 = Prerequisite missing
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve CertCheck.ps1 path
:: ---------------------------------------------------------------------------
set "PS1=%~dp0CertCheck.ps1"
if not exist "%PS1%" (
    echo [ERROR] CertCheck.ps1 not found: %PS1%
    exit /b 10
)

:: ---------------------------------------------------------------------------
:: Forward all arguments to PowerShell
:: ---------------------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
