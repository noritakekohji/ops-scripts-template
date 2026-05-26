#!/usr/bin/env bash
# ============================================================================
# get_server_info.sh
#   Collect Linux server configuration and output as JSON.
#   Requires python3 (available on Amazon Linux 2+, RHEL 8+, Ubuntu 18+).
#
# Usage:
#   get_server_info.sh [-c <categories>] [-o <output_path>] [-h]
#
# Options:
#   -c  Comma-separated categories (default: all)
#       all, os, network, services, packages, users,
#       filesystem, environment, security
#   -o  Output JSON file path
#       (default: <hostname>_<yyyyMMdd-HHmmss>.json in current directory)
#   -h  Show this help
#
# Examples:
#   ./get_server_info.sh
#   ./get_server_info.sh -c os,network,services
#   ./get_server_info.sh -o /tmp/server-before.json
#
# Authentication: requires read access to /etc/passwd, /etc/group, etc.
#                 firewall rules may require sudo
# Exit codes: 0=success, 1=usage error, 4=collection error
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- lib resolution -----------------------------------------------------------
# OPS_LIB env var takes precedence. Otherwise walk up from SCRIPT_DIR looking
# for lib/logging.sh (flat) or lib/linux/logging.sh (OS-split layout). Stop at
# .ops-deploy-root marker so we never walk out of the install tree.
_ops_find_lib() {
    local d="$1"
    while [[ -n "$d" && "$d" != "/" ]]; do
        [[ -f "$d/lib/logging.sh" ]]       && { echo "$d/lib";       return 0; }
        [[ -f "$d/lib/linux/logging.sh" ]] && { echo "$d/lib/linux"; return 0; }
        [[ -f "$d/.ops-deploy-root" ]] && return 1
        d=$(dirname -- "$d")
    done
    return 1
}
if [[ -n "${OPS_LIB:-}" ]]; then
    _ops_lib="$OPS_LIB"
elif ! _ops_lib=$(_ops_find_lib "$SCRIPT_DIR"); then
    echo "[ERROR] lib/logging.sh not found from $SCRIPT_DIR (set OPS_LIB to override)" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_ops_lib/logging.sh"
# shellcheck source=/dev/null
source "$_ops_lib/config.sh"

usage() { sed -n '2,18p' "$0" >&2; exit 1; }

categories="all"
output_path=""
status="unknown"
exit_code=0

cleanup() {
    local rc=$?
    [[ "$status" == "unknown" && "$rc" -eq 0 ]] && status="success"
    log_info "Script end: status=$status exitCode=$rc"
}
trap cleanup EXIT

while getopts "c:o:h" opt; do
    case "$opt" in
        c) categories="$OPTARG" ;;
        o) output_path="$OPTARG" ;;
        h) usage ;;
        *) log_error "Unknown option: -$OPTARG"; status="failed"; exit 1 ;;
    esac
done

load_ops_config "get_server_info" "${OPS_ENV:-}"
cfg_env="${OPS_CONFIG_ENV:-default}"

log_info "Config loaded: env=$cfg_env keys=${#OPS_CONFIG[@]}"
log_info "Args validated: categories=$categories outputPath=$output_path"

# Resolve categories
all_cats="os network services packages users filesystem environment security"
if [[ "$categories" == "all" ]]; then
    resolved="$all_cats"
else
    resolved="${categories//,/ }"
fi

# Default output path
if [[ -z "$output_path" ]]; then
    ts=$(date '+%Y%m%d-%H%M%S')
    hn=$(hostname -s 2>/dev/null || echo "localhost")
    output_path="${hn}_${ts}.json"
fi

log_info "Pre-check start"
if ! command -v python3 &>/dev/null; then
    log_error "python3 is required but not found"
    status="failed"; exit 10
fi
log_info "Pre-check passed: categories=$resolved output=$output_path"
log_info "Main start"

# ============================================================
# Python3 does all collection and JSON assembly
# ============================================================
export _OPS_CATEGORIES="$resolved"
export _OPS_OUTPUT="$output_path"

python3 - << 'PYEOF'
import os, sys, json, subprocess, socket, platform, re, datetime
from pathlib import Path

