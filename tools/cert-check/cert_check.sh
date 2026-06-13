#!/usr/bin/env bash
# ============================================================================
# cert_check.sh — TLS certificate expiry checker
#
# Usage:
#   cert_check.sh -t <target_list> [--timeout <sec>] [--json] [--html <path>]
#                 [--fail-only]
#
# Target list format (CSV):
#   <host>, <port>, <warn_days>, <description>
#   - port defaults to 443 if omitted or "-"
#   - warn_days defaults to 30 if omitted or "-"
#   - Lines starting with # are comments; blank lines are skipped
#
# Exit codes:
#   0  — All certificates OK
#   1  — One or more certificates are WARN or NG
#   2  — Target list file not found
#   10 — Prerequisite missing (openssl)
# ============================================================================
set -euo pipefail

# ── Phase 2: Arguments & defaults ──────────────────────────────────────────

TARGET_LIST=""
TIMEOUT=5
OUTPUT_JSON=false
HTML_PATH=""
FAIL_ONLY=false

usage() {
    cat <<'EOF'
Usage: cert_check.sh -t <target_list> [OPTIONS]

Options:
  -t, --target-list <file>   Path to target list (required)
  --timeout <seconds>        Connection timeout (default: 5)
  --json                     Output as JSON array
  --html <path>              Generate HTML report file
  --fail-only                Show only WARN and NG entries
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--target-list) TARGET_LIST="$2"; shift 2 ;;
        --timeout)        TIMEOUT="$2"; shift 2 ;;
        --json)           OUTPUT_JSON=true; shift ;;
        --html)           HTML_PATH="$2"; shift 2 ;;
        --fail-only)      FAIL_ONLY=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)
            echo "[ERROR] Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ── Phase 3: Validation ───────────────────────────────────────────────────

if [[ -z "$TARGET_LIST" ]]; then
    echo "[ERROR] -t <target_list> is required" >&2
    usage >&2
    exit 1
fi

if [[ ! -f "$TARGET_LIST" ]]; then
    echo "[ERROR] Target list not found: $TARGET_LIST" >&2
    exit 2
fi

if ! command -v openssl &>/dev/null; then
    echo "[ERROR] openssl is required but not found" >&2
    exit 10
fi

# ── Phase 4: Main logic ───────────────────────────────────────────────────

