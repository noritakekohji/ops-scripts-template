#!/usr/bin/env bash
# ============================================================================
# perf_monitor.sh  -  Linux パフォーマンスモニター
#   負荷テスト中のリソースを定期収集し、JSON Lines 形式で保存する
#
# 使い方:
#   perf_monitor.sh start  [-c conf] [-i 秒] [-d 秒] [-o 出力先] [-p prefix]
#   perf_monitor.sh stop   [session_dir]
#   perf_monitor.sh report <session_dir> [-c conf]
#   perf_monitor.sh status [session_dir]
#   perf_monitor.sh list
#
# オプション（start）:
#   -c  設定ファイルパス（既定: スクリプトと同じディレクトリの perf_monitor.conf）
#   -i  収集間隔秒（既定: 5）
#   -d  収集期間秒（0 = stop で明示停止、既定: 0）
#   -o  セッション親ディレクトリ（既定: カレント）
#   -p  セッションディレクトリ名プレフィックス（既定: perf）
#
# 出力ファイル（セッションディレクトリ内）:
#   data.jsonl       収集データ（JSON Lines）
#   session.conf     このセッションの設定スナップショット
#   collector.pid    コレクタープロセスの PID
#   status.txt       最新のサンプル概要（リアルタイム表示用）
#   collector.log    コレクターログ
#   report.html      HTML レポート（report コマンド実行後）
#
# 終了コード: 0 成功, 1 引数エラー, 2 設定エラー, 3 すでに実行中,
#             4 PID/セッション不在, 5 render_report.py 失敗
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEFAULT_CONF="${SCRIPT_DIR}/perf_monitor.conf"
RENDER_PY="${SCRIPT_DIR}/render_report.py"

# ── ログヘルパー ─────────────────────────────────────────────
_log() { local lvl=$1; shift; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$lvl] $*" >&2; }
log_info()  { _log "INFO " "$@"; }
log_warn()  { _log "WARN " "$@"; }
log_error() { _log "ERROR" "$@"; }

# ── 設定読み込み ─────────────────────────────────────────────
declare -A CFG=(
    [Interval]=5
    [Duration]=0
    [OutputDir]="."
    [OutputPrefix]="perf"
    [Metrics]="all"
    [ThresholdCpuPct]="80.0"
    [ThresholdMemPct]="85.0"
    [ThresholdDiskReadMBps]="500.0"
    [ThresholdDiskWriteMBps]="500.0"
    [ThresholdNetRxMbps]="900.0"
    [ThresholdNetTxMbps]="900.0"
    [ThresholdLoadAvg1]="4.0"
    [LogFile]=""
    [LogLevel]="INFO"
)

load_conf() {
    local conf_file="$1"
    [[ ! -f "$conf_file" ]] && return
    while IFS='=' read -r k v; do
        k="${k%%#*}"; k="${k//[[:space:]]/}"
        v="${v%%#*}"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        [[ -z "$k" ]] && continue
        CFG[$k]="$v"
    done < "$conf_file"
}

# セッション検索の起点ディレクトリ。perf_monitor.conf を最低限読んで OutputDir を返す。
# 既に load_conf 済みなら CFG[OutputDir] が反映されている。
_session_search_root() {
    if [[ -z "${CFG[OutputDir]:-}" || "${CFG[OutputDir]}" == "." ]]; then
        # 未ロードのケースに備えて conf を一時読み出し（副作用を避けるためサブシェル）
        if [[ -f "$DEFAULT_CONF" ]]; then
            local v
            v=$(awk -F= '/^[[:space:]]*OutputDir[[:space:]]*=/ {sub(/#.*$/,""); gsub(/[[:space:]]/,"",$2); print $2; exit}' "$DEFAULT_CONF")
            [[ -n "$v" ]] && { echo "$v"; return; }
        fi
        echo "."
    else
        echo "${CFG[OutputDir]}"
    fi
}

# 検索範囲を OutputDir 配下に限定して最新セッションを返す。
# 旧コードはカレント全体を再帰 (`find . -maxdepth 2`) しており、
# 別プロジェクトのセッションを誤検出する恐れがあった。
_find_latest_session() {
    local root
    root=$(_session_search_root)
    [[ -d "$root" ]] || root="."
    local hit
    hit=$(find "$root" -maxdepth 2 -name "collector.pid" 2>/dev/null \
          | sort -r | head -1 | xargs -r dirname 2>/dev/null || true)
    if [[ -z "$hit" ]]; then
        hit=$(find "$root" -maxdepth 2 -name "data.jsonl" 2>/dev/null \
              | sort -r | head -1 | xargs -r dirname 2>/dev/null || true)
    fi
    echo "$hit"
}

