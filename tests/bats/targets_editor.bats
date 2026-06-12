#!/usr/bin/env bats
# targets-editor の出力形式契約テスト:
# エクスポートされる lst が check_network_connectivity.sh で受理されること

load test_helper

CTL="${TOOLS_DIR}/network-check/check_network_connectivity.sh"
FIXTURE="${BATS_TEST_DIRNAME}/../fixtures/targets_editor_export_sample.lst"

@test "targets-editor: fixture は CRLF を含まない" {
    ! grep -q $'\r' "$FIXTURE"
}

@test "targets-editor: fixture は UTF-8 BOM を含まない" {
    [ "$(head -c 3 "$FIXTURE")" != $'\xef\xbb\xbf' ]
}

@test "targets-editor: fixture を network-check パーサが受理する" {
    if ! command -v ping >/dev/null; then skip "ping required"; fi
    run timeout 60 bash "$CTL" -l "$FIXTURE" -c 1 -t 2
    # 127.0.0.1 のみなので OK(0) または Warning(1) を許容
    [ "$status" -le 1 ]
}
