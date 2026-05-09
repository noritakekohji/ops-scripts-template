# スクリプト別仕様書

各スクリプトの個別仕様書。共通の規約は [shell-specification.md](../../shell-specification.md) を参照してください。

## AWS バックアップ

| 機能 | Windows | Linux |
|---|---|---|
| AMI バックアップ | [Backup-Ami.md](Backup-Ami.md) | [backup_ami.md](backup_ami.md) |
| EBS スナップショット | [Backup-EbsSnapshot.md](Backup-EbsSnapshot.md) | [backup_ebs_snapshot.md](backup_ebs_snapshot.md) |

## AWS EC2 ライフサイクル

| 機能 | スクリプト | 仕様書（PS / Bash 共通） |
|---|---|---|
| EC2 統合制御（start / stop / restart / status） | `Ec2Ctl.ps1` / `ec2ctl.sh` | [Ec2Ctl.md](Ec2Ctl.md) |

## ミドルウェア制御

| 機能 | スクリプト | 仕様書 |
|---|---|---|
| Tomcat 統合制御（start / stop / restart / status） | `TomcatCtl.ps1` / `tomcatctl.sh` | [TomcatCtl.md](TomcatCtl.md) |
| SQL Server 統合制御（start / stop / restart / status） | `SqlServerCtl.ps1` / `sqlserverctl.sh` | [SqlServerCtl.md](SqlServerCtl.md) |

## ログ運用

| 機能 | Windows | Linux |
|---|---|---|
| ログローテーション | [Rotate-Log.md](Rotate-Log.md) | [rotate_log.md](rotate_log.md) |

## ストレージ

| 機能 | スクリプト | 仕様書 |
|---|---|---|
| S3 アップロード（リストファイル + per-entry options） | `S3Upload.ps1` / `s3upload.sh` | [S3Upload.md](S3Upload.md) |

## デプロイ

| 機能 | スクリプト | 仕様書 |
|---|---|---|
| ローカル配備（`<opt_root>` 配下に script / conf / lib / tests を再配置） | `Deploy-Scripts.ps1` / `deploy_scripts.sh` | [Deploy-Scripts.md](Deploy-Scripts.md) |
