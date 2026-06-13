#!/usr/bin/env bash
# ============================================================================
# server_snapshot.sh  -  Unified server snapshot tool (Linux)
# Requires: bash 4+, python3
#
# Usage:
#   ./server_snapshot.sh collect  [-c <cats>] [-o <file>] [-l <label>]
#   ./server_snapshot.sh before   [-c <cats>] [-o <file>] [-l <label>]
#   ./server_snapshot.sh after    [-c <cats>] [-o <file>] [-l <label>]
#                                 [-b <before.json>] [--html <file>]
#   ./server_snapshot.sh compare  <before.json> <after.json> [--html <file>]
#   ./server_snapshot.sh list
#
# Subcommands:
#   collect  Collect server configuration snapshot as JSON
#   before   Collect labeled "before" snapshot (pre-change)
#   after    Collect "after" snapshot + auto-compare with latest before
#   compare  Compare two existing snapshot JSON files
#   list     List stored snapshots in current directory
#
# Options:
#   -c <cats>     Categories: all, os, network, services, packages,
#                 users, filesystem, environment, security (default: all)
#   -o <file>     Output snapshot path (default: auto-named)
#   -l <label>    Label embedded in filename (e.g. deploy-v1.2.3)
#   -b <file>     Before snapshot for "after" mode
#   --html <file> Generate HTML comparison report
#
# Exit codes: 0=success, 1=bad args, 2=file not found, 4=error, 10=prereq missing
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMPARE_PY="${SCRIPT_DIR}/compare_server_info.py"

# ============================================================
# Usage
# ============================================================

usage() { sed -n '2,30p' "$0" >&2; exit 1; }

# ============================================================
# Argument parsing
# ============================================================

command="${1:-}"
if [[ -z "$command" ]]; then
    usage
fi
shift

label=""
categories="all"
output_file=""
before_file=""
after_file=""
html_report=""

case "$command" in
  collect|before|after)
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -c|--category) categories="$2"; shift 2 ;;
        -o|--output)   output_file="$2"; shift 2 ;;
        -l|--label)    label="$2";       shift 2 ;;
        -b|--before)   before_file="$2"; shift 2 ;;
        --html)        html_report="$2"; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    ;;
  compare)
    before_file="${1:-}"; after_file="${2:-}"
    if [[ -z "$before_file" || -z "$after_file" ]]; then
        echo "Usage: $0 compare <before.json> <after.json> [--html <file>]" >&2
        exit 1
    fi
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --html) html_report="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done
    ;;
  list)
    # no additional args
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "Unknown subcommand: $command  (use: collect | before | after | compare | list)" >&2
    exit 1
    ;;
esac

# ============================================================
# Prerequisite check
# ============================================================

if [[ "$command" != "list" ]]; then
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is required but not found." >&2
        exit 10
    fi
fi

# ============================================================
# collect_snapshot()
# ============================================================

