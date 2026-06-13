#!/usr/bin/env bash
# ============================================================================
# port_inventory.sh — Listening port inventory and audit tool
#
# Usage:
#   port_inventory.sh [-e <expected_list>] [--json] [--html <path>] [--fail-only]
#
# Collects all LISTEN TCP/UDP ports with process info.
# Primary: ss -tulnp  (modern Linux)
# Fallback: netstat -tulnp  (older systems)
#
# Expected list format (CSV):
#   <port>, <proto>, <expected>, <description>
#   - proto: tcp / udp
#   - expected: ok (should be listening) / ng (should NOT be listening) / - (info)
#   - Lines starting with # are comments; blank lines are skipped
#
# Exit codes:
#   0  — All OK or no evaluation (inventory only)
#   1  — One or more NG findings
#   2  — Expected list file not found
#   10 — Prerequisite missing (neither ss nor netstat available)
# ============================================================================
set -euo pipefail

# ── Phase 2: Arguments & defaults ──────────────────────────────────────────

EXPECTED_LIST=""
OUTPUT_JSON=false
HTML_PATH=""
FAIL_ONLY=false

usage() {
    cat <<'EOF'
Usage: port_inventory.sh [-e <expected_list>] [OPTIONS]

Options:
  -e, --expected <file>   Path to expected port list (optional)
  --json                  Output as JSON array
  --html <path>           Generate HTML report file
  --fail-only             Show only NG and WARN entries
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--expected)  EXPECTED_LIST="$2"; shift 2 ;;
        --json)         OUTPUT_JSON=true; shift ;;
        --html)         HTML_PATH="$2"; shift 2 ;;
        --fail-only)    FAIL_ONLY=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Phase 3: Validation ───────────────────────────────────────────────────

if [[ -n "$EXPECTED_LIST" && ! -f "$EXPECTED_LIST" ]]; then
    echo "[ERROR] Expected list not found: $EXPECTED_LIST" >&2
    exit 2
fi

PORT_CMD=""
if command -v ss &>/dev/null; then
    PORT_CMD="ss"
elif command -v netstat &>/dev/null; then
    PORT_CMD="netstat"
else
    echo "[ERROR] Neither ss nor netstat found" >&2
    exit 10
fi

# ── Phase 4: Main logic ───────────────────────────────────────────────────

# Trim leading/trailing whitespace from a string
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    echo "$s"
}

