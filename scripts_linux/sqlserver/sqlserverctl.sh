#!/usr/bin/env bash
# ============================================================================
# sqlserverctl.sh


#   sqlserverctl.sh <action> <service_name> [-w] [-t <sec>]
#


#





#   -w  Wait until target state
#   -t  Wait timeout seconds (default 120, range 5..600)

#


# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Locate lib: repo (scripts_linux/xx/../lib) or deployed (bin/../lib/linux)
_ops_lib=""
for _d in "${SCRIPT_DIR}/../lib" "${SCRIPT_DIR}/../lib/linux"; do
    if [[ -f "${_d}/logging.sh" ]]; then _ops_lib="$(cd "${_d}" && pwd)"; break; fi
done
[[ -z "${_ops_lib:-}" ]] && { echo "[ERROR] lib/logging.sh not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "${_ops_lib}/logging.sh"
# shellcheck source=/dev/null
source "${_ops_lib}/config.sh"

usage() { sed -n '2,25p' "$0" >&2; exit 1; }

before_state=""
after_state=""
status="unknown"
action=""
service_name=""

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc action=$action service=$service_name before=$before_state after=$after_state"
}
trap cleanup EXIT

action="${1:-}"
case "$action" in
    start|stop|restart|status) shift ;;
    ""|-h|--help) usage ;;
    *) log_error "Invalid action: $action"; status="failed"; exit 1 ;;
esac

service_name="${1:-}"
if [[ -z "$service_name" || "$service_name" =~ ^- ]]; then
    log_error "Missing service name (second positional arg)"
    status="failed"; exit 1
fi
shift

wait_for_completion=0
wait_timeout=120
wait_set=0
wait_timeout_set=0

while getopts "wt:h" opt; do
    case "$opt" in
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        h|*) usage ;;
    esac
done

load_ops_config "sqlserverctl"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"

if ! [[ "$service_name" =~ ^[A-Za-z0-9._@\-]+$ ]]; then
    log_error "Invalid service name: $service_name"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 5 ]] || [[ "$wait_timeout" -gt 600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 5..600)"
    status="failed"; exit 1
fi

log_info "Args validated: action=$action service=$service_name wait=$wait_for_completion timeoutSec=$wait_timeout"

log_info "Pre-check start"

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not installed"
    status="failed"; exit 10
fi

if ! systemctl list-unit-files --no-legend "${service_name}.service" 2>/dev/null | grep -q . \
   && ! systemctl status "${service_name}" >/dev/null 2>&1; then
    log_error "Service not found: service=$service_name"
    status="failed"; exit 2
fi

before_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
log_info "Current state: service=$service_name state=$before_state"

if [[ "$action" == "status" ]]; then
    sub_state=$(systemctl show -p SubState --value "$service_name" 2>/dev/null || echo "")
    log_info "Status: service=$service_name state=$before_state sub=$sub_state"
    after_state="$before_state"
    status="success"
    exit 0
fi

if [[ "$action" == "start" && "$before_state" == "active" ]]; then
    log_info "Skipped (idempotent): service=$service_name state=active"
    after_state="$before_state"; status="skipped"; exit 0
fi
if [[ "$action" == "stop" && "$before_state" == "inactive" ]]; then
    log_info "Skipped (idempotent): service=$service_name state=inactive"
    after_state="$before_state"; status="skipped"; exit 0
fi

log_info "Pre-check passed"

log_info "Main start"

if [[ "$wait_for_completion" -eq 1 ]]; then
    if ! timeout "$wait_timeout" systemctl "$action" "$service_name"; then
        after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        log_error "systemctl $action did not complete within timeout: service=$service_name timeoutSec=$wait_timeout actual=$after_state"
        status="failed"; exit 3
    fi
else
    if ! systemctl "$action" "$service_name"; then
        after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        log_error "systemctl $action failed: service=$service_name actual=$after_state"
        status="failed"; exit 4
    fi
fi
log_info "$action initiated: service=$service_name"

after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
log_info "Main complete: service=$service_name state=$after_state"
status="success"
exit 0
