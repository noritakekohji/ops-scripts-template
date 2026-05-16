#Requires -Version 5.1
<#
.SYNOPSIS
    Windows パフォーマンスモニター: 負荷テスト中のリソースを定期収集してレポート生成。
.DESCRIPTION
    負荷テスト中の CPU/メモリ/ディスク/ネットワーク等を定期的に収集し
    JSON Lines 形式のデータファイルに保存する。
    停止後に render_report.py でHTMLレポートを生成できる。

    使い方:
      PerfMonitor.ps1 start  [-Config path] [-Interval 秒] [-Duration 秒] [-OutputDir dir] [-Prefix name]
      PerfMonitor.ps1 stop   [session_dir]
      PerfMonitor.ps1 report <session_dir> [-Config path]
      PerfMonitor.ps1 status [session_dir]
      PerfMonitor.ps1 list

.EXAMPLE
    .\PerfMonitor.ps1 start -Interval 5 -Duration 1800
    .\PerfMonitor.ps1 stop
    .\PerfMonitor.ps1 report .\perf_20260517-100000
    .\PerfMonitor.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start','stop','report','status','list')]
    [string]$Command = 'status',

    [string]$Config    = '',
    [int]   $Interval  = 0,
    [int]   $Duration  = -1,
    [string]$OutputDir = '',
    [string]$Prefix    = '',
    [string]$SessionDir = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
$DefaultConf = Join-Path $ScriptDir 'perf_monitor.conf'
$RenderPy    = Join-Path $ScriptDir 'render_report.py'

# ── ログヘルパー ─────────────────────────────────────────────
function Write-Log([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] [$Level] $Msg"
}
function Log-Info([string]$m)  { Write-Log 'INFO ' $m }
function Log-Warn([string]$m)  { Write-Log 'WARN ' $m }
function Log-Error([string]$m) { Write-Log 'ERROR' $m }

# ── 設定読み込み ─────────────────────────────────────────────
$CFG = [ordered]@{
    Interval              = 5
    Duration              = 0
    OutputDir             = '.'
    OutputPrefix          = 'perf'
    Metrics               = 'all'
    ThresholdCpuPct       = 80.0
    ThresholdMemPct       = 85.0
    ThresholdDiskReadMBps = 500.0
    ThresholdDiskWriteMBps= 500.0
    ThresholdNetRxMbps    = 900.0
    ThresholdNetTxMbps    = 900.0
    ThresholdLoadAvg1     = 4.0
    LogFile               = ''
    LogLevel              = 'INFO'
}

function Load-Conf([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = ($_ -replace '#.*$', '').Trim()
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            if ($CFG.Contains($k)) { $CFG[$k] = $v }
        }
    }
}

