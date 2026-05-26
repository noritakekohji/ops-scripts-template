#Requires -Version 5.1
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

# RUN_COVERAGE=true でカバレッジを生成（JaCoCo XML）。
# 一次ソース: scripts_windows と tools 配下の .ps1 / .psm1。
if ($env:RUN_COVERAGE -eq 'true') {
    $repoRoot = (Resolve-Path '.').Path
    $covPaths = @(
        Join-Path $repoRoot 'scripts_windows\**\*.ps1'
        Join-Path $repoRoot 'scripts_windows\**\*.psm1'
        Join-Path $repoRoot 'tools\**\*.ps1'
    )
    $covDir = Join-Path 'tests' 'results\coverage\powershell'
    New-Item -ItemType Directory -Path $covDir -Force | Out-Null
    $config.CodeCoverage.Enabled      = $true
    $config.CodeCoverage.Path         = $covPaths
    $config.CodeCoverage.OutputPath   = Join-Path $covDir 'coverage.xml'
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
}

Invoke-Pester -Configuration $config