categories = os.environ.get('_OPS_CATEGORIES', '').split()
output_path = os.environ.get('_OPS_OUTPUT', '')

def run(cmd, default=''):
    """Run a shell command and return stdout, or default on error."""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        return r.stdout.strip() if r.returncode == 0 else default
    except Exception:
        return default

def run_lines(cmd):
    """Run a shell command and return non-empty output lines."""
    out = run(cmd, '')
    return [l for l in out.splitlines() if l.strip()]

# ---- OS ----
def collect_os():
    info = {
        'hostname': socket.getfqdn(),
        'domain':   '',
        'os_name':  platform.system(),
        'os_version': platform.release(),
        'os_build':   platform.version(),
        'architecture': platform.machine(),
        'timezone':  '',
        'locale':    '',
        'last_boot': '',
        'cpu_model': '', 'cpu_sockets': 0, 'cpu_cores': 0,
        'cpu_logical_procs': 0, 'cpu_speed_mhz': 0,
        'total_memory_gb': 0.0, 'free_memory_gb': 0.0,
        'used_memory_gb': 0.0, 'swap_total_gb': 0.0, 'swap_free_gb': 0.0,
    }
    # OS name/version from /etc/os-release
    os_release = Path('/etc/os-release')
    if os_release.exists():
        for line in os_release.read_text().splitlines():
            if line.startswith('PRETTY_NAME='):
                info['os_name'] = line.split('=',1)[1].strip().strip('"')
            elif line.startswith('VERSION_ID='):
                info['os_version'] = line.split('=',1)[1].strip().strip('"')
    # Kernel
    info['os_build'] = run('uname -r', platform.release())
    # Timezone
    tz = run('timedatectl show -p Timezone --value 2>/dev/null', '')
    if not tz:
        tz = run('cat /etc/timezone 2>/dev/null', '')
    if not tz:
        link = Path('/etc/localtime')
        if link.is_symlink():
            tz = str(link.resolve()).split('zoneinfo/')[-1]
    info['timezone'] = tz
    # Locale
    info['locale'] = run("locale | grep '^LANG=' | cut -d= -f2 | tr -d '\"'", '')
    # Last boot
    info['last_boot'] = run("who -b 2>/dev/null | awk '{print $3, $4}'", run('uptime -s 2>/dev/null', ''))
    # CPU info via lscpu
    def _mhz(s):
        try: return int(float(s))
        except: return 0
    cpu_cores_per_socket = 0
    for line in run('lscpu 2>/dev/null', '').splitlines():
        if ':' not in line:
            continue
        k, _, v = line.partition(':')
        k, v = k.strip(), v.strip()
        if   k == 'Model name':         info['cpu_model'] = v
        elif k == 'Socket(s)':          info['cpu_sockets'] = int(v) if v.isdigit() else 0
        elif k == 'Core(s) per socket': cpu_cores_per_socket = int(v) if v.isdigit() else 0
        elif k == 'CPU(s)':             info['cpu_logical_procs'] = int(v) if v.isdigit() else 0
        elif k == 'CPU max MHz':        info['cpu_speed_mhz'] = _mhz(v)
        elif k == 'CPU MHz' and not info['cpu_speed_mhz']:
            info['cpu_speed_mhz'] = _mhz(v)
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
                k, _, v = l.partition(':')
                meminfo[k.strip()] = v.strip()
        def to_gb_kb(key):
            try: return round(int(meminfo[key].split()[0]) / 1048576, 2)
            except: return 0.0
        avail_key = 'MemAvailable' if 'MemAvailable' in meminfo else 'MemFree'
        info['total_memory_gb'] = to_gb_kb('MemTotal')
        info['free_memory_gb']  = to_gb_kb(avail_key)
        info['used_memory_gb']  = round(info['total_memory_gb'] - info['free_memory_gb'], 2)
        info['swap_total_gb']   = to_gb_kb('SwapTotal')
        info['swap_free_gb']    = to_gb_kb('SwapFree')
    except Exception:
        pass
    return info

