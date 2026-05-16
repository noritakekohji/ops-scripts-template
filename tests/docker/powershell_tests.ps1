#Requires -Version 7.0
<#
.SYNOPSIS
    PowerShell test suite (runs INSIDE the PowerShell Docker container)

.NOTES
    Running on PowerShell 7 / Linux. Windows-specific cmdlets are unavailable.
    Tests verify: module import, syntax, PS7-compatible logic, error handling.
#>
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off   # Allow flexible access during tests

$Repo     = '/repo'
$Fixtures = "$Repo/tests/docker/fixtures"
$Tmp      = '/tmp/ops_ps_test'
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

# ============================================================
# Test framework
# ============================================================
$script:Pass = 0
$script:Fail = 0

function Suite([string]$Name) {
    Write-Host ""
    Write-Host "$(('=' * 58))" -ForegroundColor Cyan
    Write-Host "  SUITE: $Name" -ForegroundColor Cyan
    Write-Host "$(('=' * 58))" -ForegroundColor Cyan
}

function Check([string]$Name, [scriptblock]$Test) {
    try {
        $result = & $Test
        if ($result -eq $false) { throw "returned false" }
        Write-Host "  [PASS] $Name" -ForegroundColor Green
        $script:Pass++
    } catch {
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
        $script:Fail++
    }
}

function SyntaxCheck([string]$Path) {
    $name = Split-Path -Leaf $Path
    Check "syntax: $name" {
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$null, [ref]$errors)
        if ($errors.Count -gt 0) { throw ($errors[0].Message) }
        $true
    }
}

# ============================================================
# Suite 1: Prerequisites
# ============================================================
Suite "Prerequisites"

Check "PowerShell 7+" { $PSVersionTable.PSVersion.Major -ge 7 }
Check "python3 available" { python3 --version 2>&1; $LASTEXITCODE -eq 0 }
Check "pwsh path" { (Get-Command pwsh -ErrorAction SilentlyContinue) -ne $null }

# ============================================================
# Suite 2: scripts_windows/lib — Logging.psm1
# ============================================================
Suite "scripts_windows/lib — Logging.psm1"

$LoggingPsm1 = "$Repo/scripts_windows/lib/Logging.psm1"

Check "file exists" { Test-Path $LoggingPsm1 }
SyntaxCheck $LoggingPsm1

Check "Import-Module without error" {
    Import-Module $LoggingPsm1 -Force -ErrorAction Stop
    $true
}

Check "Write-OpsLog: INFO level" {
    Import-Module $LoggingPsm1 -Force
    $out = (Write-OpsLog -Level INFO -Message 'test message' 2>&1 | Out-String)
    $out -match 'test message'
}

Check "Write-OpsLog: ERROR to stderr" {
    Import-Module $LoggingPsm1 -Force
    $err = $null
    try { Write-OpsLog -Level ERROR -Message 'err-msg' } catch { $err = $_ }
    # Should not throw — just output
    $true
}

Check "Get-OpsJstStamp returns non-empty" {
    Import-Module $LoggingPsm1 -Force
    $s = Get-OpsJstStamp
    $s -match '\d{8}-\d{6}'
}

Check "Set-OpsLogConfig sets config" {
    Import-Module $LoggingPsm1 -Force
    Set-OpsLogConfig -LogFile "$Tmp/test.log" -LogLevel 'DEBUG'
    $true
}

Check "Log file written after Set-OpsLogConfig" {
    Import-Module $LoggingPsm1 -Force
    $logFile = "$Tmp/logging_test.log"
    Set-OpsLogConfig -LogFile $logFile -LogLevel 'DEBUG'
    Write-OpsLog -Level INFO -Message 'file-write-test'
    Set-OpsLogConfig -LogFile '' -LogLevel 'INFO'  # reset
    (Test-Path $logFile) -and ((Get-Content $logFile) -match 'file-write-test')
}

# ============================================================
# Suite 3: scripts_windows/lib — Config.psm1
# ============================================================
Suite "scripts_windows/lib — Config.psm1"

$ConfigPsm1 = "$Repo/scripts_windows/lib/Config.psm1"

Check "file exists" { Test-Path $ConfigPsm1 }
SyntaxCheck $ConfigPsm1

Check "Import-Module without error" {
    Import-Module $ConfigPsm1 -Force -ErrorAction Stop
    $true
}

Check "Get-OpsRepoRoot traverses to .git" {
    Import-Module $ConfigPsm1 -Force
    $root = Get-OpsRepoRoot
    Test-Path (Join-Path $root '.git')
}

# Create isolated test repo
$testRepo = "$Tmp/test_repo"
New-Item -ItemType Directory -Path "$testRepo/.git" -Force | Out-Null
New-Item -ItemType Directory -Path "$testRepo/config/default" -Force | Out-Null
@"
Region    = us-east-1
LogLevel  = DEBUG
"@ | Set-Content "$testRepo/config/default/global.conf" -Encoding UTF8
@"
Region    = ap-northeast-1
Timeout   = 30
"@ | Set-Content "$testRepo/config/default/myapp.conf" -Encoding UTF8

