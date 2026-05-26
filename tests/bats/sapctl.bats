#!/usr/bin/env bats
# sapctl.sh の単体テスト（sapcontrol / id を PATH モックで差し替え）

load test_helper

CTL="${SCRIPTS_DIR}/sap/sapctl.sh"

setup() {
    setup_mock_bin
    # id (admin user check) は常に成功
    make_mock id 0 ""
    # sapcontrol の既定: GetSystemInstanceList で GREEN（running）
    make_mock_script sapcontrol '
case "$1 $2 $3 $4" in
  "-nr "*"-function GetSystemInstanceList") echo "GREEN RUNNING"; exit 0 ;;
  "-nr "*"-function GetProcessList")        echo "GREEN running"; exit 0 ;;
  "-nr "*"-function StartSystem")           exit 0 ;;
  "-nr "*"-function StopSystem")            exit 0 ;;
  "-nr "*"-function RestartSystem")         exit 0 ;;
  *) exit 0 ;;
esac
'
}

teardown() { teardown_mock_bin; }

# ─── 引数バリデーション ───────────────────────────────────────────

@test "sapctl: 引数なしで usage" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

@test "sapctl: 不正アクションは exit 1" {
    run bash "$CTL" foo -S S4H -N 00
    [ "$status" -eq 1 ]
}

@test "sapctl: SID 必須" {
    run bash "$CTL" status -N 00
    [ "$status" -eq 1 ]
    [[ "$output" =~ "SAP SID is required" ]]
}

@test "sapctl: インスタンス番号必須" {
    run bash "$CTL" status -S S4H
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Instance number is required" ]]
}

@test "sapctl: 不正な SID は exit 1 (小文字)" {
    run bash "$CTL" status -S s4h -N 00
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid SID" ]]
}

@test "sapctl: 不正な SID は exit 1 (数字始まり)" {
    run bash "$CTL" status -S 1AB -N 00
    [ "$status" -eq 1 ]
}

@test "sapctl: 不正な NN は exit 1 (1桁)" {
    run bash "$CTL" status -S S4H -N 0
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid instance number" ]]
}

@test "sapctl: wait-timeout 範囲外は exit 1" {
    run bash "$CTL" start -S S4H -N 00 -t 30
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Invalid wait timeout" ]]
}

# ─── adm ユーザ不在 ───────────────────────────────────────────────

@test "sapctl: <sid>adm が存在しないと exit 2" {
    make_mock id 1 ""
    run bash "$CTL" status -S S4H -N 00
    [ "$status" -eq 2 ]
}

# ─── sapcontrol / startsap 不在 ────────────────────────────────────

@test "sapctl: sapcontrol も startsap も無いと exit 10" {
    teardown_mock_bin
    setup_mock_bin
    make_mock id 0 ""
    # su のモック: command -v startsap を聞かれたら不在で 1
    make_mock_script su '
# usage: su - <user> -c <cmd>
exit 1
'
    PATH="$MOCK_BIN_DIR:/usr/bin:/bin"
    if command -v sapcontrol >/dev/null 2>&1; then
        skip "sapcontrol present in system PATH"
    fi
    run bash "$CTL" status -S S4H -N 00
    [ "$status" -eq 10 ]
}

# ─── config から SID/NN を補完 ──────────────────────────────────────

@test "sapctl: config の SID / InstanceNumber を CLI 未指定時に使う" {
    local td
    td=$(make_test_repo)
    mkdir -p "$td/config/dev" "$td/scripts_linux/sap" "$td/scripts_linux/lib"
    cat > "$td/config/dev/sapctl.conf" <<'CONF'
SID = S4H
InstanceNumber = 00
WaitTimeoutSec = 120
CONF
    cp "$CTL" "$td/scripts_linux/sap/sapctl.sh"
    cp "$LIB_DIR"/{logging.sh,config.sh} "$td/scripts_linux/lib/"

    OPS_ENV=dev run bash "$td/scripts_linux/sap/sapctl.sh" status
    [ "$status" -eq 0 ]
    # GetSystemInstanceList が SID/NN 込みで呼ばれたこと
    grep -E "^sapcontrol: " "$MOCK_LOG" | grep -E " -nr 00 -function GetSystemInstanceList"

    rm -rf "$td"
}

# ─── status は副作用なし ──────────────────────────────────────────

@test "sapctl status: Start/Stop/Restart が呼ばれない" {
    run bash "$CTL" status -S S4H -N 00
    [ "$status" -eq 0 ]
    ! grep -E "^sapcontrol: .* -function (Start|Stop|Restart)System" "$MOCK_LOG"
}

# ─── 冪等スキップ ─────────────────────────────────────────────────

@test "sapctl start: 既に running ならスキップ" {
    run bash "$CTL" start -S S4H -N 00
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped" ]]
}

@test "sapctl stop: 既に stopped ならスキップ" {
    make_mock_script sapcontrol '
case "$1 $2 $3 $4" in
  "-nr "*"-function GetSystemInstanceList") echo "GRAY STOPPED"; exit 0 ;;
  *) exit 0 ;;
esac
'
    run bash "$CTL" stop -S S4H -N 00
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Skipped" ]]
}
