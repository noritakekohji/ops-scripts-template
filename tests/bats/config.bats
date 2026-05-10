#!/usr/bin/env bats
# lib/bash/config.sh のユニットテスト
#
# 各テストでは make_test_repo で隔離 repo を作り、3 番目の引数で
# load_ops_config に渡してテスト用 config だけを読ませる。
#
# 実行方法（リポジトリ root から）:
#     bats tests/bats/config.bats

load test_helper

setup() {
    # shellcheck source=/dev/null
    source "$LIB_DIR/logging.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/config.sh"
    TEST_REPO=$(make_test_repo)
}

teardown() {
    [ -n "${TEST_REPO:-}" ] && [ -d "$TEST_REPO" ] && rm -rf "$TEST_REPO"
}

# ----------------------------------------------------------------------------
# load_ops_config: env 未指定 → config/default/ のみ
# ----------------------------------------------------------------------------

@test "env 未指定: default/global.conf のキーを読み込む" {
    cat > "$TEST_REPO/config/default/global.conf" <<'EOF'
Region = ap-northeast-1
Wait   = true
EOF
    load_ops_config 'foo' '' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "ap-northeast-1" ]
    [ "${OPS_CONFIG[Wait]}"   = "true" ]
}

@test "env 未指定: default/<name>.conf が default/global.conf を上書きする" {
    echo "Region = ap-northeast-1" > "$TEST_REPO/config/default/global.conf"
    echo "Region = us-east-1"      > "$TEST_REPO/config/default/foo.conf"
    load_ops_config 'foo' '' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "us-east-1" ]
}

# ----------------------------------------------------------------------------
# load_ops_config: env 指定 → config/<env>/ のみ（default は読まない）
# ----------------------------------------------------------------------------

@test "env 指定: config/<env>/ のキーを読み込む" {
    echo "Region = eu-west-1" > "$TEST_REPO/config/dev/foo.conf"
    load_ops_config 'foo' 'dev' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "eu-west-1" ]
}

@test "env 指定: config/default/ のキーは読まない" {
    echo "Region = ap-northeast-1" > "$TEST_REPO/config/default/foo.conf"
    echo "Region = eu-west-1"      > "$TEST_REPO/config/dev/foo.conf"
    load_ops_config 'foo' 'dev' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "eu-west-1" ]
}

@test "env 指定: default にしかないキーは取得されない" {
    echo "Region = ap-northeast-1" > "$TEST_REPO/config/default/foo.conf"
    # dev/ には foo.conf なし → OPS_CONFIG は空になる
    load_ops_config 'foo' 'dev' "$TEST_REPO"
    [ "${#OPS_CONFIG[@]}" -eq 0 ]
}

@test "env 指定: <env>/global.conf のキーを読み込む" {
    echo "Wait = true" > "$TEST_REPO/config/dev/global.conf"
    load_ops_config 'foo' 'dev' "$TEST_REPO"
    [ "${OPS_CONFIG[Wait]}" = "true" ]
}

@test "env 指定: <env>/<name>.conf が <env>/global.conf を上書きする" {
    echo "Region = eu-west-1"  > "$TEST_REPO/config/dev/global.conf"
    echo "Region = ap-south-1" > "$TEST_REPO/config/dev/foo.conf"
    load_ops_config 'foo' 'dev' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "ap-south-1" ]
}

# ----------------------------------------------------------------------------
# load_ops_config: パース仕様
# ----------------------------------------------------------------------------

@test "コメント行と空行は無視される" {
    cat > "$TEST_REPO/config/default/foo.conf" <<'EOF'
# 行頭コメント

Region = ap-northeast-1

# 別のコメント
Wait = true
EOF
    load_ops_config 'foo' '' "$TEST_REPO"
    [ "${#OPS_CONFIG[@]}" -eq 2 ]
    [ "${OPS_CONFIG[Region]}" = "ap-northeast-1" ]
}

@test "値の前後の引用符は除去される（ダブル / シングル）" {
    cat > "$TEST_REPO/config/default/foo.conf" <<'EOF'
Description = "weekly backup"
Note        = 'with spaces'
EOF
    load_ops_config 'foo' '' "$TEST_REPO"
    [ "${OPS_CONFIG[Description]}" = "weekly backup" ]
    [ "${OPS_CONFIG[Note]}"        = "with spaces" ]
}

@test "前後空白は trim される" {
    echo "   Region   =   ap-northeast-1   " > "$TEST_REPO/config/default/foo.conf"
    load_ops_config 'foo' '' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "ap-northeast-1" ]
}

@test "ファイルが存在しない場合は空の OPS_CONFIG を返す" {
    load_ops_config 'no-such-script' '' "$TEST_REPO"
    [ "${#OPS_CONFIG[@]}" -eq 0 ]
}

@test "OPS_CONFIG_ENV に env 名が設定される" {
    load_ops_config 'foo' 'dev' "$TEST_REPO"
    [ "$OPS_CONFIG_ENV" = "dev" ]
}

@test "OPS_ENV 環境変数からも env を解決できる" {
    echo "Region = eu-west-1" > "$TEST_REPO/config/dev/foo.conf"
    OPS_ENV=dev load_ops_config 'foo' '' "$TEST_REPO"
    [ "${OPS_CONFIG[Region]}" = "eu-west-1" ]
}
