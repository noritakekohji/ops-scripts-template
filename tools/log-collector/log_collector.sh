#!/usr/bin/env bash
# ============================================================================
# log_collector.sh -- Evidence log collector for incident response
#
# Collects log files matching preset globs within a time window, packages them
# into a zip archive with manifest.json (SHA-256 + metadata) and osinfo.txt.
#
# Usage:
#   log_collector.sh -t <presets> [-c <conf>] [-s <since>] [--from <datetime>]
#                    [--to <datetime>] [-o <output_dir>] [--max-size <MB>]
#
# Exit codes:
#   0  -- Success
#   1  -- Argument error / usage
#   2  -- No files collected (business error)
#   10 -- Prerequisite command missing (zip, sha256sum/shasum)
# ============================================================================
set -euo pipefail

# ── Phase 1: Constants & defaults ─────────────────────────────────────────

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly DEFAULT_CONF="${SCRIPT_DIR}/collect_targets.conf"
readonly DEFAULT_SINCE="24h"
readonly DEFAULT_MAX_SIZE_MB=500

# ── Phase 2: Arguments & configuration ───────────────────────────────────

TARGETS=""
CONF_FILE="$DEFAULT_CONF"
SINCE="$DEFAULT_SINCE"
FROM_DATETIME=""
TO_DATETIME=""
OUTPUT_DIR="."
MAX_SIZE_MB="$DEFAULT_MAX_SIZE_MB"

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME -t <presets> [OPTIONS]

Collect log files for incident evidence packaging.

Options:
  -t, --targets <presets>    Comma-separated preset names (required)
                             e.g. tomcat,os,nginx
  -c, --config <file>        Config file (default: collect_targets.conf)
  -s, --since <duration>     Time window: 24h, 7d, 30m (default: 24h)
  --from <datetime>          Start time (YYYY-MM-DD HH:MM:SS or date -d parseable)
  --to <datetime>            End time (default: now)
  -o, --output <dir>         Output directory (default: current dir)
  --max-size <MB>            Total size cap in MB (default: 500)
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--targets)   TARGETS="$2"; shift 2 ;;
        -c|--config)    CONF_FILE="$2"; shift 2 ;;
        -s|--since)     SINCE="$2"; shift 2 ;;
        --from)         FROM_DATETIME="$2"; shift 2 ;;
        --to)           TO_DATETIME="$2"; shift 2 ;;
        -o|--output)    OUTPUT_DIR="$2"; shift 2 ;;
        --max-size)     MAX_SIZE_MB="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Phase 3: Validation & prerequisites ──────────────────────────────────

if [[ -z "$TARGETS" ]]; then
    echo "[ERROR] -t <presets> is required" >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$CONF_FILE" ]]; then
    echo "[ERROR] Config file not found: $CONF_FILE" >&2
    exit 1
fi

if ! command -v zip &>/dev/null; then
    echo "[ERROR] 'zip' is required but not found" >&2
    exit 10
fi

# Detect sha256 command
SHA256_CMD=""
if command -v sha256sum &>/dev/null; then
    SHA256_CMD="sha256sum"
elif command -v shasum &>/dev/null; then
    SHA256_CMD="shasum -a 256"
else
    echo "[ERROR] 'sha256sum' or 'shasum' is required but not found" >&2
    exit 10
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "[ERROR] Output directory does not exist: $OUTPUT_DIR" >&2
    exit 1
fi

# Validate --max-size is numeric
if ! [[ "$MAX_SIZE_MB" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] --max-size must be a positive integer (MB)" >&2
    exit 1
fi

# ── Helper functions ─────────────────────────────────────────────────────

# Parse INI config into pipe-delimited records: preset|path_glob|max_file_size_mb
parse_config() {
    local file="$1"
    local current_section="" max_size=100
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip comments and trim
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            max_size=100
        elif [[ "$line" =~ ^max_file_size_mb[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
            max_size="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^path[[:space:]]*=[[:space:]]*(.*) ]]; then
            local p="${BASH_REMATCH[1]}"
            p="$(echo "$p" | sed 's/[[:space:]]*$//')"
            echo "${current_section}|${p}|${max_size}"
        fi
    done < "$file"
}

# Parse a duration string like 24h, 7d, 30m into seconds
parse_since() {
    local since="$1"
    local num="${since%[hdmHDM]}"
    local unit="${since: -1}"
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] Invalid --since value: $since" >&2
        return 1
    fi
    case "$unit" in
        h|H) echo $((num * 3600)) ;;
        d|D) echo $((num * 86400)) ;;
        m|M) echo $((num * 60)) ;;
        *)   echo $((num * 3600)) ;;  # default to hours
    esac
}

