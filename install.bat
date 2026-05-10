@echo off
:: ============================================================================
:: install.bat
::   Deploy-Scripts.ps1 を呼び出す薄いラッパ。
::   リポジトリルートから実行し、第 1 引数に環境名を渡す。
::
:: Usage:
::   install.bat <env> [Deploy-Scripts.ps1 のオプション...]
::
:: Examples:
::   install.bat dev
::   install.bat production
::   install.bat staging -Backup
::   install.bat dev -WhatIf
::
:: 配備対象は config\default\deploy_scripts.lst（または
:: config\<env>\deploy_scripts.lst で上書き）を参照。
:: 配備先は C:\ProgramData\ops-scripts（config で変更可）。
::
:: Exit codes: Deploy-Scripts.ps1 の終了コードをそのまま返す
:: ============================================================================
setlocal

if "%~1"=="" (
    echo Usage: %~nx0 ^<env^> [options] 1>&2
    echo.                                 1>&2
    echo   ^<env^>  環境名（dev / staging / production など）  1>&2
    echo.                                 1>&2
    echo   Options（Deploy-Scripts.ps1 に透過）:              1>&2
    echo     -Backup   上書き前に既存ファイルをバックアップ   1>&2
    echo     -WhatIf   Dry-run（実際の操作なし、ログのみ）    1>&2
    echo.                                 1>&2
    echo   Examples:                      1>&2
    echo     %~nx0 dev                    1>&2
    echo     %~nx0 production -Backup     1>&2
    echo     %~nx0 staging -WhatIf        1>&2
    exit /b 1
)

set "ENV_NAME=%~1"
shift

pwsh -ExecutionPolicy Bypass -File "%~dp0scripts\windows\powershell\Deploy-Scripts.ps1" -Env "%ENV_NAME%" %*

exit /b %ERRORLEVEL%
