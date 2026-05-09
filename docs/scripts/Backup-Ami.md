# `Backup-Ami.ps1`

> EC2 インスタンスから AMI を作成し、世代を超えた古い AMI を自動削除する（Windows / PowerShell 版）。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/windows/Backup-Ami.ps1
```

| 項目 | 値 |
|---|---|
| 言語 | PowerShell 7+ |
| OS | Windows |
| ペア（Linux 版） | [`backup_ami.sh`](backup_ami.md) |

## 2. 概要

- 指定した EC2 インスタンスから AMI（Amazon Machine Image）を作成する
- AMI には `CreatedBy=ops-scripts`、`NamePrefix`、`RetentionDays` 等のタグを必ず付与する
- `-RetentionDays` 指定時、同じ NamePrefix の古い AMI（と背後の EBS スナップショット）を deregister / 削除する
- `-Wait` 指定時、AMI が `available` になるまで待機

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | PowerShell 7+ |
| 必須モジュール | `AWS.Tools.EC2`（未インストール時は exit 10） |
| 認証 | デフォルト AWS credential chain（環境変数 / プロファイル / IAM ロール） |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:CreateImage`、`ec2:DescribeImages`、`ec2:CreateTags`、（pruning 利用時）`ec2:DeregisterImage`、`ec2:DeleteSnapshot` |

## 4. パラメータ

| 名前 | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-InstanceId` | string | ✅ | — | 対象 EC2 インスタンス ID。`^i-[0-9a-f]{8,17}$` |
| `-NamePrefix` | string | ✅ | — | AMI 名の prefix と pruning フィルタ。`^[A-Za-z0-9][A-Za-z0-9._-]{1,120}$` |
| `-Region` | string | — | プロファイル既定 | AWS リージョン |
| `-NoReboot` | bool | — | `$true` | `$false` でリブート許可（クラッシュ整合性が許容できない場合） |
| `-RetentionDays` | int | — | `0` | 古い AMI を deregister する閾値日数。0 で pruning 無効。範囲 0〜3650 |
| `-Wait` | switch | — | off | AMI が `available` になるまで待機 |
| `-WhatIf` / `-Confirm` | switch | — | — | 標準の dry-run / 確認プロンプト |

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 2 | インスタンスが見つからない |
| 3 | AMI が `available` に到達しない（Wait 中タイムアウト or `failed` 状態） |
| 10 | `AWS.Tools.EC2` モジュール未インストール |

## 6. AMI に付与されるタグ

| Key | Value |
|---|---|
| `Name` | `<NamePrefix>-<UTC yyyyMMdd-HHmmss>` |
| `CreatedBy` | `ops-scripts` |
| `CreatedAt` | UTC `yyyyMMdd-HHmmss` |
| `SourceInstanceId` | 元の EC2 インスタンス ID |
| `NamePrefix` | 引数 `-NamePrefix` の値 |
| `RetentionDays` | 引数 `-RetentionDays` の値（文字列） |

Pruning は **`tag:CreatedBy=ops-scripts` AND `tag:NamePrefix=<指定値>`** の AND 条件で対象を絞るため、手動作成 AMI を誤って削除することはない。

## 7. 使用例

### 基本：単発バックアップ
```powershell
.\scripts\aws\windows\Backup-Ami.ps1 `
    -InstanceId i-0abcdef0123456789 `
    -NamePrefix prod-web
```

### 完了待ち + 7 世代保持
```powershell
.\Backup-Ami.ps1 -InstanceId i-0abc -NamePrefix prod-web -RetentionDays 7 -Wait
```

### リージョン明示 + Dry-run
```powershell
.\Backup-Ami.ps1 -InstanceId i-0abc -NamePrefix prod-web -Region ap-northeast-1 -WhatIf
```

### 月次 cron（タスクスケジューラ）想定
```powershell
.\Backup-Ami.ps1 -InstanceId i-0abc -NamePrefix prod-web-monthly -RetentionDays 90 -Region ap-northeast-1
```

## 8. 出力例

```
[2026-05-09 12:14:05] [INFO ] (Backup-Ami.ps1:1234) AMI backup start: instanceId=i-0abc namePrefix=prod-web region=ap-northeast-1 noReboot=True retentionDays=7
[2026-05-09 12:14:08] [INFO ] (Backup-Ami.ps1:1234) AMI creation initiated: amiId=ami-0xyz amiName=prod-web-20260509-031405
[2026-05-09 12:18:12] [INFO ] (Backup-Ami.ps1:1234) AMI state polled: amiId=ami-0xyz state=available
[2026-05-09 12:18:13] [INFO ] (Backup-Ami.ps1:1234) Pruning old AMIs: namePrefix=prod-web retentionDays=7
[2026-05-09 12:18:14] [INFO ] (Backup-Ami.ps1:1234) Deregistered AMI: amiId=ami-0old createdAt=2026-05-01T03:14:05.000Z
[2026-05-09 12:18:15] [INFO ] (Backup-Ami.ps1:1234) Deleted snapshot: snapshotId=snap-0old
[2026-05-09 12:18:15] [INFO ] (Backup-Ami.ps1:1234) AMI backup complete: amiId=ami-0xyz
```

## 9. 関連

- ペア（Linux 版）: [`backup_ami.md`](backup_ami.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
- ロガー: [`lib/powershell/Logging.psm1`](../../lib/powershell/Logging.psm1)

## 10. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.1 | 2026-05-09 | ロガー仕様 v1.0 に合わせて `-Properties` 廃止、Message 内埋め込みに統一 |
| v1.0 | 2026-05-09 | 初版 |
