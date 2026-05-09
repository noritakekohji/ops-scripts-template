#Requires -Version 7
<#
.SYNOPSIS
    <一行サマリ：このスクリプトが何をするか>

.DESCRIPTION
    <詳細説明：前提条件、副作用、認証要件、想定実行環境>

.PARAMETER ParamName
    <パラメータの意味と制約>

.EXAMPLE
    .\Template-Script.ps1 -ParamName value
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$ParamName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- import shared logging --------------------------------------------------
# TEMPLATE: adjust the number of '..' segments based on script depth.
#   scripts/aws/windows/ami/Foo.ps1   -> 4 ups
#   scripts/windows/log/Bar.ps1       -> 3 ups
#   scripts/common/notify/Baz.ps1     -> 3 ups
$libPath = Join-Path $PSScriptRoot '..' '..' '..' '..' 'lib' 'powershell' 'Logging.psm1'
if (-not (Test-Path $libPath)) {
    throw "Logging module not found at $libPath"
}
Import-Module (Resolve-Path $libPath).Path -Force

# --- main -------------------------------------------------------------------
Write-OpsLog -Level INFO -Message "Script start: paramName=$ParamName"

try {
    if ($PSCmdlet.ShouldProcess($ParamName, 'Describe the action here')) {
        # TODO: replace with the real implementation
        Write-OpsLog -Level INFO -Message "Doing work: paramName=$ParamName"
    }
}
catch {
    Write-OpsLog -Level ERROR -Message "Operation failed: paramName=$ParamName error=$($_.Exception.Message)"
    exit 4
}

Write-OpsLog -Level INFO -Message "Script complete: paramName=$ParamName"
exit 0
