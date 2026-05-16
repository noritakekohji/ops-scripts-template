#!/usr/bin/env bash
# ============================================================================
# check_network_connectivity.sh  -  Network connectivity check (standalone)
# Requires: bash 4+, python3, ping
#
# Usage:
#   ./check_network_connectivity.sh -l <target_list> [options]
#
# Options:
#   -l <file>   Target list file (required)
#   -c <n>      Ping count per target (default: 3)
#   -t <n>      Timeout in seconds   (default: 3)
#   -o <file>   HTML report output path
#   -f          Show failed/warning targets only
#   -h          Show this help
#
# List file format (4-field, preferred):
#   <host>, <port>, <expected>, <description>
#
#   <port>     : TCP port number, or '-' for ping-only check
#   <expected> : 'ok' (expect reachable), 'ng' (expect unreachable), '-' (no eval)
#
# List file format (3-field, backward compatible — no evaluation):
#   <host>, <port>, <description>
#
# Examples:
#   google.com,   443, ok, HTTPS web
#   google.com,    22, ng, SSH (should be blocked)
#   8.8.8.8,        -, ok, Google DNS ping only
#   192.168.1.1,    -,   , Default Gateway (no eval, 3-field style)
#
# Architecture:
#   Lines are grouped by host. Per unique host: DNS + Ping run ONCE.
#   Per service under each host: TCP check runs (skipped if DNS failed).
#   Ping is skipped entirely when DNS fails.
#
# Investigation output:
#   When any target is NG/WARN, an investigation file is automatically
#   generated: network_investigation_<timestamp>.txt
#   Contents: system network info, traceroute (ping NG), /etc/hosts + dig
#   (DNS NG), nc port check (port NG).
# ============================================================================
set -euo pipefail

usage() { sed -n '2,32p' "$0" >&2; exit 1; }

list_file=""
ping_count=3
timeout_sec=3
html_report=""
fail_only=0

while getopts "l:c:t:o:fh" opt; do
    case "$opt" in
        l) list_file="$OPTARG" ;;
        c) ping_count="$OPTARG" ;;
        t) timeout_sec="$OPTARG" ;;
        o) html_report="$OPTARG" ;;
        f) fail_only=1 ;;
        h) usage ;;
        *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done

if [[ -z "$list_file" ]]; then echo "Error: -l <target_list> is required" >&2; usage; fi
if [[ ! -f "$list_file" ]]; then echo "Error: target list not found: $list_file" >&2; exit 2; fi
if ! command -v python3 &>/dev/null; then echo "Error: python3 is required" >&2; exit 10; fi

# ============================================================
# Check functions (output: status|detail fields)
# ============================================================

is_ip() {
    python3 -c "
import sys, socket
try:
    socket.inet_pton(socket.AF_INET, sys.argv[1])
    print('yes')
except:
    print('no')
" "$1"
}