# Collect listening ports via ss.
# Output: pipe-delimited records — port|proto|address|process|pid
collect_ports_ss() {
    ss -tulnp 2>/dev/null | tail -n +2 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local proto local_addr process_info
        proto=$(echo "$line" | awk '{print $1}')
        local_addr=$(echo "$line" | awk '{print $5}')
        process_info=$(echo "$line" | awk '{for(i=7;i<=NF;i++) printf "%s ", $i; print ""}')

        # Normalize protocol to lowercase
        proto="${proto,,}"
        # Strip trailing 6 for IPv6 variants (tcp6 -> tcp, udp6 -> udp)
        proto="${proto%6}"

        # Split address into addr and port
        local addr port
        if [[ "$local_addr" == *"]:"* ]]; then
            # IPv6: [::1]:8080 or [::]:80
            addr="${local_addr%:*}"
            addr="${addr#\[}"
            addr="${addr%\]}"
            port="${local_addr##*:}"
        elif [[ "$local_addr" == *":"* ]]; then
            addr="${local_addr%:*}"
            port="${local_addr##*:}"
        else
            addr="*"
            port="$local_addr"
        fi

        # Extract process name and PID from users:(("sshd",pid=1234,...))
        local pname pid
        pname=""
        pid=""
        if [[ "$process_info" =~ users:\(\(\"([^\"]+)\",pid=([0-9]+) ]]; then
            pname="${BASH_REMATCH[1]}"
            pid="${BASH_REMATCH[2]}"
        fi

        echo "${port}|${proto}|${addr}|${pname}|${pid}"
    done
}

# Collect listening ports via netstat (fallback).
# Output: same pipe-delimited format as collect_ports_ss
collect_ports_netstat() {
    netstat -tulnp 2>/dev/null | tail -n +3 | while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local proto local_addr pid_prog
        proto=$(echo "$line" | awk '{print $1}')
        local_addr=$(echo "$line" | awk '{print $4}')
        pid_prog=$(echo "$line" | awk '{print $NF}')

        proto="${proto,,}"
        proto="${proto%6}"

        # Split address
        local addr port
        if [[ "$local_addr" == *"]:"* ]]; then
            addr="${local_addr%:*}"
            addr="${addr#\[}"
            addr="${addr%\]}"
            port="${local_addr##*:}"
        elif [[ "$local_addr" == *":"* ]]; then
            addr="${local_addr%:*}"
            port="${local_addr##*:}"
        else
            addr="*"
            port="$local_addr"
        fi

        # pid/program format: "1234/sshd" or "-"
        local pname pid
        pname=""
        pid=""
        if [[ "$pid_prog" == *"/"* ]]; then
            pid="${pid_prog%%/*}"
            pname="${pid_prog#*/}"
        fi

        echo "${port}|${proto}|${addr}|${pname}|${pid}"
    done
}

# Collect ports using the available command
collect_listening_ports() {
    if [[ "$PORT_CMD" == "ss" ]]; then
        collect_ports_ss
    else
        collect_ports_netstat
    fi
}

# Parse expected port list into pipe-delimited records: port|proto|expected|description
parse_expected_list() {
    local file="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip inline comments and trim
        line="${line%%#*}"
        line="$(trim "$line")"
        [[ -z "$line" ]] && continue

        IFS=',' read -ra parts <<< "$line"
        local port proto expected desc
        port="$(trim "${parts[0]:-}")"
        proto="$(trim "${parts[1]:-}")"
        expected="$(trim "${parts[2]:-}")"
        desc="$(trim "${parts[3]:-}")"

        [[ -z "$port" ]] && continue
        [[ -z "$proto" ]] && proto="tcp"
        [[ -z "$expected" || "$expected" == "-" ]] && expected="-"
        [[ -z "$desc" ]] && desc="port ${port}/${proto}"

        # Normalize
        proto="${proto,,}"
        expected="${expected,,}"

        echo "${port}|${proto}|${expected}|${desc}"
    done < "$file"
}

# Escape special characters for JSON string values
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    echo "$s"
}

# HTML-escape a string
html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    echo "$s"
}

# ── Collect ports ─────────────────────────────────────────────────────────

declare -a COLLECTED=()
while IFS= read -r record; do
    [[ -z "$record" ]] && continue
    COLLECTED+=("$record")
done < <(collect_listening_ports)

# ── Build result set with judgment ────────────────────────────────────────

# Result format: port|proto|address|process|pid|status|description
declare -a RESULTS=()
has_ng=false

if [[ -n "$EXPECTED_LIST" ]]; then
    # Load expected entries
    declare -a EXPECTED_ENTRIES=()
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        EXPECTED_ENTRIES+=("$entry")
    done < <(parse_expected_list "$EXPECTED_LIST")

    # Track which collected ports matched an expected entry
    declare -A MATCHED_COLLECTED=()

    # For each expected entry, check against collected ports
    for exp_entry in "${EXPECTED_ENTRIES[@]}"; do
        IFS='|' read -r exp_port exp_proto exp_expected exp_desc <<< "$exp_entry"

        local_found=false
        local_addr=""
        local_process=""
        local_pid=""

        for i in "${!COLLECTED[@]}"; do
            IFS='|' read -r c_port c_proto c_addr c_process c_pid <<< "${COLLECTED[$i]}"
            if [[ "$c_port" == "$exp_port" && "$c_proto" == "$exp_proto" ]]; then
                local_found=true
                local_addr="$c_addr"
                local_process="$c_process"
                local_pid="$c_pid"
                MATCHED_COLLECTED["$i"]=1
                break
            fi
        done

        local status="INFO"
        case "$exp_expected" in
            ok)
                if "$local_found"; then
                    status="OK"
                else
                    status="NG"
                    has_ng=true
                fi
                ;;
            ng)
                if "$local_found"; then
                    status="NG"
                    has_ng=true
                else
                    status="OK"
                fi
                ;;
            -)
                if "$local_found"; then
                    status="INFO"
                else
                    status="INFO"
                fi
                ;;
        esac

        if "$local_found"; then
            RESULTS+=("${exp_port}|${exp_proto}|${local_addr}|${local_process}|${local_pid}|${status}|${exp_desc}")
        else
            RESULTS+=("${exp_port}|${exp_proto}|-|-|-|${status}|${exp_desc}")
        fi
    done

    # Collected ports not in expected list -> WARN (unexpected)
    for i in "${!COLLECTED[@]}"; do
        if [[ -z "${MATCHED_COLLECTED[$i]:-}" ]]; then
            IFS='|' read -r c_port c_proto c_addr c_process c_pid <<< "${COLLECTED[$i]}"
            RESULTS+=("${c_port}|${c_proto}|${c_addr}|${c_process}|${c_pid}|WARN|(unexpected)")
        fi
    done
else
    # No expected list: inventory mode, all entries are INFO, exit 0
    for record in "${COLLECTED[@]}"; do
        IFS='|' read -r c_port c_proto c_addr c_process c_pid <<< "$record"
        RESULTS+=("${c_port}|${c_proto}|${c_addr}|${c_process}|${c_pid}|INFO|")
    done
fi

# Apply --fail-only filter
declare -a DISPLAY_RESULTS=()
for record in "${RESULTS[@]}"; do
    if "$FAIL_ONLY"; then
        IFS='|' read -r _ _ _ _ _ rec_status _ <<< "$record"
        if [[ "$rec_status" == "OK" || "$rec_status" == "INFO" ]]; then
            continue
        fi
    fi
    DISPLAY_RESULTS+=("$record")
done

# ── Phase 5: Output ───────────────────────────────────────────────────────

