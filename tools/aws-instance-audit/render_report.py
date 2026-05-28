#!/usr/bin/env python3
"""
render_report.py  -  aws_instance_audit の JSON から HTML レポートを生成

使い方:
    python3 render_report.py <audit.json> <output.html>
"""
from __future__ import annotations
import json, sys, html
from pathlib import Path
from datetime import datetime


def he(v) -> str:
    if v is None:
        return ''
    return html.escape(str(v))


def load(path: str) -> dict:
    with open(path, encoding='utf-8-sig') as f:
        return json.load(f)


def section(title: str, body: str) -> str:
    return f"""
<div class="section">
  <div class="section-title">{he(title)}</div>
  {body}
</div>"""


def kv_table(d: dict) -> str:
    rows = ''.join(
        f"<tr><td class='k'>{he(k)}</td><td>{he(v)}</td></tr>"
        for k, v in d.items()
    )
    return f"<table class='kv'><tbody>{rows}</tbody></table>"


def render_instance(inst: dict) -> str:
    if not inst:
        return ''
    tags = inst.get('tags', {}) or {}
    meta = {k: v for k, v in inst.items() if k != 'tags'}
    body = kv_table(meta)
    if tags:
        tag_rows = ''.join(
            f"<tr><td class='k'>{he(k)}</td><td>{he(v)}</td></tr>"
            for k, v in tags.items()
        )
        body += f"<div class='subtitle'>Tags</div><table class='kv'><tbody>{tag_rows}</tbody></table>"
    return section('インスタンス', body)


def render_iam(iam: dict) -> str:
    if not iam:
        return ''
    body = kv_table({
        'role_name': iam.get('role_name', ''),
        'role_arn':  iam.get('role_arn', ''),
    })
    att = iam.get('attached_policies', []) or []
    if att:
        rows = ''.join(
            f"<tr><td>{he(p.get('name'))}</td><td class='mono'>{he(p.get('arn'))}</td></tr>"
            for p in att
        )
        body += ("<div class='subtitle'>Attached managed policies</div>"
                 "<table><thead><tr><th>Name</th><th>ARN</th></tr></thead>"
                 f"<tbody>{rows}</tbody></table>")
    inl = iam.get('inline_policies', []) or []
    if inl:
        items = ''.join(f"<li>{he(n)}</li>" for n in inl)
        body += f"<div class='subtitle'>Inline policies</div><ul>{items}</ul>"
    if not att and not inl:
        body += "<p class='muted'>（アタッチされたポリシーなし、または取得権限なし）</p>"
    return section('IAM ロール / ポリシー', body)


def _perm_rows(perms: list) -> str:
    rows = ''
    for p in perms or []:
        proto = p.get('protocol', '')
        frm, to = p.get('from_port'), p.get('to_port')
        if frm is None and to is None:
            port = 'all'
        elif frm == to:
            port = str(frm)
        else:
            port = f"{frm}-{to}"
        targets = (p.get('cidrs', []) or []) + (p.get('sg_refs', []) or [])
        tgt = ', '.join(targets) if targets else '-'
        rows += (f"<tr><td>{he(proto)}</td><td>{he(port)}</td>"
                 f"<td class='mono'>{he(tgt)}</td></tr>")
    if not rows:
        rows = "<tr><td colspan='3' class='muted'>(なし)</td></tr>"
    return rows


def render_sgs(sgs: list) -> str:
    if not sgs:
        return ''
    blocks = ''
    for g in sgs:
        head = kv_table({
            'group_id':   g.get('group_id', ''),
            'group_name': g.get('group_name', ''),
            'description': g.get('description', ''),
            'vpc_id':     g.get('vpc_id', ''),
        })
        ingress = ("<div class='subtitle'>Ingress</div>"
                   "<table><thead><tr><th>Proto</th><th>Port</th><th>Source</th></tr></thead>"
                   f"<tbody>{_perm_rows(g.get('ingress'))}</tbody></table>")
        egress = ("<div class='subtitle'>Egress</div>"
                  "<table><thead><tr><th>Proto</th><th>Port</th><th>Destination</th></tr></thead>"
                  f"<tbody>{_perm_rows(g.get('egress'))}</tbody></table>")
        blocks += f"<div class='card'>{head}{ingress}{egress}</div>"
    return section(f'Security Groups ({len(sgs)})', blocks)


