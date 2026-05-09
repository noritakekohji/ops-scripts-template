# 大規模サーバ運用シェル ディレクトリ構成設計書

エンタープライズ向け（社内利用・セキュリティ重視・大規模サーバ群運用）の運用シェルスクリプト群について、ディレクトリ構成と設計指針をまとめたドキュメントです。

PowerShell（Windows 系）と Bash（Linux 系）が混在し、Tomcat / SQL Server のように **同じミドルウェアが複数 OS で動く** ケースを前提としています。

---

## 1. 設計の基本方針

このディレクトリ構成は、次の 4 つの分離を軸にしています。

| 分離の軸 | 何を分けるか | なぜ分けるか |
|---|---|---|
| **コード / 設定 / シークレット** | スクリプト本体、環境別パラメータ、秘密情報 | コードを変えずに環境を切り替えるため。秘密情報を Git に混入させないため |
| **ミドルウェア / OS** | Tomcat や SQL Server の運用 と、AD や systemd のような OS 固有運用 | 担当者の役割（DBA、AP サーバ担当）に沿わせ、Runbook を集約しやすくするため |
| **単機能スクリプト / 業務手順（Playbook）** | 1 つの操作 と、複数操作を束ねた業務フロー | 単機能はテスト・再利用しやすく、業務フローは「やりたいこと」で表現できるようにするため |
| **インベントリ / コード** | サーバ一覧と、それを操作するスクリプト | サーバ追加・移設をコード変更なしで行うため |

### セキュリティの統制ポイント

- **シークレットはリポジトリに置かない**：参照キーのみを `config/` に置き、実値は Vault / Azure Key Vault / CyberArk から共通ライブラリ経由で取得する。
- **共通ライブラリでガードレールを作る**：ロギング・監査・シークレット取得・エラー処理を `lib/` に集約し、すべてのスクリプトがこれを通る。これにより「誰が・いつ・どこで・何をしたか」が SIEM に必ず記録される。
- **CI で必須チェック**：lint（PSScriptAnalyzer / ShellCheck）、シークレットスキャン（gitleaks）、テスト（Pester / bats）をプルリク必須に。

---

## 2. ディレクトリ構成（全体像）

```
ops-scripts/
├── README.md
├── CHANGELOG.md
├── .gitignore
├── .editorconfig
│
├── docs/                          # ドキュメント
│   ├── runbooks/                  # 運用手順書・インシデント対応
│   ├── architecture/              # 構成図・設計判断の記録
│   ├── security/                  # セキュリティポリシー、権限設計、監査要件
│   └── onboarding.md              # 新規担当者向け
│
├── config/                        # 環境別設定（コードと完全分離）
│   ├── common/                    # 全環境共通のパラメータ
│   ├── dev/
│   ├── stg/
│   └── prd/
│       └── secrets.ref.yml        # Vault 等への「参照」のみ。実値は置かない
│
├── inventory/                     # サーバ一覧
│   ├── windows/
│   ├── sqlserver/
│   ├── tomcat/
│   ├── linux/
│   └── groups.yml                 # 役割・拠点・環境でグルーピング
│
├── scripts/                       # 実スクリプト本体
│   ├── tomcat/                    # ミドルウェア（OS 横断）
│   │   ├── common/                # OS 非依存の資産
│   │   ├── windows/               # PowerShell 実装
│   │   └── linux/                 # Bash 実装
│   │
│   ├── sqlserver/
│   │   ├── common/                # T-SQL（.sql）はここに集約
│   │   ├── windows/
│   │   └── linux/
│   │
│   ├── windows/                   # OS 固有のみ（AD、IIS、イベントログ 等）
│   ├── linux/                     # OS 固有のみ（systemd、cron 等）
│   │
│   └── common/                    # ミドル横断の汎用処理（通知、監査送信 等）
│
├── lib/                           # 共通ライブラリ（再利用と統制の要）
│   ├── powershell/
│   ├── bash/
│   └── sql/
│
├── playbooks/                     # 業務手順（複数スクリプトを束ねる）
│   ├── monthly-patching/
│   ├── dr-failover/
│   ├── tomcat-blue-green/
│   └── new-server-provisioning/
│
├── tests/                         # 自動テスト
│   ├── pester/                    # PowerShell 用
│   ├── bats/                      # Bash 用
│   └── fixtures/
│
├── ci/                            # CI/CD パイプライン定義
│   ├── lint/                      # PSScriptAnalyzer / ShellCheck / sqlfluff
│   ├── security-scan/             # gitleaks / Trivy / Semgrep
│   └── pipelines/                 # GitHub Actions / Azure Pipelines 等
│
└── tools/                         # 開発支援ツール
    ├── bootstrap.ps1              # 開発環境セットアップ
    ├── new-script.ps1             # スクリプトのスケルトン生成
    └── pre-commit/                # コミット前フック（lint + secret scan）
```

