#!/usr/bin/env bash
# ============================================================================
# tomcatctl.sh
#   Tomcat lifecycle control: start / stop / restart / status (idempotent).
#
# Usage:
#   tomcatctl.sh <action> <service_name> [-w] [-t <sec>]
#
# Actions:
#   start    skip if active; otherwise systemctl start
#   stop     skip if inactive; otherwise systemctl stop
#   restart  systemctl restart (always; no idempotent skip)
#   status   read-only state report
#
# Options:
#   -w  Wait until target state (start->active, stop->inactive)
#   -t  Wait timeout seconds (default 60, range 5..600)
#   -h  Show usage
#
# Behavior options can be set in config/<env>/tomcatctl.conf.
# Authentication: requires sudo / root for systemctl service control.
# Exit codes: 0 ok / skipped, 1 usage, 2 service not found,
#             3 wait timeout, 4 systemctl failed, 10 systemctl missing
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

usage() { sed -n '2,22p' "$0" >&2; exit 1; }

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

# --- Phase 1: positional + options ------------------------------------------
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
wait_timeout=60
wait_set=0
wait_timeout_set=0

while getopts "wt:h" opt; do
    case "$opt" in
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        h|*) usage ;;
    esac
done

# --- Phase 2: load config ---------------------------------------------------
load_ops_config "tomcatctl"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

# --- Phase 1 (cont): validation ---------------------------------------------
if ! [[ "$service_name" =~ ^[A-Za-z0-9._@\-]+$ ]]; then
    log_error "Invalid service name: $service_name"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 5 ]] || [[ "$wait_timeout" -gt 600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 5..600)"
    status="failed"; exit 1
fi

log_info "Args validated: action=$action service=$service_name wait=$wait_for_completion timeoutSec=$wait_timeout"

# --- Phase 3: pre-check -----------------------------------------------------
log_info "Pre-check start"

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not installed (this script requires systemd)"
    status="failed"; exit 10
fi

# unit must exist (loaded or known to systemd)
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

# --- Phase 4: main processing -----------------------------------------------
log_info "Main start"

# systemctl start/stop/restart are blocking by default; wrap in timeout when -w
sysctl_args=( "$action" "$service_name" )
if [[ "$wait_for_completion" -eq 1 ]]; then
    if ! timeout "$wait_timeout" systemctl "${sysctl_args[@]}"; then
        after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        log_error "systemctl $action did not complete within timeout: service=$service_name timeoutSec=$wait_timeout actual=$after_state"
        status="failed"; exit 3
    fi
else
    # Without -w, just kick off (still synchronous on systemd, but no extra timeout wrap)
    if ! systemctl "${sysctl_args[@]}"; then
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
