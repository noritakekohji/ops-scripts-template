#!/usr/bin/env python3
"""
compare_server_info.py
    サーバ情報スナップショット（Get-ServerInfo / get_server_info の JSON）を
    比較してコンソール出力と HTML レポートを生成する **共通比較エンジン**。

    change_detect.sh / Compare-ServerInfo.ps1 / compare_server_info.sh の
    どこから呼ばれても **同じカテゴリ・同じ volatile 除外ルール** で動くよう、
    比較ロジックを 1 箇所に集約している。

使い方:
    python3 compare_server_info.py <before.json> <after.json>
                                   [--html <out.html>] [--hostname <name>]
                                   [--diff-only] [--no-color]
"""
from __future__ import annotations
import argparse, json, os, sys
from datetime import datetime
from pathlib import Path

# ────────────────────────────────────────────────────────────────
# 引数
# ────────────────────────────────────────────────────────────────
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description='Compare two server-info snapshots.')
    p.add_argument('before', help='Path to the "before" JSON snapshot')
    p.add_argument('after',  help='Path to the "after"  JSON snapshot')
    p.add_argument('--html',     default='', help='Output HTML report path')
    p.add_argument('--hostname', default='', help='Override host name in report')
    p.add_argument('--diff-only', action='store_true', help='Console: skip unchanged rows')
    p.add_argument('--no-color',  action='store_true', help='Console: disable ANSI colors')
    return p.parse_args()

# ────────────────────────────────────────────────────────────────
# ヘルパ
# ────────────────────────────────────────────────────────────────
def _load(path: str) -> dict:
    try:
        return json.loads(Path(path).read_text(encoding='utf-8'))
    except Exception as e:
        print(f'Error loading {path}: {e}', file=sys.stderr)
        sys.exit(2)

def _fmt(v) -> str:
    if v is None:                return ''
    if isinstance(v, list):      return ', '.join(str(x) for x in v)
    if isinstance(v, dict):      return ', '.join(f'{k}={vv}' for k, vv in v.items())
    return str(v)

def compare_dicts(bd, ad):
    """Compare flat/nested dicts; return [(state, key, before, after)]."""
    if not isinstance(bd, dict): bd = {}
    if not isinstance(ad, dict): ad = {}
    out = []
    for k in sorted(set(bd) | set(ad)):
        bv = _fmt(bd.get(k)); av = _fmt(ad.get(k))
        if   k not in bd:  out.append(('added',   k, '',  av))
        elif k not in ad:  out.append(('removed', k, bv,  ''))
        elif bv != av:     out.append(('changed', k, bv,  av))
        else:              out.append(('same',    k, bv,  av))
    return out

def compare_list(bl, al, key_field, val_fields):
    """Compare two lists of dicts by a key field."""
    if not isinstance(bl, list): bl = []
    if not isinstance(al, list): al = []
    bd = {str(i.get(key_field, '')): i for i in bl if i.get(key_field) is not None}
    ad = {str(i.get(key_field, '')): i for i in al if i.get(key_field) is not None}
    out = []
    for k in sorted(set(bd) | set(ad)):
        bv = ', '.join(f'{f}={_fmt(bd[k].get(f))}' for f in val_fields) if k in bd else ''
        av = ', '.join(f'{f}={_fmt(ad[k].get(f))}' for f in val_fields) if k in ad else ''
        if   k not in bd:    out.append(('added',   k, '',  av))
        elif k not in ad:    out.append(('removed', k, bv,  ''))
        elif bv != av:       out.append(('changed', k, bv,  av))
        else:                out.append(('same',    k, bv,  av))
    return out

