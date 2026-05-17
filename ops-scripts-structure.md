# 運用シェル ディレクトリ構成設計書

エンタープライズ向け（社内利用・セキュリティ重視・大規模サーバ群運用）の運用スクリプト群について、本リポジトリ `ops-scripts-template` の **実際のディレクトリ構成** と設計指針をまとめたドキュメントです。

PowerShell（Windows 系）と Bash（Linux 系）が混在し、AWS / OS / 各種ミドルウェア（PostgreSQL / MySQL / SAP HANA / S/4HANA / SQL Server / Tomcat）の運用を 1 つのテンプレートでカバーします。

---

## 1. 設計の基本方針

このリポジトリは、次の 4 つの分離を軸にしています。

| 分離の軸 | 何を分けるか | なぜ分けるか |
|---|---|---|
| **コード / 設定 / シークレット** | スクリプト本体、環境別パラメータ、秘密情報 | コードを変えずに環境を切り替える。秘密情報を Git に混入させない |
| **OS / ミドルウェア** | Windows (PowerShell) と Linux (Bash) の実装、AWS や各 DB 等のドメイン | 担当者の役割（DBA、AP サーバ担当）に沿わせ、Runbook を集約しやすくする |
| **本体スクリプト / 運用ツール** | 1 つのリソースを操作する制御スクリプトと、汎用補助ツール | 単機能はテスト・再利用しやすく、汎用ツールは横串で全環境に再利用できる |
| **テンプレ / 配備物** | テンプレ本体と、配備先で実際に動くスクリプト | テンプレを介して別リポジトリへ同期配備し、配備先の差分を見える化する |

### OS-first を採用している理由

ミドルウェア優先（`scripts/<middleware>/<lang>/`）も有力な選択肢でしたが、以下の理由で **OS-first（`scripts_linux/<domain>/` と `scripts_windows/<domain>/`）** を採用しています。

- **担当の現実に沿う**: 多くの組織で「Windows サーバ担当」「Linux サーバ担当」が縦割りで、レビュアーも OS 単位で分かれます。
- **PowerShell / Bash の lint / テスト系統が OS で分かれる**: PSScriptAnalyzer / Pester は Windows runner、ShellCheck / bats は Linux runner と物理的に分断され、CI の include / runner タグも OS 単位で整理する方が直感的です。
- **配備先の OS が明確**: 配備先サーバは大抵 OS が単一で、`scripts_linux/` 一式をそのまま `/opt/ops-scripts/` へ撒けるなど、配備が単純です。
- **同名スクリプトを Linux / Windows で対比しやすい**: `postgresqlctl.sh` ↔ `PostgreSQLCtl.ps1` のように、対応関係がディレクトリの並びだけで読み取れます。

### セキュリティの統制ポイント

- **シークレットはリポジトリに置かない**: 参照キーのみを `config/` に置き、実値は Vault / Azure Key Vault / CyberArk から共通ライブラリ経由で取得する。
- **共通ライブラリでガードレールを作る**: ロギング・設定取得・エラー処理を `scripts_linux/lib/` と `scripts_windows/lib/` に集約し、すべての制御スクリプトがこれを通る。これにより「誰が・いつ・どこで・何をしたか」が SIEM に必ず記録される。
- **CI で必須チェック**: lint（PSScriptAnalyzer / ShellCheck / sqlfluff / yamllint）、シークレットスキャン（gitleaks）、依存脆弱性（Trivy）、テンプレ準拠（template-check）、ユニットテスト（Pester / bats）を MR 必須にする。

---

## 2. ディレクトリ構成（全体像）

