# bats 共通ヘルパ
# 各 .bats ファイルから `load test_helper` で読み込む

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB_DIR="$REPO_ROOT/lib/bash"

# テスト用の使い捨て repo root を作って echo する
# 戻り値: 作成したディレクトリのパス
make_test_repo() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.git" "$d/config/common" "$d/config/dev"
    : > "$d/shell-specification.md"
    echo "$d"
}
