#Requires -Version 5.1
<#
.SYNOPSIS
    Windows パフォーマンスモニター: 負荷テスト中のリソースを定期収集してレポート生成。
.DESCRIPTION
    負荷テスト中の CPU/メモリ/ディスク/ネットワーク等を定期的に収集し
    JSON Lines 形式のデータファイルに保存する。
    停止後に render_report.py でHTMLレポートを生成できる。
    コレクターは独立プロセスとして起動するため bat/cmd 経由でも継続動作する。

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
    [ValidateSet('start','stop','report','status','list','_collect')]
    [string]$Command = 'status',

    # --- start / _collect ---
    [string]$Config     = '',
    [int]   $Interval   = 0,
    [int]   $Duration   = -1,
    [string]$OutputDir  = '',
    [string]$Prefix     = '',

    # --- stop / report / status (2番目の位置引数として渡せるようにする) ---
    # 例: .\PerfMonitor.ps1 report .\results\perf_20260517-100000
    [Parameter(Position = 1)]
    [string]$SessionDir = '',

    # --- _collect (internal: called by Start-Process) ---
    [string]$_Session   = '',   # session directory
    [int]   $_Interval  = 5,
    [int]   $_Duration  = 0,
    [double]$_ThrCpu    = 0,
    [double]$_ThrMem    = 0,
    [double]$_ThrDiskR  = 0,
    [double]$_ThrDiskW  = 0,
    [double]$_ThrNetRx  = 0,
    [double]$_ThrNetTx  = 0,
    [double]$_ThrLoad   = 0,
    [string]$_Metrics   = 'all'    # 収集メトリクス: 'all' / 'cpu,mem,disk,net' 等
)

$ErrorActionPreference = 'Continue'   # collector ループ内のエラーでも継続
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $ScriptPath -Parent
$DefaultConf = Join-Path $ScriptDir 'perf_monitor.conf'
$RenderPy    = Join-Path $ScriptDir 'render_report.py'

# ── ログヘルパー ─────────────────────────────────────────────
function Write-Log([string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts] [$Level] $Msg"
}

