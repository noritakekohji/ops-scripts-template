#Requires -Version 5.1
# DEPRECATED: Use tools/server-snapshot/ServerSnapshot.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('before','after','compare')]
    [string]$Mode
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$target = Join-Path (Split-Path $PSScriptRoot) 'server-snapshot\ServerSnapshot.ps1'
if (-not (Test-Path $target)) {
    Write-Error "[ERROR] ServerSnapshot.ps1 not found at: $target. Deploy server-snapshot alongside this tool."
    exit 10
}
Write-Warning "[DEPRECATED] Change-Detect.ps1 is deprecated. Use: ServerSnapshot.ps1 $Mode"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target $Mode @args
exit $LASTEXITCODE
