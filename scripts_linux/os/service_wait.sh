#!/usr/bin/env bash
# ============================================================================
# service_wait.sh
#   Wait until Ping/TCP/HTTP targets in a list file pass N consecutive rounds.
#   (Linux / Bash version)
#
# Usage:
#   service_wait.sh <targets-list-file>
#
# Targets list format (CSV, '#' = comment):
#   type, target, description [, key=value ...]
#     type   : ping | tcp | http
#     target : ping=host  tcp=host:port  http=url
#     overrides: per_check_timeout_sec=<int>
#
# Exit codes:
#   0  success (success_threshold consecutive rounds all OK)
#   1  bad usage / args
#   2  list parse error
#   3  overall timeout
#   10 missing prerequisite command
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- lib resolution (mirrors rotate_log.sh) ---------------------------------
_ops_find_lib() {
    local d="$1"
    while [[ -n "$d" && "$d" != "/" ]]; do
        [[ -f "$d/lib/logging.sh" ]]       && { echo "$d/lib";       return 0; }
        [[ -f "$d/lib/linux/logging.sh" ]] && { echo "$d/lib/linux"; return 0; }
        [[ -f "$d/.ops-deploy-root" ]] && return 1
        d=$(dirname -- "$d")
    done
    return 1
}
if [[ -n "${OPS_LIB:-}" ]]; then
    _ops_lib="$OPS_LIB"
elif ! _ops_lib=$(_ops_find_lib "$SCRIPT_DIR"); then
    echo "[ERROR] lib/logging.sh not found from $SCRIPT_DIR (set OPS_LIB to override)" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_ops_lib/logging.sh"
# shellcheck source=/dev/null
source "$_ops_lib/config.sh"

usage() { sed -n '2,21p' "$0" >&2; exit 1; }

status="unknown"
rounds=0
consec=0
start_epoch=0

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    local elapsed=$(( $(date +%s) - start_epoch ))
    log_info "[RESULT] status=$status rounds=$rounds elapsed=${elapsed}s consec=$consec"
}