# プロセス生存確認: Get-Process の代替 (GPO 制限環境対応)
# Win32_Process CIM クエリを使用。失敗時は $false を返す。
function Test-PidRunning([int]$ProcId) {
    try {
        $found = Get-CimInstance -ClassName Win32_Process `
            -Filter "ProcessId=$ProcId" -ErrorAction Stop
        return ($null -ne $found)
    } catch {
        # CIM も失敗した場合は pid ファイルの存在で判断（保守的に running とみなす）
        return $true
    }
}

# プロセス終了: Stop-Process の代替 (GPO 制限環境対応)
# taskkill.exe (Windows 組み込み) を使用。
function Stop-PidSafe([int]$ProcId) {
    try {
        # taskkill は管理者不要で自分のプロセスまたは同一ユーザーのプロセスを終了できる
        $null = & taskkill.exe /PID $ProcId /F /T 2>&1
        return $true
    } catch {
        return $false
    }
}
function Log-Info([string]$m)  { Write-Log 'INFO ' $m }
function Log-Warn([string]$m)  { Write-Log 'WARN ' $m }
function Log-Error([string]$m) { Write-Log 'ERROR' $m }

# セッション検索ルート: CLI で OutputDir を指定していればそこ、
# なければ perf_monitor.conf の OutputDir、それも未指定ならカレント。
# 旧コードはカレントを Recurse -Depth 2/3 で再帰していたため、別プロジェクトの
# セッションを誤検出する恐れがあった。検索範囲を明示する。
function Get-SessionSearchRoot {
    $root = if ($OutputDir) {
        $OutputDir
    } else {
        # まだ Load-Conf されていないこともあるため一時的に読み出す
        $confPath = if ($Config) { $Config } else { $DefaultConf }
        if (Test-Path $confPath) {
            $tmp = @{}
            Get-Content $confPath | ForEach-Object {
                $line = ($_ -replace '#.*$', '').Trim()
                if ($line -match '^([^=]+)=(.*)$') {
                    $tmp[$Matches[1].Trim()] = $Matches[2].Trim()
                }
            }
            if ($tmp.ContainsKey('OutputDir') -and $tmp['OutputDir']) { $tmp['OutputDir'] } else { '.' }
        } else { '.' }
    }
    if (-not (Test-Path $root)) { return '.' }
    return $root
}

# 最新セッションを検出するヘルパ。Stop / Status から共通利用。
function Find-LatestSession {
    $root = Get-SessionSearchRoot
    $hit = Get-ChildItem -Path $root -Filter 'collector.pid' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
    # collector.pid が無いセッション（既に stop 済み）も含めて data.jsonl で再検索
    $hit = Get-ChildItem -Path $root -Filter 'data.jsonl' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.DirectoryName }
    return $null
}

function Log-File([string]$LogFile, [string]$Level, [string]$Msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    "[$ts] [$Level] $Msg" | Out-File $LogFile -Append -Encoding utf8
}

# ── 設定読み込み ─────────────────────────────────────────────
$CFG = [ordered]@{
    Interval               = 5
    Duration               = 0
    OutputDir              = '.'
    OutputPrefix           = 'perf'
    Metrics                = 'all'
    ThresholdCpuPct        = 80.0
    ThresholdMemPct        = 85.0
    ThresholdDiskReadMBps  = 500.0
    ThresholdDiskWriteMBps = 500.0
    ThresholdNetRxMbps     = 900.0
    ThresholdNetTxMbps     = 900.0
    ThresholdLoadAvg1      = 4.0
    LogFile                = ''
    LogLevel               = 'INFO'
}

function Load-Conf([string]$Path) {
    if (-not (Test-Path $Path)) { return }
    Get-Content $Path | ForEach-Object {
        $line = ($_ -replace '#.*$', '').Trim()
        if ($line -match '^([^=]+)=(.*)$') {
            $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
            if ($CFG.Contains($k)) { $CFG[$k] = $v }
        }
    }
}

# ════════════════════════════════════════════════════════════
# _collect  —  独立プロセスとして実行されるコレクターループ
#   Start-Process powershell.exe -File PerfMonitor.ps1 _collect ... から呼ばれる
# ════════════════════════════════════════════════════════════
function Invoke-Collect {
    $sesDir     = $_Session
    $interval   = $_Interval
    $duration   = $_Duration
    $DataFile   = Join-Path $sesDir 'data.jsonl'
    $StatusFile = Join-Path $sesDir 'status.txt'
    $LogFile    = Join-Path $sesDir 'collector.log'
    $enc        = [System.Text.UTF8Encoding]::new($false)

    # 収集対象メトリクスをパース（Linux 版 sh と同じ仕様）。
    # 'all' または空はすべて収集、それ以外は cpu,mem,disk,net,load をカンマ区切り。
    # PS5.1 は null-coalescing (??) 非対応のため明示的に if 分岐する。
    $metricsRaw = if ($null -eq $_Metrics -or $_Metrics -eq '') { 'all' } else { $_Metrics }
    if ([string]::IsNullOrWhiteSpace($metricsRaw) -or $metricsRaw -ieq 'all') {
        $collectCpu = $true; $collectMem = $true; $collectDisk = $true
        $collectNet = $true; $collectLoad = $true
    } else {
        $items = $metricsRaw.ToLower().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $collectCpu  = $items -contains 'cpu'
        $collectMem  = $items -contains 'mem'  -or $items -contains 'memory'
        $collectDisk = $items -contains 'disk' -or $items -contains 'io'
        $collectNet  = $items -contains 'net'  -or $items -contains 'network'
        $collectLoad = $items -contains 'load' -or $items -contains 'loadavg'
    }

    # stdout は Start-Process の -RedirectStandardOutput で collector.log へ書かれる
    # Out-File は同ファイルと競合するため Write-Host (stdout) でログ出力する
    function CLog($lvl, $msg) {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Write-Host "[$ts] [$lvl] $msg"
    }
    CLog 'INFO ' "Collector started: interval=${interval}s duration=${duration}s"

    $startTime   = Get-Date
    $SampleCount = 0
    $SleepSec    = [math]::Max(1, $interval - 1)

    while ($true) {
        try {
            $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            $hn = $env:COMPUTERNAME

            # ── CPU (Get-Counter 代替: Win32_PerfFormattedData_PerfOS_Processor) ──
            # Get-Counter はGPOで制限される場合があるため CIM を使用する
            $cpu_pct = $null
            if ($collectCpu) {
                try {
                    $cp = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor `
                        -Filter "Name='_Total'" -ErrorAction Stop
                    if ($cp) { $cpu_pct = [math]::Round($cp.PercentProcessorTime, 1) }
                } catch {}
            }

            # ── メモリ (Win32_OperatingSystem は従来通り) ──────────────────────
            $mem_used_pct = $null; $mem_used_gb = $null
            $mem_free_gb  = $null; $mem_total_gb = $null
            $swap_used_pct = $null; $swap_used_gb = $null
            if ($collectMem) { try {
                $oi = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $total = [math]::Round($oi.TotalVisibleMemorySize / 1MB, 2)
                $free  = [math]::Round($oi.FreePhysicalMemory / 1MB, 2)
                $used  = [math]::Round($total - $free, 2)
                $mem_total_gb = $total; $mem_free_gb = $free; $mem_used_gb = $used
                if ($total -gt 0) { $mem_used_pct = [math]::Round(100 * $used / $total, 1) }
                $pf = Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue
                if ($pf) {
                    $pa = ($pf | Measure-Object AllocatedBaseSize -Sum).Sum
                    $pu = ($pf | Measure-Object CurrentUsage -Sum).Sum
                    if ($pa -gt 0) {
                        $swap_used_gb  = [math]::Round($pu / 1KB, 2)
                        $swap_used_pct = [math]::Round(100 * $pu / $pa, 1)
                    } else { $swap_used_gb = 0; $swap_used_pct = 0 }
                }
            } catch {} }

            # ── ディスク (Win32_PerfFormattedData_PerfDisk_PhysicalDisk) ────────
            $disk_read_mbps = $null; $disk_write_mbps = $null
            if ($collectDisk) { try {
                $dk = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
                    -Filter "Name='_Total'" -ErrorAction Stop
                if ($dk) {
                    $disk_read_mbps  = [math]::Round($dk.DiskReadBytesPerSec  / 1MB, 2)
                    $disk_write_mbps = [math]::Round($dk.DiskWriteBytesPerSec / 1MB, 2)
                }
            } catch {} }

            # ── ネットワーク (Win32_PerfFormattedData_Tcpip_NetworkInterface) ──
            $net_rx_mbps = $null; $net_tx_mbps = $null
            if ($collectNet) { try {
                $nics = Get-CimInstance -ClassName Win32_PerfFormattedData_Tcpip_NetworkInterface `
                    -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Loopback|isatap' }
                if ($nics) {
                    $rx_bps = ($nics | Measure-Object BytesReceivedPerSec -Sum).Sum
                    $tx_bps = ($nics | Measure-Object BytesSentPerSec     -Sum).Sum
                    $net_rx_mbps = [math]::Round($rx_bps * 8 / 1MB, 2)
                    $net_tx_mbps = [math]::Round($tx_bps * 8 / 1MB, 2)
                }
            } catch {} }

            # ── プロセス数 (Win32_OperatingSystem.NumberOfProcesses) ────────────
            # メモリ取得と同じ Win32_OperatingSystem なので mem 収集と連動させる
            $proc_count = $null
            if ($collectMem) { try {
                $os2 = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
                if ($os2) { $proc_count = [int]$os2.NumberOfProcesses }
            } catch {} }

            # JSON 出力（BOM なし UTF-8 で追記）
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
            $null = [System.IO.File]::AppendAllText(
                $DataFile,
                ($row | ConvertTo-Json -Compress) + [Environment]::NewLine,
                $enc
            )
            $SampleCount++

            # ステータスファイル更新
            $cpu_s = if ($null -ne $cpu_pct) { "${cpu_pct}%" } else { '?' }
            $mem_s = if ($null -ne $mem_used_pct) { "${mem_used_pct}%" } else { '?' }
            $dr_s  = if ($null -ne $disk_read_mbps) { "${disk_read_mbps}MB/s" } else { '?' }
            $dw_s  = if ($null -ne $disk_write_mbps) { "${disk_write_mbps}MB/s" } else { '?' }
            $rx_s  = if ($null -ne $net_rx_mbps) { "${net_rx_mbps}Mbps" } else { '?' }
            $tx_s  = if ($null -ne $net_tx_mbps) { "${net_tx_mbps}Mbps" } else { '?' }
            $t_short = (Get-Date).ToString('HH:mm:ss')
            "[$t_short] #$SampleCount | CPU:$cpu_s MEM:$mem_s | Disk R:$dr_s W:$dw_s | Net Rx:$rx_s Tx:$tx_s" |
                Out-File $StatusFile -Encoding utf8

            # しきい値チェック
            if ($null -ne $cpu_pct -and $_ThrCpu -gt 0 -and $cpu_pct -ge $_ThrCpu) {
                CLog 'WARN ' "THRESHOLD: cpu_pct=${cpu_pct}% >= ${_ThrCpu}%"
            }
            if ($null -ne $mem_used_pct -and $_ThrMem -gt 0 -and $mem_used_pct -ge $_ThrMem) {
                CLog 'WARN ' "THRESHOLD: mem_used_pct=${mem_used_pct}% >= ${_ThrMem}%"
            }
        } catch {
            CLog 'WARN ' "Sample error: $($_.Exception.Message)"
        }

        # 期間チェック
        if ($duration -gt 0) {
            $elapsed = ((Get-Date) - $startTime).TotalSeconds
            if ($elapsed -ge $duration) {
                CLog 'INFO ' "Duration reached: samples=$SampleCount elapsed=$elapsed"
                break
            }
        }

        Start-Sleep -Seconds $SleepSec
    }
    CLog 'INFO ' "Collector finished: samples=$SampleCount"
}

# ════════════════════════════════════════════════════════════
# start コマンド
# ════════════════════════════════════════════════════════════
function Invoke-Start {
    $confPath = if ($Config) { $Config } else { $DefaultConf }
    Load-Conf $confPath

    if ($Interval -gt 0)   { $CFG['Interval']     = $Interval  }
    if ($Duration -ge 0)   { $CFG['Duration']     = $Duration  }
    if ($OutputDir)        { $CFG['OutputDir']    = $OutputDir }
    if ($Prefix)           { $CFG['OutputPrefix'] = $Prefix    }

    $ts      = (Get-Date).ToString('yyyyMMdd-HHmmss')
    # OutputDir が存在しない場合は先に作成してから絶対パスに解決する
    $outDir  = $CFG['OutputDir']
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $sesDir  = Join-Path (Resolve-Path $outDir).Path "$($CFG['OutputPrefix'])_${ts}"
    New-Item -ItemType Directory -Path $sesDir -Force | Out-Null

    # 設定スナップショット保存
    $CFG.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" } |
        Out-File (Join-Path $sesDir 'session.conf') -Encoding utf8

    # コレクターを独立プロセスとして起動
    # Start-Job は親プロセス終了時にキャンセルされるため Start-Process を使用。
    # $args は PowerShell 自動変数なので $psArgs にリネーム。
    # -NoProfile を付けて環境差異（プロファイル経由の Set-StrictMode 等）を排除。
    $psArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$ScriptPath`"",
        '_collect',
        '-_Session',   "`"$sesDir`"",
        '-_Interval',  [int]$CFG['Interval'],
        '-_Duration',  [int]$CFG['Duration'],
        '-_ThrCpu',    [double]$CFG['ThresholdCpuPct'],
        '-_ThrMem',    [double]$CFG['ThresholdMemPct'],
        '-_ThrDiskR',  [double]$CFG['ThresholdDiskReadMBps'],
        '-_ThrDiskW',  [double]$CFG['ThresholdDiskWriteMBps'],
        '-_ThrNetRx',  [double]$CFG['ThresholdNetRxMbps'],
        '-_ThrNetTx',  [double]$CFG['ThresholdNetTxMbps'],
        '-_ThrLoad',   [double]$CFG['ThresholdLoadAvg1'],
        '-_Metrics',   "`"$([string]$CFG['Metrics'])`""
    )
    $proc = Start-Process powershell.exe -ArgumentList $psArgs `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $sesDir 'collector.log') `
        -RedirectStandardError  (Join-Path $sesDir 'collector.err.log')
    $proc.Id | Out-File (Join-Path $sesDir 'collector.pid') -Encoding utf8

    Log-Info "Collector started: PID=$($proc.Id) session=$sesDir"
    Write-Host ""
    Write-Host "  セッション開始: $sesDir"
    Write-Host "  PID: $($proc.Id)"
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
    $sd = if ($SessionDir) { $SessionDir } else { Find-LatestSession }
    if (-not $sd) { Log-Error "No active session found."; exit 4 }

    $pidFile = Join-Path $sd 'collector.pid'
    if (-not (Test-Path $pidFile)) { Log-Error "PID file not found: $pidFile"; exit 4 }
    $procId = [int](Get-Content $pidFile)
    if (Test-PidRunning $procId) {
        $null = Stop-PidSafe $procId
        Log-Info "Stopped PID $procId"
    } else {
        Log-Warn "PID $procId not running (already stopped?)"
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
    $df = Join-Path $sd 'data.jsonl'
    $count = if (Test-Path $df) { @(Get-Content $df).Count } else { 0 }
    Log-Info "Collector stopped: session=$sd samples=$count"
    Write-Host ""; Write-Host "  停止完了: $sd  ($count サンプル)"
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

    $confPath = if ($Config) { $Config } else { $DefaultConf }
    Load-Conf $confPath
    $sesCfg = Join-Path $sd 'session.conf'
    if (Test-Path $sesCfg) { Load-Conf $sesCfg }

    $outHtml = Join-Path $sd 'report.html'
    Log-Info "Generating report: $outHtml"

    # python3 が利用できれば render_report.py を優先使用（高品質チャート）
    $py3 = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py3) { $py3 = Get-Command python  -ErrorAction SilentlyContinue }

    if ($py3 -and (Test-Path $RenderPy)) {
        $env:PERF_THR_CPU    = $CFG['ThresholdCpuPct']
        $env:PERF_THR_MEM    = $CFG['ThresholdMemPct']
        $env:PERF_THR_DISK_R = $CFG['ThresholdDiskReadMBps']
        $env:PERF_THR_DISK_W = $CFG['ThresholdDiskWriteMBps']
        $env:PERF_THR_NET_RX = $CFG['ThresholdNetRxMbps']
        $env:PERF_THR_NET_TX = $CFG['ThresholdNetTxMbps']
        $env:PERF_THR_LOAD   = $CFG['ThresholdLoadAvg1']
        & $py3.Source $RenderPy $df $outHtml
        if ($LASTEXITCODE -eq 0) {
            Log-Info "Report generated via python3: $outHtml"
            Write-Host ""; Write-Host "  レポート生成完了: $outHtml"; Write-Host ""
            return
        }
        Log-Warn "python3 failed (exit $LASTEXITCODE), falling back to PowerShell renderer"
    } else {
        Log-Info "python3 not found — using built-in PowerShell renderer"
    }

    # PowerShell ネイティブ HTML 生成（python3 不要）
    $thr = @{
        cpu_pct        = [double]$CFG['ThresholdCpuPct']
        mem_used_pct   = [double]$CFG['ThresholdMemPct']
        disk_read_mbps = [double]$CFG['ThresholdDiskReadMBps']
        disk_write_mbps= [double]$CFG['ThresholdDiskWriteMBps']
        net_rx_mbps    = [double]$CFG['ThresholdNetRxMbps']
        net_tx_mbps    = [double]$CFG['ThresholdNetTxMbps']
    }
    if (New-PerfHtmlReport -DataFile $df -OutputFile $outHtml -Thresholds $thr) {
        Log-Info "Report generated via PS renderer: $outHtml"
        Write-Host ""; Write-Host "  レポート生成完了: $outHtml"; Write-Host ""
    } else {
        Log-Error "Report generation failed"; exit 5
    }
}