```
ops-scripts-template/
├── README.md
├── install.md / install.bat / install.sh
├── shell-specification.md         # シェル/PS のコーディング規約・出力規約
├── development-rules.md           # 開発時の落とし穴と回避策（事実上のチェックリスト）
├── ops-scripts-structure.md       # 本ドキュメント
│
├── config/                        # 環境別設定（コードと完全分離）
│   ├── default/                   # 全環境共通の既定値（OPS_ENV 未設定時もここを読む）
│   ├── dev/
│   ├── staging/
│   └── production/
│
├── scripts_linux/                 # Bash 実装（OS-first）
│   ├── lib/                       # config.sh / logging.sh（必須経路）
│   ├── aws/                       # backup_ami / backup_ebs_snapshot / ec2ctl / s3upload
│   ├── hana/                      # hanactl
│   ├── mysql/                     # mysqlctl
│   ├── os/                        # deploy_scripts / get_server_info / rotate_log
│   ├── postgresql/                # postgresqlctl
│   ├── sap/                       # sapctl
│   ├── sqlserver/                 # sqlserverctl
│   └── tomcat/                    # tomcatctl
│
├── scripts_windows/               # PowerShell 実装（OS-first）
│   ├── lib/                       # Config.psm1 / Logging.psm1（必須経路）
│   ├── aws/                       # Backup-Ami / Backup-EbsSnapshot / Ec2Ctl / S3Upload
│   ├── mysql/                     # MySQLCtl
│   ├── os/                        # Compare-ServerInfo / Deploy-Scripts / Get-ServerInfo / Rotate-Log
│   ├── postgresql/                # PostgreSQLCtl
│   ├── sap/                       # SAPCtl
│   ├── sqlserver/                 # SqlServerCtl
│   └── tomcat/                    # TomcatCtl
│
├── docs_linux/                    # Linux スクリプトの仕様書 (*.md)
├── docs_windows/                  # Windows スクリプトの仕様書 (*.md)
│
├── tools/                         # 運用補助ツール（OS 両対応のスタンドアロン）
│   ├── perf-monitor/              # 負荷テスト中のリソース監視＋HTML レポート
│   ├── network-check/             # DNS / Ping / TCP 疎通確認
│   ├── change-detect/             # サーバ情報の前後比較ワークフロー
│   ├── server-compare/            # サーバ情報収集と差分検出
│   └── templates/                 # 新規スクリプト用テンプレート（5-phase 構造）
│
├── deploy/                        # 別リポジトリへの自動同期
│   ├── servers.yaml               # コピー先リポジトリ一覧
│   ├── sync.py                    # MR 自動作成スクリプト
│   └── SPEC.md
│
├── tests/
│   ├── pester/                    # PowerShell ユニットテスト
│   ├── bats/                      # Bash ユニットテスト
│   └── docker/                    # Docker でのエンドツーエンドテスト
│
├── ci/                            # GitLab CI 定義
│   ├── lint/                      # psscriptanalyzer / shellcheck / sqlfluff / yamllint / template-check
│   ├── security/                  # gitleaks / Trivy
│   ├── test/                      # Pester / bats
│   ├── deploy/                    # 別リポジトリ自動同期
│   └── template-check/            # テンプレ準拠検査スクリプト
│
├── .gitlab-ci.yml                 # メインパイプライン（include で各モジュールを読む）
├── .gitleaks.toml / .yamllint / .sqlfluff / .gitignore / .gitattributes
└── presentations/                 # 紹介スライド (*.pptx) 等
```

---

## 3. 各ディレクトリの説明

### 3.1 `config/` — 環境別設定

**コードを変えずに環境を切り替える** ためのパラメータ置き場です。

```
config/
├── default/                       # 全環境共通の既定値（OPS_ENV 未設定時のみ参照 / 指定時は env で上書き）
│   ├── global.conf                # 全スクリプト共通設定（ログレベル等）
│   ├── postgresqlctl.conf
│   ├── tomcatctl.conf
│   └── ...                        # スクリプトごとの .conf
├── dev/
├── staging/
└── production/
```

**ルール**

- 実際のパスワードや API キーは絶対に書かない（Vault 参照のみ）。
- 各スクリプトは `lib/config.sh` (Bash) / `lib/Config.psm1` (PowerShell) 経由でロードする。
- 設定の優先順位: **CLI 引数 > 環境別 .conf > default/.conf > スクリプト内既定値**。

### 3.2 `scripts_linux/` / `scripts_windows/` — 制御スクリプト本体

**OS でディレクトリを分け、その下にドメイン別**（aws / postgresql / tomcat / os / ...）でファイルを置きます。同じドメイン名のディレクトリは Linux 側と Windows 側で対応し、同じコマンド体系・終了コード規約・引数命名でラップされます。

```
scripts_linux/postgresql/postgresqlctl.sh   ↔   scripts_windows/postgresql/PostgreSQLCtl.ps1
scripts_linux/tomcat/tomcatctl.sh          ↔   scripts_windows/tomcat/TomcatCtl.ps1
scripts_linux/os/rotate_log.sh             ↔   scripts_windows/os/Rotate-Log.ps1
```

#### ファイル命名規約

