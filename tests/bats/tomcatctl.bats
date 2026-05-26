#!/usr/bin/env bats
# tomcatctl.sh の単体テスト（systemctl は PATH モックで差し替え）

load test_helper

CTL="${SCRIPTS_DIR}/tomcat/tomcatctl.sh"

setup() {
    setup_mock_bin
    # 既定: active のサービスとして応答する systemctl モック
    make_mock_script systemctl '
case "$1" in
  is-active)   echo "active";    exit 0 ;;
  show)        echo "running";   exit 0 ;;
  list-unit-files) echo "tomcat.service enabled enabled"; exit 0 ;;
  status)      exit 0 ;;
  start|stop|restart) exit 0 ;;
  *) exit 0 ;;
esac
'
    make_mock timeout 0 ""
}

teardown() {
    teardown_mock_bin
}

# ─── 引数バリデーション ───────────────────────────────────────────

@test "tomcatctl: 引数なしで usage を表示して 1 を返す" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

@test "tomcatctl: 不正なアクションは exit 1" {
    run bash "$CTL" foo Tomcat10
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid action" ]]
}

@test "tomcatctl: -h で usage" {
    run bash "$CTL" -h
    [ "$status" -eq 1 ]
}

@test "tomcatctl: サービス名なしは exit 1" {
    run bash "$CTL" status
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Missing service name" ]]
}

@test "tomcatctl: 不正なサービス名 (記号) は exit 1" {
    run bash "$CTL" status "bad;name"
    [ "$status" -eq 1 ]
}

@test "tomcatctl: wait-timeout が範囲外は exit 1" {
    run bash "$CTL" start Tomcat10 -t 9999
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid wait timeout" ]]
}

# ─── 前提コマンド ─────────────────────────────────────────────────

@test "tomcatctl: systemctl が PATH に無いと exit 10" {
    teardown_mock_bin
    setup_mock_bin
    PATH="$MOCK_BIN_DIR:/usr/bin:/bin"
    if command -v systemctl >/dev/null 2>&1; then
        skip "systemctl present in system PATH"
    fi
    run bash "$CTL" status Tomcat10
    [ "$status" -eq 10 ]
    [[ "$output" =~ "systemctl not installed" ]]
}

# ─── サービス不在 ─────────────────────────────────────────────────

@test "tomcatctl: サービス不在は exit 2" {
    make_mock_script systemctl '
case "$1" in
  list-unit-files) echo ""; exit 0 ;;
  status) exit 4 ;;
  *) exit 0 ;;
esac
'
    run bash "$CTL" status NoSuchService
    [ "$status" -eq 2 ]
    [[ "$output" =~ "Service not found" ]]
}

# ─── 冪等スキップ ─────────────────────────────────────────────────

@test "tomcatctl start: 既に active ならスキップ (exit 0)" {
    run bash "$CTL" start Tomcat10
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped (idempotent)" ]]
    [[ "$output" =~ "state=active" ]]
}

@test "tomcatctl stop: 既に inactive ならスキップ" {
    make_mock_script systemctl '
case "$1" in
  is-active) echo "inactive"; exit 3 ;;
  list-unit-files) echo "tomcat.service enabled enabled"; exit 0 ;;
  *) exit 0 ;;
esac
'
    run bash "$CTL" stop Tomcat10
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped (idempotent)" ]]
}

# ─── status は副作用なし ──────────────────────────────────────────

@test "tomcatctl status: systemctl start/stop/restart は呼ばれない" {
    run bash "$CTL" status Tomcat10
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Status: service=Tomcat10" ]]
    # systemctl start/stop/restart が呼ばれていないこと
    ! grep -E "^systemctl: (start|stop|restart) " "$MOCK_LOG"
}

# ─── 正常系（active からの stop）───────────────────────────────────

@test "tomcatctl stop (when active): systemctl stop が呼ばれる" {
    make_mock_script systemctl '
state="active"
case "$1" in
  is-active) echo "$state"; exit 0 ;;
  list-unit-files) echo "tomcat.service enabled enabled"; exit 0 ;;
  stop) state="inactive"; exit 0 ;;
  *) exit 0 ;;
esac
'
    run bash "$CTL" stop Tomcat10
    [ "$status" -eq 0 ]
    [[ "$output" =~ "stop initiated" ]]
}

# ─── restart は冪等スキップなし ───────────────────────────────────

@test "tomcatctl restart: 状態に関わらず systemctl restart を呼ぶ" {
    run bash "$CTL" restart Tomcat10
    [ "$status" -eq 0 ]
    grep -E "^systemctl: restart Tomcat10" "$MOCK_LOG"
}

# ─── -w / -t / config 連携 ─────────────────────────────────────────

@test "tomcatctl -w: timeout コマンドが使われる" {
    make_mock_script systemctl '
state="active"
case "$1" in
  is-active) echo "$state"; exit 0 ;;
  list-unit-files) echo "tomcat.service enabled enabled"; exit 0 ;;
  stop) state="inactive"; exit 0 ;;
  *) exit 0 ;;
esac
'
    run bash "$CTL" stop Tomcat10 -w -t 30
    [ "$status" -eq 0 ]
    grep -E "^timeout: 30 systemctl stop Tomcat10" "$MOCK_LOG"
}

@test "tomcatctl: config から Wait/WaitTimeoutSec を読む" {
    # repo root を一時的に差し替えるため OPS_ENV=dev で config/dev を使う
    local td
    td=$(make_test_repo)
    mkdir -p "$td/config/dev"
    cat > "$td/config/dev/tomcatctl.conf" <<'CONF'
Wait = true
WaitTimeoutSec = 45
CONF
    # スクリプトを td にコピーして lib も配置する
    mkdir -p "$td/scripts_linux/tomcat" "$td/scripts_linux/lib"
    cp "$CTL" "$td/scripts_linux/tomcat/tomcatctl.sh"
    cp "$LIB_DIR/logging.sh" "$LIB_DIR/config.sh" "$td/scripts_linux/lib/"

    make_mock_script systemctl '
state="active"
case "$1" in
  is-active) echo "$state"; exit 0 ;;
  list-unit-files) echo "tomcat.service enabled enabled"; exit 0 ;;
  stop) state="inactive"; exit 0 ;;
  *) exit 0 ;;
esac
'
    OPS_ENV=dev run bash "$td/scripts_linux/tomcat/tomcatctl.sh" stop Tomcat10
    [ "$status" -eq 0 ]
    grep -E "^timeout: 45 systemctl stop Tomcat10" "$MOCK_LOG"

    rm -rf "$td"
}