collect_snapshot() {
    local snap_mode="$1"   # collect, before, or after
    local snap_cats="$2"
    local snap_file="$3"
    local snap_label="$4"

    # Build output filename if empty
    if [[ -z "$snap_file" ]]; then
        local hn
        hn=$(hostname -s 2>/dev/null || echo "localhost")
        local ts
        ts=$(date '+%Y%m%d-%H%M%S')
        local label_part="${snap_label:+_${snap_label}}"
        snap_file="${hn}_${snap_mode}${label_part}_${ts}.json"
    fi

    # Resolve categories
    local all_cats="os network services packages users filesystem environment security"
    local resolved
    if [[ "$snap_cats" == "all" ]]; then
        resolved="$all_cats"
    else
        resolved="${snap_cats//,/ }"
    fi

    echo ""
    echo "=== Collecting ${snap_mode^^} snapshot ==="
    echo "  Categories : $resolved"
    echo ""

    export _OPS_CATEGORIES="$resolved"
    export _OPS_OUTPUT="$snap_file"

    python3 - << 'PYEOF'
import os, sys, json, subprocess, socket, platform, re, datetime
from pathlib import Path

categories = os.environ.get('_OPS_CATEGORIES', '').split()
output_path = os.environ.get('_OPS_OUTPUT', '')

def run(cmd, default=''):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else default
    except Exception:
        return default

def run_lines(cmd):
    return [l for l in run(cmd, '').splitlines() if l.strip()]

def collect_os():
    info = {
        'hostname': socket.getfqdn(), 'domain': '',
        'os_name': platform.system(), 'os_version': platform.release(),
        'os_build': '', 'architecture': platform.machine(),
        'timezone': '', 'locale': '', 'last_boot': '',
        'cpu_model': '', 'cpu_sockets': 0, 'cpu_cores': 0,
        'cpu_logical_procs': 0, 'cpu_speed_mhz': 0,
        'total_memory_gb': 0.0, 'free_memory_gb': 0.0,
        'used_memory_gb': 0.0, 'swap_total_gb': 0.0, 'swap_free_gb': 0.0,
    }
    os_release = Path('/etc/os-release')
    if os_release.exists():
        for line in os_release.read_text().splitlines():
            if line.startswith('PRETTY_NAME='):
                info['os_name'] = line.split('=',1)[1].strip().strip('"')
            elif line.startswith('VERSION_ID='):
                info['os_version'] = line.split('=',1)[1].strip().strip('"')
    info['os_build'] = run('uname -r', platform.release())
    tz = run('timedatectl show -p Timezone --value 2>/dev/null', '')
    if not tz: tz = run('cat /etc/timezone 2>/dev/null', '')
    if not tz:
        link = Path('/etc/localtime')
        if link.is_symlink(): tz = str(link.resolve()).split('zoneinfo/')[-1]
    info['timezone'] = tz
    info['locale'] = run("locale | grep '^LANG=' | cut -d= -f2 | tr -d '\"'", '')
    info['last_boot'] = run("who -b 2>/dev/null | awk '{print $3, $4}'", run('uptime -s 2>/dev/null', ''))
    # CPU info via lscpu
    def _mhz(s):
        try: return int(float(s))
        except: return 0
    cpu_cores_per_socket = 0
    for line in run('lscpu 2>/dev/null', '').splitlines():
        if ':' not in line: continue
        k, _, v = line.partition(':'); k, v = k.strip(), v.strip()
        if   k == 'Model name':         info['cpu_model'] = v
        elif k == 'Socket(s)':          info['cpu_sockets'] = int(v) if v.isdigit() else 0
        elif k == 'Core(s) per socket': cpu_cores_per_socket = int(v) if v.isdigit() else 0
        elif k == 'CPU(s)':             info['cpu_logical_procs'] = int(v) if v.isdigit() else 0
        elif k == 'CPU max MHz':        info['cpu_speed_mhz'] = _mhz(v)
        elif k == 'CPU MHz' and not info['cpu_speed_mhz']: info['cpu_speed_mhz'] = _mhz(v)
    if info['cpu_sockets'] and cpu_cores_per_socket:
        info['cpu_cores'] = info['cpu_sockets'] * cpu_cores_per_socket
    if not info['cpu_logical_procs']:
        n = run('grep -c "^processor" /proc/cpuinfo 2>/dev/null', '0')
        info['cpu_logical_procs'] = int(n) if n.isdigit() else 0
    # Memory from /proc/meminfo
    try:
        meminfo = {}
        for l in Path('/proc/meminfo').read_text().splitlines():
            if ':' in l:
                k, _, v = l.partition(':'); meminfo[k.strip()] = v.strip()
        def to_gb_kb(key):
            try: return round(int(meminfo[key].split()[0]) / 1048576, 2)
            except: return 0.0
        avail_key = 'MemAvailable' if 'MemAvailable' in meminfo else 'MemFree'
        info['total_memory_gb'] = to_gb_kb('MemTotal')
        info['free_memory_gb']  = to_gb_kb(avail_key)
        info['used_memory_gb']  = round(info['total_memory_gb'] - info['free_memory_gb'], 2)
        info['swap_total_gb']   = to_gb_kb('SwapTotal')
        info['swap_free_gb']    = to_gb_kb('SwapFree')
    except Exception: pass
    return info

def collect_network():
    interfaces, routes, dns_servers, hosts = [], [], [], []
    addr_out = run('ip -4 addr show 2>/dev/null', '')
    current = None
    for line in addr_out.splitlines():
        m = re.match(r'^\d+:\s+(\S+):', line)
        if m: current = m.group(1)
        m2 = re.match(r'\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)', line)
        if m2 and current and not current.startswith('lo'):
            interfaces.append({'name': current, 'address': m2.group(1), 'prefix': int(m2.group(2))})
    for line in run_lines('ip -4 route show 2>/dev/null'):
        parts = line.split()
        entry = {'destination': parts[0], 'gateway': '', 'interface': ''}
        for i, p in enumerate(parts):
            if p == 'via' and i+1 < len(parts): entry['gateway'] = parts[i+1]
            if p == 'dev' and i+1 < len(parts): entry['interface'] = parts[i+1]
        routes.append(entry)
    resolv = Path('/etc/resolv.conf')
    if resolv.exists():
        servers = [l.split()[1] for l in resolv.read_text().splitlines()
                   if l.startswith('nameserver') and len(l.split()) >= 2]
        if servers: dns_servers.append({'interface': 'system', 'servers': servers})
    hosts_file = Path('/etc/hosts')
    if hosts_file.exists():
        for line in hosts_file.read_text().splitlines():
            line = re.sub(r'#.*', '', line).strip()
            if line:
                parts = line.split()
                if len(parts) >= 2: hosts.append({'ip': parts[0], 'hostnames': parts[1:]})
    return {'interfaces': interfaces, 'routes': routes, 'dns_servers': dns_servers, 'hosts': hosts}

def collect_services():
    services = []
    out = run('systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null', '')
    for line in out.splitlines():
        line = line.strip()
        if not line: continue
        parts = line.split(None, 4)
        if len(parts) < 3: continue
        name = parts[0].replace('.service', '')
        sub  = parts[2] if len(parts) > 2 else ''
        enabled = run(f'systemctl is-enabled {parts[0]} 2>/dev/null', 'unknown')
        services.append({'name': name, 'display_name': name, 'status': sub, 'start_type': enabled})
    return sorted(services, key=lambda x: x['name'])

def collect_packages():
    pkgs = []
    if Path('/usr/bin/dpkg').exists():
        out = run("dpkg-query -W -f='${Package}\t${Version}\t${Maintainer}\n' 2>/dev/null", '')
        for line in out.splitlines():
            parts = line.split('\t')
            if len(parts) >= 2:
                pkgs.append({'name': parts[0], 'version': parts[1], 'vendor': parts[2] if len(parts) > 2 else ''})
    elif Path('/usr/bin/rpm').exists():
        out = run("rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\t%{VENDOR}\n' 2>/dev/null", '')
        for line in out.splitlines():
            parts = line.split('\t')
            if len(parts) >= 2:
                pkgs.append({'name': parts[0], 'version': parts[1], 'vendor': parts[2] if len(parts) > 2 else ''})
    return sorted(pkgs, key=lambda x: x['name'])

def collect_users():
    local_users, local_groups = [], []
    try:
        for line in Path('/etc/passwd').read_text().splitlines():
            if line.startswith('#'): continue
            parts = line.split(':')
            if len(parts) < 7: continue
            local_users.append({
                'name': parts[0], 'uid': int(parts[2]), 'gid': int(parts[3]),
                'description': parts[4], 'home': parts[5], 'shell': parts[6],
                'enabled': not parts[1].startswith('!')
            })
    except Exception: pass
    try:
        for line in Path('/etc/group').read_text().splitlines():
            if line.startswith('#'): continue
            parts = line.split(':')
            if len(parts) < 4: continue
            local_groups.append({'name': parts[0], 'gid': int(parts[2]),
                                  'members': [m for m in parts[3].split(',') if m]})
    except Exception: pass
    return {'local_users': local_users, 'local_groups': local_groups}

def collect_filesystem():
    drives = []
    out = run("df -BG --output=source,target,fstype,used,avail,size,pcent 2>/dev/null | tail -n +2", '')
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 7: continue
        def to_gb(s):
            try: return float(s.replace('G',''))
            except: return 0.0
        drives.append({
            'drive': parts[1], 'root': parts[1], 'device': parts[0], 'fstype': parts[2],
            'used_gb': to_gb(parts[3]), 'free_gb': to_gb(parts[4]), 'total_gb': to_gb(parts[5]),
            'used_pct': float(parts[6].replace('%','')) if parts[6].replace('%','').replace('.','').isdigit() else 0.0,
        })
    # Physical disk layout via lsblk
    disks = []
    lsblk_raw = run('lsblk -J -b -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT 2>/dev/null', '')
    if lsblk_raw:
        try:
            lsblk_data = json.loads(lsblk_raw)
            def _add_dev(d):
                if d.get('type') in ('disk', 'part'):
                    sz = d.get('size')
                    size_gb = round(int(sz) / 1073741824, 2) if sz else 0.0
                    disks.append({
                        'name':       d.get('name', ''),
                        'size_gb':    size_gb,
                        'type':       d.get('type', ''),
                        'model':      (d.get('model') or '').strip(),
                        'mountpoint': d.get('mountpoint') or '',
                    })
                for child in d.get('children', []):
                    _add_dev(child)
            for dev in lsblk_data.get('blockdevices', []):
                _add_dev(dev)
        except Exception: pass
    fstab = []
    try:
        for line in Path('/etc/fstab').read_text().splitlines():
            line = re.sub(r'#.*', '', line).strip()
            if line:
                parts = line.split()
                if len(parts) >= 4:
                    fstab.append({'device': parts[0], 'mount_point': parts[1], 'fstype': parts[2], 'options': parts[3]})
    except Exception: pass
    return {'drives': drives, 'disks': disks, 'fstab': fstab}

def collect_environment():
    machine = {}
    try:
        for line in Path('/etc/environment').read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                machine[k.strip()] = v.strip().strip('"').strip("'")
    except Exception: pass
    if Path('/etc/profile.d').exists():
        for f in Path('/etc/profile.d').glob('*.sh'):
            try:
                for line in f.read_text().splitlines():
                    m = re.match(r'^export\s+([A-Za-z_]\w*)\s*=\s*(.+)', line)
                    if m: machine[m.group(1)] = m.group(2).strip().strip('"').strip("'")
            except Exception: pass
    return {'machine': machine}

def collect_security():
    result = {}
    if run('command -v firewall-cmd', ''):
        state = run('firewall-cmd --state 2>/dev/null', 'unknown')
        rules = []
        active = run('firewall-cmd --list-all 2>/dev/null', '')
        for line in active.splitlines():
            line = line.strip()
            if line.startswith('services:'):
                for svc in line.replace('services:','').split():
                    rules.append({'name': svc, 'direction': 'Inbound', 'action': 'Allow', 'profile': 'public'})
        result['firewall'] = {'type': 'firewalld', 'state': state}
        result['firewall_rules'] = rules
    elif run('command -v iptables', ''):
        result['firewall'] = {'type': 'iptables', 'state': 'active'}
        result['firewall_rules'] = []
    selinux = run('getenforce 2>/dev/null', '')
    if selinux: result['selinux'] = selinux.lower()
    return result

CAT_MAP = {
    'os': collect_os, 'network': collect_network, 'services': collect_services,
    'packages': collect_packages, 'users': collect_users, 'filesystem': collect_filesystem,
    'environment': collect_environment, 'security': collect_security,
}

hostname = socket.gethostname()
now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9)))
result = {
    'meta': {
        'hostname': hostname, 'os_type': 'linux',
        'collected_at': now.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'categories': categories,
    }
}