check_dns() {
    local host="$1"
    if [[ "$(is_ip "$host")" == "yes" ]]; then
        echo "na|$host|"
        return
    fi
    local result
    result=$(python3 -c "
import sys, socket
try:
    infos = socket.getaddrinfo(sys.argv[1], None)
    ips   = sorted(set(i[4][0] for i in infos if ':' not in i[4][0]))
    print('ok|' + ','.join(ips) + '|')
except Exception as e:
    print('fail||' + str(e).replace('\n',' '))
" "$host" 2>/dev/null || echo "fail||Unknown error")
    echo "$result"
}

check_ping() {
    local target="$1"
    local count="$2"
    local timeout="$3"
    local output recv rtt_avg status

    # Run ping, capture output even on failure
    if output=$(ping -c "$count" -W "$timeout" "$target" 2>&1); then
        recv=$(echo "$output" | grep -oP '\d+(?= received)' 2>/dev/null || echo 0)
        rtt_avg=$(echo "$output" | grep -oP 'rtt[^=]+=\s*[\d.]+/\K[\d.]+' 2>/dev/null || \
                  echo "$output" | awk -F'[=/]' '/rtt/{print $5}' || echo "")
        [[ -z "$rtt_avg" ]] && rtt_avg="0"
        rtt_avg=$(printf "%.0f" "$rtt_avg" 2>/dev/null || echo "0")
        status="ok"
    else
        recv=$(echo "$output" | grep -oP '\d+(?= received)' 2>/dev/null || echo 0)
        rtt_avg="0"
        if [[ "$recv" -gt 0 ]]; then
            status="partial"
            rtt_avg=$(echo "$output" | awk -F'[=/]' '/rtt/{print $5}' || echo "0")
            rtt_avg=$(printf "%.0f" "$rtt_avg" 2>/dev/null || echo "0")
        else
            status="fail"
        fi
    fi
    echo "${status}|${count}|${recv}|${rtt_avg}"
}

check_tcp() {
    local host="$1"
    local port="$2"
    local timeout="$3"
    local result
    result=$(python3 -c "
import sys, socket
host, port, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(timeout)
try:
    s.connect((host, port))
    s.close()
    print('ok|')
except socket.timeout:
    print('fail|Timeout')
except ConnectionRefusedError:
    print('fail|Connection refused')
except Exception as e:
    print('fail|' + str(e).replace('\n',' '))
" "$host" "$port" "$timeout" 2>/dev/null || echo "fail|Error")
    echo "$result"
}

# ============================================================
# Evaluation logic
# ============================================================

# compute_eval <dns_status> <expected> <check_status>
# check_status: tcp status, or ping status for ping-only lines
# Prints: PASS | FAIL | SKIP | -
compute_eval() {
    local dns_st="$1"
    local expected="$2"
    local check_st="$3"

    # No evaluation requested
    if [[ "$expected" == "-" ]] || [[ -z "$expected" ]]; then
        echo "-"
        return
    fi

    # DNS failed
    if [[ "$dns_st" == "fail" ]]; then
        case "$expected" in
            ok) echo "FAIL" ;;
            ng) echo "SKIP" ;;
            *)  echo "-" ;;
        esac
        return
    fi

    # DNS ok or na
    case "$expected" in
        ok)
            if [[ "$check_st" == "ok" ]]; then
                echo "PASS"
            else
                echo "FAIL"
            fi
            ;;
        ng)
            if [[ "$check_st" == "ok" ]]; then
                echo "FAIL"
            else
                echo "PASS"
            fi
            ;;
        *)
            echo "-"
            ;;
    esac
}

# ============================================================
# Investigation (called automatically for NG/WARN targets)
# ============================================================

