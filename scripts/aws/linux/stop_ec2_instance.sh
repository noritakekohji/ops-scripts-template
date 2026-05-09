#!/usr/bin/env bash
# ============================================================================
# stop_ec2_instance.sh
#   Stops one or more EC2 instances. Idempotent: already-stopped instances
#   are skipped without error.
#
# Usage:
#   stop_ec2_instance.sh -i <instance-ids> [-r <region>] [-w] [-t <sec>] [-F]
#
# Options:
#   -i  Comma-separated EC2 instance IDs (required, e.g. i-0abc,i-0def)
#   -r  AWS region (default: from environment / profile / config)
#   -w  Wait until every stopped instance reaches 'stopped'
#   -t  Wait timeout seconds (default 600, range 30..3600)
#   -F  Force-stop (no graceful OS shutdown). Data loss possible.
#
# Authentication: relies on the default AWS credential chain.
# Exit codes: 0 success / skipped, 1 usage, 2 not found, 3 wait/state invalid,
#             4 stop failed, 10 aws missing, 20 auth
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

usage() { sed -n '2,20p' "$0" >&2; exit 1; }

declare -a stopped=()
declare -a skipped_stopped=()
status="unknown"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc stopped=${#stopped[@]} skippedStopped=${#skipped_stopped[@]}"
}
trap cleanup EXIT

# --- Phase 1: argument parsing ----------------------------------------------
instance_ids_raw=""
region=""
wait_for_completion=0
wait_timeout=600
force_stop=0

region_set=0
wait_set=0
wait_timeout_set=0
force_set=0

while getopts "i:r:wt:Fh" opt; do
    case "$opt" in
        i) instance_ids_raw="$OPTARG" ;;
        r) region="$OPTARG"; region_set=1 ;;
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        F) force_stop=1; force_set=1 ;;
        h|*) usage ;;
    esac
done

# --- Phase 2: load config ---------------------------------------------------
load_ops_config "stop_ec2_instance"
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

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

# --- Phase 1 (cont): validation ---------------------------------------------
if [[ -z "$instance_ids_raw" ]]; then
    log_error "Missing required arg: -i"
    status="failed"; exit 1
fi
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

log_info "Args validated: instanceCount=${#instance_ids[@]} region=${region:-default} wait=$wait_for_completion timeoutSec=$wait_timeout forceStop=$force_stop"

region_arg=()
[[ -n "$region" ]] && region_arg=(--region "$region")

# --- Phase 3: pre-check -----------------------------------------------------
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
    --query 'Reservations[].Instances[].[InstanceId, State.Name]' --output text)

declare -a to_stop=()
state_invalid=0
while IFS=$'\t' read -r iid st; do
    [[ -z "$iid" ]] && continue
    case "$st" in
        stopped|stopping)
            skipped_stopped+=( "$iid" )
            log_info "Skipped (idempotent): instanceId=$iid state=$st"
            ;;
        running)
            to_stop+=( "$iid" )
            ;;
        pending)
            log_warn "Instance is pending; cannot stop now: instanceId=$iid"
            ;;
        shutting-down|terminated)
            log_error "Instance is in invalid state: instanceId=$iid state=$st"
            state_invalid=1
            ;;
        *)
            log_warn "Unexpected state: instanceId=$iid state=$st"
            ;;
    esac
done <<< "$states_raw"

if [[ "$state_invalid" -eq 1 ]]; then
    status="failed"; exit 3
fi

if [[ "${#to_stop[@]}" -eq 0 ]]; then
    log_info "Skipped (idempotent): reason=all_already_stopped count=${#skipped_stopped[@]}"
    status="skipped"; exit 0
fi

log_info "Pre-check passed: toStop=${#to_stop[@]} skippedStopped=${#skipped_stopped[@]}"

# --- Phase 4: main processing -----------------------------------------------
log_info "Main start"

force_arg=()
[[ "$force_stop" -eq 1 ]] && force_arg=(--force)

if ! aws ec2 stop-instances --instance-ids "${to_stop[@]}" "${force_arg[@]}" "${region_arg[@]}" >/dev/null; then
    log_error "Stop API call failed"
    status="failed"; exit 4
fi
stopped=( "${to_stop[@]}" )
log_info "Stop initiated: instanceIds=$(IFS=,; echo "${stopped[*]}") count=${#stopped[@]} force=$force_stop"

if [[ "$wait_for_completion" -eq 1 ]]; then
    log_info "Waiting for 'stopped': count=${#stopped[@]} timeoutSec=$wait_timeout"
    if ! timeout "$wait_timeout" aws ec2 wait instance-stopped --instance-ids "${stopped[@]}" "${region_arg[@]}"; then
        log_error "Did not reach 'stopped' within timeout: timeoutSec=$wait_timeout"
        status="failed"; exit 3
    fi
    log_info "All instances are stopped"
fi

log_info "Main complete"
status="success"
exit 0
