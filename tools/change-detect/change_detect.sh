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

    export _CD_BEFORE="$bf"
    export _CD_AFTER="$af"
    export _CD_HTML="${html}"
    export _CD_HOSTNAME="$hostname_s"
    export _CD_GENERATED="$(date '+%Y-%m-%d %H:%M:%S')"

    python3 - << 'PYEOF'
import json, os, sys
from pathlib import Path

def load(path):
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception as e:
        print(f"Error loading {path}: {e}", file=sys.stderr)
        sys.exit(1)

bf      = os.environ['_CD_BEFORE']
af      = os.environ['_CD_AFTER']
html_out = os.environ.get('_CD_HTML', '')
hostname = os.environ.get('_CD_HOSTNAME', 'localhost')
generated = os.environ.get('_CD_GENERATED', '')

b = load(bf)
a = load(af)
b_meta = b.get('meta', {})
a_meta = a.get('meta', {})

# ---- helpers ----
RESET='\033[0m'; RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'
CYAN='\033[36m'; BOLD='\033[1m'; GRAY='\033[90m'

def fmt(v):
    if v is None: return ''
    if isinstance(v, list): return ', '.join(str(x) for x in v)
    if isinstance(v, dict): return ', '.join(f"{k}={v2}" for k,v2 in v.items())
    return str(v)

def compare_dicts(bd, ad):
    """Compare flat/nested dicts; return list of (state, key, bval, aval)."""
    changes = []
    if not isinstance(bd, dict): bd = {}
    if not isinstance(ad, dict): ad = {}
    for k in sorted(set(bd) | set(ad)):
        bv = fmt(bd.get(k))
        av = fmt(ad.get(k))
        if k not in bd:              changes.append(('added',   k, '',  av))
        elif k not in ad:            changes.append(('removed', k, bv,  ''))
        elif bv != av:               changes.append(('changed', k, bv,  av))
        else:                        changes.append(('same',    k, bv,  av))
    return changes

def compare_list(bl, al, key_field, val_fields):
    """Compare two lists of dicts by a key field."""
    changes = []
    if not isinstance(bl, list): bl = []
    if not isinstance(al, list): al = []
    bd = {str(i.get(key_field,'')): i for i in bl if i.get(key_field) is not None}
    ad = {str(i.get(key_field,'')): i for i in al if i.get(key_field) is not None}
    for k in sorted(set(bd) | set(ad)):
        if k not in bd:
            av = ', '.join(f"{f}={fmt(ad[k].get(f))}" for f in val_fields)
            changes.append(('added',   k, '',  av))
        elif k not in ad:
            bv = ', '.join(f"{f}={fmt(bd[k].get(f))}" for f in val_fields)
            changes.append(('removed', k, bv,  ''))
        else:
            bv = ', '.join(f"{f}={fmt(bd[k].get(f))}" for f in val_fields)
            av = ', '.join(f"{f}={fmt(ad[k].get(f))}" for f in val_fields)
            if bv != av: changes.append(('changed', k, bv, av))
            else:        changes.append(('same',    k, bv, av))
    return changes

# ---- category comparison ----
CAT_RESULTS = []  # [(cat_name, changes_list)]

def cat_os():
    bd = {k:v for k,v in b.get('os',{}).items()}
    ad = {k:v for k,v in a.get('os',{}).items()}
    return compare_dicts(bd, ad)

def cat_services():
    return compare_list(b.get('services',[]), a.get('services',[]),
                        'name', ['status','start_type'])

def cat_packages():
    return compare_list(b.get('packages',[]), a.get('packages',[]),
                        'name', ['version'])

def cat_users():
    changes = compare_list(
        b.get('users',{}).get('local_users',[]),
        a.get('users',{}).get('local_users',[]),
        'name', ['enabled','shell'])
    changes += compare_list(
        b.get('users',{}).get('local_groups',[]),
        a.get('users',{}).get('local_groups',[]),
        'name', ['members'])
    return changes

def cat_filesystem():
    changes = compare_list(
        b.get('filesystem',{}).get('drives',[]),
        a.get('filesystem',{}).get('drives',[]),
        'drive', ['total_gb','used_gb','free_gb','used_pct','fstype'])
    # Physical disks (Linux lsblk)
    changes += compare_list(
        b.get('filesystem',{}).get('disks',[]),
        a.get('filesystem',{}).get('disks',[]),
        'name', ['size_gb','type','model'])
    return changes

def cat_environment():
    return compare_dicts(
        b.get('environment',{}).get('machine',{}),
        a.get('environment',{}).get('machine',{}))

def cat_network():
    changes = compare_list(
        b.get('network',{}).get('interfaces',[]),
        a.get('network',{}).get('interfaces',[]),
        'name', ['address','prefix'])
    changes += compare_list(
        b.get('network',{}).get('dns_servers',[]),
        a.get('network',{}).get('dns_servers',[]),
        'interface', ['servers'])
    return changes