run_investigation() {
    local results_file="$1" out_file="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # Extract NG/WARN services as tab-separated lines
    local ng_info
    ng_info=$(python3 - "$results_file" << 'PYEOF'
import json, sys

for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    host    = r['host']
    dns     = r['dns']
    ping    = r['ping']
    dns_st  = dns['status']
    ping_st = ping['status']
    addrs   = dns.get('addresses', [])
    dns_err = dns.get('error', '')
    ping_target = addrs[0] if addrs else host

    for svc in r['services']:
        port    = str(svc['port']) if svc['port'] is not None else '-'
        tcp_st  = svc['tcp']['status']
        tcp_err = svc['tcp'].get('error', '')
        overall = svc['overall']
        if overall not in ('fail', 'warn'):
            continue
        print('\t'.join([
            host, overall,
            dns_st, ping_st, tcp_st,
            port, ping_target, svc['description'], dns_err, tcp_err
        ]))
PYEOF
) || true

    [[ -z "$ng_info" ]] && return

    local ng_count
    ng_count=$(echo "$ng_info" | grep -c .)

    echo ""
    echo "=== Collecting Investigation Info (${ng_count} NG target(s)) ==="
    echo "  Output: $out_file"
    echo "  (traceroute may take a while per host...)"

    {
        echo "================================================================"
        echo "  Network Investigation Report"
        echo "  Generated : $ts"
        echo "  Hostname  : $(hostname -f 2>/dev/null || hostname -s 2>/dev/null || echo 'localhost')"
        echo "================================================================"
        echo ""
        echo "## System Network Information"
        echo ""
        echo "### Network Interfaces"
        ip addr show 2>/dev/null || ifconfig 2>/dev/null || echo "(ip/ifconfig not available)"
        echo ""
        echo "### Routing Table"
        ip route show 2>/dev/null || netstat -rn 2>/dev/null || echo "(ip route/netstat not available)"
        echo ""
        echo "### DNS Configuration (/etc/resolv.conf)"
        cat /etc/resolv.conf 2>/dev/null || echo "(not found)"
        echo ""
    } > "$out_file"

    local idx=0
    while IFS=$'\t' read -r host overall dns_st ping_st tcp_st port ping_target desc dns_err tcp_err; do
        idx=$((idx + 1))
        local fail_labels=""
        [[ "$dns_st"  == "fail"    ]] && fail_labels="${fail_labels} DNS"
        [[ "$ping_st" == "fail"    ]] && fail_labels="${fail_labels} Ping"
        [[ "$ping_st" == "partial" ]] && fail_labels="${fail_labels} Ping(partial)"
        [[ "$tcp_st"  == "fail"    ]] && fail_labels="${fail_labels} Port"

        {
            echo "================================================================"
            printf "[$idx] HOST: %s  (%s)\n" "$host" "$desc"
            printf "     Status: %s  NG items:%s\n" "${overall^^}" "$fail_labels"
            echo "----------------------------------------------------------------"
            echo ""
        } >> "$out_file"

        # DNS NG → /etc/hosts + dig/nslookup
        if [[ "$dns_st" == "fail" ]]; then
            {
                echo "### DNS Failure Investigation"
                echo "  Error: $dns_err"
                echo ""
                echo "#### /etc/hosts"
                cat /etc/hosts 2>/dev/null || echo "(not found)"
                echo ""
                echo "#### DNS query: $host"
                if command -v dig &>/dev/null; then
                    dig +noall +answer +comments "$host" 2>&1 || true
                elif command -v nslookup &>/dev/null; then
                    nslookup "$host" 2>&1 || true
                elif command -v host &>/dev/null; then
                    host "$host" 2>&1 || true
                else
                    echo "(dig / nslookup / host not available)"
                fi
                echo ""
            } >> "$out_file"
        fi

        # Ping NG/partial → traceroute/tracepath/mtr
        if [[ "$ping_st" == "fail" ]] || [[ "$ping_st" == "partial" ]]; then
            {
                echo "### Ping NG Investigation"
                echo ""
                echo "#### Traceroute: $ping_target"
                if command -v traceroute &>/dev/null; then
                    traceroute -m 20 -w "$timeout_sec" "$ping_target" 2>&1 || true
                elif command -v tracepath &>/dev/null; then
                    tracepath -m 20 "$ping_target" 2>&1 || true
                elif command -v mtr &>/dev/null; then
                    mtr --report --report-cycles 3 --no-dns "$ping_target" 2>&1 || true
                else
                    echo "(traceroute / tracepath / mtr not available)"
                fi
                echo ""
            } >> "$out_file"
        fi

        # Port NG → nc or bash /dev/tcp
        if [[ "$tcp_st" == "fail" ]] && [[ "$port" != "-" ]] && [[ -n "$port" ]]; then
            {
                echo "### Port NG Investigation"
                echo ""
                echo "#### Detailed port check: $ping_target:$port"
                if command -v nc &>/dev/null; then
                    nc -zv -w "$timeout_sec" "$ping_target" "$port" 2>&1 || true
                else
                    (exec 3<>"/dev/tcp/${ping_target}/${port}" \
                        && echo "  Connected (bash /dev/tcp)" \
                        && exec 3>&-) 2>/dev/null \
                        || echo "  Connection failed (bash /dev/tcp)"
                fi
                echo ""
            } >> "$out_file"
        fi

    done <<< "$ng_info"

    {
        echo "================================================================"
        echo "  End of Investigation Report"
        echo "================================================================"
    } >> "$out_file"

    echo "  Investigation saved: $out_file"
}

# ============================================================
# Phase 1: Parse list file — group services by host
# ============================================================

hostname_str=$(hostname -s 2>/dev/null || echo "localhost")
generated=$(date '+%Y-%m-%d %H:%M:%S')

# Associative array: host -> index in unique_hosts (bash 4+)
declare -A host_index=()
declare -a unique_hosts=()

# Temp dir for per-host service files
svc_tmpdir=$(mktemp -d)
trap 'rm -rf "$svc_tmpdir"' EXIT

# Also collect results into this JSON-lines file
tmpfile=$(mktemp "$svc_tmpdir/results.XXXXXX")

