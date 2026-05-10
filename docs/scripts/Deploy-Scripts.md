# `Deploy-Scripts.ps1` / `deploy_scripts.sh`

> リポジトリの `scripts/` / `config/` から指定対象だけを `<opt_root_dir>` 配下にローカル配備する**インストーラ**。Windows / Linux 共通仕様。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Linux | `scripts/linux/bash/deploy_scripts.sh` |
| Windows | `scripts/windows/powershell/Deploy-Scripts.ps1` |

設定ファイル `config/<env>/deploy_scripts.conf`（PS / Bash 共有、小文字）。

## 2. 配備後のレイアウト

```
<opt_root_dir>/
├── bin/        # スクリプト本体（mode 0755）
│   ├── ec2ctl.sh
│   └── Backup-Ami.ps1
└── config/     # 設定ファイル（mode 0644）フラット配置
    ├── global.conf
    ├── ec2ctl.conf
    └── backup_ami.conf
```

**CONF の配備元**：env 未指定 → `config/default/<filename>`、env 指定 → `config/<env>/<filename>`。どちらか一方のみをコピーし、マージは行いません。結果はサブディレクトリなしの `config/<filename>` 1 ファイルになります。

## 3. 前提

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 5.1 以上（7 推奨） | Bash 4+ |
| 必須 CLI | （なし） | `sha256sum`、`cp`、`chmod` |
| 認証 | 配備先パスへの書込み権 | 同左（必要なら sudo） |
| 既定 `<opt_root_dir>` | `C:\ProgramData\ops-scripts` | `/opt/ops-scripts` |

### 3.1 Windows 初回セットアップ（ZIP 展開した場合）

GitHub から ZIP でダウンロードして展開したファイルは、Windows が「インターネット由来」のマークを付けるため、
そのままでは PowerShell のセキュリティポリシーに弾かれます。

**症状：**
```
ファイル ... Deploy-Scripts.ps1 はデジタル署名されていません。
このスクリプトは現在のシステムでは実行できません。
```

**解決策 A：ブロックを一括解除する（推奨）**

リポジトリのルートで一度だけ実行します。以後は通常通り動作します。

```powershell
Get-ChildItem -Path "リポジトリのルートパス" -Recurse -Include "*.ps1","*.psm1" | Unblock-File
```

**解決策 B：実行時に `-ExecutionPolicy Bypass` を付ける（一時的）**

毎回付ける必要があるため、解決策 A を推奨します。

```powershell
powershell.exe -ExecutionPolicy Bypass -File "...\Deploy-Scripts.ps1" -Env dev
```

> **備考：** `install.bat` 経由で実行する場合は `-ExecutionPolicy Bypass` を自動で付けているため、
> この問題は発生しません。`install.bat` の利用を推奨します。

> **備考：** `git clone` で取得した場合はブロックが付かないため、この手順は不要です。

## 4. 引数 / オプション

| 項目 | PowerShell | Bash | 必須 | 説明 |
|---|---|---|---|---|
| PathList | `-PathList <file>` | `-L <file>` | ✅（config 可） | 対象リストファイル |
| OptRoot | `-OptRoot <path>` | `-d <path>` | — | 配備先 root（config の `opt_root_dir` でも可） |
| Env | `-Env <env>` | `-e <env>` | — | 環境名（dev / staging / production など） |
| Backup | `-Backup` | `-b` | — | 上書き前に `<opt_root_dir>/.backup/` に退避 |
| WhatIf / Dry-run | `-WhatIf` | `-n` | — | 実操作なし、ログのみ |

## 5. リストファイル形式

```
# 行頭 '#' はコメント、空行は無視、インラインコメントも可

# CONF: env 未指定 → config/default/<filename>
#       env 指定時 → config/<env>/<filename>
CONF, global.conf
CONF, ec2ctl.conf
CONF, backup_ami.conf

# SRC: scripts/<repo_filepath> → <opt_root_dir>/bin/<basename>
SRC, aws/bash/ec2ctl.sh
SRC, aws/bash/backup_ami.sh
SRC, aws/powershell/Backup-Ami.ps1
```

### TYPE 一覧

| TYPE | コピー元 | コピー先 | パーミッション |
|---|---|---|---|
| `CONF` | env 未指定: `config/default/<filename>`<br>env 指定時: `config/<env>/<filename>` | `<opt_root_dir>/config/<filename>` | 0644 |
| `SRC` | `scripts/<repo_filepath>` | `<opt_root_dir>/bin/<basename>` | 0755 |

カンマ前後のスペースは自由。大文字・小文字どちらでも可（内部で大文字化）。

## 6. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `PathList` | string | リストファイルのパス（リポジトリ root からの相対パスまたは絶対パス） |
| `opt_root_dir` | string | 配備先 root |
| `Backup` | bool | 既存をバックアップ |

## 7. 終了コード

| Code | 意味 |
|---|---|
| 0 | success（全件配備）/ partial（一部失敗）/ skipped（対象ゼロ）|
| 1 | 入力バリデーション失敗 |
| 2 | リストファイル不在 |
| 4 | 全件失敗 |
| 5 | 配備先 `<opt_root_dir>` への書込み不可 |

`partial` は exit 0 だが最終ログの `failed=N` で識別できる。

## 8. 冪等性 / バックアップ

| 状態 | 動作 |
|---|---|
| 配備先に同名ファイルなし | コピー（INFO） |
| 同名・SHA256 一致 | スキップ（INFO `Unchanged`） |
| 同名・差分あり、`-b` 付き | `<opt_root_dir>/.backup/<file>.<JST>` に退避 → 上書き |
| 同名・差分あり、`-b` なし | そのまま上書き（WARN）|

バックアップ命名のタイムスタンプは JST。

## 9. 使用例

### Bash：production 環境に配備
```bash
sudo /path/to/repo/scripts/linux/bash/deploy_scripts.sh \
    -L /etc/ops/deploy.list \
    -e production \
    -b
```

### PowerShell：dev 環境に配備
```powershell
.\Deploy-Scripts.ps1 `
    -PathList C:\ops\deploy.list `
    -Env dev
```

### install ラッパ経由（推奨）
```bash
# Linux
./install.sh production
./install.sh staging -b

# Windows
install.bat dev
install.bat production -Backup
```

### Dry-run で確認
```bash
./install.sh production -n
```
```powershell
install.bat staging -WhatIf
```

## 10. 出力例

```
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Config loaded: env=production keys=2
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Args validated: listFile=/etc/ops/deploy.list optRoot=/opt/ops env=production backup=0 dryRun=0
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Pre-check start
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Pre-check passed: entryCount=5
[2026-05-10 10:00:01] [INFO ] (deploy_scripts.sh:1234) Main start
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../config/default/global.conf dst=/opt/ops/config/global.conf mode=644
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../config/production/global.conf dst=/opt/ops/config/global.conf mode=644
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../config/default/ec2ctl.conf dst=/opt/ops/config/ec2ctl.conf mode=644
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Unchanged: dst=/opt/ops/config/backup_ami.conf
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Backed up: from=/opt/ops/bin/ec2ctl.sh to=/opt/ops/.backup/ec2ctl.sh.20260510-100002
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Deployed: src=.../scripts/aws/bash/ec2ctl.sh dst=/opt/ops/bin/ec2ctl.sh mode=755
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Main complete
[2026-05-10 10:00:02] [INFO ] (deploy_scripts.sh:1234) Script end: status=success exitCode=0 deployed=4 unchanged=1 backedUp=1 failed=0
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
