#!/usr/bin/env bash
# ============================================================================
# backup_ebs_snapshot.sh
#   Create EBS snapshot(s) and optionally prune old ones.
#
# Usage:
#   backup_ebs_snapshot.sh (-v <volume-id> | -i <instance-id>) -p <name-prefix>
#                          [-r <region>] [-d <retention-days>]
#                          [-m <min-interval-min>] [-w]
#
# Options:
#   -v  EBS volume id (mutually exclusive with -i)
#   -i  Snapshot every EBS volume currently attached to this instance
#   -p  Name prefix for snapshot Name tag and pruning filter (required)
#   -r  AWS region (default: from environment / profile)
#   -d  Retention days (0 disables pruning, default 0)
#   -m  Idempotency window minutes. Skip if a recent snapshot exists for
#       the same NamePrefix. 0 disables. (default 5)
#   -w  Wait until all created snapshots reach 'completed' state
#
# Authentication: relies on the default AWS credential chain.
# Exit codes: 0 success / skipped, 1 usage, 2 not found, 3 wait timeout,
#             4 create failed, 10 aws missing, 20 auth
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"

usage() { sed -n '2,24p' "$0" >&2; exit 1; }

# Phase 5 state
declare -a created=()
status="unknown"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc created=${#created[@]}"
}
trap cleanup EXIT

# --- Phase 1: argument parsing & validation ---------------------------------
volume_id=""
instance_id=""
name_prefix=""
region=""
retention_days=0
min_interval_minutes=5
wait_for_completion=0

while getopts "v:i:p:r:d:m:wh" opt; do
    case "$opt" in
        v) volume_id="$OPTARG" ;;
        i) instance_id="$OPTARG" ;;
        p) name_prefix="$OPTARG" ;;
        r) region="$OPTARG" ;;
        d) retention_days="$OPTARG" ;;
        m) min_interval_minutes="$OPTARG" ;;
        w) wait_for_completion=1 ;;
        h|*) usage ;;
    esac
done

if [[ -z "$name_prefix" ]]; then
    log_error "Missing required arg: -p"
    status="failed"; exit 1
fi
if [[ -z "$volume_id" && -z "$instance_id" ]]; then
    log_error "Specify -v or -i"
    status="failed"; exit 1
fi
if [[ -n "$volume_id" && -n "$instance_id" ]]; then
    log_error "Specify either -v or -i, not both"
    status="failed"; exit 1
fi
if [[ -n "$volume_id" && ! "$volume_id" =~ ^vol-[0-9a-f]{8,17}$ ]]; then
    log_error "Invalid volume id: $volume_id"
    status="failed"; exit 1
