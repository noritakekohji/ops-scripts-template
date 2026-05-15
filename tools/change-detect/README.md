# Change Detection Tool

デプロイや設定変更の前後でサーバー状態を収集し、差分を自動比較するツールです。

## 依存ツール

同リポジトリの以下を利用します（sibling ディレクトリ）。

| スクリプト | 用途 |
|---|---|
| `../server-compare/get_server_info.sh` | Linux: スナップショット収集 |
| `../server-compare/Get-ServerInfo.ps1` | Windows: スナップショット収集 |
| `../server-compare/Compare-ServerInfo.ps1` | Windows: 比較レポート生成 |

## 使い方（Linux）

```bash
# 1. 変更前スナップショット取得
./change_detect.sh before -l deploy-v1.2.3

# 2. ... デプロイ・設定変更作業 ...

# 3. 変更後スナップショット取得 → 自動比較
./change_detect.sh after -l deploy-v1.2.3 --html report.html

# 特定のカテゴリのみ比較
./change_detect.sh before -l deploy-v1.2.3 -c services,packages,environment

# 既存ファイルを直接比較
./change_detect.sh compare before.json after.json --html report.html
```

## 使い方（Windows）

```powershell
# 1. 変更前スナップショット取得
.\Change-Detect.ps1 before -Label deploy-v1.2.3

# 2. ... デプロイ・設定変更作業 ...

# 3. 変更後スナップショット取得 → 自動比較
.\Change-Detect.ps1 after -Label deploy-v1.2.3 -HtmlReport report.html

# 特定カテゴリのみ
.\Change-Detect.ps1 before -Label deploy-v1.2.3 -Category services,packages

# 既存ファイルを直接比較
.\Change-Detect.ps1 compare -BeforePath before.json -AfterPath after.json
```

**ダブルクリック起動**: `Change-Detect.bat`

## スナップショットの命名規則

| モード | ファイル名 |
|---|---|
| before | `<hostname>_before_<label>_<timestamp>.json` |
| after  | `<hostname>_after_<label>_<timestamp>.json`  |

`after` モードでは `*_before_*.json` の中から最新ファイルを自動検索します。

## コンソール出力例

```
=== COLLECTING AFTER snapshot ===
  Host       : web01
  Categories : all
  Output     : web01_after_deploy-v1.2.3_20260516-103000.json

=== CHANGE DETECTION REPORT ===================================================
  Before : web01_before_deploy-v1.2.3_20260516-090000.json
  After  : web01_after_deploy-v1.2.3_20260516-103000.json
  Host   : web01

=== SERVICES  [2 change(s)] ===
  ADDED    nginx           status=active, start_type=enabled
  CHANGED  tomcat          status=active → status=inactive

=== PACKAGES  [3 change(s)] ===
  ADDED    nginx           version=1.24.0
  REMOVED  apache2         version=2.4.52
  CHANGED  libssl1.1       1.1.1t-1 → 1.1.1w-1

=== ENVIRONMENT  [1 change(s)] ===
  CHANGED  APP_VERSION     1.2.2 → 1.2.3

──────────────────────────────────────────────────────────────────
  Total changes: 6  (added: 2  removed: 1  changed: 3)

  HTML report: report.html
```

## HTML レポート

| 機能 | 内容 |
|---|---|
| サマリーカード | 変更総数・追加・削除・変更 |
| カテゴリ別セクション | 変更のみ or 全件表示 |
| フィルター | All / Changes only / Added / Removed / Changed |
| 色分け | 追加（青）/ 削除（赤）/ 変更（黄）/ 同じ（グレー） |

## 比較対象カテゴリ

| カテゴリ | 比較内容 |
|---|---|
| os | OS バージョン、CPU、メモリ等の基本情報 |
| services | サービスの起動状態・スタートタイプ |
| packages | インストール済みパッケージのバージョン |
| users | ローカルユーザー・グループ |
| filesystem | ドライブ使用量・ファイルシステム種別 |
| environment | 環境変数（Machine スコープ） |
| network | ネットワークIF・ルーティング・DNS |
| security | ファイアウォールプロファイル・ルール |
