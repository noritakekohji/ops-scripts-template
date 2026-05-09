# `Stop-Ec2Instance.ps1`

> EC2 インスタンスを停止する（複数指定可、冪等）。Windows / PowerShell 版。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/windows/Stop-Ec2Instance.ps1
```

| 項目 | 値 |
|---|---|
| 言語 | PowerShell 7+ |
| OS | Windows |
| ペア（Linux 版） | [`stop_ec2_instance.sh`](stop_ec2_instance.md) |

## 2. 概要

- 1 つ以上の EC2 インスタンスを停止
- **冪等**：すでに `stopped` / `stopping` のインスタンスはスキップ
- `terminated` / `shutting-down` 状態は exit 3
- `-ForceStop` で強制停止（OS のグレースフル shutdown を待たない、データ損失リスクあり）

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | PowerShell 7+ |
| 必須モジュール | `AWS.Tools.EC2` |
| 認証 | デフォルト AWS credential chain |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:StopInstances` |

## 4. パラメータ

| 名前 | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-InstanceId` | string[] | ✅ | — | 1 つ以上の EC2 インスタンス ID（カンマ区切り） |
| `-Region` | string | — | プロファイル既定 | AWS リージョン（config 可） |
| `-Wait` | switch | — | off | 全対象が `stopped` になるまで待機（config 可） |
| `-WaitTimeoutSec` | int | — | `600` | 待機タイムアウト秒。30〜3600（config 可） |
| `-ForceStop` | switch | — | off | 強制停止。**データ損失の可能性あり** |
| `-WhatIf` / `-Confirm` | switch | — | — | 標準の dry-run / 確認 |

## 5. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `Region` | string | AWS リージョン |
| `Wait` | bool | `-Wait` の既定値 |
| `WaitTimeoutSec` | int | 待機タイムアウト秒数 |
| `ForceStop` | bool | `-ForceStop` の既定値（**通常は false 推奨**） |

## 6. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 / 冪等スキップ（全部すでに stopped） |
| 1 | 入力バリデーション失敗 |
| 2 | インスタンスが見つからない |
| 3 | 待機タイムアウト or 停止できない状態（terminated 等） |
| 4 | `Stop-EC2Instance` API 呼び出し失敗 |
| 10 | `AWS.Tools.EC2` モジュール未インストール |
| 20 | 認証・権限エラー |

## 7. 状態遷移ハンドリング

| 現在の状態 | 動作 |
|---|---|
| `stopped` | スキップ（idempotent） |
| `stopping` | スキップ（idempotent） |
| `running` | 停止対象 |
| `pending` | WARN ログ、停止しない |
| `shutting-down` | ERROR、exit 3 |
| `terminated` | ERROR、exit 3 |

## 8. 使用例

### 単一インスタンス
```powershell
.\Stop-Ec2Instance.ps1 -InstanceId i-0abc -Wait
```

### 業務時間後の cron で停止
```powershell
$env:OPS_ENV = 'prd'
.\Stop-Ec2Instance.ps1 -InstanceId i-0abc,i-0def -Wait
```

### 強制停止（OS が応答しない場合のみ）
```powershell
.\Stop-Ec2Instance.ps1 -InstanceId i-0abc -ForceStop -Wait
```

### 確認のみ
```powershell
.\Stop-Ec2Instance.ps1 -InstanceId i-0abc,i-0def -WhatIf
```

## 9. 出力例

### 通常成功
```
[2026-05-09 21:00:01] [INFO ] (Stop-Ec2Instance.ps1:4321) Config loaded: env=prd keys=3
[2026-05-09 21:00:01] [INFO ] (Stop-Ec2Instance.ps1:4321) Args validated: instanceCount=2 region=ap-northeast-1 wait=True timeoutSec=600 forceStop=False
[2026-05-09 21:00:01] [INFO ] (Stop-Ec2Instance.ps1:4321) Pre-check passed: toStop=2 skippedStopped=0
[2026-05-09 21:00:02] [INFO ] (Stop-Ec2Instance.ps1:4321) Stop initiated: instanceIds=i-0abc,i-0def count=2 force=False
[2026-05-09 21:00:02] [INFO ] (Stop-Ec2Instance.ps1:4321) Waiting for 'stopped': count=2 timeoutSec=600
[2026-05-09 21:01:42] [INFO ] (Stop-Ec2Instance.ps1:4321) All instances are stopped
[2026-05-09 21:01:42] [INFO ] (Stop-Ec2Instance.ps1:4321) Script end: status=success exitCode=0 stopped=2 skippedStopped=0
```

### 冪等スキップ
```
[2026-05-09 21:05:00] [INFO ] (Stop-Ec2Instance.ps1:5678) Skipped (idempotent): instanceId=i-0abc state=stopped
[2026-05-09 21:05:00] [INFO ] (Stop-Ec2Instance.ps1:5678) Skipped (idempotent): instanceId=i-0def state=stopped
[2026-05-09 21:05:00] [INFO ] (Stop-Ec2Instance.ps1:5678) Skipped (idempotent): reason=all_already_stopped count=2
[2026-05-09 21:05:00] [INFO ] (Stop-Ec2Instance.ps1:5678) Script end: status=skipped exitCode=0 stopped=0 skippedStopped=2
```

## 10. 注意事項

- **`-ForceStop` はデータ損失のリスク**：通常は使わない。OS シャットダウンが応答しないインスタンスを最後の手段で停止する場合のみ
- 停止中（`stopping` 状態）の場合は二度目の Stop API 呼び出しは無意味なのでスキップする設計
- `Stop-EC2Instance` の課金停止は `stopped` になった時点から（`stopping` 中は EBS 課金のみ継続）

## 11. 関連

- ペア（Linux 版）: [`stop_ec2_instance.md`](stop_ec2_instance.md)
- 起動スクリプト: [`Start-Ec2Instance.md`](Start-Ec2Instance.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)

## 12. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.0 | 2026-05-09 | 初版（5 段階フロー、config 対応、複数インスタンス、冪等スキップ、`-ForceStop`） |