# ────────────────────────────────────────────────────────────────
# カテゴリ別比較（Linux / Windows 共通）
#   volatile （計測時刻で揺れる値）は除外する。ServerSnapshot.ps1 の
#   PS ネイティブ比較器（Compare-*）と同一フィールド・同一除外で動くこと。
#   除外ルール:
#     - os:           free_memory_gb / used_memory_gb / swap_free_gb
#     - filesystem:   used_gb / free_gb / used_pct（drives。mount_options は
#                     PS が比較しないため対象外）
#     - network:      time_sync の _volatile キー（last_sync 等）
# ────────────────────────────────────────────────────────────────
_VOLATILE_OS = {'free_memory_gb', 'used_memory_gb', 'swap_free_gb'}

def cat_os(b, a):
    bd = {k: v for k, v in (b.get('os') or {}).items() if k not in _VOLATILE_OS}
    ad = {k: v for k, v in (a.get('os') or {}).items() if k not in _VOLATILE_OS}
    return compare_dicts(bd, ad)

def cat_services(b, a):
    return compare_list(b.get('services', []), a.get('services', []),
                        'name', ['status', 'start_type'])

def cat_packages(b, a):
    return compare_list(b.get('packages', []), a.get('packages', []),
                        'name', ['version', 'vendor'])

def cat_users(b, a):
    bu = (b.get('users') or {}); au = (a.get('users') or {})
    out = compare_list(bu.get('local_users', []),  au.get('local_users', []),
                       'name', ['enabled', 'shell', 'full_name'])
    out += compare_list(bu.get('local_groups', []), au.get('local_groups', []),
                       'name', ['members'])
    return out

def cat_filesystem(b, a):
    bf = (b.get('filesystem') or {}); af = (a.get('filesystem') or {})
    # Stable drive attributes only (mirrors PS Compare-Filesystem: total_gb /
    # fstype / label). used_gb / free_gb / used_pct fluctuate continuously and
    # are excluded; mount_options is collected but NOT compared by PS native, so
    # it is omitted here to keep both engines field-equivalent.
    out = compare_list(bf.get('drives', []), af.get('drives', []),
                       'drive', ['total_gb', 'fstype', 'label'])
    # disks is a Linux-only collection (the PS native engine never runs against
    # it); comparing it here cannot diverge from PS while preserving Linux detail.
    out += compare_list(bf.get('disks', []),  af.get('disks', []),
                        'name', ['size_gb', 'type', 'model'])
    return out

def cat_environment(b, a):
    be = (b.get('environment') or {}); ae = (a.get('environment') or {})
    out = compare_dicts(be.get('machine', {}), ae.get('machine', {}))
    # user env block compared only when present in either snapshot (PS parity).
    bu = be.get('user'); au = ae.get('user')
    if bu or au:
        out += compare_dicts(bu or {}, au or {})
    return out

def cat_network(b, a):
    bn = (b.get('network') or {}); an = (a.get('network') or {})
    out = compare_list(bn.get('interfaces', []),  an.get('interfaces', []),
                       'name', ['address', 'prefix'])
    out += compare_list(bn.get('routes', []),      an.get('routes', []),
                        'destination', ['gateway', 'interface'])
    out += compare_list(bn.get('dns_servers', []), an.get('dns_servers', []),
                        'interface', ['servers'])
    out += compare_list(bn.get('hosts', []),       an.get('hosts', []),
                        'ip', ['hostnames'])
    # time_sync: scalar dict, but drop _volatile (last-sync timestamps etc.)
    # before comparing — same exclusion as PS Compare-Network.
    bts = bn.get('time_sync'); ats = an.get('time_sync')
    if bts is not None or ats is not None:
        btd = {k: v for k, v in (bts or {}).items() if k != '_volatile'}
        atd = {k: v for k, v in (ats or {}).items() if k != '_volatile'}
        out += compare_dicts(btd, atd)
    # proxy: scalar dict, compared as-is when present in either snapshot.
    bp = bn.get('proxy'); ap = an.get('proxy')
    if bp is not None or ap is not None:
        out += compare_dicts(bp or {}, ap or {})
    return out