---

## 3. 各ディレクトリの説明

### 3.1 `docs/` — ドキュメント

運用に必要な「人間向け情報」を置きます。

| サブディレクトリ | 内容 | 例 |
|---|---|---|
| `runbooks/` | 障害対応・定例作業の手順書 | 「Tomcat が応答しないときの対処」 |
| `architecture/` | システム構成図、設計判断の根拠 | 「なぜ AlwaysOn AG を採用したか」 |
| `security/` | 権限設計、監査要件、ポリシー | 「本番作業時の承認フロー」 |
| `onboarding.md` | 新規担当者の立ち上げ手順 | 環境構築、権限申請の流れ |

> **ポイント**：スクリプトを読まなくても**「何をするためのものか」が分かる入口**になります。

---

### 3.2 `config/` — 環境別設定

**コードを変えずに環境を切り替える** ためのパラメータ置き場です。

```
config/
├── common/              # 全環境共通（タイムアウト値、ログレベル既定 等）
├── dev/
├── stg/
└── prd/
    ├── tomcat.yml       # 本番 Tomcat の接続先・JVM パラメータ等
    ├── sqlserver.yml
    └── secrets.ref.yml  # 例：sqlserver_password: ref://vault/prd/sqlserver
```

**ルール**

- 実際のパスワードや API キーは絶対に書かない。
- 書いてよいのは「Vault 内のどこに格納されているか」という参照キーだけ。
- 環境ファイルの差分が、そのまま「環境間の差」として可視化される。

---

### 3.3 `inventory/` — サーバ一覧

「どのサーバが、どの役割で、どの環境にいるか」をデータとして持ちます。Ansible のインベントリ形式に近い思想です。

```yaml
# inventory/groups.yml の例
tomcat_prod:
  hosts: [tomcat01, tomcat02, tomcat03]

sqlserver_prod:
  hosts: [sqldb01, sqldb02]

# ホスト個別の属性
tomcat01: { os: windows, dc: tokyo }
tomcat02: { os: linux,   dc: tokyo }
tomcat03: { os: linux,   dc: osaka }
```

**ポイント**

- サーバ追加 = YAML への 1 行追記。スクリプト改修は不要。
- `os` 属性で **PowerShell 版 / Bash 版を Playbook が自動で振り分け** られるようになる（後述）。

---

### 3.4 `scripts/` — スクリプト本体

最重要ディレクトリ。**「ミドルウェア優先 + OS サブディレクトリ」** のルールで配置します。

#### なぜミドルウェア優先か

運用担当は通常、**OS ではなくミドル単位で分業** されています（DBA、AP サーバ担当、AD 担当 …）。OS で先に分けると同じ Tomcat の知識が `windows/tomcat/` と `linux/tomcat/` の 2 箇所に分散し、メンテが破綻します。

#### 構造のパターン

##### パターン A：クロスプラットフォームなミドル（Tomcat、SQL Server、Nginx 等）

```
scripts/tomcat/
├── common/                        # OS 非依存の資産
│   ├── server.xml.template        # 設定テンプレート
│   └── healthcheck-logic.md       # 検証手順の真の定義
├── windows/                       # PowerShell 実装
│   ├── deploy/
│   │   └── Deploy-War.ps1
│   ├── lifecycle/
│   │   ├── Start-Tomcat.ps1
│   │   └── Stop-Tomcat.ps1
│   └── threaddump/
│       └── Get-ThreadDump.ps1
└── linux/                         # Bash 実装
    ├── deploy/
    │   └── deploy_war.sh
    ├── lifecycle/
    │   ├── start_tomcat.sh
    │   └── stop_tomcat.sh
    └── threaddump/
        └── get_thread_dump.sh
```

`common/` に **OS 非依存の真の手順** を置くのがコツです。

- SQL Server の `.sql` ファイル（T-SQL）は OS に依存しないので `sqlserver/common/` に集約し、Windows / Linux のラッパは中身を呼び出すだけにする。
- Tomcat の `server.xml` テンプレや JVM 引数表も `tomcat/common/` に置けば、PowerShell と Bash の二重管理を避けられる。

##### パターン B：OS 固有の運用（AD、systemd 等）

ミドル名で括れないもの（その OS にしか存在しない概念）は `scripts/windows/` または `scripts/linux/` 直下に置きます。

```
scripts/windows/
├── ad/                            # Active Directory
├── iis/                           # IIS
├── eventlog/                      # Windows イベントログ
└── patch/                         # WSUS / Windows Update

scripts/linux/
├── systemd/                       # サービス管理
├── cron/
└── patch/                         # yum / apt
```

