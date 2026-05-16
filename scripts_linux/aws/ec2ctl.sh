#!/usr/bin/env bash
# ============================================================================
# ec2ctl.sh


#   ec2ctl.sh <action> <instance_id[,instance_id,...]> [-r <region>]
#             [-w] [-t <sec>] [-F]
#







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

usage() { sed -n '2,28p' "$0" >&2; exit 1; }

declare -a acted=()
declare -a skipped=()
status="unknown"
action=""

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc action=$action acted=${#acted[@]} skipped=${#skipped[@]}"
}
trap cleanup EXIT


action="${1:-}"
case "$action" in
    start|stop|restart|status) shift ;;
    ""|-h|--help) usage ;;
    *) log_error "Invalid action: $action (must be start|stop|restart|status)"; status="failed"; exit 1 ;;
esac

instance_ids_raw="${1:-}"
if [[ -z "$instance_ids_raw" || "$instance_ids_raw" =~ ^- ]]; then
    log_error "Missing instance id(s) (second positional arg)"
    status="failed"; exit 1
fi
shift

region=""
wait_for_completion=0
wait_timeout=600
force_stop=0

region_set=0
wait_set=0
wait_timeout_set=0
force_set=0

while getopts "r:wt:Fh" opt; do
    case "$opt" in
        r) region="$OPTARG"; region_set=1 ;;
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        F) force_stop=1; force_set=1 ;;
        h|*) usage ;;
    esac
done


load_ops_config "ec2ctl"
[[ "$region_set" -eq 0       && -n "${OPS_CONFIG[Region]:-}"         ]] && region="${OPS_CONFIG[Region]}"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in
        true|TRUE|True|1) wait_for_completion=1 ;;
        *)                wait_for_completion=0 ;;
    esac
fi
if [[ "$force_set" -eq 0 && -n "${OPS_CONFIG[ForceStop]:-}" ]]; then
    case "${OPS_CONFIG[ForceStop]}" in
        true|TRUE|True|1) force_stop=1 ;;
        *)                force_stop=0 ;;
    esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"


if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 30 ]] || [[ "$wait_timeout" -gt 3600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 30..3600)"
    status="failed"; exit 1
fi

declare -a instance_ids=()
IFS=',' read -ra instance_ids <<< "$instance_ids_raw"
for id in "${instance_ids[@]}"; do
    if ! [[ "$id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
        log_error "Invalid instance id: $id"
        status="failed"; exit 1
    fi
done

log_info "Args validated: action=$action instanceCount=${#instance_ids[@]} region=${region:-default} wait=$wait_for_completion timeoutSec=$wait_timeout forceStop=$force_stop"

region_arg=()
[[ -n "$region" ]] && region_arg=(--region "$region")


log_info "Pre-check start"

if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not installed"
    status="failed"; exit 10
fi

if ! aws_err=$(aws ec2 describe-instances --instance-ids "${instance_ids[@]}" "${region_arg[@]}" 2>&1 >/dev/null); then
    if echo "$aws_err" | grep -qE "InvalidInstanceID|NotFound|does not exist"; then
        log_error "Instance(s) not found: error=$aws_err"
        status="failed"; exit 2
    else
        log_error "AWS API call failed (auth?): error=$aws_err"
        status="failed"; exit 20
    fi
fi

states_raw=$(aws ec2 describe-instances --instance-ids "${instance_ids[@]}" "${region_arg[@]}" \
    --query 'Reservations[].Instances[].[InstanceId, State.Name, Placement.AvailabilityZone, LaunchTime]' --output text)

# status: 状況を出力して終了
if [[ "$action" == "status" ]]; then
    while IFS=$'\t' read -r iid st az lt; do
        [[ -z "$iid" ]] && continue
        log_info "Status: instanceId=$iid state=$st az=$az launchTime=$lt"
    done <<< "$states_raw"
    status="success"
    exit 0
fi

declare -a to_act=()
state_invalid=0
while IFS=$'\t' read -r iid st _; do
    [[ -z "$iid" ]] && continue
    case "$action" in
        start)
            case "$st" in
                running|pending) skipped+=( "$iid" ); log_info "Skipped (idempotent): instanceId=$iid state=$st" ;;
                stopped)         to_act+=( "$iid" ) ;;
                stopping)        log_warn "Cannot start (stopping): instanceId=$iid" ;;
                *)               log_error "Cannot start (state=$st): instanceId=$iid"; state_invalid=1 ;;
            esac
            ;;
        stop)
            case "$st" in
                stopped|stopping) skipped+=( "$iid" ); log_info "Skipped (idempotent): instanceId=$iid state=$st" ;;
                running)          to_act+=( "$iid" ) ;;
                pending)          log_warn "Cannot stop (pending): instanceId=$iid" ;;
                *)                log_error "Cannot stop (state=$st): instanceId=$iid"; state_invalid=1 ;;
            esac
            ;;
        restart)
            case "$st" in
                running) to_act+=( "$iid" ) ;;
                *)       log_error "Cannot restart (state=$st, must be running): instanceId=$iid"; state_invalid=1 ;;
            esac
            ;;
    esac