def cat_security(b, a):
    bs = (b.get('security') or {}); as_ = (a.get('security') or {})
    out = compare_list(bs.get('firewall_profiles', []), as_.get('firewall_profiles', []),
                       'name', ['enabled', 'inbound_action', 'outbound_action'])
    out += compare_list(bs.get('firewall_rules', []),    as_.get('firewall_rules', []),
                        'name', ['direction', 'action', 'profile'])
    # NOTE: uac / defender / apparmor are collected but NOT compared by PS native
    # Compare-Security; omitted here so both engines stay field-equivalent.
    return out

def cat_patches(b, a):
    return compare_list(b.get('patches', []), a.get('patches', []),
                        'id', ['description', 'installed_on'])

def cat_tuning(b, a):
    return compare_dicts(b.get('tuning') or {}, a.get('tuning') or {})

def cat_scheduled(b, a):
    bs = (b.get('scheduled') or {}); as_ = (a.get('scheduled') or {})
    out = compare_list(bs.get('scheduled_tasks', []), as_.get('scheduled_tasks', []),
                       'name', ['state', 'path'])
    out += compare_list(bs.get('startup', []),        as_.get('startup', []),
                        'name', ['command', 'scope'])
    return out

# middleware: per-product scalar instance fields + config files compared by sha256.
#   Mirrors ServerSnapshot.ps1 Compare-Middleware (the PS-native fallback) so the
#   Python and PS compare engines emit identical middleware diffs.
#   Config files are keyed by  instanceKey::absolute-path  (the same logical file at
#   a different absolute path shows as REMOVED+ADDED, not CHANGED — same-host diffs OK).
_MW_SPECS = [
    # (product, key-builder, scalar value fields, config-files field name)
    ('hana',      lambda x: f"{x.get('sid','')}",
                  ['version', 'instance_no', 'state'], 'config_files'),
    ('sap',       lambda x: f"{x.get('sid','')}/{x.get('instance','')}",
                  ['kernel_version', 'type', 'state'], 'profiles'),
    ('sqlserver', lambda x: f"{x.get('instance_name','')}",
                  ['version', 'edition', 'state', 'port', 'sp_configure_available'], 'config_files'),
    ('tomcat',    lambda x: f"{x.get('name','')}@{x.get('catalina_base','')}",
                  ['version', 'java_version', 'state'], 'config_files'),
]

def cat_middleware(b, a):
    bm = (b.get('middleware') or {}); am = (a.get('middleware') or {})
    out = []
    for prod, keyfn, vals, cfg_field in _MW_SPECS:
        bl = bm.get(prod) or []; al = am.get(prod) or []
        if not isinstance(bl, list): bl = []
        if not isinstance(al, list): al = []
        if not bl and not al:
            continue
        # scalar instance fields, keyed by the product key
        b_scalar = [dict({'name': keyfn(i)}, **{v: i.get(v) for v in vals}) for i in bl]
        a_scalar = [dict({'name': keyfn(i)}, **{v: i.get(v) for v in vals}) for i in al]
        out += compare_list(b_scalar, a_scalar, 'name', vals)
        # config files compared by sha256 (key = instanceKey::path)
        def _cfg_rows(lst):
            rows = []
            for inst in lst:
                files = inst.get(cfg_field) or {}
                if not isinstance(files, dict):
                    continue
                for path, meta in files.items():
                    sha = meta.get('sha256') if isinstance(meta, dict) else None
                    rows.append({'name': f"{keyfn(inst)}::{path}", 'sha256': sha})
            return rows
        b_cfg = _cfg_rows(bl); a_cfg = _cfg_rows(al)
        if b_cfg or a_cfg:
            out += compare_list(b_cfg, a_cfg, 'name', ['sha256'])
    return out

