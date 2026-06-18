@echo off
:: ============================================================================
:: aws_instance_audit.bat  -  Launcher for Get-AwsInstanceAudit.ps1 (Windows)
::   Transcript-style logging is handled by the .ps1 itself.
::
:: Usage:
::   aws_instance_audit.bat [-Category cats] [-OutputPath out.json]
::                          [-HtmlReport out.html] [-Region region]
::   aws_instance_audit.bat -FromJson <saved.json> [-OutputPath file] [-HtmlReport file]
::
:: Examples:
::   aws_instance_audit.bat
::   aws_instance_audit.bat -Category iam,sg -HtmlReport audit.html
::   aws_instance_audit.bat -OutputPath C:\reports\audit.json
::
:: Requirements: PowerShell 5.1+, AWS CLI v2 (python3 only for -HtmlReport)
:: Exit codes  : forwarded from Get-AwsInstanceAudit.ps1
:: ============================================================================
setlocal
set "PS1=%~dp0Get-AwsInstanceAudit.ps1"
if not exist "%PS1%" (
    echo [ERROR] Get-AwsInstanceAudit.ps1 not found: %PS1%
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