done <<< "$states_raw"

if [[ "$state_invalid" -eq 1 ]]; then
    status="failed"; exit 3
fi

if [[ "${#to_act[@]}" -eq 0 ]]; then
    log_info "Skipped (idempotent): reason=all_already_in_target_state action=$action count=${#skipped[@]}"
    status="skipped"; exit 0
fi

log_info "Pre-check passed: action=$action toAct=${#to_act[@]} skipped=${#skipped[@]}"


log_info "Main start"

case "$action" in
    start)
        if ! aws ec2 start-instances --instance-ids "${to_act[@]}" "${region_arg[@]}" >/dev/null; then
            log_error "Start API call failed"
            status="failed"; exit 4
        fi
        acted=( "${to_act[@]}" )
        log_info "Start initiated: instanceIds=$(IFS=,; echo "${acted[*]}") count=${#acted[@]}"
        ;;
    stop)
        force_arg=()
        [[ "$force_stop" -eq 1 ]] && force_arg=(--force)
        if ! aws ec2 stop-instances --instance-ids "${to_act[@]}" "${force_arg[@]}" "${region_arg[@]}" >/dev/null; then
            log_error "Stop API call failed"
            status="failed"; exit 4
        fi
        acted=( "${to_act[@]}" )
        log_info "Stop initiated: instanceIds=$(IFS=,; echo "${acted[*]}") count=${#acted[@]} force=$force_stop"
        ;;
    restart)
        if ! aws ec2 reboot-instances --instance-ids "${to_act[@]}" "${region_arg[@]}" >/dev/null; then
            log_error "Reboot API call failed"
            status="failed"; exit 4
        fi
        acted=( "${to_act[@]}" )
        log_info "Restart (reboot) initiated: instanceIds=$(IFS=,; echo "${acted[*]}") count=${#acted[@]}"
        ;;
esac

# start/stop の完了待機処理
if [[ "$wait_for_completion" -eq 1 && "${#acted[@]}" -gt 0 && "$action" != "restart" ]]; then
    target_state=$([[ "$action" == "start" ]] && echo "running" || echo "stopped")
    waiter=$([[ "$action" == "start" ]] && echo "instance-running" || echo "instance-stopped")
    log_info "Waiting for '$target_state': count=${#acted[@]} timeoutSec=$wait_timeout"
    if ! timeout "$wait_timeout" aws ec2 wait "$waiter" --instance-ids "${acted[@]}" "${region_arg[@]}"; then
        log_error "Did not reach '$target_state' within timeout: timeoutSec=$wait_timeout"
        status="failed"; exit 3
    fi
    log_info "All instances reached '$target_state'"
fi

log_info "Main complete"
status="success"
exit 0
