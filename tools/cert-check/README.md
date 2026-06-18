# cert-check

TLS 証明書の有効期限チェックツール。

**このフォルダ一式をコピーすれば動きます。**

```
tools/cert-check/
├── CertCheck.ps1       # Windows 本体（.NET SslStream で証明書取得）
├── cert_check.bat      # Windows 起動用バッチ
├── cert_check.sh       # Linux 本体（openssl s_client で証明書取得）
└── cert_targets.lst    # チェック対象リスト（サンプル）
```

---

## 前提

| 実行環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+ |
| Linux   | Bash 4+, `openssl` |

---

## ターゲットリストの書式

`cert_targets.lst` に 1 行 1 エントリで記述します。

```
<host>, <port>, <warn_days>, <description>
```

| フィールド | 既定値 | 説明 |
|---|---|---|
| host | (必須) | ホスト名または IP アドレス |
| port | `443` | TCP ポート番号（省略または `-` で既定値） |
| warn_days | `30` | 警告しきい値（残り日数）（省略または `-` で既定値） |
| description | (空) | 任意のラベル |

- `#` で始まる行はコメント。空行はスキップ
- `# ---- Section Name ----` 形式のコメントはセクション見出しとして出力をグループ化

```
# ---- Public Web Services ----
google.com,      443, 30, Google HTTPS
github.com,      443, 30, GitHub HTTPS

# ---- Internal Services ----
app.internal.example.com,  443, 60, App Server
db.internal.example.com,  5432, 30, PostgreSQL TLS
```

---

## 使い方

### 基本（コンソールテーブル出力）

```powershell
# Windows
.\cert_check.bat -TargetList cert_targets.lst
```

```bash
# Linux
./cert_check.sh -t cert_targets.lst
```

### JSON 出力

```powershell
# Windows
.\cert_check.bat -TargetList cert_targets.lst -Json
```

```bash
# Linux
./cert_check.sh -t cert_targets.lst --json
```

### HTML レポート出力

```powershell
# Windows
.\cert_check.bat -TargetList cert_targets.lst -HtmlReport report.html
```

```bash
# Linux
./cert_check.sh -t cert_targets.lst --html report.html
```

### WARN / NG のみ表示

```powershell
# Windows
.\cert_check.bat -TargetList cert_targets.lst -FailOnly
```

```bash
# Linux
./cert_check.sh -t cert_targets.lst --fail-only
```

### オプション組み合わせ

```powershell
# Windows: HTML レポート + WARN/NG のみ
.\cert_check.bat -TargetList cert_targets.lst -HtmlReport report.html -FailOnly
```

```bash
# Linux: HTML レポート + WARN/NG のみ + タイムアウト指定
./cert_check.sh -t cert_targets.lst --html report.html --fail-only --timeout 15
```

### 保存済み JSON からレポート再生成（Windows のみ）

過去に `-Json` で保存した結果を読み込み、収集せずにレポートを再生成できます。

```powershell
# JSON を再表示
.\CertCheck.ps1 -FromJson saved.json -Json

# HTML レポートを生成
.\CertCheck.ps1 -FromJson saved.json -HtmlReport report.html

# NG/WARN のみ
.\CertCheck.ps1 -FromJson saved.json -FailOnly
```

判定（OK/WARN/NG）は JSON に保存された値をそのまま使うため、対象リストは不要です。

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
| **OK** | 残り日数 > warn_days | 有効期限に余裕あり |
| **WARN** | 0 < 残り日数 <= warn_days | 有効期限が近い |
| **NG** | 残り日数 <= 0、または接続失敗 | 期限切れまたは接続不可 |

---

## 終了コード

| Code | 意味 |
|---|---|
| 0  | 全証明書が OK |
| 1  | WARN または NG が 1 件以上 |
| 2  | ターゲットリストファイルが見つからない |
| 10 | 前提コマンド不足（openssl 等） |

---

## バージョン

変更履歴は [CHANGELOG.md](../../CHANGELOG.md) を参照してください。
