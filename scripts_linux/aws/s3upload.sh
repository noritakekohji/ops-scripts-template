#!/usr/bin/env bash
# ============================================================================
# s3upload.sh
#   繝ｭ繝ｼ繧ｫ繝ｫ繝輔ぃ繧､繝ｫ繧・Amazon S3 縺ｫ繧｢繝・・繝ｭ繝ｼ繝会ｼ郁｡悟腰菴堺ｸ頑嶌縺榊ｯｾ蠢懶ｼ・#
# 菴ｿ縺・婿:
#   s3upload.sh [-p <local>] [-L <list-file>] [-b <bucket>] [-x <prefix>]
#               [-r <region>] [-c <storage-class>] [-e <sse>] [-k <kms-key>]
#               [-m archive|mirror]
#
# -L 縺ｮ繝ｪ繧ｹ繝亥推陦鯉ｼ・p 蜊倡匱繧ょ酔蠖｢蠑擾ｼ・
#     <local_path> [Bucket=... Prefix=... Region=... StorageClass=...
#                   ServerSideEncryption=... KmsKeyId=... Mode=...]
#
# 隗｣豎ｺ鬆・ｽ・ 陦悟・ > CLI > config/<env>/s3upload.conf > 譌｢螳壼､
# 繝｢繝ｼ繝・
#   archive  s3://<bucket>/<prefix>/<filename>.<JST yyyyMMdd-HHmmss>・域里螳夲ｼ・#   mirror   s3://<bucket>/<prefix>/<filename>・井ｸ頑嶌縺搾ｼ・#
# 隱崎ｨｼ: 繝・ヵ繧ｩ繝ｫ繝・AWS credential chain
# 遨ｺ縺ｮ繝ｭ繝ｼ繧ｫ繝ｫ繝輔ぃ繧､繝ｫ縺ｯ繧ｹ繧ｭ繝・・・亥・遲会ｼ・# 邨ゆｺ・さ繝ｼ繝・ 0 謌仙粥/繧ｹ繧ｭ繝・・, 1 usage, 2 繝ｪ繧ｹ繝医ヵ繧｡繧､繝ｫ荳榊惠,
#             4 蜈ｨ莉ｶ繧｢繝・・繝ｭ繝ｼ繝牙､ｱ謨・ 10 aws CLI 荳榊惠
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

usage() { sed -n '2,24p' "$0" >&2; exit 1; }

uploaded=0
skipped=0
failed=0
status="unknown"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc uploaded=$uploaded skipped=$skipped failed=$failed"
}
trap cleanup EXIT

# --- 繝輔ぉ繝ｼ繧ｺ 1: 蠑墓焚繝代・繧ｹ ----------------------------------------------
path=""
path_list=""
bucket=""
prefix=""
region=""
storage_class="STANDARD"
sse="none"
kms_key_id=""
mode="archive"

bucket_set=0
prefix_set=0
region_set=0
sc_set=0
sse_set=0
kms_set=0
mode_set=0

while getopts "p:L:b:x:r:c:e:k:m:h" opt; do
    case "$opt" in
        p) path="$OPTARG" ;;
        L) path_list="$OPTARG" ;;
        b) bucket="$OPTARG"; bucket_set=1 ;;
        x) prefix="$OPTARG"; prefix_set=1 ;;
        r) region="$OPTARG"; region_set=1 ;;
        c) storage_class="$OPTARG"; sc_set=1 ;;
        e) sse="$OPTARG"; sse_set=1 ;;
        k) kms_key_id="$OPTARG"; kms_set=1 ;;
        m) mode="$OPTARG"; mode_set=1 ;;
        h|*) usage ;;
    esac
done

