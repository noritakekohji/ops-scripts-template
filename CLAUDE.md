# ops-scripts-template — Claude Code プロジェクトメモリ

このファイルは Claude Code が会話開始時に **自動的に読み込む** プロジェクトメモリです。
リポジトリの構造・規約・落とし穴を集約しており、ここに書いたことを守れば事故が減ります。

---

## このリポジトリの目的

エンタープライズ向け運用スクリプト（PowerShell / Bash / SQL 混在）の **共通テンプレート**。
AWS / OS / 各種ミドルウェア（PostgreSQL / MySQL / SAP HANA / S/4HANA / SQL Server / Tomcat / nginx）の
**制御スクリプト本体**、**運用補助ツール**（perf-monitor / network-check / server-snapshot /
cert-check / port-inventory / log-collector / aws-instance-audit）、
**GitLab CI 設定**、**仕様書**を 1 リポジトリに集約しています。

別リポジトリへの配備は `deploy/sync.py`（GitLab MR 自動作成）で行います。

---

## ディレクトリ構成（要点のみ）

OS-first レイアウトです。詳細は [`ops-scripts-structure.md`](ops-scripts-structure.md)。

```
scripts_linux/<domain>/   Bash 実装 (aws / hana / mysql / nginx / os / postgresql / sap / sqlserver / tomcat / lib)
scripts_windows/<domain>/ PowerShell 実装（domain は Linux 側と 1:1 対応）
config/{default,dev,staging,production}/  環境別設定
docs_{linux,windows}/<domain>/<file>.md   各スクリプトの仕様書
tools/{perf-monitor,network-check,server-snapshot,cert-check,port-inventory,log-collector,aws-instance-audit,templates}/  自己完結ツール
deploy/    別リポジトリ同期 (sync.py + servers.yaml + SPEC.md)
tests/{pester,bats,docker}/  ユニット & Docker E2E
ci/{lint,security,test,deploy,template-check}/  GitLab CI 定義
```

**重要**: 同名ドメインは Linux 側と Windows 側で必ず 1:1 対応させること。
例: `scripts_linux/tomcat/tomcatctl.sh` ↔ `scripts_windows/tomcat/TomcatCtl.ps1`

---

## 必読ドキュメント

| ドキュメント | いつ読むか |
|---|---|
| [`development-rules.md`](development-rules.md) | **コードを書く前に必ず**。落とし穴と回避策の集大成 |
| [`shell-specification.md`](shell-specification.md) | 新規スクリプト追加時。コーディング規約・出力規約 |
| [`ops-scripts-structure.md`](ops-scripts-structure.md) | 配置に迷ったとき |
| [`tools/templates/README.md`](tools/templates/README.md) | 新規スクリプトのテンプレ手順 |
| [`deploy/SPEC.md`](deploy/SPEC.md) | 配備機能を触るとき |

---

## 絶対に守るべき規約

### エンコーディング・改行

- **PowerShell (.ps1 / .psm1) は UTF-8 BOM 付き**で保存（PS5.1 + CP932 環境の文字化け回避）
- **Bash (.sh) は UTF-8 BOM なし + LF**（BOM があるとシバンが壊れる）
- **.bat は CRLF**（cmd.exe の前提）
- 共有設定ファイル（.conf / .yml / .json 等）は **LF 統一**
- `.gitattributes` がこれを強制しているので逆らわないこと

### Bash

```bash
#!/usr/bin/env bash       # 必須シバン
set -euo pipefail          # 必須
```

- 変数初期化を忘れない（`set -u` 下で死ぬ）
- `read -d ''` は NUL 区切り。複数行を配列化するなら `mapfile -t`
- `set -e` 下で `python3 ... ; if [[ $? -eq 0 ]]` は無意味 → `if python3 ...; then` を使う
- `OPTIND` は関数の最初で `OPTIND=1` リセット
- **Shift-JIS LF-eating バグ**: 日本語コメント直後の行が消えることがあるため、英語コメントを推奨。日本語を書く場合は LF を死守

### PowerShell

```powershell
#Requires -Version 5.1     # 必須。PS7 専用機能は使わない
[CmdletBinding()]
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
```

- **PS5.1 互換が必須**。以下は使えない:
  - `??` (null-coalescing) / `?:` (ternary) / `?.` (null-conditional)
  - `utf8NoBOM` エンコーディング名（`UTF8Encoding($false)` を使う）
  - `Get-Content -AsHashtable`
- 自動変数を上書きしない（`$args`, `$pid`, `$host`, `$input` 等）
- `Start-Job` は親プロセス終了で死ぬ → 独立プロセスは `Start-Process` を使う
- BOM 必須（前述）
- 子プロセス `powershell.exe` を起動するときは `-NoProfile` を付ける
- `(Get-Content file).Count` は 1 行ファイルで文字数を返す → `@(Get-Content file).Count`

