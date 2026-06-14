# Network Connectivity Check Tools

サーバーから複数の接続先に対し、DNS / Ping / TCPポート の疎通確認をまとめて行うツールです。
**このフォルダ一式をコピーするだけで動きます。**

```
tools/network-check/
├── Check-NetworkConnectivity.ps1   # Windows PowerShell 本体
├── Check-NetworkConnectivity.bat   # Windows 起動用バッチ
├── check_network_connectivity.sh   # Linux Bash
├── targets.lst                     # 接続先リストファイル（サンプル）
├── targets-editor.xlsm             # targets.lst 編集用 Excel マクロブック
├── targets-editor.bas              # 上記の VBA ソース（真実の源）
└── build_targets_editor.ps1        # .bas から .xlsm を再生成するビルドスクリプト
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

2 形式をサポートします（混在可）。同じホスト名を持つ行は DNS / Ping を 1 回だけ実行し、TCP のみサービス単位で繰り返します。

### 4-field 形式（期待値付き評価）

```
# <host>, <port>, <expected>, <description>
#   expected: ok (到達するはず) / ng (到達しないはず) / - (評価しない)
#   port:     TCP ポート番号、または '-' で Ping のみ

8.8.8.8,    -, ok, Google DNS Primary (ping)
google.com, 443, ok, HTTPS
google.com,  22, ng, SSH (should be blocked)
```

### 3-field 形式（評価なし、後方互換）

```
# <host>, <port>, <description>

example.com,  443, HTTPS
192.168.1.1,    -, Default Gateway
```

---

## 使い方

### Windows

```cmd
:: バッチ起動（推奨。ログは <スクリプト名>_<日時>.log に Transcript されます）
Check-NetworkConnectivity.bat -TargetList targets.lst
```

```powershell
# PowerShell 直接実行
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

## コンソール出力例（実装イメージ）

ホスト単位のヘッダ行に DNS / Ping、続いてサービスごとの TCP 行を出力します。

```
[HOST] google.com
  DNS  : OK  142.250.196.110
  Ping : OK  21ms avg (4/4)
  [443/TCP] HTTPS         : OK   expected=ok  -> OK
  [80/TCP ] HTTP          : OK   expected=ok  -> OK
  [22/TCP ] SSH           : NG   expected=ng  -> OK (unreachable as expected)

──────────────────────────────────────────────────
  Hosts: 3   Services: 5   OK: 4   NG: 1   Warning: 0
```

---

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 全て OK（Warning なし） |
| 1 | 1 件以上 Failed |
| 2 | リストファイルが見つからない |
| 10 | 前提コマンドが見つからない |

---

## targets.lst を Excel で作る（targets-editor.xlsm）

`targets-editor.xlsm` を開き、`Targets` シートに入力して
「Export targets.lst」ボタンを押すと 4-field 形式の targets.lst を出力します。

| 列 | 内容 |
|---|---|
| Enabled | `on` / `off`（ドロップダウン）。`on` の行のみ targets.lst に出力。`off` / 空欄はスキップ |
| Section | 出力時に `# ---- <Section> ----` コメントになるグループ名（任意） |
| Host | ホスト名または IP（必須） |
| Port | TCP ポート番号、または `-`（Ping のみ）。空欄は `-` 扱い |
| Expected | `ok` / `ng` / `-`（ドロップダウン。空欄は `-` 扱い） |
| Description | 説明 |

- 出力は **UTF-8（BOM なし）+ LF**。リポジトリの LF 統一規約に準拠します
- 不正な入力（Enabled 不正、Host 空欄、Port 範囲外、Expected 不正、セルのエラー値）は
  赤くハイライトされ、修正するまでエクスポートされません
- 一時的に対象から外したい行は Enabled を `off` にすれば、行を削除せずスキップできます
- 注意: Description に `#` を含めると、パーサ側でコメントとして切り詰められます

### マクロを修正するとき

真実の源は `targets-editor.bas` です。`.bas` を編集してから
`build_targets_editor.ps1` で `.xlsm` を再生成してください
（要 Excel + 「VBA プロジェクト オブジェクト モデルへのアクセスを信頼する」設定。
ビルド後は設定を元に戻して構いません）。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build_targets_editor.ps1
```
