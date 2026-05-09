# `SqlServerCtl.ps1` / `sqlserverctl.sh`

> SQL Server ライフサイクル統合制御：start / stop / restart / status を 1 本で。Windows / Linux 共通仕様。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Windows | `scripts/sqlserver/powershell/SqlServerCtl.ps1` |
| Linux | `scripts/sqlserver/bash/sqlserverctl.sh` |

設定ファイル `config/<env>/sqlserverctl.conf`（Windows / Linux 共有、小文字）。

## 2. 概要

```
<action> <service_name> [options]
```

| Action | Windows | Linux | 冪等スキップ条件 |
|---|---|---|---|
| `start` | `Start-Service` | `systemctl start` | Running / active |
| `stop` | `Stop-Service -Force` | `systemctl stop` | Stopped / inactive |
| `restart` | `Restart-Service -Force` | `systemctl restart` | （冪等性なし） |
| `status` | `Get-Service` | `systemctl is-active` | — |

## 3. SQL Server サービス名

| 環境 | 例 |
|---|---|
| Windows 既定インスタンス | `MSSQLSERVER` |
| Windows 名前付きインスタンス | `MSSQL$PROD` (PowerShell では `'MSSQL$PROD'` のように単一引用符で囲む) |
| Windows SQL Agent | `SQLSERVERAGENT` / `SQLAgent$PROD` |
| Linux | `mssql-server` |

SQL Agent は **本スクリプトの対象外**。必要なら別途 `sqlserverctl <action> SQLSERVERAGENT` のように呼ぶ。

## 4. 前提

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 7+ | Bash 4+ |
| 必要な権限 | サービス制御権（管理者推奨） | sudo / root |
| その他 | SQL Server が **Windows サービスとして稼働** | `mssql-server` の **systemd unit が存在** |

## 5. 引数 / オプション

| 項目 | PowerShell | Bash | 必須 | 既定 | 説明 |
|---|---|---|---|---|---|
| Action | 位置 0 | 位置 1 | ✅ | — | start / stop / restart / status |
| ServiceName | 位置 1 | 位置 2 | ✅ | — | `MSSQLSERVER` / `MSSQL$PROD` / `mssql-server` 等 |
| Wait | `-Wait` | `-w` | — | off | 完了待ち（config 可） |
| WaitTimeoutSec | `-WaitTimeoutSec` | `-t` | — | `120` | 5〜600（config 可、SQL Server は起動が遅いので Tomcat より長め） |

## 6. 設定ファイル

`config/<env>/sqlserverctl.conf`：

| キー | 型 | 説明 |
|---|---|---|
| `Wait` | bool | 完了待ち |
| `WaitTimeoutSec` | int | 待機タイムアウト |

## 7. 終了コード

[`TomcatCtl.md`](TomcatCtl.md#6-終了コード) と同一。

## 8. 使用例

### PowerShell（既定インスタンス）
```powershell
.\SqlServerCtl.ps1 start MSSQLSERVER -Wait
.\SqlServerCtl.ps1 stop  MSSQLSERVER -Wait
.\SqlServerCtl.ps1 restart MSSQLSERVER -Wait
.\SqlServerCtl.ps1 status MSSQLSERVER
```

### PowerShell（名前付きインスタンス）
```powershell
.\SqlServerCtl.ps1 restart 'MSSQL$PROD' -Wait
```

### Bash
```bash
sudo ./sqlserverctl.sh start mssql-server -w
sudo ./sqlserverctl.sh stop  mssql-server -w
sudo ./sqlserverctl.sh restart mssql-server -w
./sqlserverctl.sh status mssql-server
```

## 9. 出力例

```
[... ] (SqlServerCtl.ps1:1234) Args validated: action=restart service=MSSQLSERVER wait=True timeoutSec=120
[... ] (SqlServerCtl.ps1:1234) Current state: service=MSSQLSERVER state=Running
[... ] (SqlServerCtl.ps1:1234) Pre-check passed
[... ] (SqlServerCtl.ps1:1234) restart initiated: service=MSSQLSERVER
[... ] (SqlServerCtl.ps1:1234) Reached target state: service=MSSQLSERVER state=Running
[... ] (SqlServerCtl.ps1:1234) Script end: status=success exitCode=0 action=restart service=MSSQLSERVER before=Running after=Running
```

## 10. 注意事項

- **接続中のクライアントは強制切断される**。stop / restart 前にアプリ側でメンテ告知すること
- `MSSQL$<INSTANCE>` の `$` は PowerShell では変数展開を避けるため **単一引用符** で囲む：`'MSSQL$PROD'`
- SQL Agent サービスは別 unit。SQL Server 本体だけ stop しても Agent は止まらない（依存関係次第で Windows サービスマネージャが連動する）

## 11. 関連

- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)
- Tomcat コントロール: [TomcatCtl.md](TomcatCtl.md)
- EC2 コントロール: [Ec2Ctl.md](Ec2Ctl.md)