# ── メトリクス収集（1サンプル）────────────────────────────────
function Collect-Sample {
    $ts  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $hn  = $env:COMPUTERNAME
    $os  = 'windows'
    $met = $CFG['Metrics']

    # CPU
    $cpu_pct = $null
    if ($met -eq 'all' -or $met -match 'cpu') {
        try {
            $c = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop)
            $cpu_pct = [math]::Round($c.CounterSamples[0].CookedValue, 1)
        } catch { $cpu_pct = $null }
    }

    # メモリ
    $mem_used_pct = $null; $mem_used_gb = $null
    $mem_free_gb  = $null; $mem_total_gb = $null
    $swap_used_pct = $null; $swap_used_gb = $null
    if ($met -eq 'all' -or $met -match 'mem') {
        try {
            $os_info = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $total  = [math]::Round($os_info.TotalVisibleMemorySize / 1MB, 2)
            $free   = [math]::Round($os_info.FreePhysicalMemory / 1MB, 2)
            $used   = [math]::Round($total - $free, 2)
            $mem_total_gb  = $total
            $mem_free_gb   = $free
            $mem_used_gb   = $used
            $mem_used_pct  = if ($total -gt 0) { [math]::Round(100 * $used / $total, 1) } else { $null }
            # ページファイル（スワップ相当）
            $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
            if ($pf) {
                $pf_alloc = ($pf | Measure-Object -Property AllocatedBaseSize -Sum).Sum
                $pf_curr  = ($pf | Measure-Object -Property CurrentUsage      -Sum).Sum
                if ($pf_alloc -gt 0) {
                    $swap_used_gb  = [math]::Round($pf_curr / 1KB, 2)
                    $swap_used_pct = [math]::Round(100 * $pf_curr / $pf_alloc, 1)
                } else {
                    $swap_used_gb = 0; $swap_used_pct = 0
                }
            }
        } catch {}
    }

    # ディスク I/O
    $disk_read_mbps = $null; $disk_write_mbps = $null
    if ($met -eq 'all' -or $met -match 'disk') {
        try {
            $dr = Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec'  -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $dw = Get-Counter '\PhysicalDisk(_Total)\Disk Write Bytes/sec' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $disk_read_mbps  = [math]::Round($dr.CounterSamples[0].CookedValue / 1MB, 2)
            $disk_write_mbps = [math]::Round($dw.CounterSamples[0].CookedValue / 1MB, 2)
        } catch {}
    }

    # ネットワーク
    $net_rx_mbps = $null; $net_tx_mbps = $null
    if ($met -eq 'all' -or $met -match 'net') {
        try {
            $rx = Get-Counter '\Network Interface(*)\Bytes Received/sec' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $tx = Get-Counter '\Network Interface(*)\Bytes Sent/sec'     -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
            $rx_total = ($rx.CounterSamples | Where-Object { $_.InstanceName -notmatch 'loopback|isatap' } |
                         Measure-Object CookedValue -Sum).Sum
            $tx_total = ($tx.CounterSamples | Where-Object { $_.InstanceName -notmatch 'loopback|isatap' } |
                         Measure-Object CookedValue -Sum).Sum
            $net_rx_mbps = [math]::Round($rx_total * 8 / 1MB, 2)
            $net_tx_mbps = [math]::Round($tx_total * 8 / 1MB, 2)
        } catch {}
    }

    # プロセス数 / ページファイル使用率
    $proc_count = $null
    if ($met -eq 'all' -or $met -match 'proc') {
        try {
            $pc = Get-Counter '\System\Processes' -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
            if ($pc) { $proc_count = [int]$pc.CounterSamples[0].CookedValue }
        } catch {}
    }

    # JSON オブジェクト生成
    $null_json = 'null'
    function Fmt($v) { if ($null -eq $v) { 'null' } else { "$v" } }

    $json = [ordered]@{
        ts             = $ts
        hostname       = $hn
        os             = $os
        cpu_pct        = $cpu_pct
        mem_used_pct   = $mem_used_pct
        mem_used_gb    = $mem_used_gb
        mem_free_gb    = $mem_free_gb
        mem_total_gb   = $mem_total_gb
        swap_used_pct  = $swap_used_pct
        swap_used_gb   = $swap_used_gb
        disk_read_mbps = $disk_read_mbps
        disk_write_mbps= $disk_write_mbps
        net_rx_mbps    = $net_rx_mbps
        net_tx_mbps    = $net_tx_mbps
        load_avg_1     = $null    # Windows には LoadAvg がない
        load_avg_5     = $null
        load_avg_15    = $null
        proc_count     = $proc_count
    }
    return ($json | ConvertTo-Json -Compress)
}

