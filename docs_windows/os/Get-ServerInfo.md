# `Get-ServerInfo.ps1` / `get_server_info.sh`

> Windows / Linux サーバーの設定情報を収集し、JSON ファイルに出力する。`Compare-ServerInfo.ps1` と組み合わせて現新比較に使う。

[← 仕様書一覧](README.md) | [← 共通仕様](../../shell-specification.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Windows | `scripts/windows/powershell/Get-ServerInfo.ps1` |
| Linux | `scripts/linux/bash/get_server_info.sh` |

設定ファイル: `config/<env>/get_server_info.conf`

---

## 2. 収集カテゴリ

| カテゴリ | 内容 |
|---|---|
| `os` | OS バージョン、ホスト名、タイムゾーン、ロケール、メモリ |
| `network` | IP アドレス、ルーティング、DNS、hosts ファイル |
| `services` | サービス一覧（名前、状態、起動設定） |
| `packages` | インストール済みパッケージ一覧（名前、バージョン） |
| `users` | ローカルユーザー、グループ、メンバー |
| `filesystem` | ドライブ / マウントポイントの使用状況 |
| `environment` | システム環境変数 |
| `security` | ファイアウォール設定（Windows Defender 含む） |

---

## 3. パラメータ / オプション

### Windows（PowerShell）

| パラメータ | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-Category` | string[] | — | `all` | 収集カテゴリ（複数可） |
| `-OutputPath` | string | — | `<hostname>_<timestamp>.json` | JSON 出力先 |

### Linux（Bash）

| オプション | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `-c <categories>` | — | `all` | カンマ区切りカテゴリ |
| `-o <path>` | — | `<hostname>_<timestamp>.json` | JSON 出力先 |
| `-h` | — | — | ヘルプ表示 |

---

## 4. 前提条件

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 5.1+ | Bash 4+、**python3** |
| 必要権限 | 一般ユーザー可（管理者で実行するとより多くの情報を取得） | 一般ユーザー可（firewall は sudo が必要な場合あり） |

> Linux は `python3` が必須です（Amazon Linux 2+、RHEL 8+、Ubuntu 18+ で標準搭載）。

---

## 5. 出力 JSON フォーマット

```json
{
  "meta": {
    "hostname":     "server01",
    "os_type":      "windows",
    "collected_at": "2026-05-12T10:00:00+09:00",
    "categories":   ["os", "network", "services"]
  },
  "os": {
    "hostname":       "server01",
    "os_name":        "Windows Server 2022 Datacenter",
    "os_version":     "10.0.20348",
    "timezone":       "Tokyo Standard Time",
    "total_memory_gb": 16.0
  },
  "services": [
    { "name": "Tomcat10", "status": "running", "start_type": "auto" }
  ]
}
```

---

## 6. 使用例

### 全カテゴリを収集

```powershell
# Windows
.\Get-ServerInfo.ps1
.\Get-ServerInfo.ps1 -OutputPath C:\temp\server-before.json
```

```bash
# Linux
./get_server_info.sh
./get_server_info.sh -o /tmp/server-before.json
```

### 特定カテゴリのみ収集

```powershell
.\Get-ServerInfo.ps1 -Category os,network,services
```

```bash
./get_server_info.sh -c os,network,services
```

---

## 7. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 4 | 収集処理エラー |
| 10 | 前提条件不足（python3 未インストール等） |

---

## 8. 関連

- 比較ツール: [`Compare-ServerInfo.md`](Compare-ServerInfo.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
