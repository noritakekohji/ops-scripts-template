#!/usr/bin/env bash
# collect_snapshot.sh — Collect server snapshots from multiple tools and ZIP them
#
# Usage:
#   collect_snapshot.sh [--label|-l <label>] [--output|-o <dir>] [--menu|-m]
#
# Options:
#   --label, -l <label>  Snapshot label (optional). Included in folder/ZIP name.
#   --output, -o <dir>   Output directory (default: ./snapshots)
#   --menu, -m           Interactive TUI mode: prompts for label, output dir, tools
#
# Environment:
#   COLLECT_SNAPSHOT_TOOLS_DIR  Override the tools root directory
#                               (default: parent dir of this script)
#
# Exit codes:
#   0   All tools succeeded
#   1   One or more tools failed, OR ZIP compression failed
#   10  Required prerequisites (zip or tar) not found

set -uo pipefail

# ── Phase 1: Constants and derived paths ─────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="${COLLECT_SNAPSHOT_TOOLS_DIR:-$(dirname "$SCRIPT_DIR")}"

readonly TOOL_LIST=("server-snapshot" "port-inventory" "aws-instance-audit")

# ── Phase 2: Argument parsing ─────────────────────────────────────────────────

LABEL=""
OUTPUT_DIR="./snapshots"
MENU_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --label|-l)
            [[ $# -lt 2 ]] && { echo "ERROR: --label requires an argument" >&2; exit 1; }
            LABEL="$2"; shift 2 ;;
        --output|-o)
            [[ $# -lt 2 ]] && { echo "ERROR: --output requires an argument" >&2; exit 1; }
            OUTPUT_DIR="$2"; shift 2 ;;
        --menu|-m)
            MENU_MODE=true; shift ;;
        --)
            shift; break ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
        *)
            echo "ERROR: Unexpected argument: $1" >&2; exit 1 ;;
    esac
done

# ── Phase 3: Prerequisite check ──────────────────────────────────────────────

if ! command -v zip &>/dev/null && ! command -v tar &>/dev/null; then
    echo "ERROR: Neither zip nor tar found. Cannot compress snapshots." >&2
    exit 10
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "WARN: python3 not found; server-snapshot compare engine may be unavailable" >&2
    # Note: this is a warning, not fatal - server-snapshot collect still works without python3
fi

# ── Helper: build snapshot name ──────────────────────────────────────────────

make_timestamp() {
    date '+%Y%m%d-%H%M%S'
}

# make_snap_name <label> <ts>
make_snap_name() {
    local label="$1"
    local ts="$2"
    local hostname
    hostname="$(hostname -s 2>/dev/null || hostname)"
    if [[ -n "$label" ]]; then
        echo "${hostname}_${label}_${ts}"
    else
        echo "${hostname}_${ts}"
    fi
}

# ── Helper: run a single tool ────────────────────────────────────────────────

# run_tool <tool_name> <snap_dir> <ts>
# Writes JSON output to <snap_dir>/<tool_name>/<hostname>_<ts>.json
# Returns 0 on success, 1 on script-not-found or tool failure
run_tool() {
    local tool_name="$1"
    local snap_dir="$2"
    local ts="$3"
    local hostname
    hostname="$(hostname -s 2>/dev/null || hostname)"
    local out_dir="${snap_dir}/${tool_name}"
    local out_json="${out_dir}/${hostname}_${ts}.json"

    mkdir -p "$out_dir"

    local script_path
    case "$tool_name" in
        server-snapshot)     script_path="${TOOLS_DIR}/server-snapshot/server_snapshot.sh" ;;
        port-inventory)      script_path="${TOOLS_DIR}/port-inventory/port_inventory.sh" ;;
        aws-instance-audit)  script_path="${TOOLS_DIR}/aws-instance-audit/aws_instance_audit.sh" ;;
        *)
            echo "WARN: Unknown tool: $tool_name" >&2
            return 1 ;;
    esac

    if [[ ! -f "$script_path" ]]; then
        echo "WARN: Tool script not found: $script_path" >&2
        return 1
    fi

    case "$tool_name" in
        server-snapshot)
            bash "$script_path" collect -o "$out_json"
            ;;
        port-inventory)
            bash "$script_path" --json > "$out_json"
            ;;
        aws-instance-audit)
            bash "$script_path" -o "$out_json"
            ;;
    esac
}

# ── Helper: run all (selected) tools ─────────────────────────────────────────

# run_all <snap_dir> <ts> <log_file> [tool1 tool2 ...]
# Returns overall exit status (0 = all OK, 1 = any failure)
run_all() {
    local snap_dir="$1"
    local ts="$2"
    local log_file="$3"
    shift 3
    local tools=("$@")
    local overall_exit=0
    local total="${#tools[@]}"
    local idx=0

    for tool_name in "${tools[@]}"; do
        idx=$((idx + 1))
        printf "[%d/%d] %-22s ... " "$idx" "$total" "$tool_name"
        run_tool "$tool_name" "$snap_dir" "$ts" >> "$log_file" 2>&1
        local tool_exit=$?
        if [[ $tool_exit -eq 0 ]]; then
            echo "done (exit=0)"
            printf '[%s] %s: exit=0\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$tool_name" >> "$log_file"
        else
            overall_exit=1
            echo "WARN (exit=${tool_exit})"
            printf '[%s] %s: exit=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$tool_name" "$tool_exit" >> "$log_file"
        fi
    done

    return $overall_exit
}