for cat in categories:
    if cat in CAT_MAP:
        print(f'  Collecting: {cat} ...')
        try: result[cat] = CAT_MAP[cat]()
        except Exception as e: result[cat] = {'error': str(e)}

out_dir = os.path.dirname(output_path)
if out_dir: os.makedirs(out_dir, exist_ok=True)
with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, indent=2, ensure_ascii=False, default=str)

print(f'\nDone.')
print(f'  Hostname : {hostname}')
print(f'  Output   : {output_path}')
PYEOF

    # Set global variable for caller
    _SNAP_OUTPUT="$snap_file"
}

# ============================================================
# run_comparison()
# ============================================================

run_comparison() {
    local bf="$1" af="$2" html="${3:-}"

    [[ -f "$bf" ]] || { echo "Error: before file not found: $bf" >&2; exit 2; }
    [[ -f "$af" ]] || { echo "Error: after file not found: $af" >&2; exit 2; }
    [[ -f "$COMPARE_PY" ]] || { echo "Error: compare engine not found: $COMPARE_PY" >&2; exit 10; }

    local hn
    hn=$(hostname -s 2>/dev/null || echo "localhost")
    local py_args=( "$bf" "$af" )
    [[ -n "$html" ]] && py_args+=( --html "$html" )
    [[ -n "$hn" ]]   && py_args+=( --hostname "$hn" )
    python3 "$COMPARE_PY" "${py_args[@]}"
}

