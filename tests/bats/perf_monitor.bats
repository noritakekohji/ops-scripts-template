#!/usr/bin/env bats
# perf_monitor.sh の単体テスト + 短時間結合テスト

load test_helper

TOOL_DIR="${TOOLS_DIR}/perf-monitor"
SH="${TOOL_DIR}/perf_monitor.sh"
PY="${TOOL_DIR}/render_report.py"

setup() {
    WORK=$(make_test_workdir)
}
teardown() {
    # 残っているコレクタ PID があれば停止
    if [[ -d "$WORK" ]]; then
        find "$WORK" -name 'collector.pid' -exec sh -c 'kill "$(cat "$1")" 2>/dev/null || true' _ {} \;
    fi
    rm -rf "$WORK"
}

# ─── 引数バリデーション ───────────────────────────────────────────

@test "perf_monitor: 不明なサブコマンドは exit 1" {
    run bash "$SH" foo
    [ "$status" -eq 1 ]
}

@test "perf_monitor: report に session_dir を渡さないと exit 1" {
    run bash "$SH" report
    [ "$status" -eq 1 ]
}

# ─── data.jsonl が無い session_dir に report → exit 4 ────────────

@test "perf_monitor: data.jsonl が無い session_dir で report は exit 4" {
    mkdir -p "$WORK/empty_session"
    run bash "$SH" report "$WORK/empty_session"
    [ "$status" -eq 4 ]
}

# ─── 結合: start → 数サンプル → stop → report ─────────────────────

@test "perf_monitor: start/stop/report の end-to-end (短時間)" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    # 1 秒間隔・3 秒で自動停止（duration が 0 でないと指定間隔の経過後に自動 stop）
    run bash "$SH" start -i 1 -d 3 -o "$WORK"
    [ "$status" -eq 0 ]
    # session ディレクトリを検出
    local sess
    sess=$(find "$WORK" -maxdepth 1 -type d -name 'perf_*' | head -1)
    [ -n "$sess" ]
    # コレクタが終了するまで少し待つ
    sleep 4
    [ -f "$sess/data.jsonl" ]
    # サンプルが 1 件以上書かれている
    [ "$(wc -l < "$sess/data.jsonl")" -ge 1 ]
    # report 生成
    run bash "$SH" report "$sess"
    [ "$status" -eq 0 ]
    [ -f "$sess/report.html" ]
    # HTML らしいキーワードが入っている
    grep -q -i "performance monitor report" "$sess/report.html"
}

# ─── status は data ファイル不在でも落ちない ─────────────────────

@test "perf_monitor: アクティブセッション無しでも status は exit 0" {
    run bash "$SH" status "$WORK"
    [ "$status" -eq 0 ]
}

# ─── list は空でも 0 ─────────────────────────────────────────────

@test "perf_monitor: list はセッション無しでも exit 0" {
    cd "$WORK"
    run bash "$SH" list
    [ "$status" -eq 0 ]
}

# ─── render_report.py 単独動作（カテゴリ統計）────────────────────

@test "perf_monitor: render_report.py が JSON Lines から HTML を生成" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local data="$WORK/data.jsonl"
    local out="$WORK/report.html"
    # 最小限のサンプル 5 行
    cat > "$data" <<'EOF'
{"ts":"2026-05-01T10:00:00+09:00","hostname":"h","os":"linux","cpu_pct":10,"mem_used_pct":40,"mem_used_gb":4,"mem_free_gb":6,"mem_total_gb":10,"swap_used_pct":0,"swap_used_gb":0,"disk_read_mbps":1,"disk_write_mbps":1,"net_rx_mbps":1,"net_tx_mbps":1,"load_avg_1":0.5,"load_avg_5":0.3,"load_avg_15":0.2,"proc_count":100}
{"ts":"2026-05-01T10:00:01+09:00","hostname":"h","os":"linux","cpu_pct":50,"mem_used_pct":60,"mem_used_gb":6,"mem_free_gb":4,"mem_total_gb":10,"swap_used_pct":0,"swap_used_gb":0,"disk_read_mbps":2,"disk_write_mbps":2,"net_rx_mbps":2,"net_tx_mbps":2,"load_avg_1":1.0,"load_avg_5":0.5,"load_avg_15":0.3,"proc_count":102}
{"ts":"2026-05-01T10:00:02+09:00","hostname":"h","os":"linux","cpu_pct":90,"mem_used_pct":85,"mem_used_gb":8,"mem_free_gb":2,"mem_total_gb":10,"swap_used_pct":0,"swap_used_gb":0,"disk_read_mbps":3,"disk_write_mbps":3,"net_rx_mbps":3,"net_tx_mbps":3,"load_avg_1":2.0,"load_avg_5":1.0,"load_avg_15":0.5,"proc_count":105}
EOF
    PERF_THR_CPU=80 PERF_THR_MEM=80 python3 "$PY" "$data" "$out"
    [ -f "$out" ]
    grep -q -i "<canvas" "$out"
    # しきい値超過カウントが反映される
    grep -E "しきい値超過" "$out"
}
