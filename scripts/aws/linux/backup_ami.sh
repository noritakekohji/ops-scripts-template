#!/usr/bin/env bash
# ============================================================================
# backup_ami.sh
#   Create an AMI backup of an EC2 instance and optionally prune old AMIs.
#
# Usage:
#   backup_ami.sh -i <instance-id> -p <name-prefix> [-r <region>]
#                 [-d <retention-days>] [-m <min-interval-min>] [-R] [-w]
#
# Options:
#   -i  EC2 instance id (required)
#   -p  Name prefix used for AMI naming and pruning filter (required)
#   -r  AWS region (default: from environment / profile)
#   -d  Retention days. AMIs older than this with same NamePrefix and
#       CreatedBy=ops-scripts tag are deregistered. 0 disables. (default 0)
#   -m  Idempotency window (minutes). Skip if a recent AMI exists for the
#       same NamePrefix. 0 disables. (default 5)
#   -R  Allow reboot during AMI creation (default: --no-reboot)
#   -w  Wait until the AMI becomes 'available'
#
# Authentication: relies on the default AWS credential chain.
# Exit codes: 0 success / skipped, 1 usage, 2 instance not found,
#             3 wait timeout, 4 create failed, 10 aws missing, 20 auth
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"

usage() { sed -n '2,23p' "$0" >&2; exit 1; }

# Phase 5 state (declared early so trap can see them)
ami_id=""
status="unknown"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc amiId=$ami_id"
}
trap cleanup EXIT

# --- Phase 1: argument parsing & validation ---------------------------------
instance_id=""
name_prefix=""
region=""
retention_days=0
min_interval_minutes=5
no_reboot="--no-reboot"
wait_for_completion=0

while getopts "i:p:r:d:m:Rwh" opt; do
    case "$opt" in
        i) instance_id="$OPTARG" ;;
        p) name_prefix="$OPTARG" ;;
        r) region="$OPTARG" ;;
        d) retention_days="$OPTARG" ;;
        m) min_interval_minutes="$OPTARG" ;;
        R) no_reboot="--reboot" ;;
        w) wait_for_completion=1 ;;
        h|*) usage ;;
    esac
done

if [[ -z "$instance_id" || -z "$name_prefix" ]]; then
    log_error "Missing required arg: -i and -p are required"
    status="failed"; exit 1
fi
if ! [[ "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
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

log_info "Args validated: instance=$instance_id prefix=$name_prefix region=${region:-default} retention=$retention_days minIntervalMin=$min_interval_minutes"

region_arg=()
[[ -n "$region" ]] && region_arg=(--region "$region")

# --- Phase 3: pre-check -----------------------------------------------------
log_info "Pre-check start"

# 3-a: required CLI
if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not installed"
    status="failed"; exit 10
fi

# 3-b/c: combined auth + instance lookup
if ! aws_err=$(aws ec2 describe-instances --instance-ids "$instance_id" "${region_arg[@]}" 2>&1 >/dev/null); then
    if echo "$aws_err" | grep -qE "InvalidInstanceID|NotFound|does not exist"; then
        log_error "Instance not found: instanceId=$instance_id"
        status="failed"; exit 2
    else
        log_error "AWS API call failed (auth?): error=$aws_err"
        status="failed"; exit 20
    fi
fi

# 3-d: idempotency
if [[ "$min_interval_minutes" -gt 0 ]]; then
    cutoff_iso=$(date -u -d "-${min_interval_minutes} minutes" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
                 || date -u -v"-${min_interval_minutes}M" +"%Y-%m-%dT%H:%M:%S")
    recent=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=tag:CreatedBy,Values=ops-scripts" \
                  "Name=tag:NamePrefix,Values=${name_prefix}" \
        "${region_arg[@]}" \
        --query "Images[?CreationDate>='${cutoff_iso}'] | sort_by(@, &CreationDate) | [-1].[ImageId, CreationDate]" \
        --output text 2>/dev/null || true)
    if [[ -n "$recent" && "$recent" != "None"$'\t'"None" && "$recent" != "None None" ]]; then
        recent_id=$(echo "$recent" | awk '{print $1}')
        recent_at=$(echo "$recent" | awk '{print $2}')
        if [[ "$recent_id" != "None" && -n "$recent_id" ]]; then
            log_info "Skipped (idempotent): reason=recent_ami_exists amiId=$recent_id createdAt=$recent_at minIntervalMin=$min_interval_minutes"
            status="skipped"; exit 0
        fi
    fi
fi

log_info "Pre-check passed"

# --- Phase 4: main processing -----------------------------------------------
log_info "Main start"

ts=$(date -u +"%Y%m%d-%H%M%S")
ami_name="${name_prefix}-${ts}"
description="Automated backup of ${instance_id} at ${ts} UTC"

tag_spec="ResourceType=image,Tags=[\
{Key=Name,Value=${ami_name}},\
{Key=CreatedBy,Value=ops-scripts},\
{Key=CreatedAt,Value=${ts}},\
{Key=SourceInstanceId,Value=${instance_id}},\
{Key=NamePrefix,Value=${name_prefix}},\
{Key=RetentionDays,Value=${retention_days}}]"

if ! ami_id=$(aws ec2 create-image \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "$description" \
        "$no_reboot" \
        --tag-specifications "$tag_spec" \
        "${region_arg[@]}" \
        --query 'ImageId' --output text); then
    log_error "AMI creation failed for $instance_id"
    status="failed"; exit 4
fi
log_info "AMI creation initiated: ami_id=$ami_id name=$ami_name"

if [[ "$wait_for_completion" -eq 1 ]]; then
    log_info "Waiting for AMI to become available: $ami_id"
    if ! aws ec2 wait image-available --image-ids "$ami_id" "${region_arg[@]}"; then
        log_error "AMI did not become available within wait period: $ami_id"
        status="failed"; exit 3
    fi
    log_info "AMI is available: $ami_id"
fi

# Pruning
if [[ "$retention_days" -gt 0 ]]; then
    cutoff=$(date -u -d "-${retention_days} days" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
             || date -u -v"-${retention_days}d" +"%Y-%m-%dT%H:%M:%S")
    log_info "Pruning AMIs older than ${cutoff} for prefix '${name_prefix}'"

    old_amis=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=tag:CreatedBy,Values=ops-scripts" \
                  "Name=tag:NamePrefix,Values=${name_prefix}" \
        "${region_arg[@]}" \
        --query "Images[?CreationDate<'${cutoff}' && ImageId!='${ami_id}'].ImageId" \
        --output text)

    for old_ami in $old_amis; do
        [[ -z "$old_ami" ]] && continue

        snaps=$(aws ec2 describe-images --image-ids "$old_ami" "${region_arg[@]}" \
            --query 'Images[0].BlockDeviceMappings[?Ebs!=null].Ebs.SnapshotId' \
            --output text)

        if aws ec2 deregister-image --image-id "$old_ami" "${region_arg[@]}"; then
            log_info "Deregistered AMI: $old_ami"
        else
            log_warn "Deregister failed: $old_ami"
            continue
        fi

        for snap in $snaps; do
            [[ -z "$snap" ]] && continue
            if aws ec2 delete-snapshot --snapshot-id "$snap" "${region_arg[@]}" 2>/dev/null; then
                log_info "Deleted snapshot: $snap"
            else
                log_warn "Snapshot delete failed: $snap"
            fi
        done
    done
fi

log_info "Main complete"
status="success"
exit 0