usage() {
    sed -n '2,18p' "$0" >&2
    exit 1
}

# ════════════════════════════════════════════════════════════
# メトリクス収集関数
# ════════════════════════════════════════════════════════════

# CPU: /proc/stat から user nice sys idle iowait irq softirq steal を返す
_cpu_stat() {
    awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat
}

# CPU% 計算（前回値と今回値から）
_cpu_pct() {
    local prev="$1" curr="$2"
    awk -v p="$prev" -v c="$curr" 'BEGIN{
        split(p, pv, " "); split(c, cv, " ")
        pt=0; ct=0
        for(i=1;i<=8;i++){pt+=pv[i]; ct+=cv[i]}
        pid=pv[4]+pv[5]; cid=cv[4]+cv[5]
        dt=ct-pt
        if(dt==0){print "0.0"; exit}
        printf "%.1f", 100*(dt-(cid-pid))/dt
    }'
}

# メモリ: MemTotal MemAvailable SwapTotal SwapFree (kB)
_mem_stat() {
    awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}/^SwapTotal/{st=$2}/^SwapFree/{sf=$2}
         END{print t,a,st,sf}' /proc/meminfo
}

# ディスク: /proc/diskstats から主要ブロックデバイスの累積セクター数 (読み,書き)
_disk_stat() {
    awk '
    /^[[:space:]]*[0-9]+ [0-9]+ (sd[a-z]+|nvme[0-9]+n[0-9]+|xvd[a-z]+|vd[a-z]+|hd[a-z]+) /{
        rs+=$6; ws+=$10
    }
    END{print rs+0, ws+0}' /proc/diskstats
}

# ネットワーク: /proc/net/dev から loopback 除く受信/送信バイト累積
_net_stat() {
    awk 'NR>2 && !/lo:/{
        gsub(/:/,""); rx+=$2; tx+=$10
    } END{print rx+0, tx+0}' /proc/net/dev
}

# ロードアベレージ
_load_avg() {
    cut -d' ' -f1-3 /proc/loadavg
}

# プロセス数
_proc_count() {
    # running processes (all states)
    ls /proc | grep -c '^[0-9]' || echo 0
}