def cat_security():
    changes = compare_list(
        b.get('security',{}).get('firewall_profiles',[]),
        a.get('security',{}).get('firewall_profiles',[]),
        'name', ['enabled','inbound_action','outbound_action'])
    changes += compare_list(
        b.get('security',{}).get('firewall_rules',[]),
        a.get('security',{}).get('firewall_rules',[]),
        'name', ['direction','action'])
    return changes

CAT_FUNCS = [
    ('os',          cat_os),
    ('services',    cat_services),
    ('packages',    cat_packages),
    ('users',       cat_users),
    ('filesystem',  cat_filesystem),
    ('environment', cat_environment),
    ('network',     cat_network),
    ('security',    cat_security),
]

all_cats_in_both = set(b.keys()) & set(a.keys()) - {'meta'}
for cat_name, cat_fn in CAT_FUNCS:
    if cat_name not in all_cats_in_both:
        continue
    try:
        changes = cat_fn()
    except Exception as e:
        changes = [('error', str(e), '', '')]
    CAT_RESULTS.append((cat_name, changes))

# ---- console output ----
total_added = total_removed = total_changed = 0
for _, changes in CAT_RESULTS:
    for state,*_ in changes:
        if state == 'added':   total_added   += 1
        elif state == 'removed': total_removed += 1
        elif state == 'changed': total_changed += 1

print()
print(f"{BOLD}{'='*62}{RESET}")
print(f"{BOLD}  CHANGE DETECTION REPORT{RESET}")
print(f"  Before : {os.path.basename(bf)}")
print(f"  After  : {os.path.basename(af)}")
print(f"  Host   : {b_meta.get('hostname','?')} → {a_meta.get('hostname','?')}")
print(f"{'='*62}{RESET}")

for cat_name, changes in CAT_RESULTS:
    diff = [c for c in changes if c[0] in ('added','removed','changed')]
    color = YELLOW if diff else GREEN
    print(f"\n{color}=== {cat_name.upper()}  [{len(diff)} change(s)] ==={RESET}")

    for state, key, bv, av in changes:
        if state == 'same': continue
        key_w = key[:42].ljust(42)
        if state == 'added':
            print(f"  {GREEN}ADDED  {RESET}  {key_w}  {GREEN}{av}{RESET}")
        elif state == 'removed':
            print(f"  {RED}REMOVED{RESET}  {key_w}  {RED}{bv}{RESET}")
        elif state == 'changed':
            print(f"  {YELLOW}CHANGED{RESET}  {key_w}  {RED}{bv}{RESET}  →  {GREEN}{av}{RESET}")
        elif state == 'error':
            print(f"  {RED}ERROR  {RESET}  {key}")

print()
print('─' * 62)
total_diff = total_added + total_removed + total_changed
summary_color = YELLOW if total_diff else GREEN
print(f"{summary_color}  Total changes: {total_diff}  "
      f"(added: {total_added}  removed: {total_removed}  changed: {total_changed}){RESET}")
print()