##### パターン C：ミドル横断の汎用処理

通知や監査送信のように、すべてのスクリプトから呼ばれる横串の処理は `scripts/common/` に置きます。

```
scripts/common/
├── notify/                        # Slack / Teams / メール通知
├── audit/                         # 操作ログを SIEM へ送信
└── healthcheck/                   # 横串ヘルスチェック
```

#### ファイル命名規約

各 OS の慣習に揃えます。OS はディレクトリ構造ですでに分かっているので、ファイル名に `_win` のような接尾辞は不要です。

| OS | 形式 | 例 |
|---|---|---|
| PowerShell | `Verb-Noun.ps1`（PascalCase + ハイフン） | `Deploy-War.ps1`、`Invoke-FullBackup.ps1` |
| Bash | `verb_noun.sh`（snake_case） | `deploy_war.sh`、`invoke_full_backup.sh` |
| T-SQL | `snake_case.sql` | `full_backup.sql`、`reindex.sql` |

---

### 3.5 `lib/` — 共通ライブラリ

**セキュリティ統制とコード再利用の中核** です。すべてのスクリプトはここを経由してログ・監査・シークレットを扱います。

```
lib/
├── powershell/
│   ├── Logging.psm1               # 構造化ログ（JSON 形式）
│   ├── Secrets.psm1               # Key Vault / CyberArk から取得
│   ├── Audit.psm1                 # who / what / when / from を記録
│   ├── ErrorHandling.psm1         # 例外と終了コードの規約
│   └── Validation.psm1            # 入力検証、ホワイトリスト
├── bash/
│   ├── logging.sh
│   ├── secrets.sh                 # Vault CLI ラッパ
│   ├── audit.sh
│   ├── retry.sh                   # 冪等性とリトライ
│   └── safety.sh                  # set -euo pipefail 等を強制
└── sql/
    └── helpers/                   # 共通 T-SQL スニペット
```

**ポイント**

- スクリプトが `Get-Secret` を直接呼ぶのではなく、必ず `Secrets.psm1` 経由で取得 → 取得操作も自動で監査ログに残る。
- `Logging.psm1` に統一することで、ログのフォーマットが揃い、SIEM のパースが簡単になる。
- 「セキュリティ機能を毎回個別実装しない」＝**間違える余地を構造的に消す**。

---

### 3.6 `playbooks/` — 業務手順

「やりたいこと（業務要求）」を表現する高レベルなワークフロー。複数の単機能スクリプトを束ねます。

```
playbooks/
├── monthly-patching/              # 月次パッチ適用
│   ├── README.md                  # 手順の概要・前提・ロールバック方針
│   └── run.yml                    # 実行定義
├── dr-failover/                   # 災対切替
├── tomcat-blue-green/
└── new-server-provisioning/
```

**OS 差はここで吸収する**

```yaml
# playbooks/tomcat-rolling-restart/run.yml の例（イメージ）
target_group: tomcat_prod          # inventory のグループを指定
steps:
  - name: 停止
    action: tomcat/lifecycle/stop  # OS は inventory の os 属性で自動分岐
  - name: 起動
    action: tomcat/lifecycle/start
  - name: ヘルスチェック
    action: tomcat/healthcheck
```

業務担当は **OS の違いを意識せず**「Tomcat をローリング再起動する」と表現できます。

---

### 3.7 `tests/` — 自動テスト

```
tests/
├── pester/                        # PowerShell（Pester フレームワーク）
├── bats/                          # Bash（bats-core フレームワーク）
└── fixtures/                      # テスト用データ
```

**何をテストするか**

- スクリプトが想定どおりの引数検証を行うか。
- 異常系で正しい終了コードを返すか。
- 監査ログが正しく出力されるか。
- 冪等性（同じスクリプトを 2 回流しても安全か）。

---

### 3.8 `ci/` — CI/CD 定義

プルリクエスト時に走らせるチェックを定義します。

```
ci/
├── lint/
│   ├── psscriptanalyzer.json      # PowerShell の規約チェック
│   ├── shellcheck.config          # Bash の静的解析
│   └── sqlfluff.cfg               # SQL の整形・規約
├── security-scan/
│   ├── gitleaks.toml              # シークレット混入チェック
│   ├── trivy.yml                  # 依存ライブラリの脆弱性
│   └── semgrep.yml                # コード規約・脆弱性パターン
└── pipelines/
    ├── pr.yml                     # PR チェック
    └── release.yml                # リリース時の署名・配布
```

**必須化すべきチェック**

1. lint：書式・規約違反
2. シークレットスキャン：パスワードや API キーの混入
3. テスト：上記 `tests/` 配下を実行
4. 依存スキャン：使っているモジュール・パッケージの脆弱性

---

