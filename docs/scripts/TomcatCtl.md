# `TomcatCtl.ps1` / `tomcatctl.sh`

> Tomcat ライフサイクル統合制御：start / stop / restart / status を 1 本で。Windows / Linux 共通仕様。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Windows | `scripts/tomcat/powershell/TomcatCtl.ps1` |
| Linux | `scripts/tomcat/bash/tomcatctl.sh` |

設定ファイル `config/<env>/tomcatctl.conf`（Windows / Linux 共有、小文字）。

## 2. 概要

```
<action> <service_name> [options]
```

| Action | Windows | Linux | 冪等スキップ条件 |
|---|---|---|---|
| `start` | `Start-Service` | `systemctl start` | Running / active |
| `stop` | `Stop-Service -Force` | `systemctl stop` | Stopped / inactive |
| `restart` | `Restart-Service -Force` | `systemctl restart` | （冪等性なし、常時実行） |
| `status` | `Get-Service` | `systemctl is-active` | — |

## 3. 前提

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 7+ | Bash 4+ |
| 必要な権限 | サービス制御権（管理者推奨） | sudo / root（systemctl のため） |
| その他 | Tomcat が **Windows サービスとしてインストール済み** | Tomcat の **systemd unit が存在** |

Windows でサービス未登録の場合（catalina.bat 直起動）はサポート外。サービス化（`service.bat install`）してから本スクリプトを使用する。

## 4. 引数 / オプション

| 項目 | PowerShell | Bash | 必須 | 既定 | 説明 |
|---|---|---|---|---|---|
| Action | 位置 0 | 位置 1 | ✅ | — | start / stop / restart / status |
| ServiceName | 位置 1 | 位置 2 | ✅ | — | サービス名（例：`Tomcat10` / `tomcat10`） |
| Wait | `-Wait` | `-w` | — | off | 完了待ち（config 可） |
| WaitTimeoutSec | `-WaitTimeoutSec` | `-t` | — | `60` | 5〜600（config 可） |

## 5. 設定ファイル

`config/<env>/tomcatctl.conf`：

| キー | 型 | 説明 |
|---|---|---|
| `Wait` | bool | 完了待ち |
| `WaitTimeoutSec` | int | 待機タイムアウト |

## 6. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 / 冪等スキップ |
| 1 | 入力バリデーション失敗 |
| 2 | サービスが見つからない |
| 3 | 待機タイムアウト |
| 4 | サービス制御コマンド失敗 |
| 10 | systemctl 未インストール（Linux のみ） |

## 7. 使用例

### PowerShell
```powershell
.\TomcatCtl.ps1 start Tomcat10 -Wait
.\TomcatCtl.ps1 stop  Tomcat10 -Wait
.\TomcatCtl.ps1 restart Tomcat10 -Wait
.\TomcatCtl.ps1 status Tomcat10
```

### Bash
```bash
sudo ./tomcatctl.sh start tomcat10 -w
sudo ./tomcatctl.sh stop  tomcat10 -w
sudo ./tomcatctl.sh restart tomcat10 -w
./tomcatctl.sh status tomcat10
```

## 8. 出力例

```
[... ] (tomcatctl.sh:1234) Args validated: action=start service=tomcat10 wait=1 timeoutSec=60
[... ] (tomcatctl.sh:1234) Current state: service=tomcat10 state=inactive
[... ] (tomcatctl.sh:1234) Pre-check passed
[... ] (tomcatctl.sh:1234) start initiated: service=tomcat10
[... ] (tomcatctl.sh:1234) Main complete: service=tomcat10 state=active
[... ] (tomcatctl.sh:1234) Script end: status=success exitCode=0 action=start service=tomcat10 before=inactive after=active
```

冪等スキップ：
```
[... ] Current state: service=tomcat10 state=active
[... ] Skipped (idempotent): service=tomcat10 state=active
[... ] Script end: status=skipped exitCode=0 action=start service=tomcat10 before=active after=active
```

## 9. 関連

- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)
- EC2 コントロール（参考）: [Ec2Ctl.md](Ec2Ctl.md)
- SQL Server コントロール: [SqlServerCtl.md](SqlServerCtl.md)
