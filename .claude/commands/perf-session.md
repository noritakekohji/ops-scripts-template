---
description: "perf-monitor の最新セッション状態を表示し、必要なら HTML レポートを生成"
allowed-tools: Bash, PowerShell
---

`tools/perf-monitor/PerfMonitor.ps1 list` で全セッション一覧を取得し、最新のセッションについて
以下を行ってください:

1. `status` で稼働状態と最新サンプルを表示
2. `data.jsonl` の行数（サンプル数）を確認
3. `report.html` が未生成なら、`report <session_dir>` を実行して生成（python3 が利用不可なら
   PowerShell ネイティブレンダラーへ自動フォールバックする実装になっている）
4. 生成されたレポートのフルパスをユーザに提示

セッション検索範囲は `perf_monitor.conf` の `OutputDir` 配下に限定されています。別の
`OutputDir` を見たい場合は引数で渡せます。
