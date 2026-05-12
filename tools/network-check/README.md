# Network Connectivity Check Tools

サーバーから複数の接続先に対し、DNS / Ping / TCPポート の疎通確認をまとめて行うツールです。
**このフォルダの 3 ファイルをコピーするだけで動きます。**

```
tools/network-check/
├── Check-NetworkConnectivity.ps1   # Windows PowerShell
├── check_network_connectivity.sh   # Linux Bash
└── targets.lst                     # 接続先リストファイル（サンプル）
```

---

## チェック内容

| チェック | 内容 | IP 指定時 |
|---|---|---|
| **DNS** | ホスト名 → IP への名前解決 | スキップ（N/A） |
| **Ping** | ICMP による疎通確認（複数回） | 実行 |
| **Port** | TCP ポートへの接続確認 | 実行 |

---

## 前提

| ツール | 必要なもの |
|---|---|
| `Check-NetworkConnectivity.ps1` | Windows PowerShell 5.1+ |
| `check_network_connectivity.sh` | Bash 4+、python3、ping コマンド |

---

## リストファイル形式

```
# <host>, <port>, <description>
#   port に '-' または空白 → Ping のみ（ポートチェックなし）

8.8.8.8,       53,  Google DNS
example.com,   80,  HTTP
example.com,  443,  HTTPS
192.168.1.1,    -,  Default Gateway
```

---

## 使い方

### Windows

```powershell
# 基本実行
.\Check-NetworkConnectivity.ps1 -TargetList targets.lst

# HTML レポートも生成
.\Check-NetworkConnectivity.ps1 -TargetList targets.lst -HtmlReport report.html

# 失敗・警告のみ表示
.\Check-NetworkConnectivity.ps1 -TargetList targets.lst -FailOnly

# Ping 回数・タイムアウトを変更
.\Check-NetworkConnectivity.ps1 -TargetList targets.lst -PingCount 5 -TimeoutSec 5
```

### Linux

```bash
# 実行権限付与（初回のみ）
chmod +x check_network_connectivity.sh

# 基本実行
./check_network_connectivity.sh -l targets.lst

# HTML レポートも生成
./check_network_connectivity.sh -l targets.lst -o report.html

# 失敗・警告のみ表示
./check_network_connectivity.sh -l targets.lst -f

# Ping 回数・タイムアウトを変更
./check_network_connectivity.sh -l targets.lst -c 5 -t 5
```

---

## コンソール出力例

```
=== Network Connectivity Check ===
  List    : targets.lst
  Targets : 5

[OK  ] 8.8.8.8                   Google DNS Primary
         DNS  : ─  N/A (IP address)
         Ping : ✓  6ms avg (3/3)
         Port : ✓  53/TCP connected

[FAIL] db.internal               MySQL
         DNS  : ✗  Name or service not known
         Ping : ✗  (0/3)
         Port : ✗  3306/TCP - Timeout

──────────────────────────────────────────────────
  Total: 5   OK: 3   Warning: 1   Failed: 1
```

---

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 全て OK（Warning なし） |
| 1 | 1 件以上 Failed |
| 2 | リストファイルが見つからない |
| 10 | 前提コマンドが見つからない |