# ════════════════════════════════════════════════════════════
# コレクタースクリプトブロック（Start-Job で実行）
# ════════════════════════════════════════════════════════════
$CollectorBlock = {
    param($SessionDir, $Interval, $Duration, $Thr, $ScriptDir)

    $ts_fmt = 'yyyy-MM-dd HH:mm:ss'
    function Log-Info([string]$m) { "[$(Get-Date -f $ts_fmt)] [INFO ] $m" | Out-File "${SessionDir}\collector.log" -Append -Encoding utf8 }
    function Log-Warn([string]$m) { "[$(Get-Date -f $ts_fmt)] [WARN ] $m" | Out-File "${SessionDir}\collector.log" -Append -Encoding utf8 }

    # render_report.py を呼べるようにパスを追加（未使用だが参考のため）
    $DataFile   = Join-Path $SessionDir 'data.jsonl'
    $StatusFile = Join-Path $SessionDir 'status.txt'
    $StartTime  = Get-Date
    $SampleCount = 0

    Log-Info "Collector started: session=$SessionDir interval=${Interval}s duration=${Duration}s"

    # Get-Counter は1秒かけてサンプルを取るため、interval から1を引いたsleep
    $SleepSec = [math]::Max(1, $Interval - 1)

    while ($true) {
        try {
            $ts  = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            $hn  = $env:COMPUTERNAME

            # CPU
            $cpu_pct = $null
            try {
                $c = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $cpu_pct = [math]::Round($c.CounterSamples[0].CookedValue, 1)
            } catch {}

            # メモリ
            $mem_used_pct = $null; $mem_used_gb = $null; $mem_free_gb = $null; $mem_total_gb = $null
            $swap_used_pct = $null; $swap_used_gb = $null
            try {
                $oi = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $total = [math]::Round($oi.TotalVisibleMemorySize / 1MB, 2)
                $free  = [math]::Round($oi.FreePhysicalMemory / 1MB, 2)
                $used  = [math]::Round($total - $free, 2)
                $mem_total_gb = $total; $mem_free_gb = $free; $mem_used_gb = $used
                $mem_used_pct = if ($total -gt 0) { [math]::Round(100 * $used / $total, 1) } else { $null }
                $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
                if ($pf) {
                    $pa = ($pf | Measure-Object AllocatedBaseSize -Sum).Sum
                    $pc_use = ($pf | Measure-Object CurrentUsage -Sum).Sum
                    if ($pa -gt 0) {
                        $swap_used_gb = [math]::Round($pc_use / 1KB, 2)
                        $swap_used_pct = [math]::Round(100 * $pc_use / $pa, 1)
                    } else { $swap_used_gb = 0; $swap_used_pct = 0 }
                }
            } catch {}

            # ディスク
            $disk_read_mbps = $null; $disk_write_mbps = $null
            try {
                $dr = Get-Counter '\PhysicalDisk(_Total)\Disk Read Bytes/sec'  -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $dw = Get-Counter '\PhysicalDisk(_Total)\Disk Write Bytes/sec' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $disk_read_mbps  = [math]::Round($dr.CounterSamples[0].CookedValue / 1MB, 2)
                $disk_write_mbps = [math]::Round($dw.CounterSamples[0].CookedValue / 1MB, 2)
            } catch {}

            # ネットワーク
            $net_rx_mbps = $null; $net_tx_mbps = $null
            try {
                $rx = Get-Counter '\Network Interface(*)\Bytes Received/sec' -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $tx = Get-Counter '\Network Interface(*)\Bytes Sent/sec'     -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop
                $rx_total = ($rx.CounterSamples | Where-Object { $_.InstanceName -notmatch 'loopback|isatap' } | Measure-Object CookedValue -Sum).Sum
                $tx_total = ($tx.CounterSamples | Where-Object { $_.InstanceName -notmatch 'loopback|isatap' } | Measure-Object CookedValue -Sum).Sum
                $net_rx_mbps = [math]::Round($rx_total * 8 / 1MB, 2)
                $net_tx_mbps = [math]::Round($tx_total * 8 / 1MB, 2)
            } catch {}

            # プロセス数
            $proc_count = $null
            try {
                $pc = Get-Counter '\System\Processes' -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
                if ($pc) { $proc_count = [int]$pc.CounterSamples[0].CookedValue }
            } catch {}

            # JSON 出力
            $row = [ordered]@{
                ts = $ts; hostname = $hn; os = 'windows'
                cpu_pct = $cpu_pct
                mem_used_pct = $mem_used_pct; mem_used_gb = $mem_used_gb
                mem_free_gb = $mem_free_gb; mem_total_gb = $mem_total_gb
                swap_used_pct = $swap_used_pct; swap_used_gb = $swap_used_gb
                disk_read_mbps = $disk_read_mbps; disk_write_mbps = $disk_write_mbps
                net_rx_mbps = $net_rx_mbps; net_tx_mbps = $net_tx_mbps
                load_avg_1 = $null; load_avg_5 = $null; load_avg_15 = $null
                proc_count = $proc_count
            }
            ($row | ConvertTo-Json -Compress) | Out-File $DataFile -Append -Encoding utf8NoBOM
            $SampleCount++

            # ステータスファイル更新
            $cpu_s   = if ($null -ne $cpu_pct)   { "${cpu_pct}%"  } else { '?' }
            $mem_s   = if ($null -ne $mem_used_pct){ "${mem_used_pct}%"} else { '?' }
            $dr_s    = if ($null -ne $disk_read_mbps) { "${disk_read_mbps}MB/s"} else { '?' }
            $dw_s    = if ($null -ne $disk_write_mbps){ "${disk_write_mbps}MB/s"} else { '?' }
            $rx_s    = if ($null -ne $net_rx_mbps){ "${net_rx_mbps}Mbps"} else { '?' }
            $tx_s    = if ($null -ne $net_tx_mbps){ "${net_tx_mbps}Mbps"} else { '?' }
            $t_short = (Get-Date).ToString('HH:mm:ss')
            "[$t_short] #$SampleCount | CPU:$cpu_s MEM:$mem_s | Disk R:$dr_s W:$dw_s | Net Rx:$rx_s Tx:$tx_s" |
                Out-File $StatusFile -Encoding utf8NoBOM

            # しきい値チェック
            if ($null -ne $cpu_pct -and $Thr.CpuPct -gt 0 -and $cpu_pct -ge $Thr.CpuPct) {
                Log-Warn "THRESHOLD: cpu_pct=${cpu_pct}% >= $($Thr.CpuPct)%"
            }
            if ($null -ne $mem_used_pct -and $Thr.MemPct -gt 0 -and $mem_used_pct -ge $Thr.MemPct) {
                Log-Warn "THRESHOLD: mem_used_pct=${mem_used_pct}% >= $($Thr.MemPct)%"
            }
        } catch {
            Log-Warn "Sample error: $($_.Exception.Message)"
        }

        # 期間チェック
        if ($Duration -gt 0) {
            $elapsed = ((Get-Date) - $StartTime).TotalSeconds
            if ($elapsed -ge $Duration) {
                Log-Info "Duration reached: samples=$SampleCount elapsed=$elapsed"
                break
            }
        }

        Start-Sleep -Seconds $SleepSec
    }
    Log-Info "Collector finished: samples=$SampleCount"
}