# Parse target list into pipe-delimited records: host|port|warn_days|description
parse_target_list() {
    local file="$1"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip inline comments and trim
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        IFS=',' read -ra parts <<< "$line"
        local host="${parts[0]:-}"
        local port="${parts[1]:-}"
        local warn="${parts[2]:-}"
        local desc="${parts[3]:-}"

        # Trim whitespace from each field
        host="$(echo "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        port="$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        warn="$(echo "$warn" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        desc="$(echo "$desc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        [[ -z "$host" ]] && continue
        [[ -z "$port" || "$port" == "-" ]] && port=443
        [[ -z "$warn" || "$warn" == "-" ]] && warn=30
        [[ -z "$desc" ]] && desc="${host}:${port}"

        echo "${host}|${port}|${warn}|${desc}"
    done < "$file"
}

# Check a single certificate. Returns pipe-delimited result:
#   status|subject|issuer|end_date|days_remaining|san
check_certificate() {
    local host="$1" port="$2" timeout="$3"

    # Connect with SNI and retrieve certificate (use timeout command if available)
    local cert_pem
    if command -v timeout &>/dev/null; then
        cert_pem=$(echo "" | timeout "$timeout" openssl s_client -servername "$host" \
            -connect "${host}:${port}" -verify_quiet \
            2>/dev/null </dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p') || true
    else
        cert_pem=$(echo "" | openssl s_client -servername "$host" \
            -connect "${host}:${port}" -verify_quiet \
            2>/dev/null </dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p') || true
    fi

    if [[ -z "$cert_pem" ]]; then
        echo "NG||||-1|Connection failed"
        return
    fi

    # Extract individual fields from the PEM
    local subject issuer end_date san

    subject=$(echo "$cert_pem" | openssl x509 -noout -subject 2>/dev/null \
        | sed 's/^subject= *//; s/^subject=//') || subject=""
    issuer=$(echo "$cert_pem" | openssl x509 -noout -issuer 2>/dev/null \
        | sed 's/^issuer= *//; s/^issuer=//') || issuer=""
    end_date=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null \
        | sed 's/^notAfter=//') || end_date=""

    if [[ -z "$end_date" ]]; then
        echo "NG|${subject}|${issuer}||-1|Certificate parse error"
        return
    fi

    # SAN extraction (-ext may not be available on older openssl; fall back to -text)
    san=$(echo "$cert_pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -oP 'DNS:[^\s,]+' | sed 's/DNS://g' | paste -sd ', ' -) || true
    if [[ -z "$san" ]]; then
        san=$(echo "$cert_pem" | openssl x509 -noout -text 2>/dev/null \
            | grep -A1 'Subject Alternative Name' \
            | tail -1 | grep -oP 'DNS:[^\s,]+' | sed 's/DNS://g' | paste -sd ', ' -) || true
    fi

    # Calculate days remaining (GNU date first, then BSD date fallback)
    local end_epoch now_epoch days_remaining
    end_epoch=$(date -d "$end_date" +%s 2>/dev/null) || \
        end_epoch=$(date -j -f "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null) || {
        echo "NG|${subject}|${issuer}|${end_date}|-1|Date parse error"
        return
    }
    now_epoch=$(date +%s)
    days_remaining=$(( (end_epoch - now_epoch) / 86400 ))

    echo "OK|${subject}|${issuer}|${end_date}|${days_remaining}|${san}"
}

# Determine status based on days remaining and threshold
judge_status() {
    local raw_status="$1" days_remaining="$2" warn_days="$3"

    if [[ "$raw_status" == "NG" ]]; then
        echo "NG"
    elif [[ "$days_remaining" -lt 0 ]]; then
        echo "NG"
    elif [[ "$days_remaining" -lt "$warn_days" ]]; then
        echo "WARN"
    else
        echo "OK"
    fi
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

# Collect results into arrays
declare -a RESULTS=()
has_failure=false

while IFS='|' read -r host port warn_days desc; do
    cert_result=$(check_certificate "$host" "$port" "$TIMEOUT")

    IFS='|' read -r raw_status subject issuer end_date days_remaining san <<< "$cert_result"
    status=$(judge_status "$raw_status" "$days_remaining" "$warn_days")

    if [[ "$status" != "OK" ]]; then
        has_failure=true
    fi

    # Store as pipe-delimited record
    RESULTS+=("${host}|${port}|${desc}|${subject}|${issuer}|${end_date}|${days_remaining}|${san}|${status}|${warn_days}")
done < <(parse_target_list "$TARGET_LIST")

# Apply --fail-only filter
declare -a DISPLAY_RESULTS=()
for record in "${RESULTS[@]}"; do
    if "$FAIL_ONLY"; then
        local_status="${record##*|}"
        # status is second-to-last; extract it properly
        IFS='|' read -r _ _ _ _ _ _ _ _ rec_status _ <<< "$record"
        if [[ "$rec_status" == "OK" ]]; then
            continue
        fi
    fi
    DISPLAY_RESULTS+=("$record")
done

# ── Phase 5: Output ───────────────────────────────────────────────────────

# Console table output
print_table() {
    local hdr_fmt="%-30s %5s  %-30s  %-12s  %5s  %s\n"
    local row_fmt="%-30s %5s  %-30s  %-12s  %5s  %s\n"
    local sep
    sep=$(printf '%.0s─' {1..100})

    printf "$hdr_fmt" "HOST" "PORT" "SUBJECT" "EXPIRY" "DAYS" "STATUS"
    echo "$sep"

    for record in "${DISPLAY_RESULTS[@]}"; do
        IFS='|' read -r host port desc subject issuer end_date days_remaining san status warn_days <<< "$record"

        # Shorten end_date to YYYY-MM-DD if possible
        local short_date
        short_date=$(date -d "$end_date" +%Y-%m-%d 2>/dev/null) || short_date="$end_date"

        # Truncate long fields for display
        local disp_host="${host:0:30}"
        local disp_subject="${subject:0:30}"

        printf "$row_fmt" "$disp_host" "$port" "$disp_subject" "$short_date" "$days_remaining" "$status"
    done
}

# JSON output
print_json() {
    local first=true
    echo "["
    for record in "${DISPLAY_RESULTS[@]}"; do
        IFS='|' read -r host port desc subject issuer end_date days_remaining san status warn_days <<< "$record"

        if "$first"; then
            first=false
        else
            echo ","
        fi

        cat <<JSONITEM
  {
    "host": "$(json_escape "$host")",
    "port": $port,
    "description": "$(json_escape "$desc")",
    "subject": "$(json_escape "$subject")",
    "issuer": "$(json_escape "$issuer")",
    "not_after": "$(json_escape "$end_date")",
    "days_remaining": $days_remaining,
    "san": "$(json_escape "$san")",
    "status": "$status",
    "warn_days": $warn_days
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
<title>TLS Certificate Check Report</title>
<style>
  body { font-family: Arial, Helvetica, sans-serif; margin: 20px; background: #f5f5f5; }
  h1 { color: #333; }
  .timestamp { color: #666; font-size: 0.9em; margin-bottom: 16px; }
  table { border-collapse: collapse; width: 100%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
  th { background: #2c3e50; color: #fff; padding: 10px 12px; text-align: left; font-size: 0.9em; }
  td { padding: 8px 12px; border-bottom: 1px solid #e0e0e0; font-size: 0.85em; }
  tr:hover { background: #f0f4f8; }
  .ok   { background: #e8f5e9; }
  .warn { background: #fff8e1; }
  .ng   { background: #ffebee; }
  .status-ok   { color: #2e7d32; font-weight: bold; }
  .status-warn { color: #f57f17; font-weight: bold; }
  .status-ng   { color: #c62828; font-weight: bold; }
  .summary { margin-top: 16px; font-size: 0.9em; color: #555; }
</style>
</head>
<body>
<h1>TLS Certificate Check Report</h1>
HTMLHEAD

    echo "<p class=\"timestamp\">Generated: ${timestamp}</p>" >> "$path"

    cat >> "$path" <<'TABLEHEAD'
<table>
<thead>
<tr>
  <th>Host</th><th>Port</th><th>Description</th><th>Subject</th>
  <th>Issuer</th><th>Not After</th><th>Days</th><th>SAN</th><th>Status</th>
</tr>
</thead>
<tbody>
TABLEHEAD

    local count_ok=0 count_warn=0 count_ng=0
    for record in "${DISPLAY_RESULTS[@]}"; do
        IFS='|' read -r host port desc subject issuer end_date days_remaining san status warn_days <<< "$record"

        local row_class="ok" status_class="status-ok"
        case "$status" in
            WARN) row_class="warn"; status_class="status-warn"; ((count_warn++)) || true ;;
            NG)   row_class="ng";   status_class="status-ng";   ((count_ng++))   || true ;;
            *)    ((count_ok++)) || true ;;
        esac

        # HTML-escape fields
        local esc_subject esc_issuer esc_san esc_desc
        esc_subject="${subject//&/&amp;}"
        esc_subject="${esc_subject//</&lt;}"
        esc_issuer="${issuer//&/&amp;}"
        esc_issuer="${esc_issuer//</&lt;}"
        esc_san="${san//&/&amp;}"
        esc_san="${esc_san//</&lt;}"
        esc_desc="${desc//&/&amp;}"
        esc_desc="${esc_desc//</&lt;}"

        cat >> "$path" <<TABLEROW
<tr class="${row_class}">
  <td>${host}</td><td>${port}</td><td>${esc_desc}</td><td>${esc_subject}</td>
  <td>${esc_issuer}</td><td>${end_date}</td><td>${days_remaining}</td>
  <td>${esc_san}</td><td class="${status_class}">${status}</td>
</tr>
TABLEROW
    done

    cat >> "$path" <<HTMLFOOT
</tbody>
</table>
<p class="summary">Total: $((count_ok + count_warn + count_ng)) &mdash;
OK: ${count_ok}, WARN: ${count_warn}, NG: ${count_ng}</p>
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

# Exit code: 1 if any failure, 0 otherwise
if "$has_failure"; then
    exit 1
fi
exit 0
