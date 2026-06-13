# log-collector

障害時の証跡（ログファイル）収集ツール。

プリセット定義に従い、指定した時間窓内のログファイルを収集し、SHA-256 マニフェスト・OS 情報とともに ZIP アーカイブにパッケージングします。

**このフォルダ一式をコピーすれば動きます。**

```
tools/log-collector/
├── LogCollector.ps1       # Windows 本体
├── log_collector.bat      # Windows 起動用バッチ
├── log_collector.sh       # Linux 本体
├── collect_targets.conf   # 収集対象プリセット定義
└── README.md              # 本ファイル
```

---

## 前提

| 実行環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+ |
| Linux   | Bash 4+, `zip`, `sha256sum`（または `shasum`） |

---

## 収集対象プリセット（collect_targets.conf）

INI ライクなセクション形式で収集対象を定義します。

```ini
[preset_name]
path = /path/to/logs/*.log
path = C:\path\to\logs\*.log
max_file_size_mb = 100
```

| キー | 既定値 | 説明 |
|---|---|---|
| `path` | (必須) | グロブパターン。複数行で複数パターン指定可 |
| `max_file_size_mb` | `100` | 個別ファイルの上限サイズ（MB）。超過ファイルはスキップ |

- `#` で始まる行はコメント
- 1 つのプリセットに `path` を複数行書ける（Windows / Linux 両方のパスを併記可能）

### 組み込みプリセット一覧

| プリセット | 対象パス（抜粋） | max_file_size_mb |
|---|---|---|
| `tomcat` | `/opt/tomcat/logs/*.log`, `C:\tomcat\logs\*.log` | 50 |
| `nginx` | `/var/log/nginx/*.log`, `C:\nginx\logs\*.log` | 100 |
| `postgresql` | `/var/log/postgresql/*.log`, `C:\PostgreSQL\*\data\log\*.log` | 100 |
| `mysql` | `/var/log/mysql/*.log`, `C:\ProgramData\MySQL\*\Data\*.err` | 100 |
| `os` | `/var/log/syslog`, `/var/log/messages`, `C:\Windows\Logs\CBS\*.log` | 200 |
| `hana` | `/usr/sap/*/HDB*/*/trace/*.trc` | 200 |
| `sap` | `/usr/sap/*/D*/work/*.log` | 100 |

---

## 使い方

### 基本（プリセット指定）

```powershell
# Windows
.\log_collector.bat -Target tomcat,os
```

```bash
# Linux
./log_collector.sh -t tomcat,os
```

### 時間窓の指定

```powershell
# Windows: 過去 48 時間
.\log_collector.bat -Target tomcat -Since 48h

# Windows: 日時範囲を指定
.\log_collector.bat -Target os -From "2026-06-01 00:00" -To "2026-06-02 00:00"
```

```bash
# Linux: 過去 48 時間
./log_collector.sh -t tomcat -s 48h

# Linux: 日時範囲を指定
./log_collector.sh -t os --from "2026-06-01 00:00:00" --to "2026-06-02 00:00:00"
```

### カスタム設定ファイル・出力先・サイズ上限

```powershell
# Windows
.\log_collector.bat -Target tomcat -ConfigFile C:\ops\custom_targets.conf -OutputDir C:\evidence -MaxSizeMB 1000
```

```bash
# Linux
./log_collector.sh -t tomcat -c /opt/ops/custom_targets.conf -o /tmp/evidence --max-size 1000
```

---

## 出力形式

ZIP アーカイブが以下のファイル名で生成されます。

```
evidence_<hostname>_<YYYYMMDD_HHMMSS>.zip
```

### アーカイブ内容

| ファイル | 説明 |
|---|---|
| `manifest.json` | 収集ファイルの一覧（パス、サイズ、mtime、SHA-256 ハッシュ） |
| `osinfo.txt` | OS 情報スナップショット（Linux: `uname -a` 等 / Windows: `systeminfo` + ディスク使用量） |
| `files/...` | 収集されたログファイル本体 |

---

## サイズ上限の動作

`-MaxSizeMB` / `--max-size` で全体の合計サイズ上限を指定します（既定: 500 MB）。

- 対象ファイルは **更新日時が新しい順** にソートされ、上限に達するまで収集されます
- 上限超過により収集をスキップしたファイルがある場合、**WARN** ログを出力します
- 個別ファイルの上限（`max_file_size_mb`）を超えるファイルも WARN でスキップされます

---

## パーミッション処理

読み取り権限がないファイルは **WARN を出力してスキップ** します。収集は中断しません。

---

## 終了コード

| Code | 意味 |
|---|---|
| 0  | 成功 |
| 1  | 引数不正（パラメータ誤り、設定ファイル不在、不明なプリセット） |
| 2  | 収集ファイルなし（全てスキップ、またはマッチなし） |
| 10 | 前提コマンド不足（`zip`, `sha256sum` 等） |

---

## バージョン

変更履歴は [CHANGELOG.md](../../CHANGELOG.md) を参照してください。
