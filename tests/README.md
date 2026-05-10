# テスト実施手順

`lib/` 配下の共通モジュール（ロガー / 設定ファイルローダ）に対するユニットテストの実行方法。

| 種別 | フレームワーク | 配置 | バージョン要件 |
|---|---|---|---|
| PowerShell | Pester | `tests/pester/` | 5.5.0 以上 |
| Bash | bats-core | `tests/bats/` | 1.5.0 以上推奨 |

---

## 1. 前提条件のインストール

### Windows（PowerShell）

```powershell
# 管理者権限不要（CurrentUser スコープ）
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck

# バージョン確認
Get-Module -ListAvailable Pester | Where-Object Version -ge '5.5.0'
```

### Linux（Bash）

```bash
# Ubuntu / Debian
sudo apt-get install -y bats

# RHEL 系
sudo dnf install -y bats   # または: sudo yum install bats

# macOS
brew install bats-core

# バージョン確認
bats --version
```

### CI 上の前提

CI（GitLab Runner）には [`ci/test/pester.gitlab-ci.yml`](../ci/test/pester.gitlab-ci.yml) と [`ci/test/bats.gitlab-ci.yml`](../ci/test/bats.gitlab-ci.yml) がそれぞれの環境を用意済み。手動セットアップ不要。

---

## 2. 全テストの実行

リポジトリ root から以下を実行する。

### Pester（PowerShell）

```powershell
# シンプル実行
Invoke-Pester -Path tests/pester

# 詳細表示（推奨）
Invoke-Pester -Path tests/pester -Output Detailed

# JUnit 形式でレポート出力（CI 互換）
$config = New-PesterConfiguration
$config.Run.Path = 'tests/pester'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = 'pester-results.xml'
$config.TestResult.OutputFormat = 'JUnitXml'
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
```

### bats（Bash）

```bash
# シンプル実行
bats tests/bats

# verbose（実行中のテスト名を表示）
bats --verbose-run tests/bats

# JUnit 形式でレポート出力
bats --formatter junit tests/bats > bats-results.xml

# tap 形式（CI / IDE 連携）
bats --tap tests/bats
```

---

## 3. 特定のテストだけ実行

### Pester

```powershell
# ファイル単位
Invoke-Pester -Path tests/pester/Logging.Tests.ps1

# Describe / It 名でフィルタ
Invoke-Pester -Path tests/pester -FullNameFilter '*JST*'

# タグで絞り込み（タグ付きの場合）
Invoke-Pester -Path tests/pester -TagFilter logging
```

### bats

```bash
# ファイル単位
bats tests/bats/logging.bats

# テスト名（@test "..."）の正規表現マッチ
bats --filter 'JST' tests/bats

# 特定行のテストだけ
bats --filter-tags 'logging' tests/bats   # tags 付き構文を使う場合
```

---

## 4. 期待する出力

### Pester（成功時）
```
Starting discovery in 1 file.
Discovery found 17 tests in ...
Running tests.
[+] tests/pester/Logging.Tests.ps1   500ms (300ms|150ms)
[+] tests/pester/Config.Tests.ps1    420ms (250ms|130ms)
Tests completed in 920ms
Tests Passed: 17, Failed: 0, Skipped: 0 NotRun: 0
```

### bats（成功時）
```
 ✓ ops_jst_stamp: 既定で yyyyMMdd-HHmmss 形式の 15 文字を返す
 ✓ ops_jst_stamp: カスタムフォーマットを受け付ける
 ...
20 tests, 0 failures
```

### 失敗例（赤字部分が原因）
```
[-] tests/pester/Config.Tests.ps1.Get-OpsConfig.common/<name>.conf が common/global.conf を上書きする 50ms
   Expected: 'us-east-1'
   But was : 'ap-northeast-1'
```

---

## 5. CI 上での自動実行

PR / マージ時に自動で走る（`.gitlab-ci.yml` の `include` で有効化済み）。

| ジョブ | 実行内容 | 失敗条件 |
|---|---|---|
| `pester` | `tests/pester/` 配下を Pester で実行、JUnit XML を artifacts に出力 | テスト失敗 1 件以上 |
| `bats` | `tests/bats/` 配下を bats で実行、JUnit XML を artifacts に出力 | テスト失敗 1 件以上 |

