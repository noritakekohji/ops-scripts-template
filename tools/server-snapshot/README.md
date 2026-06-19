# server-snapshot

サーバ情報スナップショットの収集・比較ツール（server-compare + change-detect 統合）。

**このフォルダ一式をコピーすれば動きます。**

```
tools/server-snapshot/
├── ServerSnapshot.ps1       # Windows 本体（収集・比較・一覧）
├── server_snapshot.bat      # Windows 起動用バッチ
├── server_snapshot.sh       # Linux 本体（収集・比較・一覧）
└── compare_server_info.py   # 共通比較エンジン（HTML レポート生成）
```

---

## 前提

| 実行環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+ |
| Linux   | Bash 4+, `python3` |

> **python3 は Windows では任意**: ServerSnapshot.ps1 は python3 が見つからない場合、
> PowerShell ネイティブの比較処理にフォールバックします。

---

## サブコマンド

| サブコマンド | 説明 |
|---|---|
| `collect` | サーバー構成のスナップショットを JSON で収集（既定） |
| `before`  | ラベル付き「変更前」スナップショットを収集 |
| `after`   | ラベル付き「変更後」スナップショットを収集し、最新の before と自動比較 |
| `compare` | 既存の 2 つのスナップショット JSON を直接比較 |
| `list`    | カレントディレクトリのスナップショット一覧を表示 |

---

## 使い方

### collect — スナップショット収集

```powershell
# Windows: 全カテゴリ収集
.\server_snapshot.bat collect

# カテゴリ指定
.\server_snapshot.bat collect -Category os,network,services -OutputPath server01.json
```

```bash
# Linux: 全カテゴリ収集
./server_snapshot.sh collect

# カテゴリ指定
./server_snapshot.sh collect -c os,network,services -o server01.json
```

### before / after — 変更前後の比較

```powershell
# Windows
.\server_snapshot.bat before -Label deploy-v1.2.3
# ... デプロイ作業 ...
.\server_snapshot.bat after -Label deploy-v1.2.3 -HtmlReport report.html

# カテゴリ絞り込み
.\server_snapshot.bat before -Label deploy-v1.2.3 -Category services,packages,environment
```

```bash
# Linux
./server_snapshot.sh before -l deploy-v1.2.3
# ... デプロイ作業 ...
./server_snapshot.sh after -l deploy-v1.2.3 --html report.html

# カテゴリ絞り込み
./server_snapshot.sh before -l deploy-v1.2.3 -c services,packages,environment
```

### compare — 既存ファイルの直接比較

```powershell
# Windows
.\server_snapshot.bat compare -BeforePath before.json -AfterPath after.json
.\server_snapshot.bat compare -BeforePath before.json -AfterPath after.json -HtmlReport diff.html -DiffOnly
```

```bash
# Linux
./server_snapshot.sh compare before.json after.json
./server_snapshot.sh compare before.json after.json --html diff.html
```

### list — スナップショット一覧

```powershell
.\server_snapshot.bat list
```

```bash
./server_snapshot.sh list
```

---

## 収集カテゴリ

| カテゴリ | 収集内容 |
|---|---|
| `os`          | OS バージョン、ホスト名、カーネル、CPU、メモリ、タイムゾーン、HW/仮想化、ロケール詳細、再起動保留 |
| `network`     | IP アドレス、ルーティング、DNS、hosts、プロキシ設定、時刻同期（NTP） |
| `services`    | サービス一覧（状態・起動設定） |
| `packages`    | インストール済みパッケージとバージョン |
| `users`       | ローカルユーザー・グループ |
| `filesystem`  | ドライブ / マウントポイントの使用状況、マウントオプション |
| `environment` | システム環境変数 |
| `security`    | ファイアウォール設定・ルール、UAC (Win) / AppArmor (Linux) |
| `patches`     | 適用済みパッチ/更新 (HotFix / rpm / dpkg) |
| `tuning`      | 性能チューニング設定 (sysctl / CPU ガバナー / THP / ページファイル / 電源プラン) |
| `scheduled`   | スケジュールタスク / スタートアップ / cron / systemd timers |
| `middleware`  | ミドルウェア（HANA / SAP / SQL Server / Tomcat）のバージョン・状態・Listen ポート・設定ファイル全文 |

既定値は `all`（全カテゴリ収集）。カンマ区切りで複数指定可能。

```powershell
# Windows: 新カテゴリ指定例
.\server_snapshot.bat collect -Category tuning,patches,scheduled
```

```bash
# Linux: 新カテゴリ指定例
./server_snapshot.sh collect -c tuning,patches,scheduled
```

---

## `middleware` カテゴリ

ミドルウェア製品ごとのバージョン・状態・Listen ポートと、設定ファイルの全文を収集します。
出力は製品サブキー `hana` / `sap` / `sqlserver` / `tomcat` に分かれ、各サブキーは
**インスタンスの配列**です。

```powershell
# Windows
.\server_snapshot.bat collect -Category middleware
```

```bash
# Linux
bash server_snapshot.sh collect --category middleware
```

### 製品ごとの収集内容

