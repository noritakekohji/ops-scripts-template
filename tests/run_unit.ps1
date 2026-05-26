#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell 単体テストランナー（Pester 5+ を使用）

.DESCRIPTION
    使い方（リポジトリ root から）:
        .\tests\run_unit.ps1                    # tests\pester\ 配下を全部実行
        .\tests\run_unit.ps1 -Path Logging      # ファイル名フィルタ
        .\tests\run_unit.ps1 -Coverage          # カバレッジ HTML を生成
                                                # (tests\results\coverage\powershell\index.html)

    前提:
        - PowerShell 5.1+
        - Pester 5+（未インストール時はインストール手順を案内）
        - -Coverage 時のみ ReportUnit や JaCoCo は不要（Pester が JaCoCo XML を出力）

    終了コード:
        0  全テスト合格
        1  1 件以上失敗
        10 Pester がインストールされていない
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [switch]$Coverage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot   = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..'))).Path
$testsDir   = Join-Path $repoRoot 'tests\pester'
$resultsDir = Join-Path $repoRoot 'tests\results'
$coverageDir = Join-Path $resultsDir 'coverage\powershell'

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [Version]'5.0.0' })) {
    Write-Host "[ERROR] Pester 5+ not found. Install with:" -ForegroundColor Red
    Write-Host "  Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force"
    exit 10
}
Import-Module Pester -MinimumVersion 5.0.0

# 対象ファイル
$targets = if ($Path) {
    Get-ChildItem -Path $testsDir -Recurse -Filter "*$Path*.Tests.ps1" | Select-Object -ExpandProperty FullName
} else {
    Get-ChildItem -Path $testsDir -Recurse -Filter '*.Tests.ps1' | Select-Object -ExpandProperty FullName
}

if (-not $targets) {
    Write-Warning "No *.Tests.ps1 files found under $testsDir"
    exit 0
}

Write-Host "==> Running $($targets.Count) Pester test file(s)"
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

$pesterConfig = [PesterConfiguration]::Default
$pesterConfig.Run.Path        = $targets
$pesterConfig.Run.PassThru    = $true
$pesterConfig.Output.Verbosity = 'Detailed'
$pesterConfig.TestResult.Enabled   = $true
$pesterConfig.TestResult.OutputPath = Join-Path $resultsDir 'pester-results.xml'

if ($Coverage) {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $coverageDir
    New-Item -ItemType Directory -Path $coverageDir -Force | Out-Null
    # 計測対象: scripts_windows と tools 配下の .ps1 / .psm1
    $covPaths = @(
        Join-Path $repoRoot 'scripts_windows\**\*.ps1'
        Join-Path $repoRoot 'scripts_windows\**\*.psm1'
        Join-Path $repoRoot 'tools\**\*.ps1'
    )
    $pesterConfig.CodeCoverage.Enabled    = $true
    $pesterConfig.CodeCoverage.Path       = $covPaths
    $pesterConfig.CodeCoverage.OutputPath = Join-Path $coverageDir 'coverage.xml'
    $pesterConfig.CodeCoverage.OutputFormat = 'JaCoCo'
}

$result = Invoke-Pester -Configuration $pesterConfig

if ($Coverage -and $result.CodeCoverage) {
    $pct = if ($result.CodeCoverage.CommandsAnalyzed -gt 0) {
        [math]::Round(100 * $result.CodeCoverage.CommandsExecuted / $result.CodeCoverage.CommandsAnalyzed, 1)
    } else { 0 }
    Write-Host ""
    Write-Host "Coverage: $($result.CodeCoverage.CommandsExecuted)/$($result.CodeCoverage.CommandsAnalyzed) commands = ${pct}%"
    Write-Host "  JaCoCo XML: $($pesterConfig.CodeCoverage.OutputPath.Value)"
    Write-Host "  (Convert to HTML with: reportgenerator -reports:coverage.xml -targetdir:html)"
}

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