# ── 1サンプル収集（JSON 1行を stdout へ出力）───────────────
collect_sample() {
    local interval="$1"
    local prev_cpu="$2" prev_disk="$3" prev_net="$4"
    local metrics="${CFG[Metrics]}"

    local ts
    ts=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S+00:00')
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "unknown")

    # ── CPU ──────────────────────────────────────────────────
    local cpu_pct="null"
    local curr_cpu=""
    if [[ "$metrics" == "all" ]] || echo "$metrics" | grep -q "cpu"; then
        curr_cpu=$(_cpu_stat)
        if [[ -n "$prev_cpu" ]]; then
            cpu_pct=$(_cpu_pct "$prev_cpu" "$curr_cpu")
        fi
    fi

    # ── メモリ ───────────────────────────────────────────────
    local mem_used_pct="null" mem_used_gb="null" mem_free_gb="null"
    local mem_total_gb="null" swap_used_pct="null" swap_used_gb="null"
    if [[ "$metrics" == "all" ]] || echo "$metrics" | grep -q "mem"; then
        local ms
        ms=$(_mem_stat)
        local mt ma st sf
        read -r mt ma st sf <<< "$ms"
        if [[ "$mt" -gt 0 ]]; then
            mem_total_gb=$(awk "BEGIN{printf \"%.2f\",$mt/1048576}")
            mem_free_gb=$(awk  "BEGIN{printf \"%.2f\",$ma/1048576}")
            mem_used_gb=$(awk  "BEGIN{printf \"%.2f\",($mt-$ma)/1048576}")
            mem_used_pct=$(awk "BEGIN{printf \"%.1f\",100*($mt-$ma)/$mt}")
        fi
        if [[ "$st" -gt 0 ]]; then
            swap_used_gb=$(awk  "BEGIN{printf \"%.2f\",($st-$sf)/1048576}")
            swap_used_pct=$(awk "BEGIN{printf \"%.1f\",100*($st-$sf)/$st}")
        else
            swap_used_gb="0.0"; swap_used_pct="0.0"
        fi
    fi

    # ── ディスク I/O ─────────────────────────────────────────
    local disk_read_mbps="null" disk_write_mbps="null"
    local curr_disk=""
    if [[ "$metrics" == "all" ]] || echo "$metrics" | grep -q "disk"; then
        curr_disk=$(_disk_stat)
        if [[ -n "$prev_disk" && -n "$curr_disk" ]]; then
            local pr pw cr cw
            read -r pr pw <<< "$prev_disk"
            read -r cr cw <<< "$curr_disk"
            # 1セクター = 512 バイト
            disk_read_mbps=$(awk  "BEGIN{printf \"%.2f\",($cr-$pr)*512/1048576/$interval}")
            disk_write_mbps=$(awk "BEGIN{printf \"%.2f\",($cw-$pw)*512/1048576/$interval}")
        fi
    fi

    # ── ネットワーク ─────────────────────────────────────────
    local net_rx_mbps="null" net_tx_mbps="null"
    local curr_net=""
    if [[ "$metrics" == "all" ]] || echo "$metrics" | grep -q "net"; then
        curr_net=$(_net_stat)
        if [[ -n "$prev_net" && -n "$curr_net" ]]; then
            local pr pt cr ct
            read -r pr pt <<< "$prev_net"
            read -r cr ct <<< "$curr_net"
            net_rx_mbps=$(awk "BEGIN{printf \"%.2f\",($cr-$pr)*8/1048576/$interval}")
            net_tx_mbps=$(awk "BEGIN{printf \"%.2f\",($ct-$pt)*8/1048576/$interval}")
        fi
    fi

    # ── ロードアベレージ ─────────────────────────────────────
    local load1="null" load5="null" load15="null"
    if [[ "$metrics" == "all" ]] || echo "$metrics" | grep -q "load"; then
        local la
        la=$(_load_avg)
        read -r load1 load5 load15 <<< "$la"
    fi

    # ── プロセス数 ───────────────────────────────────────────
    local proc_count="null"
    if [[ "$metrics" == "all" ]] || echo "$metrics" | grep -q "proc"; then
        proc_count=$(_proc_count)
    fi

    # JSON Lines 出力
    # 空文字は JSON の "null" にフォールバック
    _j() { [[ -z "$1" ]] && echo "null" || echo "$1"; }
    printf '{"ts":"%s","hostname":"%s","os":"linux","cpu_pct":%s,"mem_used_pct":%s,"mem_used_gb":%s,"mem_free_gb":%s,"mem_total_gb":%s,"swap_used_pct":%s,"swap_used_gb":%s,"disk_read_mbps":%s,"disk_write_mbps":%s,"net_rx_mbps":%s,"net_tx_mbps":%s,"load_avg_1":%s,"load_avg_5":%s,"load_avg_15":%s,"proc_count":%s}\n' \
        "$ts" "$hostname" \
        "$(_j "$cpu_pct")" "$(_j "$mem_used_pct")" "$(_j "$mem_used_gb")" "$(_j "$mem_free_gb")" "$(_j "$mem_total_gb")" \
        "$(_j "$swap_used_pct")" "$(_j "$swap_used_gb")" \
        "$(_j "$disk_read_mbps")" "$(_j "$disk_write_mbps")" \
        "$(_j "$net_rx_mbps")" "$(_j "$net_tx_mbps")" \
        "$(_j "$load1")" "$(_j "$load5")" "$(_j "$load15")" "$(_j "$proc_count")"

    # 前回値をファイルに保存（1行ごとに1値、区切り文字なしで安全に読み戻せる）
    printf '%s\n%s\n%s\n' "$curr_cpu" "$curr_disk" "$curr_net" >&3
}