| 製品 | 対応 OS | 収集する値 | 設定ファイルの収集元 |
|---|---|---|---|
| `hana`      | **Linux のみ** | バージョン / 状態 / Listen ポート + 設定ファイル全文 | `/usr/sap/<SID>/SYS/global/hdb/custom/config` 配下の HANA ini |
| `sap`       | Windows / Linux | バージョン / 状態 / Listen ポート + 設定ファイル全文 | SAP プロファイル（Linux: `/usr/sap/<SID>/SYS/profile`、Windows: `\usr\sap\<SID>\SYS\profile`） |
| `sqlserver` | Windows / Linux | バージョン / 状態 / Listen ポート + 設定ファイル全文 + `sp_configure` | レジストリ / サービス / `mssql.conf`、`sp_configure` は統合認証で取得 |
| `tomcat`    | Windows / Linux | バージョン / 状態 / Listen ポート + 設定ファイル全文 | `CATALINA_BASE` 配下の `server.xml` / `conf` |

> HANA は Linux 専用です（Windows では収集されません）。SAP / SQL Server / Tomcat は両 OS で収集します。

### `middleware.conf` — 検出パスとマスクの上書き

ツールフォルダ内の `middleware.conf`（INI ライク）で、検出パス・マスクパターン・サイズ上限を
環境ごとに上書きできます。

| セクション | 制御内容 |
|---|---|
| `[hana]`      | `sids` — HANA SID のリスト（設定ファイル探索の `%SID%` グロブを展開） |
| `[sap]`       | `sids` — SAP SID のリスト（プロファイル探索の `%SID%` グロブを展開） |
| `[sqlserver]` | `instances` — SQL Server インスタンス名のリスト、`connect=auto\|off`（`sp_configure` 取得の有効/無効） |
| `[tomcat]`    | `bases` — `CATALINA_BASE` のリスト |
| `[masking]`   | 設定ファイル内の機密値をマスクする追加パターン |
| `[limits]`    | `max_file_kb` — 全文収集する設定ファイルのサイズ上限（KB） |

`sids` / `instances` / `bases` はカンマ区切りのリスト。パス中の `%SID%` は各 SID で展開されます。

### セキュリティ / 挙動

- **機密キーの自動マスク**: 設定ファイル内の既知キー（パスワード等のパターン）に一致する値は
  `***` に置換してから保存します。`[masking]` で追加パターンを指定できます。
- **読み取り不可のファイル**: アクセス権がなく読めなかったファイルは内容を保存せず、
  `reason=permission_denied` として記録します。
- **サイズ上限超過**: `max_file_kb` を超えるファイルは全文を保存せず、`sha256` とサイズのみを保存し
  `reason=too_large` として記録します。
- **SQL Server `sp_configure`**: 統合認証（integrated auth）で best-effort 取得します。
  **資格情報は一切保存しません**。接続できない場合は `sp_configure_available=false` に degrade します。

### compare の挙動と既知の制限

`middleware` の比較は、各製品インスタンスのスカラ項目（バージョン・状態・ポート等）の差分に加え、
**設定ファイルを sha256 で比較**します（全文テキスト diff ではなく、どのファイルが変わったかを検出）。

> **既知の制限**: 設定ファイルは `instanceKey::絶対パス` をキーとして突き合わせます。
> このため、同じ論理ファイルでも絶対パスが異なる場合（インストール先ディレクトリが違う、
> あるいは Windows と Linux のスナップショット間の比較など）は、`CHANGED` ではなく
> `REMOVED` + `ADDED` として表示されます。**同一ホストの before/after 比較では影響ありません。**

---

## スナップショットの命名規則

出力パスを省略した場合、以下の形式で自動命名されます。

```
<hostname>_<mode>_<label>_<timestamp>.json
```

| 要素 | 例 |
|---|---|
| hostname  | `web01` |
| mode      | `collect` / `before` / `after` |
| label     | `deploy-v1.2.3`（省略時は `snapshot`） |
| timestamp | `20260613-143000` |

例: `web01_before_deploy-v1.2.3_20260613-143000.json`

`after` モードでは `*_before_<label>_*.json` の中から最新ファイルを自動検索して比較します。

---

## 終了コード

| Code | 意味 |
|---|---|
| 0  | 成功 |
| 1  | 引数不正 |
| 2  | ファイルが見つからない |
| 3  | 待機タイムアウト |
| 4  | 処理エラー |
| 10 | 前提コマンド不足 |
| 20 | 一時障害（リトライ可能） |

---

## server-compare / change-detect からの移行

server-snapshot は従来の 2 ツールを統合したものです。旧コマンドは委譲ラッパーとして残っていますが、
新規利用では server-snapshot を直接使用してください。

| 旧ツール | 旧コマンド | 新コマンド |
|---|---|---|
| server-compare | `Get-ServerInfo.ps1 -OutputPath out.json` | `server_snapshot.bat collect -OutputPath out.json` |
| server-compare | `Compare-ServerInfo.ps1 -Before a.json -After b.json` | `server_snapshot.bat compare -BeforePath a.json -AfterPath b.json` |
| change-detect  | `change_detect.sh before -l label` | `server_snapshot.sh before -l label` |
| change-detect  | `change_detect.sh after -l label` | `server_snapshot.sh after -l label` |
| change-detect  | `Change-Detect.ps1 before -Label label` | `server_snapshot.bat before -Label label` |

---

## バージョン

変更履歴は [CHANGELOG.md](../../CHANGELOG.md) を参照してください。
