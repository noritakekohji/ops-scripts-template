#!/usr/bin/env bash
# ============================================================================
# backup_ebs_snapshot.sh
#   EBS ボリュームのスナップショットを作成し、世代を超えた古いスナップショットを
#   自動削除する（Linux / Bash 版）
#
# 使い方:
#   backup_ebs_snapshot.sh (-v <volume-id> | -i <instance-id>) -p <name-prefix>
#                          [-r <region>] [-d <retention-days>]
#                          [-m <min-interval-min>] [-w]
#
# 挙動パラメータは CLI、config、もしくはスクリプト既定値で指定可能。
# 実行ごとの対象 (-v / -i / -p) は CLI 専用
#
# 認証: デフォルト AWS credential chain（環境変数 / プロファイル / IAM ロール）
# 終了コード: 0 成功/スキップ, 1 usage, 2 不在, 3 待機タイムアウト,
#             4 作成失敗数, 10 aws CLI 不在, 20 認証
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

usage() { sed -n '2,18p' "$0" >&2; exit 1; }

declare -a created=()
status="unknown"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc created=${#created[@]}"
}
trap cleanup EXIT


volume_id=""
instance_id=""
name_prefix=""
region=""
retention_days=0
min_interval_minutes=5
wait_for_completion=0

region_set=0
retention_days_set=0
min_interval_set=0
wait_set=0

while getopts "v:i:p:r:d:m:wh" opt; do
    case "$opt" in
        v) volume_id="$OPTARG" ;;
        i) instance_id="$OPTARG" ;;
        p) name_prefix="$OPTARG" ;;
        r) region="$OPTARG"; region_set=1 ;;
        d) retention_days="$OPTARG"; retention_days_set=1 ;;
        m) min_interval_minutes="$OPTARG"; min_interval_set=1 ;;
        w) wait_for_completion=1; wait_set=1 ;;
        h|*) usage ;;
    esac
done


load_ops_config "backup_ebs_snapshot"
[[ "$region_set" -eq 0         && -n "${OPS_CONFIG[Region]:-}"             ]] && region="${OPS_CONFIG[Region]}"
[[ "$retention_days_set" -eq 0 && -n "${OPS_CONFIG[RetentionDays]:-}"      ]] && retention_days="${OPS_CONFIG[RetentionDays]}"
[[ "$min_interval_set" -eq 0   && -n "${OPS_CONFIG[MinIntervalMinutes]:-}" ]] && min_interval_minutes="${OPS_CONFIG[MinIntervalMinutes]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in
        true|TRUE|True|1) wait_for_completion=1 ;;
        *)                wait_for_completion=0 ;;
    esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"


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


log_info "Pre-check start"

if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not installed"
    status="failed"; exit 10
fi

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


log_info "Main start"

ts=$(ops_jst_stamp)

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