# ---- Network ----
def collect_network():
    interfaces = []
    # ip addr show
    addr_out = run('ip -4 addr show 2>/dev/null', '')
    current_iface = None
    for line in addr_out.splitlines():
        m = re.match(r'^\d+:\s+(\S+):', line)
        if m:
            current_iface = m.group(1)
        m2 = re.match(r'\s+inet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)', line)
        if m2 and current_iface and not current_iface.startswith('lo'):
            interfaces.append({'name': current_iface, 'address': m2.group(1), 'prefix': int(m2.group(2))})

    # Routes
    routes = []
    for line in run_lines('ip -4 route show 2>/dev/null'):
        parts = line.split()
        entry = {'destination': parts[0], 'gateway': '', 'interface': ''}
        for i, p in enumerate(parts):
            if p == 'via' and i+1 < len(parts): entry['gateway'] = parts[i+1]
            if p == 'dev' and i+1 < len(parts): entry['interface'] = parts[i+1]
        routes.append(entry)

    # DNS
    dns_servers = []
    resolv = Path('/etc/resolv.conf')
    if resolv.exists():
        servers = [l.split()[1] for l in resolv.read_text().splitlines()
                   if l.startswith('nameserver') and len(l.split()) >= 2]
        if servers:
            dns_servers.append({'interface': 'system', 'servers': servers})

    # /etc/hosts
    hosts = []
    hosts_file = Path('/etc/hosts')
    if hosts_file.exists():
        for line in hosts_file.read_text().splitlines():
            line = re.sub(r'#.*', '', line).strip()
            if line:
                parts = line.split()
                if len(parts) >= 2:
                    hosts.append({'ip': parts[0], 'hostnames': parts[1:]})

    return {'interfaces': interfaces, 'routes': routes, 'dns_servers': dns_servers, 'hosts': hosts}

# ---- Services ----
def collect_services():
    services = []
    # systemd
    out = run('systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null', '')
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 4)
        if len(parts) < 3:
            continue
        name = parts[0].replace('.service', '')
        sub  = parts[2] if len(parts) > 2 else ''   # active/inactive/failed
        # Get start type (enabled/disabled/static)
        enabled = run(f'systemctl is-enabled {parts[0]} 2>/dev/null', 'unknown')
        services.append({
            'name':         name,
            'display_name': name,
            'status':       sub,
            'start_type':   enabled,
        })
    return sorted(services, key=lambda x: x['name'])

# ---- Packages ----
def collect_packages():
    pkgs = []
    # Debian/Ubuntu
    if Path('/usr/bin/dpkg').exists():
        out = run("dpkg-query -W -f='${Package}\t${Version}\t${Maintainer}\n' 2>/dev/null", '')
        for line in out.splitlines():
            parts = line.split('\t')
            if len(parts) >= 2:
                pkgs.append({'name': parts[0], 'version': parts[1], 'vendor': parts[2] if len(parts) > 2 else ''})
    # RHEL/CentOS/Amazon Linux
    elif Path('/usr/bin/rpm').exists():
        out = run("rpm -qa --queryformat '%{NAME}\t%{VERSION}-%{RELEASE}\t%{VENDOR}\n' 2>/dev/null", '')
        for line in out.splitlines():
            parts = line.split('\t')
            if len(parts) >= 2:
                pkgs.append({'name': parts[0], 'version': parts[1], 'vendor': parts[2] if len(parts) > 2 else ''})
    return sorted(pkgs, key=lambda x: x['name'])

# ---- Users ----
def collect_users():
    local_users = []
    try:
        for line in Path('/etc/passwd').read_text().splitlines():
            if line.startswith('#'): continue
            parts = line.split(':')
            if len(parts) < 7: continue
            local_users.append({
                'name':        parts[0],
                'uid':         int(parts[2]),
                'gid':         int(parts[3]),
                'description': parts[4],
                'home':        parts[5],
                'shell':       parts[6],
                'enabled':     not parts[1].startswith('!'),
            })
    except Exception:
        pass

    local_groups = []
    try:
        for line in Path('/etc/group').read_text().splitlines():
            if line.startswith('#'): continue
            parts = line.split(':')
            if len(parts) < 4: continue
            members = [m for m in parts[3].split(',') if m]
            local_groups.append({'name': parts[0], 'gid': int(parts[2]), 'members': members})
    except Exception:
        pass

    return {'local_users': local_users, 'local_groups': local_groups}

