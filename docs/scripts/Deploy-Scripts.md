# `Deploy-Scripts.ps1` / `deploy_scripts.sh`

> リポジトリの `scripts/` / `config/` / `lib/` / `tests/` から指定対象だけを `<opt_root>` 配下にローカル配備する**インストーラ**。Windows / Linux 共通仕様。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Linux | `scripts/linux/bash/deploy_scripts.sh` |
| Windows | `scripts/windows/powershell/Deploy-Scripts.ps1` |

設定ファイル `config/<env>/deploy_scripts.conf`（PS / Bash 共有、小文字）。

## 2. 配備後のレイアウト

サーバ OS は 1 種類なのでフラット：

```
<opt_root>/
├── script/                 # 実スクリプト本体（mode 0755）
│   ├── backup_ami.sh       # Linux 例
│   └── ec2ctl.sh
├── conf/                   # 設定ファイル（mode 0644）フラット配置
│   ├── ops.conf            # default を基底に env で上書き済み
│   ├── backup_ami.conf
│   └── ec2ctl.conf
├── tests/                  # ユニットテスト（mode 0755、`-m with-tests` or `all` の場合のみ）
└── lib/                    # 共通ライブラリ（必須付帯）
    └── bash/               # または powershell/
```

**conf のマージ方針**：`config/default/<name>.conf` をコピーした後、`-e <env>`（または `OPS_ENV`）が指定されていれば `config/<env>/<name>.conf` で上書きします。結果はサブディレクトリなしの `conf/<name>.conf` 1 ファイルになります。

配備時にスクリプト内の lib import パスを書換えます：
- Bash：`source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"` → `source "${SCRIPT_DIR}/../lib/bash/logging.sh"`
- PS：`Join-Path $PSScriptRoot '..' '..' '..' 'lib' ...` → `Join-Path $PSScriptRoot '..' 'lib' ...`

リポジトリ側は変更されません（コピー後のファイルのみを書換え）。

## 3. 前提

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 7+ | Bash 4+ |
| 必須 CLI | （なし） | `sha256sum`、`find`、`cp`、`chmod`、`sed` |
| 認証 | 配備先パスへの書込み権 | 同左（必要なら sudo） |
| 既定 `<opt_root>` | `C:\ProgramData\ops-scripts` | `/opt/ops-scripts` |

## 4. 引数 / オプション

| 項目 | PowerShell | Bash | 必須 | 既定 | 説明 |
|---|---|---|---|---|---|
| PathList | `-PathList <file>` | `-L <file>` | ✅ | — | 対象スクリプトのリストファイル |
| OptRoot | `-OptRoot <path>` | `-d <path>` | — | OS 別 | 配備先 root |
| Env | `-Env <env>` | `-e <env>` | — | `$OPS_ENV`（未設定時は default のみ）| 環境名。dev / staging / production など |
| Mode | `-Mode <mode>` | `-m <mode>` | — | `with-config` | 既定 mode |
| Backup | `-Backup` | `-b` | — | off | 上書き前に `<opt_root>/.backup/` に退避 |
| WhatIf / Dry-run | `-WhatIf` | `-n` | — | off | 実操作なし、ログのみ |

### Mode 一覧

| Mode | 配備内容 |
|---|---|
| `script-only` | 本体スクリプトのみ |
| `with-config`（既定） | スクリプト + `conf/<name>.conf`（default → env マージ済み）|
| `with-tests` | スクリプト + 対応するテスト |
| `all` | スクリプト + conf + tests |

## 5. リストファイル形式

```
# 行頭 '#' はコメント、空行は無視
# <name> [Key=Value ...]

# 拡張子省略可。Bash 側は backup_ami.sh が、PS 側は Backup-Ami.ps1 が解決される
backup_ami
ec2ctl
rotate_log

# 行内で挙動を上書き
sqlserverctl    Mode=all                     # script + conf + tests
tomcatctl       Mode=script-only             # script のみ

# 名前解決を上書き（リポジトリ root からの相対パス）
my_special_script  Path=scripts/aws/bash/my_special_script.sh

# 別 conf 名にエイリアス
my_script  Conf=shared.conf  Tests=my_script_smoke.bats
```

### 受け付ける Key

| キー | 説明 |
|---|---|
| `Mode` | `script-only` / `with-config` / `with-tests` / `all` |
| `Path` | 明示的な repo 相対パス（再帰検索を回避） |
| `Conf` | 既定の `<stem>.conf` 以外の名前を指定 |
| `Tests` | 既定の `<stem>.bats` / `<Stem>.Tests.ps1` 以外の名前を指定 |

