#!/usr/bin/env bash
# ============================================================================
# get_server_info.sh  -  Collect Linux server configuration (standalone)
# Requires: python3
#
# Usage:
#   ./get_server_info.sh [-c <categories>] [-o <output_path>]
#
# Options:
#   -c  Comma-separated categories (default: all)
#       all, os, network, services, packages, users,
#       filesystem, environment, security
#   -o  Output JSON file path
#       (default: <hostname>_<yyyyMMdd-HHmmss>.json)
#   -h  Show this help
# ============================================================================
set -euo pipefail

usage() { sed -n '2,14p' "$0" >&2; exit 1; }

categories="all"
output_path=""

while getopts "c:o:h" opt; do
    case "$opt" in
        c) categories="$OPTARG" ;;
        o) output_path="$OPTARG" ;;
        h) usage ;;
        *) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required but not found." >&2
    exit 10
fi

all_cats="os network services packages users filesystem environment security"
if [[ "$categories" == "all" ]]; then
    resolved="$all_cats"
else
    resolved="${categories//,/ }"
fi

if [[ -z "$output_path" ]]; then
    ts=$(date '+%Y%m%d-%H%M%S')
    hn=$(hostname -s 2>/dev/null || echo "localhost")
    output_path="${hn}_${ts}.json"
fi

echo "Collecting server info: $resolved"

export _OPS_CATEGORIES="$resolved"
export _OPS_OUTPUT="$output_path"

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
        'timezone': '', 'locale': '', 'last_boot': '', 'total_memory_gb': 0.0,
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
    try:
        for l in Path('/proc/meminfo').read_text().splitlines():
            if l.startswith('MemTotal:'):
                info['total_memory_gb'] = round(int(l.split()[1]) / 1024 / 1024, 2)
                break
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
    fstab = []
    try:
        for line in Path('/etc/fstab').read_text().splitlines():
            line = re.sub(r'#.*', '', line).strip()
            if line:
                parts = line.split()
                if len(parts) >= 4:
                    fstab.append({'device': parts[0], 'mount_point': parts[1], 'fstype': parts[2], 'options': parts[3]})
    except Exception: pass
    return {'drives': drives, 'fstab': fstab}

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
