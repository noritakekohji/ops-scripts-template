# スクリプトテンプレート

新規スクリプトを追加するときの **出発点となる骨組み**。CI の `template-check` ジョブはここで定義された必須要素が含まれているかを `scripts/**` 配下の全スクリプトで検証します。

| ファイル | 用途 |
|---|---|
| [`Template-Script.ps1`](Template-Script.ps1) | PowerShell 5.1+ 用 |
| [`template_script.sh`](template_script.sh) | Bash 用 |

## スクリプト構造（5 フェーズ）

両テンプレートは以下の 5 段階で構成されています。**新規スクリプトを書くときも同じ並びを守ってください**。

```
┌─────────────────────────────────────────────┐
│ ① 引数パース & 入力チェック                   │
│    - 必須項目／形式／範囲                    │
│    - クロスパラメータ整合                    │
│    - NG → exit 1                            │
├─────────────────────────────────────────────┤
│ ② 環境セットアップ                           │
│    - Logger 読み込み                         │
│    - StrictMode / set -euo pipefail          │
│    - 後処理ハンドラ登録                      │
├─────────────────────────────────────────────┤
│ ③ プレチェック（前提条件＋冪等性）           │
│    a. 必要ツール／モジュール       NG→exit 10│
│    b. 認証可否                     NG→exit 20│
│    c. 対象リソース存在             NG→exit 2 │
│    d. 既に目的状態か（冪等）       YES→exit 0│
│    e. 外部依存到達性               NG→exit 5 │
├─────────────────────────────────────────────┤
│ ④ メイン処理                                 │
│    - 副作用のある実処理                      │
│    - 失敗 → exit 4                          │
├─────────────────────────────────────────────┤
│ ⑤ 後処理（必ず実行）                         │
│    - 一時ファイル／ロック解放                │
│    - 完了サマリログ                          │
└─────────────────────────────────────────────┘
```

### 各フェーズの役割

| フェーズ | 副作用 | 失敗時 exit | 役割 |
|---|---|---|---|
| ① 入力チェック | なし | `1` | 引数の構文・形式検証のみ。外部問い合わせはしない |
| ② セットアップ | なし | （即時 throw） | ロガー、安全モード、cleanup ハンドラ登録 |
| ③ プレチェック | **読み取りのみ**（副作用なし） | `2` / `5` / `10` / `20` / **`0`（スキップ）** | 動かして良い状態か、もう完了済みかを判定 |
| ④ メイン処理 | あり | `4` | 実処理。失敗時も ⑤ が必ず走る |
| ⑤ 後処理 | あり | （引き継ぎ） | finally / trap EXIT で確実に実行 |

### 冪等性（③-d）

> 既にスクリプトが目指す状態になっていれば、何もせず正常終了する

| 例 | スキップ条件 |
|---|---|
| AMI バックアップ | 直近 N 分以内に同 NamePrefix の AMI 作成済み |
| サービス起動 | 既に `Running` 状態 |
| サービス停止 | 既に `Stopped` 状態 |
| ログローテート | 対象ファイルが空・閾値未満 |
| ユーザ追加 | 既に存在 |

スキップ時は **エラーではなく `INFO` でスキップ理由を記録し exit 0**。cron や Playbook が「失敗」と誤認しません。

### 終了コード一覧

| Code | 意味 | どのフェーズで |
|---|---|---|
| 0 | 成功 / 冪等スキップ | ③-d / ④ |
| 1 | 入力エラー | ① |
| 2 | 対象リソース不在 | ③-c |
| 3 | リソース状態不正 | ④ |
| 4 | メイン処理操作失敗 | ④ |
| 5 | 外部依存到達不可 | ③-e |
| 10〜 | 環境前提エラー | ③-a |
| 20〜 | 認証・権限エラー | ③-b |

### 必ず出るログ

| タイミング | ログ |
|---|---|
| ① 通過後 | `Args validated: ...` |
| ③ 開始 | `Pre-check start` |
| ③ スキップ | `Skipped (idempotent): reason=...` |
| ③ 通過 | `Pre-check passed` |
| ④ 開始 | `Main start` |
| ④ 完了 | `Main complete` |
| ⑤ 必ず | `Script end: status=<success/failed/skipped> exitCode=<N>` |

## テンプレートはそのまま動く

両テンプレートは **コピー前にそのまま実行できる完全な動作デモ** です。各フェーズに動くダミー処理が入っており、ログ出力で 5 段階の流れと冪等スキップを目視確認できます。

### 動かしてみる

```powershell
# 1 回目：成功（status=success exitCode=0）
powershell.exe tools/templates/Template-Script.ps1 -ParamName demo

# 60 秒以内に再実行：冪等スキップ（status=skipped exitCode=0）
powershell.exe tools/templates/Template-Script.ps1 -ParamName demo
```

