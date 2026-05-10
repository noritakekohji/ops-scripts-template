@echo off
:: ============================================================================
:: install.bat
::   Thin wrapper that invokes Deploy-Scripts.ps1.
::   Run from the repository root. The first argument is the environment name.
::
:: Usage:
::   install.bat [<env>] [options]
::
:: Arguments:
::   <env>   Environment name (dev / staging / production / ...).
::           Defaults to "default" when omitted.
::
:: Options (passed through to Deploy-Scripts.ps1):
::   -Backup   Back up existing files before overwriting.
::   -WhatIf   Dry-run; log actions without making changes.
::
:: Examples:
::   install.bat
::   install.bat dev
::   install.bat production -Backup
::   install.bat staging -WhatIf
::
:: Deploy targets : config\default\deploy_scripts.lst
::                  (or config\<env>\deploy_scripts.lst when env is given)
:: Deploy root    : C:\ProgramData\ops-scripts  (configurable via conf)
::
:: Runtime        : powershell.exe (Windows PowerShell 5.1)
:: Exit codes     : forwarded from Deploy-Scripts.ps1
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve env argument.
:: If the first argument is missing or starts with "-", treat it as an option
:: and use "default" as the environment name.
:: ---------------------------------------------------------------------------
if "%~1"=="" (
    set "ENV_NAME=default"
) else (
    if "%~1:~0,1%"=="-" (
        set "ENV_NAME=default"
    ) else (
        set "ENV_NAME=%~1"
        shift
    )
)

:: ---------------------------------------------------------------------------
:: Run Deploy-Scripts.ps1 with Windows PowerShell 5.1 (powershell.exe).
:: ---------------------------------------------------------------------------
powershell.exe -ExecutionPolicy Bypass -File "%~dp0scripts\windows\powershell\Deploy-Scripts.ps1" -Env "%ENV_NAME%" %*

exit /b %ERRORLEVEL%
