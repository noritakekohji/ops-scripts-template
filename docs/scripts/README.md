# スクリプト別仕様書

各スクリプトの個別仕様書。共通の規約は [shell-specification.md](../../shell-specification.md) を参照してください。

## AWS バックアップ

| 機能 | Windows | Linux |
|---|---|---|
| AMI バックアップ | [Backup-Ami.md](Backup-Ami.md) | [backup_ami.md](backup_ami.md) |
| EBS スナップショット | [Backup-EbsSnapshot.md](Backup-EbsSnapshot.md) | [backup_ebs_snapshot.md](backup_ebs_snapshot.md) |

## AWS EC2 ライフサイクル

| 機能 | Windows | Linux |
|---|---|---|
| EC2 起動 | [Start-Ec2Instance.md](Start-Ec2Instance.md) | [start_ec2_instance.md](start_ec2_instance.md) |
| EC2 停止 | [Stop-Ec2Instance.md](Stop-Ec2Instance.md) | [stop_ec2_instance.md](stop_ec2_instance.md) |

## ログ運用

| 機能 | Windows | Linux |
|---|---|---|
| ログローテーション | [Rotate-Log.md](Rotate-Log.md) | [rotate_log.md](rotate_log.md) |