# ════════════════════════════════════════════════════════════
# start コマンド
# ════════════════════════════════════════════════════════════
function Invoke-Start {
    $confPath = if ($Config) { $Config } else { $DefaultConf }
    Load-Conf $confPath

    if ($Interval -gt 0)  { $CFG['Interval']      = $Interval  }
    if ($Duration -ge 0)  { $CFG['Duration']      = $Duration  }
    if ($OutputDir)       { $CFG['OutputDir']     = $OutputDir }
    if ($Prefix)          { $CFG['OutputPrefix']  = $Prefix    }

    $ts         = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $sesDir     = Join-Path (Resolve-Path $CFG['OutputDir']).Path "$($CFG['OutputPrefix'])_${ts}"
    New-Item -ItemType Directory -Path $sesDir -Force | Out-Null

    # セッション設定スナップショット
    $CFG.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" } |
        Out-File (Join-Path $sesDir 'session.conf') -Encoding utf8NoBOM

    $thr = @{
        CpuPct    = [double]$CFG['ThresholdCpuPct']
        MemPct    = [double]$CFG['ThresholdMemPct']
        DiskReadMB= [double]$CFG['ThresholdDiskReadMBps']
        DiskWriteMB=[double]$CFG['ThresholdDiskWriteMBps']
        NetRx     = [double]$CFG['ThresholdNetRxMbps']
        NetTx     = [double]$CFG['ThresholdNetTxMbps']
        LoadAvg1  = [double]$CFG['ThresholdLoadAvg1']
    }

    $job = Start-Job -ScriptBlock $CollectorBlock -ArgumentList `
        $sesDir, [int]$CFG['Interval'], [int]$CFG['Duration'], $thr, $ScriptDir
    $job.Id | Out-File (Join-Path $sesDir 'collector.jobid') -Encoding utf8NoBOM

    Log-Info "Collector Job started: JobId=$($job.Id) session=$sesDir"
    Write-Host ""
    Write-Host "  セッション開始: $sesDir"
    Write-Host "  Job ID: $($job.Id)"
    Write-Host "  収集間隔: $($CFG['Interval'])秒 / 期間: $(if([int]$CFG['Duration'] -eq 0){'stop まで'}else{"$($CFG['Duration'])秒"})"
    Write-Host ""
    Write-Host "  停止:     .\PerfMonitor.ps1 stop   $sesDir"
    Write-Host "  状態確認:  .\PerfMonitor.ps1 status $sesDir"
    Write-Host "  レポート:  .\PerfMonitor.ps1 report $sesDir"
    Write-Host ""
}

# ════════════════════════════════════════════════════════════
# stop コマンド
# ════════════════════════════════════════════════════════════
function Invoke-Stop {
    $sd = if ($SessionDir) { $SessionDir } else {
        Get-ChildItem -Path '.' -Filter 'collector.jobid' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty DirectoryName
    }
    if (-not $sd) { Log-Error "No active session found."; exit 4 }

    $jobIdFile = Join-Path $sd 'collector.jobid'
    if (-not (Test-Path $jobIdFile)) { Log-Error "Job ID file not found: $jobIdFile"; exit 4 }
    $jobId = [int](Get-Content $jobIdFile)
    $job = Get-Job -Id $jobId -ErrorAction SilentlyContinue
    if ($job) {
        Stop-Job -Id $jobId -ErrorAction SilentlyContinue
        Remove-Job -Id $jobId -Force -ErrorAction SilentlyContinue
        Log-Info "Job $jobId stopped."
    } else {
        Log-Warn "Job $jobId not found (already stopped?)"
    }
    Remove-Item $jobIdFile -Force -ErrorAction SilentlyContinue
    $count = 0
    $df = Join-Path $sd 'data.jsonl'
    if (Test-Path $df) { $count = (Get-Content $df).Count }
    Log-Info "Collector stopped: session=$sd samples=$count"
    Write-Host ""
    Write-Host "  停止完了: $sd  ($count サンプル)"
    Write-Host "  レポート生成: .\PerfMonitor.ps1 report $sd"
    Write-Host ""
}

# ════════════════════════════════════════════════════════════
# report コマンド
# ════════════════════════════════════════════════════════════
function Invoke-Report {
    $sd = if ($SessionDir) { $SessionDir } else {
        Log-Error "session_dir required: PerfMonitor.ps1 report <session_dir>"; exit 1
    }
    $df = Join-Path $sd 'data.jsonl'
    if (-not (Test-Path $df)) { Log-Error "Data file not found: $df"; exit 4 }
    if (-not (Test-Path $RenderPy)) { Log-Error "render_report.py not found: $RenderPy"; exit 5 }

    $confPath = if ($Config) { $Config } else { $DefaultConf }
    Load-Conf $confPath
    $sesCfg = Join-Path $sd 'session.conf'
    if (Test-Path $sesCfg) { Load-Conf $sesCfg }

    $outHtml = Join-Path $sd 'report.html'
    Log-Info "Generating report: $outHtml"

    $env:PERF_THR_CPU    = $CFG['ThresholdCpuPct']
    $env:PERF_THR_MEM    = $CFG['ThresholdMemPct']
    $env:PERF_THR_DISK_R = $CFG['ThresholdDiskReadMBps']
    $env:PERF_THR_DISK_W = $CFG['ThresholdDiskWriteMBps']
    $env:PERF_THR_NET_RX = $CFG['ThresholdNetRxMbps']
    $env:PERF_THR_NET_TX = $CFG['ThresholdNetTxMbps']
    $env:PERF_THR_LOAD   = $CFG['ThresholdLoadAvg1']

    python3 $RenderPy $df $outHtml
    if ($LASTEXITCODE -eq 0) {
        Log-Info "Report generated: $outHtml"
        Write-Host ""; Write-Host "  レポート生成完了: $outHtml"; Write-Host ""
    } else {
        Log-Error "render_report.py failed"; exit 5
    }
}

# ════════════════════════════════════════════════════════════
# status コマンド
# ════════════════════════════════════════════════════════════
function Invoke-Status {
    $sd = if ($SessionDir) { $SessionDir } else {
        Get-ChildItem -Path '.' -Filter 'data.jsonl' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty DirectoryName
    }
    if (-not $sd) { Write-Host "アクティブなセッションが見つかりません"; return }

    Write-Host ""; Write-Host "  セッション: $sd"
    $jf = Join-Path $sd 'collector.jobid'
    if (Test-Path $jf) {
        $jid = [int](Get-Content $jf)
        $j = Get-Job -Id $jid -ErrorAction SilentlyContinue
        Write-Host "  状態: $(if($j -and $j.State -eq 'Running'){'収集中 (Job='+$jid+')'}else{'停止済み'})"
    } else { Write-Host "  状態: 停止済み" }

    $df = Join-Path $sd 'data.jsonl'
    $count = if (Test-Path $df) { (Get-Content $df).Count } else { 0 }
    Write-Host "  サンプル数: $count"

    $sf = Join-Path $sd 'status.txt'
    if (Test-Path $sf) {
        Write-Host ""; Write-Host "  最新サンプル:"
        Get-Content $sf | Write-Host
    }
    Write-Host ""
}

# ════════════════════════════════════════════════════════════
# list コマンド
# ════════════════════════════════════════════════════════════
function Invoke-List {
    Write-Host ""; Write-Host "  セッション一覧:"
    $found = $false
    Get-ChildItem -Path '.' -Filter 'collector.jobid' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $d = $_.DirectoryName
            $jid = [int](Get-Content $_.FullName)
            $j = Get-Job -Id $jid -ErrorAction SilentlyContinue
            $active = if ($j -and $j.State -eq 'Running') { '収集中' } else { '停止済み' }
            $df = Join-Path $d 'data.jsonl'
            $count = if (Test-Path $df) { (Get-Content $df).Count } else { 0 }
            Write-Host ("  [{0,-6}] {1}  ({2} サンプル)" -f $active, $d, $count)
            $found = $true
        }
    if (-not $found) { Write-Host "  (なし)" }
    Write-Host ""
}

# ════════════════════════════════════════════════════════════
# エントリポイント
# ════════════════════════════════════════════════════════════
switch ($Command) {
    'start'  { Invoke-Start  }
    'stop'   { Invoke-Stop   }
    'report' { Invoke-Report }
    'status' { Invoke-Status }
    'list'   { Invoke-List   }
}
