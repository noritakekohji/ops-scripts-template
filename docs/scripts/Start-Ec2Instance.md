# `Start-Ec2Instance.ps1`

> EC2 インスタンスを起動する（複数指定可、冪等）。Windows / PowerShell 版。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/windows/Start-Ec2Instance.ps1
```

| 項目 | 値 |
|---|---|
| 言語 | PowerShell 7+ |
| OS | Windows |
| ペア（Linux 版） | [`start_ec2_instance.sh`](start_ec2_instance.md) |

## 2. 概要

- 1 つ以上の EC2 インスタンスを起動
- **冪等**：すでに `running` / `pending` のインスタンスはスキップ
- `terminated` / `shutting-down` 状態は起動できない → exit 3
- `-Wait` 指定時、すべての対象が `running` になるまで待機（timeout あり）

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | PowerShell 7+ |
| 必須モジュール | `AWS.Tools.EC2`（未導入なら exit 10） |
| 認証 | デフォルト AWS credential chain |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:StartInstances` |

## 4. パラメータ

| 名前 | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-InstanceId` | string[] | ✅ | — | 1 つ以上の EC2 インスタンス ID。`-InstanceId i-0abc,i-0def` で複数指定 |
| `-Region` | string | — | プロファイル既定 | AWS リージョン（config 可） |
| `-Wait` | switch | — | off | 全対象が `running` になるまで待機（config 可） |
| `-WaitTimeoutSec` | int | — | `600` | `-Wait` の最大待機秒数。範囲 30〜3600（config 可） |
| `-WhatIf` / `-Confirm` | switch | — | — | 標準の dry-run / 確認プロンプト |

## 5. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `Region` | string | AWS リージョン |
| `Wait` | bool | `-Wait` の既定値 |
| `WaitTimeoutSec` | int | 待機タイムアウト秒数 |

`config/<env>/Start-Ec2Instance.conf` または `config/<env>/ops.conf` で指定可能。CLI が常に優先。

## 6. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功（`status=success`）または冪等スキップ（`status=skipped`：全インスタンスが既に running） |
| 1 | 入力バリデーション失敗 |
| 2 | インスタンスが見つからない |
| 3 | 待機タイムアウト、または起動できない状態（terminated 等） |
| 4 | `Start-EC2Instance` API 呼び出し失敗 |
| 10 | `AWS.Tools.EC2` モジュール未インストール |
| 20 | 認証・権限エラー |

## 7. 状態遷移ハンドリング

| 現在の状態 | 動作 |
|---|---|
| `running` | スキップ（idempotent） |
| `pending` | スキップ（idempotent） |
| `stopped` | 起動対象 |
| `stopping` | WARN ログ、起動しない |
| `shutting-down` | ERROR、exit 3 |
| `terminated` | ERROR、exit 3 |

## 8. 使用例

### 単一インスタンス
```powershell
.\Start-Ec2Instance.ps1 -InstanceId i-0abc -Wait
```

### 複数インスタンスを一括起動
```powershell
.\Start-Ec2Instance.ps1 -InstanceId i-0abc,i-0def,i-0ghi -Region ap-northeast-1 -Wait
```

### 業務時間前の cron で起動（環境変数で本番環境を選択）
```powershell
$env:OPS_ENV = 'prd'
.\Start-Ec2Instance.ps1 -InstanceId i-0abc,i-0def -Wait
```

## 9. 出力例

### 通常成功
```
[2026-05-09 09:00:01] [INFO ] (Start-Ec2Instance.ps1:4321) Config loaded: env=prd keys=3
[2026-05-09 09:00:01] [INFO ] (Start-Ec2Instance.ps1:4321) Args validated: instanceCount=2 region=ap-northeast-1 wait=True timeoutSec=600
[2026-05-09 09:00:01] [INFO ] (Start-Ec2Instance.ps1:4321) Pre-check start
[2026-05-09 09:00:02] [INFO ] (Start-Ec2Instance.ps1:4321) Pre-check passed: toStart=2 skippedRunning=0
[2026-05-09 09:00:02] [INFO ] (Start-Ec2Instance.ps1:4321) Main start
[2026-05-09 09:00:03] [INFO ] (Start-Ec2Instance.ps1:4321) Start initiated: instanceIds=i-0abc,i-0def count=2
[2026-05-09 09:00:03] [INFO ] (Start-Ec2Instance.ps1:4321) Waiting for 'running': count=2 timeoutSec=600
[2026-05-09 09:00:43] [INFO ] (Start-Ec2Instance.ps1:4321) All instances are running
[2026-05-09 09:00:43] [INFO ] (Start-Ec2Instance.ps1:4321) Main complete
[2026-05-09 09:00:43] [INFO ] (Start-Ec2Instance.ps1:4321) Script end: status=success exitCode=0 started=2 skippedRunning=0
```

### 冪等スキップ（全部すでに running）
```
[2026-05-09 09:05:00] [INFO ] (Start-Ec2Instance.ps1:5678) Args validated: instanceCount=2 ...
[2026-05-09 09:05:01] [INFO ] (Start-Ec2Instance.ps1:5678) Skipped (idempotent): instanceId=i-0abc state=running
[2026-05-09 09:05:01] [INFO ] (Start-Ec2Instance.ps1:5678) Skipped (idempotent): instanceId=i-0def state=running
[2026-05-09 09:05:01] [INFO ] (Start-Ec2Instance.ps1:5678) Skipped (idempotent): reason=all_already_running count=2
[2026-05-09 09:05:01] [INFO ] (Start-Ec2Instance.ps1:5678) Script end: status=skipped exitCode=0 started=0 skippedRunning=2
```

## 10. 関連

- ペア（Linux 版）: [`start_ec2_instance.md`](start_ec2_instance.md)
- 停止スクリプト: [`Stop-Ec2Instance.md`](Stop-Ec2Instance.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)

## 11. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.0 | 2026-05-09 | 初版（5 段階フロー、config 対応、複数インスタンス対応、冪等スキップ） |
