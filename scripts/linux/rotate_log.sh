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
# Behavior parameters can be set via CLI, via config files (config/<env>/
# rotate_log.conf), or fall back to script defaults. CLI > config > default.
# Per-run targets (-p / -L) are CLI-only.
#
# Naming: app.log -> app.log.YYYYMMDD-HHMMSS [.gz] (UTC).
# Exit codes: 0 success / skipped, 1 usage, 2 list file not found, 4 rotate failed
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/bash/config.sh"

usage() { sed -n '2,18p' "$0" >&2; exit 1; }

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
    case "${OPS_CONFIG[Compress]}" in
        true|TRUE|True|1) compress=1 ;;
        *)                compress=0 ;;
    esac
fi
if [[ "$copy_truncate_set" -eq 0 && -n "${OPS_CONFIG[CopyTruncate]:-}" ]]; then
    case "${OPS_CONFIG[CopyTruncate]}" in
        true|TRUE|True|1) copy_truncate=1 ;;
        *)                copy_truncate=0 ;;
    esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

# --- Phase 1 (cont): validation ---------------------------------------------
if ! [[ "$max_size_mb" =~ ^[0-9]+$ ]] \
    || ! [[ "$max_age_days" =~ ^[0-9]+$ ]] \
    || ! [[ "$retention" =~ ^[0-9]+$ ]]; then
    log_error "Numeric arguments must be non-negative integers"
    status="failed"; exit 1
fi
if [[ "$max_size_mb" -le 0 && "$max_age_days" -le 0 ]]; then
    log_error "At least one of -s or -a must be > 0"
    status="failed"; exit 1
fi

log_info "Args validated: path='$path' pathList='$path_list' pattern='$pattern' maxSizeMB=$max_size_mb maxAgeDays=$max_age_days compress=$compress retention=$retention copyTruncate=$copy_truncate dryRun=$dry_run"

# --- Phase 3: pre-check (collect targets) -----------------------------------
log_info "Pre-check start"

declare -a target_paths=()
[[ -n "$path" ]] && target_paths+=( "$path" )

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
        target_paths+=( "$line" )
        list_count=$((list_count+1))
    done < "$path_list"
    log_info "Loaded paths from list: pathList=$path_list count=$list_count"
fi

if [[ "${#target_paths[@]}" -eq 0 ]]; then
    log_error "Specify -p or -L (or both)"
    status="failed"; exit 1
fi

declare -a files=()
for p in "${target_paths[@]}"; do
    if [[ ! -e "$p" ]]; then
        log_warn "Path not found, skipping: path=$p"
        continue
    fi
    if [[ -d "$p" ]]; then
        matched=0
        while IFS= read -r -d '' f; do
            files+=( "$f" )
            matched=$((matched+1))
        done < <(find "$p" -maxdepth 1 -type f -name "$pattern" -print0)
        log_debug "Resolved directory: path=$p matched=$matched"
    else
        files+=( "$p" )
    fi
done

if [[ "${#files[@]}" -gt 0 ]]; then
    declare -A seen=()
    declare -a unique=()
    for f in "${files[@]}"; do
        if [[ -z "${seen[$f]:-}" ]]; then
            seen[$f]=1
            unique+=( "$f" )
        fi
    done
    files=( "${unique[@]}" )
fi

if [[ "${#files[@]}" -eq 0 ]]; then
    log_info "Skipped (idempotent): reason=no_matching_files"
    status="skipped"; exit 0
fi

log_info "Pre-check passed: matched=${#files[@]}"

# --- Phase 4: main processing -----------------------------------------------
log_info "Main start"

now_epoch=$(date +%s)
cutoff_epoch=0
if [[ "$max_age_days" -gt 0 ]]; then
    cutoff_epoch=$(( now_epoch - max_age_days * 86400 ))
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
    if [[ "$max_size_mb" -gt 0 ]]; then
        threshold=$(( max_size_mb * 1024 * 1024 ))
        if [[ "$size_bytes" -ge "$threshold" ]]; then
            need_rotate=1
            reason="size=$(( size_bytes / 1024 / 1024 ))MB>=$max_size_mb"
        fi
    fi
    if [[ "$need_rotate" -eq 0 && "$cutoff_epoch" -gt 0 && "$mtime_epoch" -lt "$cutoff_epoch" ]]; then
        need_rotate=1
        reason="mtime_older_than_${max_age_days}d"
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

    if [[ "$copy_truncate" -eq 1 ]]; then
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

    if [[ "$compress" -eq 1 ]]; then
        if gzip -- "$rotated_path"; then
            log_info "Compressed: file=${rotated_path}.gz"
        else
            log_warn "Compression failed: file=$rotated_path"
        fi
    fi
done

if [[ "$retention" -gt 0 && "$dry_run" -eq 0 ]]; then
    for f in "${files[@]}"; do
        shopt -s nullglob
        peers=( "${f}".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]* )
        shopt -u nullglob

        if [[ "${#peers[@]}" -gt "$retention" ]]; then
            IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${peers[@]}" | sort -r && printf '\0')
            for ((i=retention; i<${#sorted[@]}; i++)); do
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

log_info "Main complete"
status="success"
exit 0