| 種別 | 形式 | 例 |
|---|---|---|
| PowerShell | `Verb-Noun.ps1`（[承認動詞](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)） | `Backup-Ami.ps1`、`Rotate-Log.ps1`、`PostgreSQLCtl.ps1` |
| Bash | `verb_noun.sh`（snake_case） | `backup_ami.sh`、`rotate_log.sh`、`postgresqlctl.sh` |
| T-SQL | `snake_case.sql` | `full_backup.sql` |

#### 共通の構造（5-phase）

すべての制御スクリプトは `tools/templates/` のテンプレに沿って **5 つのフェーズ** で書きます。詳細は `shell-specification.md` を参照。

1. **シバン / ヘッダコメント**: 用途・引数・終了コード規約を必ず記載
2. **引数 / 設定読み込み**: `lib/config.sh` / `lib/Config.psm1` 経由
3. **事前検査**: 引数バリデーション、前提コマンド存在確認
4. **本処理**: 冪等に実装（既に目的状態ならスキップ）
5. **後始末 / 結果出力**: 構造化ログ + 規約に従った終了コード

### 3.3 `scripts_*/lib/` — 共通ライブラリ

**セキュリティ統制とコード再利用の中核**。すべての制御スクリプトはここを経由してログ・設定を扱います。

```
scripts_linux/lib/
├── logging.sh                     # JST 固定タイムスタンプ + key=value 構造化ログ
└── config.sh                      # 環境別 .conf 読み込み + 検証

scripts_windows/lib/
├── Logging.psm1                   # 同上（PS5.1 互換）
└── Config.psm1                    # 同上
```

ロギング API（`log_info` / `Write-OpsLog`）と設定 API（`load_ops_config` / `Get-OpsConfig`）は Linux / Windows で **同等の意味論** を持ち、ログ書式・JST タイムスタンプ・優先順位（CLI > config > default）が揃っています。

### 3.4 `docs_linux/` / `docs_windows/` — スクリプト仕様書

各スクリプトについて、用途・前提・引数・終了コード・実行例を Markdown で記述します。OS ごとに分け、対応するスクリプトと 1:1 で対応させます。

### 3.5 `tools/` — 運用補助ツール

各サーバへ単体配布して使う **スタンドアロンの運用補助ツール** を集めています。`scripts_*/lib/` には依存せず、自己完結します。

| ツール | 説明 |
|---|---|
| `perf-monitor/`    | 負荷テスト中のリソース監視＋HTML レポート |
| `network-check/`   | DNS / Ping / TCP 疎通チェック |
| `change-detect/`   | サーバ情報の現新差分検出ワークフロー |
| `server-compare/`  | サーバ情報収集と差分検出 |
| `templates/`       | 新規スクリプト雛形（5-phase 構造の動くデモ） |

各ツールは `.ps1` + `.bat`（Windows）と `.sh`（Linux）を同梱し、`README.md` を持ちます。

### 3.6 `deploy/` — 別リポジトリへの自動同期

```
deploy/
├── servers.yaml                   # 配備先リポジトリ一覧
├── sync.py                        # GitLab API 経由で MR を作成
└── SPEC.md                        # 同期仕様書
```

詳細は `deploy/SPEC.md`、CI 連携は `ci/deploy/sync.gitlab-ci.yml`。

### 3.7 `tests/` — 自動テスト

```
tests/
├── pester/                        # PowerShell ユニットテスト（Pester）
├── bats/                          # Bash ユニットテスト（bats-core）
└── docker/                        # Docker コンテナで実環境テスト
    ├── Dockerfile.linux
    ├── Dockerfile.powershell
    ├── linux_tests.sh
    ├── powershell_tests.ps1
    └── run_tests.{ps1,sh}
```

**何をテストするか**

- 引数バリデーションと終了コードの規約遵守
- 冪等性（再実行で副作用が増えない）
- 構造化ログが規約どおりに出力されるか
- 設定優先順位（CLI > config > default）が正しく働くか

### 3.8 `ci/` — GitLab CI 定義

| ステージ | ジョブ | 内容 |
|---|---|---|
| lint | psscriptanalyzer | PowerShell の規約・潜在バグ |
| lint | shellcheck | Bash の規約・潜在バグ |
| lint | sqlfluff | SQL の整形・規約 |
| lint | yamllint | YAML 構文 |
| lint | template-check | テンプレ準拠検査（`#Requires -Version 5.1` 等） |
| security | gitleaks | シークレット混入 |
| security | trivy-fs | 依存脆弱性 |
| test | pester | PS ユニットテスト |
| test | bats | Bash ユニットテスト |
| deploy | sync | 別リポジトリへの自動同期 |