# Console table output
print_table() {
    local hdr_fmt="%-7s %-6s %-18s %-16s %-7s %-6s  %s\n"
    local row_fmt="%-7s %-6s %-18s %-16s %-7s %-6s  %s\n"
    local sep
    sep=$(printf '%.0s─' {1..80})

    printf "$hdr_fmt" "PORT" "PROTO" "ADDRESS" "PROCESS" "PID" "STATUS" "DESCRIPTION"
    echo "$sep"

    if [[ ${#DISPLAY_RESULTS[@]} -eq 0 ]]; then
        echo "(no entries)"
        return
    fi

    for record in "${DISPLAY_RESULTS[@]}"; do
        IFS='|' read -r port proto addr process pid status desc <<< "$record"
        printf "$row_fmt" "$port" "$proto" "${addr:0:18}" "${process:0:16}" "${pid:--}" "$status" "$desc"
    done
}

# JSON output
print_json() {
    local first=true
    echo "["

    for record in "${DISPLAY_RESULTS[@]}"; do
        IFS='|' read -r port proto addr process pid status desc <<< "$record"

        if "$first"; then
            first=false
        else
            echo ","
        fi

        # Ensure port is numeric for JSON; fallback to string
        local port_val="$port"
        if [[ "$port_val" =~ ^[0-9]+$ ]]; then
            port_val="$port"
        else
            port_val="\"$(json_escape "$port")\""
        fi

        local pid_val="null"
        if [[ -n "$pid" && "$pid" != "-" && "$pid" =~ ^[0-9]+$ ]]; then
            pid_val="$pid"
        fi

        cat <<JSONITEM
  {
    "port": ${port_val},
    "protocol": "$(json_escape "$proto")",
    "address": "$(json_escape "$addr")",
    "process": "$(json_escape "$process")",
    "pid": ${pid_val},
    "status": "$(json_escape "$status")",
    "description": "$(json_escape "$desc")"
  }
JSONITEM
    done
    echo ""
    echo "]"
}

# HTML report
generate_html() {
    local path="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    cat > "$path" <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Port Inventory Report</title>
<style>
  body { font-family: Arial, Helvetica, sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #333; }
  .timestamp { color: #666; font-size: 0.9em; margin-bottom: 16px; }
  .tool-info { color: #888; font-size: 0.8em; margin-bottom: 8px; }
  table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  th { background: #2c3e50; color: #fff; padding: 10px 12px; text-align: left; font-size: 0.9em; }
  td { padding: 8px 12px; border-bottom: 1px solid #e0e0e0; font-size: 0.85em; }
  tr:hover { background: #f0f4f8; }
  .ok   { background: #e8f5e9; }
  .warn { background: #fff8e1; }
  .ng   { background: #ffebee; }
  .info { background: #fff; }
  .status-ok   { color: #2e7d32; font-weight: bold; }
  .status-warn { color: #f57f17; font-weight: bold; }
  .status-ng   { color: #c62828; font-weight: bold; }
  .status-info { color: #555; }
  .summary { margin-top: 16px; font-size: 0.9em; color: #555; }
</style>
</head>
<body>
<h1>Port Inventory Report</h1>
HTMLHEAD

    echo "<p class=\"timestamp\">Generated: ${timestamp}</p>" >> "$path"
    echo "<p class=\"tool-info\">Collection tool: ${PORT_CMD}</p>" >> "$path"

    cat >> "$path" <<'TABLEHEAD'
<table>
<thead>
<tr>
  <th>Port</th><th>Proto</th><th>Address</th><th>Process</th>
  <th>PID</th><th>Status</th><th>Description</th>
</tr>
</thead>
<tbody>
TABLEHEAD

    local count_ok=0 count_warn=0 count_ng=0 count_info=0
    for record in "${DISPLAY_RESULTS[@]}"; do
        IFS='|' read -r port proto addr process pid status desc <<< "$record"

        local row_class="info" status_class="status-info"
        case "$status" in
            OK)   row_class="ok";   status_class="status-ok";   ((count_ok++))   || true ;;
            WARN) row_class="warn"; status_class="status-warn"; ((count_warn++)) || true ;;
            NG)   row_class="ng";   status_class="status-ng";   ((count_ng++))   || true ;;
            *)    ((count_info++)) || true ;;
        esac

        cat >> "$path" <<TABLEROW
<tr class="${row_class}">
  <td>${port}</td><td>${proto}</td><td>$(html_escape "$addr")</td>
  <td>$(html_escape "$process")</td><td>${pid:--}</td>
  <td class="${status_class}">${status}</td><td>$(html_escape "$desc")</td>
</tr>
TABLEROW
    done

    local total=$((count_ok + count_warn + count_ng + count_info))
    cat >> "$path" <<HTMLFOOT
</tbody>
</table>
<p class="summary">Total: ${total} &mdash;
OK: ${count_ok}, WARN: ${count_warn}, NG: ${count_ng}, INFO: ${count_info}</p>
</body>
</html>
HTMLFOOT

    echo "[INFO] HTML report written to: $path"
}

# Produce output
if "$OUTPUT_JSON"; then
    print_json
else
    print_table
fi

if [[ -n "$HTML_PATH" ]]; then
    generate_html "$HTML_PATH"
fi

# Exit code: 1 if any NG, 0 otherwise
if "$has_ng"; then
    exit 1
fi
exit 0