# ════════════════════════════════════════════════════════════
# コレクターループ（バックグラウンドで実行）
# ════════════════════════════════════════════════════════════
_run_collector() {
    local session_dir="$1"
    local data_file="${session_dir}/data.jsonl"
    local status_file="${session_dir}/status.txt"
    local interval="${CFG[Interval]}"
    local duration="${CFG[Duration]}"
    local thr_cpu="${CFG[ThresholdCpuPct]}"
    local thr_mem="${CFG[ThresholdMemPct]}"

    log_info "Collector started: session=$session_dir interval=${interval}s duration=${duration}s"

    local start_ts
    start_ts=$(date +%s)
    local prev_cpu="" prev_disk="" prev_net=""
    local sample_count=0
    local prev_vals_file
    prev_vals_file=$(mktemp)

    # SIGTERM / SIGINT 受信時のクリーンアップ
    trap 'log_info "Collector stopped by signal: samples=$sample_count"; rm -f "$prev_vals_file"; exit 0' TERM INT

    # 初回: 前回値の初期化のためにサンプルを読み捨て
    prev_cpu=$(_cpu_stat)
    prev_disk=$(_disk_stat)
    prev_net=$(_net_stat)
    sleep "$interval"

    while true; do
        # サンプル収集（fd3 で前回値を受け取る）
        local sample
        sample=$(collect_sample "$interval" "$prev_cpu" "$prev_disk" "$prev_net" \
                    3>"$prev_vals_file")
        # 前回値を1行ずつ読み戻す（IFS区切りを使わず安全に）
        {
            IFS= read -r prev_cpu
            IFS= read -r prev_disk
            IFS= read -r prev_net
        } < "$prev_vals_file"

        echo "$sample" >> "$data_file"
        sample_count=$(( sample_count + 1 ))

        # ステータスファイル更新（リアルタイム表示用）
        local cpu_v mem_v dr_v dw_v rx_v tx_v ld1_v
        cpu_v=$(echo "$sample" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('cpu_pct','null'))" 2>/dev/null || echo "?")
        mem_v=$(echo "$sample" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('mem_used_pct','null'))" 2>/dev/null || echo "?")
        dr_v=$(echo "$sample"  | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('disk_read_mbps','null'))" 2>/dev/null || echo "?")
        dw_v=$(echo "$sample"  | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('disk_write_mbps','null'))" 2>/dev/null || echo "?")
        rx_v=$(echo "$sample"  | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('net_rx_mbps','null'))" 2>/dev/null || echo "?")
        tx_v=$(echo "$sample"  | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('net_tx_mbps','null'))" 2>/dev/null || echo "?")
        ld1_v=$(echo "$sample" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('load_avg_1','null'))" 2>/dev/null || echo "?")
        local ts_short
        ts_short=$(date '+%H:%M:%S')
        printf '[%s] #%d | CPU:%s%% MEM:%s%% | Disk R:%sMB/s W:%sMB/s | Net Rx:%sMbps Tx:%sMbps | Load:%s\n' \
            "$ts_short" "$sample_count" "$cpu_v" "$mem_v" "$dr_v" "$dw_v" "$rx_v" "$tx_v" "$ld1_v" \
            > "$status_file"

        # しきい値チェック（ログ出力）
        if [[ "$thr_cpu" != "0" ]] && [[ "$cpu_v" != "?" ]] && \
           awk "BEGIN{exit ($cpu_v < $thr_cpu)}"; then
            log_warn "THRESHOLD: cpu_pct=${cpu_v}% >= ${thr_cpu}%"
        fi
        if [[ "$thr_mem" != "0" ]] && [[ "$mem_v" != "?" ]] && \
           awk "BEGIN{exit ($mem_v < $thr_mem)}"; then
            log_warn "THRESHOLD: mem_used_pct=${mem_v}% >= ${thr_mem}%"
        fi

        # 期間チェック
        if [[ "$duration" -gt 0 ]]; then
            local elapsed=$(( $(date +%s) - start_ts ))
            if [[ $elapsed -ge $duration ]]; then
                log_info "Duration reached: samples=$sample_count elapsed=${elapsed}s"
                break
            fi
        fi

        sleep "$interval"
    done

    rm -f "$prev_vals_file"
    log_info "Collector finished: samples=$sample_count"
}

