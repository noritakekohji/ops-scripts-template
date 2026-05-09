#!/usr/bin/env bash
# ============================================================================
# backup_ebs_snapshot.sh
#   Create EBS snapshot(s) and optionally prune old ones.
#
# Usage:
#   backup_ebs_snapshot.sh (-v <volume-id> | -i <instance-id>) -p <name-prefix>
#                          [-r <region>] [-d <retention-days>] [-w]
#
# Options:
#   -v  EBS volume id (mutually exclusive with -i)
#   -i  Snapshot every EBS volume currently attached to this instance
#   -p  Name prefix for snapshot Name tag and pruning filter (required)
#   -r  AWS region (default: from environment / profile)
#   -d  Retention days. Snapshots older than this with the same NamePrefix
#       and CreatedBy=ops-scripts tag are deleted. 0 disables. (default 0)
#   -w  Wait until all created snapshots reach 'completed' state
#
# Authentication: relies on the default AWS credential chain.
# Exit codes: 0 = success, 1 = usage / validation, 2 = no volumes,
#             3 = snapshot did not complete, 4 = create failed,
#             10 = aws CLI missing
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../lib/bash/logging.sh"

usage() {
    sed -n '2,21p' "$0" >&2
    exit 1
}

volume_id=""
instance_id=""
name_prefix=""
region=""
retention_days=0
wait_for_completion=0

while getopts "v:i:p:r:d:wh" opt; do
    case "$opt" in
        v) volume_id="$OPTARG" ;;
        i) instance_id="$OPTARG" ;;
        p) name_prefix="$OPTARG" ;;
        r) region="$OPTARG" ;;
        d) retention_days="$OPTARG" ;;
        w) wait_for_completion=1 ;;
        h|*) usage ;;
    esac
done

if [[ -z "$name_prefix" ]]; then usage; fi
if [[ -z "$volume_id" && -z "$instance_id" ]]; then usage; fi
if [[ -n "$volume_id" && -n "$instance_id" ]]; then
    log_error "Specify either -v or -i, not both"
    exit 1
fi

if [[ -n "$volume_id" && ! "$volume_id" =~ ^vol-[0-9a-f]{8,17}$ ]]; then
    log_error "Invalid volume id: $volume_id"
    exit 1
fi
if [[ -n "$instance_id" && ! "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
    log_error "Invalid instance id: $instance_id"
    exit 1
fi
if ! [[ "$name_prefix" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{1,120}$ ]]; then
    log_error "Invalid name prefix: $name_prefix"
    exit 1
fi
if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [[ "$retention_days" -gt 3650 ]]; then
    log_error "Invalid retention days: $retention_days"
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI is not installed"
    exit 10
fi

region_arg=()
[[ -n "$region" ]] && region_arg=(--region "$region")

# --- resolve volumes --------------------------------------------------------
declare -a volumes=()
if [[ -n "$instance_id" ]]; then
    log_info "Resolving volumes attached to instance: $instance_id"
    raw=$(aws ec2 describe-instances --instance-ids "$instance_id" "${region_arg[@]}" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[?Ebs!=null].Ebs.VolumeId' \
        --output text 2>/dev/null || true)
    if [[ -z "$raw" ]]; then
        log_error "No volumes resolved for instance: $instance_id"
        exit 2
    fi
    # shellcheck disable=SC2206
    volumes=( $raw )
else
    volumes=( "$volume_id" )
fi

log_info "EBS snapshot start: prefix=$name_prefix region=${region:-default} retention=$retention_days volumes=${#volumes[@]}"

# --- create snapshots -------------------------------------------------------
ts=$(date -u +"%Y%m%d-%H%M%S")
declare -a created=()

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
        exit 4
    fi

    log_info "Snapshot initiated: snapshot=$snap_id volume=$vol"
    created+=( "$snap_id" )
done

# --- optional wait ----------------------------------------------------------
if [[ "$wait_for_completion" -eq 1 && "${#created[@]}" -gt 0 ]]; then
    log_info "Waiting for ${#created[@]} snapshot(s) to complete"
    if ! aws ec2 wait snapshot-completed --snapshot-ids "${created[@]}" "${region_arg[@]}"; then
        log_error "Snapshot(s) did not complete within wait period"
        exit 3
    fi
    log_info "All snapshots completed"
fi

# --- prune old snapshots ----------------------------------------------------
if [[ "$retention_days" -gt 0 ]]; then
    if cutoff=$(date -u -d "-${retention_days} days" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null); then
        :
    else
        cutoff=$(date -u -v"-${retention_days}d" +"%Y-%m-%dT%H:%M:%S")
    fi
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
        # Skip just-created
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

log_info "EBS snapshot backup complete: created=${#created[@]}"
exit 0
