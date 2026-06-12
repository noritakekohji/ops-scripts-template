# tools/ 見直し — 統廃合・新規ツール・targets.lst エクスポートマクロ 設計書

- 日付: 2026-06-12
- ステータス: ユーザー承認済み（実装計画作成前）

## 背景と目的

`tools/` 配下の運用補助ツール 5 種を見直し、以下を行う。

1. **統廃合**: server-compare と change-detect は領域が重複し、change-detect が
   server-compare へ sibling 依存している（「ツールは自己完結」ルールと矛盾）。
   1 ツール `server-snapshot` に統合する。
2. **新規ツール**: log-collector / port-inventory / cert-check の 3 つを追加する。
3. **targets.lst 作成支援**: network-check のターゲットリストを Excel で編集・
   エクスポートできるマクロブックを追加する（エクスポート専用）。

### スコープ外（ユーザー判断）

- targets.lst のインポート（lst → Excel）機能
- 環境別シート対応
- cert-check の network-check への組み込み（独立ツールとする）
- disk-report ツール

## 共通要件

全ツールはリポジトリ規約に準拠する。

- 5-phase 構造（テンプレ準拠、`ci/template-check` を通すこと）
- 終了コード規約（0=成功 / 1=引数不正 / 2=業務エラー / 3=タイムアウト / 4=制御失敗 / 10=前提コマンド不足 / 20=一時障害）
- PowerShell: PS 5.1 互換・UTF-8 BOM 付き / Bash: `set -euo pipefail`・UTF-8 BOM なし LF / .bat: CRLF
- ツールは **自己完結**（`scripts_*/lib/` に依存しない、フォルダ一式コピーで動く）
- Windows セキュリティ制限環境への配慮（Get-Counter/Get-Process 代替、python3 フォールバック）
- bats / Pester テスト、README、CHANGELOG 更新をセットで行う

## A. server-snapshot（server-compare + change-detect 統合）

### 構成

```
tools/server-snapshot/
├── ServerSnapshot.ps1       # Windows 本体
├── server_snapshot.bat      # Windows 起動用バッチ
├── server_snapshot.sh       # Linux 本体
├── compare_server_info.py   # 共通比較エンジン（server-compare から移設、真実の源）
└── README.md
```

### コマンド体系

| サブコマンド | 旧ツールの対応 | 内容 |
|---|---|---|
| `collect` | Get-ServerInfo / get_server_info.sh | スナップショット JSON を収集 |
| `before`  | Change-Detect before | ラベル付き before スナップショット |
| `after`   | Change-Detect after | after 収集 + 最新 before と自動比較 |
| `compare` | Compare-ServerInfo | 任意の 2 JSON を比較（コンソール + HTML） |
| `list`    | （新規） | 蓄積スナップショットの一覧表示 |

- 収集カテゴリ（os/network/services/packages/users/filesystem/environment/security）と
  スナップショット命名規則（`<hostname>_<mode>_<label>_<timestamp>.json`）は現行を踏襲。
- python3 制限環境では PowerShell ネイティブ比較へ自動フォールバック（現行どおり）。

### 後方互換

- `tools/server-compare/` と `tools/change-detect/` は **委譲ラッパー** として残す。
  各スクリプトは引数をそのまま server-snapshot の対応サブコマンドへ転送し、
  起動時に非推奨警告（WARN ログ 1 行）を出す。README に移行案内を書く。
- 委譲解決は「同リポジトリ内の `../server-snapshot/`」のみ。見つからなければ
  exit 10 で「server-snapshot を同梱してください」と案内する。

## B. log-collector（障害時の証跡収集）

### 構成

```
tools/log-collector/
├── LogCollector.ps1 / log_collector.bat / log_collector.sh
├── collect_targets.conf     # 収集対象プリセット定義
└── README.md
```

### 機能

- `-Since 24h` または `-From/-To` で対象期間を指定（既定: 直近 24h、mtime ベース）。
- `collect_targets.conf` にドメイン別プリセット（tomcat / nginx / postgresql / mysql /
  os 等）として「パス glob + 最大サイズ」を定義。`-Target tomcat,os` で選択。
- 出力: `evidence_<hostname>_<timestamp>.zip`
  - `manifest.json`: 収集ファイル一覧（パス・サイズ・SHA-256・mtime）
  - `osinfo.txt`: OS 基本情報（systeminfo / uname -a + df 等）
  - 収集ファイル本体（元のディレクトリ構造を維持）
- 総量上限（既定 500MB、conf で変更可）を超えたら新しい mtime 優先で打ち切り WARN。
- 権限不足で読めないファイルは WARN を出してスキップし、全体は続行（exit 0、
  1 件も収集できなければ exit 2）。

## C. port-inventory（待受ポート棚卸し）