# ── Helper: compress snapshot dir ────────────────────────────────────────────

# compress_snap <snap_dir> <out_dir> <snap_name>
# Compresses <out_dir>/<snap_name>/ into <out_dir>/<snap_name>.zip (or .tar.gz)
# Removes the uncompressed directory on success.
compress_snap() {
    local snap_dir="$1"
    local out_dir="$2"
    local snap_name="$3"

    printf '[collect-snapshot] compressing ... '
    local compress_exit=0

    if command -v zip &>/dev/null; then
        (cd "$out_dir" && zip -qr "${snap_name}.zip" "$snap_name") || compress_exit=$?
        if [[ $compress_exit -eq 0 ]]; then
            echo "${snap_name}.zip"
            rm -rf "$snap_dir"
        else
            echo "ERROR: zip failed (exit=${compress_exit})" >&2
        fi
    elif command -v tar &>/dev/null; then
        (cd "$out_dir" && tar -czf "${snap_name}.tar.gz" "$snap_name") || compress_exit=$?
        if [[ $compress_exit -eq 0 ]]; then
            echo "${snap_name}.tar.gz"
            rm -rf "$snap_dir"
        else
            echo "ERROR: tar failed (exit=${compress_exit})" >&2
        fi
    fi

    return $compress_exit
}

# ── Phase 4a: TUI mode ───────────────────────────────────────────────────────

do_menu() {
    echo "=== collect-snapshot TUI ==="
    echo ""

    # Step 1: label
    printf "Snapshot label (empty to skip): "
    local input_label=""
    read -r input_label
    [[ -n "$input_label" ]] && LABEL="$input_label"

    # Step 2: output directory
    read -r -p "Output directory [Enter for ${OUTPUT_DIR}]: " input_out
    [[ -n "$input_out" ]] && OUTPUT_DIR="$input_out"

    # Step 3: tool selection
    echo ""
    echo "Select tools to run (comma-separated numbers, empty = all):"
    local i=0
    for t in "${TOOL_LIST[@]}"; do
        i=$((i + 1))
        echo "  $i) $t"
    done
    printf "Selection: "
    local input_sel=""
    read -r input_sel

    local selected_tools=()
    if [[ -z "$input_sel" ]]; then
        selected_tools=("${TOOL_LIST[@]}")
    else
        IFS=',' read -ra nums <<< "$input_sel"
        for n in "${nums[@]}"; do
            n="${n// /}"
            if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#TOOL_LIST[@]} )); then
                selected_tools+=("${TOOL_LIST[$((n-1))]}")
            fi
        done
        [[ ${#selected_tools[@]} -eq 0 ]] && selected_tools=("${TOOL_LIST[@]}")
    fi

    # Snapshot archives present before run (for diff detection)
    local before_list
    before_list=$(find "$OUTPUT_DIR" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) \
        2>/dev/null | sort || true)

    do_run "${selected_tools[@]}"
    local run_status=$?

    # Completion message (TUI mode) — find the newly created archive
    local after_list zip_name
    after_list=$(find "$OUTPUT_DIR" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) \
        2>/dev/null | sort || true)
    zip_name=$(comm -13 <(echo "$before_list") <(echo "$after_list") | head -1 | xargs basename 2>/dev/null || true)
    if [[ -n "$zip_name" ]]; then
        echo "Done: created ${zip_name}"
    fi

    return $run_status
}

# ── Phase 4b: CUI (main run) logic ───────────────────────────────────────────

do_run() {
    local tools=("$@")

    local ts
    ts="$(make_timestamp)"
    local snap_name
    snap_name="$(make_snap_name "$LABEL" "$ts")"
    local out_dir="$OUTPUT_DIR"
    local snap_dir="${out_dir}/${snap_name}"
    local log_file="${snap_dir}/collect-snapshot.log"

    mkdir -p "$snap_dir"
    : > "$log_file"

    local hostname
    hostname="$(hostname -s 2>/dev/null || hostname)"
    local start_time
    start_time="$(date '+%Y-%m-%d %H:%M:%S')"

    echo "[collect-snapshot] host=${hostname}  start=${start_time}"
    echo "[collect-snapshot] output=${snap_dir}/"

    local run_exit=0
    run_all "$snap_dir" "$ts" "$log_file" "${tools[@]}" || run_exit=$?

    # Compress
    local compress_exit=0
    compress_snap "$snap_dir" "$out_dir" "$snap_name" || compress_exit=$?

    if [[ $compress_exit -ne 0 ]]; then
        run_exit=1
    fi

    if [[ $run_exit -eq 0 ]]; then
        echo "[collect-snapshot] all done."
    else
        echo "[collect-snapshot] done with warnings (exit=${run_exit})."
    fi

    return $run_exit
}

# ── Phase 4: Dispatch ─────────────────────────────────────────────────────────

if [[ "$MENU_MODE" == true ]]; then
    do_menu
else
    do_run "${TOOL_LIST[@]}"
fi
