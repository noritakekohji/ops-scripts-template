#!/usr/bin/env bats
# lib/bash/logging.sh のユニットテスト
#
# 実行方法（リポジトリ root から）:
#     bats tests/bats/logging.bats

load test_helper

setup() {
    # shellcheck source=/dev/null
    source "$LIB_DIR/logging.sh"
}

# ----------------------------------------------------------------------------
# ops_jst_stamp
# ----------------------------------------------------------------------------

@test "ops_jst_stamp: 既定で yyyyMMdd-HHmmss 形式の 15 文字を返す" {
    run ops_jst_stamp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{8}-[0-9]{6}$ ]]
    [ "${#output}" -eq 15 ]
}

@test "ops_jst_stamp: カスタムフォーマットを受け付ける" {
    run ops_jst_stamp '%Y'
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}$ ]]
}

@test "ops_jst_stamp: JST (UTC+9) で時刻を返す" {
    local utc_hour jst_expected stamp_hour
    utc_hour=$(date -u +%H)
    jst_expected=$(( (10#$utc_hour + 9) % 24 ))
    stamp_hour=$(ops_jst_stamp '%H')
    [ "$((10#$stamp_hour))" -eq "$jst_expected" ]
}

# ----------------------------------------------------------------------------
# log_* (出力フォーマット・ストリーム振り分け)
# ----------------------------------------------------------------------------

@test "log_info: stdout に [INFO ] でタグ付けされて書き込まれる" {
    run log_info "hello"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[INFO\ \] ]]
    [[ "$output" =~ hello$ ]]
}

@test "log_info: 仕様フォーマットに一致する" {
    # [YYYY-MM-DD hh:mm:ss] [INFO ] (shellname:pid) message
    run log_info "fmt-check"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^\[[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\]\ \[INFO\ \]\ \([^:]+:[0-9]+\)\ fmt-check$ ]]
}

@test "log_warn: stderr に書き込まれ、stdout には出ない" {
    local stdout_out stderr_out
    stdout_out=$(log_warn "warn-msg" 2>/dev/null)
    stderr_out=$(log_warn "warn-msg" 2>&1 1>/dev/null)
    [ -z "$stdout_out" ]
    [[ "$stderr_out" =~ \[WARN\ \] ]]
    [[ "$stderr_out" =~ warn-msg$ ]]
}

@test "log_error: stderr に [ERROR] タグで書き込まれる" {
    local stderr_out
    stderr_out=$(log_error "err-msg" 2>&1 1>/dev/null)
    [[ "$stderr_out" =~ \[ERROR\] ]]
    [[ "$stderr_out" =~ err-msg$ ]]
}

@test "log_debug: stdout に [DEBUG] タグで書き込まれる" {
    run log_debug "debug-msg"
    [ "$status" -eq 0 ]
    [[ "$output" =~ \[DEBUG\] ]]
}

@test "log_*: メッセージ中の改行は単一スペースに置換される" {
    local out
    out=$(log_info $'line1\nline2')
    [[ "$out" =~ "line1 line2" ]]
}