```bash
# 1 回目：成功
bash tools/templates/template_script.sh -p demo

# 60 秒以内に再実行：冪等スキップ
bash tools/templates/template_script.sh -p demo
```

### 出力例（1 回目：成功）

```
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Args validated: paramName=demo
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Pre-check start
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Pre-check passed
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Main start
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Wrote scratch file: file=C:\Users\...\Temp\xxx.tmp bytes=64
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Marker updated: marker=C:\Users\...\Temp\template-demo-demo.marker
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Main complete
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Cleanup: removed temp file=C:\Users\...\Temp\xxx.tmp
[2026-05-09 12:14:05] [INFO ] (Template-Script.ps1:1234) Script end: status=success exitCode=0
```

### 出力例（2 回目：冪等スキップ）

```
[2026-05-09 12:14:25] [INFO ] (Template-Script.ps1:1234) Args validated: paramName=demo
[2026-05-09 12:14:25] [INFO ] (Template-Script.ps1:1234) Pre-check start
[2026-05-09 12:14:25] [INFO ] (Template-Script.ps1:1234) Skipped (idempotent): reason=marker_recent marker=... ageSec=20
[2026-05-09 12:14:25] [INFO ] (Template-Script.ps1:1234) Script end: status=skipped exitCode=0
```

## 新規スクリプトを書く手順

1. 適切な配置先にコピー（例：`scripts_windows/aws/Backup-Foo.ps1` または `scripts_linux/aws/backup_foo.sh`）
2. ファイル名と内部のヘッダ（`SYNOPSIS` / `DESCRIPTION` / `Usage` 等）を実際の用途に書き換え
3. **lib のインポートパスを配置深さに合わせて調整**（テンプレ内に "TEMPLATE: adjust ..." コメントあり）
4. **config 名を変更**：`Get-OpsConfig -Name 'Template-Script'` / `load_ops_config "template_script"` の引数を実際のスクリプト名に
5. **config からの上書き対象を追加**（テンプレ内に `# TEMPLATE: copy this pattern` ガイド）。挙動パラメータ（Region、RetentionDays、MaxSizeMB 等）は config 経由にし、per-run の対象（InstanceId、Path 等）は CLI 専用で
6. デモ用の `# DEMO:` コメント部分を **実際のチェック / 処理に置き換え**
   - 3-a：必要モジュール・CLI のチェック
   - 3-b：認証確認（`Get-STSCallerIdentity`、`aws sts get-caller-identity` 等）
   - 3-c：対象リソースの存在確認
   - 3-d：冪等スキップ条件
   - 4：本来の処理に置き換え
7. 実行権限を付与（Bash のみ、`git update-index --chmod=+x`）
8. （推奨）`config/default/<name>.conf` に既定値の雛形を追加
9. （推奨）`docs/scripts/<filename>.md` の個別仕様書も追加

## CI チェック内容

`ci/template-check/check_template.sh` が走査して以下を検証します。

### PowerShell（`scripts_windows/**/*.ps1`）
- `#Requires -Version 5.1` の宣言（以上）
- コメントベースヘルプ（`<# ... #>`）の存在
- `[CmdletBinding(...)]` 属性
- `$ErrorActionPreference = 'Stop'` の設定
- `Set-StrictMode -Version Latest` の設定
- `Logging.psm1` の import

### Bash（`scripts_linux/**/*.sh`）
- 1 行目が `#!/usr/bin/env bash`
- `set -euo pipefail` の設定
- `lib/logging.sh` の source
- 実行ビット（`100755`）が立っていること

> 注意: `tools/` 配下のスタンドアロンツールはこれらのライブラリに依存しない自己完結スクリプトであることを意図しているため、library-import ルールの対象外です。

> 5 フェーズ構造の存在自体は CI では検証していません（運用で守る）。コードレビュー時にレビュアが見てください。

## ローカル実行

```bash
bash ci/template-check/check_template.sh
```

違反があれば `VIOLATION: <file> -- <rule>` 形式で stderr に列挙され、exit 1 になります。

## 違反時の典型的な対処

| メッセージ例 | 対処 |
|---|---|
| `PS: must declare #Requires -Version 5.1` | スクリプトの 1 行目に `#Requires -Version 5.1` を追加 |
| `PS: must import Logging.psm1` | `Logging.psm1` の Import-Module ブロックをテンプレートからコピー |
| `Bash: first non-empty line must be the bash shebang` | 1 行目を `#!/usr/bin/env bash` に変更（`#!/bin/sh` や `#!/bin/bash` は NG） |
| `Bash: must be executable` | `git update-index --chmod=+x <file>` で実行ビット付与 |
