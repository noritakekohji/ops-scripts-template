# GitLab CI テンプレート（ops-scripts 用）

エンタープライズ向け運用シェル（PowerShell / Bash / SQL 混在）リポジトリのための、GitLab CI / GitLab Runner 向けテンプレートです。**別リポジトリにコピーするだけで動く**ように、設定ファイル・実行スクリプト・除外ルールを一式まとめてあります。

---

## 1. 含まれるもの

```
ci-template/
├── .gitlab-ci.yml                # メインパイプライン（include で各モジュールを読み込む）
├── .gitleaks.toml                # gitleaks 除外ルール
├── .yamllint                     # yamllint 設定
├── .sqlfluff                     # sqlfluff 設定（既定: T-SQL）
├── .gitignore                    # シークレット混入防止 + CI 成果物の除外
└── ci/
    ├── lint/
    │   ├── powershell.gitlab-ci.yml      # PSScriptAnalyzer
    │   ├── run-psscriptanalyzer.ps1
    │   ├── shell.gitlab-ci.yml           # ShellCheck
    │   ├── sql.gitlab-ci.yml             # sqlfluff
    │   └── yaml.gitlab-ci.yml            # yamllint
    ├── security/
    │   ├── secrets.gitlab-ci.yml         # gitleaks（シークレット混入検査）
    │   └── deps.gitlab-ci.yml            # Trivy（依存脆弱性）
    └── test/
        ├── pester.gitlab-ci.yml          # Pester（PowerShell）
        ├── run-pester.ps1
        └── bats.gitlab-ci.yml            # bats-core（Bash）
```

---

## 2. 別リポジトリへのコピー手順

新しいリポジトリのルートで、`ci-template/` の中身を**そのままコピー**します。

```powershell
# 例：PowerShell
Copy-Item -Recurse ci-template\* C:\path\to\new-repo\
Copy-Item ci-template\.gitlab-ci.yml C:\path\to\new-repo\
Copy-Item ci-template\.gitleaks.toml,ci-template\.yamllint,ci-template\.sqlfluff,ci-template\.gitignore C:\path\to\new-repo\
```

```bash
# 例：Bash
cp -r ci-template/. /path/to/new-repo/
```

コピー後、**コピー先のリポジトリルートで** 以下のレイアウトになっていれば OK です。

```
new-repo/
├── .gitlab-ci.yml
├── .gitleaks.toml
├── .yamllint
├── .sqlfluff
├── .gitignore
└── ci/
    ├── lint/
    ├── security/
    └── test/
```

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
