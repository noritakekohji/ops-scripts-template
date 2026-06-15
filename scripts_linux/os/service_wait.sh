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

# Hardcoded defaults; .lst header overrides.
initial_wait_sec=0
interval_sec=5
success_threshold=3
timeout_sec=600
default_per_check=5

# v2: monitoring params moved to the .lst header. Warn (but don't fail) if
# anyone left them in conf so a stale conf can't silently change behavior.
for stale_key in initial_wait_sec interval_sec success_threshold timeout_sec per_check_timeout_sec; do
    if [[ -n "${OPS_CONFIG[$stale_key]:-}" ]]; then
        log_warn "Conf key '$stale_key' is no longer used; move it to the .lst header. Ignoring."
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

parse_header_line() {
    local lineno="$1" raw="$2"
    local key val
    if [[ ! "$raw" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        parse_fail "$lineno" bad_header "raw='$raw'"
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # Strip inline comment and trailing whitespace.
    val="${val%%#*}"
    val="${val%"${val##*[![:space:]]}"}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        parse_fail "$lineno" bad_header_value "key=$key value='$val'"
    fi
    case "$key" in
        initial_wait_sec)
            [[ "$initial_wait_sec_set" -eq 1 ]] && log_warn "Header key '$key' overridden (later value wins)"
            initial_wait_sec="$val"; initial_wait_sec_set=1 ;;
        interval_sec)
            [[ "$interval_sec_set" -eq 1 ]] && log_warn "Header key '$key' overridden (later value wins)"
            interval_sec="$val"; interval_sec_set=1 ;;
        success_threshold)
            [[ "$success_threshold_set" -eq 1 ]] && log_warn "Header key '$key' overridden (later value wins)"
            success_threshold="$val"; success_threshold_set=1 ;;
        timeout_sec)
            [[ "$timeout_sec_set" -eq 1 ]] && log_warn "Header key '$key' overridden (later value wins)"
            timeout_sec="$val"; timeout_sec_set=1 ;;
        per_check_timeout_sec)
            [[ "$default_per_check_set" -eq 1 ]] && log_warn "Header key '$key' overridden (later value wins)"
            default_per_check="$val"; default_per_check_set=1 ;;
        *)
            parse_fail "$lineno" unknown_header_key "key='$key'" ;;
    esac
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
    # v3.1: rows are strictly 3 columns. Any trailing content (commas in desc,
    # leftover key=value etc.) is rejected so timing settings live only in the
    # .lst header.
    if [[ "${#cols[@]}" -gt 3 ]]; then
        parse_fail "$lineno" extra_columns "raw='$raw'"
    fi
    local p_type="${cols[0]}"
    local p_target="${cols[1]}"
    local p_desc="${cols[2]}"
    local p_per_check="$default_per_check"

    case "$p_type" in
        ping|tcp|http|service|process) ;;
        *)
            parse_fail "$lineno" unknown_type "type='$p_type'" ;;
    esac

    if [[ "$p_type" == "tcp" && ! "$p_target" =~ ^[^:]+:[0-9]+$ ]]; then
        parse_fail "$lineno" tcp_needs_host_port "target='$p_target'"
    fi
    if [[ "$p_type" == "http" && "$p_target" != http://* && "$p_target" != https://* ]]; then
        parse_fail "$lineno" http_needs_url "target='$p_target'"
    fi
    if [[ "$p_type" == "service" && ! "$p_target" =~ ^[A-Za-z0-9._@-]+$ ]]; then
        parse_fail "$lineno" bad_service_name "target='$p_target'"
    fi
    targets_text+="${p_type}"$'\t'"${p_target}"$'\t'"${p_desc}"$'\t'"${p_per_check}"$'\n'
}

# Track which header keys were set so duplicates can WARN.
initial_wait_sec_set=0
interval_sec_set=0
success_threshold_set=0
timeout_sec_set=0
default_per_check_set=0

# Header phase: key=value before any target row. Switches off as soon as the
# first CSV-style target row is seen. After that, only CSV rows are accepted.
header_phase=1
lineno=0
while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    if [[ "$line" == *,* ]]; then
        header_phase=0
        parse_list_line "$lineno" "$line"
    elif [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]; then
        if [[ "$header_phase" -eq 1 ]]; then
            parse_header_line "$lineno" "$line"
        else
            parse_fail "$lineno" header_after_targets "raw='$line'"
        fi
    else
        parse_fail "$lineno" bad_line "raw='$line'"
    fi
done < "$list_file"

target_count=$(printf '%s' "$targets_text" | grep -c '^' || true)
if [[ "$target_count" -eq 0 ]]; then
    log_error "Target list is empty: $list_file"
    status="failed"; exit 2
fi

# Test hooks: env vars trump anything from the .lst header or hardcoded default.
[[ -n "${OPS_OVERRIDE_INITIAL_WAIT_SEC:-}"  ]] && initial_wait_sec="$OPS_OVERRIDE_INITIAL_WAIT_SEC"
[[ -n "${OPS_OVERRIDE_INTERVAL_SEC:-}"      ]] && interval_sec="$OPS_OVERRIDE_INTERVAL_SEC"
[[ -n "${OPS_OVERRIDE_TIMEOUT_SEC:-}"       ]] && timeout_sec="$OPS_OVERRIDE_TIMEOUT_SEC"
[[ -n "${OPS_OVERRIDE_SUCCESS_THRESHOLD:-}" ]] && success_threshold="$OPS_OVERRIDE_SUCCESS_THRESHOLD"

# Final numeric validation (covers conf carrying garbage, env-hook typos, and
# any default we somehow left as non-integer).
for v in initial_wait_sec interval_sec success_threshold timeout_sec default_per_check; do
    val="${!v}"
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        log_error "Config $v must be a non-negative integer, got '$val'"
        status="failed"; exit 1
    fi
done

needs_ping=0; needs_http=0; needs_systemctl=0; needs_pgrep=0
while IFS=$'\t' read -r t_type _ _ _; do
    [[ -z "$t_type" ]] && continue
    [[ "$t_type" == "ping" ]]    && needs_ping=1
    [[ "$t_type" == "http" ]]    && needs_http=1
    [[ "$t_type" == "service" ]] && needs_systemctl=1
    [[ "$t_type" == "process" ]] && needs_pgrep=1
done <<< "$targets_text"

if [[ "$needs_ping" -eq 1 ]] && ! command -v ping >/dev/null 2>&1; then
    log_error "Prerequisite missing: ping"
    status="failed"; exit 10
fi
if [[ "$needs_http" -eq 1 ]] && ! command -v curl >/dev/null 2>&1; then
    log_error "Prerequisite missing: curl"
    status="failed"; exit 10
fi
if [[ "$needs_systemctl" -eq 1 ]] && ! command -v systemctl >/dev/null 2>&1; then
    log_error "Prerequisite missing: systemctl"
    status="failed"; exit 10
fi
if [[ "$needs_pgrep" -eq 1 ]] && ! command -v pgrep >/dev/null 2>&1; then
    log_error "Prerequisite missing: pgrep"
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

check_service() {
    local name="$1" to="$2"
    timeout "$to" systemctl is-active --quiet -- "$name" >/dev/null 2>&1
}

check_process() {
    local name="$1" to="$2"
    timeout "$to" pgrep -x -- "$name" >/dev/null 2>&1
}

run_check() {
    local type="$1" target="$2" to="$3"
    case "$type" in
        ping)    check_ping    "$target" "$to" ;;
        tcp)     check_tcp     "$target" "$to" ;;
        http)    check_http    "$target" "$to" ;;
        service) check_service "$target" "$to" ;;
        process) check_process "$target" "$to" ;;
        *) return 1 ;;
    esac
}