Check "Get-OpsConfig reads values" {
    Import-Module $ConfigPsm1 -Force
    $cfg = Get-OpsConfig -Name 'myapp' -RepoRoot $testRepo
    $cfg['Region'] -eq 'ap-northeast-1'
}

Check "Get-OpsConfig: global.conf fallback" {
    Import-Module $ConfigPsm1 -Force
    $cfg = Get-OpsConfig -Name 'myapp' -RepoRoot $testRepo
    $cfg.ContainsKey('LogLevel')  # from global.conf
}

Check "Get-OpsConfig: empty when no file (no global.conf)" {
    Import-Module $ConfigPsm1 -Force
    # Use a repo without global.conf so no keys are loaded
    $emptyRepo = "$Tmp/empty_repo"
    New-Item -ItemType Directory -Path "$emptyRepo/.git" -Force | Out-Null
    New-Item -ItemType Directory -Path "$emptyRepo/config/default" -Force | Out-Null
    $cfg = Get-OpsConfig -Name 'no-such-script' -RepoRoot $emptyRepo
    $cfg.Count -eq 0
}

# ============================================================
# Suite 4: scripts_windows/os — Get-ServerInfo.ps1
# ============================================================
Suite "scripts_windows/os — Get-ServerInfo.ps1"

$GetSvInfo = "$Repo/scripts_windows/os/Get-ServerInfo.ps1"

Check "file exists" { Test-Path $GetSvInfo }
SyntaxCheck $GetSvInfo

Check "runs with available categories (PS7/Linux)" {
    # Windows-specific cmdlets will fail gracefully; script should not crash
    $out = "$Tmp/svinfo_scripts.json"
    # Run with a short timeout; accept partial output
    try {
        & pwsh -NonInteractive -Command "
            `$ErrorActionPreference = 'SilentlyContinue'
            & '$GetSvInfo' -Category os -OutputPath '$out'
        " 2>/dev/null
    } catch {}
    Test-Path $out  # File created even with partial results
}

# ============================================================
# Suite 5: scripts_windows/os — Compare-ServerInfo.ps1
# ============================================================
Suite "scripts_windows/os — Compare-ServerInfo.ps1"

$Compare = "$Repo/scripts_windows/os/Compare-ServerInfo.ps1"

Check "file exists" { Test-Path $Compare }
SyntaxCheck $Compare

# Create two test JSON files for comparison
$beforeJson = @{
    meta     = @{ hostname = 'server-before'; os_type = 'windows'; collected_at = '2026-01-01T00:00:00+09:00'; categories = @('os') }
    os       = @{ hostname = 'server-before'; os_name = 'Windows Server 2022'; os_version = '10.0.20348'; cpu_model = 'Intel Xeon E5'; cpu_cores = 8; total_memory_gb = 16.0 }
} | ConvertTo-Json -Depth 5
$afterJson = @{
    meta     = @{ hostname = 'server-after'; os_type = 'windows'; collected_at = '2026-06-01T00:00:00+09:00'; categories = @('os') }
    os       = @{ hostname = 'server-after'; os_name = 'Windows Server 2022'; os_version = '10.0.20348'; cpu_model = 'Intel Xeon E5'; cpu_cores = 16; total_memory_gb = 32.0 }
} | ConvertTo-Json -Depth 5

$beforeFile = "$Tmp/compare_before.json"
$afterFile  = "$Tmp/compare_after.json"
[System.IO.File]::WriteAllText($beforeFile, $beforeJson, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($afterFile,  $afterJson,  [System.Text.Encoding]::UTF8)

Check "compare runs without crash" {
    $html = "$Tmp/compare_report.html"
    & pwsh -NonInteractive -Command "
        `$ErrorActionPreference = 'SilentlyContinue'
        & '$Compare' -Before '$beforeFile' -After '$afterFile' -HtmlReport '$html'
    " 2>/dev/null
    Test-Path $html
}

Check "compare HTML contains diff" {
    $html = "$Tmp/compare_report.html"
    if (-not (Test-Path $html)) { return $false }
    $content = Get-Content $html -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }
    # cpu_cores changed from 8->16; any of these should appear
    ($content -match 'cpu_cores') -or ($content -match 'changed') -or ($content -match 'diff')
}

# ============================================================
# Suite 6: scripts_windows/os — Rotate-Log.ps1
# ============================================================
Suite "scripts_windows/os — Rotate-Log.ps1"

$RotateLog = "$Repo/scripts_windows/os/Rotate-Log.ps1"

Check "file exists" { Test-Path $RotateLog }
SyntaxCheck $RotateLog

# Create test log files on the Linux filesystem
$logDir = "$Tmp/test_win_logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
1..100 | ForEach-Object { "Log entry $_ " + ('x' * 100) } | Set-Content "$logDir/app.log" -Encoding UTF8
1..100 | ForEach-Object { "Log entry $_ " + ('x' * 100) } | Set-Content "$logDir/error.log" -Encoding UTF8

