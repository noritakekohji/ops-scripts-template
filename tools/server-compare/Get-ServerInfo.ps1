#Requires -Version 5.1
# DEPRECATED: Use tools/server-snapshot/ServerSnapshot.ps1 collect
# This script delegates to server-snapshot and will be removed in a future version.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$target = Join-Path (Split-Path $PSScriptRoot) 'server-snapshot\ServerSnapshot.ps1'
if (-not (Test-Path $target)) {
    Write-Error "[ERROR] ServerSnapshot.ps1 not found at: $target. Deploy server-snapshot alongside this tool."
    exit 10
}
Write-Warning "[DEPRECATED] Get-ServerInfo.ps1 is deprecated. Use: ServerSnapshot.ps1 collect"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target collect @args
exit $LASTEXITCODE
