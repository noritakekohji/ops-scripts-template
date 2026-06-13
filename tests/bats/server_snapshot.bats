#!/usr/bin/env bats
# server_snapshot.sh の単体テスト + compare 結合テスト

load test_helper

CTL="${TOOLS_DIR}/server-snapshot/server_snapshot.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

@test "server_snapshot: 引数なしで usage (exit 1)" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

@test "server_snapshot: 不明サブコマンドは exit 1" {
    run bash "$CTL" foo
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Unknown subcommand" ]]
}

@test "server_snapshot: collect -c os で JSON を生成する" {
    if [[ "$(uname -s)" != "Linux" ]]; then skip "Linux only"; fi
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" collect -c os -o "$WORK/snap.json"
    [ "$status" -eq 0 ]
    [ -s "$WORK/snap.json" ]
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert 'meta' in d, 'meta key missing'
assert 'os' in d, 'os category missing'
assert d['meta']['categories'] == ['os'], 'unexpected categories: ' + str(d['meta']['categories'])
" "$WORK/snap.json"
}

@test "server_snapshot: compare <before> <after> で差分レポート" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" compare "${FIXTURES}/server_info_before.json" "${FIXTURES}/server_info_after.json"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "CHANGE DETECTION REPORT" ]]
}

@test "server_snapshot: compare に不存在ファイル → exit 2" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    cd "$WORK"
    run bash "$CTL" compare "$WORK/nope.json" "${FIXTURES}/server_info_after.json"
    [ "$status" -eq 2 ]
}

@test "server_snapshot: list は exit 0" {
    cd "$WORK"
    run bash "$CTL" list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "No snapshots found" ]]
}
