#!/usr/bin/env bash
# ============================================================================
# rotate_log.sh
#   Rotate log files based on size or age, with optional gzip compression.
#
# Usage:
#   rotate_log.sh -p <path> [-P <pattern>] [-s <max-size-mb>] [-a <max-age-days>]
#                 [-c] [-k <retention>] [-T] [-n]
#
# Options:
#   -p  Log file path, OR directory containing logs (required)
#   -P  Glob pattern when -p is a directory (default: *.log)
#   -s  Rotate when size >= this many MB (0 disables)
#   -a  Rotate when mtime older than this many days (0 disables)
#   -c  Gzip the rotated file
#   -k  Keep at most this many rotated files per source (0 disables)
#   -T  Use copy+truncate instead of rename
#   -n  Dry run (only log what would happen)
#
# At least one of -s or -a must be > 0.
#
# Naming: app.log -> app.log.YYYYMMDD-HHMMSS [.gz]   (UTC timestamp)
# Exit codes: 0 ok, 1 usage/validation, 2 path not found, 4 rotation failed
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"

usage() { sed -n '2,22p' "$0" >&2; exit 1; }

path=""
pattern="*.log"
max_size_mb=0
max_age_days=0
compress=0
retention=0
copy_truncate=0
dry_run=0

while getopts "p:P:s:a:ck:Tnh" opt; do
    case "$opt" in
        p) path="$OPTARG" ;;
        P) pattern="$OPTARG" ;;
        s) max_size_mb="$OPTARG" ;;
        a) max_age_days="$OPTARG" ;;
        c) compress=1 ;;
        k) retention="$OPTARG" ;;
        T) copy_truncate=1 ;;
        n) dry_run=1 ;;
        h|*) usage ;;
    esac
done

[[ -z "$path" ]] && usage

if ! [[ "$max_size_mb" =~ ^[0-9]+$ ]] \
    || ! [[ "$max_age_days" =~ ^[0-9]+$ ]] \
    || ! [[ "$retention" =~ ^[0-9]+$ ]]; then
    log_error "Numeric arguments must be non-negative integers"
    exit 1
fi
if [[ "$max_size_mb" -le 0 && "$max_age_days" -le 0 ]]; then
    log_error "At least one of -s or -a must be > 0"
    exit 1
fi
if [[ ! -e "$path" ]]; then
    log_error "Path not found: path=$path"
    exit 2
fi

# --- resolve target files ---------------------------------------------------
declare -a files=()
if [[ -d "$path" ]]; then
    while IFS= read -r -d '' f; do
        files+=( "$f" )
    done < <(find "$path" -maxdepth 1 -type f -name "$pattern" -print0)
else
    files=( "$path" )
fi

if [[ "${#files[@]}" -eq 0 ]]; then
    log_info "No matching files: path=$path pattern=$pattern"
    exit 0
fi

log_info "Rotation start: path=$path matched=${#files[@]} maxSizeMB=$max_size_mb maxAgeDays=$max_age_days compress=$compress retention=$retention copyTruncate=$copy_truncate dryRun=$dry_run"

now_epoch=$(date +%s)
cutoff_epoch=0
if [[ "$max_age_days" -gt 0 ]]; then
    cutoff_epoch=$(( now_epoch - max_age_days * 86400 ))
fi

rotated=0
skipped=0

for f in "${files[@]}"; do
    if [[ ! -s "$f" ]]; then
        log_debug "Skip empty: file=$f"
        skipped=$((skipped+1))
        continue
    fi

    # GNU stat (Linux). %s = size in bytes, %Y = mtime epoch, %a = mode.
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

# --- retention pruning ------------------------------------------------------
if [[ "$retention" -gt 0 && "$dry_run" -eq 0 ]]; then
    for f in "${files[@]}"; do
        shopt -s nullglob
        # Match: <file>.YYYYMMDD-HHMMSS  optionally followed by anything (.gz)
        peers=( "${f}".[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]* )
        shopt -u nullglob

        if [[ "${#peers[@]}" -gt "$retention" ]]; then
            # Sort newest first by name (timestamp suffix is lexicographic chronological)
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

log_info "Rotation complete: rotated=$rotated skipped=$skipped"
exit 0
