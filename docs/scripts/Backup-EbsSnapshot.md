# `Backup-EbsSnapshot.ps1`

> EBS ボリュームのスナップショットを作成し、世代を超えた古いスナップショットを自動削除する（Windows / PowerShell 版）。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/windows/Backup-EbsSnapshot.ps1
```

| 項目 | 値 |
|---|---|
| 言語 | PowerShell 7+ |
| OS | Windows |
| ペア（Linux 版） | [`backup_ebs_snapshot.sh`](backup_ebs_snapshot.md) |

## 2. 概要

- 単一の EBS ボリューム（`-VolumeId`）または EC2 インスタンスにアタッチされた全ボリューム（`-InstanceId`）をスナップショット化
- スナップショットには `CreatedBy=ops-scripts`、`NamePrefix`、`RetentionDays`、`SourceVolumeId` 等のタグを必ず付与
- `-RetentionDays` 指定時、同じ NamePrefix の古いスナップショットを削除
- `-Wait` 指定時、全スナップショットが `completed` になるまで待機

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | PowerShell 7+ |
| 必須モジュール | `AWS.Tools.EC2`（未インストール時は exit 10） |
| 認証 | デフォルト AWS credential chain |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:DescribeVolumes`、`ec2:CreateSnapshot`、`ec2:DescribeSnapshots`、`ec2:CreateTags`、（pruning 利用時）`ec2:DeleteSnapshot` |

## 4. パラメータ

| 名前 | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-VolumeId` | string | △ | — | 単一ボリューム ID。`^vol-[0-9a-f]{8,17}$`。`-InstanceId` と排他 |
| `-InstanceId` | string | △ | — | このインスタンスにアタッチされた全 EBS をスナップショット。`^i-[0-9a-f]{8,17}$` |
| `-NamePrefix` | string | ✅ | — | スナップショット Name タグと pruning フィルタ |
| `-Region` | string | — | プロファイル既定 | AWS リージョン |
| `-RetentionDays` | int | — | `0` | 古いスナップショットを削除する閾値日数。0〜3650 |
| `-Wait` | switch | — | off | 全スナップショットが `completed` になるまで待機 |
| `-WhatIf` / `-Confirm` | switch | — | — | 標準の dry-run / 確認プロンプト |

`-VolumeId` か `-InstanceId` のいずれか一方が必須（ParameterSet 強制）。

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 2 | インスタンス不在、または EBS ボリューム未アタッチ |
| 3 | スナップショットが `error` 状態に到達 |
| 4 | `New-EC2Snapshot` API 呼び出し失敗 |
| 10 | `AWS.Tools.EC2` モジュール未インストール |

## 6. スナップショットに付与されるタグ

| Key | Value |
|---|---|
| `Name` | `<NamePrefix>-<VolumeId>-<UTC yyyyMMdd-HHmmss>` |
| `CreatedBy` | `ops-scripts` |
| `CreatedAt` | UTC `yyyyMMdd-HHmmss` |
| `SourceVolumeId` | バックアップ元ボリューム ID |
| `NamePrefix` | 引数 `-NamePrefix` の値 |
| `RetentionDays` | 引数 `-RetentionDays` の値（文字列） |

Pruning は **`tag:CreatedBy=ops-scripts` AND `tag:NamePrefix=<指定値>`** の AND 条件で対象を絞る。

## 7. 使用例

### 単一ボリュームをスナップショット
```powershell
.\Backup-EbsSnapshot.ps1 -VolumeId vol-0abc -NamePrefix prod-db -RetentionDays 14
```

### インスタンス配下の全 EBS を一括スナップショット
```powershell
.\Backup-EbsSnapshot.ps1 -InstanceId i-0abc -NamePrefix prod-app -Wait
```

### Region 指定 + 30 日保持
```powershell
.\Backup-EbsSnapshot.ps1 -InstanceId i-0abc -NamePrefix prod-app `
    -Region ap-northeast-1 -RetentionDays 30 -Wait
```

## 8. 出力例

```
[2026-05-09 12:14:05] [INFO ] (Backup-EbsSnapshot.ps1:2412) Resolving volumes for instance: instanceId=i-0abc
[2026-05-09 12:14:06] [INFO ] (Backup-EbsSnapshot.ps1:2412) EBS snapshot start: namePrefix=prod-app region=ap-northeast-1 retentionDays=14 volumeCount=2
[2026-05-09 12:14:07] [INFO ] (Backup-EbsSnapshot.ps1:2412) Snapshot initiated: snapshotId=snap-0xyz1 volumeId=vol-0abc1
[2026-05-09 12:14:08] [INFO ] (Backup-EbsSnapshot.ps1:2412) Snapshot initiated: snapshotId=snap-0xyz2 volumeId=vol-0abc2
[2026-05-09 12:14:08] [INFO ] (Backup-EbsSnapshot.ps1:2412) Waiting for snapshots to complete: count=2
[2026-05-09 12:18:23] [INFO ] (Backup-EbsSnapshot.ps1:2412) All snapshots completed
[2026-05-09 12:18:24] [INFO ] (Backup-EbsSnapshot.ps1:2412) Pruning old snapshots: namePrefix=prod-app retentionDays=14
[2026-05-09 12:18:25] [INFO ] (Backup-EbsSnapshot.ps1:2412) Deleted snapshot: snapshotId=snap-0old startedAt=2026-04-25T03:14:05.000Z
[2026-05-09 12:18:25] [INFO ] (Backup-EbsSnapshot.ps1:2412) EBS snapshot backup complete: created=2
```

## 9. 関連

- ペア（Linux 版）: [`backup_ebs_snapshot.md`](backup_ebs_snapshot.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
- AMI 側: [`Backup-Ami.md`](Backup-Ami.md)（AMI 経由で EBS もまとめてバックアップしたい場合）

## 10. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.1 | 2026-05-09 | ロガー仕様 v1.0 に合わせて Message 埋め込みに統一 |
| v1.0 | 2026-05-09 | 初版 |
