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

    # ── 前回の累積値（差分計算用、Linux 版 sh と同じ意味論）─────────────────
    # PerfFormattedData は CIM 内部の 1 秒サンプル基準の「瞬時値」になるため、
    # 同じ interval 平均にするには PerfRawData（累積値）を間隔で差分する必要がある。
    # 1 回目はベースラインのみ採るので null を出力する。
    $prevDiskRead  = $null; $prevDiskWrite = $null; $prevDiskTime  = $null
    $prevNetRx     = $null; $prevNetTx     = $null; $prevNetTime   = $null

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

            # ── ディスク (Win32_PerfRawData_PerfDisk_PhysicalDisk: 累積バイト) ──
            # interval 平均にするため累積値を差分する（Linux sh と同じ計算方式）
            $disk_read_mbps = $null; $disk_write_mbps = $null
            if ($collectDisk) { try {
                $dk = Get-CimInstance -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk `
                    -Filter "Name='_Total'" -ErrorAction Stop
                if ($dk) {
                    $now = Get-Date
                    $curRead  = [double]$dk.DiskReadBytesPerSec    # raw counter は実は累積バイト
                    $curWrite = [double]$dk.DiskWriteBytesPerSec
                    if ($null -ne $prevDiskRead -and $null -ne $prevDiskTime) {
                        $dt = ($now - $prevDiskTime).TotalSeconds
                        if ($dt -gt 0) {
                            $rd = [math]::Max(0, $curRead  - $prevDiskRead)
                            $wr = [math]::Max(0, $curWrite - $prevDiskWrite)
                            $disk_read_mbps  = [math]::Round($rd / $dt / 1MB, 2)
                            $disk_write_mbps = [math]::Round($wr / $dt / 1MB, 2)
                        }
                    }
                    $prevDiskRead  = $curRead
                    $prevDiskWrite = $curWrite
                    $prevDiskTime  = $now
                }
            } catch {} }

            # ── ネットワーク (Win32_PerfRawData_Tcpip_NetworkInterface: 累積バイト) ──
            $net_rx_mbps = $null; $net_tx_mbps = $null
            if ($collectNet) { try {
                $nics = Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface `
                    -ErrorAction Stop | Where-Object { $_.Name -notmatch 'Loopback|isatap' }
                if ($nics) {
                    $now = Get-Date
                    $curRx = [double](($nics | Measure-Object BytesReceivedPerSec -Sum).Sum)
                    $curTx = [double](($nics | Measure-Object BytesSentPerSec     -Sum).Sum)
                    if ($null -ne $prevNetRx -and $null -ne $prevNetTime) {
                        $dt = ($now - $prevNetTime).TotalSeconds
                        if ($dt -gt 0) {
                            $rx = [math]::Max(0, $curRx - $prevNetRx)
                            $tx = [math]::Max(0, $curTx - $prevNetTx)
                            $net_rx_mbps = [math]::Round($rx * 8 / $dt / 1MB, 2)
                            $net_tx_mbps = [math]::Round($tx * 8 / $dt / 1MB, 2)
                        }
                    }
                    $prevNetRx = $curRx; $prevNetTx = $curTx; $prevNetTime = $now
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
        load_avg_1     = [double]$CFG['ThresholdLoadAvg1']
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

    # ── ヘルパー ─────────────────────────────────────────────────
    function Get-TsLabel([string]$Ts) {
        try   { return ([datetime]::Parse($Ts)).ToString('HH:mm:ss') }
        catch {
            $len   = if ($Ts) { $Ts.Length } else { 0 }
            $take  = [math]::Min(8, $len)
            $start = $len - $take
            return $Ts.Substring($start, $take)
        }
    }

    function To-JsValue($v) {
        if ($null -eq $v) { return 'null' }
        # 数値であることを確認できれば数値、それ以外は文字列化（JSON 用にダブルクオート）
        if ($v -is [bool])                       { return ([bool]$v).ToString().ToLower() }
        if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { return "$v" }
        return "`"$v`""
    }

    function To-JsArr([string]$Key) {
        $parts = $records | ForEach-Object { To-JsValue $_.$Key }
        return '[' + ($parts -join ',') + ']'
    }

    function JsStr([string]$s) { return "`"" + ($s -replace '\\','\\\\' -replace '"','\"') + "`"" }

    function Measure-Stats([string]$Key) {
        $vals = @($records | Where-Object { $null -ne $_.$Key } | ForEach-Object { [double]$_.$Key })
        if ($vals.Count -eq 0) { return $null }
        $sorted = @($vals | Sort-Object)
        $p95i   = [math]::Min([int]($vals.Count * 95 / 100), $vals.Count - 1)
        return [PSCustomObject]@{
            min   = [math]::Round(($vals | Measure-Object -Min).Minimum, 2)
            max   = [math]::Round(($vals | Measure-Object -Max).Maximum, 2)
            avg   = [math]::Round(($vals | Measure-Object -Average).Average, 2)
            p95   = [math]::Round($sorted[$p95i], 2)
            count = $vals.Count
        }
    }

    # ── メタ情報 ─────────────────────────────────────────────────
    $tsFirst = $records[0].ts;  $tsLast = $records[-1].ts
    $hn      = $records[0].hostname
    $osName  = if ($records[0].PSObject.Properties.Match('os').Count) { [string]$records[0].os } else { 'unknown' }
    $isLinux = ($osName -eq 'linux')
    try {
        $dur     = [math]::Round(([datetime]::Parse($tsLast) - [datetime]::Parse($tsFirst)).TotalSeconds)
        $startStr = ([datetime]::Parse($tsFirst)).ToString('yyyy-MM-dd HH:mm:ss')
        $endStr   = ([datetime]::Parse($tsLast)).ToString('yyyy-MM-dd HH:mm:ss')
    } catch { $dur = 0; $startStr = $tsFirst; $endStr = $tsLast }
    if ($dur -ge 3600) {
        $durStr = "$([int]($dur/3600))時間$([int]($dur%3600/60))分$([int]($dur%60))秒"
    } elseif ($dur -ge 60) {
        $durStr = "$([int]($dur/60))分$([int]($dur%60))秒"
    } else {
        $durStr = "${dur}秒"
    }
    $genTime = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $nSam    = $records.Count

    # ── 統計（全メトリクス） ──────────────────────────────────────
    $stKeys = @('cpu_pct','mem_used_pct','mem_used_gb','mem_free_gb','mem_total_gb',
                'swap_used_pct','swap_used_gb',
                'disk_read_mbps','disk_write_mbps',
                'net_rx_mbps','net_tx_mbps',
                'load_avg_1','load_avg_5','load_avg_15',
                'proc_count')
    $st = @{}
    foreach ($k in $stKeys) { $st[$k] = Measure-Stats $k }

    # ── アラート検出 ─────────────────────────────────────────────
    $alerts = New-Object System.Collections.Generic.List[object]
    foreach ($r in $records) {
        $violations = New-Object System.Collections.Generic.List[object]
        foreach ($k in $Thresholds.Keys) {
            $tv = [double]$Thresholds[$k]
            if ($tv -le 0) { continue }
            $v = $r.$k
            if ($null -ne $v -and [double]$v -ge $tv) {
                $violations.Add([PSCustomObject]@{ metric=$k; value=[double]$v; threshold=$tv })
            }
        }
        if ($violations.Count -gt 0) {
            $alerts.Add([PSCustomObject]@{ ts=$r.ts; violations=$violations })
        }
    }
    $alertCount = $alerts.Count

    # ── サマリーカード ───────────────────────────────────────────
    function Get-PeakText([string]$key, [string]$unit) {
        $s = $st[$key]
        if (-not $s) { return 'N/A' }
        return "$($s.max)$unit (avg $($s.avg)$unit)"
    }
    function Build-Card([string]$title, [string]$value, [string]$color) {
        return "<div class=`"card`" style=`"border-top:3px solid $color`"><div class=`"card-title`">$title</div><div class=`"card-value`">$value</div></div>"
    }
    $alertColor = if ($alertCount -gt 0) { '#ef4444' } else { '#16a34a' }
    $loadPeak = if ($isLinux) { Get-PeakText 'load_avg_1' '' } else { 'N/A (Windows)' }
    $cardsHtml = (
        (Build-Card 'CPU ピーク'        (Get-PeakText 'cpu_pct'         '%')    '#3b82f6') +
        (Build-Card 'メモリ ピーク'      (Get-PeakText 'mem_used_pct'    '%')    '#8b5cf6') +
        (Build-Card 'Disk Read ピーク'  (Get-PeakText 'disk_read_mbps'  'MB/s') '#f59e0b') +
        (Build-Card 'Disk Write ピーク' (Get-PeakText 'disk_write_mbps' 'MB/s') '#f97316') +
        (Build-Card 'Net Rx ピーク'     (Get-PeakText 'net_rx_mbps'     'Mbps') '#06b6d4') +
        (Build-Card 'Net Tx ピーク'     (Get-PeakText 'net_tx_mbps'     'Mbps') '#0891b2') +
        (Build-Card 'Load Avg ピーク'   $loadPeak                              '#22c55e') +
        (Build-Card 'しきい値超過'       "$alertCount 回"                        $alertColor)
    )

    # ── Chart.js 生成 ────────────────────────────────────────────
    # 共通ラベル JS 配列
    $labelsJs = '[' + (($records | ForEach-Object { JsStr (Get-TsLabel $_.ts) }) -join ',') + ']'

    function Make-Chart {
        param(
            [string]$ChartId,
            [string]$Title,
            [array]$Datasets,    # @{ Label; Data; Color; Fill }
            [string]$YLabel = '',
            [double]$Threshold = 0,
            [string]$ThresholdLabel = '',
            [Nullable[double]]$YMax = $null,
            [int]$Height = 220
        )
        $dsJson = New-Object System.Collections.Generic.List[string]
        foreach ($d in $Datasets) {
            $dataJs = $d.Data
            $fillJs = if ($d.Fill) { "'origin'" } else { 'false' }
            $dsJson.Add(@"
{label:$(JsStr $d.Label),data:$dataJs,borderColor:'$($d.Color)',backgroundColor:'$($d.Color)26',borderWidth:1.5,pointRadius:0,tension:0.3,fill:$fillJs,spanGaps:true}
"@)
        }
        if ($Threshold -gt 0) {
            $thrData = '[' + ((1..$nSam | ForEach-Object { $Threshold }) -join ',') + ']'
            $thrLabel = if ($ThresholdLabel) { $ThresholdLabel } else { "しきい値 ($Threshold)" }
            $dsJson.Add("{label:$(JsStr $thrLabel),data:$thrData,borderColor:'#ef4444',borderWidth:1.5,borderDash:[6,4],pointRadius:0,fill:false,spanGaps:true}")
        }
        $datasetsJs = $dsJson -join ','
        $yMaxOpt = if ($null -ne $YMax) { "max: $YMax," } else { '' }
        $titleDisplay = if ($YLabel) { 'true' } else { 'false' }
        $yLabelJs = JsStr $YLabel
        return @"
<div class="chart-box">
  <div class="chart-title">$Title</div>
  <canvas id="$ChartId" height="$Height"></canvas>
</div>
<script>
(function(){
  var ctx = document.getElementById('$ChartId').getContext('2d');
  new Chart(ctx, {
    type: 'line',
    data: { labels: $labelsJs, datasets: [$datasetsJs] },
    options: {
      responsive: true, animation: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { position: 'top', labels: { boxWidth: 12, font: { size: 11 } } },
        tooltip: { callbacks: { label: function(c){ return c.dataset.label + ': ' + (c.parsed.y == null ? '-' : c.parsed.y) + ' $YLabel'; } } }
      },
      scales: {
        x: { ticks: { maxTicksLimit: 12, font: { size: 10 } }, grid: { color: '#f1f5f9' } },
        y: { beginAtZero: true, $yMaxOpt
             title: { display: $titleDisplay, text: $yLabelJs, font: { size: 11 } },
             ticks: { font: { size: 10 } }, grid: { color: '#f1f5f9' } }
      }
    }
  });
})();
</script>
"@
    }

    $thrCpu = [double]$Thresholds['cpu_pct']
    $thrMem = [double]$Thresholds['mem_used_pct']
    $thrDr  = [double]$Thresholds['disk_read_mbps']; $thrDw = [double]$Thresholds['disk_write_mbps']
    $thrRx  = [double]$Thresholds['net_rx_mbps'];    $thrTx = [double]$Thresholds['net_tx_mbps']
    $thrLoad = if ($Thresholds.ContainsKey('load_avg_1')) { [double]$Thresholds['load_avg_1'] } else { 0.0 }

    $chartsHtml = ''
    # 1. CPU
    $chartsHtml += Make-Chart -ChartId 'chartCpu' -Title 'CPU 使用率' `
        -Datasets @(@{Label='CPU (%)'; Data=(To-JsArr 'cpu_pct'); Color='#3b82f6'; Fill=$true}) `
        -YLabel '%' -Threshold $thrCpu -ThresholdLabel "しきい値 ($thrCpu%)" -YMax 100
    # 2. メモリ使用率
    $chartsHtml += Make-Chart -ChartId 'chartMem' -Title 'メモリ使用率' `
        -Datasets @(
            @{Label='Memory (%)'; Data=(To-JsArr 'mem_used_pct'); Color='#8b5cf6'; Fill=$true},
            @{Label='Swap (%)';   Data=(To-JsArr 'swap_used_pct'); Color='#c084fc'; Fill=$false}
        ) `
        -YLabel '%' -Threshold $thrMem -ThresholdLabel "しきい値 ($thrMem%)" -YMax 100
    # 3. メモリ容量 (GB)
    $yMaxMem = if ($st['mem_total_gb']) { [double]$st['mem_total_gb'].max } else { $null }
    $chartsHtml += Make-Chart -ChartId 'chartMemGB' -Title 'メモリ容量 (GB)' `
        -Datasets @(
            @{Label='使用 (GB)';     Data=(To-JsArr 'mem_used_gb'); Color='#7c3aed'; Fill=$true},
            @{Label='空き (GB)';     Data=(To-JsArr 'mem_free_gb'); Color='#a78bfa'; Fill=$false},
            @{Label='スワップ (GB)'; Data=(To-JsArr 'swap_used_gb'); Color='#c084fc'; Fill=$false}
        ) `
        -YLabel 'GB' -Threshold 0 -YMax $yMaxMem
    # 4. ディスク I/O
    $chartsHtml += Make-Chart -ChartId 'chartDisk' -Title 'ディスク I/O' `
        -Datasets @(
            @{Label='Read (MB/s)';  Data=(To-JsArr 'disk_read_mbps');  Color='#f59e0b'; Fill=$false},
            @{Label='Write (MB/s)'; Data=(To-JsArr 'disk_write_mbps'); Color='#f97316'; Fill=$false}
        ) `
        -YLabel 'MB/s' -Threshold ([math]::Max($thrDr,$thrDw)) -ThresholdLabel 'しきい値'
    # 5. ネットワーク
    $chartsHtml += Make-Chart -ChartId 'chartNet' -Title 'ネットワークスループット' `
        -Datasets @(
            @{Label='Rx (Mbps)'; Data=(To-JsArr 'net_rx_mbps'); Color='#06b6d4'; Fill=$false},
            @{Label='Tx (Mbps)'; Data=(To-JsArr 'net_tx_mbps'); Color='#0891b2'; Fill=$false}
        ) `
        -YLabel 'Mbps' -Threshold ([math]::Max($thrRx,$thrTx)) -ThresholdLabel 'しきい値'
    # 6. ロードアベレージ（Linux のみ）
    if ($isLinux) {
        $chartsHtml += Make-Chart -ChartId 'chartLoad' -Title 'ロードアベレージ' `
            -Datasets @(
                @{Label='Load 1min';  Data=(To-JsArr 'load_avg_1');  Color='#22c55e'; Fill=$false},
                @{Label='Load 5min';  Data=(To-JsArr 'load_avg_5');  Color='#4ade80'; Fill=$false},
                @{Label='Load 15min'; Data=(To-JsArr 'load_avg_15'); Color='#86efac'; Fill=$false}
            ) `
            -YLabel '' -Threshold $thrLoad -ThresholdLabel "しきい値 ($thrLoad)"
    }
    # 7. プロセス数
    $hasProc = @($records | Where-Object { $null -ne $_.proc_count }).Count -gt 0
    if ($hasProc) {
        $chartsHtml += Make-Chart -ChartId 'chartProc' -Title 'プロセス数' `
            -Datasets @(@{Label='Processes'; Data=(To-JsArr 'proc_count'); Color='#64748b'; Fill=$false}) `
            -YLabel ''
    }

    # ── 統計サマリーテーブル ─────────────────────────────────────
    function Stat-Row([string]$Label, [string]$Key, [string]$Unit) {
        $s = $st[$Key]
        if (-not $s) { return "<tr><td>$Label</td><td colspan=`"4`" class=`"na`">N/A</td></tr>" }
        $tv = if ($Thresholds.ContainsKey($Key)) { [double]$Thresholds[$Key] } else { 0.0 }
        $maxCls = if ($tv -gt 0 -and $s.max -ge $tv)        { ' class="alert"' } else { '' }
        $avgCls = if ($tv -gt 0 -and $s.avg -ge $tv * 0.8)  { ' class="warn"'  } else { '' }
        return "<tr><td>$Label</td><td>$($s.min)$Unit</td><td$avgCls>$($s.avg)$Unit</td><td$maxCls>$($s.max)$Unit</td><td>$($s.p95)$Unit</td></tr>"
    }
    $statRows = (
        (Stat-Row 'CPU 使用率'        'cpu_pct'         '%') +
        (Stat-Row 'メモリ使用率'      'mem_used_pct'    '%') +
        (Stat-Row 'メモリ使用量'      'mem_used_gb'     'GB') +
        (Stat-Row 'スワップ使用率'    'swap_used_pct'   '%') +
        (Stat-Row 'ディスク Read'     'disk_read_mbps'  'MB/s') +
        (Stat-Row 'ディスク Write'    'disk_write_mbps' 'MB/s') +
        (Stat-Row 'ネット受信'        'net_rx_mbps'     'Mbps') +
        (Stat-Row 'ネット送信'        'net_tx_mbps'     'Mbps')
    )
    if ($isLinux) {
        $statRows += (Stat-Row 'ロードアベレージ 1min' 'load_avg_1' '')
        $statRows += (Stat-Row 'ロードアベレージ 5min' 'load_avg_5' '')
    }
    $statRows += (Stat-Row 'プロセス数' 'proc_count' '')

    # ── しきい値超過テーブル（最大 200 行） ──────────────────────
    $alertSection = ''
    if ($alertCount -gt 0) {
        $rows = New-Object System.Collections.Generic.List[string]
        $shown = 0
        foreach ($a in $alerts) {
            $tsDisp = Get-TsLabel $a.ts
            foreach ($v in $a.violations) {
                if ($shown -ge 200) { break }
                $rows.Add("<tr><td>$tsDisp</td><td>$($v.metric)</td><td class=`"alert`">$($v.value)</td><td>$($v.threshold)</td></tr>")
                $shown++
            }
            if ($shown -ge 200) { break }
        }
        if ($alertCount -gt 200) {
            $rows.Add("<tr><td colspan=`"4`">... 他 $($alertCount - 200) 件</td></tr>")
        }
        $alertRows = $rows -join "`n"
        $alertSection = @"
<div class="section">
  <div class="section-title">しきい値超過一覧（$alertCount 件）</div>
  <table>
    <thead><tr><th>時刻</th><th>メトリクス</th><th>値</th><th>しきい値</th></tr></thead>
    <tbody>$alertRows</tbody>
  </table>
</div>
"@
    }

    # ── しきい値設定テーブル ─────────────────────────────────────
    $thrMap = @(
        @{label='CPU 使用率';            key='cpu_pct';         unit='%'},
        @{label='メモリ使用率';          key='mem_used_pct';    unit='%'},
        @{label='ディスク Read';         key='disk_read_mbps';  unit='MB/s'},
        @{label='ディスク Write';        key='disk_write_mbps'; unit='MB/s'},
        @{label='ネット受信';            key='net_rx_mbps';     unit='Mbps'},
        @{label='ネット送信';            key='net_tx_mbps';     unit='Mbps'},
        @{label='ロードアベレージ 1min'; key='load_avg_1';      unit=''}
    )
    $thrRows = ''
    foreach ($t in $thrMap) {
        $tv = if ($Thresholds.ContainsKey($t.key)) { [double]$Thresholds[$t.key] } else { 0.0 }
        if ($tv -gt 0) { $thrRows += "<tr><td>$($t.label)</td><td>$tv$($t.unit)</td></tr>" }
    }
    $thrSection = if ($thrRows) { @"
<div class="section">
  <div class="section-title">しきい値設定</div>
  <table style="max-width:400px">
    <thead><tr><th>メトリクス</th><th>しきい値</th></tr></thead>
    <tbody>$thrRows</tbody>
  </table>
</div>
"@ } else { '' }

    $alertBadge = if ($alertCount -gt 0) {
        "<span class=`"alert-badge`">$alertCount 回</span>"
    } else { "<span class=`"ok-badge`">なし</span>" }

    # ── HTML 組み立て ───────────────────────────────────────────
    $html = @"
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Performance Monitor Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}
.header{background:#1e293b;color:#fff;padding:20px 24px}
.header h1{font-size:22px;font-weight:700}
.header .sub{font-size:12px;color:#94a3b8;margin-top:4px}
.meta-bar{display:flex;gap:12px;padding:14px 24px;flex-wrap:wrap;background:#fff;border-bottom:1px solid #e2e8f0}
.meta-item{font-size:12px;color:#475569}
.meta-item span{font-weight:600;color:#1e293b;margin-left:4px}
.section{padding:16px 24px}
.section-title{font-size:14px;font-weight:700;color:#1e293b;margin-bottom:12px;padding-left:8px;border-left:3px solid #3b82f6}
.cards{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}
.card{background:#fff;border-radius:8px;padding:14px 18px;min-width:160px;box-shadow:0 1px 3px rgba(0,0,0,.1);flex:1}
.card-title{font-size:11px;color:#64748b;margin-bottom:6px}
.card-value{font-size:14px;font-weight:700;color:#1e293b}
.charts-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:16px}
.chart-box{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}
.chart-title{font-size:13px;font-weight:600;color:#1e293b;margin-bottom:10px}
table{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.1)}
th{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;color:#475569;font-size:12px;border-bottom:2px solid #e2e8f0}
td{padding:7px 12px;border-bottom:1px solid #f1f5f9;font-size:12px}
tr:last-child td{border-bottom:none}
td.alert{color:#dc2626;font-weight:700}
td.warn{color:#d97706;font-weight:600}
td.na{color:#94a3b8}
.alert-badge{display:inline-block;background:#fee2e2;color:#b91c1c;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.ok-badge{display:inline-block;background:#dcfce7;color:#15803d;padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}
.footer{text-align:center;padding:16px;font-size:11px;color:#94a3b8}
</style>
</head>
<body>
<div class="header">
  <h1>&#128200; Performance Monitor Report</h1>
  <div class="sub">Generated: $genTime (PowerShell renderer)</div>
</div>
<div class="meta-bar">
  <div class="meta-item">ホスト<span>$hn</span></div>
  <div class="meta-item">OS<span>$osName</span></div>
  <div class="meta-item">開始<span>$startStr</span></div>
  <div class="meta-item">終了<span>$endStr</span></div>
  <div class="meta-item">計測時間<span>$durStr</span></div>
  <div class="meta-item">サンプル数<span>$nSam 件</span></div>
  <div class="meta-item">しきい値超過<span>$alertBadge</span></div>
</div>
<div class="section">
  <div class="section-title">サマリー</div>
  <div class="cards">$cardsHtml</div>
</div>
<div class="section">
  <div class="section-title">リソース推移グラフ</div>
  <div class="charts-grid">$chartsHtml</div>
</div>
<div class="section">
  <div class="section-title">統計サマリー</div>
  <table>
    <thead><tr><th>メトリクス</th><th>最小</th><th>平均</th><th>最大</th><th>95パーセンタイル</th></tr></thead>
    <tbody>$statRows</tbody>
  </table>
</div>
$alertSection
$thrSection
<div class="footer">Performance Monitor &bull; PerfMonitor.ps1 (PS renderer) &bull; $genTime</div>
</body>
</html>
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