# Convert a datetime string to epoch seconds
datetime_to_epoch() {
    local dt="$1"
    # Try GNU date first, then BSD date
    date -d "$dt" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$dt" +%s 2>/dev/null || {
        echo "[ERROR] Cannot parse datetime: $dt" >&2
        return 1
    }
}

# Compute file SHA-256 hash
file_sha256() {
    local file="$1"
    $SHA256_CMD "$file" | awk '{print $1}'
}

# Get file mtime as epoch seconds
file_mtime_epoch() {
    local file="$1"
    # GNU stat
    stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0
}

# Get file mtime as ISO-like string
file_mtime_str() {
    local file="$1"
    local epoch
    epoch="$(file_mtime_epoch "$file")"
    # GNU date
    date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
        date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
        echo "unknown"
}

# Collect OS information
collect_osinfo() {
    local outfile="$1"
    {
        echo "=== OS Information ==="
        echo "Hostname: $(hostname)"
        echo "Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        uname -a
        echo ""
        echo "=== Disk Usage ==="
        df -h 2>/dev/null || echo "(df not available)"
        echo ""
        echo "=== Memory ==="
        free -h 2>/dev/null || vm_stat 2>/dev/null || echo "(memory info not available)"
        echo ""
        echo "=== Uptime ==="
        uptime 2>/dev/null || echo "(uptime not available)"
    } > "$outfile"
}

# Escape a string for JSON value (minimal escaping)
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}

# ── Phase 4: Main logic ──────────────────────────────────────────────────

# Compute time window (epoch seconds)
NOW_EPOCH="$(date +%s)"

if [[ -n "$FROM_DATETIME" ]]; then
    FROM_EPOCH="$(datetime_to_epoch "$FROM_DATETIME")"
else
    SINCE_SECONDS="$(parse_since "$SINCE")"
    FROM_EPOCH=$((NOW_EPOCH - SINCE_SECONDS))
fi

if [[ -n "$TO_DATETIME" ]]; then
    TO_EPOCH="$(datetime_to_epoch "$TO_DATETIME")"
else
    TO_EPOCH="$NOW_EPOCH"
fi