### バッチファイル (.bat)

- `%~1:~0,1%` のように `%~1` を直接 substring できない。一旦変数化 (`set "ARG=%~1"`) してから `%ARG:~0,1%`
- 引数を遅延展開する場合は `setlocal enabledelayedexpansion` と `!VAR!`
- 文字化け回避のため英語コメント推奨

### Windows セキュリティ制限環境

GPO / AppLocker で以下がブロックされることがある。代替手段:

| 制限されることがある | 代替手段 |
|---|---|
| `Get-Counter` | `Win32_PerfFormattedData_*` / `Win32_PerfRawData_*` CIM |
| `Get-Process` | `Win32_Process` CIM |
| `Stop-Process` | `taskkill.exe` |
| `python3` | PowerShell ネイティブ実装をフォールバックとして用意 |

`tools/perf-monitor/PerfMonitor.ps1` がこのパターンの参考実装。

### tools/ ディレクトリ規約（運用補助ツール）

#### ツール一覧と役割

| ツール | 用途 | 参考 |
|---|---|---|
| `perf-monitor` | 負荷テスト中のリソース定期収集 + HTML レポート | サブコマンドの参照実装 |
| `network-check` | DNS/Ping/TCP 疎通チェック + targets-editor.xlsm | 対象リスト形式の参照実装 |
| `server-snapshot` | サーバ情報スナップショットの収集・比較 | 統合ツールの参照実装 |
| `cert-check` | TLS 証明書有効期限チェック | 単機能ツールの参照実装 |
| `port-inventory` | 待受ポート棚卸し・期待値監査 | 判定ロジックの参照実装 |
| `log-collector` | 障害時の証跡（ログファイル）収集 → ZIP | conf 設計の参照実装 |
| `aws-instance-audit` | AWS EC2 インスタンス棚卸し | — |

#### ファイル構成の必須パターン

すべてのツールは以下の **3 プラットフォーム + ドキュメント** 構成に従う:

```
tools/<tool-name>/
├── <ToolName>.ps1           # Windows 本体（UTF-8 BOM 付き）
├── <tool_name>.sh           # Linux 本体（UTF-8 BOM なし + LF）
├── <tool_name>.bat          # Windows 起動用バッチ（CRLF）
├── <config_or_list_file>    # 設定ファイルまたは対象リスト（LF）
└── README.md                # ツール固有の説明
```

**命名規則:**
- PS1: `PascalCase`（例: `CertCheck.ps1`）
- sh / bat: `snake_case`（例: `cert_check.sh`, `cert_check.bat`）
- ディレクトリ: `kebab-case`（例: `cert-check/`）

#### 自己完結ルール

- ツールは **`scripts_*/lib/` に依存してはならない**。フォルダ一式コピーで動くこと
- 共通比較エンジン等の Python スクリプトは **同梱コピー** とする
- python3 が制限される環境では PS ネイティブ / Bash ネイティブのフォールバックを用意

#### サブコマンドパターン

複数機能を持つツールは PerfMonitor.ps1 パターンに従う:

```powershell
# PowerShell: ValidateSet でサブコマンド定義
param(
    [Parameter(Position = 0)]
    [ValidateSet('collect','before','after','compare','list')]
    [string]$Command = 'collect'
)
switch ($Command) { ... }
```

```bash
# Bash: case 文でディスパッチ
command="${1:-}"
case "$command" in
    collect) shift; do_collect "$@" ;;
    compare) shift; do_compare "$@" ;;
    *) usage; exit 1 ;;
esac
```

```batch
:: bat: goto :cmd_* ラベルでルーティング
if /i "%CMD%"=="collect" goto :cmd_collect
if /i "%CMD%"=="compare" goto :cmd_compare
```

#### 対象リスト（.lst）形式

`network-check/targets.lst` と同じ思想で CSV 形式:

```
# コメント行（# で始まる）
# セクション区切り: # ---- Section Name ----
<field1>, <field2>, <field3>, <description>
```

- 各ツールのリスト形式:
  - `cert_targets.lst`: `<host>, <port>, <warn_days>, <description>`
  - `expected_ports.lst`: `<port>, <proto>, <expected>, <description>`
  - `targets.lst`: `<host>, <port>, <expected>, <description>`

#### 設定ファイル（.conf）形式

INI ライクなプリセット定義（log-collector パターン）:

```ini
[preset_name]
path = /path/to/glob/*.log
max_file_size_mb = 100
```

#### 出力モード

すべてのツールで以下の 3 出力モードをサポートする:

