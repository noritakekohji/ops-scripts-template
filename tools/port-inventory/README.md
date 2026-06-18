# port-inventory

待受ポート棚卸し・監査ツール。

**このフォルダ一式をコピーすれば動きます。**

```
tools/port-inventory/
├── PortInventory.ps1     # Windows 本体
├── port_inventory.bat    # Windows 起動用バッチ
├── port_inventory.sh     # Linux 本体（ss / netstat）
└── expected_ports.lst    # 期待ポートリスト（サンプル）
```

---

## 前提

| 実行環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+ |
| Linux   | Bash 4+, `ss` または `netstat` |

---

## 動作モード

### 棚卸しモード（expected list なし）

LISTEN 状態の TCP/UDP ポートを一覧表示します。プロセス名・実行パスも解決します。
常に終了コード 0 で終了します。

### 監査モード（expected list あり）

期待ポートリストと実際のポートを突き合わせ、OK / NG / WARN / INFO を判定します。

---

## 期待ポートリストの書式

`expected_ports.lst` に 1 行 1 エントリで記述します。

```
<port>, <proto>, <expected>, <description>
```

| フィールド | 説明 |
|---|---|
| port | ポート番号 |
| proto | `tcp` または `udp` |
| expected | `ok`（LISTEN すべき）/ `ng`（LISTEN すべきでない）/ `-`（情報のみ） |
| description | 任意のラベル |

- `#` で始まる行はコメント。空行はスキップ

```
# ---- SSH ----
22,   tcp, ok, SSH Server

# ---- Web Services ----
80,   tcp, ok, HTTP
443,  tcp, ok, HTTPS

# ---- Database ----
# 1433, tcp, ng, SQL Server (should not be exposed)
```

---

## 使い方

### 棚卸しモード（ポート一覧のみ）

```powershell
# Windows
.\port_inventory.bat
```

```bash
# Linux
./port_inventory.sh
```

### 監査モード（期待リストと突き合わせ）

```powershell
# Windows
.\port_inventory.bat -ExpectedList expected_ports.lst
```

```bash
# Linux
./port_inventory.sh -e expected_ports.lst
```

### JSON 出力

```powershell
# Windows
.\port_inventory.bat -ExpectedList expected_ports.lst -Json
```

```bash
# Linux
./port_inventory.sh -e expected_ports.lst --json
```

### HTML レポート出力

```powershell
# Windows
.\port_inventory.bat -ExpectedList expected_ports.lst -HtmlReport report.html
```

```bash
# Linux
./port_inventory.sh -e expected_ports.lst --html report.html
```

### NG / WARN のみ表示

```powershell
# Windows
.\port_inventory.bat -ExpectedList expected_ports.lst -FailOnly
```

```bash
# Linux
./port_inventory.sh -e expected_ports.lst --fail-only
```

### オプション組み合わせ

```powershell
# Windows: HTML レポート + NG/WARN のみ
.\port_inventory.bat -ExpectedList expected_ports.lst -HtmlReport report.html -FailOnly
```

```bash
# Linux: JSON + NG/WARN のみ
./port_inventory.sh -e expected_ports.lst --json --fail-only
```

### 保存済み JSON からレポート再生成（Windows のみ）

過去に `-Json` で保存した結果を読み込み、収集せずにレポートを再生成できます。

```powershell
.\PortInventory.ps1 -FromJson saved.json -Json
.\PortInventory.ps1 -FromJson saved.json -HtmlReport report.html
.\PortInventory.ps1 -FromJson saved.json -FailOnly
```

判定（OK/NG/WARN/INFO）は JSON に保存された値をそのまま使うため、期待値リストは不要です。

---

## 出力モード

| モード | Windows オプション | Linux オプション | 説明 |
|---|---|---|---|
| コンソールテーブル | (既定) | (既定) | ターミナルに整形テーブルを出力 |
| JSON | `-Json` | `--json` | JSON 配列として標準出力 |
| HTML レポート | `-HtmlReport <path>` | `--html <path>` | HTML ファイルを生成 |

---

## 判定ロジック

| 判定 | 条件 | 説明 |
|---|---|---|
| **OK** | expected=`ok` かつ実際に LISTEN している | 期待通りにポートが開いている |
| **NG** | expected=`ok` だが LISTEN していない | 開いているべきポートが閉じている |
| **NG** | expected=`ng` かつ実際に LISTEN している | 閉じるべきポートが開いている |
| **WARN** | expected=`ng` だが LISTEN していない | 期待通り閉じているが注意対象 |
| **INFO** | expected=`-` | 情報のみ（判定なし） |

---

## 終了コード

| Code | 意味 |
|---|---|
| 0  | 全て OK、または棚卸しモード（判定なし） |
| 1  | NG が 1 件以上 |
| 2  | 期待ポートリストファイルが見つからない |
| 10 | 前提コマンド不足（ss / netstat 等） |

---

## Windows フォールバック

ポート収集は `Get-NetTCPConnection` / `Get-NetUDPEndpoint` を優先的に使用します。
AppLocker や GPO でこれらがブロックされている環境では、`netstat -ano` + `Win32_Process` CIM に自動フォールバックします。

---

## バージョン

変更履歴は [CHANGELOG.md](../../CHANGELOG.md) を参照してください。
