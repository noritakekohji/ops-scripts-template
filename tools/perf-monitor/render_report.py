#!/usr/bin/env python3
"""
render_report.py  -  perf_monitor の JSON Lines データから HTML レポートを生成

使い方:
    python3 render_report.py <data.jsonl> <output.html>

環境変数（しきい値、未設定 or 0 で無効）:
    PERF_THR_CPU      CPU使用率しきい値 (%)
    PERF_THR_MEM      メモリ使用率しきい値 (%)
    PERF_THR_DISK_R   ディスク読み込みしきい値 (MB/s)
    PERF_THR_DISK_W   ディスク書き込みしきい値 (MB/s)
    PERF_THR_NET_RX   ネット受信しきい値 (Mbps)
    PERF_THR_NET_TX   ネット送信しきい値 (Mbps)
    PERF_THR_LOAD     ロードアベレージ1分しきい値
"""
from __future__ import annotations
import json, os, sys, statistics
from pathlib import Path
from datetime import datetime

# ─────────────────────────────────────────────────────────────
# しきい値読み込み
# ─────────────────────────────────────────────────────────────
def _thr(key: str, default: float = 0.0) -> float:
    try:
        v = float(os.environ.get(key, default))
        return v if v > 0 else 0.0
    except ValueError:
        return 0.0

THR = {
    'cpu_pct':         _thr('PERF_THR_CPU',    80.0),
    'mem_used_pct':    _thr('PERF_THR_MEM',    85.0),
    'disk_read_mbps':  _thr('PERF_THR_DISK_R', 500.0),
    'disk_write_mbps': _thr('PERF_THR_DISK_W', 500.0),
    'net_rx_mbps':     _thr('PERF_THR_NET_RX', 900.0),
    'net_tx_mbps':     _thr('PERF_THR_NET_TX', 900.0),
    'load_avg_1':      _thr('PERF_THR_LOAD',    4.0),
}

# ─────────────────────────────────────────────────────────────
# データ読み込み・統計
# ─────────────────────────────────────────────────────────────
def load_data(path: str) -> list[dict]:
    records = []
    with open(path, encoding='utf-8-sig') as f:  # utf-8-sig handles optional BOM
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return records

def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    idx = min(int(len(values) * p / 100), len(values) - 1)
    return round(sorted(values)[idx], 2)

def stats(records: list[dict], key: str) -> dict | None:
    vals = [r[key] for r in records if r.get(key) is not None]
    if not vals:
        return None
    return {
        'min':  round(min(vals), 2),
        'max':  round(max(vals), 2),
        'avg':  round(statistics.mean(vals), 2),
        'p95':  pct(vals, 95),
        'count': len(vals),
    }

def ts_label(ts_str: str) -> str:
    """ISO timestamp → 表示用短縮文字列"""
    try:
        dt = datetime.fromisoformat(ts_str)
        return dt.strftime('%H:%M:%S')
    except Exception:
        return ts_str[:19].replace('T', ' ')