while IFS= read -r raw_line; do
    # Strip inline comments and whitespace
    line="${raw_line%%#*}"
    line="${line//[$'\r']}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    # Split by comma — up to 4 fields
    IFS=',' read -r f1 f2 f3 f4 <<< "$line"

    host="${f1//[[:space:]]}"
    [[ -z "$host" ]] && continue

    port="${f2//[[:space:]]}"
    [[ -z "$port" ]] && port="-"

    # Detect 3-field vs 4-field by checking if f4 is set
    local_expected="-"
    local_desc=""
    if [[ -n "${f4+x}" ]] && [[ -n "${f4}" || -n "${f3//[[:space:]]}" ]]; then
        # Could be 4-field: host, port, expected, description
        # Or 3-field: host, port, description  (f4 empty/absent)
        trimmed_f3="${f3#"${f3%%[![:space:]]*}"}"
        trimmed_f3="${trimmed_f3%"${trimmed_f3##*[![:space:]]}"}"
        trimmed_f4="${f4#"${f4%%[![:space:]]*}"}"
        trimmed_f4="${trimmed_f4%"${trimmed_f4##*[![:space:]]}"}"

        # If f4 is non-empty, treat as 4-field format
        if [[ -n "$trimmed_f4" ]]; then
            local_expected="${trimmed_f3,,}"
            [[ -z "$local_expected" ]] && local_expected="-"
            local_desc="$trimmed_f4"
        else
            # f4 empty: could still be 4-field with empty description, or 3-field
            # Check if f3 looks like an expected value keyword
            case "${trimmed_f3,,}" in
                ok|ng|-)
                    local_expected="${trimmed_f3,,}"
                    local_desc=""
                    ;;
                *)
                    # 3-field: f3 is the description
                    local_desc="$trimmed_f3"
                    ;;
            esac
        fi
    else
        # 3-field: f3 is the description
        trimmed_f3="${f3#"${f3%%[![:space:]]*}"}"
        trimmed_f3="${trimmed_f3%"${trimmed_f3##*[![:space:]]}"}"
        local_desc="$trimmed_f3"
    fi

    [[ -z "$local_desc" ]] && local_desc="$host"

    # Register host if new
    if [[ -z "${host_index[$host]+x}" ]]; then
        host_index[$host]="${#unique_hosts[@]}"
        unique_hosts+=("$host")
    fi

    # Append service record to host's service file
    # Format: port <TAB> expected <TAB> desc
    svc_file="${svc_tmpdir}/svc_${host_index[$host]}"
    printf '%s\t%s\t%s\n' "$port" "$local_expected" "$local_desc" >> "$svc_file"

done < "$list_file"

# ============================================================
# Phase 2: Check phase — per unique host
# ============================================================

echo ""
echo "=== Network Connectivity Check ==="
echo "  List    : $list_file"
echo "  Timeout : ${timeout_sec}s / Ping: ${ping_count} packets"
echo ""

cnt_ok=0; cnt_warn=0; cnt_fail=0; cnt_total=0
cnt_pass=0; cnt_eval_fail=0; cnt_eval_skip=0
has_eval=0

for host in "${unique_hosts[@]}"; do
    idx="${host_index[$host]}"
    svc_file="${svc_tmpdir}/svc_${idx}"
    [[ ! -f "$svc_file" ]] && continue

    # ---- DNS (once per host) ----
    IFS='|' read -r dns_st dns_addrs dns_err <<< "$(check_dns "$host")"

    # Use resolved IP for ping/TCP if possible
    ping_target="$host"
    if [[ "$dns_st" == "ok" ]] && [[ -n "$dns_addrs" ]]; then
        ping_target="${dns_addrs%%,*}"
    fi

    # ---- Ping (once per host, skip if DNS failed) ----
    ping_st="skip"; ping_sent=0; ping_recv=0; ping_rtt="0"
    if [[ "$dns_st" != "fail" ]]; then
        IFS='|' read -r ping_st ping_sent ping_recv ping_rtt <<< "$(check_ping "$ping_target" "$ping_count" "$timeout_sec")"
    fi

    # ---- Console: HOST header ----
    printf "\n\e[1m[HOST] %s\e[0m\n" "$host"

    # DNS line
    case "$dns_st" in
        ok)   printf "       DNS  : \e[32m✓\e[0m  %s\n" "$dns_addrs" ;;
        fail) printf "       DNS  : \e[31m✗\e[0m  %s\n" "$dns_err" ;;
        na)   printf "       DNS  : \e[90m─\e[0m  N/A (IP address)\n" ;;
    esac

    # Ping line
    rtt_label=""
    [[ -n "${ping_rtt:-}" ]] && [[ "${ping_rtt:-0}" != "0" ]] && rtt_label="${ping_rtt}ms avg "
    case "$ping_st" in
        ok)      printf "       Ping : \e[32m✓\e[0m  %s(%s/%s)\n" "$rtt_label" "$ping_recv" "$ping_sent" ;;
        partial) printf "       Ping : \e[33m⚠\e[0m  %s(%s/%s)\n" "$rtt_label" "$ping_recv" "$ping_sent" ;;
        fail)    printf "       Ping : \e[31m✗\e[0m  (%s/%s)\n"   "$ping_recv" "$ping_sent" ;;
        skip)    printf "       Ping : \e[90m─\e[0m  Skip (DNS failed)\n" ;;
    esac

    # Services JSON is written line-by-line to a temp file (avoids embedding JSON null in Python code)
    host_svcs_file="$svc_tmpdir/svcs_${idx}"

    # ---- Per-service checks ----
    while IFS=$'\t' read -r svc_port svc_expected svc_desc; do
        cnt_total=$((cnt_total + 1))

        # TCP check
        tcp_st="na"; tcp_err=""; overall="ok"

        if [[ "$dns_st" == "fail" ]]; then
            # DNS failed: skip TCP
            tcp_st="skip"
            tcp_err="DNS failed"
        elif [[ "$svc_port" == "-" ]] || [[ -z "$svc_port" ]]; then
            # Ping-only line
            tcp_st="na"
            tcp_err=""
        else
            IFS='|' read -r tcp_st tcp_err <<< "$(check_tcp "$ping_target" "$svc_port" "$timeout_sec")"
        fi

        # Overall service status
        if [[ "$dns_st" == "fail" ]]; then
            overall="fail"
        else
            overall="ok"
            for st in "$ping_st" "$tcp_st"; do
                [[ "$st" == "na" || "$st" == "skip" ]] && continue
                [[ "$st" == "fail" ]]    && { overall="fail"; break; }
                [[ "$st" == "partial" ]] && overall="warn"
            done
        fi

        # Evaluation
        # For ping-only lines (port='-'), evaluate against ping status
        if [[ "$svc_port" == "-" ]] || [[ -z "$svc_port" ]]; then
            eval_check_st="$ping_st"
            [[ "$eval_check_st" == "partial" ]] && eval_check_st="fail"
        else
            eval_check_st="$tcp_st"
            [[ "$eval_check_st" == "skip" ]] && eval_check_st="fail"
        fi
        eval_result=$(compute_eval "$dns_st" "$svc_expected" "$eval_check_st")

        # Update summary counters
        case "$overall" in
            ok)   cnt_ok=$((cnt_ok+1)) ;;
            warn) cnt_warn=$((cnt_warn+1)) ;;
            fail) cnt_fail=$((cnt_fail+1)) ;;
        esac

        if [[ "$eval_result" != "-" ]]; then
            has_eval=1
            case "$eval_result" in
                PASS) cnt_pass=$((cnt_pass+1)) ;;
                FAIL) cnt_eval_fail=$((cnt_eval_fail+1)) ;;
                SKIP) cnt_eval_skip=$((cnt_eval_skip+1)) ;;
            esac
        fi

        # ---- Console: service line ----
        # Skip if fail_only and this service is ok and eval is not FAIL
        if [[ "$fail_only" -eq 1 ]] && [[ "$overall" == "ok" ]] && [[ "$eval_result" != "FAIL" ]]; then
            :
        else
            # TCP badge
            case "$tcp_st" in
                ok)   tcp_badge="\e[32m[OK  ]\e[0m"; tcp_sym="✓"; tcp_msg="Connected" ;;
                fail) tcp_badge="\e[31m[FAIL]\e[0m"; tcp_sym="✗"; tcp_msg="${tcp_err:-Connection failed}" ;;
                skip) tcp_badge="\e[90m[SKIP]\e[0m"; tcp_sym="─"; tcp_msg="DNS failed" ;;
                na)   tcp_badge="\e[90m[N/A ]\e[0m"; tcp_sym="─"; tcp_msg="Ping only" ;;
                *)    tcp_badge="\e[90m[----]\e[0m"; tcp_sym="─"; tcp_msg="$tcp_st" ;;
            esac

            # Eval suffix
            eval_suffix=""
            if [[ "$svc_expected" != "-" ]] && [[ -n "$svc_expected" ]]; then
                case "$eval_result" in
                    PASS) eval_suffix=" Expected ${svc_expected^^} → \e[32mPASS\e[0m" ;;
                    FAIL) eval_suffix=" Expected ${svc_expected^^} → \e[31mFAIL\e[0m" ;;
                    SKIP) eval_suffix=" Expected ${svc_expected^^} → \e[90mSKIP\e[0m" ;;
                    *)    eval_suffix="" ;;
                esac
            fi

            if [[ "$svc_port" == "-" ]] || [[ -z "$svc_port" ]]; then
                printf "       Ping-only           %b %s  %-22s%b   %s\n" \
                    "$tcp_badge" "$tcp_sym" "$tcp_msg" "$eval_suffix" "$svc_desc"
            else
                printf "       Port %5s/TCP %b %s  %-22s%b   %s\n" \
                    "$svc_port" "$tcp_badge" "$tcp_sym" "$tcp_msg" "$eval_suffix" "$svc_desc"
            fi
        fi

        # Write service JSON as a single line to temp file (parsed by Python later)
        python3 -c "
