#!/usr/bin/env bash
# ============================================================================
# rotate_log.sh
#   繝ｭ繧ｰ繝輔ぃ繧､繝ｫ繧偵し繧､繧ｺ縺ｾ縺溘・邨碁℃譎る俣縺ｧ繝ｭ繝ｼ繝・・繝茨ｼ井ｻｻ諢上〒 gzip 蝨ｧ邵ｮ・・#
# 菴ｿ縺・婿:
#   rotate_log.sh [-p <path>] [-L <list-file>] [-P <pattern>]
#                 [-s <max-size-mb>] [-a <max-age-days>]
#                 [-c] [-k <retention>] [-T] [-n]
#
# -L 縺ｮ繝ｪ繧ｹ繝亥推陦後〒蟇ｾ雎｡縺斐→縺ｮ荳頑嶌縺阪′蜿ｯ閭ｽ:
#     <path> [Key=Value ...]
# 蜿励￠莉倥￠繧九く繝ｼ・・ase-sensitive・・
#   Pattern, MaxSizeMB, MaxAgeDays, Compress, RetentionCount, CopyTruncate
# 隗｣豎ｺ鬆・ｽ・ 陦悟・ > CLI > config > 譌｢螳壼､
# 荳肴・繧ｭ繝ｼ / 荳肴ｭ｣蛟､縺ｯ WARN 繧貞・縺励※縺昴・繧ｭ繝ｼ縺縺醍┌隕厄ｼ医お繝ｳ繝医Μ縺ｯ邯呎価蛟､縺ｧ螳溯｡鯉ｼ・# MaxSizeMB 縺ｨ MaxAgeDays 縺ｮ荳｡譁ｹ縺・effective=0 縺ｮ繧ｨ繝ｳ繝医Μ縺ｯ
# WARN 繧貞・縺励※縺昴・繧ｨ繝ｳ繝医Μ縺ｮ縺ｿ繧ｹ繧ｭ繝・・縲ゆｻ悶↓縺ｯ豕｢蜿翫＠縺ｪ縺・#
# 蜻ｽ蜷・ <name>.YYYYMMDD-HHMMSS [.gz]・・ST・・# 邨ゆｺ・さ繝ｼ繝・ 0 謌仙粥/繧ｹ繧ｭ繝・・, 1 usage, 2 繝ｪ繧ｹ繝医ヵ繧｡繧､繝ｫ荳榊惠, 4 繝ｭ繝ｼ繝・・繝亥､ｱ謨・# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

usage() { sed -n '2,22p' "$0" >&2; exit 1; }

status="unknown"
rotated=0
skipped=0

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc rotated=$rotated skipped=$skipped"
}
trap cleanup EXIT

# --- 繝輔ぉ繝ｼ繧ｺ 1: 蠑墓焚繝代・繧ｹ ----------------------------------------------
path=""
path_list=""
pattern="*.log"
max_size_mb=0
max_age_days=0
compress=0
retention=0
copy_truncate=0
dry_run=0

pattern_set=0
max_size_set=0
max_age_set=0
compress_set=0
retention_set=0
copy_truncate_set=0

while getopts "p:L:P:s:a:ck:Tnh" opt; do
    case "$opt" in
        p) path="$OPTARG" ;;
        L) path_list="$OPTARG" ;;
        P) pattern="$OPTARG"; pattern_set=1 ;;
        s) max_size_mb="$OPTARG"; max_size_set=1 ;;
        a) max_age_days="$OPTARG"; max_age_set=1 ;;
        c) compress=1; compress_set=1 ;;
        k) retention="$OPTARG"; retention_set=1 ;;
        T) copy_truncate=1; copy_truncate_set=1 ;;
        n) dry_run=1 ;;
        h|*) usage ;;
    esac
done

# --- 繝輔ぉ繝ｼ繧ｺ 2: 險ｭ螳壹ヵ繧｡繧､繝ｫ隱ｭ霎ｼ縺ｿ縲∵悴謖・ｮ壼､縺ｸ蜿肴丐 ---------------------------
load_ops_config "rotate_log"
[[ "$pattern_set" -eq 0    && -n "${OPS_CONFIG[Pattern]:-}"        ]] && pattern="${OPS_CONFIG[Pattern]}"
[[ "$max_size_set" -eq 0   && -n "${OPS_CONFIG[MaxSizeMB]:-}"      ]] && max_size_mb="${OPS_CONFIG[MaxSizeMB]}"
[[ "$max_age_set" -eq 0    && -n "${OPS_CONFIG[MaxAgeDays]:-}"     ]] && max_age_days="${OPS_CONFIG[MaxAgeDays]}"
[[ "$retention_set" -eq 0  && -n "${OPS_CONFIG[RetentionCount]:-}" ]] && retention="${OPS_CONFIG[RetentionCount]}"
if [[ "$compress_set" -eq 0 && -n "${OPS_CONFIG[Compress]:-}" ]]; then
    case "${OPS_CONFIG[Compress]}" in true|TRUE|True|1) compress=1 ;; *) compress=0 ;; esac