CATEGORIES = [
    ('os',          cat_os),
    ('services',    cat_services),
    ('packages',    cat_packages),
    ('users',       cat_users),
    ('filesystem',  cat_filesystem),
    ('environment', cat_environment),
    ('network',     cat_network),
    ('security',    cat_security),
    ('patches',     cat_patches),
    ('tuning',      cat_tuning),
    ('scheduled',   cat_scheduled),
    ('middleware',  cat_middleware),
]

# ────────────────────────────────────────────────────────────────
# 出力（コンソール）
# ────────────────────────────────────────────────────────────────
def _colors(enable: bool) -> dict:
    if not enable:
        return {k: '' for k in ['RESET','RED','GREEN','YELLOW','CYAN','BOLD','GRAY']}
    return {
        'RESET': '\033[0m', 'RED':    '\033[31m', 'GREEN': '\033[32m',
        'YELLOW':'\033[33m','CYAN':   '\033[36m', 'BOLD':  '\033[1m',
        'GRAY':  '\033[90m',
    }

def print_console(cat_results, b_meta, a_meta, bf, af, diff_only, color_enable):
    C = _colors(color_enable)
    total_added = total_removed = total_changed = 0
    for _, changes in cat_results:
        for state, *_ in changes:
            if state == 'added':   total_added   += 1
            elif state == 'removed': total_removed += 1
            elif state == 'changed': total_changed += 1
    print()
    print(f"{C['BOLD']}{'='*62}{C['RESET']}")
    print(f"{C['BOLD']}  CHANGE DETECTION REPORT{C['RESET']}")
    print(f"  Before : {os.path.basename(bf)}")
    print(f"  After  : {os.path.basename(af)}")
    print(f"  Host   : {b_meta.get('hostname','?')} → {a_meta.get('hostname','?')}")
    print(f"{'='*62}{C['RESET']}")

    for cat_name, changes in cat_results:
        diff = [c for c in changes if c[0] in ('added','removed','changed')]
        color = C['YELLOW'] if diff else C['GREEN']
        print(f"\n{color}=== {cat_name.upper()}  [{len(diff)} change(s)] ==={C['RESET']}")
        for state, key, bv, av in changes:
            if state == 'same' and diff_only:
                continue
            key_w = key[:42].ljust(42)
            if state == 'added':
                print(f"  {C['GREEN']}ADDED  {C['RESET']}  {key_w}  {C['GREEN']}{av}{C['RESET']}")
            elif state == 'removed':
                print(f"  {C['RED']}REMOVED{C['RESET']}  {key_w}  {C['RED']}{bv}{C['RESET']}")
            elif state == 'changed':
                print(f"  {C['YELLOW']}CHANGED{C['RESET']}  {key_w}  "
                      f"{C['RED']}{bv}{C['RESET']}  →  {C['GREEN']}{av}{C['RESET']}")
            elif state == 'error':
                print(f"  {C['RED']}ERROR  {C['RESET']}  {key}")
            elif state == 'same':
                print(f"  {C['GRAY']}same   {C['RESET']}  {key_w}  {C['GRAY']}{bv}{C['RESET']}")

    print()
    print('─' * 62)
    total_diff = total_added + total_removed + total_changed
    sc = C['YELLOW'] if total_diff else C['GREEN']
    print(f"{sc}  Total changes: {total_diff}  "
          f"(added: {total_added}  removed: {total_removed}  changed: {total_changed}){C['RESET']}")
    print()
    return total_diff, total_added, total_removed, total_changed