| モード | PS フラグ | Bash フラグ | 説明 |
|---|---|---|---|
| コンソールテーブル | （既定） | （既定） | `printf` / `Format-Table` で整形 |
| JSON | `-Json` | `--json` | 構造化出力。`ConvertTo-Json -Depth 3` |
| HTML レポート | `-HtmlReport <path>` | `--html <path>` | 自己完結 HTML + 埋め込み CSS |
| フィルタ | `-FailOnly` | `--fail-only` | NG/WARN のみ表示 |

#### 判定ロジックの共通パターン

対象リストの `expected` フィールドで判定を制御:

| expected | 実際の状態 | 判定 |
|---|---|---|
| `ok` | 期待どおり | OK |
| `ok` | 期待と異なる | **NG** |
| `ng` | 期待どおり（存在しない） | OK |
| `ng` | 期待と異なる（存在する） | **NG** |
| `-` | — | INFO（判定なし） |
| （リスト外） | 検出された | **WARN**（unexpected） |

#### 新規ツール追加時のチェックリスト

1. `tools/<tool-name>/` ディレクトリを作成
2. PS1 + sh + bat の 3 ファイルを作成（命名規則に従う）
3. 設定/対象リストファイルをサンプル付きで作成
4. `tests/bats/<tool_name>.bats` テストを作成
5. `tools/<tool-name>/README.md` を作成
6. `CHANGELOG.md` の `[Unreleased]` に追加
7. エンコーディング検証: PS1 に BOM あり、sh に BOM なし + LF
8. `ci/template-check` を通す

### lib と config の解決メカニズム

各制御スクリプトは **`SCRIPT_DIR` から親方向に上り歩き** して `lib/` と `config/` を探します。

```
lib 解決:
  1. $OPS_LIB (環境変数)      ← 明示オーバーライド
  2. <親>/lib/logging.sh        ← フラットレイアウト (deploy 後)
  3. <親>/lib/<os>/logging.sh   ← OS-split レイアウト
  4. .ops-deploy-root マーカーで打ち切る（外部 lib への漏れ防止）

config 解決:
  1. $OPS_CONFIG_DIR (環境変数) ← 明示オーバーライド
  2. <root>/config/<env>/<name>.conf
  3. <root>/config/<name>.conf  ← deploy 後のフラット構造
  4. <root> は .ops-deploy-root / .git / shell-specification.md で検出
```

deploy 時に `<install-root>/.ops-deploy-root` が自動で作成されます。配備先サーバ上では
これがあるおかげで「親方向に `/` まで遡って別プロジェクトの lib を拾う」事故を防げます。

### 設定の優先順位

すべての制御スクリプトで以下を厳守:

```
1. CLI 引数
2. config/<env>/<name>.conf      ┐ env 指定時のみ
3. config/<env>/global.conf      ┘
4. config/default/<name>.conf    ┐ env 未指定時のみ
5. config/default/global.conf    ┘
6. スクリプトのハードコード既定値
```

env は環境変数 `OPS_ENV` で切り替え。default と env の上書きマージは行わない。

### 終了コード規約

| Code | 意味 |
|---|---|
| 0  | 成功（または skipped） |
| 1  | 引数不正・usage |
| 2  | 業務エラー（リソース不在等） |
| 3  | 待機タイムアウト |
| 4  | 制御失敗（systemctl/Service 異常） |
| 10 | 前提コマンド不足（systemctl / aws CLI / python3 等） |
| 20 | 一時障害（外部 API 失敗、リトライ可能） |

### ロギング

- 共通 lib を必ず通す: `scripts_linux/lib/logging.sh` / `scripts_windows/lib/Logging.psm1`
- 関数: `log_debug/info/warn/error` または `Write-OpsLog -Level INFO`
- 出力フォーマット: `[YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message`
- タイムスタンプは **JST 固定**（`TZ=Asia/Tokyo`）
- 構造化情報は `key=value` をスペース区切りでメッセージに埋め込む（独自フィールド引数は使わない）
- 1 イベント = 1 行（改行を含むメッセージは空白に置換）
- ファイル出力は `.conf` の `LogFile` / `LogLevel` キーで制御（PS / Bash 両対応）

### 5-phase 構造（テンプレ準拠）

```
Phase 1: シバン / ヘッダコメント（用途・引数・終了コード）
Phase 2: 引数 + 設定読み込み (lib 経由)
Phase 3: 事前検査（引数バリデーション、前提コマンド存在確認）
Phase 4: 本処理（冪等に。既に目的状態ならスキップ）
Phase 5: 後始末 + 結果出力（trap / finally で構造化ログ）
```

---

## よく使うコマンド

