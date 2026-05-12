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
# List file format:
#   <host>, <port>, <description>
#   Use '-' or empty port to skip TCP port check.
# ============================================================================
set -euo pipefail

usage() { sed -n '2,17p' "$0" >&2; exit 1; }

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
# Main check loop
# ============================================================

hostname_str=$(hostname -s 2>/dev/null || echo "localhost")
generated=$(date '+%Y-%m-%d %H:%M:%S')

echo ""
echo "=== Network Connectivity Check ==="
echo "  List    : $list_file"
echo "  Timeout : ${timeout_sec}s / Ping: ${ping_count} packets"
echo ""

# Collect results as JSON lines to a temp file
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cnt_ok=0; cnt_warn=0; cnt_fail=0; cnt_total=0

while IFS= read -r raw_line; do
    # Strip inline comments and whitespace
    line="${raw_line%%#*}"
    line="${line//[$'\r']}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue

    IFS=',' read -r host port desc <<< "$line"
    host="${host//[[:space:]]}"
    port="${port//[[:space:]]}"
    desc="${desc#"${desc%%[![:space:]]*}"}"
    desc="${desc%"${desc##*[![:space:]]}"}"
    [[ -z "$host" ]] && continue
    [[ -z "$desc" ]] && desc="$host"

    cnt_total=$((cnt_total+1))

    # DNS
    IFS='|' read -r dns_st dns_addrs dns_err <<< "$(check_dns "$host")"
    # Use resolved IP for ping/TCP if possible
    ping_target="$host"
    if [[ "$dns_st" == "ok" ]] && [[ -n "$dns_addrs" ]]; then
        ping_target="${dns_addrs%%,*}"
    fi

    # Ping
    IFS='|' read -r ping_st ping_sent ping_recv ping_rtt <<< "$(check_ping "$ping_target" "$ping_count" "$timeout_sec")"

    # TCP
    tcp_st="na"; tcp_err=""
    if [[ -n "$port" ]] && [[ "$port" != "-" ]]; then
        IFS='|' read -r tcp_st tcp_err <<< "$(check_tcp "$ping_target" "$port" "$timeout_sec")"
    fi

    # Overall status
    overall="ok"
    for st in "$dns_st" "$ping_st" "$tcp_st"; do
        [[ "$st" == "na" ]] && continue
        [[ "$st" == "fail"    ]] && { overall="fail"; break; }
        [[ "$st" == "partial" ]] && overall="warn"
    done

    case "$overall" in
        ok)   cnt_ok=$((cnt_ok+1)) ;;
        warn) cnt_warn=$((cnt_warn+1)) ;;
        fail) cnt_fail=$((cnt_fail+1)) ;;
    esac

    # Store as JSON
    python3 - << PYEOF >> "$tmpfile"
import json
r = {
    "host":        $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$host"),
    "port":        $(python3 -c "import json,sys; p=sys.argv[1]; print(json.dumps(int(p)) if p and p!='-' else 'None')" "${port:--}"),
    "description": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$desc"),
    "dns":  {"status": "$dns_st",  "addresses": $(python3 -c "import json,sys; s=sys.argv[1]; print(json.dumps(s.split(',') if s else []))" "${dns_addrs:-}"), "error": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${dns_err:-}")},
    "ping": {"status": "$ping_st", "sent": ${ping_sent:-0}, "recv": ${ping_recv:-0}, "avg_rtt": $([ -n "${ping_rtt:-}" ] && [ "${ping_rtt:-0}" != "0" ] && echo "${ping_rtt}" || echo "None")},
    "tcp":  {"status": "$tcp_st",  "error": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${tcp_err:-}")},
    "overall": "$overall"
}
print(json.dumps(r))
PYEOF

    # Console output
    if [[ "$fail_only" -eq 1 ]] && [[ "$overall" == "ok" ]]; then continue; fi

    badge="    "; color_start=""; color_end=$'\e[0m'
    case "$overall" in
        ok)   badge="OK  "; color_start=$'\e[32m' ;;
        warn) badge="WARN"; color_start=$'\e[33m' ;;
        fail) badge="FAIL"; color_start=$'\e[31m' ;;
    esac

    printf "%s[%s] %-25s %s%s\n" "$color_start" "$badge" "$host" "$desc" "$color_end"

    # DNS line
    case "$dns_st" in
        ok)   printf "  \e[32m  DNS  : ✓  %s\e[0m\n" "$dns_addrs" ;;
        fail) printf "  \e[31m  DNS  : ✗  %s\e[0m\n" "$dns_err" ;;
        na)   printf "  \e[90m  DNS  : ─  N/A (IP address)\e[0m\n" ;;
    esac

    # Ping line
    rtt_label=""; [[ -n "${ping_rtt:-}" ]] && [[ "${ping_rtt:-0}" != "0" ]] && rtt_label="${ping_rtt}ms avg "
    case "$ping_st" in
        ok)      printf "  \e[32m  Ping : ✓  %s(%s/%s)\e[0m\n" "$rtt_label" "$ping_recv" "$ping_sent" ;;
        partial) printf "  \e[33m  Ping : ⚠  %s(%s/%s)\e[0m\n" "$rtt_label" "$ping_recv" "$ping_sent" ;;
        fail)    printf "  \e[31m  Ping : ✗  (%s/%s)\e[0m\n"   "$ping_recv" "$ping_sent" ;;
    esac

    # TCP line
    if [[ "$tcp_st" == "na" ]]; then
        printf "  \e[90m  Port : ─  N/A\e[0m\n"
    elif [[ "$tcp_st" == "ok" ]]; then
        printf "  \e[32m  Port : ✓  %s/TCP connected\e[0m\n" "$port"
    else
        printf "  \e[31m  Port : ✗  %s/TCP - %s\e[0m\n" "$port" "$tcp_err"
    fi