# ────────────────────────────────────────────────────────────────
# 出力（HTML）
# ────────────────────────────────────────────────────────────────
def write_html(path, cat_results, totals, b_meta, a_meta, bf, af, generated):
    def he(s):
        return (str(s).replace('&','&amp;').replace('<','&lt;')
                       .replace('>','&gt;').replace('"','&quot;'))
    total_diff, total_added, total_removed, total_changed = totals
    rows_html = []
    for cat_name, changes in cat_results:
        diff = [c for c in changes if c[0] in ('added','removed','changed')]
        diff_count = len(diff)
        badge = (f"<span class='badge bdiff'>{diff_count} diff</span>" if diff_count
                 else "<span class='badge bok'>OK</span>")
        rows = []
        for state, key, bv, av in changes:
            cls = {'added':'r-added','removed':'r-removed',
                   'changed':'r-changed','same':'r-same'}.get(state, '')
            rows.append(f"<tr class='{cls}'><td class='key'>{he(key)}</td>"
                        f"<td class='bv'>{he(bv)}</td>"
                        f"<td class='av'>{he(av)}</td></tr>")
        total_in_cat = len(changes); same_count = total_in_cat - diff_count
        rows_html.append(f"""
<section id="{cat_name}" class="cat">
  <h2>{he(cat_name)} {badge}
    <small>same: {same_count} | changed: {sum(1 for c in changes if c[0]=='changed')} | added: {sum(1 for c in changes if c[0]=='added')} | removed: {sum(1 for c in changes if c[0]=='removed')}</small>
  </h2>
  <table><thead><tr><th>Key / Name</th><th>Before</th><th>After</th></tr></thead>
  <tbody>{''.join(rows)}</tbody></table>
</section>""")
    nav = ' | '.join(f"<a href='#{cn}'>{cn}</a>" for cn, _ in cat_results)
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
tr.r-changed td.key{{color:#92400e;font-weight:600}}
tr.r-changed td.bv{{color:#b91c1c}}tr.r-changed td.av{{color:#15803d}}
tr.r-added td{{background:#eff6ff}}tr.r-added td.key{{color:#1e3a5f;font-weight:600}}
tr.r-added td.av{{color:#1d4ed8}}
tr.r-removed td{{background:#fff1f2}}tr.r-removed td.key{{color:#9f1239;font-weight:600}}
tr.r-removed td.bv{{color:#b91c1c}}
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
  <div class="info-card"><div class="lbl">BEFORE</div><strong>{he(b_meta.get('hostname','?'))}</strong><br>
    <span style="color:#64748b">{he(b_meta.get('collected_at',''))}</span><br>
    <code style="font-size:11px">{he(os.path.basename(bf))}</code></div>
  <div class="info-card"><div class="lbl">AFTER</div><strong>{he(a_meta.get('hostname','?'))}</strong><br>
    <span style="color:#64748b">{he(a_meta.get('collected_at',''))}</span><br>
    <code style="font-size:11px">{he(os.path.basename(af))}</code></div>
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
<div class="footer">compare_server_info.py &bull; {generated}</div>
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
    out_dir = os.path.dirname(path)
    if out_dir: os.makedirs(out_dir, exist_ok=True)
    Path(path).write_text(html, encoding='utf-8')
    print(f'  HTML report: {path}')

# ────────────────────────────────────────────────────────────────
# main
# ────────────────────────────────────────────────────────────────
def main() -> int:
    args = parse_args()
    b = _load(args.before)
    a = _load(args.after)
    b_meta = b.get('meta', {})
    a_meta = a.get('meta', {})
    if args.hostname:
        b_meta = dict(b_meta); b_meta['hostname'] = args.hostname
        a_meta = dict(a_meta); a_meta['hostname'] = args.hostname

    in_both = set(b.keys()) & set(a.keys()) - {'meta'}
    cat_results = []
    for cat_name, fn in CATEGORIES:
        if cat_name not in in_both:
            continue
        try:
            changes = fn(b, a)
        except Exception as e:
            changes = [('error', str(e), '', '')]
        cat_results.append((cat_name, changes))

    totals = print_console(cat_results, b_meta, a_meta,
                           args.before, args.after,
                           args.diff_only, not args.no_color)
    if args.html:
        write_html(args.html, cat_results, totals, b_meta, a_meta,
                   args.before, args.after,
                   generated=datetime.now().strftime('%Y-%m-%d %H:%M:%S'))
    return 0

if __name__ == '__main__':
    sys.exit(main())
