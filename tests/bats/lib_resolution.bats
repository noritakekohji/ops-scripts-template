#!/usr/bin/env bats
# lib 解決ロジックの単体テスト
#   - SCRIPT_DIR から親方向に lib/logging.sh または lib/<os>/logging.sh を探す
#   - .ops-deploy-root マーカーで打ち切る
#   - OPS_LIB 環境変数による明示オーバーライド
# 検証は実際の制御スクリプト（tomcatctl.sh）を deploy 後レイアウトに見立てた
# 一時ディレクトリで動かす形で行う。

load test_helper

setup() {
    WORK=$(make_test_workdir)
    setup_mock_bin
    # systemctl をモック化（is-active=active 固定）
    make_mock_script systemctl '
case "$1" in
  is-active) echo "active"; exit 0 ;;
  list-unit-files) echo "Tomcat10.service enabled enabled"; exit 0 ;;
  *) exit 0 ;;
esac
'
    make_mock timeout 0 ""
}
teardown() {
    teardown_mock_bin
    rm -rf "$WORK"
}

# ─── deploy 後フラット構造 (bin/<script>, lib/<file>) ───

@test "lib resolution: flat deploy layout (bin/<script>, lib/logging.sh)" {
    mkdir -p "$WORK/bin" "$WORK/lib"
    cp "$LIB_DIR/logging.sh"  "$WORK/lib/logging.sh"
    cp "$LIB_DIR/config.sh"   "$WORK/lib/config.sh"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/bin/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"

    run bash "$WORK/bin/tomcatctl.sh" start Tomcat10
    [ "$status" -eq 0 ]   # active のため idempotent skip
}

# ─── deploy 後 OS-split (bin/<script>, lib/linux/<file>) ───

@test "lib resolution: OS-split deploy layout (lib/linux/logging.sh)" {
    mkdir -p "$WORK/bin" "$WORK/lib/linux"
    cp "$LIB_DIR/logging.sh"  "$WORK/lib/linux/logging.sh"
    cp "$LIB_DIR/config.sh"   "$WORK/lib/linux/config.sh"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/bin/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"

    run bash "$WORK/bin/tomcatctl.sh" start Tomcat10
    [ "$status" -eq 0 ]
}

# ─── deploy 後にドメイン階層を保持 (bin/<dom>/<script>) ───

@test "lib resolution: deeper deploy layout (bin/<domain>/<script>)" {
    mkdir -p "$WORK/bin/tomcat" "$WORK/lib"
    cp "$LIB_DIR/logging.sh"  "$WORK/lib/logging.sh"
    cp "$LIB_DIR/config.sh"   "$WORK/lib/config.sh"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/bin/tomcat/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"

    run bash "$WORK/bin/tomcat/tomcatctl.sh" start Tomcat10
    [ "$status" -eq 0 ]
}

# ─── OPS_LIB による明示オーバーライド ───

@test "lib resolution: OPS_LIB env var overrides discovery" {
    # スクリプトを変なところに置く（自動検出だと見つからない）
    mkdir -p "$WORK/random/place" "$WORK/explicit_lib"
    cp "$LIB_DIR/logging.sh"  "$WORK/explicit_lib/logging.sh"
    cp "$LIB_DIR/config.sh"   "$WORK/explicit_lib/config.sh"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/random/place/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"   # 検出範囲をここで打ち切る

    OPS_LIB="$WORK/explicit_lib" run bash "$WORK/random/place/tomcatctl.sh" start Tomcat10
    [ "$status" -eq 0 ]
}

# ─── lib が見つからない時の挙動 ───

@test "lib resolution: missing lib -> exit 1 with hint" {
    mkdir -p "$WORK/bin"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/bin/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"   # マーカーで打ち切るので lib は本当に見つからない

    run bash "$WORK/bin/tomcatctl.sh" start Tomcat10
    [ "$status" -eq 1 ]
    [[ "$output" =~ "lib/logging.sh not found" ]]
    [[ "$output" =~ "OPS_LIB" ]]
}

# ─── 配備マーカーが無くてもリポジトリ root が見つかれば動く ───
# （CI でリポジトリ内のテストとして動かす想定の retro-compat 検証）

@test "lib resolution: still works from inside the repo tree" {
    run bash "$SCRIPTS_DIR/tomcat/tomcatctl.sh" start Tomcat10
    [ "$status" -eq 0 ]
}

# ─── config 解決: OPS_CONFIG_DIR ───

@test "config resolution: OPS_CONFIG_DIR overrides discovery" {
    mkdir -p "$WORK/bin" "$WORK/lib" "$WORK/explicit_conf"
    cp "$LIB_DIR/logging.sh"  "$WORK/lib/logging.sh"
    cp "$LIB_DIR/config.sh"   "$WORK/lib/config.sh"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/bin/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"
    cat > "$WORK/explicit_conf/tomcatctl.conf" <<'CONF'
WaitTimeoutSec = 77
Wait = true
CONF

    # active のため start は skipped → "timeoutSec=77" が log に出れば config 読込み成功
    OPS_CONFIG_DIR="$WORK/explicit_conf" run bash "$WORK/bin/tomcatctl.sh" status Tomcat10
    [ "$status" -eq 0 ]
    [[ "$output" =~ "timeoutSec=77" ]]
}

# ─── 配備先のフラット config (config/<name>.conf) を拾う ───

@test "config resolution: deployed flat config (config/<name>.conf)" {
    mkdir -p "$WORK/bin" "$WORK/lib" "$WORK/config"
    cp "$LIB_DIR/logging.sh"  "$WORK/lib/logging.sh"
    cp "$LIB_DIR/config.sh"   "$WORK/lib/config.sh"
    cp "$SCRIPTS_DIR/tomcat/tomcatctl.sh" "$WORK/bin/tomcatctl.sh"
    touch "$WORK/.ops-deploy-root"
    cat > "$WORK/config/tomcatctl.conf" <<'CONF'
WaitTimeoutSec = 99
CONF

    run bash "$WORK/bin/tomcatctl.sh" status Tomcat10
    [ "$status" -eq 0 ]
    [[ "$output" =~ "timeoutSec=99" ]]
}