def render_network(net: dict) -> str:
    if not net:
        return ''
    body = ''
    if net.get('vpc'):
        body += "<div class='subtitle'>VPC</div>" + kv_table(net['vpc'])
    if net.get('subnet'):
        body += "<div class='subtitle'>Subnet</div>" + kv_table(net['subnet'])
    enis = net.get('enis', []) or []
    if enis:
        rows = ''.join(
            f"<tr><td class='mono'>{he(e.get('eni_id'))}</td>"
            f"<td>{he(e.get('private_ip'))}</td>"
            f"<td class='mono'>{he(', '.join(e.get('groups', [])))}</td>"
            f"<td>{he(e.get('description'))}</td></tr>"
            for e in enis
        )
        body += ("<div class='subtitle'>ENIs</div>"
                 "<table><thead><tr><th>ENI</th><th>Private IP</th><th>SGs</th><th>Desc</th></tr></thead>"
                 f"<tbody>{rows}</tbody></table>")
    rts = net.get('route_tables', []) or []
    if rts:
        for rt in rts:
            rows = ''.join(
                f"<tr><td class='mono'>{he(r.get('dest'))}</td><td class='mono'>{he(r.get('target'))}</td></tr>"
                for r in rt.get('routes', [])
            )
            body += (f"<div class='subtitle'>Route table {he(rt.get('route_table_id'))}</div>"
                     "<table><thead><tr><th>Destination</th><th>Target</th></tr></thead>"
                     f"<tbody>{rows}</tbody></table>")
    return section('ネットワーク (VPC / Subnet / ENI / Route)', body)


def render(data_path: str, out_path: str) -> None:
    d = load(data_path)
    meta = d.get('meta', {})
    gen = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    parts = [
        render_instance(d.get('instance', {})),
        render_iam(d.get('iam', {})),
        render_sgs(d.get('security_groups', [])),
        render_network(d.get('network', {})),
    ]
    body = ''.join(p for p in parts if p)

    htmldoc = f"""<!DOCTYPE html>
<html lang="ja"><head><meta charset="UTF-8">
<title>AWS Instance Audit Report</title>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}}
.header{{background:#232f3e;color:#fff;padding:20px 24px}}
.header h1{{font-size:20px;font-weight:700}}
.header .sub{{font-size:12px;color:#ff9900;margin-top:4px}}
.meta-bar{{display:flex;gap:14px;padding:12px 24px;flex-wrap:wrap;background:#fff;border-bottom:1px solid #e2e8f0}}
.meta-item{{font-size:12px;color:#475569}}.meta-item span{{font-weight:600;color:#1e293b;margin-left:4px}}
.section{{padding:16px 24px}}
.section-title{{font-size:15px;font-weight:700;color:#1e293b;margin-bottom:12px;padding-left:8px;border-left:3px solid #ff9900}}
.subtitle{{font-size:12px;font-weight:700;color:#475569;margin:12px 0 6px}}
.card{{background:#fff;border-radius:8px;padding:16px;margin-bottom:14px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-bottom:8px}}
th{{background:#f1f5f9;padding:7px 10px;text-align:left;font-weight:600;color:#475569;font-size:12px;border-bottom:2px solid #e2e8f0}}
td{{padding:6px 10px;border-bottom:1px solid #f1f5f9;font-size:12px;vertical-align:top;word-break:break-all}}
tr:last-child td{{border-bottom:none}}
td.k{{font-weight:600;color:#475569;width:200px}}
.mono{{font-family:Consolas,monospace;font-size:11px}}
.muted{{color:#94a3b8}}
ul{{margin-left:20px}}
.footer{{text-align:center;padding:16px;font-size:11px;color:#94a3b8}}
</style></head><body>
<div class="header">
  <h1>&#9729; AWS Instance Audit Report</h1>
  <div class="sub">Generated: {he(gen)}</div>
</div>
<div class="meta-bar">
  <div class="meta-item">Host<span>{he(meta.get('hostname'))}</span></div>
  <div class="meta-item">Instance<span>{he(meta.get('instance_id'))}</span></div>
  <div class="meta-item">Region<span>{he(meta.get('region'))}</span></div>
  <div class="meta-item">Collected<span>{he(meta.get('collected_at'))}</span></div>
  <div class="meta-item">Categories<span>{he(meta.get('categories'))}</span></div>
</div>
{body}
<div class="footer">aws_instance_audit &bull; {he(gen)}</div>
</body></html>"""

    p = Path(out_path)
    if p.parent and not p.parent.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(htmldoc, encoding='utf-8')
    print(f'Report: {out_path}')


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} <audit.json> <output.html>', file=sys.stderr)
        sys.exit(1)
    render(sys.argv[1], sys.argv[2])
