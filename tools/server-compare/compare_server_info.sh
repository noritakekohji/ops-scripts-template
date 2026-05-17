#!/usr/bin/env bash
# ============================================================================
# compare_server_info.sh  -  Server snapshot comparator (Linux)
#   tools/server-compare/compare_server_info.py の薄いラッパー。
#   Compare-ServerInfo.ps1 と同じ比較ロジック・volatile 除外ルールで動く。
#
# Usage:
#   compare_server_info.sh <before.json> <after.json> [--html out.html]
#                          [--hostname name] [--diff-only] [--no-color]
#
# Exit codes:  0 OK / 1 引数不正 / 2 ファイル不存在 / 10 python3/.py 不在
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMPARE_PY="${SCRIPT_DIR}/compare_server_info.py"

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <before.json> <after.json> [--html out.html] [--hostname name]" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required" >&2; exit 10
fi
if [[ ! -f "$COMPARE_PY" ]]; then
    echo "Error: compare engine not found: $COMPARE_PY" >&2; exit 10
fi

exec python3 "$COMPARE_PY" "$@"
