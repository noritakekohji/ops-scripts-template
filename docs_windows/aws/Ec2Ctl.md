# `Ec2Ctl.ps1` / `ec2ctl.sh`

> EC2 ライフサイクル統合制御：start / stop / restart / status を 1 本で。Windows / Linux 共通仕様。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Windows | `scripts_windows/aws/Ec2Ctl.ps1` |
| Linux | `scripts_linux/aws/ec2ctl.sh` |

> Windows のケース非依存 FS で衝突するため、本仕様書 1 本で PS / Bash 両方を兼ねます。設定ファイル `config/<env>/ec2ctl.conf` も PS / Bash 共有（小文字統一）。

## 2. 概要

```
<action> <instance_id[,instance_id,...]> [options]
```

| Action | 動作 | 冪等スキップ条件 |
|---|---|---|
| `start` | 停止インスタンスを起動 | running / pending |
| `stop` | 起動インスタンスを停止（強制可） | stopped / stopping |
| `restart` | running を Reboot API で再起動 | （冪等性なし、running 必須） |
| `status` | 状態表示（read-only） | — |

`terminated` / `shutting-down` 状態は exit 3。

## 3. 前提

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 5.1+ | Bash 4+ |
| 必須 | `AWS.Tools.EC2` | `aws` CLI v2、`timeout` |
| 認証 | デフォルト AWS credential chain |
| IAM | `ec2:DescribeInstances` + 操作別（`StartInstances` / `StopInstances` / `RebootInstances`） |

## 4. 引数 / オプション

| 項目 | PowerShell | Bash | 必須 | 既定 | 説明 |
|---|---|---|---|---|---|
| Action | `-Action`（位置 0） | 第 1 位置引数 | ✅ | — | start / stop / restart / status |
| InstanceId | `-InstanceId`（位置 1） | 第 2 位置引数 | ✅ | — | カンマ区切りで複数可 |
| Region | `-Region` | `-r` | — | プロファイル既定 | config 可 |
| Wait | `-Wait` | `-w` | — | off | 完了待ち（restart/status は無視）、config 可 |
| WaitTimeoutSec | `-WaitTimeoutSec` | `-t` | — | `600` | 30〜3600、config 可 |
| ForceStop | `-ForceStop` | `-F` | — | off | stop 時のみ。**通常 false 推奨**、config 可 |
| Help / dry-run | `-WhatIf` / `-Confirm` | `-h` | — | — | |

## 5. 設定ファイル

`config/<env>/ec2ctl.conf`（PS / Bash 共有）：

| キー | 型 | 説明 |
|---|---|---|
| `Region` | string | AWS リージョン |
| `Wait` | bool | 完了待ち |
| `WaitTimeoutSec` | int | 待機タイムアウト |
| `ForceStop` | bool | 強制停止 |

## 6. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 / 冪等スキップ |
| 1 | 入力バリデーション失敗 |
| 2 | インスタンスが見つからない |
| 3 | 操作不能な状態 / 待機タイムアウト |
| 4 | API 呼び出し失敗 |
| 10 | aws CLI / AWS.Tools.EC2 未インストール |
| 20 | 認証・権限エラー |

## 7. 使用例

### PowerShell
```powershell
.\Ec2Ctl.ps1 start i-0abc -Wait
.\Ec2Ctl.ps1 start i-0abc,i-0def,i-0ghi -Region ap-northeast-1 -Wait
.\Ec2Ctl.ps1 stop  i-0abc -ForceStop -Wait
.\Ec2Ctl.ps1 restart i-0abc
.\Ec2Ctl.ps1 status i-0abc,i-0def
```

### Bash
```bash
./ec2ctl.sh start i-0abc -w
./ec2ctl.sh start i-0abc,i-0def,i-0ghi -r ap-northeast-1 -w
./ec2ctl.sh stop  i-0abc -F -w
./ec2ctl.sh restart i-0abc
./ec2ctl.sh status i-0abc,i-0def
```

### cron（業務時間に合わせて起動・停止）
```cron
0  9 * * 1-5  OPS_ENV=production /opt/ops-scripts/scripts_linux/aws/ec2ctl.sh start i-0abc,i-0def -w
0 21 * * 1-5  OPS_ENV=production /opt/ops-scripts/scripts_linux/aws/ec2ctl.sh stop  i-0abc,i-0def -w
```

## 8. 出力例

### 通常成功
```
[... ] (ec2ctl.sh:1234) Args validated: action=start instanceCount=2 region=ap-northeast-1 wait=1 timeoutSec=600 forceStop=0
[... ] (ec2ctl.sh:1234) Pre-check passed: action=start toAct=2 skipped=0
[... ] (ec2ctl.sh:1234) Start initiated: instanceIds=i-0abc,i-0def count=2
[... ] (ec2ctl.sh:1234) All instances reached 'running'
[... ] (ec2ctl.sh:1234) Script end: status=success exitCode=0 action=start acted=2 skipped=0
```

### 冪等スキップ
```
[... ] Skipped (idempotent): instanceId=i-0abc state=running
[... ] Skipped (idempotent): reason=all_already_in_target_state action=start count=1
[... ] Script end: status=skipped exitCode=0 action=start acted=0 skipped=1
```

### status
```
[... ] Status: instanceId=i-0abc state=running az=ap-northeast-1a launchTime=2026-05-09T01:00:00.000Z
[... ] Status: instanceId=i-0def state=stopped az=ap-northeast-1c launchTime=2026-05-08T23:00:00.000Z
[... ] Script end: status=success exitCode=0 action=status acted=0 skipped=0
```

## 9. 注意事項

- `restart` は AWS Reboot API（state は `running` のまま、観測可能な状態変化なし）。`-Wait` は無視
- `-ForceStop` / `-F` は OS のグレースフル shutdown を待たない → **データ損失リスク**
- インスタンス課金は `stopped` になった時点で停止（`stopping` 中は EBS 課金継続）

## 10. 関連

- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)

