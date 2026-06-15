#Requires -Version 5.1
# DEPRECATED: Use tools/server-snapshot/ServerSnapshot.ps1 compare
[CmdletBinding()]
param(
    [string]$Before,
    [string]$After,
    [string]$HtmlReport,
    [string[]]$Category,
    [switch]$DiffOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$target = Join-Path (Split-Path $PSScriptRoot) 'server-snapshot\ServerSnapshot.ps1'
if (-not (Test-Path $target)) {
    Write-Error "[ERROR] ServerSnapshot.ps1 not found at: $target. Deploy server-snapshot alongside this tool."
    exit 10
}
Write-Warning "[DEPRECATED] Compare-ServerInfo.ps1 is deprecated. Use: ServerSnapshot.ps1 compare"

$forward = @('compare')
if ($Before)     { $forward += @('-BeforePath', $Before) }
if ($After)      { $forward += @('-AfterPath',  $After) }
if ($HtmlReport) { $forward += @('-HtmlReport', $HtmlReport) }
if ($Category)   { $forward += @('-Category'); $forward += $Category }
if ($DiffOnly)   { $forward += '-DiffOnly' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target @forward
exit $LASTEXITCODE
