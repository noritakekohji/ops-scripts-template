# `stop_ec2_instance.sh`

> EC2 インスタンスを停止する（複数指定可、冪等）。Linux / Bash 版。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/aws/linux/stop_ec2_instance.sh
```

| 項目 | 値 |
|---|---|
| 言語 | Bash 4+ |
| OS | Linux |
| ペア（Windows 版） | [`Stop-Ec2Instance.ps1`](Stop-Ec2Instance.md) |

## 2. 概要

[`Stop-Ec2Instance.ps1`](Stop-Ec2Instance.md) と同等の機能を Linux / aws CLI で実装。動作・状態遷移ハンドリング・冪等性ルールはすべて Windows 版と同一。

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | Bash 4+ |
| 必須 CLI | `aws`（v2 推奨）、`timeout`（GNU coreutils） |
| 認証 | デフォルト AWS credential chain |
| 必要 IAM 権限 | `ec2:DescribeInstances`、`ec2:StopInstances` |

## 4. オプション

| Flag | 引数 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-i` | `<id1,id2,...>` | ✅ | — | カンマ区切りの EC2 インスタンス ID |
| `-r` | `<region>` | — | プロファイル既定 | AWS リージョン（config 可） |
| `-w` | — | — | off | 全対象が `stopped` になるまで待機（config 可） |
| `-t` | `<sec>` | — | `600` | 待機タイムアウト秒。30〜3600（config 可） |
| `-F` | — | — | off | 強制停止（config 可、**通常 false 推奨**） |
| `-h` | — | — | — | usage 表示 |

## 5. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `Region` | string | AWS リージョン |
| `Wait` | bool | `-w` の既定値 |
| `WaitTimeoutSec` | int | 待機タイムアウト秒数 |
| `ForceStop` | bool | `-F` の既定値 |

## 6. 終了コード

[`Stop-Ec2Instance.md`](Stop-Ec2Instance.md#6-終了コード) と同一。

## 7. 状態遷移ハンドリング

[`Stop-Ec2Instance.md`](Stop-Ec2Instance.md#7-状態遷移ハンドリング) と同一。

## 8. 使用例

### 単一インスタンス
```bash
./scripts/aws/linux/stop_ec2_instance.sh -i i-0abc -w
```

### 業務時間後 cron（毎平日 21:00）
```cron
0 21 * * 1-5  OPS_ENV=prd /opt/ops-scripts/scripts/aws/linux/stop_ec2_instance.sh -i i-0abc,i-0def -w >> /var/log/ops/ec2-stop.log 2>&1
```

### 強制停止
```bash
./stop_ec2_instance.sh -i i-0abc -F -w
```

## 9. 出力例

```
[2026-05-09 21:00:01] [INFO ] (stop_ec2_instance.sh:18342) Config loaded: env=prd keys=3
[2026-05-09 21:00:01] [INFO ] (stop_ec2_instance.sh:18342) Args validated: instanceCount=2 region=ap-northeast-1 wait=1 timeoutSec=600 forceStop=0
[2026-05-09 21:00:01] [INFO ] (stop_ec2_instance.sh:18342) Pre-check passed: toStop=2 skippedStopped=0
[2026-05-09 21:00:02] [INFO ] (stop_ec2_instance.sh:18342) Stop initiated: instanceIds=i-0abc,i-0def count=2 force=0
[2026-05-09 21:00:02] [INFO ] (stop_ec2_instance.sh:18342) Waiting for 'stopped': count=2 timeoutSec=600
[2026-05-09 21:01:42] [INFO ] (stop_ec2_instance.sh:18342) All instances are stopped
[2026-05-09 21:01:42] [INFO ] (stop_ec2_instance.sh:18342) Script end: status=success exitCode=0 stopped=2 skippedStopped=0
```

## 10. 注意事項

- **`-F` はデータ損失リスク**：通常は使わない
- 課金は `stopped` になった時点から停止（`stopping` 中は EBS 課金継続）

## 11. 関連

- ペア（Windows 版）: [`Stop-Ec2Instance.md`](Stop-Ec2Instance.md)
- 起動スクリプト: [`start_ec2_instance.md`](start_ec2_instance.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)

## 12. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.0 | 2026-05-09 | 初版 |
