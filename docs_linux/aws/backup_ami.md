# `backup_ami.sh`

> EC2 インスタンスから AMI を作成し、世代を超えた古い AMI を自動削除する（Linux / Bash 版）。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/bash/backup_ami.sh
```

| 項目 | 値 |
|---|---|
| 言語 | Bash（`#!/usr/bin/env bash`、`set -euo pipefail`） |
| OS | Linux |
| ペア（Windows 版） | [`Backup-Ami.ps1`](Backup-Ami.md) |

## 2. 概要

[`Backup-Ami.ps1`](Backup-Ami.md) と同等の機能を Linux / aws CLI で実装したもの。動作・タグ・命名規則・pruning ルールはすべて Windows 版と同じ。

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | Bash 4+（連想配列を一部使用） |
| 必須 CLI | `aws`（v2 推奨）、`date`（GNU coreutils） |
| 認証 | デフォルト AWS credential chain（環境変数 / プロファイル / IAM ロール） |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:CreateImage`、`ec2:DescribeImages`、`ec2:CreateTags`、（pruning 利用時）`ec2:DeregisterImage`、`ec2:DeleteSnapshot` |

## 4. オプション

| Flag | 引数 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-i` | `<instance-id>` | ✅ | — | EC2 インスタンス ID。`^i-[0-9a-f]{8,17}$` |
| `-p` | `<name-prefix>` | ✅ | — | AMI 名 prefix と pruning フィルタ |
| `-r` | `<region>` | — | プロファイル既定 | AWS リージョン |
| `-d` | `<days>` | — | `0` | Retention days（0〜3650）、0 で pruning 無効 |
| `-m` | `<minutes>` | — | `5` | 直近 N 分以内に同 NamePrefix の AMI が存在すれば**冪等スキップ**。0 で無効。範囲 0〜1440 |
| `-R` | — | — | off（`--no-reboot`） | リブート許可（クラッシュ整合性が許容できない場合） |
| `-w` | — | — | off | AMI が `available` になるまで待機（`aws ec2 wait image-available`） |
| `-h` | — | — | — | usage を表示 |

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功（`status=success`）または冪等スキップ（`status=skipped`） |
| 1 | usage / 入力バリデーション失敗 |
| 2 | インスタンスが見つからない / アクセス不可 |
| 3 | AMI が `available` に到達しない |
| 4 | `aws ec2 create-image` 失敗 |
| 10 | `aws` CLI 未インストール |
| 20 | 認証・権限エラー |

## 6. AMI に付与されるタグ

[`Backup-Ami.md`](Backup-Ami.md) と同一。

## 7. 使用例

### 基本
```bash
./scripts/aws/bash/backup_ami.sh -i i-0abcdef0123456789 -p prod-web
```

### 完了待ち + 7 世代保持
```bash
./backup_ami.sh -i i-0abc -p prod-web -d 7 -w
```

### Region 指定
```bash
./backup_ami.sh -i i-0abc -p prod-web -r ap-northeast-1 -d 30 -w
```

### cron 例（毎日 03:00 に実行）
```cron
0 3 * * *  /opt/ops-scripts/scripts/aws/bash/backup_ami.sh -i i-0abc -p prod-web-daily -d 14 -w >> /var/log/ops/backup-ami.log 2>&1
```

## 8. 出力例

### 通常成功
```
[2026-05-09 12:14:05] [INFO ] (backup_ami.sh:18342) Args validated: instance=i-0abc prefix=prod-web region=ap-northeast-1 retention=7 minIntervalMin=5
[2026-05-09 12:14:05] [INFO ] (backup_ami.sh:18342) Pre-check start
[2026-05-09 12:14:06] [INFO ] (backup_ami.sh:18342) Pre-check passed
[2026-05-09 12:14:06] [INFO ] (backup_ami.sh:18342) Main start
[2026-05-09 12:14:08] [INFO ] (backup_ami.sh:18342) AMI creation initiated: ami_id=ami-0xyz name=prod-web-20260509-031405
[2026-05-09 12:14:08] [INFO ] (backup_ami.sh:18342) Waiting for AMI to become available: ami-0xyz
[2026-05-09 12:18:12] [INFO ] (backup_ami.sh:18342) AMI is available: ami-0xyz
[2026-05-09 12:18:13] [INFO ] (backup_ami.sh:18342) Pruning AMIs older than 2026-05-02T03:14:05 for prefix 'prod-web'
[2026-05-09 12:18:14] [INFO ] (backup_ami.sh:18342) Deregistered AMI: ami-0old
[2026-05-09 12:18:15] [INFO ] (backup_ami.sh:18342) Deleted snapshot: snap-0old
[2026-05-09 12:18:15] [INFO ] (backup_ami.sh:18342) Main complete
[2026-05-09 12:18:15] [INFO ] (backup_ami.sh:18342) Script end: status=success exitCode=0 amiId=ami-0xyz
```

### 冪等スキップ
```
[2026-05-09 12:16:00] [INFO ] (backup_ami.sh:24891) Args validated: instance=i-0abc prefix=prod-web region=ap-northeast-1 retention=7 minIntervalMin=5
[2026-05-09 12:16:00] [INFO ] (backup_ami.sh:24891) Pre-check start
[2026-05-09 12:16:00] [INFO ] (backup_ami.sh:24891) Skipped (idempotent): reason=recent_ami_exists amiId=ami-0xyz createdAt=2026-05-09T03:14:08.000Z minIntervalMin=5
[2026-05-09 12:16:00] [INFO ] (backup_ami.sh:24891) Script end: status=skipped exitCode=0 amiId=
```

## 9. 関連

- ペア（Windows 版）: [`Backup-Ami.md`](Backup-Ami.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
- ロガー: [`lib/bash/logging.sh`](../../lib/bash/logging.sh)