import json, sys
port = int(sys.argv[1]) if sys.argv[1] not in ('-','') else None
svc = {
    'port':        port,
    'description': sys.argv[2],
    'expected':    sys.argv[3],
    'tcp':         {'status': sys.argv[4], 'error': sys.argv[5]},
    'overall':     sys.argv[6],
    'eval_result': sys.argv[7],
}
print(json.dumps(svc))
" "${svc_port:--}" "${svc_desc}" "${svc_expected}" \
  "$tcp_st" "${tcp_err:-}" "$overall" "$eval_result" \
  >> "$host_svcs_file"

    done < "$svc_file"

    # Emit host-level JSON record (services read from file to avoid null/None issue)
    export _HOST="$host" _DNS_ST="$dns_st" _DNS_ADDRS="${dns_addrs:-}" _DNS_ERR="${dns_err:-}"
    export _PING_ST="$ping_st" _PING_SENT="${ping_sent:-0}" _PING_RECV="${ping_recv:-0}" _PING_RTT="${ping_rtt:-0}"
    export _SVCS_FILE="$host_svcs_file"
    python3 - << 'PYEOF' >> "$tmpfile"
import json, os
from pathlib import Path
svcs = []
sf = os.environ.get('_SVCS_FILE', '')
if sf and Path(sf).exists():
    for line in Path(sf).read_text().splitlines():
        line = line.strip()
        if line:
            svcs.append(json.loads(line))
