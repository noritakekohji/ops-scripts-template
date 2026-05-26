#!/usr/bin/env bash
# ============================================================================
# tests/run_unit.sh  -  Bash 単体テストランナー
#
# 使い方:
#   tests/run_unit.sh                  # bats で全テストを実行
#   tests/run_unit.sh tests/bats/x.bats  # 個別ファイル
#   tests/run_unit.sh --coverage       # kcov でカバレッジを生成
#                                       (results/coverage/bash/index.html)
#
# 前提:
#   - bats-core が PATH に存在（apt: bats / brew: bats-core）
#   - --coverage 時のみ kcov が PATH に存在
#
# 終了コード:
#   0  全テスト合格
#   1  1 件以上失敗
#   10 bats / kcov 不在
# ============================================================================
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TESTS_DIR="${REPO_ROOT}/tests/bats"
RESULTS_DIR="${REPO_ROOT}/tests/results"
COVERAGE_DIR="${RESULTS_DIR}/coverage/bash"

with_coverage=0
explicit_targets=()

for arg in "$@"; do
    case "$arg" in
        --coverage|-c) with_coverage=1 ;;
        --help|-h)
            sed -n '2,18p' "$0"; exit 0 ;;
        *) explicit_targets+=( "$arg" ) ;;
    esac
done

if ! command -v bats >/dev/null 2>&1; then
    echo "[ERROR] bats not found. Install: apt-get install bats / brew install bats-core" >&2
    exit 10
fi

if [[ "$with_coverage" -eq 1 ]] && ! command -v kcov >/dev/null 2>&1; then
    echo "[ERROR] kcov not found (required for --coverage). Install: apt-get install kcov" >&2
    exit 10
fi

# 対象ファイルの決定
if [[ "${#explicit_targets[@]}" -eq 0 ]]; then
    mapfile -t targets < <(find "$TESTS_DIR" -name '*.bats' | sort)
else
    targets=( "${explicit_targets[@]}" )
fi

if [[ "${#targets[@]}" -eq 0 ]]; then
    echo "[WARN] no .bats files found under $TESTS_DIR"
    exit 0
fi

echo "==> Running ${#targets[@]} bats file(s)"
mkdir -p "$RESULTS_DIR"

if [[ "$with_coverage" -eq 1 ]]; then
    rm -rf "$COVERAGE_DIR"
    mkdir -p "$COVERAGE_DIR"
    # kcov 経由で bats を実行。include-pattern でリポジトリ内のスクリプトのみ集計
    kcov \
        --include-path="${REPO_ROOT}/scripts_linux,${REPO_ROOT}/tools" \
        --exclude-path="${REPO_ROOT}/tests" \
        "$COVERAGE_DIR" bats "${targets[@]}"
    rc=$?
    echo "Coverage report: ${COVERAGE_DIR}/index.html"
else
    bats "${targets[@]}"
    rc=$?
fi

exit "$rc"
