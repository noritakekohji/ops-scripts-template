@echo off
:: ============================================================================
:: port_inventory.bat  -  Listening Port Inventory launcher (Windows)
::   Thin wrapper around PortInventory.ps1.
::
:: Usage:
::   port_inventory.bat [-ExpectedList <file>] [-HtmlReport <file>]
::                      [-Json] [-FailOnly]
::   port_inventory.bat -FromJson <saved.json> [-HtmlReport file] [-Json] [-FailOnly]
::
:: Examples:
::   port_inventory.bat
::   port_inventory.bat -ExpectedList expected_ports.lst
::   port_inventory.bat -ExpectedList expected_ports.lst -HtmlReport report.html
::   port_inventory.bat -Json
::
:: Requirements: PowerShell 5.1+
:: Exit codes  : forwarded from PortInventory.ps1
::   0  = All OK or no evaluation (inventory only)
::   1  = NG found
::   2  = Expected list file not found
:: ============================================================================
setlocal

:: ---------------------------------------------------------------------------
:: Resolve PortInventory.ps1 path
:: ---------------------------------------------------------------------------
set "PS1=%~dp0PortInventory.ps1"
if not exist "%PS1%" (
    echo [ERROR] PortInventory.ps1 not found: %PS1%
    exit /b 10
)

:: ---------------------------------------------------------------------------
:: Forward all arguments to PowerShell
:: ---------------------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %ERRORLEVEL%