# --- 繝輔ぉ繝ｼ繧ｺ 2: 險ｭ螳壹ヵ繧｡繧､繝ｫ隱ｭ霎ｼ縺ｿ ---------------------------------------------------
load_ops_config "s3upload"
[[ "$bucket_set" -eq 0 && -n "${OPS_CONFIG[Bucket]:-}"               ]] && bucket="${OPS_CONFIG[Bucket]}"
[[ "$prefix_set" -eq 0 && -n "${OPS_CONFIG[Prefix]:-}"               ]] && prefix="${OPS_CONFIG[Prefix]}"
[[ "$region_set" -eq 0 && -n "${OPS_CONFIG[Region]:-}"               ]] && region="${OPS_CONFIG[Region]}"
[[ "$sc_set" -eq 0     && -n "${OPS_CONFIG[StorageClass]:-}"         ]] && storage_class="${OPS_CONFIG[StorageClass]}"
[[ "$sse_set" -eq 0    && -n "${OPS_CONFIG[ServerSideEncryption]:-}" ]] && sse="${OPS_CONFIG[ServerSideEncryption]}"
[[ "$kms_set" -eq 0    && -n "${OPS_CONFIG[KmsKeyId]:-}"             ]] && kms_key_id="${OPS_CONFIG[KmsKeyId]}"
[[ "$mode_set" -eq 0   && -n "${OPS_CONFIG[Mode]:-}"                 ]] && mode="${OPS_CONFIG[Mode]}"
# -L 未指定なら config の PathList を使用、相対パスは repo root 起点で絶対化
if [[ -z "$path_list" && -n "${OPS_CONFIG[PathList]:-}" ]]; then
    path_list="${OPS_CONFIG[PathList]}"
    if [[ "$path_list" != /* ]]; then
        path_list="$(ops_repo_root)/$path_list"
    fi
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"

# 繧ｰ繝ｭ繝ｼ繝舌Ν譌｢螳壼､縺ｮ enum 讀懆ｨｼ
case "$storage_class" in STANDARD|STANDARD_IA|ONEZONE_IA|INTELLIGENT_TIERING|GLACIER|GLACIER_IR|DEEP_ARCHIVE) ;;
    *) log_error "Invalid StorageClass: $storage_class"; status="failed"; exit 1 ;;
esac
case "$sse" in none|AES256|aws:kms) ;;
    *) log_error "Invalid ServerSideEncryption: $sse"; status="failed"; exit 1 ;;
esac
case "$mode" in archive|mirror) ;;
    *) log_error "Invalid Mode: $mode"; status="failed"; exit 1 ;;
esac

log_info "Args validated: path='$path' pathList='$path_list' bucket='$bucket' prefix='$prefix' region='$region' storageClass=$storage_class sse=$sse mode=$mode"

# --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け・医お繝ｳ繝医Μ蜿朱寔・・-----------------------------------
log_info "Pre-check start"

if ! command -v aws >/dev/null 2>&1; then
    log_error "aws CLI not installed"
    status="failed"; exit 10
fi

# 蜷・お繝ｳ繝医Μ繧偵ち繝門玄蛻・ｊ繝ｬ繧ｳ繝ｼ繝峨→縺励※繧ｨ繝ｳ繧ｳ繝ｼ繝・
# <path>\t<bucket>\t<prefix>\t<region>\t<storage_class>\t<sse>\t<kms>\t<mode>
entries_text=""

parse_list_line() {
    local line="$1"
    # shellcheck disable=SC2206
    local -a tok=( $line )
    local p_path="${tok[0]}"
    local p_bucket="$bucket"
    local p_prefix="$prefix"
    local p_region="$region"
    local p_sc="$storage_class"
    local p_sse="$sse"
    local p_kms="$kms_key_id"
    local p_mode="$mode"
    local i kv key val
    for ((i=1; i<${#tok[@]}; i++)); do
        kv="${tok[$i]}"
        if [[ ! "$kv" =~ ^([^=]+)=(.*)$ ]]; then
            log_warn "Invalid token: line='$line' token='$kv'"; continue
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
        case "$key" in
            Bucket)               p_bucket="$val" ;;
            Prefix)               p_prefix="$val" ;;
            Region)               p_region="$val" ;;
            KmsKeyId)             p_kms="$val" ;;
            StorageClass)
                case "$val" in STANDARD|STANDARD_IA|ONEZONE_IA|INTELLIGENT_TIERING|GLACIER|GLACIER_IR|DEEP_ARCHIVE) p_sc="$val" ;;
                    *) log_warn "Invalid StorageClass: line='$line' value='$val'" ;;
                esac ;;
            ServerSideEncryption)
                case "$val" in none|AES256|aws:kms) p_sse="$val" ;;
                    *) log_warn "Invalid ServerSideEncryption: line='$line' value='$val'" ;;
                esac ;;
            Mode)
                case "$val" in archive|mirror) p_mode="$val" ;;
                    *) log_warn "Invalid Mode: line='$line' value='$val'" ;;
                esac ;;
            *) log_warn "Unknown key: line='$line' key='$key'" ;;
        esac
    done
    entries_text+="${p_path}"$'\t'"${p_bucket}"$'\t'"${p_prefix}"$'\t'"${p_region}"$'\t'"${p_sc}"$'\t'"${p_sse}"$'\t'"${p_kms}"$'\t'"${p_mode}"$'\n'
}

if [[ -n "$path" ]]; then parse_list_line "$path"; fi

if [[ -n "$path_list" ]]; then
    if [[ ! -f "$path_list" ]]; then
        log_error "Path list file not found: pathList=$path_list"
        status="failed"; exit 2
    fi
    list_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        parse_list_line "$line"
        list_count=$((list_count+1))
    done < "$path_list"
    log_info "Loaded entries from list: pathList=$path_list count=$list_count"
fi

if [[ -z "$entries_text" ]]; then
    log_error "Specify -p or -L (or both)"
    status="failed"; exit 1
fi

entry_count=$(printf '%s' "$entries_text" | grep -c '^')
log_info "Pre-check passed: entryCount=$entry_count"

# --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・-----------------------------------------------
log_info "Main start"
stamp=$(ops_jst_stamp)

while IFS=$'\t' read -r e_path e_bucket e_prefix e_region e_sc e_sse e_kms e_mode; do
    [[ -z "$e_path" ]] && continue

    if [[ -z "$e_bucket" ]]; then
        log_warn "No bucket for entry, skipping: path=$e_path"
        failed=$((failed+1)); continue
    fi
    if [[ ! -f "$e_path" ]]; then
        log_warn "File not found, skipping: path=$e_path"
        failed=$((failed+1)); continue
    fi
    if [[ ! -s "$e_path" ]]; then
        log_info "Skip empty: file=$e_path"
        skipped=$((skipped+1)); continue
    fi

    filename=$(basename -- "$e_path")
    e_prefix_trim="${e_prefix#/}"; e_prefix_trim="${e_prefix_trim%/}"
    if [[ -n "$e_prefix_trim" ]]; then key="${e_prefix_trim}/${filename}"; else key="${filename}"; fi
    if [[ "$e_mode" == "archive" ]]; then key="${key}.${stamp}"; fi

    s3_uri="s3://${e_bucket}/${key}"

    cp_args=( --storage-class "$e_sc" )
    [[ -n "$e_region" ]] && cp_args+=( --region "$e_region" )
    case "$e_sse" in
        AES256)  cp_args+=( --sse AES256 ) ;;
        aws:kms) cp_args+=( --sse aws:kms )
                 [[ -n "$e_kms" ]] && cp_args+=( --sse-kms-key-id "$e_kms" ) ;;
    esac

    if aws s3 cp "$e_path" "$s3_uri" "${cp_args[@]}" >/dev/null 2>&1; then
        size_bytes=$(stat -c %s -- "$e_path")
        log_info "Uploaded: file=$e_path bucket=$e_bucket key=$key bytes=$size_bytes storageClass=$e_sc sse=$e_sse mode=$e_mode"
        uploaded=$((uploaded+1))
    else
        err_msg=$(aws s3 cp "$e_path" "$s3_uri" "${cp_args[@]}" 2>&1 || true)
        log_error "Upload failed: file=$e_path bucket=$e_bucket key=$key error=$err_msg"
        failed=$((failed+1))
    fi
done <<< "$entries_text"

if [[ "$uploaded" -eq 0 && "$failed" -eq 0 ]]; then
    log_info "Skipped (idempotent): reason=no_uploadable_files"
    status="skipped"
elif [[ "$uploaded" -eq 0 && "$failed" -gt 0 ]]; then
    log_error "All uploads failed"
    status="failed"; exit 4
else
    log_info "Main complete"
    if [[ "$failed" -gt 0 ]]; then status="partial"; else status="success"; fi
fi
exit 0
