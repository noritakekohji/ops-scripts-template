#Requires -Version 5.1
<#
.SYNOPSIS
    PowerShell 側を全て実行（単体 + 結合）

.DESCRIPTION
    使い方（リポジトリ root から）:
        .\tests\run_all.ps1                 # unit + integration
        .\tests\run_all.ps1 -UnitOnly
        .\tests\run_all.ps1 -IntegrationOnly
        .\tests\run_all.ps1 -Coverage       # 単体テストのカバレッジを生成
#>
[CmdletBinding()]
param(
    [switch]$UnitOnly,
    [switch]$IntegrationOnly,
    [switch]$Coverage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..'))).Path

$failures = 0
$runUnit        = -not $IntegrationOnly
$runIntegration = -not $UnitOnly

if ($runUnit) {
    Write-Host "========================================================"
    Write-Host "  UNIT TESTS (Pester)"
    Write-Host "========================================================"
    & (Join-Path $PSScriptRoot 'run_unit.ps1') -Coverage:$Coverage
    if ($LASTEXITCODE -ne 0) { $failures++ }
}

if ($runIntegration) {
    Write-Host ""
    Write-Host "========================================================"
    Write-Host "  INTEGRATION TESTS (Pester)"
    Write-Host "========================================================"
    $integDir = Join-Path $repoRoot 'tests\integration'
    if (Test-Path $integDir) {
        $files = Get-ChildItem -Path $integDir -Recurse -Filter '*.Tests.ps1' | Select-Object -ExpandProperty FullName
        if ($files) {
            Import-Module Pester -MinimumVersion 5.0.0
            $cfg = [PesterConfiguration]::Default
            $cfg.Run.Path = $files
            $cfg.Output.Verbosity = 'Detailed'
            $cfg.Run.PassThru = $true
            $r = Invoke-Pester -Configuration $cfg
            if ($r.FailedCount -gt 0) { $failures++ }
        } else {
            Write-Host "(no .Tests.ps1 under tests\integration)"
        }
    } else {
        Write-Host "(tests\integration\ does not exist; skip)"
    }
}

if ($failures -gt 0) {
    Write-Host ""
    Write-Host "FAILED: $failures suite(s) had failures" -ForegroundColor Red
    exit 1
}
Write-Host ""
Write-Host "ALL TESTS PASSED" -ForegroundColor Green
exit 0