# ════════════════════════════════════════════════════════════
# PowerShell ネイティブ HTML レポート生成
#   python3 が使えない環境向けのフォールバック。
#   Chart.js (CDN) を使ってブラウザで描画するため
#   ネットワーク接続があれば python3 版と同等のグラフが得られる。
# ════════════════════════════════════════════════════════════
function New-PerfHtmlReport {
    param(
        [string]$DataFile,
        [string]$OutputFile,
        [hashtable]$Thresholds
    )
    $enc = [System.Text.UTF8Encoding]::new($false)

    # データ読み込み
    $records = @(
        Get-Content $DataFile -Encoding utf8 |
        Where-Object { $_.Trim() } |
        ForEach-Object { ConvertFrom-Json $_ }
    )
    if ($records.Count -eq 0) { Write-Log 'ERROR' "No records in $DataFile"; return $false }

    # タイムスタンプラベル
    function Get-TsLabel([string]$Ts) {
        try   { return ([datetime]::Parse($Ts)).ToString('HH:mm:ss') }
        catch {
            # フォーマット不明な場合は末尾最大 8 文字を返す（境界式バグ修正）
            $len   = if ($Ts) { $Ts.Length } else { 0 }
            $take  = [math]::Min(8, $len)
            $start = $len - $take
            return $Ts.Substring($start, $take)
        }
    }

    # JS 配列文字列生成
    function To-JsArr([string]$Key) {
        $parts = $records | ForEach-Object {
            $v = $_.$Key
            if ($null -eq $v) { 'null' } else { "$v" }
        }
        return '[' + ($parts -join ',') + ']'
    }

    $labels_js = '[' + (($records | ForEach-Object { '"' + (Get-TsLabel $_.ts) + '"' }) -join ',') + ']'

    # 統計計算
    function Measure-Stats([string]$Key) {
        $vals = @($records | Where-Object { $null -ne $_.$Key } | ForEach-Object { [double]$_.$Key })
        if ($vals.Count -eq 0) { return $null }
        $sorted = @($vals | Sort-Object)
        $p95i   = [math]::Min([int]($vals.Count * 0.95), $vals.Count - 1)
        return [PSCustomObject]@{
            min = [math]::Round(($vals | Measure-Object -Min).Minimum, 2)
            max = [math]::Round(($vals | Measure-Object -Max).Maximum, 2)
            avg = [math]::Round(($vals | Measure-Object -Average).Average, 2)
            p95 = [math]::Round($sorted[$p95i], 2)
        }
    }

    # しきい値超過チェック
    function Get-AlertCount([string]$Key) {
        $tv = $Thresholds[$Key]
        if (-not $tv -or $tv -le 0) { return 0 }
        return @($records | Where-Object { $null -ne $_.$Key -and [double]$_.$Key -ge $tv }).Count
    }

    $tsFirst = $records[0].ts;  $tsLast = $records[-1].ts
    $hn      = $records[0].hostname
    try { $dur = [math]::Round(([datetime]::Parse($tsLast) - [datetime]::Parse($tsFirst)).TotalSeconds) } catch { $dur = 0 }
    $genTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $nSam    = $records.Count

    $st_cpu  = Measure-Stats 'cpu_pct'
    $st_mem  = Measure-Stats 'mem_used_pct'
    $st_dr   = Measure-Stats 'disk_read_mbps'
    $st_dw   = Measure-Stats 'disk_write_mbps'
    $st_rx   = Measure-Stats 'net_rx_mbps'
    $st_tx   = Measure-Stats 'net_tx_mbps'

    $totalAlerts = 0
    foreach ($k in $Thresholds.Keys) { $totalAlerts += Get-AlertCount $k }

    function Stat-Row([string]$Label, $St, [string]$Unit, [string]$Key) {
        if (-not $St) { return "<tr><td>$Label</td><td colspan='4' class='na'>N/A</td></tr>" }
        $tv  = $Thresholds[$Key]
        $mcls = if ($tv -gt 0 -and $St.max -ge $tv) { " class='alert'" } else { "" }
        return "<tr><td>$Label</td><td>$($St.min)$Unit</td><td>$($St.avg)$Unit</td><td$mcls>$($St.max)$Unit</td><td>$($St.p95)$Unit</td></tr>"
    }

    $statRows = (
        (Stat-Row 'CPU 使用率'     $st_cpu '%'    'cpu_pct') +
        (Stat-Row 'メモリ使用率'   $st_mem '%'    'mem_used_pct') +
        (Stat-Row 'Disk Read'     $st_dr  'MB/s' 'disk_read_mbps') +
        (Stat-Row 'Disk Write'    $st_dw  'MB/s' 'disk_write_mbps') +
        (Stat-Row 'Net Rx'        $st_rx  'Mbps' 'net_rx_mbps') +
        (Stat-Row 'Net Tx'        $st_tx  'Mbps' 'net_tx_mbps')
    )

    # アラートテーブル行生成（最大 200 行）
    $alertRows = ''
    $alertLines = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $records) {
        foreach ($k in $Thresholds.Keys) {
            $tv = $Thresholds[$k]
            if ($tv -le 0) { continue }
            $v  = $r.$k
            if ($null -ne $v -and [double]$v -ge $tv) {
                $tl = Get-TsLabel $r.ts
                $alertLines.Add("<tr><td>$tl</td><td>$k</td><td class='alert'>$v</td><td>$tv</td></tr>")
                if ($alertLines.Count -ge 200) { break }
            }
        }
        if ($alertLines.Count -ge 200) { break }
    }
    $alertRows = $alertLines -join "`n"
    $alertSection = if ($totalAlerts -gt 0) { @"
<div class="section">
  <div class="section-title">&#x26A0; しきい値超過一覧 ($totalAlerts 件)</div>
  <table><thead><tr><th>時刻</th><th>メトリクス</th><th>値</th><th>しきい値</th></tr></thead>
  <tbody>$alertRows</tbody></table>
</div>
"@ } else { '' }

    # Chart.js 関数定義
    $cpu_js   = To-JsArr 'cpu_pct'
    $mem_js   = To-JsArr 'mem_used_pct'
    $dr_js    = To-JsArr 'disk_read_mbps'
    $dw_js    = To-JsArr 'disk_write_mbps'
    $rx_js    = To-JsArr 'net_rx_mbps'
    $tx_js    = To-JsArr 'net_tx_mbps'
    $ld1_js   = To-JsArr 'load_avg_1'

    $thr_cpu = $Thresholds['cpu_pct']; $thr_mem = $Thresholds['mem_used_pct']
    $thr_dr  = $Thresholds['disk_read_mbps']; $thr_dw = $Thresholds['disk_write_mbps']
    $thr_rx  = $Thresholds['net_rx_mbps'];    $thr_tx = $Thresholds['net_tx_mbps']

    function Make-Chart([string]$id, [string]$title, [string]$y_label, [string]$data_js,
                        [string]$color, [double]$threshold = 0, [string]$data2_js = '',
                        [string]$color2 = '', [string]$label1 = '', [string]$label2 = '') {
        $lbl1  = if ($label1) { $label1 } else { $title }
        $thr_ds = if ($threshold -gt 0) {
            ",{label:'しきい値 ($threshold)',data:Array($nSam).fill($threshold),borderColor:'#ef4444',borderWidth:1.5,borderDash:[6,4],pointRadius:0,fill:false,spanGaps:true}"
        } else { '' }
        $ds2 = if ($data2_js) {
            ",{label:'$label2',data:$data2_js,borderColor:'$color2',backgroundColor:'${color2}26',borderWidth:1.5,pointRadius:0,tension:0.3,fill:false,spanGaps:true}"
        } else { '' }
        return @"
<div class="chart-box">
  <div class="chart-title">$title</div>
  <canvas id="$id" height="220"></canvas>
</div>
<script>
(function(){var ctx=document.getElementById('$id').getContext('2d');
new Chart(ctx,{type:'line',data:{labels:$labels_js,datasets:[
  {label:'$lbl1',data:$data_js,borderColor:'$color',backgroundColor:'${color}26',borderWidth:1.5,pointRadius:0,tension:0.3,fill:true,spanGaps:true}
  $ds2$thr_ds]},
options:{responsive:true,animation:false,interaction:{mode:'index',intersect:false},
  plugins:{legend:{position:'top',labels:{boxWidth:12,font:{size:11}}},
  tooltip:{callbacks:{label:function(c){return c.dataset.label+': '+(c.parsed.y??'-')+' $y_label'}}}},
  scales:{x:{ticks:{maxTicksLimit:12,font:{size:10}},grid:{color:'#f1f5f9'}},
          y:{beginAtZero:true,title:{display:true,text:'$y_label',font:{size:11}},ticks:{font:{size:10}},grid:{color:'#f1f5f9'}}}}});
})();</script>
"@
    }

    $charts = (
        (Make-Chart 'ch_cpu'  'CPU 使用率'            '%'    $cpu_js  '#3b82f6' $thr_cpu) +
        (Make-Chart 'ch_mem'  'メモリ使用率'           '%'    $mem_js  '#8b5cf6' $thr_mem) +
        (Make-Chart 'ch_disk' 'ディスク I/O'          'MB/s' $dr_js   '#f59e0b' ([math]::Max($thr_dr,$thr_dw)) '' $dw_js '#f97316' 'Read (MB/s)' 'Write (MB/s)') +
        (Make-Chart 'ch_net'  'ネットワーク'           'Mbps' $rx_js   '#06b6d4' ([math]::Max($thr_rx,$thr_tx)) '' $tx_js '#0891b2' 'Rx (Mbps)' 'Tx (Mbps)') +
        (Make-Chart 'ch_load' 'ロードアベレージ'       ''     $ld1_js  '#22c55e')
    )

    $peakCpu = if ($st_cpu) { "$($st_cpu.max)% (avg $($st_cpu.avg)%)" } else { 'N/A' }
    $peakMem = if ($st_mem) { "$($st_mem.max)% (avg $($st_mem.avg)%)" } else { 'N/A' }
    $alertBadge = if ($totalAlerts -gt 0) { "<span class='alert-badge'>$totalAlerts 回</span>" } else { "<span class='ok-badge'>なし</span>" }
    $durStr = "$([int]($dur/60))分$([int]($dur%60))秒"

    $html = @"
<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Performance Monitor Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}
.header{background:#1e293b;color:#fff;padding:20px 24px}
.header h1{font-size:22px;font-weight:700}
.header .sub{font-size:12px;color:#94a3b8;margin-top:4px}
.meta-bar{display:flex;gap:12px;padding:14px 24px;flex-wrap:wrap;background:#fff;border-bottom:1px solid #e2e8f0}
.meta-item{font-size:12px;color:#475569}.meta-item span{font-weight:600;color:#1e293b;margin-left:4px}
.section{padding:16px 24px}
.section-title{font-size:14px;font-weight:700;color:#1e293b;margin-bottom:12px;padding-left:8px;border-left:3px solid #3b82f6}
.cards{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}
.card{background:#fff;border-radius:8px;padding:14px 18px;min-width:160px;box-shadow:0 1px 3px rgba(0,0,0,.1);flex:1}
.card-title{font-size:11px;color:#64748b;margin-bottom:6px}.card-value{font-size:14px;font-weight:700;color:#1e293b}
.charts-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:16px}
.chart-box{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.chart-title{font-size:13px;font-weight:600;color:#1e293b;margin-bottom:10px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.1)}
th{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;color:#475569;font-size:12px;border-bottom:2px solid #e2e8f0}
td{padding:7px 12px;border-bottom:1px solid #f1f5f9;font-size:12px}tr:last-child td{border-bottom:none}
td.alert{color:#dc2626;font-weight:700}td.na{color:#94a3b8}
.alert-badge{background:#fee2e2;color:#b91c1c;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.ok-badge{background:#dcfce7;color:#15803d;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}
</style></head><body>
<div class="header"><h1>&#128200; Performance Monitor Report</h1>
<div class="sub">Generated: $genTime (PowerShell renderer)</div></div>
<div class="meta-bar">
  <div class="meta-item">ホスト<span>$hn</span></div>
  <div class="meta-item">開始<span>$tsFirst</span></div>
  <div class="meta-item">終了<span>$tsLast</span></div>
  <div class="meta-item">計測時間<span>$durStr</span></div>
  <div class="meta-item">サンプル数<span>$nSam 件</span></div>
  <div class="meta-item">しきい値超過<span>$alertBadge</span></div>
</div>
<div class="section"><div class="section-title">サマリー</div>
<div class="cards">
  <div class="card" style="border-top:3px solid #3b82f6"><div class="card-title">CPU ピーク</div><div class="card-value">$peakCpu</div></div>
  <div class="card" style="border-top:3px solid #8b5cf6"><div class="card-title">メモリ ピーク</div><div class="card-value">$peakMem</div></div>
  <div class="card" style="border-top:3px solid $(if($totalAlerts -gt 0){'#ef4444'}else{'#16a34a'})"><div class="card-title">しきい値超過</div><div class="card-value">$totalAlerts 回</div></div>
</div></div>
<div class="section"><div class="section-title">リソース推移グラフ</div>
<div class="charts-grid">$charts</div></div>
<div class="section"><div class="section-title">統計サマリー</div>
<table><thead><tr><th>メトリクス</th><th>最小</th><th>平均</th><th>最大</th><th>95パーセンタイル</th></tr></thead>
<tbody>$statRows</tbody></table></div>
$alertSection
<div class="footer">Performance Monitor &bull; PerfMonitor.ps1 (PS renderer) &bull; $genTime</div>
</body></html>
"@

    [System.IO.File]::WriteAllText($OutputFile, $html, $enc)
    return $true
}

# ════════════════════════════════════════════════════════════
# status コマンド
# ════════════════════════════════════════════════════════════
function Invoke-Status {
    $sd = if ($SessionDir) { $SessionDir } else { Find-LatestSession }
    if (-not $sd) { Write-Host "アクティブなセッションが見つかりません"; return }

    Write-Host ""; Write-Host "  セッション: $sd"
    $pf = Join-Path $sd 'collector.pid'
    if (Test-Path $pf) {
        $collectorPid = [int](Get-Content $pf)
        $running = Test-PidRunning $collectorPid
        Write-Host "  状態: $(if($running){'収集中 (PID='+$collectorPid+')'}else{'停止済み'})"
    } else { Write-Host "  状態: 停止済み" }

    $df = Join-Path $sd 'data.jsonl'
    $count = if (Test-Path $df) { @(Get-Content $df).Count } else { 0 }
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
    # 検出範囲は OutputDir 配下に限定（誤って別プロジェクトのセッションを表示しないため）
    $searchRoot = Get-SessionSearchRoot
    Get-ChildItem -Path $searchRoot -Filter 'collector.pid' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $d = $_.DirectoryName
            $collectorPid = [int](Get-Content $_.FullName)
            $active = if (Test-PidRunning $collectorPid) { '収集中' } else { '停止済み' }
            $df = Join-Path $d 'data.jsonl'
            $count = if (Test-Path $df) { @(Get-Content $df).Count } else { 0 }
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
    'start'    { Invoke-Start  }
    'stop'     { Invoke-Stop   }
    'report'   { Invoke-Report }
    'status'   { Invoke-Status }
    'list'     { Invoke-List   }
    '_collect' { Invoke-Collect }
}
