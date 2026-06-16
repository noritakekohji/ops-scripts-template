@echo off
setlocal

:: Launch CollectSnapshot.ps1 in interactive (TUI) menu mode.
:: Double-clicking this bat opens the TUI menu.
:: To run unattended (CUI), call CollectSnapshot.ps1 directly.

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%CollectSnapshot.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Menu %*

exit /b %ERRORLEVEL%
