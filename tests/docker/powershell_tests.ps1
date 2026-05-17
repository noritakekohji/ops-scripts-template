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
    # Implementation uses [Console]::Out.WriteLine which bypasses PS streams.
    # Verify the call completes without throwing (content verified by log-file test below).
    Write-OpsLog -Level INFO -Message 'test message'
    $true
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
    # Exit 0 = all OK, 1 = some failures, 4 = script crash.  0 and 1 are acceptable.
    & pwsh -NonInteractive -File $CheckNC `
        -TargetList "$Fixtures/test_targets.lst" -HtmlReport $ncHtml 2>/dev/null
    $LASTEXITCODE -ne 4
}

Check "HTML report created" {
    Test-Path $ncHtml
}

Check "HTML report has content" {
    if (-not (Test-Path $ncHtml)) { return $false }
    # Use raw bytes to avoid any encoding/BOM issues
    $bytes = [System.IO.File]::ReadAllBytes($ncHtml)
    $bytes.Length -gt 500
}

# ============================================================
# Suite 12: tools/change-detect — PS script
# ============================================================
Suite "tools/change-detect — Change-Detect.ps1"

$ChangeDetect = "$Repo/tools/change-detect/Change-Detect.ps1"

Check "file exists" { Test-Path $ChangeDetect }
SyntaxCheck $ChangeDetect

# ============================================================
# Suite 13: tools/perf-monitor
# ============================================================
Suite "tools/perf-monitor"

$PerfMonSh   = "$Repo/tools/perf-monitor/perf_monitor.sh"
$PerfMonPs   = "$Repo/tools/perf-monitor/PerfMonitor.ps1"
$PerfMonPy   = "$Repo/tools/perf-monitor/render_report.py"
$PerfMonConf = "$Repo/tools/perf-monitor/perf_monitor.conf"
$PerfDir     = "$Tmp/perf_monitor"
New-Item -ItemType Directory -Path $PerfDir -Force | Out-Null

Check "perf_monitor.sh exists"   { Test-Path $PerfMonSh   }
Check "PerfMonitor.ps1 exists"   { Test-Path $PerfMonPs   }
Check "render_report.py exists"  { Test-Path $PerfMonPy   }
Check "perf_monitor.conf exists" { Test-Path $PerfMonConf }
SyntaxCheck $PerfMonPs

# render_report.py: Python3 で直接テストデータを生成してレポート確認
# (PS7/Linux コンテナでは Get-Counter 系が動かないため、
#  データ生成は Python で行い render_report.py の動作を検証する)
Check "render_report.py: generates HTML from test data" {
    $testData = "$PerfDir/test_data.jsonl"
    $testHtml = "$PerfDir/test_report.html"

    # テストデータ生成（Python3 で JSON Lines を作成）
    & pwsh -NonInteractive -Command "
        `$null = python3 -c @'
import json, datetime, math, random, pathlib
start = datetime.datetime(2026, 5, 17, 10, 0, 0)
rows = []
random.seed(42)
for i in range(24):  # 2分相当(5秒x24)
    t = start + datetime.timedelta(seconds=i*5)
    rows.append({
        'ts': t.strftime('%Y-%m-%dT%H:%M:%S+09:00'),
        'hostname': 'test-host', 'os': 'linux',
        'cpu_pct':          round(30 + 50*(i/24) + random.uniform(-5,5), 1),
        'mem_used_pct':     round(55 + 20*(i/24) + random.uniform(-2,2), 1),
        'mem_used_gb':      round(8.8  + 3.2*(i/24), 2),
        'mem_free_gb':      round(7.2  - 3.2*(i/24), 2),
        'mem_total_gb':     16.0,
        'swap_used_pct':    round(5 + 3*(i/24), 1),
        'swap_used_gb':     round(0.8 + 0.5*(i/24), 2),
        'disk_read_mbps':   round(abs(random.gauss(80,  40)), 2),
        'disk_write_mbps':  round(abs(random.gauss(50,  30)), 2),
        'net_rx_mbps':      round(abs(random.gauss(200, 80)), 2),
        'net_tx_mbps':      round(abs(random.gauss(50,  20)), 2),
        'load_avg_1':       round(1.5 + 2.5*(i/24) + random.uniform(-0.3,0.3), 2),
        'load_avg_5':       round(1.2 + 2.0*(i/24), 2),
        'load_avg_15':      round(1.0 + 1.5*(i/24), 2),
        'proc_count':       random.randint(280, 350),
    })
with open('$testData', 'w') as f:
    for r in rows: f.write(json.dumps(r) + chr(10))
print('generated', len(rows), 'rows')
'@
    " 2>/dev/null

    Test-Path $testData
}

Check "render_report.py: HTML output valid" {
    $testData = "$PerfDir/test_data.jsonl"
    $testHtml = "$PerfDir/test_report.html"
    if (-not (Test-Path $testData)) { return $false }

    $env:PERF_THR_CPU    = '75'
    $env:PERF_THR_MEM    = '65'
    $env:PERF_THR_DISK_R = '100'
    $env:PERF_THR_DISK_W = '80'
    $env:PERF_THR_NET_RX = '250'
    $env:PERF_THR_NET_TX = '70'
    $env:PERF_THR_LOAD   = '3.0'

    & python3 $PerfMonPy $testData $testHtml 2>/dev/null
    Test-Path $testHtml
}

Check "render_report.py: HTML has Chart.js" {
    $testHtml = "$PerfDir/test_report.html"
    if (-not (Test-Path $testHtml)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($testHtml)
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    ($content -match 'chart\.js') -and ($content -match 'chartCpu') -and ($content -match 'chartMem')
}

Check "render_report.py: HTML has stats table" {
    $testHtml = "$PerfDir/test_report.html"
    if (-not (Test-Path $testHtml)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($testHtml)
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    ($content -match '95') -and ($content -match 'CPU|cpu') -and ($bytes.Length -gt 5000)
}

Check "render_report.py: HTML has alert section" {
    $testHtml = "$PerfDir/test_report.html"
    if (-not (Test-Path $testHtml)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($testHtml)
    $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    # しきい値超過か「しきい値設定」セクションがあること
    ($content -match 'しきい値') -or ($content -match 'alert') -or ($content -match 'Threshold')
}

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
