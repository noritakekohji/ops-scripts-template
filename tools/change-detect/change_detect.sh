#!/usr/bin/env bash
# ============================================================================
# change_detect.sh  -  Capture server state before/after a change and compare
# Requires: bash 4+, python3
# Depends:  ../server-compare/get_server_info.sh
#
# Usage:
#   ./change_detect.sh before  [-l <label>] [-c <cats>] [-o <file>]
#   ./change_detect.sh after   [-l <label>] [-c <cats>] [-o <file>]
#                              [-b <before.json>] [--html <file>]
#   ./change_detect.sh compare <before.json> <after.json> [--html <file>]
#
# Modes:
#   before   Collect server info and save as "before" snapshot
#   after    Collect server info, auto-find latest "before", and compare
#   compare  Compare two existing snapshot files directly
#
# Options:
#   -l <label>    Label embedded in filename (e.g. deploy-v1.2.3)
#   -c <cats>     Categories: all, os, network, services, packages,
#                 users, filesystem, environment, security (default: all)
#   -o <file>     Output snapshot path (default: auto-named)
#   -b <file>     Before snapshot to use when running "after" mode
#   --html <file> Generate HTML comparison report
#
# Examples:
#   ./change_detect.sh before -l deploy-v1.2.3
#   ./change_detect.sh after  -l deploy-v1.2.3 --html report.html
#   ./change_detect.sh compare before.json after.json --html report.html
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GET_INFO="${SCRIPT_DIR}/../server-compare/get_server_info.sh"
# 比較ロジックは tools/server-compare/compare_server_info.py に集約
# （PowerShell 版 Compare-ServerInfo.ps1 もこの .py を呼び出すため、
#  カテゴリ・volatile 除外ルール・HTML 出力が両プラットフォームで揃う）
COMPARE_PY="${SCRIPT_DIR}/../server-compare/compare_server_info.py"

# ============================================================
# Argument parsing
# ============================================================

mode="${1:-}"
if [[ -z "$mode" ]]; then
    echo "Usage: $0 <before|after|compare> [options]" >&2; exit 1
fi
shift

label=""
categories="all"
output_file=""
before_file=""
after_file=""
html_report=""

case "$mode" in
  before|after)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -l|--label)    label="$2";      shift 2 ;;
        -c|--category) categories="$2"; shift 2 ;;
        -o|--output)   output_file="$2"; shift 2 ;;
        -b|--before)   before_file="$2"; shift 2 ;;
        --html)        html_report="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    ;;
  compare)
    before_file="${1:-}"; after_file="${2:-}"
    if [[ -z "$before_file" || -z "$after_file" ]]; then
        echo "Usage: $0 compare <before.json> <after.json> [--html <file>]" >&2; exit 1
    fi
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --html) html_report="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    ;;
  *)
    echo "Unknown mode: $mode  (use: before | after | compare)" >&2; exit 1 ;;
esac

if ! command -v python3 &>/dev/null; then echo "Error: python3 is required" >&2; exit 10; fi

hostname_s=$(hostname -s 2>/dev/null || echo "localhost")
ts=$(date '+%Y%m%d-%H%M%S')
label_part="${label:+_${label}}"

# ============================================================
# Snapshot collection
# ============================================================

collect_snapshot() {
    local snap_type="$1"  # before | after
    local snap_file="$2"

    if [[ ! -f "$GET_INFO" ]]; then
        echo "Error: get_server_info.sh not found: $GET_INFO" >&2; exit 1
    fi

    echo ""
    echo "=== Collecting ${snap_type^^} snapshot ==="
    echo "  Host       : $hostname_s"
    echo "  Categories : $categories"
    echo "  Output     : $snap_file"
    echo ""

    bash "$GET_INFO" -c "$categories" -o "$snap_file"
}

# Find the most recent *_before_*.json in current directory
find_latest_before() {
    local latest=""
    # Sort by filename descending (timestamp in name gives correct order)
    for f in $(ls -t ${hostname_s}_before*.json 2>/dev/null); do
        latest="$f"; break
    done
    echo "$latest"
}

# ============================================================
# Comparison (Python)
# ============================================================

run_comparison() {
    local bf="$1"
    local af="$2"
    local html="$3"

    if [[ ! -f "$bf" ]]; then echo "Error: before file not found: $bf" >&2; exit 2; fi
    if [[ ! -f "$af" ]]; then echo "Error: after  file not found: $af" >&2; exit 2; fi
    if [[ ! -f "$COMPARE_PY" ]]; then
        echo "Error: compare engine not found: $COMPARE_PY" >&2; exit 10
    fi

    local py_args=( "$bf" "$af" )
    [[ -n "$html" ]]       && py_args+=( --html "$html" )
    [[ -n "$hostname_s" ]] && py_args+=( --hostname "$hostname_s" )
    python3 "$COMPARE_PY" "${py_args[@]}"
    return $?
}


# ============================================================
# Main
# ============================================================

case "$mode" in
  before)
    [[ -z "$output_file" ]] && output_file="${hostname_s}_before${label_part}_${ts}.json"
    collect_snapshot "before" "$output_file"
    echo ""
    echo "  Before snapshot saved: $output_file"
    echo "  Run './change_detect.sh after${label:+ -l }${label}' after making your changes."
    ;;

  after)
    [[ -z "$output_file" ]] && output_file="${hostname_s}_after${label_part}_${ts}.json"
    collect_snapshot "after" "$output_file"
    after_file="$output_file"

    # Auto-find the latest before snapshot if not specified
    if [[ -z "$before_file" ]]; then
        before_file=$(find_latest_before)
        if [[ -z "$before_file" ]]; then
            echo "Error: No before snapshot found in current directory." >&2
            echo "  Run './change_detect.sh before' first, or specify with -b <file>" >&2
            exit 1
        fi
        echo "  Using before snapshot: $before_file"
    fi

    run_comparison "$before_file" "$after_file" "$html_report"
    ;;

  compare)
    run_comparison "$before_file" "$after_file" "$html_report"
    ;;
esac