各ジョブはテストディレクトリ／ファイルが空のときは **自動的にスキップ**する作りになっている（テストを書く前から CI が赤くならない）。

---

## 6. カバレッジ

| 対象 | テストファイル | 内容 |
|---|---|---|
| `Get-OpsJstStamp` | `pester/Logging.Tests.ps1` | 既定フォーマット、カスタムフォーマット、JST 固定（UTC+9） |
| `Write-OpsLog` | `pester/Logging.Tests.ps1` | レベル検証、stdout/stderr 振り分け、改行置換、レベル左詰め |
| `Get-OpsConfig` | `pester/Config.Tests.ps1` | 4 階層マージ順、コメント / 空行スキップ、引用符除去、空白 trim、不正行スキップ |
| `ops_jst_stamp` | `bats/logging.bats` | 既定フォーマット、カスタムフォーマット、JST 固定 |
| `log_*`（4 関数） | `bats/logging.bats` | フォーマット、stdout/stderr 振り分け、改行置換 |
| `load_ops_config` | `bats/config.bats` | 4 階層マージ順、パース仕様、`OPS_ENV` 連携、第 3 引数の repo root 上書き |

---

## 7. テストの隔離方針

設定ファイルのテストは **実リポジトリの `config/` を読まない**ように毎テスト一時ディレクトリを作って渡している：

- **Pester**：`Get-OpsConfig -RepoRoot $tempDir`
- **bats**：`load_ops_config <name> <env> <repo_root>`（第 3 引数）

各テスト後に `Remove-Item -Recurse -Force` / `rm -rf` で一時ディレクトリを破棄する（`AfterEach` / `teardown`）。

---

## 8. トラブルシューティング

### 「Pester not found」
モジュールがインストールされていない、または古いバージョン。`Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck` を実行。

### 「bats: command not found」
パッケージマネージャでインストール（上記「前提条件」参照）。

### Pester 4.x が読み込まれてしまう
PowerShell 7+ では Pester 5+ の文法を使っているので、`Import-Module Pester -MinimumVersion 5.5.0 -Force` で明示的に新しい方を読み込む。

### bats: `[[: unbound variable`
Bash 3.x で実行している可能性あり（macOS 標準は 3.x）。`bash --version` で 4.x 以上か確認、必要なら `brew install bash`。

### Pester の Console 出力捕捉が効かない
`[Console]::SetOut` 経由で捕捉している（PowerShell の `Write-Output` ではなく `[Console]::Out.WriteLine` を使うため）。Pester 5.5+ なら問題なし。

### `load_ops_config` がテスト用 repo を見ない
第 3 引数を渡しているか確認。渡さないと自動的にリポジトリ root を探しに行き、実 config を読む。

---

## 9. テストの追加方法

### 新しい Pester テスト
1. `tests/pester/<対象モジュール名>.Tests.ps1` を作成
2. `BeforeAll` で対象モジュールを `Import-Module ... -Force`
3. `Describe` / `It` で構造化
4. 副作用のあるテストは `BeforeEach` / `AfterEach` で隔離（一時ディレクトリ等）

### 新しい bats テスト
1. `tests/bats/<対象機能>.bats` を作成、先頭で `load test_helper`
2. `setup()` / `teardown()` を必要に応じて定義
3. `@test "<日本語の意図>"` で各テストを書く
4. アサーションは `[ "$x" = "y" ]` か `[[ ... ]]`

### 命名規約
- Pester：`<対象>.Tests.ps1`（PascalCase + `.Tests`）
- bats：`<対象>.bats`（snake_case）
- テスト名は **日本語の意図優先**（grep しやすさよりレビューしやすさ）

---

## 10. 範囲外（v1）

以下は今回スコープ外。必要になり次第追加：

- 各スクリプト（`Backup-Ami.ps1` 等）の引数バリデーション・冪等スキップ判定
- AWS API 呼び出しのモック（PS Pester `Mock`、bats では関数差し替え）
- statefulな I/O（rotate_log の rename / copytruncate、s3upload のキー組み立て）