[[ $# -lt 1 ]] && usage
list_file="$1"

start_epoch=$(date +%s)
trap cleanup EXIT

load_ops_config "service_wait"

initial_wait_sec="${OPS_CONFIG[initial_wait_sec]:-0}"
interval_sec="${OPS_CONFIG[interval_sec]:-5}"
success_threshold="${OPS_CONFIG[success_threshold]:-3}"
timeout_sec="${OPS_CONFIG[timeout_sec]:-600}"
default_per_check="${OPS_CONFIG[per_check_timeout_sec]:-5}"

# Test hooks: env vars can override conf for fast tests.
[[ -n "${OPS_OVERRIDE_INITIAL_WAIT_SEC:-}"  ]] && initial_wait_sec="$OPS_OVERRIDE_INITIAL_WAIT_SEC"
[[ -n "${OPS_OVERRIDE_INTERVAL_SEC:-}"      ]] && interval_sec="$OPS_OVERRIDE_INTERVAL_SEC"
[[ -n "${OPS_OVERRIDE_TIMEOUT_SEC:-}"       ]] && timeout_sec="$OPS_OVERRIDE_TIMEOUT_SEC"
[[ -n "${OPS_OVERRIDE_SUCCESS_THRESHOLD:-}" ]] && success_threshold="$OPS_OVERRIDE_SUCCESS_THRESHOLD"

# Optional file logging
if [[ -n "${OPS_CONFIG[LogFile]:-}" ]]; then
    set_ops_log_config "${OPS_CONFIG[LogFile]}" "${OPS_CONFIG[LogLevel]:-INFO}" || true
fi

for v in initial_wait_sec interval_sec success_threshold timeout_sec default_per_check; do
    val="${!v}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        log_error "Config $v must be a non-negative integer, got '$val'"
        status="failed"; exit 1
    fi
done

if [[ ! -f "$list_file" ]]; then
    log_error "Target list file not found: $list_file"
    status="failed"; exit 2
fi

# Parsed targets stored as TAB-separated lines: type \t target \t desc \t per_check
targets_text=""

parse_fail() {
    local lineno="$1"
    local reason="$2"
    local detail="${3:-}"
    log_error "List parse error: line=$lineno reason=$reason${detail:+ $detail}"
    status="failed"
    exit 2
}

parse_list_line() {
    local lineno="$1" raw="$2"
    # Split on commas with surrounding whitespace.
    local IFS=','
    # shellcheck disable=SC2206
    local -a cols=( $raw )
    unset IFS
    # Trim each column.
    local i
    for ((i=0; i<${#cols[@]}; i++)); do
        cols[$i]="${cols[$i]#"${cols[$i]%%[![:space:]]*}"}"
        cols[$i]="${cols[$i]%"${cols[$i]##*[![:space:]]}"}"
    done
    if [[ "${#cols[@]}" -lt 3 ]]; then
        parse_fail "$lineno" need_3_cols "raw='$raw'"
    fi
    local p_type="${cols[0]}"
    local p_target="${cols[1]}"
    local p_desc="${cols[2]}"
    local p_per_check="$default_per_check"

    case "$p_type" in
        ping|tcp|http) ;;
        *)
            parse_fail "$lineno" unknown_type "type='$p_type'" ;;
    esac

    if [[ "$p_type" == "tcp" && "$p_target" != *:* ]]; then
        parse_fail "$lineno" tcp_needs_host_port "target='$p_target'"
    fi
    if [[ "$p_type" == "http" && "$p_target" != http://* && "$p_target" != https://* ]]; then
        parse_fail "$lineno" http_needs_url "target='$p_target'"
    fi

    # Parse "key=value" tokens in column 4..end (space-separated within a single column).
    local extra=""
    if [[ "${#cols[@]}" -ge 4 ]]; then
        extra="${cols[3]}"
        # Append any further comma-split columns too, to be permissive.
        local j
        for ((j=4; j<${#cols[@]}; j++)); do extra="$extra ${cols[$j]}"; done
    fi
    if [[ -n "$extra" ]]; then
        # shellcheck disable=SC2206
        local -a kvs=( $extra )
        local kv key val
        for kv in "${kvs[@]}"; do
            if [[ ! "$kv" =~ ^([^=]+)=(.*)$ ]]; then
                parse_fail "$lineno" bad_token "token='$kv'"
            fi
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            case "$key" in
                per_check_timeout_sec)
                    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
                        parse_fail "$lineno" bad_per_check "value='$val'"
                    fi
                    p_per_check="$val" ;;
                *)
                    parse_fail "$lineno" unknown_key "key='$key'" ;;
            esac
        done
    fi

    targets_text+="${p_type}"$'\t'"${p_target}"$'\t'"${p_desc}"$'\t'"${p_per_check}"$'\n'
}

lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    parse_list_line "$lineno" "$line"
done < "$list_file"

target_count=$(printf '%s' "$targets_text" | grep -c '^' || true)
if [[ "$target_count" -eq 0 ]]; then
    log_error "Target list is empty: $list_file"
    status="failed"; exit 2
fi

needs_ping=0; needs_http=0
while IFS=$'\t' read -r t_type _ _ _; do
    [[ -z "$t_type" ]] && continue
    [[ "$t_type" == "ping" ]] && needs_ping=1
    [[ "$t_type" == "http" ]] && needs_http=1
done <<< "$targets_text"

if [[ "$needs_ping" -eq 1 ]] && ! command -v ping >/dev/null 2>&1; then
    log_error "Prerequisite missing: ping"
    status="failed"; exit 10
fi
if [[ "$needs_http" -eq 1 ]] && ! command -v curl >/dev/null 2>&1; then
    log_error "Prerequisite missing: curl"
    status="failed"; exit 10
fi

log_info "start targets=$target_count timeout=$timeout_sec success=$success_threshold interval=$interval_sec initial=$initial_wait_sec"

check_ping() {
    local host="$1" to="$2"
    # ping -W is seconds on Linux. macOS differs but we target Linux here.
    ping -c 1 -W "$to" -- "$host" >/dev/null 2>&1
}

check_tcp() {
    local target="$1" to="$2"
    local host="${target%:*}" port="${target##*:}"
    # /dev/tcp + timeout(1). Pass host/port as positional args so they are not
    # re-evaluated as shell syntax inside the inner bash -c command string.
    timeout "$to" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1
}

check_http() {
    local url="$1" to="$2"
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$to" -- "$url" 2>/dev/null || echo "000")
    [[ "$code" =~ ^2[0-9][0-9]$ ]]
}

run_check() {
    local type="$1" target="$2" to="$3"
    case "$type" in
        ping) check_ping "$target" "$to" ;;
        tcp)  check_tcp  "$target" "$to" ;;
        http) check_http "$target" "$to" ;;
        *) return 1 ;;
    esac
}

# Temporary stub: real round loop comes in Task 5.
sleep "$initial_wait_sec"
deadline=$(( start_epoch + timeout_sec ))
while [[ $(date +%s) -lt $deadline ]]; do
    rounds=$((rounds+1))
    log_info "[ROUND $rounds] stub (functions defined, loop not wired)"
    sleep "$interval_sec"
done
status="timeout"
exit 3
