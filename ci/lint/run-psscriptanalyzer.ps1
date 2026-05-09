#Requires -Version 7
[CmdletBinding()]
param(
    [string]$Path = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')),
    [string]$ReportFile = 'psscriptanalyzer-report.json'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AcceptLicense
}
Import-Module PSScriptAnalyzer

$results = Invoke-ScriptAnalyzer -Path $Path -Recurse -Severity @('Error', 'Warning')

if ($null -eq $results) { $results = @() }

$results | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportFile -Encoding utf8

$errors = @($results | Where-Object Severity -eq 'Error')
$warnings = @($results | Where-Object Severity -eq 'Warning')

Write-Host "PSScriptAnalyzer: errors=$($errors.Count) warnings=$($warnings.Count)"
if ($results.Count -gt 0) {
    $results | Format-Table RuleName, Severity, ScriptName, Line, Message -AutoSize
}

if ($errors.Count -gt 0) { exit 1 }
exit 0
