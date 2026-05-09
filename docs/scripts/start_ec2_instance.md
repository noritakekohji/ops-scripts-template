# `start_ec2_instance.sh`

> EC2 インスタンスを起動する（複数指定可、冪等）。Linux / Bash 版。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/linux/start_ec2_instance.sh
```

| 項目 | 値 |
|---|---|
| 言語 | Bash 4+ |
| OS | Linux |
| ペア（Windows 版） | [`Start-Ec2Instance.ps1`](Start-Ec2Instance.md) |

## 2. 概要

[`Start-Ec2Instance.ps1`](Start-Ec2Instance.md) と同等の機能を Linux / aws CLI で実装。動作・状態遷移ハンドリング・冪等性ルールはすべて Windows 版と同一。

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | Bash 4+ |
| 必須 CLI | `aws`（v2 推奨）、`timeout`（GNU coreutils） |
| 認証 | デフォルト AWS credential chain |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:StartInstances` |

## 4. オプション

| Flag | 引数 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-i` | `<id1,id2,...>` | ✅ | — | カンマ区切りの EC2 インスタンス ID |
| `-r` | `<region>` | — | プロファイル既定 | AWS リージョン（config 可） |
| `-w` | — | — | off | 全対象が `running` になるまで待機（config 可） |
| `-t` | `<sec>` | — | `600` | 待機タイムアウト秒。30〜3600（config 可） |
| `-h` | — | — | — | usage 表示 |

## 5. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `Region` | string | AWS リージョン |
| `Wait` | bool | `-w` の既定値 |
| `WaitTimeoutSec` | int | 待機タイムアウト秒数 |

## 6. 終了コード

[`Start-Ec2Instance.md`](Start-Ec2Instance.md#6-終了コード) と同一。

## 7. 状態遷移ハンドリング

[`Start-Ec2Instance.md`](Start-Ec2Instance.md#7-状態遷移ハンドリング) と同一。

## 8. 使用例

### 単一インスタンス
```bash
./scripts/aws/linux/start_ec2_instance.sh -i i-0abc -w
```

### 複数インスタンス
```bash
./start_ec2_instance.sh -i i-0abc,i-0def,i-0ghi -r ap-northeast-1 -w
```

### 業務時間前 cron（毎平日 09:00）
```cron
0 9 * * 1-5  OPS_ENV=prd /opt/ops-scripts/scripts/aws/linux/start_ec2_instance.sh -i i-0abc,i-0def -w >> /var/log/ops/ec2-start.log 2>&1
```

### systemd timer（毎平日 09:00）
```ini
# /etc/systemd/system/ec2-start.service
[Service]
Type=oneshot
Environment=OPS_ENV=prd
ExecStart=/opt/ops-scripts/scripts/aws/linux/start_ec2_instance.sh -i i-0abc,i-0def -w
```

```ini
# /etc/systemd/system/ec2-start.timer
[Timer]
OnCalendar=Mon..Fri 09:00
[Install]
WantedBy=timers.target
```

## 9. 出力例

```
[2026-05-09 09:00:01] [INFO ] (start_ec2_instance.sh:18342) Config loaded: env=prd keys=3
[2026-05-09 09:00:01] [INFO ] (start_ec2_instance.sh:18342) Args validated: instanceCount=2 region=ap-northeast-1 wait=1 timeoutSec=600
[2026-05-09 09:00:01] [INFO ] (start_ec2_instance.sh:18342) Pre-check start
[2026-05-09 09:00:02] [INFO ] (start_ec2_instance.sh:18342) Pre-check passed: toStart=2 skippedRunning=0
[2026-05-09 09:00:02] [INFO ] (start_ec2_instance.sh:18342) Main start
[2026-05-09 09:00:03] [INFO ] (start_ec2_instance.sh:18342) Start initiated: instanceIds=i-0abc,i-0def count=2
[2026-05-09 09:00:03] [INFO ] (start_ec2_instance.sh:18342) Waiting for 'running': count=2 timeoutSec=600
[2026-05-09 09:00:43] [INFO ] (start_ec2_instance.sh:18342) All instances are running
[2026-05-09 09:00:43] [INFO ] (start_ec2_instance.sh:18342) Script end: status=success exitCode=0 started=2 skippedRunning=0
```

## 10. 関連

- ペア（Windows 版）: [`Start-Ec2Instance.md`](Start-Ec2Instance.md)
- 停止スクリプト: [`stop_ec2_instance.md`](stop_ec2_instance.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)

## 11. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.0 | 2026-05-09 | 初版（5 段階フロー、config 対応、複数インスタンス、冪等スキップ） |
