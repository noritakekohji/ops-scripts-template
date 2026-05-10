#!/usr/bin/env bash
# ============================================================================
# backup_ami.sh
#   EC2 繧､繝ｳ繧ｹ繧ｿ繝ｳ繧ｹ縺九ｉ AMI 繧剃ｽ懈・縺励∝ｿ・ｦ√↓蠢懊§縺ｦ蜿､縺・AMI 繧剃ｸ紋ｻ｣蜑企勁縺吶ｋ
#
# 菴ｿ縺・婿:
#   backup_ami.sh -i <instance-id> -p <name-prefix> [-r <region>]
#                 [-d <retention-days>] [-m <min-interval-min>] [-R] [-w]
#
# 謖吝虚繝代Λ繝｡繝ｼ繧ｿ縺ｯ CLI縲…onfig 繝輔ぃ繧､繝ｫ (config/<env>/
# backup_ami.conf) 繧ゅ＠縺上・繧ｹ繧ｯ繝ｪ繝励ヨ譌｢螳壼､縺ｧ謖・ｮ壼庄閭ｽ縲ょ━蜈磯・ｽ・ CLI > config > 譌｢螳壼､縲・# 螳溯｡後＃縺ｨ縺ｮ蟇ｾ雎｡ (-i / -p) 縺ｯ CLI 蟆ら畑
#
# 隱崎ｨｼ: 繝・ヵ繧ｩ繝ｫ繝・AWS credential chain・育腸蠅・､画焚 / 繝励Ο繝輔ぃ繧､繝ｫ / IAM 繝ｭ繝ｼ繝ｫ・・# 邨ゆｺ・さ繝ｼ繝・ 0 謌仙粥/繧ｹ繧ｭ繝・・, 1 usage, 2 繧､繝ｳ繧ｹ繧ｿ繝ｳ繧ｹ荳榊惠,
#             3 蠕・ｩ溘ち繧､繝繧｢繧ｦ繝・ 4 菴懈・螟ｱ謨・ 10 aws CLI 荳榊惠, 20 隱崎ｨｼ
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

usage() { sed -n '2,18p' "$0" >&2; exit 1; }

ami_id=""
status="unknown"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc amiId=$ami_id"
}
trap cleanup EXIT

# --- 繝輔ぉ繝ｼ繧ｺ 1: 蠑墓焚繝代・繧ｹ ----------------------------------------------
instance_id=""
name_prefix=""
region=""
retention_days=0
min_interval_minutes=5
no_reboot="--no-reboot"
wait_for_completion=0

region_set=0
retention_days_set=0
min_interval_set=0
no_reboot_set=0
wait_set=0

while getopts "i:p:r:d:m:Rwh" opt; do
    case "$opt" in
        i) instance_id="$OPTARG" ;;
        p) name_prefix="$OPTARG" ;;
        r) region="$OPTARG"; region_set=1 ;;
        d) retention_days="$OPTARG"; retention_days_set=1 ;;
        m) min_interval_minutes="$OPTARG"; min_interval_set=1 ;;
        R) no_reboot="--reboot"; no_reboot_set=1 ;;
        w) wait_for_completion=1; wait_set=1 ;;
        h|*) usage ;;
    esac
done

# --- 繝輔ぉ繝ｼ繧ｺ 2: 險ｭ螳壹ヵ繧｡繧､繝ｫ隱ｭ霎ｼ縺ｿ縲∵悴謖・ｮ壼､縺ｸ蜿肴丐 ---------------------------
load_ops_config "backup_ami"
[[ "$region_set" -eq 0         && -n "${OPS_CONFIG[Region]:-}"             ]] && region="${OPS_CONFIG[Region]}"
[[ "$retention_days_set" -eq 0 && -n "${OPS_CONFIG[RetentionDays]:-}"      ]] && retention_days="${OPS_CONFIG[RetentionDays]}"
[[ "$min_interval_set" -eq 0   && -n "${OPS_CONFIG[MinIntervalMinutes]:-}" ]] && min_interval_minutes="${OPS_CONFIG[MinIntervalMinutes]}"
if [[ "$no_reboot_set" -eq 0 && -n "${OPS_CONFIG[NoReboot]:-}" ]]; then
    case "${OPS_CONFIG[NoReboot]}" in
        true|TRUE|True|1) no_reboot="--no-reboot" ;;
        *)                no_reboot="--reboot" ;;
    esac
fi
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in
        true|TRUE|True|1) wait_for_completion=1 ;;
        *)                wait_for_completion=0 ;;
    esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"

# --- 繝輔ぉ繝ｼ繧ｺ 1・育ｶ壹″・・ 繝舌Μ繝・・繧ｷ繝ｧ繝ｳ ---------------------------------------------
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

# --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け -----------------------------------------------------
log_info "Pre-check start"

if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not installed"
    status="failed"; exit 10
fi

if ! aws_err=$(aws ec2 describe-instances --instance-ids "$instance_id" "${region_arg[@]}" 2>&1 >/dev/null); then
    if echo "$aws_err" | grep -qE "InvalidInstanceID|NotFound|does not exist"; then
        log_error "Instance not found: instanceId=$instance_id"
        status="failed"; exit 2
    else
        log_error "AWS API call failed (auth?): error=$aws_err"
        status="failed"; exit 20
    fi
fi

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
    if [[ -n "$recent" ]]; then
        recent_id=$(echo "$recent" | awk '{print $1}')
        recent_at=$(echo "$recent" | awk '{print $2}')
        if [[ -n "$recent_id" && "$recent_id" != "None" ]]; then
            log_info "Skipped (idempotent): reason=recent_ami_exists amiId=$recent_id createdAt=$recent_at minIntervalMin=$min_interval_minutes"
            status="skipped"; exit 0
        fi
    fi
fi

log_info "Pre-check passed"

# --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・-----------------------------------------------
log_info "Main start"

ts=$(ops_jst_stamp)
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