# ============================================================
# find_latest_before()
# ============================================================

find_latest_before() {
    local hn
    hn=$(hostname -s 2>/dev/null || echo "localhost")
    local latest=""
    for f in $(ls -t "${hn}"_before*.json 2>/dev/null); do
        latest="$f"; break
    done
    echo "$latest"
}

# ============================================================
# list_snapshots()
# ============================================================

list_snapshots() {
    local files
    files=$(ls -1t *_collect_*.json *_before_*.json *_after_*.json 2>/dev/null || true)
    if [[ -z "$files" ]]; then
        echo "No snapshots found in current directory."
        return
    fi
    echo ""
    echo "  Snapshots in: $(pwd)"
    printf '  %s\n' "$(printf '%.0s-' {1..70})"
    while IFS= read -r f; do
        local size_kb
        size_kb=$(awk "BEGIN{printf \"%.1f\", $(stat -c%s "$f" 2>/dev/null || echo 0) / 1024}")
        local mtime
        mtime=$(stat -c '%Y' "$f" 2>/dev/null || echo "0")
        local mtime_fmt
        mtime_fmt=$(date -d "@$mtime" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
        printf '  %-50s %8s KB  %s\n' "$f" "$size_kb" "$mtime_fmt"
    done <<< "$files"
    printf '  %s\n' "$(printf '%.0s-' {1..70})"
    local count
    count=$(echo "$files" | wc -l)
    echo "  Total: $count snapshot(s)"
    echo ""
}

# ============================================================
# Main dispatch
# ============================================================

case "$command" in
  collect)
    collect_snapshot "collect" "$categories" "$output_file" "$label"
    ;;
  before)
    collect_snapshot "before" "$categories" "$output_file" "$label"
    echo ""
    echo "  Before snapshot saved: $_SNAP_OUTPUT"
    echo "  Run './server_snapshot.sh after${label:+ -l }${label}' after making your changes."
    ;;
  after)
    collect_snapshot "after" "$categories" "$output_file" "$label"
    out="$_SNAP_OUTPUT"
    echo ""
    echo "  After snapshot saved: $out"

    if [[ -z "$before_file" ]]; then
        before_file=$(find_latest_before)
        if [[ -z "$before_file" ]]; then
            echo "Error: No before snapshot found. Run './server_snapshot.sh before' first." >&2
            exit 2
        fi
        echo "  Using before snapshot: $before_file"
    fi

    run_comparison "$before_file" "$out" "$html_report"
    ;;
  compare)
    run_comparison "$before_file" "$after_file" "$html_report"
    ;;
  list)
    list_snapshots
    ;;
esac
