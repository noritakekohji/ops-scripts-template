#!/usr/bin/env bash
# ============================================================================
# backup_ami.sh
#   Create an AMI backup of an EC2 instance and optionally prune old AMIs.
#
# Usage:
#   backup_ami.sh -i <instance-id> -p <name-prefix> [-r <region>]
#                 [-d <retention-days>] [-R] [-w]
#
# Options:
#   -i  EC2 instance id (required, e.g. i-0abc...)
#   -p  Name prefix used for AMI naming and pruning filter (required)
#   -r  AWS region (default: from environment / profile)
#   -d  Retention days. AMIs older than this with the same NamePrefix
#       and CreatedBy=ops-scripts tag are deregistered. 0 disables. (default 0)
#   -R  Allow reboot during AMI creation. Default: --no-reboot
#   -w  Wait until the AMI becomes 'available'
#
# Authentication: relies on the default AWS credential chain.
# Exit codes: 0 = success, 1 = usage, 2 = instance not found,
#             3 = AMI did not become available, 4 = AMI create failed,
#             10 = aws CLI missing
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"

usage() {
    sed -n '2,21p' "$0" >&2
    exit 1
}

instance_id=""
name_prefix=""
region=""
retention_days=0
no_reboot="--no-reboot"
wait_for_completion=0

while getopts "i:p:r:d:Rwh" opt; do
    case "$opt" in
        i) instance_id="$OPTARG" ;;
        p) name_prefix="$OPTARG" ;;
        r) region="$OPTARG" ;;
        d) retention_days="$OPTARG" ;;
        R) no_reboot="--reboot" ;;
        w) wait_for_completion=1 ;;
        h|*) usage ;;
    esac
done

[[ -z "$instance_id" || -z "$name_prefix" ]] && usage

if ! [[ "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
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

log_info "AMI backup start: instance=$instance_id prefix=$name_prefix region=${region:-default} retention=$retention_days"

# --- validate instance ------------------------------------------------------
if ! aws ec2 describe-instances --instance-ids "$instance_id" "${region_arg[@]}" >/dev/null 2>&1; then
    log_error "Instance not found or not accessible: $instance_id"
    exit 2
fi

# --- create AMI -------------------------------------------------------------
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
    exit 4
fi

log_info "AMI creation initiated: ami_id=$ami_id name=$ami_name"

# --- optional wait ----------------------------------------------------------
if [[ "$wait_for_completion" -eq 1 ]]; then
    log_info "Waiting for AMI to become available: $ami_id"
    if ! aws ec2 wait image-available --image-ids "$ami_id" "${region_arg[@]}"; then
        log_error "AMI did not become available within wait period: $ami_id"
        exit 3
    fi
    log_info "AMI is available: $ami_id"
fi

# --- prune old AMIs ---------------------------------------------------------
if [[ "$retention_days" -gt 0 ]]; then
    if cutoff=$(date -u -d "-${retention_days} days" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null); then
        :
    else
        # BSD date (macOS) fallback
        cutoff=$(date -u -v"-${retention_days}d" +"%Y-%m-%dT%H:%M:%S")
    fi
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

        # Capture snapshot ids before deregister
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
                log_warn "Snapshot delete failed (in use?): $snap"
            fi
        done
    done
fi

log_info "AMI backup complete: $ami_id"
exit 0