done < "$list_file"

# Summary
echo ""
echo "$(printf '─%.0s' {1..50})"
printf "  Total: %d   \e[32mOK: %d\e[0m   \e[33mWarning: %d\e[0m   \e[31mFailed: %d\e[0m\n" \
    "$cnt_total" "$cnt_ok" "$cnt_warn" "$cnt_fail"
echo ""

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

    python3 - "$tmpfile" << 'PYEOF'
import sys, json, os
from pathlib import Path

results_file = sys.argv[1]
results = []
for line in Path(results_file).read_text().splitlines():
    line = line.strip()
    if line:
        results.append(json.loads(line))

html_output  = os.environ['_HTML_OUTPUT']
list_file    = os.environ['_HTML_LISTFILE']
ping_count   = os.environ['_HTML_PINGCOUNT']
timeout_sec  = os.environ['_HTML_TIMEOUT']
hostname_str = os.environ['_HTML_HOSTNAME']
generated    = os.environ['_HTML_GENERATED']

ok_count   = sum(1 for r in results if r['overall'] == 'ok')
warn_count = sum(1 for r in results if r['overall'] == 'warn')
fail_count = sum(1 for r in results if r['overall'] == 'fail')
total      = len(results)

def he(s):
    return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

def badge(st):
    classes = {'ok':'ok','partial':'warn','fail':'fail','na':'na','warn':'warn'}
    labels  = {'ok':'OK','partial':'PARTIAL','fail':'FAIL','na':'N/A','warn':'WARN'}
    c = classes.get(st, 'na')
    l = labels.get(st, st.upper())
    return f"<span class='badge {c}'>{l}</span>"

rows = []
for r in results:
    rc = {'ok':'row-ok','warn':'row-warn','fail':'row-fail'}.get(r['overall'],'')
    ob = badge(r['overall'])

    # DNS
    dns = r['dns']
    if   dns['status'] == 'ok':   dns_cell = badge('ok')   + ' ' + he(','.join(dns['addresses']))
    elif dns['status'] == 'fail': dns_cell = badge('fail') + ' ' + he(dns['error'])
    else:                          dns_cell = badge('na')   + ' IP address'

    # Ping
    p = r['ping']
    rtt = f"{p['avg_rtt']}ms " if p.get('avg_rtt') else ''
    cnt = f"({p['recv']}/{p['sent']})"
    if   p['status'] == 'ok':      ping_cell = badge('ok')      + f' {rtt}{cnt}'
    elif p['status'] == 'partial': ping_cell = badge('partial') + f' {rtt}{cnt}'
    else:                           ping_cell = badge('fail')    + f' {cnt}'

    # TCP
    t = r['tcp']
    if   t['status'] == 'na':   tcp_cell = badge('na')
    elif t['status'] == 'ok':   tcp_cell = badge('ok')   + f" {r['port']}/TCP"
    else:                        tcp_cell = badge('fail') + f" {r['port']}/TCP " + he(t['error'])

    rows.append(f"<tr class='{rc}'><td>{he(r['host'])}</td><td>{he(r['description'])}</td>"
                f"<td>{dns_cell}</td><td>{ping_cell}</td><td>{tcp_cell}</td><td>{ob}</td></tr>")

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
  <div class="card fail"> <div class="num">{fail_count}</div><div class="lbl">Failed</div></div>
</div>
<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filter('all',this)">All</button>
  <button onclick="filter('ok',this)">OK</button>
  <button onclick="filter('warn',this)">Warning</button>
  <button onclick="filter('fail',this)">Failed</button>
</div>
<div class="table-wrap">
<table><thead><tr><th>Host</th><th>Description</th><th>DNS</th><th>Ping</th><th>Port (TCP)</th><th>Status</th></tr></thead>
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
