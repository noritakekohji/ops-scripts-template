# シェルスクリプト仕様書

このリポジトリで運用シェルスクリプト（PowerShell / Bash / T-SQL）を書くときの **規約と必須要件** をまとめたものです。すべてのスクリプトはこの仕様に準拠してください。CI のチェック項目はこの仕様をベースにしています。

ディレクトリ構成の設計思想は [`ops-scripts-structure.md`](ops-scripts-structure.md) を参照してください。

---

## 目次

1. [目的と対象範囲](#1-目的と対象範囲)
2. [ディレクトリ配置ルール](#2-ディレクトリ配置ルール)
3. [ファイル命名規約](#3-ファイル命名規約)
4. [ヘッダ・メタ情報](#4-ヘッダメタ情報)
5. [ランタイム要件と安全モード](#5-ランタイム要件と安全モード)
6. [入力検証](#6-入力検証)
7. [認証・シークレット](#7-認証シークレット)
8. [ロガー仕様 v1.0](#8-ロガー仕様-v10)
9. [設定ファイル](#9-設定ファイル)
10. [AWS タグ付け規約](#10-aws-タグ付け規約)
11. [終了コード規約](#11-終了コード規約)
12. [冪等性・副作用の制御](#12-冪等性副作用の制御)
13. [テスト](#13-テスト)
14. [CI 必須チェック](#14-ci-必須チェック)
15. [コミット規約](#15-コミット規約)

---

## 1. 目的と対象範囲

### 目的
- 運用スクリプトの **品質・セキュリティ・監査性** を担保する
- 担当者・OS・ミドルウェアが変わっても **読み方・書き方・動かし方** が揃うようにする
- 障害調査時にログを **横断的に検索** できるようにする

### 対象範囲
- `scripts/` 配下のすべての `.ps1` / `.psm1` / `.sh` / `.bash` / `.sql`
- `lib/` 配下の共通モジュール
- `playbooks/` から呼び出されるすべての実行スクリプト

---

## 2. ディレクトリ配置ルール

階層は浅く保つ。アクション（Backup / Rotate / Invoke 等）は **ファイル名** で表現し、ディレクトリでは表現しない。

| 操作対象 | 配置先 |
|---|---|
| クロスプラットフォームなミドル（Tomcat、SQL Server、Nginx、AWS 等） | `scripts/<middleware>/<lang>/<file>`（lang = `powershell` / `bash`） |
| クロスプラットフォームミドルの OS 非依存資産 | `scripts/<middleware>/common/<file>` |
| OS にしか存在しない概念（AD、systemd、IIS、cron 等） | `scripts/<os>/<lang>/<file>` |
| ミドル横断の汎用処理（通知、監査送信） | `scripts/common/<file>` |
| 業務手順（複数スクリプトの組み合わせ） | `playbooks/<業務名>/` |

### 配置例

```
scripts/aws/powershell/Backup-Ami.ps1                # AWS は middleware 扱い、3 階層
scripts/aws/bash/backup_ebs_snapshot.sh
scripts/sqlserver/common/full_backup.sql          # T-SQL は OS 非依存
scripts/sqlserver/powershell/Invoke-FullBackup.ps1
scripts/windows/Disable-AdUser.ps1                # AD は Windows 固有、2 階層
scripts/linux/restart_systemd_service.sh          # systemd は Linux 固有
scripts/common/Send-Slack.ps1                     # 横串
```

ファイル数が増えて視認性が落ちた時点で、対象別のサブディレクトリ（例：`scripts/aws/powershell/ami/`）を再導入する余地は残してあります。

詳細は [`ops-scripts-structure.md`](ops-scripts-structure.md) を参照。

---

## 3. ファイル命名規約

| 種別 | 形式 | 例 |
|---|---|---|
| PowerShell スクリプト | `Verb-Noun.ps1`（PascalCase + ハイフン、Verb は[承認済み動詞](https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)） | `Backup-Ami.ps1`、`Invoke-FullBackup.ps1` |
| PowerShell モジュール | `PascalCase.psm1` | `Logging.psm1` |
| Bash スクリプト | `snake_case.sh` | `backup_ami.sh`、`invoke_full_backup.sh` |
| Bash ライブラリ | `lowercase.sh` | `logging.sh` |
| T-SQL | `snake_case.sql` | `full_backup.sql` |
| ディレクトリ | 小文字 + ハイフン | `ami/`、`ebs/`、`backup/` |

**OS の差はディレクトリ構造で表現する**。ファイル名に `_win` / `_linux` のような OS サフィックスは付けない。

---

## 4. ヘッダ・メタ情報

スクリプトを開いた数秒で「何をするものか・前提・使い方」が分かるように書く。

### PowerShell

```powershell
#Requires -Version 5.1
<#
.SYNOPSIS
    1 行で目的を書く（動詞で始める）。

.DESCRIPTION
    詳細。前提条件、副作用、認証要件、想定実行環境を含める。

.PARAMETER ParamName
    各パラメータの意味と制約。

.EXAMPLE
    .\Backup-Ami.ps1 -InstanceId i-0abc -NamePrefix prod -RetentionDays 7
#>
```

### Bash

```bash
#!/usr/bin/env bash
# ============================================================================
# script_name.sh
#   1 行サマリ。
#
# Usage:
#   script_name.sh -<flag> <value> ...
#
# Options:
#   -<flag>  説明（required / optional）
#
# Authentication: 認証要件（IAM ロール / Vault 参照 等）
# Exit codes: 0 = 成功、1 = 入力エラー、2 = リソース不在、...
# ============================================================================
```

---

## 5. ランタイム要件と安全モード

### PowerShell：先頭で必須

```powershell
#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    # ...
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
```

| 設定 | 効果 |
|---|---|
| `#Requires -Version 5.1` | PowerShell 5.1 以上必須 |
| `[CmdletBinding(SupportsShouldProcess)]` | `-WhatIf` / `-Confirm` を自動サポート |
| `$ErrorActionPreference = 'Stop'` | 例外を即時停止（暗黙の continue を禁止） |
| `Set-StrictMode -Version Latest` | 未定義変数・タイポを停止扱い |

### Bash：先頭で必須

```bash
#!/usr/bin/env bash
set -euo pipefail
```

| 設定 | 効果 |
|---|---|
| `#!/usr/bin/env bash` | POSIX `sh` ではなく Bash を必須化 |
| `set -e` | コマンド失敗で即時停止 |
| `set -u` | 未定義変数で停止 |
| `set -o pipefail` | パイプ途中の失敗も検知 |

---

## 6. 入力検証

### 必須要件
- すべての引数を **正規表現または列挙値** で検証する
- AWS リソース ID は厳格に検証：

| 種別 | 正規表現 |
|---|---|
| EC2 インスタンス | `^i-[0-9a-f]{8,17}$` |
| EBS ボリューム | `^vol-[0-9a-f]{8,17}$` |
| EBS スナップショット | `^snap-[0-9a-f]{8,17}$` |
| AMI | `^ami-[0-9a-f]{8,17}$` |
| 名前プレフィックス | `^[A-Za-z0-9][A-Za-z0-9._-]{1,120}$` |

- 数値は **範囲も検証**（例：`RetentionDays` は 0〜3650）

### PowerShell の例

```powershell
param(
    [Parameter(Mandatory)][ValidatePattern('^i-[0-9a-f]{8,17}$')]
    [string]$InstanceId,

    [ValidateRange(0, 3650)]
    [int]$RetentionDays = 0
)
```

### Bash の例

```bash
if ! [[ "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]]; then
    log_error "Invalid instance id: $instance_id"
    exit 1
fi
if ! [[ "$retention_days" =~ ^[0-9]+$ ]] || [[ "$retention_days" -gt 3650 ]]; then
    log_error "Invalid retention days: $retention_days"
    exit 1
fi
```

---

## 7. 認証・シークレット

### 厳守ルール
1. **シークレット（パスワード、API キー、秘密鍵、トークン）をスクリプト内に書かない**
2. リポジトリ内のいかなるファイルにも **平文のシークレットを置かない**（CI の gitleaks で検知される）
3. 環境変数経由で渡すときも **既定値をコードに書かない**
4. ログにシークレットを出力しない（マスキングは v1.1 で導入予定）

### 推奨パターン

| 環境 | シークレットストア |
|---|---|
| AWS（EC2/Lambda 上） | IAM インスタンスロール / IAM ロールチェイン |
| AWS（オフプラットフォーム） | Named profile + AWS Secrets Manager / SSM Parameter Store |
| Windows サーバ | Windows Credential Manager / Azure Key Vault |
| Linux サーバ | HashiCorp Vault / CyberArk |

### 設定ファイルの取り扱い

`config/<env>/secrets.ref.yml` のような **参照キーのみ** のファイルを使う。実値は実行時に Vault から取得する。`.gitleaks.toml` の allowlist は `ref://...` 形式の参照を除外済み。

---

## 8. ロガー仕様 v1.0

### フォーマット

```
[YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message
```

| 要素 | 仕様 |
|---|---|
| タイムスタンプ | `YYYY-MM-DD hh:mm:ss`（**日本時刻 / JST / UTC+9 固定**、24h、ミリ秒なし。OS の TZ 設定に依存しない） |
| Level | `INFO ` / `WARN ` / `ERROR` / `DEBUG`（**5 文字左詰め**で揃える） |
| shellname | 呼び出しスクリプトの **basename**（パスなし） |
| pid | プロセス ID |
| Message | 呼び出し側が組み立てる任意の文字列。改行は空白に置換される |

### 出力先

| Level | 出力先 |
|---|---|
| DEBUG | stdout |
| INFO | stdout |
| WARN | **stderr** |
| ERROR | **stderr** |

### 出力サンプル

```
[2026-05-09 12:14:05] [INFO ] (Backup-Ami.ps1:1234) AMI backup start: instanceId=i-0abc namePrefix=prod-web retentionDays=7
[2026-05-09 12:14:35] [INFO ] (Backup-Ami.ps1:1234) AMI creation initiated: amiId=ami-0xyz amiName=prod-web-20260509-031405
[2026-05-09 12:15:05] [WARN ] (Backup-Ami.ps1:1234) Snapshot delete failed: snapshotId=snap-0abc error=Snapshot in use
[2026-05-09 12:15:06] [ERROR] (Backup-Ami.ps1:1234) AMI did not reach available state: amiId=ami-0xyz state=failed
```

### API

#### PowerShell（`lib/powershell/Logging.psm1`）

```powershell
$libPath = [IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'powershell', 'Logging.psm1')
Import-Module (Resolve-Path $libPath).Path -Force

Write-OpsLog -Level INFO  -Message "AMI backup start: instanceId=$id retention=$days"
Write-OpsLog -Level WARN  -Message "Snapshot delete failed: snapshotId=$snap error=$err"
Write-OpsLog -Level ERROR -Message "Instance not found: instanceId=$id"
Write-OpsLog -Level DEBUG -Message "Polling state: amiId=$id state=$state"
```

- 関数は `Write-OpsLog` のみ
- `-Level` は `DEBUG` / `INFO`（既定） / `WARN` / `ERROR`
- ファイル出力を有効にするには `Set-OpsLogConfig -LogFile <path> -LogLevel <level>` を呼ぶ（`global.conf` の `LogFile` / `LogLevel` キーで設定可）
- **構造化プロパティ引数（`-Properties` 等）はサポートしない**
- 構造化情報は呼び出し側で `key=value` 形式に整形して `-Message` に埋め込む

#### Bash（`lib/bash/logging.sh`）

```bash
source "$(dirname "$0")/../../../../lib/bash/logging.sh"

log_info  "AMI backup start: instance=$instance_id retention=$retention_days"
log_warn  "Snapshot delete failed: snapshot=$snap (in use?)"
log_error "Instance not found: $instance_id"
log_debug "Polling state: amiId=$ami_id state=$state"
```

- 関数は `log_debug` / `log_info` / `log_warn` / `log_error`
- 引数はメッセージ文字列のみ
- 構造化情報は `key=value` を埋め込む形で含める

### 構造化情報の書き方（推奨）

Message 内に `key=value` をスペース区切りで列挙する：

```
AMI creation initiated: amiId=ami-0xyz instanceId=i-0abc namePrefix=prod-web
```

このスタイルにより：
- 人間の目で読みやすい
- `grep amiId=ami-0abc` で **特定のリソースに絞り込み検索** できる
- SIEM（Splunk / ELK 等）の `kv` パーサが **自動的にフィールド抽出** する

スペースを含む値は `"..."` で囲む（例：`error="message with spaces"`）。

### 禁止事項
- 平文のパスワード・トークンを Message に含めない
- 1 イベントを複数行に分けて出力しない（必ず 1 行 1 イベント）
- ロガー以外の手段で `Write-Host` / `echo` を使った独自ログを出さない（監査ログの一元性を破壊する）

---

## 9. 設定ファイル

スクリプトの挙動を決めるパラメータ（リージョン、保持日数、冪等性ウィンドウ 等）は **`config/<env>/<script-name>.conf`** で外出しできる。CLI 引数は config より常に優先される。

### 解決の優先順位（高 → 低）

```
1. CLI 引数
2. config/<env>/<script-name>.conf   ─┐ env 指定時のみ（default は読まない）
3. config/<env>/global.conf          ─┘
4. config/default/<script-name>.conf ─┐ env 未指定時のみ
5. config/default/global.conf        ─┘
6. スクリプトのハードコード既定値
```

`<env>` は環境変数 `OPS_ENV` で切り替え。  
env 未指定 → `config/default/` のみ参照。env 指定 → `config/<env>/` のみ参照（default との上書きマージは行わない）。

### フォーマット

```ini
# 行頭 '#' はコメント、空行は無視

Region        = ap-northeast-1
RetentionDays = 7
NoReboot      = true                  # bool は true / false
Description   = "weekly backup"       # 値の前後を "..." または '...' で囲める
```

| ルール | 内容 |
|---|---|
| 1 行 1 設定 | `Key = Value` |
| コメント | 行頭 `#` のみ |
| 空白 | キー・値ともに自動 trim |
| クォート | 値の前後 `"..."` / `'...'` は除去 |
| 文字コード | UTF-8 |

### 命名

config ファイルは **Windows / Linux ペアで共有**（snake_case 小文字に統一）。

| 機能 | スクリプト | 共有 config |
|---|---|---|
| AMI バックアップ | `Backup-Ami.ps1` / `backup_ami.sh` | `backup_ami.conf` |
| EBS スナップショット | `Backup-EbsSnapshot.ps1` / `backup_ebs_snapshot.sh` | `backup_ebs_snapshot.conf` |
| ログローテーション | `Rotate-Log.ps1` / `rotate_log.sh` | `rotate_log.conf` |
| EC2 ライフサイクル | `Ec2Ctl.ps1` / `ec2ctl.sh` | `ec2ctl.conf` |

キー名は **PascalCase**（`Region`、`RetentionDays`、`MaxSizeMB` …）で PS と Bash 共通。

### スコープのルール

- **CLI のみ**：per-run の対象（`-InstanceId`、`-VolumeId`、`-NamePrefix`、`-Path`、`-PathList` 等）
- **config 可**：挙動ポリシー（`Region`、`RetentionDays`、`MinIntervalMinutes`、`NoReboot`、`Wait`、`Pattern`、`MaxSizeMB` 等）

per-run の対象を config に書くと、運用スクリプトが「環境ごとに違うインスタンスを暗黙に選ぶ」状態になり追跡性が落ちるため**禁止**。

### スクリプト側の使い方

#### PowerShell（`lib/powershell/Config.psm1`）
```powershell
Import-Module (Resolve-Path "<repo>/lib/powershell/Config.psm1").Path -Force
$cfg = Get-OpsConfig -Name 'backup_ami'
if (-not $PSBoundParameters.ContainsKey('Region') -and $cfg.ContainsKey('Region')) {
    $Region = [string]$cfg['Region']
}
```

#### Bash（`lib/bash/config.sh`）
```bash
source "<repo>/lib/bash/config.sh"
load_ops_config "backup_ami"
[[ "$region_set" -eq 0 && -n "${OPS_CONFIG[Region]:-}" ]] && region="${OPS_CONFIG[Region]}"
```

Bash 側は `getopts` ループで `_set=1` を立て、未設定の場合のみ config から拾う。

### 必ず出るログ

設定が読み込まれたことは Phase 2 の冒頭で 1 行ログに残す：

```
[2026-05-09 12:14:05] [INFO ] (Backup-Ami.ps1:1234) Config loaded: env=production keys=4
```

### 禁止事項

- **シークレットを `.conf` に書かない**（パスワード、API キー、トークン）。Vault 等の参照キー形式（`ref://...`）は可
- per-run の対象（InstanceId、VolumeId、Path 等）を config に書かない

### 詳細

[`config/README.md`](config/README.md) にフォーマット仕様、運用例、サンプルがあります。

---

## 10. AWS タグ付け規約

AWS リソース（AMI / Snapshot / Volume / EC2 等）を作成するスクリプトは、**必ず以下のタグを付与** する。

| Key | Value | 必須 | 用途 |
|---|---|---|---|
| `Name` | `<NamePrefix>-<UTC yyyyMMdd-HHmmss>` | ✅ | 視認性 |
| `CreatedBy` | `ops-scripts`（固定） | ✅ | 自動生成リソースの識別 |
| `CreatedAt` | UTC タイムスタンプ `yyyyMMdd-HHmmss` | ✅ | 作成日時 |
| `NamePrefix` | スクリプト引数の `-NamePrefix` | ✅ | pruning フィルタ |
| `RetentionDays` | 保持日数（数値の文字列） | ✅ | 監査・ポリシー検証 |
| `SourceInstanceId` または `SourceVolumeId` | バックアップ元 | ✅ | 系譜の追跡 |

### Pruning（世代管理）の安全装置

古いリソースの削除は **必ず以下の AND 条件で対象を絞り込む**：

```
tag:CreatedBy = ops-scripts
AND
tag:NamePrefix = <指定された prefix>
```

これにより：
- 手動作成リソースを誤って削除することがない
- 別の系統（別 NamePrefix）のバックアップを巻き込むことがない

---

## 11. 終了コード規約

| Code | 意味 | 使用例 |
|---|---|---|
| 0 | 成功 | 正常終了 |
| 1 | 入力エラー | 引数欠落、validation 失敗、usage |
| 2 | リソース不在・参照不可 | インスタンスが見つからない、ボリュームが見つからない |
| 3 | リソース状態不正 | 待機中にタイムアウト、`failed` 状態到達 |
| 4 | 操作失敗 | API 呼び出しエラー、書き込み失敗 |
| 10〜 | 環境前提エラー | 必須モジュール / CLI 未インストール |
| 20〜 | 認証・権限エラー | IAM 不足、認証失敗（実装時に追加） |

PowerShell は `exit <code>` で明示的に終了させる。Bash も明示的なエラーパスでは `exit <code>` を使う。

---

## 12. 冪等性・副作用の制御

### 必須要件
- 同じ引数で 2 回実行しても **副作用が増えない** こと
  - リソース名は UTC タイムスタンプサフィックスで衝突を避ける
  - 操作前に既存リソースの状態を確認する
- 失敗時に **中途半端な状態を残さない** こと
- 削除系の操作は必ず **ホワイトリスト方式**（タグや prefix で対象を限定）

### `-WhatIf` / Dry-run 対応

#### PowerShell
```powershell
[CmdletBinding(SupportsShouldProcess)]
# ...
if ($PSCmdlet.ShouldProcess($Target, "Action description")) {
    # 実際の操作
}
```

`-WhatIf` で実行すると操作内容のみ表示し、実際の API 呼び出しは行わない。

#### Bash
明示的な `--dry-run` フラグを実装する（任意）。AWS CLI には組み込みの `--dry-run` がある。

---

## 13. テスト

| 種別 | 配置先 | フレームワーク |
|---|---|---|
| PowerShell ユニットテスト | `tests/pester/<area>/*.Tests.ps1` | Pester 5+ |
| Bash ユニットテスト | `tests/bats/<area>/*.bats` | bats-core |
| T-SQL テスト | `tests/tsqlt/` | tSQLt（任意） |

### 推奨カバレッジ
新規スクリプトには **最低 1 件のテスト** を追加することを推奨：
- 引数 validation の正常系・異常系
- パス解決（lib import）の正常動作

CI（[ci/test/pester.gitlab-ci.yml](ci/test/pester.gitlab-ci.yml) / [ci/test/bats.gitlab-ci.yml](ci/test/bats.gitlab-ci.yml)）は、テストファイルが存在しない場合は自動でスキップする。

---

## 14. CI 必須チェック

PR ごとに自動実行される（[`.gitlab-ci.yml`](.gitlab-ci.yml)）：

| ステージ | チェック | 失敗条件 |
|---|---|---|
| lint | PSScriptAnalyzer | Error 重大度の検出 |
| lint | ShellCheck | warning 以上 |
| lint | sqlfluff | ルール違反 |
| lint | yamllint | エラー |
| security | gitleaks | シークレット 1 件でも検出 |
| security | trivy-fs | HIGH / CRITICAL 検出 |
| test | Pester / bats | テスト失敗 |

すべて **必須**。マージは全チェックグリーンが条件。

---

## 15. コミット規約

- 1 コミット = 1 論理変更
- メッセージは英語推奨。**WHY を書く**（WHAT は diff から自明）
- 件名は 50 文字以内、本文は 72 文字で改行
- 例：

```
Switch logger to plain-text format (spec v1.0)

JSON output proved overkill for our SIEM (Splunk auto-extracts kv).
Plain-text is easier to grep on the box during incidents.
```

---

