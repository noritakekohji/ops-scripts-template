# テスト

`lib/` 配下の共通モジュールのユニットテスト。

| 種別 | フレームワーク | 配置 |
|---|---|---|
| PowerShell | Pester 5+ | `tests/pester/` |
| Bash | bats-core | `tests/bats/` |

## 実行方法

### PowerShell（Pester）

```powershell
# 必要なら初回のみ
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck

# リポジトリ root から
Invoke-Pester -Path tests/pester -Output Detailed
```

### Bash（bats-core）

```bash
# 例：Ubuntu / Debian
sudo apt install bats

# リポジトリ root から
bats tests/bats
```

CI（[`ci/test/pester.gitlab-ci.yml`](../ci/test/pester.gitlab-ci.yml) / [`ci/test/bats.gitlab-ci.yml`](../ci/test/bats.gitlab-ci.yml)）でも自動実行される。

## カバレッジ

| 対象 | テストファイル | 内容 |
|---|---|---|
| `Get-OpsJstStamp` | `pester/Logging.Tests.ps1` | 既定フォーマット、カスタムフォーマット、JST 固定（UTC+9） |
| `Write-OpsLog` | `pester/Logging.Tests.ps1` | レベル検証、stdout/stderr 振り分け、改行置換、レベル左詰め |
| `Get-OpsConfig` | `pester/Config.Tests.ps1` | 4 階層マージ順、コメント / 空行スキップ、引用符除去、空白 trim、不正行スキップ |
| `ops_jst_stamp` | `bats/logging.bats` | 既定フォーマット、カスタムフォーマット、JST 固定 |
| `log_info` / `log_warn` / `log_error` / `log_debug` | `bats/logging.bats` | フォーマット、stdout/stderr 振り分け、改行置換 |
| `load_ops_config` | `bats/config.bats` | 4 階層マージ順、パース仕様、`OPS_ENV` 連携、第 3 引数の repo root 上書き |

## テストの隔離

設定ファイルのテストは **実リポジトリの `config/` を読まない**ように、
毎テスト一時ディレクトリを作って `Get-OpsConfig -RepoRoot` / `load_ops_config '...' '...' <repo_root>` で渡している。

## 範囲外（v1）

以下は今回スコープ外。必要になり次第追加：

- 各スクリプト（`Backup-Ami.ps1` 等）の引数バリデーション・冪等スキップ判定
- AWS API 呼び出しのモック（PS Pester `Mock`、bats では関数差し替え）
- statefulな I/O（rotate_log の rename / copytruncate、s3upload のキー組み立て）
