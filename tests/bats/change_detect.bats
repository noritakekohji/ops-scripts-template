#!/usr/bin/env bats
# change_detect.sh の単体テスト + compare 結合テスト

load test_helper

CTL="${TOOLS_DIR}/change-detect/change_detect.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

@test "change_detect: 引数なしで usage" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

@test "change_detect: 不明モードは exit 1" {
    run bash "$CTL" foo
    [ "$status" -eq 1 ]
}

@test "change_detect: compare に before/after を渡すと結合エンジンで diff" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" compare "${FIXTURES}/server_info_before.json" "${FIXTURES}/server_info_after.json"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "CHANGE DETECTION REPORT" ]]
}

@test "change_detect: compare に --html で HTML レポート" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    local html="${WORK}/d.html"
    run bash "$CTL" compare "${FIXTURES}/server_info_before.json" "${FIXTURES}/server_info_after.json" --html "$html"
    [ "$status" -eq 0 ]
    [ -f "$html" ]
}

@test "change_detect: compare に不存在ファイル → exit 2" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" compare "$WORK/nope.json" "${FIXTURES}/server_info_after.json"
    [ "$status" -eq 2 ]
}
