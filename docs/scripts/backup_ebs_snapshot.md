# `backup_ebs_snapshot.sh`

> EBS ボリュームのスナップショットを作成し、世代を超えた古いスナップショットを自動削除する（Linux / Bash 版）。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/linux/backup_ebs_snapshot.sh
```

| 項目 | 値 |
|---|---|
| 言語 | Bash（`set -euo pipefail`） |
| OS | Linux |
| ペア（Windows 版） | [`Backup-EbsSnapshot.ps1`](Backup-EbsSnapshot.md) |

## 2. 概要

[`Backup-EbsSnapshot.ps1`](Backup-EbsSnapshot.md) と同等の機能を Linux / aws CLI で実装したもの。動作・タグ・命名規則・pruning ルールはすべて Windows 版と同じ。

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | Bash 4+ |
| 必須 CLI | `aws`（v2 推奨）、`date`（GNU coreutils） |
| 認証 | デフォルト AWS credential chain |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:DescribeVolumes`、`ec2:CreateSnapshot`、`ec2:DescribeSnapshots`、`ec2:CreateTags`、（pruning 利用時）`ec2:DeleteSnapshot` |

## 4. オプション

| Flag | 引数 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-v` | `<volume-id>` | △ | — | 単一 EBS ボリューム ID。`^vol-[0-9a-f]{8,17}$`。`-i` と排他 |
| `-i` | `<instance-id>` | △ | — | このインスタンスにアタッチされた全 EBS をスナップショット |
| `-p` | `<name-prefix>` | ✅ | — | スナップショット Name タグと pruning フィルタ |
| `-r` | `<region>` | — | プロファイル既定 | AWS リージョン |
| `-d` | `<days>` | — | `0` | Retention days（0〜3650） |
| `-m` | `<minutes>` | — | `5` | 直近 N 分以内に同 NamePrefix のスナップショットが存在すれば**冪等スキップ**。0 で無効。範囲 0〜1440 |
| `-w` | — | — | off | 全スナップショットが `completed` になるまで待機 |
| `-h` | — | — | — | usage 表示 |

`-v` か `-i` のいずれか一方が必須。

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功（`status=success`）または冪等スキップ（`status=skipped`） |
| 1 | usage / バリデーション失敗 |
| 2 | インスタンス不在、または EBS 未アタッチ |
| 3 | スナップショットが期限内に完了しない |
| 4 | `aws ec2 create-snapshot` 失敗 |
| 10 | `aws` CLI 未インストール |
| 20 | 認証・権限エラー |

## 6. スナップショットに付与されるタグ

[`Backup-EbsSnapshot.md`](Backup-EbsSnapshot.md) と同一。

## 7. 使用例

### 単一ボリューム
```bash
./scripts/aws/linux/backup_ebs_snapshot.sh -v vol-0abc -p prod-db -d 14
```

### インスタンス配下の全 EBS
```bash
./backup_ebs_snapshot.sh -i i-0abc -p prod-app -w
```

### Region 指定 + 30 日保持
```bash
./backup_ebs_snapshot.sh -i i-0abc -p prod-app -r ap-northeast-1 -d 30 -w
```

### cron 例（毎日 02:00）
```cron
0 2 * * *  /opt/ops-scripts/scripts/aws/linux/backup_ebs_snapshot.sh -i i-0abc -p prod-db-daily -d 7 -w >> /var/log/ops/backup-ebs.log 2>&1
```

## 8. 出力例

### 通常成功
```
[2026-05-09 12:14:05] [INFO ] (backup_ebs_snapshot.sh:23501) Args validated: prefix=prod-app region=ap-northeast-1 retention=14 minIntervalMin=5
[2026-05-09 12:14:05] [INFO ] (backup_ebs_snapshot.sh:23501) Pre-check start
[2026-05-09 12:14:06] [INFO ] (backup_ebs_snapshot.sh:23501) Pre-check passed: volumeCount=2
[2026-05-09 12:14:06] [INFO ] (backup_ebs_snapshot.sh:23501) Main start
[2026-05-09 12:14:07] [INFO ] (backup_ebs_snapshot.sh:23501) Snapshot initiated: snapshot=snap-0xyz1 volume=vol-0abc1
[2026-05-09 12:14:08] [INFO ] (backup_ebs_snapshot.sh:23501) Snapshot initiated: snapshot=snap-0xyz2 volume=vol-0abc2
[2026-05-09 12:14:08] [INFO ] (backup_ebs_snapshot.sh:23501) Waiting for 2 snapshot(s) to complete
[2026-05-09 12:18:23] [INFO ] (backup_ebs_snapshot.sh:23501) All snapshots completed
[2026-05-09 12:18:24] [INFO ] (backup_ebs_snapshot.sh:23501) Pruning snapshots older than 2026-04-25T03:14:05 for prefix 'prod-app'
[2026-05-09 12:18:25] [INFO ] (backup_ebs_snapshot.sh:23501) Deleted snapshot: snap-0old
[2026-05-09 12:18:25] [INFO ] (backup_ebs_snapshot.sh:23501) Main complete
[2026-05-09 12:18:25] [INFO ] (backup_ebs_snapshot.sh:23501) Script end: status=success exitCode=0 created=2
```

### 冪等スキップ
```
[2026-05-09 12:16:00] [INFO ] (backup_ebs_snapshot.sh:30122) Args validated: prefix=prod-app region=ap-northeast-1 retention=14 minIntervalMin=5
[2026-05-09 12:16:00] [INFO ] (backup_ebs_snapshot.sh:30122) Pre-check start
[2026-05-09 12:16:00] [INFO ] (backup_ebs_snapshot.sh:30122) Skipped (idempotent): reason=recent_snapshot_exists snapshotId=snap-0xyz1 startedAt=2026-05-09T03:14:07.000Z minIntervalMin=5
[2026-05-09 12:16:00] [INFO ] (backup_ebs_snapshot.sh:30122) Script end: status=skipped exitCode=0 created=0
```

## 9. 関連

- ペア（Windows 版）: [`Backup-EbsSnapshot.md`](Backup-EbsSnapshot.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
- AMI 側: [`backup_ami.md`](backup_ami.md)

