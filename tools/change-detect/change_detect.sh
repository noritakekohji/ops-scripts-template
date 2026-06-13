#!/usr/bin/env bash
# DEPRECATED: Use tools/server-snapshot/server_snapshot.sh
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="${SCRIPT_DIR}/../server-snapshot/server_snapshot.sh"
if [[ ! -f "$TARGET" ]]; then
    echo "[ERROR] server_snapshot.sh not found: $TARGET" >&2
    echo "        Deploy server-snapshot alongside this tool." >&2
    exit 10
fi
mode="${1:-}"
if [[ -z "$mode" ]]; then
    echo "Usage: $0 <before|after|compare> [options]" >&2
    exit 1
fi
shift
echo "[WARN] change_detect.sh is deprecated. Use: server_snapshot.sh $mode" >&2
exec bash "$TARGET" "$mode" "$@"