fi
if [[ -n "$instance_id" && ! "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
    log_error "Invalid instance id: $instance_id"
    status="failed"; exit 1
fi
if ! [[ "$name_prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,120}$ ]]; then
    log_error "Invalid name prefix: $name_prefix"
    status="failed"; exit 1
fi
if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [[ "$retention_days" -gt 3650 ]]; then
    log_error "Invalid retention days: $retention_days"
    status="failed"; exit 1
fi
if ! [[ "$min_interval_minutes" =~ ^[0-9]+$ ]] || [[ "$min_interval_minutes" -gt 1440 ]]; then
    log_error "Invalid min interval minutes: $min_interval_minutes"
    status="failed"; exit 1
fi

log_info "Args validated: prefix=$name_prefix region=${region:-default} retention=$retention_days minIntervalMin=$min_interval_minutes"

region_arg=()
[[ -n "$region" ]] && region_arg=(--region "$region")

# --- Phase 3: pre-check -----------------------------------------------------
log_info "Pre-check start"

# 3-a: required CLI
if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not installed"
    status="failed"; exit 10
fi

# 3-b/c: resolve volumes (combined auth + existence)
declare -a volumes=()
if [[ -n "$instance_id" ]]; then
    if ! aws_err=$(aws ec2 describe-instances --instance-ids "$instance_id" "${region_arg[@]}" 2>&1 >/dev/null); then
        if echo "$aws_err" | grep -qE "InvalidInstanceID|NotFound|does not exist"; then
            log_error "Instance not found: instanceId=$instance_id"
            status="failed"; exit 2
        else
            log_error "AWS API call failed (auth?): error=$aws_err"
            status="failed"; exit 20
        fi
    fi
    raw=$(aws ec2 describe-instances --instance-ids "$instance_id" "${region_arg[@]}" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[?Ebs!=null].Ebs.VolumeId' \
        --output text 2>/dev/null || true)
    if [[ -z "$raw" || "$raw" == "None" ]]; then
        log_error "No EBS volumes attached: instanceId=$instance_id"
        status="failed"; exit 2
    fi
    # shellcheck disable=SC2206
    volumes=( $raw )
else
    if ! aws_err=$(aws ec2 describe-volumes --volume-ids "$volume_id" "${region_arg[@]}" 2>&1 >/dev/null); then
        if echo "$aws_err" | grep -qE "InvalidVolume|NotFound|does not exist"; then
            log_error "Volume not found: volumeId=$volume_id"
            status="failed"; exit 2
        else
            log_error "AWS API call failed (auth?): error=$aws_err"
            status="failed"; exit 20
        fi
    fi
    volumes=( "$volume_id" )
fi

# 3-d: idempotency
if [[ "$min_interval_minutes" -gt 0 ]]; then
    cutoff_iso=$(date -u -d "-${min_interval_minutes} minutes" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
                 || date -u -v"-${min_interval_minutes}M" +"%Y-%m-%dT%H:%M:%S")
    recent=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:CreatedBy,Values=ops-scripts" \
                  "Name=tag:NamePrefix,Values=${name_prefix}" \
        "${region_arg[@]}" \
        --query "Snapshots[?StartTime>='${cutoff_iso}'] | sort_by(@, &StartTime) | [-1].[SnapshotId, StartTime]" \
        --output text 2>/dev/null || true)
    if [[ -n "$recent" ]]; then
        recent_id=$(echo "$recent" | awk '{print $1}')
        recent_at=$(echo "$recent" | awk '{print $2}')
        if [[ -n "$recent_id" && "$recent_id" != "None" ]]; then
            log_info "Skipped (idempotent): reason=recent_snapshot_exists snapshotId=$recent_id startedAt=$recent_at minIntervalMin=$min_interval_minutes"
            status="skipped"; exit 0
        fi
    fi
fi

log_info "Pre-check passed: volumeCount=${#volumes[@]}"

# --- Phase 4: main processing -----------------------------------------------
log_info "Main start"

ts=$(date -u +"%Y%m%d-%H%M%S")

for vol in "${volumes[@]}"; do
    snap_name="${name_prefix}-${vol}-${ts}"
    description="Automated snapshot of ${vol} at ${ts} UTC"
    tag_spec="ResourceType=snapshot,Tags=[\
{Key=Name,Value=${snap_name}},\
{Key=CreatedBy,Value=ops-scripts},\
{Key=CreatedAt,Value=${ts}},\
{Key=SourceVolumeId,Value=${vol}},\
{Key=NamePrefix,Value=${name_prefix}},\
{Key=RetentionDays,Value=${retention_days}}]"

    if ! snap_id=$(aws ec2 create-snapshot \
            --volume-id "$vol" \
            --description "$description" \
            --tag-specifications "$tag_spec" \
            "${region_arg[@]}" \
            --query 'SnapshotId' --output text); then
        log_error "Snapshot creation failed: volume=$vol"
        status="failed"; exit 4
    fi
    log_info "Snapshot initiated: snapshot=$snap_id volume=$vol"
    created+=( "$snap_id" )
done

if [[ "$wait_for_completion" -eq 1 && "${#created[@]}" -gt 0 ]]; then
    log_info "Waiting for ${#created[@]} snapshot(s) to complete"
    if ! aws ec2 wait snapshot-completed --snapshot-ids "${created[@]}" "${region_arg[@]}"; then
        log_error "Snapshot(s) did not complete within wait period"
        status="failed"; exit 3
    fi
    log_info "All snapshots completed"
fi

# Pruning
if [[ "$retention_days" -gt 0 ]]; then
    cutoff=$(date -u -d "-${retention_days} days" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
             || date -u -v"-${retention_days}d" +"%Y-%m-%dT%H:%M:%S")
    log_info "Pruning snapshots older than ${cutoff} for prefix '${name_prefix}'"

    old_snaps=$(aws ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:CreatedBy,Values=ops-scripts" \
                  "Name=tag:NamePrefix,Values=${name_prefix}" \
        "${region_arg[@]}" \
        --query "Snapshots[?StartTime<'${cutoff}'].SnapshotId" \
        --output text)

    for snap in $old_snaps; do
        [[ -z "$snap" ]] && continue
        skip=0
        for c in "${created[@]:-}"; do
            [[ "$c" == "$snap" ]] && skip=1 && break
        done
        [[ "$skip" -eq 1 ]] && continue

        if aws ec2 delete-snapshot --snapshot-id "$snap" "${region_arg[@]}" 2>/dev/null; then
            log_info "Deleted snapshot: $snap"
        else
            log_warn "Snapshot delete failed (in use?): $snap"
        fi
    done
fi

log_info "Main complete"
status="success"
exit 0