### 名前解決ルール

| 入力 | Linux 側 (`.sh`) | Windows 側 (`.ps1`) |
|---|---|---|
| `backup_ami.sh` | `scripts/**/backup_ami.sh` | — |
| `Backup-Ami.ps1` | — | `scripts/**/Backup-Ami.ps1` |
| `backup_ami`（拡張子省略）| `backup_ami.sh` | `backup_ami.ps1` → 見つからなければ `Backup-Ami.ps1` 試行 |

複数マッチ時は WARN を出して**先頭採用**。明示したい場合は行内 `Path=...` を使う。

## 6. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `OptRoot` | string | 配備先 root |
| `Mode` | enum | 既定 mode |
| `Backup` | bool | 既存をバックアップ |

## 7. 終了コード

| Code | 意味 |
|---|---|
| 0 | success（全件配備）/ partial（一部失敗）/ skipped（対象ゼロ）|
| 1 | 入力バリデーション失敗 |
| 2 | リストファイル不在 |
| 4 | 全件失敗 |
| 5 | 配備先 `<opt_root>` への書込み不可 |

`partial` は exit 0 だが最終ログの `failed=N` で識別できる。

## 8. 冪等性 / バックアップ

| 状態 | 動作 |
|---|---|
| 配備先に同名ファイルなし | コピー（INFO） |
| 同名・SHA256 一致 | スキップ（INFO `Unchanged`） |
| 同名・差分あり、`-b` 付き | `<opt_root>/.backup/<file>.<JST>` に退避 → 上書き |
| 同名・差分あり、`-b` なし | そのまま上書き（WARN）|

バックアップ命名のタイムスタンプは JST。

## 9. 使用例

### Bash：production 用に最小配備（conf は default + production でマージ）
```bash
# /etc/ops-scripts/deploy.list
# backup_ami
# ec2ctl
# rotate_log

sudo /opt/ops-scripts-src/scripts/linux/bash/deploy_scripts.sh \
    -L /etc/ops-scripts/deploy.list \
    -e production \
    -m with-config \
    -b
```

### PowerShell：dev 環境に全部入り
```powershell
.\Deploy-Scripts.ps1 `
    -PathList C:\ops\deploy.list `
    -Env dev `
    -Mode all `
    -Backup
```

### Dry-run で何が起こるか確認
```bash
deploy_scripts.sh -L /etc/ops-scripts/deploy.list -n
```
```powershell
.\Deploy-Scripts.ps1 -PathList C:\ops\deploy.list -WhatIf
```

## 10. 出力例

```
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Config loaded: env=production keys=4
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Args validated: listFile=/etc/ops-scripts/deploy.list optRoot=/opt/ops-scripts env=production mode=with-config backup=1 dryRun=0
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Pre-check start
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Repo root: /opt/ops-scripts-src
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Pre-check passed: entryCount=3
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Main start
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../backup_ami.sh dst=/opt/ops-scripts/script/backup_ami.sh mode=755
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../config/default/backup_ami.conf dst=/opt/ops-scripts/conf/backup_ami.conf mode=644
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../config/production/backup_ami.conf dst=/opt/ops-scripts/conf/backup_ami.conf mode=644
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Unchanged: dst=/opt/ops-scripts/conf/ops.conf
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Backed up: from=/opt/ops-scripts/script/ec2ctl.sh to=/opt/ops-scripts/.backup/ec2ctl.sh.20260510-100002
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../ec2ctl.sh dst=/opt/ops-scripts/script/ec2ctl.sh mode=755
[2026-05-10 10:00:03] [INFO ] (deploy_scripts.sh:1234) Deploying lib/bash
[2026-05-10 10:00:03] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../lib/bash/logging.sh dst=/opt/ops-scripts/lib/bash/logging.sh mode=644
[2026-05-10 10:00:03] [INFO ] (deploy_scripts.sh:1234) Main complete
[2026-05-10 10:00:03] [INFO ] (deploy_scripts.sh:1234) Script end: status=success exitCode=0 deployed=9 unchanged=1 backedUp=1 failed=0
```

## 11. v1 で含めない（今後の拡張余地）

- リモート配備（SSH / rsync） — 現在はローカルのみ
- ロールバック専用コマンド（`-b` のバックアップから手動で戻すことは可能）
- 配備済みだがリストから外れたファイルの掃除
- 署名・チェックサム検証（一致確認は SHA256 で実施しているが、改ざん検知は別途）

## 12. 関連

- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)
- 各スクリプト仕様書: [docs/scripts/README.md](README.md)