### 構成

```
tools/port-inventory/
├── PortInventory.ps1 / port_inventory.bat / port_inventory.sh
├── expected_ports.lst       # 期待値リスト（サンプル）
└── README.md
```

### 機能

- LISTEN 中の TCP/UDP ポート + プロセス名（可能なら実行パス）を収集。
- `expected_ports.lst` 形式: `<port>, <proto>, <expected>, <description>`
  （expected: ok=待受しているはず / ng=待受してはいけない / -=記録のみ。
  network-check targets.lst と同じ思想）。
- 判定: 期待 ok なのに無い → NG / 期待 ng なのに有る → NG /
  リストにない LISTEN → WARN（unexpected）。
- リスト未指定時は判定なしの一覧出力のみ。`--json` / HTML レポート出力対応。
- Windows: `Get-NetTCPConnection` が制限される環境向けに `netstat -ano` +
  `Win32_Process` CIM のフォールバック。Linux: `ss -tulnp`、無ければ `netstat`。

## D. cert-check（TLS 証明書期限チェック、独立ツール）

### 構成

```
tools/cert-check/
├── CertCheck.ps1 / cert_check.bat / cert_check.sh
├── cert_targets.lst         # 対象リスト（サンプル）
└── README.md
```

### 機能

- `cert_targets.lst` 形式: `<host>, <port>, <warn_days>, <description>`
  （warn_days 省略時は既定 30。port 省略時は 443）。
- TLS 接続し、期限（NotAfter）・残日数・発行者・Subject・SAN を取得。
  - 残日数 < warn_days → WARN / 期限切れ・接続不可 → NG。
- SNI 対応。検証は「期限チェック」が目的なので、チェーン検証エラーは
  WARN 扱いで情報は取得継続する。
- Linux: `openssl s_client`。Windows: .NET `SslStream`（openssl 不要）。
- コンソール一覧 + `--json` / HTML レポート出力。
- 終了コード: network-check と同一の体系とする。
  0=全 OK（WARN なし）/ 1=NG あり / 2=リスト不在 / 10=前提コマンド不足。

## E. targets-editor（network-check 用 Excel マクロ）

### 構成

```
tools/network-check/
├── targets-editor.xlsm      # 入力シート + エクスポートボタン
└── targets-editor.bas       # VBA ソースのエクスポート（レビュー・再生成用）
```

### 機能（エクスポート専用）

- 入力シート列: `Section` / `Host` / `Port` / `Expected` / `Description`。
  - Expected はドロップダウン（ok / ng / -）、Port は数値または `-` を入力規則で検証。
  - Section が前行と変わったところで `# ---- <Section> ----` コメント行を出力。
- 「Export」ボタン: ファイル保存ダイアログで出力先を選び、4-field 形式の
  targets.lst を生成。ヘッダコメント（書式説明）も自動で先頭に付与。
- エンコーディング: **ADODB.Stream で UTF-8（BOM なし）+ LF** を明示制御
  （Excel 標準保存の CP932/CRLF を回避し、リポジトリの LF 統一規約に準拠）。
- エクスポート前バリデーション: Host 空欄 / Port 不正 / Expected 不正をチェックし、
  問題行をハイライトしてエラー一覧をメッセージ表示（不正があれば出力しない）。
- `.xlsm` はバイナリのため、VBA ソースを `targets-editor.bas` として並置し
  diff レビュー可能にする。マクロ修正時は .bas を更新して xlsm に再インポートする
  運用とし、README に手順を書く。

## クリーンアップ（付随作業）

- `tools/perf-monitor/results_test/` と `tools/**/__pycache__/` を .gitignore に追加し、
  作業残骸を削除する。
- `render_report.py`（perf-monitor / aws-instance-audit で重複）は自己完結ルールを
  優先して当面コピー配置のまま維持。将来的な同期検査は今回のスコープ外とする。

## 実装順序

1. targets-editor（Excel マクロ）— 小さく即効性がある
2. server-snapshot 統合（+ 旧 2 ツールのラッパー化）
3. cert-check
4. port-inventory
5. log-collector — conf 設計が最も重いため最後

各ステップごとにテスト・README・CHANGELOG・template-check を完了させてから
次に進む（1 ステップ = 1 コミット以上、Conventional Commits 準拠）。

## テスト方針

- Bash: bats（tests/bats/）、PowerShell: Pester（tests/pester/）。
- 外部依存（TLS 接続・LISTEN ポート・ログファイル）はモック / フィクスチャで代替し、
  最低 happy path + 主要エラー系（リスト不在 → exit 2 等）を検証。
- targets-editor の VBA は自動テスト対象外。出力サンプル lst を
  check_network_connectivity.sh のパーサで読めることをフィクスチャとして検証する。
