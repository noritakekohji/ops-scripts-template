#!/usr/bin/env bats
# hanactl.sh の単体テスト
# 本物の HDB / sapcontrol は無いので、引数バリデーションと SID/NN 補完だけ
# 担保する（実 HDB を呼ぶフローは sapctl と同じパターン、結合テスト対象外）。

load test_helper

CTL="${SCRIPTS_DIR}/hana/hanactl.sh"

setup() {
    setup_mock_bin
    make_mock id 0 ""
    make_mock_script sapcontrol '
case "$1 $2 $3 $4" in
  "-nr "*"-function GetProcessList") echo "GREEN"; exit 0 ;;
  *) exit 0 ;;
esac
'
}
teardown() { teardown_mock_bin; }

@test "hanactl: usage" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

@test "hanactl: 不正アクション" {
    run bash "$CTL" foo -S HDB -N 00
    [ "$status" -eq 1 ]
}

@test "hanactl: SID 必須" {
    run bash "$CTL" status -N 00
    [ "$status" -eq 1 ]
}

@test "hanactl: NN 必須" {
    run bash "$CTL" status -S HDB
    [ "$status" -eq 1 ]
}

@test "hanactl: 不正な SID" {
    run bash "$CTL" status -S hdb -N 00
    [ "$status" -eq 1 ]
}

@test "hanactl: 不正な NN" {
    run bash "$CTL" status -S HDB -N 1
    [ "$status" -eq 1 ]
}

@test "hanactl: <sid>adm 不在は exit 2" {
    make_mock id 1 ""
    run bash "$CTL" status -S HDB -N 00
    [ "$status" -eq 2 ]
}

@test "hanactl: config の SID / InstanceNumber を補完" {
    local td
    td=$(make_test_repo)
    mkdir -p "$td/config/dev" "$td/scripts_linux/hana" "$td/scripts_linux/lib"
    cat > "$td/config/dev/hanactl.conf" <<'CONF'
SID = HDB
InstanceNumber = 00
WaitTimeoutSec = 120
CONF
    cp "$CTL" "$td/scripts_linux/hana/hanactl.sh"
    cp "$LIB_DIR"/{logging.sh,config.sh} "$td/scripts_linux/lib/"

    OPS_ENV=dev run bash "$td/scripts_linux/hana/hanactl.sh" status
    # config からの補完が効いて少なくともバリデーションを通過することだけ確認
    # （実 HDB / sapcontrol 呼び出しの成否はモック次第なので緩めに）
    [ "$status" -ne 1 ]
    [[ ! "$output" =~ "Invalid SID" ]]
    [[ ! "$output" =~ "Invalid instance number" ]]

    rm -rf "$td"
}
