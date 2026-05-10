@echo off
:: ============================================================================
:: install.bat
::   Deploy-Scripts.ps1 を呼び出す薄いラッパ。
::   リポジトリルートから実行し、第 1 引数に環境名を渡す。
::
:: Usage:
::   install.bat [<env>] [Deploy-Scripts.ps1 のオプション...]
::
:: Examples:
::   install.bat                    rem default 環境に配備
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

:: env を指定しない場合は "default" を使う
if "%~1"=="" (
    set "ENV_NAME=default"
) else (
    :: 最初の引数を確認（"-" で始まる場合はオプション、そうでない場合は env）
    if "%~1:~0,1%"=="-" (
        set "ENV_NAME=default"
    ) else (
        set "ENV_NAME=%~1"
        shift
    )
)

:: ----------------------------------------------------------------------------
:: PowerShell 7 (pwsh) を検索
::   1. PATH に pwsh があればそれを使う
::   2. 既定のインストール先を順に確認する
::   3. 見つからなければエラー（PS 5.1 の powershell.exe は #Requires -Version 7 で弾かれるため不使用）
:: ----------------------------------------------------------------------------
set "PWSH="

where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PWSH=pwsh"
    goto :run
)

if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
    goto :run
)

:: バージョン番号付きディレクトリ（例: 7.4.6）を探す
for /d %%d in ("%ProgramFiles%\PowerShell\7.*") do (
    if exist "%%d\pwsh.exe" (
        set "PWSH=%%d\pwsh.exe"
        goto :run
    )
)

echo [ERROR] PowerShell 7 が見つかりません。以下からインストールしてください: 1>&2
echo         https://github.com/PowerShell/PowerShell/releases 1>&2
exit /b 1

:run
"%PWSH%" -ExecutionPolicy Bypass -File "%~dp0scripts\windows\powershell\Deploy-Scripts.ps1" -Env "%ENV_NAME%" %*

exit /b %ERRORLEVEL%