# ════════════════════════════════════════════════════════════
# コマンド: start
# ════════════════════════════════════════════════════════════
cmd_start() {
    local conf_file="$DEFAULT_CONF"
    local opt_interval="" opt_duration="" opt_outdir="" opt_prefix=""

    while getopts "c:i:d:o:p:h" opt; do
        case "$opt" in
            c) conf_file="$OPTARG" ;;
            i) opt_interval="$OPTARG" ;;
            d) opt_duration="$OPTARG" ;;
            o) opt_outdir="$OPTARG" ;;
            p) opt_prefix="$OPTARG" ;;
            h|*) usage ;;
        esac
    done

    load_conf "$conf_file"
    [[ -n "$opt_interval" ]] && CFG[Interval]="$opt_interval"
    [[ -n "$opt_duration" ]] && CFG[Duration]="$opt_duration"
    [[ -n "$opt_outdir"   ]] && CFG[OutputDir]="$opt_outdir"
    [[ -n "$opt_prefix"   ]] && CFG[OutputPrefix]="$opt_prefix"

    # バリデーション
    if ! [[ "${CFG[Interval]}" =~ ^[0-9]+$ ]] || [[ "${CFG[Interval]}" -lt 1 ]]; then
        log_error "Invalid interval: ${CFG[Interval]}"; exit 2
    fi

    # セッションディレクトリ作成
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    local session_dir="${CFG[OutputDir]}/${CFG[OutputPrefix]}_${ts}"
    mkdir -p "$session_dir"
    session_dir=$(cd "$session_dir" && pwd)

    # 設定スナップショット保存
    {
        echo "# Session config snapshot: $ts"
        for k in "${!CFG[@]}"; do echo "$k = ${CFG[$k]}"; done
    } > "${session_dir}/session.conf"

    # コレクター起動（バックグラウンド）
    local log_file="${session_dir}/collector.log"
    local pid_file="${session_dir}/collector.pid"

    _run_collector "$session_dir" \
        >> "$log_file" 2>&1 &
    local pid=$!
    echo "$pid" > "$pid_file"
    disown "$pid" 2>/dev/null || true

    log_info "Collector started: PID=$pid session=$session_dir"
    echo ""
    echo "  セッション開始: ${session_dir}"
    echo "  PID: ${pid}"
    echo "  収集間隔: ${CFG[Interval]}秒 / 期間: $([ "${CFG[Duration]}" -eq 0 ] && echo "stop まで" || echo "${CFG[Duration]}秒")"
    echo ""
    echo "  停止:    perf_monitor.sh stop  ${session_dir}"
    echo "  状態確認: perf_monitor.sh status ${session_dir}"
    echo "  レポート: perf_monitor.sh report ${session_dir}"
    echo ""
}

# ════════════════════════════════════════════════════════════
# コマンド: stop
# ════════════════════════════════════════════════════════════
cmd_stop() {
    local session_dir="${1:-}"

    # セッションディレクトリが指定されていない場合は最新を探す
    # 検索範囲は perf_monitor.conf の OutputDir 配下に限定する
    # （カレント全体を再帰すると別プロジェクトのセッションを誤検出するため）
    if [[ -z "$session_dir" ]]; then
        session_dir=$(_find_latest_session)
        if [[ -z "$session_dir" ]]; then
            log_error "No active session found. Specify session directory."
            exit 4
        fi
    fi

    local pid_file="${session_dir}/collector.pid"
    if [[ ! -f "$pid_file" ]]; then
        log_error "PID file not found: $pid_file"; exit 4
    fi
    local pid
    pid=$(cat "$pid_file")
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid"
        log_info "Sent TERM to PID $pid"
        # 最大 5 秒待機
        for _ in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
    else
        log_warn "PID $pid is not running (already stopped?)"
    fi
    rm -f "$pid_file"
    local data_file="${session_dir}/data.jsonl"
    local count=0
    [[ -f "$data_file" ]] && count=$(wc -l < "$data_file")
    log_info "Collector stopped: session=$session_dir samples=$count"
    echo ""
    echo "  停止完了: ${session_dir}  (${count} サンプル)"
    echo "  レポート生成: perf_monitor.sh report ${session_dir}"
    echo ""
}