# ---- HTML report ----
if html_out:
    def he(s):
        return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;')

    rows_html = []
    for cat_name, changes in CAT_RESULTS:
        diff = [c for c in changes if c[0] in ('added','removed','changed')]
        diff_count = len(diff)
        badge = f"<span class='badge bdiff'>{diff_count} diff</span>" if diff_count else "<span class='badge bok'>OK</span>"
        anchor = cat_name

        rows = []
        for state, key, bv, av in changes:
            cls = {'added':'r-added','removed':'r-removed','changed':'r-changed','same':'r-same'}.get(state,'')
            rows.append(
                f"<tr class='{cls}'>"
                f"<td class='key'>{he(key)}</td>"
                f"<td class='bv'>{he(bv)}</td>"
                f"<td class='av'>{he(av)}</td></tr>"
            )

        total_in_cat = len(changes)
        same_count = total_in_cat - diff_count
        rows_html.append(f"""
<section id="{anchor}" class="cat">
  <h2>{he(cat_name)} {badge}
    <small>same: {same_count} | changed: {sum(1 for c in changes if c[0]=='changed')} | added: {sum(1 for c in changes if c[0]=='added')} | removed: {sum(1 for c in changes if c[0]=='removed')}</small>
  </h2>
  <table><thead><tr><th>Key / Name</th><th>Before</th><th>After</th></tr></thead>
  <tbody>{''.join(rows)}</tbody></table>
</section>""")

    nav = ' | '.join(f"<a href='#{cn}'>{cn}</a>" for cn,_ in CAT_RESULTS)
    html = f"""<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8">
<title>Change Detection Report</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}}
.header{{background:#1e293b;color:#fff;padding:20px 24px}}
.header h1{{font-size:20px;font-weight:600}}
.header .sub{{font-size:12px;color:#94a3b8;margin-top:4px}}
.header .nav{{margin-top:10px;font-size:12px}}.header .nav a{{color:#93c5fd;margin-right:10px}}
.summary{{display:flex;gap:12px;padding:16px 24px;flex-wrap:wrap}}
.card{{background:#fff;border-radius:8px;padding:16px 20px;text-align:center;flex:1;min-width:110px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.card .num{{font-size:28px;font-weight:700}}.card .lbl{{font-size:11px;color:#64748b;margin-top:2px}}
.card.c-diff .num{{color:#d97706}}.card.c-add .num{{color:#2563eb}}.card.c-rem .num{{color:#dc2626}}.card.c-ok .num{{color:#16a34a}}
.info{{display:flex;gap:12px;padding:0 24px 16px;flex-wrap:wrap}}
.info-card{{background:#fff;border-radius:8px;padding:12px 16px;flex:1;box-shadow:0 1px 3px rgba(0,0,0,.1);font-size:12px}}
.info-card .lbl{{font-size:11px;color:#64748b;margin-bottom:4px}}
.cat{{background:#fff;margin:0 24px 16px;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.cat h2{{font-size:15px;font-weight:600;margin-bottom:10px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}}
.cat h2 small{{font-size:11px;color:#64748b;font-weight:400}}
.badge{{font-size:11px;padding:2px 8px;border-radius:10px;font-weight:600}}
.bok{{background:#dcfce7;color:#16a34a}}.bdiff{{background:#fef3c7;color:#d97706}}
table{{width:100%;border-collapse:collapse;font-size:12px}}
th{{background:#f1f5f9;padding:7px 10px;text-align:left;font-weight:600;color:#475569;border-bottom:2px solid #e2e8f0}}
td{{padding:6px 10px;border-bottom:1px solid #f1f5f9;vertical-align:top;word-break:break-all}}
tr:last-child td{{border-bottom:none}}
tr.r-same td{{background:#f8fafc;color:#94a3b8}}
tr.r-changed td{{background:#fffbeb}}
tr.r-changed td.key{{color:#92400e;font-weight:600}}tr.r-changed td.bv{{color:#b91c1c}}tr.r-changed td.av{{color:#15803d}}
tr.r-added td{{background:#eff6ff}}tr.r-added td.key{{color:#1e3a5f;font-weight:600}}tr.r-added td.av{{color:#1d4ed8}}
tr.r-removed td{{background:#fff1f2}}tr.r-removed td.key{{color:#9f1239;font-weight:600}}tr.r-removed td.bv{{color:#b91c1c}}
td.key{{width:30%;font-weight:500}}td.bv,td.av{{width:35%}}
.filter-bar{{padding:8px 24px;display:flex;gap:8px;align-items:center;flex-wrap:wrap}}
.filter-bar label{{font-size:12px;color:#64748b;margin-right:4px}}
.filter-bar button{{font-size:12px;padding:4px 12px;border:1px solid #cbd5e1;border-radius:4px;background:#fff;cursor:pointer}}
.filter-bar button.active{{background:#1e293b;color:#fff;border-color:#1e293b}}
.hidden{{display:none}}.footer{{text-align:center;padding:16px;font-size:11px;color:#94a3b8}}
</style></head><body>
<div class="header">
  <h1>&#128202; Change Detection Report</h1>
  <div class="sub">Generated: {generated}</div>
  <div class="nav">{nav}</div>
</div>
<div class="summary">
  <div class="card c-diff"><div class="num">{total_diff}</div><div class="lbl">Total Changes</div></div>
  <div class="card c-add"><div class="num">{total_added}</div><div class="lbl">Added</div></div>
  <div class="card c-rem"><div class="num">{total_removed}</div><div class="lbl">Removed</div></div>
  <div class="card c-diff"><div class="num">{total_changed}</div><div class="lbl">Changed</div></div>
</div>
<div class="info">
  <div class="info-card"><div class="lbl">BEFORE</div><strong>{he(b_meta.get('hostname','?'))}</strong><br><span style="color:#64748b">{he(b_meta.get('collected_at',''))}</span><br><code style="font-size:11px">{he(os.path.basename(bf))}</code></div>
  <div class="info-card"><div class="lbl">AFTER</div><strong>{he(a_meta.get('hostname','?'))}</strong><br><span style="color:#64748b">{he(a_meta.get('collected_at',''))}</span><br><code style="font-size:11px">{he(os.path.basename(af))}</code></div>
</div>
<div class="filter-bar">
  <label>Show:</label>
  <button class="active" onclick="filterAll(this)">All</button>
  <button onclick="filterDiff(this)">Changes only</button>
  <button onclick="filterState('r-added',this)">Added</button>
  <button onclick="filterState('r-removed',this)">Removed</button>
  <button onclick="filterState('r-changed',this)">Changed</button>
</div>
{''.join(rows_html)}
<div class="footer">change_detect.sh &bull; {generated}</div>
<script>
function filterAll(btn){{
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(r=>r.classList.remove('hidden'));
}}
function filterDiff(btn){{
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(r=>r.classList.toggle('hidden', r.classList.contains('r-same')));
}}
function filterState(cls,btn){{
  document.querySelectorAll('.filter-bar button').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('tbody tr').forEach(r=>r.classList.toggle('hidden', !r.classList.contains(cls)));
}}
</script></body></html>"""

    out_dir = os.path.dirname(html_out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(html_out, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f"  HTML report: {html_out}")
PYEOF
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