rtt = os.environ['_PING_RTT']
r = {
    "host": os.environ['_HOST'],
    "dns":  {
        "status":    os.environ['_DNS_ST'],
        "addresses": [x for x in os.environ['_DNS_ADDRS'].split(',') if x],
        "error":     os.environ['_DNS_ERR'],
    },
    "ping": {
        "status":  os.environ['_PING_ST'],
        "sent":    int(os.environ['_PING_SENT']),
        "recv":    int(os.environ['_PING_RECV']),
        "avg_rtt": int(rtt) if rtt and rtt != '0' else None,
    },
    "services": svcs,
}
print(json.dumps(r))
PYEOF

done

# ============================================================
# Summary
# ============================================================

echo ""
printf '%.0s─' {1..50}; echo ""
printf "  Total: %d   \e[32mOK: %d\e[0m   \e[33mWarning: %d\e[0m   \e[31mFailed: %d\e[0m\n" \
    "$cnt_total" "$cnt_ok" "$cnt_warn" "$cnt_fail"
if [[ "$has_eval" -eq 1 ]]; then
    printf "  Evaluation: \e[32mPASS: %d\e[0m / \e[31mFAIL: %d\e[0m / \e[90mSKIP: %d\e[0m\n" \
        "$cnt_pass" "$cnt_eval_fail" "$cnt_eval_skip"
fi
echo ""

# ============================================================
# Investigation (auto-run on NG/WARN)
# ============================================================

if [[ "$cnt_fail" -gt 0 ]] || [[ "$cnt_warn" -gt 0 ]]; then
    invest_ts=$(date '+%Y%m%d-%H%M%S')
    invest_dir="${TMPDIR:-/tmp}"
    invest_file="${invest_dir}/network_investigation_${invest_ts}.txt"
    run_investigation "$tmpfile" "$invest_file" || true
fi

# ============================================================
# HTML report
# ============================================================

if [[ -n "$html_report" ]]; then
    export _HTML_OUTPUT="$html_report"
    export _HTML_LISTFILE="$list_file"
    export _HTML_PINGCOUNT="$ping_count"
    export _HTML_TIMEOUT="$timeout_sec"
    export _HTML_HOSTNAME="$hostname_str"
    export _HTML_GENERATED="$generated"
    export _HTML_HAS_EVAL="$has_eval"

    python3 - "$tmpfile" << 'PYEOF'
import sys, json, os
from pathlib import Path

results_file = sys.argv[1]
hosts = []
for line in Path(results_file).read_text().splitlines():
    line = line.strip()
    if line:
        hosts.append(json.loads(line))

html_output  = os.environ['_HTML_OUTPUT']
list_file    = os.environ['_HTML_LISTFILE']
ping_count   = os.environ['_HTML_PINGCOUNT']
timeout_sec  = os.environ['_HTML_TIMEOUT']
hostname_str = os.environ['_HTML_HOSTNAME']
generated    = os.environ['_HTML_GENERATED']
has_eval     = os.environ['_HTML_HAS_EVAL'] == '1'

# Flatten all services for summary counting
all_services = []
for h in hosts:
    for svc in h['services']:
        all_services.append((h, svc))