def duration_str(sec: float) -> str:
    h = int(sec // 3600); m = int((sec % 3600) // 60); s = int(sec % 60)
    if h > 0:
        return f"{h}時間{m}分{s}秒"
    if m > 0:
        return f"{m}分{s}秒"
    return f"{s}秒"

# ─────────────────────────────────────────────────────────────
# Chart.js データセット生成
# ─────────────────────────────────────────────────────────────
def make_chart(
    chart_id: str,
    title: str,
    labels: list[str],
    datasets: list[dict],       # {label, data, color, fill}
    y_label: str = '',
    threshold: float = 0.0,
    threshold_label: str = '',
    y_max: float | None = None,
    height: int = 220,
) -> str:
    """Chart.js 折れ線グラフ HTML を返す"""

    ds_json_parts = []
    for ds in datasets:
        # null 値は JS の null へ
        data_js = json.dumps([None if v is None else v for v in ds['data']])
        fill_js = 'false'
        if ds.get('fill'):
            fill_js = "'origin'"
        ds_json_parts.append(f"""{{
            label: {json.dumps(ds['label'])},
            data: {data_js},
            borderColor: '{ds['color']}',
            backgroundColor: '{ds['color']}26',
            borderWidth: 1.5,
            pointRadius: 0,
            tension: 0.3,
            fill: {fill_js},
            spanGaps: true
        }}""")

    # しきい値ライン
    if threshold > 0:
        thr_data = [threshold] * len(labels)
        thr_label = threshold_label or f'しきい値 ({threshold})'
        ds_json_parts.append(f"""{{
            label: {json.dumps(thr_label)},
            data: {json.dumps(thr_data)},
            borderColor: '#ef4444',
            borderWidth: 1.5,
            borderDash: [6,4],
            pointRadius: 0,
            fill: false,
            spanGaps: true
        }}""")

    datasets_js = ',\n'.join(ds_json_parts)
    labels_js   = json.dumps(labels)
    y_label_js  = json.dumps(y_label)
    y_max_opt   = f'max: {y_max},' if y_max is not None else ''

    return f"""
<div class="chart-box">
  <div class="chart-title">{title}</div>
  <canvas id="{chart_id}" height="{height}"></canvas>
</div>
<script>
(function(){{
  const ctx = document.getElementById('{chart_id}').getContext('2d');
  new Chart(ctx, {{
    type: 'line',
    data: {{
      labels: {labels_js},
      datasets: [{datasets_js}]
    }},
    options: {{
      responsive: true,
      animation: false,
      interaction: {{ mode: 'index', intersect: false }},
      plugins: {{
        legend: {{ position: 'top', labels: {{ boxWidth: 12, font: {{ size: 11 }} }} }},
        tooltip: {{ callbacks: {{
          label: ctx => ctx.dataset.label + ': ' + (ctx.parsed.y ?? '-') + ' {y_label}'
        }} }}
      }},
      scales: {{
        x: {{
          ticks: {{ maxTicksLimit: 12, font: {{ size: 10 }} }},
          grid: {{ color: '#f1f5f9' }}
        }},
        y: {{
          beginAtZero: true,
          {y_max_opt}
          title: {{ display: {('true' if y_label else 'false')}, text: {y_label_js}, font: {{ size: 11 }} }},
          ticks: {{ font: {{ size: 10 }} }},
          grid: {{ color: '#f1f5f9' }}
        }}
      }}
    }}
  }});
}})();
</script>"""

# ─────────────────────────────────────────────────────────────
# アラート検出
# ─────────────────────────────────────────────────────────────
def find_alerts(records: list[dict]) -> list[dict]:
    alerts = []
    for r in records:
        violations = []
        for key, thr in THR.items():
            if thr <= 0:
                continue
            v = r.get(key)
            if v is not None and v >= thr:
                violations.append({'metric': key, 'value': v, 'threshold': thr})
        if violations:
            alerts.append({'ts': r.get('ts', ''), 'violations': violations})
    return alerts

# ─────────────────────────────────────────────────────────────
# HTML レポート生成
# ─────────────────────────────────────────────────────────────
def render(data_path: str, output_path: str) -> None:
    records = load_data(data_path)
    if not records:
        print(f'[ERROR] No data in {data_path}', file=sys.stderr)
        sys.exit(1)

    # メタ情報
    hostname = records[0].get('hostname', 'unknown')
    os_name  = records[0].get('os', 'unknown')
    ts_first = records[0].get('ts', '')
    ts_last  = records[-1].get('ts', '')
    n_samples = len(records)
    try:
        dt_first = datetime.fromisoformat(ts_first)
        dt_last  = datetime.fromisoformat(ts_last)
        elapsed  = (dt_last - dt_first).total_seconds()
        start_str = dt_first.strftime('%Y-%m-%d %H:%M:%S')
        end_str   = dt_last.strftime('%Y-%m-%d %H:%M:%S')
        dur_str   = duration_str(elapsed)
    except Exception:
        start_str = ts_first[:19]; end_str = ts_last[:19]; dur_str = '不明'

    is_linux   = (os_name == 'linux')
    labels     = [ts_label(r.get('ts', '')) for r in records]
    gen_time   = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

    # ── 統計値 ────────────────────────────────────────────────
    st = {k: stats(records, k) for k in [
        'cpu_pct', 'mem_used_pct', 'mem_used_gb', 'mem_free_gb', 'mem_total_gb',
        'swap_used_pct', 'swap_used_gb',
        'disk_read_mbps', 'disk_write_mbps',
        'net_rx_mbps', 'net_tx_mbps',
        'load_avg_1', 'load_avg_5', 'load_avg_15',
        'proc_count',
    ]}

    # ── アラート ──────────────────────────────────────────────
    alerts = find_alerts(records)
    alert_count = len(alerts)

    def peak(key: str, unit: str = '') -> str:
        s = st.get(key)
        if not s:
            return 'N/A'
        return f"{s['max']}{unit} (avg {s['avg']}{unit})"

    # ── サマリーカード ────────────────────────────────────────
    def card(title: str, value: str, color: str) -> str:
        return f"""<div class="card" style="border-top:3px solid {color}">
    <div class="card-title">{title}</div>
    <div class="card-value">{value}</div>
  </div>"""

    cpu_peak = peak('cpu_pct', '%')
    mem_peak = peak('mem_used_pct', '%')
    dr_peak  = peak('disk_read_mbps', 'MB/s')
    dw_peak  = peak('disk_write_mbps', 'MB/s')
    rx_peak  = peak('net_rx_mbps', 'Mbps')
    tx_peak  = peak('net_tx_mbps', 'Mbps')
    ld_peak  = peak('load_avg_1', '') if is_linux else 'N/A (Windows)'
    alert_color = '#ef4444' if alert_count > 0 else '#16a34a'

    cards_html = ''.join([
        card('CPU ピーク',       cpu_peak, '#3b82f6'),
        card('メモリ ピーク',     mem_peak, '#8b5cf6'),
        card('Disk Read ピーク', dr_peak,  '#f59e0b'),
        card('Disk Write ピーク',dw_peak,  '#f97316'),
        card('Net Rx ピーク',    rx_peak,  '#06b6d4'),
        card('Net Tx ピーク',    tx_peak,  '#0891b2'),
        card('Load Avg ピーク',  ld_peak,  '#22c55e'),
        card('しきい値超過',      f'{alert_count} 回', alert_color),
    ])

    # ── データ抽出 ────────────────────────────────────────────
    def vals(key: str) -> list:
        return [r.get(key) for r in records]

    # ── グラフ生成 ────────────────────────────────────────────
    charts_html = ''

    # 1. CPU
    charts_html += make_chart(
        'chartCpu', 'CPU 使用率', labels,
        [{'label': 'CPU (%)', 'data': vals('cpu_pct'), 'color': '#3b82f6', 'fill': True}],
        '%', THR['cpu_pct'], f"しきい値 ({THR['cpu_pct']}%)", y_max=100,
    )

    # 2. メモリ
    charts_html += make_chart(
        'chartMem', 'メモリ使用率', labels,
        [
            {'label': 'Memory (%)', 'data': vals('mem_used_pct'), 'color': '#8b5cf6', 'fill': True},
            {'label': 'Swap (%)',   'data': vals('swap_used_pct'), 'color': '#c084fc', 'fill': False},
        ],
        '%', THR['mem_used_pct'], f"しきい値 ({THR['mem_used_pct']}%)", y_max=100,
    )

    # 3. メモリ容量
    mem_total = st.get('mem_total_gb')
    y_max_mem = (mem_total['max'] if mem_total else None)
    charts_html += make_chart(
        'chartMemGB', 'メモリ容量 (GB)', labels,
        [
            {'label': '使用 (GB)',  'data': vals('mem_used_gb'), 'color': '#7c3aed', 'fill': True},
            {'label': '空き (GB)',  'data': vals('mem_free_gb'), 'color': '#a78bfa', 'fill': False},
            {'label': 'スワップ (GB)', 'data': vals('swap_used_gb'), 'color': '#c084fc', 'fill': False},
        ],
        'GB', 0, '', y_max=y_max_mem,
    )

    # 4. ディスク I/O
    charts_html += make_chart(
        'chartDisk', 'ディスク I/O', labels,
        [
            {'label': 'Read (MB/s)',  'data': vals('disk_read_mbps'),  'color': '#f59e0b', 'fill': False},
            {'label': 'Write (MB/s)', 'data': vals('disk_write_mbps'), 'color': '#f97316', 'fill': False},
        ],
        'MB/s', max(THR['disk_read_mbps'], THR['disk_write_mbps']), 'しきい値',
    )

    # 5. ネットワーク
    charts_html += make_chart(
        'chartNet', 'ネットワークスループット', labels,
        [
            {'label': 'Rx (Mbps)', 'data': vals('net_rx_mbps'), 'color': '#06b6d4', 'fill': False},
            {'label': 'Tx (Mbps)', 'data': vals('net_tx_mbps'), 'color': '#0891b2', 'fill': False},
        ],
        'Mbps', max(THR['net_rx_mbps'], THR['net_tx_mbps']), 'しきい値',
    )

    # 6. ロードアベレージ（Linux のみ）
    if is_linux:
        charts_html += make_chart(
            'chartLoad', 'ロードアベレージ', labels,
            [
                {'label': 'Load 1min',  'data': vals('load_avg_1'),  'color': '#22c55e', 'fill': False},
                {'label': 'Load 5min',  'data': vals('load_avg_5'),  'color': '#4ade80', 'fill': False},
                {'label': 'Load 15min', 'data': vals('load_avg_15'), 'color': '#86efac', 'fill': False},
            ],
            '', THR['load_avg_1'], f"しきい値 ({THR['load_avg_1']})",
        )

    # 7. プロセス数
    if any(r.get('proc_count') is not None for r in records):
        charts_html += make_chart(
            'chartProc', 'プロセス数', labels,
            [{'label': 'Processes', 'data': vals('proc_count'), 'color': '#64748b', 'fill': False}],
            '',
        )

    # ── 統計サマリーテーブル ──────────────────────────────────
    def stat_row(label: str, key: str, unit: str) -> str:
        s = st.get(key)
        if not s:
            return f'<tr><td>{label}</td><td colspan="4" class="na">N/A</td></tr>'
        thr_v  = THR.get(key, 0)
        max_cls = ' class="alert"' if thr_v > 0 and s['max'] >= thr_v else ''
        avg_cls = ' class="warn"'  if thr_v > 0 and s['avg'] >= thr_v * 0.8 else ''
        return (f'<tr><td>{label}</td>'
                f'<td>{s["min"]}{unit}</td>'
                f'<td{avg_cls}>{s["avg"]}{unit}</td>'
                f'<td{max_cls}>{s["max"]}{unit}</td>'
                f'<td>{s["p95"]}{unit}</td></tr>')

    stat_rows = ''.join([
        stat_row('CPU 使用率',           'cpu_pct',        '%'),
        stat_row('メモリ使用率',          'mem_used_pct',   '%'),
        stat_row('メモリ使用量',          'mem_used_gb',    'GB'),
        stat_row('スワップ使用率',        'swap_used_pct',  '%'),
        stat_row('ディスク Read',         'disk_read_mbps', 'MB/s'),
        stat_row('ディスク Write',        'disk_write_mbps','MB/s'),
        stat_row('ネット受信',            'net_rx_mbps',    'Mbps'),
        stat_row('ネット送信',            'net_tx_mbps',    'Mbps'),
    ] + ([
        stat_row('ロードアベレージ 1min', 'load_avg_1',     ''),
        stat_row('ロードアベレージ 5min', 'load_avg_5',     ''),
    ] if is_linux else []) + [
        stat_row('プロセス数',            'proc_count',     ''),
    ])

    # ── しきい値超過テーブル ──────────────────────────────────
    alert_rows_html = ''
    if alerts:
        rows = []
        for a in alerts[:200]:   # 最大200行表示
            ts_disp = ts_label(a['ts'])
            for v in a['violations']:
                rows.append(
                    f'<tr><td>{ts_disp}</td>'
                    f'<td>{v["metric"]}</td>'
                    f'<td class="alert">{v["value"]}</td>'
                    f'<td>{v["threshold"]}</td></tr>'
                )
        alert_rows_html = '\n'.join(rows)
        if len(alerts) > 200:
            alert_rows_html += f'<tr><td colspan="4">... 他 {len(alerts)-200} 件</td></tr>'

    # ── しきい値設定テーブル ──────────────────────────────────
    thr_rows = ''
    thr_map = [
        ('CPU 使用率', 'cpu_pct', '%'),
        ('メモリ使用率', 'mem_used_pct', '%'),
        ('ディスク Read', 'disk_read_mbps', 'MB/s'),
        ('ディスク Write', 'disk_write_mbps', 'MB/s'),
        ('ネット受信', 'net_rx_mbps', 'Mbps'),
        ('ネット送信', 'net_tx_mbps', 'Mbps'),
        ('ロードアベレージ 1min', 'load_avg_1', ''),
    ]
    for label, key, unit in thr_map:
        tv = THR.get(key, 0)
        if tv > 0:
            thr_rows += f'<tr><td>{label}</td><td>{tv}{unit}</td></tr>'

    # ── HTML 組み立て ─────────────────────────────────────────
    html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>Performance Monitor Report</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<style>
*{{box-sizing:border-box;margin:0;padding:0}}
body{{font-family:'Segoe UI',Arial,sans-serif;font-size:13px;background:#f0f2f5;color:#222}}
.header{{background:#1e293b;color:#fff;padding:20px 24px}}
.header h1{{font-size:22px;font-weight:700}}
.header .sub{{font-size:12px;color:#94a3b8;margin-top:4px}}
.meta-bar{{display:flex;gap:12px;padding:14px 24px;flex-wrap:wrap;background:#fff;border-bottom:1px solid #e2e8f0}}
.meta-item{{font-size:12px;color:#475569}}
.meta-item span{{font-weight:600;color:#1e293b;margin-left:4px}}
.section{{padding:16px 24px}}
.section-title{{font-size:14px;font-weight:700;color:#1e293b;margin-bottom:12px;
    padding-left:8px;border-left:3px solid #3b82f6}}
.cards{{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}}
.card{{background:#fff;border-radius:8px;padding:14px 18px;min-width:160px;
    box-shadow:0 1px 3px rgba(0,0,0,.1);flex:1}}
.card-title{{font-size:11px;color:#64748b;margin-bottom:6px}}
.card-value{{font-size:14px;font-weight:700;color:#1e293b}}
.charts-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(480px,1fr));gap:16px}}
.chart-box{{background:#fff;border-radius:8px;padding:16px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.chart-title{{font-size:13px;font-weight:600;color:#1e293b;margin-bottom:10px}}
table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;
    overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
th{{background:#f1f5f9;padding:8px 12px;text-align:left;font-weight:600;
    color:#475569;font-size:12px;border-bottom:2px solid #e2e8f0}}
td{{padding:7px 12px;border-bottom:1px solid #f1f5f9;font-size:12px}}
tr:last-child td{{border-bottom:none}}
td.alert{{color:#dc2626;font-weight:700}}
td.warn{{color:#d97706;font-weight:600}}
td.na{{color:#94a3b8}}
.alert-badge{{display:inline-block;background:#fee2e2;color:#b91c1c;
    padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}}
.ok-badge{{display:inline-block;background:#dcfce7;color:#15803d;
    padding:2px 8px;border-radius:4px;font-size:11px;font-weight:600}}
.footer{{text-align:center;padding:16px;font-size:11px;color:#94a3b8}}
</style>
</head>
<body>

<div class="header">
  <h1>&#128200; Performance Monitor Report</h1>
  <div class="sub">Generated: {gen_time}</div>
</div>

<div class="meta-bar">
  <div class="meta-item">ホスト<span>{hostname}</span></div>
  <div class="meta-item">OS<span>{os_name}</span></div>
  <div class="meta-item">開始<span>{start_str}</span></div>
  <div class="meta-item">終了<span>{end_str}</span></div>
  <div class="meta-item">計測時間<span>{dur_str}</span></div>
  <div class="meta-item">サンプル数<span>{n_samples} 件</span></div>
  <div class="meta-item">しきい値超過
    <span>{"<span class='alert-badge'>" + str(alert_count) + " 回</span>" if alert_count > 0 else "<span class='ok-badge'>なし</span>"}</span>
  </div>
</div>

<div class="section">
  <div class="section-title">サマリー</div>
  <div class="cards">{cards_html}</div>
</div>

<div class="section">
  <div class="section-title">リソース推移グラフ</div>
  <div class="charts-grid">
    {charts_html}
  </div>
</div>

<div class="section">
  <div class="section-title">統計サマリー</div>
  <table>
    <thead><tr><th>メトリクス</th><th>最小</th><th>平均</th><th>最大</th><th>95パーセンタイル</th></tr></thead>
    <tbody>{stat_rows}</tbody>
  </table>
</div>

{"" if not alerts else f'''
<div class="section">
  <div class="section-title">しきい値超過一覧（{alert_count} 件）</div>
  <table>
    <thead><tr><th>時刻</th><th>メトリクス</th><th>値</th><th>しきい値</th></tr></thead>
    <tbody>{alert_rows_html}</tbody>
  </table>
</div>
'''}

{"" if not thr_rows else f'''
<div class="section">
  <div class="section-title">しきい値設定</div>
  <table style="max-width:400px">
    <thead><tr><th>メトリクス</th><th>しきい値</th></tr></thead>
    <tbody>{thr_rows}</tbody>
  </table>
</div>
'''}

<div class="footer">Performance Monitor &bull; perf_monitor.sh / PerfMonitor.ps1 &bull; {gen_time}</div>
</body>
</html>"""

    Path(output_path).write_text(html, encoding='utf-8')
    print(f'Report: {output_path}  ({n_samples} samples, {alert_count} alerts)')


# ─────────────────────────────────────────────────────────────
if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(f'Usage: {sys.argv[0]} <data.jsonl> <output.html>', file=sys.stderr)
        sys.exit(1)
    render(sys.argv[1], sys.argv[2])