echo "[INFO] Time window: $(date -d "@${FROM_EPOCH}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$FROM_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null) -> $(date -d "@${TO_EPOCH}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$TO_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"

# Parse requested target list
IFS=',' read -ra TARGET_LIST <<< "$TARGETS"

# Parse config and filter to requested presets
declare -a CONFIG_ENTRIES=()
while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    CONFIG_ENTRIES+=("$entry")
done < <(parse_config "$CONF_FILE")

# Validate that all requested presets exist in config
declare -A KNOWN_PRESETS=()
for entry in "${CONFIG_ENTRIES[@]}"; do
    IFS='|' read -r preset _ _ <<< "$entry"
    KNOWN_PRESETS["$preset"]=1
done

for target in "${TARGET_LIST[@]}"; do
    target="$(echo "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [[ -z "${KNOWN_PRESETS[$target]+_}" ]]; then
        echo "[ERROR] Unknown preset: $target" >&2
        echo "[INFO] Available presets: ${!KNOWN_PRESETS[*]}" >&2
        exit 1
    fi
done

# Discover files: collect candidates as mtime_epoch|size_bytes|path
declare -a CANDIDATES=()
MAX_SIZE_BYTES=$((MAX_SIZE_MB * 1024 * 1024))

# Filter and register a single file as a candidate
register_candidate() {
    local filepath="$1" max_bytes="$2" max_mb="$3"
    local fsize fmtime
    fsize="$(stat -c %s "$filepath" 2>/dev/null || stat -f %z "$filepath" 2>/dev/null || echo 0)"
    fmtime="$(file_mtime_epoch "$filepath")"
    [[ "$fmtime" -lt "$FROM_EPOCH" || "$fmtime" -gt "$TO_EPOCH" ]] && return 0
    if [[ "$fsize" -gt "$max_bytes" ]]; then
        echo "[WARN] Skipping oversized file (${fsize} bytes > ${max_mb}MB): $filepath"
        return 0
    fi
    CANDIDATES+=("${fmtime}|${fsize}|${filepath}")
}

for target in "${TARGET_LIST[@]}"; do
    target="$(echo "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    echo "[INFO] Discovering files for preset: $target"

    for entry in "${CONFIG_ENTRIES[@]}"; do
        IFS='|' read -r preset glob max_file_mb <<< "$entry"
        [[ "$preset" != "$target" ]] && continue
        # Skip Windows paths on Linux
        [[ "$glob" =~ ^[A-Z]:\\ ]] && continue

        local_max_bytes=$((max_file_mb * 1024 * 1024))
        local glob_dir glob_name
        glob_dir="$(dirname "$glob")"
        glob_name="$(basename "$glob")"

        if [[ "$glob_dir" == *"*"* ]]; then
            while IFS= read -r filepath; do
                [[ -n "$filepath" ]] && register_candidate "$filepath" "$local_max_bytes" "$max_file_mb"
            done < <(find / -path "$glob" -type f 2>/dev/null || true)
        else
            [[ ! -d "$glob_dir" ]] && continue
            while IFS= read -r filepath; do
                [[ -n "$filepath" ]] && register_candidate "$filepath" "$local_max_bytes" "$max_file_mb"
            done < <(find "$glob_dir" -maxdepth 1 -name "$glob_name" -type f 2>/dev/null || true)
        fi
    done
done

# Deduplicate by realpath
declare -A SEEN_PATHS=()
declare -a UNIQUE_CANDIDATES=()
for candidate in "${CANDIDATES[@]}"; do
    IFS='|' read -r cmtime csize cpath <<< "$candidate"
    local rpath
    rpath="$(realpath "$cpath" 2>/dev/null || echo "$cpath")"
    if [[ -z "${SEEN_PATHS[$rpath]+_}" ]]; then
        SEEN_PATHS["$rpath"]=1
        UNIQUE_CANDIDATES+=("$candidate")
    fi
done

# Check if any files found
if [[ ${#UNIQUE_CANDIDATES[@]} -eq 0 ]]; then
    echo "[WARN] No files matched the criteria"
    exit 2
fi

echo "[INFO] Found ${#UNIQUE_CANDIDATES[@]} candidate file(s)"

# Sort by mtime descending (newest first) for size cap
IFS=$'\n' SORTED_CANDIDATES=($(printf '%s\n' "${UNIQUE_CANDIDATES[@]}" | sort -t'|' -k1,1 -rn))
unset IFS

# Apply total size cap
declare -a SELECTED_FILES=()
TOTAL_SIZE=0

for candidate in "${SORTED_CANDIDATES[@]}"; do
    IFS='|' read -r cmtime csize cpath <<< "$candidate"
    NEW_TOTAL=$((TOTAL_SIZE + csize))
    if [[ "$NEW_TOTAL" -gt "$MAX_SIZE_BYTES" ]]; then
        echo "[WARN] Size cap reached (${MAX_SIZE_MB}MB). Skipping: $cpath"
        continue
    fi
    TOTAL_SIZE="$NEW_TOTAL"
    SELECTED_FILES+=("$cpath")
done

if [[ ${#SELECTED_FILES[@]} -eq 0 ]]; then
    echo "[WARN] No files within size cap"
    exit 2
fi

TOTAL_SIZE_MB=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_SIZE} / 1048576}")
echo "[INFO] Selected ${#SELECTED_FILES[@]} file(s), total size: ${TOTAL_SIZE_MB}MB"

# Create temporary working directory
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

EVIDENCE_DIR="${WORK_DIR}/evidence"
mkdir -p "$EVIDENCE_DIR"

# Copy files preserving directory structure
COPY_COUNT=0
for filepath in "${SELECTED_FILES[@]}"; do
    # Preserve absolute path structure under evidence/
    dest="${EVIDENCE_DIR}${filepath}"
    dest_dir="$(dirname "$dest")"
    if ! mkdir -p "$dest_dir" 2>/dev/null; then
        echo "[WARN] Cannot create directory: $dest_dir"
        continue
    fi
    if ! cp "$filepath" "$dest" 2>/dev/null; then
        echo "[WARN] Permission denied, skipping: $filepath"
        continue
    fi
    ((COPY_COUNT++))
done

if [[ "$COPY_COUNT" -eq 0 ]]; then
    echo "[WARN] No files could be copied (permission denied on all)"
    exit 2
fi

echo "[INFO] Copied $COPY_COUNT file(s)"

collect_osinfo "${EVIDENCE_DIR}/osinfo.txt"
echo "[INFO] Collected OS information"

# Create manifest.json with file metadata and checksums
create_manifest() {
    local manifest="$1"
    local from_iso to_iso
    from_iso="$(date -d "@${FROM_EPOCH}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -r "$FROM_EPOCH" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
    to_iso="$(date -d "@${TO_EPOCH}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -r "$TO_EPOCH" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)"
    {
        echo "{\"hostname\":\"$(hostname)\",\"collected_at\":\"$(date '+%Y-%m-%dT%H:%M:%S%z')\","
        echo "\"time_window\":{\"from\":\"${from_iso}\",\"to\":\"${to_iso}\"},"
        echo "\"presets\":\"${TARGETS}\",\"total_size_bytes\":${TOTAL_SIZE},\"file_count\":${COPY_COUNT},"
        echo "\"files\":["
        local first=true
        for filepath in "${SELECTED_FILES[@]}"; do
            local local_dest="${EVIDENCE_DIR}${filepath}"
            [[ ! -f "$local_dest" ]] && continue
            local fsize fhash fmtime
            fsize="$(stat -c %s "$local_dest" 2>/dev/null || stat -f %z "$local_dest" 2>/dev/null || echo 0)"
            fhash="$(file_sha256 "$local_dest")"
            fmtime="$(file_mtime_str "$filepath")"
            "$first" && first=false || echo ","
            echo "{\"path\":\"$(json_escape "$filepath")\",\"size_bytes\":${fsize},\"sha256\":\"${fhash}\",\"mtime\":\"$(json_escape "$fmtime")\"}"
        done
        echo "]}"
    } > "$manifest"
}
create_manifest "${EVIDENCE_DIR}/manifest.json"
echo "[INFO] Created manifest.json"

# ── Phase 5: Package & output ────────────────────────────────────────────

HOSTNAME_SAFE="$(hostname | sed 's/[^a-zA-Z0-9._-]/_/g')"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
ZIP_NAME="evidence_${HOSTNAME_SAFE}_${TIMESTAMP}.zip"
ABS_OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
ZIP_PATH="${ABS_OUTPUT_DIR}/${ZIP_NAME}"

# Create zip archive from the evidence directory
(cd "$WORK_DIR" && zip -r "$ZIP_PATH" evidence/) > /dev/null

ZIP_SIZE="$(stat -c %s "$ZIP_PATH" 2>/dev/null || stat -f %z "$ZIP_PATH" 2>/dev/null || echo 0)"
ZIP_SIZE_MB=$(awk "BEGIN {printf \"%.1f\", ${ZIP_SIZE} / 1048576}")

echo ""
echo "===== Evidence Collection Complete ====="
echo "  Archive : ${ZIP_PATH}"
echo "  Size    : ${ZIP_SIZE_MB}MB (${ZIP_SIZE} bytes)"
echo "  Files   : ${COPY_COUNT}"
echo "  Presets : ${TARGETS}"
echo "========================================="
exit 0
