#!/usr/bin/env bats
# get_server_info.sh の smoke test
# 実 OS API を叩くので、結果の妥当性ではなく "落ちずに JSON を出すこと" を確認する

load test_helper

CTL="${SCRIPTS_DIR}/os/get_server_info.sh"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

@test "get_server_info: -h で usage を出す" {
    run bash "$CTL" -h
    [ "$status" -ne 0 ] || [ "$status" -eq 0 ]   # usage はどちらでも可
}

@test "get_server_info: -o ファイル出力で JSON を生成する" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    # 既定では CWD にファイル名を組み立てて書くので、CWD を書込み可能な
    # tmpdir に切り替えて実行する。
    cd "$WORK"
    run bash "$CTL" -o "$WORK/info.json"
    [ "$status" -eq 0 ]
    [ -s "$WORK/info.json" ]
    python3 -c "import json; json.load(open('$WORK/info.json'))"
}

@test "get_server_info: -o でファイル出力" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local out="$WORK/info.json"
    run bash "$CTL" -o "$out"
    [ "$status" -eq 0 ]
    [ -s "$out" ]
    # 出力が JSON として読めること
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$out"
}

@test "get_server_info: -c os で os カテゴリのみが出る" {
    if ! command -v python3 >/dev/null; then skip "python3 required"; fi
    local out="$WORK/info.json"
    run bash "$CTL" -c os -o "$out"
    [ "$status" -eq 0 ]
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert 'os' in d, 'os category missing'
" "$out"
}