ok_count   = sum(1 for _, s in all_services if s['overall'] == 'ok')
warn_count = sum(1 for _, s in all_services if s['overall'] == 'warn')
fail_count = sum(1 for _, s in all_services if s['overall'] == 'fail')
total      = len(all_services)

pass_count      = sum(1 for _, s in all_services if s['eval_result'] == 'PASS')
eval_fail_count = sum(1 for _, s in all_services if s['eval_result'] == 'FAIL')
eval_skip_count = sum(1 for _, s in all_services if s['eval_result'] == 'SKIP')

def he(s):
    return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def badge(st, label=None):
    classes = {'ok':'ok','partial':'warn','fail':'fail','na':'na','warn':'warn','skip':'na'}
    labels  = {'ok':'OK','partial':'PARTIAL','fail':'FAIL','na':'N/A','warn':'WARN','skip':'SKIP'}
    c = classes.get(st, 'na')
    l = label if label else labels.get(st, st.upper())
    return f"<span class='badge {c}'>{l}</span>"

def eval_badge(er):
    if er == 'PASS':
        return "<span class='badge eval-pass'>PASS</span>"
    elif er == 'FAIL':
        return "<span class='badge eval-fail'>FAIL</span>"
    elif er == 'SKIP':
        return "<span class='badge eval-skip'>SKIP</span>"
    else:
        return "<span class='badge na'>—</span>"

rows = []
for h, svc in all_services:
    dns  = h['dns']
    ping = h['ping']
    overall = svc['overall']
    rc = {'ok':'row-ok','warn':'row-warn','fail':'row-fail'}.get(overall,'')

    # DNS cell
    if   dns['status'] == 'ok':   dns_cell = badge('ok')   + ' ' + he(','.join(dns['addresses']))
    elif dns['status'] == 'fail': dns_cell = badge('fail') + ' ' + he(dns['error'])
    else:                          dns_cell = badge('na')   + ' IP address'

    # Ping cell
    p = ping
    rtt = f"{p['avg_rtt']}ms " if p.get('avg_rtt') else ''
    cnt = f"({p['recv']}/{p['sent']})"
    if   p['status'] == 'ok':      ping_cell = badge('ok')      + f' {rtt}{cnt}'
    elif p['status'] == 'partial': ping_cell = badge('partial') + f' {rtt}{cnt}'
    elif p['status'] == 'skip':    ping_cell = badge('skip')
    else:                           ping_cell = badge('fail')    + f' {cnt}'

    # Port/TCP cell
    t = svc['tcp']
    port_val = svc['port']
    if   t['status'] == 'na':   tcp_cell = badge('na') + ' Ping only'
    elif t['status'] == 'skip': tcp_cell = badge('skip') + ' DNS failed'
    elif t['status'] == 'ok':   tcp_cell = badge('ok')   + f" {port_val}/TCP"
    else:                        tcp_cell = badge('fail') + f" {port_val}/TCP " + he(t.get('error',''))

    # Overall badge
    ob = badge(overall)

    # Expected cell
    exp = svc.get('expected', '-')
    exp_cell = he(exp.upper()) if exp and exp != '-' else '—'

    # Eval badge
    eb = eval_badge(svc.get('eval_result', '-'))

    rows.append(
        f"<tr class='{rc}'>"
        f"<td>{he(h['host'])}</td>"
        f"<td>{he(svc['description'])}</td>"
        f"<td>{dns_cell}</td>"
        f"<td>{ping_cell}</td>"
        f"<td>{tcp_cell}</td>"
        f"<td>{ob}</td>"
        f"<td>{exp_cell}</td>"
        f"<td>{eb}</td>"
        f"</tr>"
    )

eval_cards = ""
if has_eval:
    eval_cards = f"""
  <div class="card eval-pass-card"><div class="num">{pass_count}</div><div class="lbl">PASS</div></div>
  <div class="card eval-fail-card"><div class="num">{eval_fail_count}</div><div class="lbl">Eval FAIL</div></div>
  <div class="card eval-skip-card"><div class="num">{eval_skip_count}</div><div class="lbl">Eval SKIP</div></div>"""

