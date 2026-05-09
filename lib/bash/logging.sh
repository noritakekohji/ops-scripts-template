# Shared structured-log helpers for ops scripts.
# Source this file from your script:
#   source "$(dirname "$0")/../../../../lib/bash/logging.sh"
#
# Provides:
#   log_debug / log_info / log_warn / log_error   (single-line JSON to stdout/stderr)
#
# JSON encoding uses jq when available; otherwise falls back to a minimal
# escape that handles backslash / double-quote.

_ops_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local actor="${USER:-${LOGNAME:-unknown}}"
    local host
    host=$(hostname 2>/dev/null || echo unknown)
    local script="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-$0}}"

    if command -v jq >/dev/null 2>&1; then
        jq -nc \
            --arg ts "$ts" \
            --arg level "$level" \
            --arg message "$msg" \
            --arg actor "$actor" \
            --arg host "$host" \
            --arg script "$script" \
            --argjson pid "$$" \
            '{timestamp:$ts, level:$level, message:$message, actor:$actor, host:$host, script:$script, pid:$pid}'
    else
        local esc=${msg//\\/\\\\}
        esc=${esc//\"/\\\"}
        printf '{"timestamp":"%s","level":"%s","message":"%s","actor":"%s","host":"%s","script":"%s","pid":%d}\n' \
            "$ts" "$level" "$esc" "$actor" "$host" "$script" "$$"
    fi
}

log_debug() { _ops_log DEBUG "$@"; }
log_info()  { _ops_log INFO  "$@"; }
log_warn()  { _ops_log WARN  "$@" >&2; }
log_error() { _ops_log ERROR "$@" >&2; }
