# systemd 制御スクリプト (tomcatctl / nginxctl / mysqlctl / postgresqlctl /
# sqlserverctl / hanactl) の共通テスト関数。
#
# 使い方:
#   load test_helper
#   load systemd_ctl_helpers
#   @test "mysqlctl: usage" { ctl_assert_usage "$SCRIPTS_DIR/mysql/mysqlctl.sh"; }

# 既定の systemctl モック: is-active は 'active'、その他は exit 0
_default_systemctl_mock() {
    local unit_name="${1:-test.service}"
    make_mock_script systemctl "
case \"\$1\" in
  is-active) echo \"active\"; exit 0 ;;
  list-unit-files) echo \"${unit_name} enabled enabled\"; exit 0 ;;
  *) exit 0 ;;
esac
"
}

# 引数なしで usage に落ちる
ctl_assert_usage() {
    local ctl="$1"
    run bash "$ctl"
    [ "$status" -eq 1 ]
}

# 不正アクション
ctl_assert_invalid_action() {
    local ctl="$1"
    local svc="${2:-svc}"
    run bash "$ctl" foo "$svc"
    [ "$status" -eq 1 ]
}

# サービス名なし
ctl_assert_missing_service() {
    local ctl="$1"
    run bash "$ctl" status
    [ "$status" -eq 1 ]
}

# systemctl が PATH に無いと exit 10
ctl_assert_no_systemctl() {
    local ctl="$1"
    local svc="${2:-svc}"
    teardown_mock_bin
    setup_mock_bin
    PATH="$MOCK_BIN_DIR"
    run bash "$ctl" status "$svc"
    [ "$status" -eq 10 ]
}

# サービス不在
ctl_assert_service_not_found() {
    local ctl="$1"
    local svc="${2:-NoSuchService}"
    make_mock_script systemctl '
case "$1" in
  list-unit-files) echo ""; exit 0 ;;
  status) exit 4 ;;
  *) exit 0 ;;
esac
'
    run bash "$ctl" status "$svc"
    [ "$status" -eq 2 ]
}

# start active → skipped
ctl_assert_idempotent_start() {
    local ctl="$1"
    local svc="${2:-svc}"
    local unit="${3:-${svc}.service}"
    _default_systemctl_mock "$unit"
    run bash "$ctl" start "$svc"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped (idempotent)" ]]
}

# stop inactive → skipped
ctl_assert_idempotent_stop() {
    local ctl="$1"
    local svc="${2:-svc}"
    local unit="${3:-${svc}.service}"
    make_mock_script systemctl "
case \"\$1\" in
  is-active) echo \"inactive\"; exit 3 ;;
  list-unit-files) echo \"${unit} enabled enabled\"; exit 0 ;;
  *) exit 0 ;;
esac
"
    run bash "$ctl" stop "$svc"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped (idempotent)" ]]
}

# restart は冪等スキップなし
ctl_assert_restart_always_runs() {
    local ctl="$1"
    local svc="${2:-svc}"
    local unit="${3:-${svc}.service}"
    _default_systemctl_mock "$unit"
    run bash "$ctl" restart "$svc"
    [ "$status" -eq 0 ]
    grep -E "^systemctl: restart " "$MOCK_LOG" >/dev/null
}

# status は副作用なし
ctl_assert_status_readonly() {
    local ctl="$1"
    local svc="${2:-svc}"
    local unit="${3:-${svc}.service}"
    _default_systemctl_mock "$unit"
    run bash "$ctl" status "$svc"
    [ "$status" -eq 0 ]
    ! grep -E "^systemctl: (start|stop|restart) " "$MOCK_LOG"
}

# -w -t で timeout 経由
ctl_assert_wait_uses_timeout() {
    local ctl="$1"
    local svc="${2:-svc}"
    local unit="${3:-${svc}.service}"
    make_mock_script systemctl "
state=\"active\"
case \"\$1\" in
  is-active) echo \"\$state\"; exit 0 ;;
  list-unit-files) echo \"${unit} enabled enabled\"; exit 0 ;;
  stop) state=\"inactive\"; exit 0 ;;
  *) exit 0 ;;
esac
"
    make_mock timeout 0 ""
    run bash "$ctl" stop "$svc" -w -t 30
    [ "$status" -eq 0 ]
    grep -E "^timeout: 30 systemctl stop " "$MOCK_LOG" >/dev/null
}
