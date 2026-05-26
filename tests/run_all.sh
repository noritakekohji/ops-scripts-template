#!/usr/bin/env bash
# ============================================================================
# tests/run_all.sh  -  Bash 側を全て実行（単体 + 結合）
#
# 使い方:
#   tests/run_all.sh             # unit + integration
#   tests/run_all.sh --unit-only
#   tests/run_all.sh --integration-only
#   tests/run_all.sh --coverage  # kcov で単体テストを計測
# ============================================================================
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)

run_unit=1
run_integration=1
coverage_flag=""

for arg in "$@"; do
    case "$arg" in
        --unit-only)        run_integration=0 ;;
        --integration-only) run_unit=0 ;;
        --coverage|-c)      coverage_flag="--coverage" ;;
        --help|-h)          sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "[ERROR] unknown arg: $arg" >&2; exit 1 ;;
    esac
done

failures=0

if [[ "$run_unit" -eq 1 ]]; then
    echo "========================================================"
    echo "  UNIT TESTS (bats)"
    echo "========================================================"
    if ! "${REPO_ROOT}/tests/run_unit.sh" ${coverage_flag:+$coverage_flag}; then
        failures=$((failures+1))
    fi
fi

if [[ "$run_integration" -eq 1 ]]; then
    echo ""
    echo "========================================================"
    echo "  INTEGRATION TESTS (bats, with real file ops)"
    echo "========================================================"
    if [[ -d "${REPO_ROOT}/tests/integration" ]]; then
        mapfile -t integ_files < <(find "${REPO_ROOT}/tests/integration" -name '*.bats' | sort)
        if [[ "${#integ_files[@]}" -gt 0 ]]; then
            if ! bats "${integ_files[@]}"; then
                failures=$((failures+1))
            fi
        else
            echo "(no integration tests under tests/integration)"
        fi
    else
        echo "(tests/integration/ does not exist; skip)"
    fi
fi

if [[ "$failures" -gt 0 ]]; then
    echo ""
    echo "FAILED: $failures suite(s) had failures"
    exit 1
fi

echo ""
echo "ALL TESTS PASSED"
exit 0