fi
if [[ "$copy_truncate_set" -eq 0 && -n "${OPS_CONFIG[CopyTruncate]:-}" ]]; then
    case "${OPS_CONFIG[CopyTruncate]}" in true|TRUE|True|1) copy_truncate=1 ;; *) copy_truncate=0 ;; esac
fi
# -L 譛ｪ謖・ｮ壹↑繧・config 縺ｮ PathList 繧呈治逕ｨ縲ら嶌蟇ｾ繝代せ縺ｯ repo root 襍ｷ轤ｹ縺ｧ邨ｶ蟇ｾ蛹悶・if [[ -z "$path_list" && -n "${OPS_CONFIG[PathList]:-}" ]]; then
    path_list="${OPS_CONFIG[PathList]}"
    if [[ "$path_list" != /* ]]; then
        path_list="$(ops_repo_root)/$path_list"
    fi
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"

# --- 繝輔ぉ繝ｼ繧ｺ 1・育ｶ壹″・・ 謨ｰ蛟､繝舌Μ繝・・繧ｷ繝ｧ繝ｳ -------------------------------
if ! [[ "$max_size_mb" =~ ^[0-9]+$ ]] \
    || ! [[ "$max_age_days" =~ ^[0-9]+$ ]] \
    || ! [[ "$retention" =~ ^[0-9]+$ ]]; then
    log_error "Numeric arguments must be non-negative integers"
    status="failed"; exit 1
fi

log_info "Args validated: path='$path' pathList='$path_list' pattern='$pattern' maxSizeMB=$max_size_mb maxAgeDays=$max_age_days compress=$compress retention=$retention copyTruncate=$copy_truncate dryRun=$dry_run"

# --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け・亥ｯｾ雎｡蜿朱寔・・-----------------------------------
log_info "Pre-check start"

# 蜷・ち繝ｼ繧ｲ繝・ヨ縺ｯ繧ｿ繝門玄蛻・ｊ繝ｬ繧ｳ繝ｼ繝峨→縺励※繧ｨ繝ｳ繧ｳ繝ｼ繝・
# <path>\t<pattern>\t<maxSizeMB>\t<maxAgeDays>\t<compress>\t<retention>\t<copyTruncate>
# $targets_text 縺ｫ 1 陦後★縺､闢・ｩ搾ｼ域隼陦悟玄蛻・ｊ・・targets_text=""

parse_list_line() {
    # 蜈･蜉・ $1 = 陦鯉ｼ・rim 貂医∩縲∫ｩｺ繝ｻ繧ｳ繝｡繝ｳ繝医・髯､螟匁ｸ医∩・・    # 蜃ｺ蜉・ $targets_text 縺ｫ繧ｿ繝悶Ξ繧ｳ繝ｼ繝峨ｒ霑ｽ險・    local line="$1"
    # shellcheck disable=SC2206
    local -a tok=( $line )    # 遨ｺ逋ｽ縺ｧ split
    local p_path="${tok[0]}"
    local p_pattern="$pattern"
    local p_size="$max_size_mb"
    local p_age="$max_age_days"
    local p_compress="$compress"
    local p_retention="$retention"
    local p_copytruncate="$copy_truncate"
    local i kv key val
    for ((i=1; i<${#tok[@]}; i++)); do
        kv="${tok[$i]}"
        if [[ ! "$kv" =~ ^([^=]+)=(.*)$ ]]; then
            log_warn "Invalid token in list line: line='$line' token='$kv'"
            continue
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        case "$key" in
            Pattern) p_pattern="$val" ;;
            MaxSizeMB)
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -le 1048576 ]]; then p_size="$val"
                else log_warn "Invalid MaxSizeMB: line='$line' value='$val'"; fi ;;
            MaxAgeDays)
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -le 3650 ]]; then p_age="$val"
                else log_warn "Invalid MaxAgeDays: line='$line' value='$val'"; fi ;;
            RetentionCount)
                if [[ "$val" =~ ^[0-9]+$ ]] && [[ "$val" -le 10000 ]]; then p_retention="$val"
                else log_warn "Invalid RetentionCount: line='$line' value='$val'"; fi ;;
            Compress)
                case "$val" in true|TRUE|True|1) p_compress=1 ;; false|FALSE|False|0) p_compress=0 ;;
                    *) log_warn "Invalid Compress: line='$line' value='$val'" ;;
                esac ;;
            CopyTruncate)
                case "$val" in true|TRUE|True|1) p_copytruncate=1 ;; false|FALSE|False|0) p_copytruncate=0 ;;
                    *) log_warn "Invalid CopyTruncate: line='$line' value='$val'" ;;
                esac ;;
            *) log_warn "Unknown key in list line: line='$line' key='$key'" ;;
        esac
    done
    targets_text+="${p_path}"$'\t'"${p_pattern}"$'\t'"${p_size}"$'\t'"${p_age}"$'\t'"${p_compress}"$'\t'"${p_retention}"$'\t'"${p_copytruncate}"$'\n'
}

if [[ -n "$path" ]]; then
    parse_list_line "$path"
fi

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

if [[ -z "$targets_text" ]]; then
    log_error "Specify -p or -L (or both)"
    status="failed"; exit 1
fi

target_count=$(printf '%s' "$targets_text" | grep -c '^')
log_info "Pre-check passed: targetCount=$target_count"

# --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・ｼ亥ｯｾ雎｡縺斐→・・----------------------------------
log_info "Main start"

while IFS=$'\t' read -r t_path t_pattern t_size t_age t_compress t_retention t_copytruncate; do
    [[ -z "$t_path" ]] && continue

    if [[ ! -e "$t_path" ]]; then
        log_warn "Path not found, skipping: path=$t_path"
        continue
    fi
    if [[ "$t_size" -le 0 && "$t_age" -le 0 ]]; then
        log_warn "No trigger for target (MaxSizeMB and MaxAgeDays both 0), skipping: path=$t_path"
        continue
    fi

    declare -a files=()
    if [[ -d "$t_path" ]]; then
        matched=0
        while IFS= read -r -d '' f; do
            files+=( "$f" )
            matched=$((matched+1))
        done < <(find "$t_path" -maxdepth 1 -type f -name "$t_pattern" -print0)
        log_debug "Resolved directory: path=$t_path pattern=$t_pattern matched=$matched"
    else
        files=( "$t_path" )
    fi
    if [[ "${#files[@]}" -eq 0 ]]; then continue; fi

    now_epoch=$(date +%s)
    cutoff_epoch=0
    if [[ "$t_age" -gt 0 ]]; then
        cutoff_epoch=$(( now_epoch - t_age * 86400 ))
    fi

    for f in "${files[@]}"; do
        if [[ ! -s "$f" ]]; then
            log_debug "Skip empty: file=$f"
            skipped=$((skipped+1))
            continue
        fi

        size_bytes=$(stat -c %s -- "$f")
        mtime_epoch=$(stat -c %Y -- "$f")

        need_rotate=0
        reason=""
        if [[ "$t_size" -gt 0 ]]; then
            threshold=$(( t_size * 1024 * 1024 ))
            if [[ "$size_bytes" -ge "$threshold" ]]; then
                need_rotate=1
                reason="size=$(( size_bytes / 1024 / 1024 ))MB>=$t_size"
            fi
        fi
        if [[ "$need_rotate" -eq 0 && "$cutoff_epoch" -gt 0 && "$mtime_epoch" -lt "$cutoff_epoch" ]]; then
            need_rotate=1
            reason="mtime_older_than_${t_age}d"
        fi

        if [[ "$need_rotate" -eq 0 ]]; then
            log_debug "Skip: file=$f size=$size_bytes"
            skipped=$((skipped+1))
            continue
        fi

        stamp=$(ops_jst_stamp)
        rotated_path="${f}.${stamp}"

        if [[ "$dry_run" -eq 1 ]]; then
            log_info "[DRY-RUN] would rotate: from=$f to=$rotated_path reason=$reason"
            rotated=$((rotated+1))
            continue
        fi

        if [[ "$t_copytruncate" -eq 1 ]]; then
            if cp -p -- "$f" "$rotated_path" && : > "$f"; then
                log_info "Rotated (copytruncate): from=$f to=$rotated_path reason=$reason"
            else
                log_error "Rotation failed: file=$f"
                continue
            fi
        else
            mode=$(stat -c %a -- "$f")
            if mv -- "$f" "$rotated_path" && touch -- "$f" && chmod "$mode" -- "$f"; then
                log_info "Rotated (rename): from=$f to=$rotated_path reason=$reason"
            else
                log_error "Rotation failed: file=$f"
                continue
            fi
        fi

        rotated=$((rotated+1))

        if [[ "$t_compress" -eq 1 ]]; then
            if gzip -- "$rotated_path"; then
                log_info "Compressed: file=${rotated_path}.gz"
            else
                log_warn "Compression failed: file=$rotated_path"
            fi
        fi
    done

    # 蟇ｾ雎｡縺斐→縺ｮ荳紋ｻ｣菫晄戟・亥商縺・ｂ縺ｮ縺九ｉ蜑企勁・・    if [[ "$t_retention" -gt 0 && "$dry_run" -eq 0 ]]; then
        for f in "${files[@]}"; do
            shopt -s nullglob
            peers=( "${f}".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]* )
            shopt -u nullglob
            if [[ "${#peers[@]}" -gt "$t_retention" ]]; then
                IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${peers[@]}" | sort -r && printf '\0')
                for ((i=t_retention; i<${#sorted[@]}; i++)); do
                    p="${sorted[$i]}"
                    if rm -f -- "$p"; then
                        log_info "Pruned: file=$p"
                    else
                        log_warn "Prune failed: file=$p"
                    fi
                done
            fi
        done
    fi
done <<< "$targets_text"

if [[ "$rotated" -eq 0 && "$skipped" -gt 0 ]]; then
    log_info "Skipped (idempotent): reason=no_files_required_rotation"
    status="skipped"
else
    log_info "Main complete"
    status="success"
fi
exit 0