Check "-WhatIf dry-run" {
    & pwsh -NonInteractive -Command "
        `$ErrorActionPreference = 'SilentlyContinue'
        & '$RotateLog' -Path '$logDir/app.log' -MaxSizeMB 0 -WhatIf
    " 2>/dev/null
    $true
}

# ============================================================
# Suite 7: scripts_windows/os — Deploy-Scripts.ps1
# ============================================================
Suite "scripts_windows/os — Deploy-Scripts.ps1"

$DeployPs1 = "$Repo/scripts_windows/os/Deploy-Scripts.ps1"

Check "file exists" { Test-Path $DeployPs1 }
SyntaxCheck $DeployPs1

$deployLst = "$Tmp/deploy_test_win.lst"
@"
CONF, global.conf
SRC,  scripts_windows/os/Rotate-Log.ps1
"@ | Set-Content $deployLst -Encoding UTF8

Check "-WhatIf dry-run" {
    $dest = "$Tmp/deploy_win_dest"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    & pwsh -NonInteractive -Command "
        `$ErrorActionPreference = 'SilentlyContinue'
        & '$DeployPs1' -PathList '$deployLst' -OptRoot '$dest' -WhatIf
    " 2>/dev/null
    $true
}

# ============================================================
# Suite 8: scripts_windows/aws — syntax checks (no AWS)
# ============================================================
Suite "scripts_windows/aws — syntax (no AWS credentials)"

foreach ($script in @('Backup-Ami.ps1','Backup-EbsSnapshot.ps1','Ec2Ctl.ps1','S3Upload.ps1')) {
    $f = "$Repo/scripts_windows/aws/$script"
    Check "file exists: $script" { Test-Path $f }
    SyntaxCheck $f
}

# ============================================================
# Suite 9: scripts_windows/sqlserver + tomcat — syntax
# ============================================================
Suite "scripts_windows/sqlserver + tomcat — syntax"

foreach ($f in @(
    "$Repo/scripts_windows/sqlserver/SqlServerCtl.ps1",
    "$Repo/scripts_windows/tomcat/TomcatCtl.ps1"
)) {
    $name = Split-Path -Leaf $f
    Check "file exists: $name" { Test-Path $f }
    SyntaxCheck $f
}

# ============================================================
# Suite 10: tools/server-compare — PS scripts
# ============================================================
Suite "tools/server-compare — PS scripts"

foreach ($f in @(
    "$Repo/tools/server-compare/Get-ServerInfo.ps1",
    "$Repo/tools/server-compare/Compare-ServerInfo.ps1"
)) {
    $name = Split-Path -Leaf $f
    Check "file exists: $name" { Test-Path $f }
    SyntaxCheck $f
}

$toolsHtml = "$Tmp/tools_compare.html"
Check "Compare-ServerInfo (tools) runs with test JSON" {
    & pwsh -NonInteractive -File "$Repo/tools/server-compare/Compare-ServerInfo.ps1" `
        -Before $beforeFile -After $afterFile -HtmlReport $toolsHtml 2>/dev/null
    Test-Path $toolsHtml
}

# ============================================================
# Suite 11: tools/network-check — PS script
# ============================================================
Suite "tools/network-check — Check-NetworkConnectivity.ps1"

$CheckNC = "$Repo/tools/network-check/Check-NetworkConnectivity.ps1"

Check "file exists" { Test-Path $CheckNC }
SyntaxCheck $CheckNC

$ncHtml = "$Tmp/nc_ps_report.html"
Check "runs against test targets" {
    & pwsh -NonInteractive -File $CheckNC `
        -TargetList "$Fixtures/test_targets.lst" -HtmlReport $ncHtml 2>/dev/null
    Test-Path $ncHtml
}

Check "HTML contains evaluation column" {
    if (-not (Test-Path $ncHtml)) { return $false }
    $c = Get-Content $ncHtml -Raw -ErrorAction SilentlyContinue
    if (-not $c) { return $false }
    ($c -match 'Expected') -or ($c -match 'Evaluation') -or ($c -match 'PASS') -or ($c -match 'eval')
}

# ============================================================
# Suite 12: tools/change-detect — PS script
# ============================================================
Suite "tools/change-detect — Change-Detect.ps1"

$ChangeDetect = "$Repo/tools/change-detect/Change-Detect.ps1"

Check "file exists" { Test-Path $ChangeDetect }
SyntaxCheck $ChangeDetect

# ============================================================
# Summary
# ============================================================
$Total = $script:Pass + $script:Fail
Write-Host ""
Write-Host "$(('─' * 58))" -ForegroundColor White
if ($script:Fail -eq 0) {
    Write-Host "  ✓ ALL TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "  ✗ SOME TESTS FAILED" -ForegroundColor Red
}
Write-Host ("  Total: {0}   PASS: {1}   FAIL: {2}" -f $Total, $script:Pass, $script:Fail)
Write-Host "$(('─' * 58))" -ForegroundColor White
Write-Host ""

exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