---

## 4. 命名と配置のクイックリファレンス

```
そのスクリプトは何を操作する？
│
├─ ミドルウェア（Tomcat / SQL Server / PostgreSQL / MySQL / HANA / SAP 等）
│   └─ scripts_{linux,windows}/<middleware>/<file>
│       例: scripts_linux/postgresql/postgresqlctl.sh
│           scripts_windows/postgresql/PostgreSQLCtl.ps1
│
├─ クラウド（AWS）
│   └─ scripts_{linux,windows}/aws/<file>
│       例: scripts_linux/aws/backup_ami.sh
│           scripts_windows/aws/Backup-Ami.ps1
│
├─ OS 共通（ログローテ・情報収集等）
│   └─ scripts_{linux,windows}/os/<file>
│       例: scripts_linux/os/rotate_log.sh
│           scripts_windows/os/Rotate-Log.ps1
│
└─ スタンドアロンの運用補助ツール
    └─ tools/<tool-name>/
        例: tools/perf-monitor/, tools/network-check/
```

**アクションはディレクトリではなくファイル名で表現する**（`Backup-Ami.ps1` の `Backup-`、`rotate_log.sh` の `rotate_` 等）。

---

## 5. セキュリティ・運用上のチェックリスト

### コード側

- [ ] スクリプトは必ず `lib/` の Logging / Config を経由する
- [ ] 引数検証（ホワイトリスト方式）を冒頭で実施する
- [ ] 終了コードを規約に従って返す（0 成功 / 1 引数エラー / 2 業務エラー / 10 前提不足 / 20 一時障害）
- [ ] 冪等性を確保する（再実行で副作用が増えない）
- [ ] PowerShell は `#Requires -Version 5.1` と `[CmdletBinding()]` を必須に
- [ ] Bash は `set -euo pipefail` を必須に
- [ ] PowerShell スクリプトは UTF-8 BOM 付きで保存（PS5.1 + CP932 環境の文字化け回避）

### リポジトリ運用

- [ ] `config/<env>/secrets.ref.yml` 以外にシークレット参照を書かない
- [ ] 本番設定の変更は別ブランチ＋承認者レビュー必須
- [ ] CI の lint / シークレットスキャン / テスト / template-check をすべてグリーンに
- [ ] リリースタグに署名する（改ざん検知）

### 実行環境

- [ ] スクリプト実行アカウントは最小権限
- [ ] 本番実行は踏み台サーバ経由のみ許可
- [ ] 監査ログは中央 SIEM に集約し、改ざん不可の領域に保存

---

## 6. 拡張時の指針

| やりたいこと | やるべきこと |
|---|---|
| 新しいミドルを追加 | `scripts_linux/<mw>/` と `scripts_windows/<mw>/` を作成し、テンプレ (`tools/templates/`) からコピーして編集 |
| 既存ミドルに新しい操作を追加 | 該当 `scripts_<os>/<mw>/` 配下に新ファイルを追加 |
| 新しい運用補助ツールを追加 | `tools/<name>/` を作成（`.ps1` + `.bat` + `.sh` + `README.md`） |
| 新しい環境（例：QA）を追加 | `config/qa/` を追加し、各 `.conf` を必要分だけ用意 |
| 配備先を増やす | `deploy/servers.yaml` に 1 エントリ追加するだけ |

**してはいけないこと**

- 共通処理を各スクリプトに直接書く（→ `lib/` に集約する）
- シークレットを `config/` の YAML に直接書く（→ Vault 参照にする）
- `tools/*/` から `scripts_*/lib/` に依存する（→ ツールは自己完結であるべき）
- 配備先のリポジトリで手修正する（→ テンプレ側に反映してから sync で配る）

---

## 付録：最小構成の起点

ゼロから立ち上げる際の最小セットです。

```
ops-scripts-template/
├── README.md
├── shell-specification.md
├── development-rules.md
├── scripts_linux/lib/{config.sh,logging.sh}
├── scripts_windows/lib/{Config.psm1,Logging.psm1}
├── tools/templates/{Template-Script.ps1,template_script.sh,README.md}
└── ci/{lint,security,test,template-check}/
```

この **「共通ライブラリ + テンプレート + lint + テスト枠」** を最初に固めれば、その後追加されるスクリプトは自然と品質が揃います。順序を逆にして個別スクリプトから書き始めると、後からのガバナンス導入が極めて困難になるので注意してください。