```bash
# テンプレ準拠チェック (CI と同じ検査)
bash ci/template-check/check_template.sh

# ローカル単体テスト（モック使用、bats / Pester 必要）
bash  tests/run_unit.sh
pwsh  tests/run_unit.ps1
# 単体 + 結合（rotate_log の tmpdir、perf-monitor 短時間 start/stop など）
bash  tests/run_all.sh
pwsh  tests/run_all.ps1
# カバレッジ（要 kcov / Pester built-in）
bash  tests/run_unit.sh --coverage
pwsh  tests/run_unit.ps1 -Coverage

# Docker でユニットテスト
bash tests/docker/run_tests.sh        # Linux 側
pwsh -File tests/docker/run_tests.ps1 # Windows 側

# 配備同期 (dry-run)
DRY_RUN=true python deploy/sync.py
```

詳細は [`tests/README.md`](tests/README.md)。

```powershell
# perf-monitor 操作（負荷テスト時のリソース監視）
.\tools\perf-monitor\perf_monitor.bat start -Interval 5
.\tools\perf-monitor\perf_monitor.bat status
.\tools\perf-monitor\perf_monitor.bat stop
.\tools\perf-monitor\perf_monitor.bat report <session_dir>

# 疎通チェック
.\tools\network-check\Check-NetworkConnectivity.bat -TargetList targets.lst

# サーバ情報スナップショット
.\tools\server-snapshot\server_snapshot.bat collect
.\tools\server-snapshot\server_snapshot.bat before -Label deploy-v1
.\tools\server-snapshot\server_snapshot.bat after  -Label deploy-v1 -HtmlReport report.html
.\tools\server-snapshot\server_snapshot.bat compare before.json after.json
.\tools\server-snapshot\server_snapshot.bat list

# TLS 証明書期限チェック
.\tools\cert-check\cert_check.bat -TargetList cert_targets.lst
.\tools\cert-check\cert_check.bat -TargetList cert_targets.lst -HtmlReport report.html
.\tools\cert-check\cert_check.bat -TargetList cert_targets.lst -Json

# 待受ポート棚卸し
.\tools\port-inventory\port_inventory.bat                                          # 一覧のみ
.\tools\port-inventory\port_inventory.bat -ExpectedList expected_ports.lst          # 期待値監査
.\tools\port-inventory\port_inventory.bat -ExpectedList expected_ports.lst -Json

# 障害時の証跡収集
.\tools\log-collector\log_collector.bat -Target tomcat,os
.\tools\log-collector\log_collector.bat -Target nginx -Since 48h
.\tools\log-collector\log_collector.bat -Target tomcat -From "2026-06-01 00:00" -To "2026-06-02 00:00"
```

---

## 「やってはいけない」リスト

- 共通処理を各スクリプトに直接書く → `lib/` に集約
- シークレットを `config/` の YAML に直書き → Vault 参照のみ（`config/<env>/secrets.ref.yml`）
- `tools/*/` から `scripts_*/lib/` に依存 → ツールは **自己完結**であるべき
- 配備先リポジトリで手修正 → このテンプレ側に反映してから `sync.py` で配る
- 同じドメインで Linux / Windows のコマンド体系を変える → 1:1 対応を維持
- 新規 `.ps1` を BOM なしで保存（CI は通っても CP932 環境で文字化け）
- `Start-Job` で長時間プロセスを起動（親が消えると死ぬ）→ `Start-Process`
- 新規ツールで PS1 / sh / bat のどれかを省略 → 3 プラットフォーム必須
- 対象リストのパーサを各ツール独自に書く → CSV + `#` コメント + セクション区切りの共通形式に従う
- SAN 取得で `FriendlyName` を使う → 日本語 Windows で壊れる。`Oid.Value -eq '2.5.29.17'` を使う
- PS5.1 で `@($list)` の要素数を `.Count` で取る → 要素 1 つの場合ハッシュテーブルのキー数が返る。`, @($list)` でカンマ演算子を使う

---

## 利用可能なスラッシュコマンド

このプロジェクトには以下のカスタムコマンドが定義されています:

- `/template-check` — CI と同じテンプレ準拠検査をローカルで実行
- `/docker-test` — Docker テストスイートを起動（Linux / Windows 両方）
- `/run-tests` — bats + Pester のローカル単体/結合テストを実行
- `/encoding-audit` — `.ps1` の BOM 欠落と `.sh` の CRLF を検査
- `/new-controller` — 新規制御スクリプト（XXXCtl.ps1 / xxxctl.sh）の雛形を作成

`.claude/commands/` 配下で定義しています。

---

## 利用可能なサブエージェント

- `repo-reviewer` — リポジトリ全体のレビュー（軽微 / 設計判断に分類）
- `controller-builder` — 新規ミドル制御スクリプトを Tomcat 同等パターンで一式生成

`.claude/agents/` 配下で定義しています。

---

## 関連プロジェクトリンク

- リポジトリ: https://github.com/noritakekohji/ops-scripts-template
- 配備先候補は `deploy/servers.yaml`
