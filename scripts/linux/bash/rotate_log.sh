#!/usr/bin/env bash
# ============================================================================
# rotate_log.sh
#   Rotate log files based on size or age, with optional gzip compression.
#
# Usage:
#   rotate_log.sh [-p <path>] [-L <list-file>] [-P <pattern>]
#                 [-s <max-size-mb>] [-a <max-age-days>]
#                 [-c] [-k <retention>] [-T] [-n]
#
# Each line in the list file (-L) may set per-target overrides:
#     <path> [Key=Value ...]
# Recognised keys (case-sensitive):
#   Pattern, MaxSizeMB, MaxAgeDays, Compress, RetentionCount, CopyTruncate
# Resolution: per-line > CLI > config > script default.
# Unknown keys / invalid values are warned and skipped (entry still runs
# with inherited values). An entry with both MaxSizeMB and MaxAgeDays
# effectively 0 is warned and skipped. Other entries are unaffected.
#
# Naming: <name>.YYYYMMDD-HHMMSS [.gz] (UTC).
# Exit codes: 0 success / skipped, 1 usage, 2 list file not found, 4 rotate failed
# ============================================================================
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

# --- Phase 1: argument parsing ----------------------------------------------
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

# --- Phase 2: load config and apply to unspecified ---------------------------
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

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

# --- Phase 1 (cont): basic numeric validation -------------------------------
if ! [[ "$max_size_mb" =~ ^[0-9]+$ ]] \
    || ! [[ "$max_age_days" =~ ^[0-9]+$ ]] \
    || ! [[ "$retention" =~ ^[0-9]+$ ]]; then
    log_error "Numeric arguments must be non-negative integers"
    status="failed"; exit 1
fi

log_info "Args validated: path='$path' pathList='$path_list' pattern='$pattern' maxSizeMB=$max_size_mb maxAgeDays=$max_age_days compress=$compress retention=$retention copyTruncate=$copy_truncate dryRun=$dry_run"

# --- Phase 3: pre-check (collect targets) -----------------------------------
log_info "Pre-check start"

# Each target is encoded as a tab-separated record:
# <path>\t<pattern>\t<maxSizeMB>\t<maxAgeDays>\t<compress>\t<retention>\t<copyTruncate>
# Stored line by line in $targets_text (newline-separated).
targets_text=""

parse_list_line() {
    # In : $1 = raw line (already trimmed; non-empty; non-comment)
    # Out: appends one tab-record to $targets_text
    local line="$1"
    # shellcheck disable=SC2206
    local -a tok=( $line )    # split on whitespace
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

# --- Phase 4: main processing (per target) ----------------------------------
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

        stamp=$(date -u +"%Y%m%d-%H%M%S")
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

    # Per-target retention pruning
    if [[ "$t_retention" -gt 0 && "$dry_run" -eq 0 ]]; then
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
