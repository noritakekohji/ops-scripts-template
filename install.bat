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
::
:: NOTE: %* does not reflect shift in cmd.exe, so we branch into two
::       separate run labels to avoid passing the env name twice.
:: ---------------------------------------------------------------------------
if "%~1"=="" (
    set "ENV_NAME=default"
    goto :run_noshift
)
:: cmd.exe では %~1 を直接 substring 展開できないため、いったん変数化する。
set "ARG1=%~1"
if "%ARG1:~0,1%"=="-" (
    set "ENV_NAME=default"
    goto :run_noshift
)
set "ENV_NAME=%~1"
shift
goto :run_shifted

:: ---------------------------------------------------------------------------
:: No shift was done: pass remaining args via %* (all original args).
:: ---------------------------------------------------------------------------
:run_noshift
powershell.exe -ExecutionPolicy Bypass -File "%~dp0scripts_windows\os\Deploy-Scripts.ps1" -Env "%ENV_NAME%" %*
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:: Env arg was consumed by shift: pass remaining args via %1 %2 ... %9.
:: After shift, %1 is the original %2, so the env name is no longer included.
:: ---------------------------------------------------------------------------
:run_shifted
powershell.exe -ExecutionPolicy Bypass -File "%~dp0scripts_windows\os\Deploy-Scripts.ps1" -Env "%ENV_NAME%" %1 %2 %3 %4 %5 %6 %7 %8 %9
exit /b %ERRORLEVEL%
