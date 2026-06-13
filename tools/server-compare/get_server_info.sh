#!/usr/bin/env bash
# DEPRECATED: Use tools/server-snapshot/server_snapshot.sh collect
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET="${SCRIPT_DIR}/../server-snapshot/server_snapshot.sh"
if [[ ! -f "$TARGET" ]]; then
    echo "[ERROR] server_snapshot.sh not found: $TARGET" >&2
    echo "        Deploy server-snapshot alongside this tool." >&2
    exit 10
fi
echo "[WARN] get_server_info.sh is deprecated. Use: server_snapshot.sh collect" >&2
exec bash "$TARGET" collect "$@"