# ════════════════════════════════════════════════════════════
# コマンド: report
# ════════════════════════════════════════════════════════════
cmd_report() {
    local session_dir="${1:-}"
    local conf_file="$DEFAULT_CONF"

    shift 2>/dev/null || true
    # OPTIND は前回呼び出しの値を引き継ぐので明示的にリセット
    OPTIND=1
    while getopts "c:h" opt; do
        case "$opt" in c) conf_file="$OPTARG" ;; h|*) usage ;; esac
    done

    if [[ -z "$session_dir" ]]; then
        log_error "Session directory required: perf_monitor.sh report <session_dir>"
        exit 1
    fi

    local data_file="${session_dir}/data.jsonl"
    if [[ ! -f "$data_file" ]]; then
        log_error "Data file not found: $data_file"; exit 4
    fi

    load_conf "$conf_file"
    # セッション設定も読み込む（しきい値など）
    [[ -f "${session_dir}/session.conf" ]] && load_conf "${session_dir}/session.conf"

    if [[ ! -f "$RENDER_PY" ]]; then
        log_error "render_report.py not found: $RENDER_PY"; exit 5
    fi

    local output_html="${session_dir}/report.html"
    log_info "Generating report: $output_html"

    # set -e 下では python3 が失敗した時点で停止するため、if 文の中で実行して
    # 成否で分岐する（旧コードの `if [[ $? -eq 0 ]]` は意味を持たなかった）。
    if PERF_THR_CPU="${CFG[ThresholdCpuPct]}"           \
       PERF_THR_MEM="${CFG[ThresholdMemPct]}"           \
       PERF_THR_DISK_R="${CFG[ThresholdDiskReadMBps]}"  \
       PERF_THR_DISK_W="${CFG[ThresholdDiskWriteMBps]}" \
       PERF_THR_NET_RX="${CFG[ThresholdNetRxMbps]}"     \
       PERF_THR_NET_TX="${CFG[ThresholdNetTxMbps]}"     \
       PERF_THR_LOAD="${CFG[ThresholdLoadAvg1]}"        \
       python3 "$RENDER_PY" "$data_file" "$output_html"; then
        log_info "Report generated: $output_html"
        echo ""
        echo "  レポート生成完了: ${output_html}"
        echo ""
    else
        log_error "render_report.py failed"; exit 5
    fi
}

# ════════════════════════════════════════════════════════════
# コマンド: status
# ════════════════════════════════════════════════════════════
cmd_status() {
    local session_dir="${1:-}"

    # 指定がなければ最新セッションを探す（OutputDir 配下に限定）
    if [[ -z "$session_dir" ]]; then
        session_dir=$(_find_latest_session)
        if [[ -z "$session_dir" ]]; then
            echo "アクティブなセッションが見つかりません"; exit 0
        fi
    fi

    local pid_file="${session_dir}/collector.pid"
    local status_file="${session_dir}/status.txt"
    local data_file="${session_dir}/data.jsonl"

    echo ""
    echo "  セッション: ${session_dir}"

    # 稼働状態
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "  状態: 収集中 (PID=$pid)"
        else
            echo "  状態: 停止済み"
        fi
    else
        echo "  状態: 停止済み"
    fi

    # サンプル数
    local count=0
    [[ -f "$data_file" ]] && count=$(wc -l < "$data_file")
    echo "  サンプル数: ${count}"

    # 最新の値
    if [[ -f "$status_file" ]]; then
        echo ""
        echo "  最新サンプル:"
        cat "$status_file"
    elif [[ -f "$data_file" && "$count" -gt 0 ]]; then
        echo "  最新サンプル: $(tail -1 "$data_file")"
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════
# コマンド: list
# ════════════════════════════════════════════════════════════
cmd_list() {
    echo ""
    echo "  セッション一覧:"
    local found=0
    while IFS= read -r pid_file; do
        local d
        d=$(dirname "$pid_file")
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || echo "?")
        local active="停止済み"
        kill -0 "$pid" 2>/dev/null && active="収集中"
        local count=0
        [[ -f "${d}/data.jsonl" ]] && count=$(wc -l < "${d}/data.jsonl")
        printf "  [%-6s] %s  (%d サンプル)\n" "$active" "$d" "$count"
        found=1
    done < <(find "$(_session_search_root)" -maxdepth 3 -name "collector.pid" 2>/dev/null | sort)
    [[ $found -eq 0 ]] && echo "  (なし)"
    echo ""
}

# ════════════════════════════════════════════════════════════
# エントリポイント
# ════════════════════════════════════════════════════════════
case "${1:-}" in
    start)  shift; cmd_start  "$@" ;;
    stop)   shift; cmd_stop   "${1:-}" ;;
    report) shift; cmd_report "$@" ;;
    status) shift; cmd_status "${1:-}" ;;
    list)   cmd_list ;;
    ""|-h|--help) usage ;;
    *) log_error "Unknown command: $1"; usage ;;
esac
