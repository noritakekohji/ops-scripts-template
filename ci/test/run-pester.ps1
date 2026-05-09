#Requires -Version 7
[CmdletBinding()]
param(
    [string]$TestPath = 'tests/pester',
    [string]$ResultFile = 'pester-results.xml'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $TestPath)) {
    Write-Host "No Pester tests found at '$TestPath'. Skipping."
    exit 0
}

$needed = [version]'5.5.0'
$installed = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge $needed }
if (-not $installed) {
    Install-Module Pester -MinimumVersion $needed -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion $needed

$config = New-PesterConfiguration
$config.Run.Path = $TestPath
$config.Run.Exit = $true
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = $ResultFile
$config.TestResult.OutputFormat = 'JUnitXml'
$config.Output.Verbosity = 'Detailed'

Invoke-Pester -Configuration $config