html = f"""<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Network Connectivity Check</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}}
.header{{background:#1e293b;color:#fff;padding:20px 24px}}
.header h1{{font-size:20px;font-weight:600}}
.header .sub{{font-size:12px;color:#94a3b8;margin-top:4px}}
.meta{{display:flex;gap:12px;padding:16px 24px;flex-wrap:wrap}}
.meta-item{{background:#fff;border-radius:8px;padding:10px 16px;font-size:12px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.meta-item .label{{color:#64748b;margin-right:6px}}
.summary{{display:flex;gap:12px;padding:0 24px 16px;flex-wrap:wrap}}
.card{{background:#fff;border-radius:8px;padding:16px 20px;text-align:center;flex:1;min-width:100px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.card .num{{font-size:28px;font-weight:700}}.card .lbl{{font-size:11px;color:#64748b;margin-top:2px}}
.card.total .num{{color:#1e293b}}.card.ok .num{{color:#16a34a}}.card.warn .num{{color:#d97706}}.card.fail .num{{color:#dc2626}}
.card.eval-pass-card .num{{color:#16a34a}}.card.eval-fail-card .num{{color:#dc2626}}.card.eval-skip-card .num{{color:#64748b}}
.filter-bar{{padding:8px 24px;display:flex;gap:8px;align-items:center}}
.filter-bar label{{font-size:12px;color:#64748b;margin-right:4px}}
.filter-bar button{{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px;background:#fff;cursor:pointer}}
.filter-bar button.active{{background:#1e293b;color:#fff;border-color:#1e293b}}
.table-wrap{{margin:0 24px 24px;background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1);overflow-x:auto}}
table{{width:100%;border-collapse:collapse;font-size:12px}}
th{{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}}
td{{padding:7px 12px;border-bottom:1px solid #f1f5f9;vertical-align:middle}}
tr:last-child td{{border-bottom:none}}
tr.row-ok{{background:#fff}}tr.row-warn{{background:#fffbeb}}tr.row-fail{{background:#fff1f2}}
.badge{{display:inline-block;font-size:11px;padding:2px 7px;border-radius:4px;font-weight:600;white-space:nowrap}}
.badge.ok{{background:#dcfce7;color:#15803d}}.badge.warn{{background:#fef3c7;color:#92400e}}
.badge.fail{{background:#fee2e2;color:#b91c1c}}.badge.na{{background:#f1f5f9;color:#64748b}}
.badge.eval-pass{{background:#dcfce7;color:#15803d}}.badge.eval-fail{{background:#fee2e2;color:#b91c1c}}
.badge.eval-skip{{background:#e2e8f0;color:#64748b}}
td:first-child{{font-family:monospace;font-weight:600}}
.footer{{text-align:center;padding:16px;font-size:11px;color:#94a3b8}}.hidden{{display:none}}
</style></head><body>
<div class="header"><h1>&#127760; Network Connectivity Check</h1><div class="sub">Generated: {generated}</div></div>
<div class="meta">
  <div class="meta-item"><span class="label">Target list:</span>{he(list_file)}</div>
  <div class="meta-item"><span class="label">Ping count:</span>{ping_count}</div>
  <div class="meta-item"><span class="label">Timeout:</span>{timeout_sec}s</div>
  <div class="meta-item"><span class="label">Executed:</span>{he(hostname_str)}</div>
</div>
<div class="summary">
  <div class="card total"><div class="num">{total}</div><div class="lbl">Total</div></div>
  <div class="card ok">   <div class="num">{ok_count}</div><div class="lbl">OK</div></div>
  <div class="card warn"> <div class="num">{warn_count}</div><div class="lbl">Warning</div></div>
  <div class="card fail"> <div class="num">{fail_count}</div><div class="lbl">Failed</div></div>{eval_cards}
</div>
<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filter('all',this)">All</button>
  <button onclick="filter('ok',this)">OK</button>
  <button onclick="filter('warn',this)">Warning</button>
  <button onclick="filter('fail',this)">Failed</button>
</div>
<div class="table-wrap">
<table><thead><tr>
  <th>Host</th><th>Description</th><th>DNS</th><th>Ping</th><th>Port (TCP)</th>
  <th>Status</th><th>Expected</th><th>Evaluation</th>
</tr></thead>
<tbody>{''.join(rows)}</tbody></table></div>
<div class="footer">check_network_connectivity.sh &bull; {generated}</div>
<script>
function filter(mode,btn){{
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(row=>{{
    var show=mode==='all'||(mode==='ok'&&row.classList.contains('row-ok'))||(mode==='warn'&&row.classList.contains('row-warn'))||(mode==='fail'&&row.classList.contains('row-fail'));
    row.classList.toggle('hidden',!show);
  }});
}}
</script></body></html>"""

out_dir = os.path.dirname(html_output)
if out_dir: os.makedirs(out_dir, exist_ok=True)
with open(html_output, 'w', encoding='utf-8') as f:
    f.write(html)
print(f"  HTML report: {html_output}")
PYEOF
fi

exit $([ "$cnt_fail" -gt 0 ] && echo 1 || echo 0)
