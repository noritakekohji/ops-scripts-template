#!/usr/bin/env bats
# nginxctl.sh の単体テスト
# tomcatctl.sh と同じ構造なので、同じ規約に沿って動くことだけ最小限で確認する
# （完全な分岐網羅は tomcatctl.bats に集約）

load test_helper

CTL="${SCRIPTS_DIR}/nginx/nginxctl.sh"

setup() {
    setup_mock_bin
    make_mock_script systemctl '
case "$1" in
  is-active) echo "active"; exit 0 ;;
  list-unit-files) echo "nginx.service enabled enabled"; exit 0 ;;
  *) exit 0 ;;
esac
'
    make_mock timeout 0 ""
}
teardown() { teardown_mock_bin; }

@test "nginxctl: 不正アクションは exit 1" {
    run bash "$CTL" foo nginx
    [ "$status" -eq 1 ]
}

@test "nginxctl: サービス名なしは exit 1" {
    run bash "$CTL" status
    [ "$status" -eq 1 ]
}

@test "nginxctl status: 状態のみ参照（state=active）" {
    run bash "$CTL" status nginx
    [ "$status" -eq 0 ]
    [[ "$output" =~ "state=active" ]]
}

@test "nginxctl start: 既に active ならスキップ" {
    run bash "$CTL" start nginx
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped (idempotent)" ]]
}

@test "nginxctl restart: 状態に関わらず restart を発行" {
    run bash "$CTL" restart nginx
    [ "$status" -eq 0 ]
    grep -E "^systemctl: restart nginx" "$MOCK_LOG"
}

@test "nginxctl: -w -t で timeout 経由になる" {
    make_mock_script systemctl '
state="active"
case "$1" in
  is-active) echo "$state"; exit 0 ;;
  list-unit-files) echo "nginx.service enabled enabled"; exit 0 ;;
  stop) state="inactive"; exit 0 ;;
  *) exit 0 ;;
esac
'
    run bash "$CTL" stop nginx -w -t 20
    [ "$status" -eq 0 ]
    grep -E "^timeout: 20 systemctl stop nginx" "$MOCK_LOG"
}
