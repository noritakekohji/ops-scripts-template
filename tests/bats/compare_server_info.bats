#!/usr/bin/env bats
# compare_server_info.py 統合テスト (fixture JSON でカテゴリ比較・HTML 生成)

load test_helper

CTL="${TOOLS_DIR}/server-snapshot/compare_server_info.py"
FIXTURES="${REPO_ROOT}/tests/fixtures"
BEFORE="${FIXTURES}/server_info_before.json"
AFTER="${FIXTURES}/server_info_after.json"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

@test "compare_server_info: ヘルプを出す" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" --help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Compare two server-info snapshots" ]]
}

@test "compare_server_info: 2 つの JSON 引数を取って実行する" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" "$BEFORE" "$AFTER" --no-color
    [ "$status" -eq 0 ]
    [[ "$output" =~ "CHANGE DETECTION REPORT" ]]
}

@test "compare_server_info: services の追加/削除/変更を検出" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" "$BEFORE" "$AFTER" --no-color
    # cron が active -> inactive (changed)
    [[ "$output" =~ "CHANGED" ]] && [[ "$output" =~ "cron" ]]
    # new-svc が ADDED
    [[ "$output" =~ "ADDED" ]] && [[ "$output" =~ "new-svc" ]]
    # old-svc が REMOVED
    [[ "$output" =~ "REMOVED" ]] && [[ "$output" =~ "old-svc" ]]
}

@test "compare_server_info: packages の追加/バージョン変更を検出" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" "$BEFORE" "$AFTER" --no-color
    [[ "$output" =~ "openssh-server" ]]  # version 変更
    [[ "$output" =~ "vim" ]]              # added
}

@test "compare_server_info: filesystem は volatile (used_gb/free_gb/used_pct) を無視" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" "$BEFORE" "$AFTER" --no-color --diff-only
    # before/after で used_gb / free_gb / used_pct は変わっているが
    # 比較ロジックは stable field (total_gb / fstype) のみ比較するため、
    # filesystem の changed には乗らないはず
    if [[ "$output" =~ "filesystem" ]]; then
        # filesystem セクションがあっても、used_gb=... の changed は出ない
        ! [[ "$output" =~ "used_gb=20" ]]
    fi
}

@test "compare_server_info: os は volatile (free_memory_gb 等) を無視" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" "$BEFORE" "$AFTER" --no-color --diff-only
    # free_memory_gb 4.5 -> 4.2 は無視され、changed には現れない
    ! [[ "$output" =~ "free_memory_gb" ]]
    # 一方 kernel は changed として出る
    [[ "$output" =~ "kernel" ]]
}

@test "compare_server_info: --html で HTML レポートが生成される" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local out="$WORK/diff.html"
    run python3 "$CTL" "$BEFORE" "$AFTER" --no-color --html "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q -i "Change Detection Report" "$out"
}

@test "compare_server_info: 不存在の before ファイル → exit 2" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    run python3 "$CTL" "$WORK/nope.json" "$AFTER" --no-color
    [ "$status" -eq 2 ]
}
