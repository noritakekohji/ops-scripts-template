# ops-scripts-template

エンタープライズ向け運用スクリプト（PowerShell / Bash / SQL 混在）の **共通テンプレートリポジトリ**です。GitLab CI 設定一式に加えて、AWS / OS / 各種ミドルウェア（PostgreSQL / MySQL / SAP HANA / S4HANA / SQL Server / Tomcat）の **制御スクリプト本体**、**運用補助ツール**（perf-monitor / network-check / change-detect / server-compare）、**仕様書**を同梱しています。

別リポジトリへの配備は `deploy/sync.py` または GitLab CI（`ci/deploy/sync.gitlab-ci.yml`）で行います。

---

## 1. 含まれるもの

```
ops-scripts-template/
├── .gitlab-ci.yml                # メインパイプライン（include で各モジュールを読み込む）
├── .gitleaks.toml                # gitleaks 除外ルール
├── .yamllint                     # yamllint 設定
├── .sqlfluff                     # sqlfluff 設定（既定: T-SQL）
├── .gitattributes / .gitignore   # 改行・エンコーディング統制
├── README.md / install.md / shell-specification.md / development-rules.md
├── ops-scripts-structure.md      # 全体ディレクトリ構成の詳細
├── ci/
│   ├── lint/        # PSScriptAnalyzer / ShellCheck / sqlfluff / yamllint / template-check
│   ├── security/    # gitleaks / Trivy
│   ├── test/        # Pester / bats
│   ├── deploy/      # 別リポジトリへの自動同期
│   └── template-check/
├── config/          # default / dev / staging / production の .conf
├── scripts_linux/   # bash スクリプト本体 (aws/hana/mysql/os/postgresql/sap/sqlserver/tomcat/lib)
├── scripts_windows/ # PowerShell スクリプト本体 (同上 + lib)
├── docs_linux/      # Linux 側スクリプトの仕様書 (.md)
├── docs_windows/    # Windows 側スクリプトの仕様書 (.md)
├── tools/           # 運用補助ツール
│   ├── perf-monitor/      # 負荷テスト中のリソース監視＋HTML レポート
│   ├── network-check/     # DNS/Ping/TCP 接続性チェック
│   ├── change-detect/     # サーバ情報の前後比較
│   ├── server-compare/    # サーバ情報収集と差分検出
│   ├── aws-instance-audit/ # EC2 自インスタンスの IAM/SG/VPC 監査
│   └── templates/         # 新規スクリプト用テンプレート
├── deploy/          # 別リポジトリへの同期スクリプト (sync.py / servers.yaml)
└── tests/
    ├── pester/      # PowerShell ユニットテスト
    ├── bats/        # Bash ユニットテスト
    └── docker/      # Docker でのエンドツーエンドテスト
```

詳細な構成は `ops-scripts-structure.md` を参照。

---

## 2. 別リポジトリへの配備

`deploy/sync.py` で別リポジトリへスクリプト・ドキュメント・CI 設定を同期できます。詳細は `deploy/SPEC.md`。CI 経由で自動同期する場合は `ci/deploy/sync.gitlab-ci.yml` を include してください。

---

## 3. GitLab Runner の前提

| ジョブ | 必要な runner | runner タグ（既定） |
|---|---|---|
| psscriptanalyzer / pester | Windows、PowerShell 7+ | `windows` |
| shellcheck / sqlfluff / yamllint / gitleaks / trivy / bats | Linux + Docker executor | `linux` |

### タグを変える場合

各 `*.gitlab-ci.yml` の `tags:` ブロックを自社のタグ規約に合わせて書き換えてください。例：

```yaml
tags:
  - prod-runner
  - windows
```

### Docker executor が使えない場合

Linux ジョブの `image:` 行を削除し、必要なコマンド（`shellcheck`、`yamllint`、`sqlfluff`、`gitleaks`、`trivy`）を Runner ホストにあらかじめインストールしてください。

---

## 4. 個別の検査を無効化する

`.gitlab-ci.yml` の `include:` セクションで、不要な行をコメントアウトするだけです。

```yaml
include:
  # lint
  - local: ci/lint/powershell.gitlab-ci.yml
  - local: ci/lint/shell.gitlab-ci.yml
  # - local: ci/lint/sql.gitlab-ci.yml      # ← SQL を扱わないなら無効化
  - local: ci/lint/yaml.gitlab-ci.yml
  # security
  - local: ci/security/secrets.gitlab-ci.yml
  - local: ci/security/deps.gitlab-ci.yml
  # test
  # - local: ci/test/pester.gitlab-ci.yml   # ← Pester テストがまだ無いなら無効化
  # - local: ci/test/bats.gitlab-ci.yml     # ← bats テストがまだ無いなら無効化
```

テストジョブは「テストファイルが無ければ自動スキップ」する作りなので、有効のままでも壊れません。

---

## 5. 各検査の概要

| ステージ | ジョブ | 何を検査するか | 失敗条件 |
|---|---|---|---|
| lint | psscriptanalyzer | PowerShell の規約・潜在バグ | `Error` 重大度の検出 |
| lint | shellcheck | Bash スクリプトの規約・潜在バグ | warning 以上の検出 |
| lint | sqlfluff | SQL の整形・規約 | ルール違反の検出 |
| lint | yamllint | YAML 構文・整形 | エラーの検出 |
| security | gitleaks | シークレット（API キー、パスワード等）の混入 | 1 件でも検出 |
| security | trivy-fs | 依存ライブラリ・ファイルシステムの脆弱性 | HIGH/CRITICAL の検出 |
| test | pester | PowerShell ユニットテスト | テスト失敗 |
| test | bats | Bash ユニットテスト | テスト失敗 |

---

## 6. シークレット運用との関係

このテンプレートはあくまで **「シークレットがリポジトリに混入していないこと」を保証する** ものです。**実際のシークレット取得**は実行時に Vault / Azure Key Vault / CyberArk から行ってください（`lib/*/Secrets.*` の責務）。

`config/<env>/secrets.ref.yml` のような **参照キーのみ** のファイルは `.gitleaks.toml` の `allowlist` で除外済みです。実値が混入するとここで止まります。

---

## 7. カスタマイズのよくあるポイント

| やりたいこと | 変更する場所 |
|---|---|
| SQL ダイアレクトを変える（PostgreSQL 等） | `.sqlfluff` の `dialect = tsql` を変更 |
| lint 失敗の閾値を緩める | `ci/lint/run-psscriptanalyzer.ps1` の `Severity` / `shellcheck --severity` |
| Trivy で許容する CVE を指定 | `ci/security/deps.gitlab-ci.yml` に `--ignorefile .trivyignore` を追加し `.trivyignore` を作成 |
| 監査用に成果物を長く保持 | 各ジョブの `artifacts.expire_in` を延ばす |
| MR 以外でも全ジョブを走らせる | `.gitlab-ci.yml` の `workflow.rules` を調整 |

---

## 8. 動作確認

新リポジトリにコピー後、最初の MR でパイプラインが走り、各ジョブが想定どおりスキップ／実行されることを確認してください。すべてのジョブを通すには、最低限以下が必要です。

- `.gitlab-ci.yml` ほかの設定ファイルがリポジトリルートにある
- `tags` の値が、実在する GitLab Runner にマッチしている
- Linux ジョブで Docker executor の Runner が利用可能
- Windows ジョブで PowerShell 7+ がインストールされた Windows Runner が利用可能