### 3.9 `tools/` — 開発支援ツール

```
tools/
├── bootstrap.ps1                  # 開発環境のセットアップ（モジュールインストール 等）
├── new-script.ps1                 # スクリプトのスケルトン自動生成
└── pre-commit/                    # コミット前フック
```

**`new-script.ps1` の役割**

新規スクリプトのテンプレート（ヘッダコメント、`lib/` の import、引数検証の雛形）を強制生成します。これにより、

- 用途・所有者・対象環境・冪等性の有無 がヘッダに必ず書かれる
- 共通ライブラリの読み込みを忘れない
- 命名規約から逸脱しない

という品質が、**人間の注意力に頼らず保たれます**。

---

## 4. 命名と配置のクイックリファレンス

迷ったときの判定フロー。

```
そのスクリプトは何を操作する？
│
├─ 特定のミドルウェア（Tomcat / SQL Server / Nginx / Redis 等）
│   └─ scripts/<middleware>/<os>/<action>/
│       例: scripts/tomcat/linux/deploy/deploy_war.sh
│
├─ OS にしか存在しない概念（AD / systemd / イベントログ 等）
│   └─ scripts/<os>/<action>/
│       例: scripts/windows/ad/Disable-User.ps1
│
├─ ミドル横断の汎用処理（通知 / 監査送信 等）
│   └─ scripts/common/<action>/
│       例: scripts/common/notify/Send-Slack.ps1
│
└─ 業務手順（複数スクリプトの組み合わせ）
    └─ playbooks/<業務名>/
        例: playbooks/monthly-patching/
```

---

## 5. セキュリティ・運用上のチェックリスト

このディレクトリ構成を活かすために、以下を運用ルールとして守ります。

### コード側

- [ ] スクリプトは必ず `lib/` の Logging / Audit / Secrets を経由する
- [ ] 引数検証（ホワイトリスト方式）を冒頭で実施する
- [ ] 終了コードを規約に従って返す（成功 0、業務エラー 1、システムエラー 2 等）
- [ ] 冪等性を確保する（再実行で副作用が増えない）
- [ ] PowerShell は `#Requires` と `[CmdletBinding()]` を必須に
- [ ] Bash は `set -euo pipefail` を必須に

### リポジトリ運用

- [ ] `config/<env>/secrets.ref.yml` 以外にシークレット参照を書かない
- [ ] 本番設定の変更は別ブランチ＋承認者レビュー必須
- [ ] CI の lint / シークレットスキャン / テストをすべてグリーンに
- [ ] リリースタグに署名する（改ざん検知）

### 実行環境

- [ ] スクリプト実行アカウントは最小権限
- [ ] 本番実行は踏み台サーバ経由のみ許可
- [ ] 監査ログは中央 SIEM に集約し、改ざん不可の領域に保存
- [ ] 緊急時の手動実行も `lib/Audit` 経由で必ず記録される設計にする

---

## 6. 拡張時の指針

| やりたいこと | やるべきこと |
|---|---|
| 新しいミドル（例：Redis）を追加 | `scripts/redis/{common,windows,linux}/` を作成 |
| 既存ミドルに新しい操作を追加 | 該当 `<middleware>/<os>/<action>/` 配下に新ファイル |
| 新しい業務手順を追加 | `playbooks/<業務名>/` を作成し、既存スクリプトを呼び出す |
| 新しい環境（例：QA）を追加 | `config/qa/` と `inventory/` のグループを追加 |
| 新しい OS（例：macOS）を追加 | 各 `<middleware>/macos/` を追加し、`lib/bash/` を共有 or `lib/macos/` 新設 |

**してはいけないこと**

- 共通処理を各スクリプトに直接書く（→ `lib/` に集約する）
- ミドルに紐づく操作を `scripts/<os>/` 直下に置く（→ `scripts/<middleware>/<os>/` に置く）
- シークレットを `config/` の YAML に直接書く（→ Vault 参照にする）
- Playbook を経由せず本番スクリプトを直接叩くことを常態化する（→ 監査ログが分散する）

---

## 付録：最小構成の起点

ゼロから立ち上げるとき、最初に作るべきは次の最小セットです。

```
ops-scripts/
├── README.md
├── lib/powershell/Logging.psm1
├── lib/powershell/Audit.psm1
├── lib/powershell/Secrets.psm1
├── lib/bash/logging.sh
├── lib/bash/audit.sh
├── lib/bash/secrets.sh
├── tools/new-script.ps1
└── ci/lint/
```

この **「共通ライブラリ + テンプレート生成 + lint」** さえ最初に固めておけば、その後追加されるスクリプトは自然と品質が揃います。順序を逆にして個別スクリプトから書き始めると、後からのガバナンス導入が極めて困難になるので注意してください。