sleep "$initial_wait_sec"
deadline=$(( start_epoch + timeout_sec ))

while [[ $(date +%s) -lt $deadline ]]; do
    rounds=$((rounds+1))
    round_ok=1
    while IFS=$'\t' read -r t_type t_target t_desc t_per_check; do
        [[ -z "$t_type" ]] && continue
        if run_check "$t_type" "$t_target" "$t_per_check"; then
            log_info "[ROUND $rounds] $t_type $t_target -> OK (desc=$t_desc)"
        else
            log_warn "[ROUND $rounds] $t_type $t_target -> NG (desc=$t_desc)"
            round_ok=0
        fi
    done <<< "$targets_text"

    if [[ "$round_ok" -eq 1 ]]; then
        consec=$((consec+1))
    else
        consec=0
    fi

    if [[ "$round_ok" -eq 1 ]]; then
        log_info "[ROUND $rounds] PASS consec=$consec/$success_threshold"
    else
        log_info "[ROUND $rounds] FAIL consec=$consec/$success_threshold"
    fi

    if [[ "$consec" -ge "$success_threshold" ]]; then
        status="success"
        exit 0
    fi

    # Sleep, but don't oversleep the deadline.
    now=$(date +%s)
    remain=$(( deadline - now ))
    if [[ "$remain" -le 0 ]]; then break; fi
    sleep_n="$interval_sec"
    [[ "$sleep_n" -gt "$remain" ]] && sleep_n="$remain"
    sleep "$sleep_n"
done

status="timeout"
exit 3
