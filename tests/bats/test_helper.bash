# bats 共通ヘルパ
# 各 .bats ファイルから `load test_helper` で読み込む

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="$REPO_ROOT/scripts_linux/lib"
SCRIPTS_DIR="$REPO_ROOT/scripts_linux"
TOOLS_DIR="$REPO_ROOT/tools"

# テスト用の使い捨て repo root を作って echo する
# 戻り値: 作成したディレクトリのパス
make_test_repo() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.git" "$d/config/default" "$d/config/dev"
    : > "$d/shell-specification.md"
    echo "$d"
}

# 使い捨てワークディレクトリ
make_test_workdir() {
    mktemp -d
}

# ─────────────────────────────────────────────────────────────
# モック機構
#   モックバイナリを置く一時 bin ディレクトリを PATH に前置する。
#   呼び出しごとに引数が ${MOCK_LOG} に追記される。
# ─────────────────────────────────────────────────────────────

# モック環境をセットアップ。 setup_mock_bin を呼ぶと
#   MOCK_BIN_DIR : 新しい一時 bin ディレクトリ（PATH 先頭に追加）
#   MOCK_LOG      : 呼び出しログのファイル
# が設定される。teardown では teardown_mock_bin で後始末。
setup_mock_bin() {
    MOCK_BIN_DIR=$(mktemp -d)
    MOCK_LOG="${MOCK_BIN_DIR}/_calls.log"
    : > "$MOCK_LOG"
    _MOCK_ORIG_PATH="$PATH"
    PATH="$MOCK_BIN_DIR:$PATH"
    export MOCK_BIN_DIR MOCK_LOG PATH
}

teardown_mock_bin() {
    if [[ -n "${_MOCK_ORIG_PATH:-}" ]]; then
        PATH="$_MOCK_ORIG_PATH"
        export PATH
        unset _MOCK_ORIG_PATH
    fi
    [[ -n "${MOCK_BIN_DIR:-}" && -d "$MOCK_BIN_DIR" ]] && rm -rf "$MOCK_BIN_DIR"
    unset MOCK_BIN_DIR MOCK_LOG
}

# モックバイナリを 1 つ作成する。
#   $1 = コマンド名
#   $2 = exit code（既定 0）
#   $3 = stdout に出す文字列（既定 空）
#   $4 = stderr に出す文字列（既定 空）
#
# 呼び出されるたびに "$1: $@" を MOCK_LOG に追記する。
make_mock() {
    local name="$1"
    local rc="${2:-0}"
    local stdout_text="${3:-}"
    local stderr_text="${4:-}"
    local f="${MOCK_BIN_DIR}/${name}"
    cat > "$f" <<EOF
#!/usr/bin/env bash
echo "${name}: \$*" >> "${MOCK_LOG}"
EOF
    if [[ -n "$stdout_text" ]]; then
        printf 'printf %%s %q\n' "$stdout_text" >> "$f"
    fi
    if [[ -n "$stderr_text" ]]; then
        printf 'printf %%s %q >&2\n' "$stderr_text" >> "$f"
    fi
    printf 'exit %s\n' "$rc" >> "$f"
    chmod +x "$f"
}

# より柔軟なモック: 引数によって挙動を変えるヘルパ。
# スクリプト本体を文字列で渡す。$MOCK_LOG への append は自動的に追加される。
make_mock_script() {
    local name="$1"
    local body="$2"
    local f="${MOCK_BIN_DIR}/${name}"
    cat > "$f" <<EOF
#!/usr/bin/env bash
echo "${name}: \$*" >> "${MOCK_LOG}"
${body}
EOF
    chmod +x "$f"
}

# モックが呼ばれた回数を返す
mock_call_count() {
    local name="$1"
    grep -c "^${name}: " "$MOCK_LOG" 2>/dev/null || echo 0
}

# n 番目（1-origin）に呼ばれた引数を取得
mock_call_args() {
    local name="$1"
    local n="${2:-1}"
    grep "^${name}: " "$MOCK_LOG" | sed -n "${n}p" | sed "s/^${name}: //"
}

# モックが少なくとも 1 回呼ばれたか判定
mock_called() {
    local name="$1"
    [[ "$(mock_call_count "$name")" -gt 0 ]]
}