# ---- Filesystem ----
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
            'drive':    parts[1],
            'root':     parts[1],
            'device':   parts[0],
            'fstype':   parts[2],
            'used_gb':  to_gb(parts[3]),
            'free_gb':  to_gb(parts[4]),
            'total_gb': to_gb(parts[5]),
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
        except Exception:
            pass

    # /etc/fstab
    fstab = []
    try:
        for line in Path('/etc/fstab').read_text().splitlines():
            line = re.sub(r'#.*', '', line).strip()
            if line:
                parts = line.split()
                if len(parts) >= 4:
                    fstab.append({'device': parts[0], 'mount_point': parts[1], 'fstype': parts[2], 'options': parts[3]})
    except Exception:
        pass

    return {'drives': drives, 'disks': disks, 'fstab': fstab}

# ---- Environment ----
def collect_environment():
    machine = {}
    # /etc/environment
    try:
        for line in Path('/etc/environment').read_text().splitlines():
            if '=' in line and not line.startswith('#'):
                k, _, v = line.partition('=')
                machine[k.strip()] = v.strip().strip('"').strip("'")
    except Exception:
        pass
    # /etc/profile.d/*.sh (key=value exports only)
    for f in Path('/etc/profile.d').glob('*.sh') if Path('/etc/profile.d').exists() else []:
        try:
            for line in f.read_text().splitlines():
                m = re.match(r'^export\s+([A-Za-z_]\w*)\s*=\s*(.+)', line)
                if m:
                    machine[m.group(1)] = m.group(2).strip().strip('"').strip("'")
        except Exception:
            pass
    return {'machine': machine}

# ---- Security ----
def collect_security():
    result = {}

    # firewalld
    if run('command -v firewall-cmd', ''):
        state   = run('firewall-cmd --state 2>/dev/null', 'unknown')
        zones   = run_lines('firewall-cmd --list-all-zones 2>/dev/null')
        result['firewall'] = {'type': 'firewalld', 'state': state, 'zone_count': len([z for z in zones if not z.startswith(' ')])}
        rules = []
        active = run('firewall-cmd --list-all 2>/dev/null', '')
        for line in active.splitlines():
            line = line.strip()
            if line.startswith('services:'):
                for svc in line.replace('services:','').split():
                    rules.append({'name': svc, 'direction': 'Inbound', 'action': 'Allow', 'profile': 'public'})
        result['firewall_rules'] = rules
    # iptables fallback
    elif run('command -v iptables', ''):
        out = run('iptables -L --line-numbers -n 2>/dev/null', '')
        result['firewall'] = {'type': 'iptables', 'state': 'active' if out else 'unknown'}
        result['firewall_rules'] = []

    # SELinux
    selinux = run('getenforce 2>/dev/null', '')
    if selinux:
        result['selinux'] = selinux.lower()

    # AppArmor
    aa = run('aa-status --enabled 2>/dev/null && echo yes || echo no', 'no')
    if aa.strip() == 'yes':
        result['apparmor'] = 'enabled'

    return result

# ============================================================
# Assemble
# ============================================================
CAT_MAP = {
    'os':          collect_os,
    'network':     collect_network,
    'services':    collect_services,
    'packages':    collect_packages,
    'users':       collect_users,
    'filesystem':  collect_filesystem,
    'environment': collect_environment,
    'security':    collect_security,
}

hostname = socket.gethostname()
now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=9)))

result = {
    'meta': {
        'hostname':     hostname,
        'os_type':      'linux',
        'collected_at': now.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'categories':   categories,
    }
}

for cat in categories:
    if cat in CAT_MAP:
        try:
            result[cat] = CAT_MAP[cat]()
        except Exception as e:
            result[cat] = {'error': str(e)}

out_dir = os.path.dirname(output_path)
if out_dir:
    os.makedirs(out_dir, exist_ok=True)

with open(output_path, 'w', encoding='utf-8') as f:
    json.dump(result, f, indent=2, ensure_ascii=False, default=str)

# Console summary
print('')
print('=== Collection Complete ===')
print(f'  Hostname   : {hostname}')
print(f'  OS Type    : linux')
print(f'  Categories : {", ".join(categories)}')
print(f'  Output     : {output_path}')
print('')
PYEOF

log_info "Main complete"
status="success"
