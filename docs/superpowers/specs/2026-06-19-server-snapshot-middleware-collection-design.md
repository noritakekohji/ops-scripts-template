# server-snapshot ミドルウェア情報取得 設計書

**日付:** 2026-06-19
**対象ツール:** `tools/server-snapshot/`
**関連:** [`2026-06-17-server-snapshot-os-expansion-design.md`](./2026-06-17-server-snapshot-os-expansion-design.md)（OS 拡充。本設計はその後続）

---

## 1. 目的 / 背景

server-snapshot の目的は「テスト環境断面の把握」と「性能テスト再現性」。OS レベルの収集
（os/network/services/packages/users/filesystem/environment/security/patches/tuning/scheduled）
は実装済み。本設計では **ミドルウェアの構成情報** を同ツールで収集し、テスト環境の断面比較・
再現に使えるようにする。

対象ミドルウェア（今回）: **SAP HANA / SAP NW・S/4HANA / SQL Server / Tomcat**。
（mysql / nginx / postgresql は今回対象外。将来同パターンで追加可能。）

取得の深さ: **バージョン + 主要設定 + 状態 + 設定ファイル全文**（最も深いレベル。機密はマスク）。

---

## 2. スコープ

### 2.1 In scope
- server-snapshot に**トップレベル 1 カテゴリ `middleware`** を追加。
- 配下に製品サブキー `hana` / `sap` / `sqlserver` / `tomcat`（各々インスタンス配列）。
- 自動検出 + `middleware.conf` による上書き。
- 設定ファイル全文収集（既知機密キーをマスク）。
- compare 比較器（`Compare-Middleware`）。
- Pester / bats テスト、README / CHANGELOG 更新。

### 2.2 Out of scope
- mysql / nginx / postgresql のミドルウェア収集（将来）。
- DB へのデータ問い合わせ（テーブル件数等）。SQL Server の `sp_configure` のみ best-effort で取得。
- 資格情報を保存しての DB 接続（リポジトリ原則に反するため不採用）。
- 設定ファイルの全文 diff（compare は sha256 ベース。下記 6 章）。

### 2.3 共通制約（既存ツール規約の継承）
- **両OS 1:1**: カテゴリ名・JSON トップ構造を揃える。適用外の製品キーは**省略**（空で埋めない）。
- **自己完結**: `scripts_*/lib/` に依存しない。`middleware.conf` はツールに同梱。
- **フォールバック**: 収集失敗（コマンド無し / 権限無し / パース失敗）は当該項目を空または
  マーカー付きで記録し、収集全体は止めない。
- **PS5.1**: `??`/`?:`/`?.` 禁止。`Set-StrictMode -Version Latest` 下で欠落プロパティに触れない
  （`Safe-Exec` ラッパ使用）。
- **エンコーディング**: `.ps1`=UTF-8 BOM、`.sh`=BOM なし LF、`.conf`=LF。
- **Windows 制限環境**: `Get-Process`→`Win32_Process` 等の CIM フォールバックを既存方針で踏襲。

---

## 3. データモデル

`collect ... -Category middleware` の出力に以下を追加する。

```jsonc
"middleware": {
  "hana": [
    {
      "sid": "PRD",
      "instance_no": "00",
      "version": "2.00.073.00.1700000000",
      "edition": "",
      "state": "GREEN",                 // sapcontrol GetProcessList 集約 (GREEN/YELLOW/GRAY/'')
      "ports": [30013, 30015],
      "config_files": { "<abs_path>": <FileEntry> }
    }
  ],
  "sap": [
    {
      "sid": "PRD",
      "instance": "ASCS01",             // 例: ASCS01 / D00 / PAS
      "instance_no": "01",
      "type": "ASCS",                   // ASCS / ERS / PAS / AAS / '' (判別不能)
      "kernel_version": "789, patch 200",
      "state": "GREEN",
      "ports": [3201, 3901],
      "profiles": { "<abs_path>": <FileEntry> }
    }
  ],
  "sqlserver": [
    {
      "instance_name": "MSSQLSERVER",   // 既定 or 名前付き
      "version": "15.0.4345.5",
      "edition": "Developer Edition (64-bit)",
      "state": "running",               // サービス状態
      "port": 1433,
      "config_files": { "<abs_path>": <FileEntry> },   // Linux: mssql.conf 等
      "sp_configure": { "max server memory (MB)": "2147483647", ... } | null,
      "sp_configure_available": true
    }
  ],
  "tomcat": [
    {
      "name": "tomcat9",                // サービス名 or ディレクトリ名
      "catalina_base": "/opt/tomcat9",
      "version": "Apache Tomcat/9.0.85",
      "java_version": "17.0.10",
      "jvm_opts": "-Xms2g -Xmx2g ...",  // setenv / サービス定義から
      "state": "running",
      "pid": 12345,
      "connector_ports": [8080, 8443],
      "config_files": { "<abs_path>": <FileEntry> }
    }
  ]
}
```

### 3.1 FileEntry（config_files / profiles の各値）

```jsonc
{
  "content": "…masked text…",  // 収集できマスク済みの全文。未収集時は ""
  "masked": true,              // マスク置換が1箇所以上行われたか
  "size_bytes": 4096,          // 元ファイルのバイト数
  "sha256": "ab12…",           // 元ファイル（マスク前）の sha256。compare のキー
  "readable": true,            // 読取り可否
  "reason": ""                 // readable=false 時の理由 ("permission_denied"/"not_found"/"too_large")
}
```

- **サイズ上限超過時**: `content=""`, `readable=true`, `reason="too_large"`, `size_bytes` と `sha256` は保持。
- **権限不足時**: `content=""`, `readable=false`, `reason="permission_denied"`, `sha256=""`。
- **不在時**: そのファイルはエントリ自体を作らない（検出で見つかったもののみ列挙）。

### 3.2 OS 適用

| 製品 | Linux | Windows |
|---|---|---|
| hana | ○ | 省略 |
| sap  | ○ | 省略 |
| sqlserver | ○（インストール時のみ） | ○ |
| tomcat | ○ | ○ |

省略キーは JSON に出さない（既存 1:1 規約に従う）。

---

## 4. 検出と収集ロジック

### 4.1 検出（自動 + conf 上書き）

| 製品 | 自動検出 | conf 上書き |
|---|---|---|
| hana | `/usr/sap/<SID>/HDB<nr>` ディレクトリ走査、`/hana/shared/<SID>` | `[hana] sids=`, `config_globs=` |
| sap  | `/usr/sap/<SID>/SYS/profile/`、`/usr/sap/<SID>/<INST>` | `[sap] sids=`, `profile_globs=` |
| sqlserver | Win: レジストリ `HKLM\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL`。Linux: `/var/opt/mssql`, `systemctl` | `[sqlserver] instances=`, `connect=auto|off` |
| tomcat | 環境変数 `CATALINA_HOME`/`CATALINA_BASE`、`/opt/tomcat*`・`/usr/share/tomcat*`、Win サービス `Tomcat*`、稼働プロセスの `-Dcatalina.base` | `[tomcat] bases=` |

- conf に明示列挙があれば**自動検出に追加マージ**（重複は正規化して排除）。`sids`/`instances`/`bases`
  を空にすれば自動検出のみ。
- 検出ゼロの製品は空配列ではなく**キー自体を省略**（その OS で未インストール扱い）。

### 4.2 バージョン / 状態 / ポート 取得元

- **HANA**: version=`HDB version`（sidadm 環境）。state/ports=`sapcontrol -nr <nr> -function GetProcessList`
  と Listen ポート（`ss -ltnp` / CIM 相当）から。取得不可は空。
- **SAP**: kernel=`disp+work -v`。state=`sapcontrol GetProcessList`。
- **SQL Server**: version/edition=`SERVERPROPERTY`（接続可時）またはレジストリ。state=サービス。
  port=レジストリ `Tcp\IPAll\TcpPort` / `ss`。`sp_configure`=統合認証 best-effort（4.3）。
- **Tomcat**: version=`catalina.sh version` / `RELEASE-NOTES` / `catalina.jar` MANIFEST。
  java_version=`java -version`。jvm_opts=`setenv.sh/.bat` ・サービス定義 ・稼働プロセス引数。
  state/pid/ports=プロセス（`Win32_Process` フォールバック）と server.xml の `<Connector port>`。

### 4.3 SQL Server `sp_configure`（best-effort・資格情報非保存）

- `connect=auto`（既定）: Windows は `sqlcmd -E`（統合認証）、Linux は現在ユーザの統合/既定接続で
  `EXEC sp_configure` + `SELECT @@VERSION` を試行。
- 成功 → `sp_configure` に name→value を格納、`sp_configure_available=true`。
- 失敗（sqlcmd 無し / 認証不可 / タイムアウト）→ `sp_configure=null`, `sp_configure_available=false`。
  バージョン・サービス・ポート・mssql.conf の収集は継続（退化）。
- `connect=off` → 接続を一切試みず最初から退化モード。
- **資格情報は conf にも保存しない**。SQL 認証ユーザ/パスワード指定はサポートしない。

---

## 5. 機密・権限・サイズ

### 5.1 マスク
- 既定パターン（行内・大文字小文字無視で部分一致）:
  `password`, `passwd`, `pwd`, `secret`, `key`, `credential`, `token`, `connectionstring`。
- マッチ行は `key = value` / `key: value` / XML 属性 `key="value"` の **値部分**を `***` に置換。
  キー名・構造は保持（断面比較のため）。
- `[masking] patterns=` で追加・上書き可能。
- バイナリのセキュアストア（HANA SSFS `*.DAT/*.KEY`、`hdbuserstore`）は収集対象外（テキストでない
  ため content 化しない。検出しても FileEntry を作らない）。

### 5.2 権限
- best-effort 読取り。読めない場合は `readable=false`, `reason="permission_denied"` を記録し継続。
- sidadm 専用ファイルなど、実行ユーザによって読めないものがある前提。**昇格はしない**。

### 5.3 サイズ
- 既定上限 **256 KB/ファイル**（`[limits] max_file_kb=` で変更可）。
- 超過は content を格納せず `reason="too_large"` + `size_bytes` + `sha256` のみ。

---

## 6. compare

`Compare-Middleware($b, $a)` を Section 5 に追加し、compare dispatch に登録。

- 製品ごとにインスタンスをキーで突合:
  - hana: `sid`、sap: `sid`+`instance`、sqlserver: `instance_name`、tomcat: `name`+`catalina_base`。
- 各インスタンスのスカラ項目（version/state/ports/...）は `Compare-Dict` 相当で差分検出。
- **config_files / profiles は `sha256` をキー値として比較**（content 全文 diff はしない）。
  → 「どのファイルが変わったか（added/removed/changed）」を示す。レポート肥大と揮発混入を回避。
- `sp_configure` は dict 比較（name→value の差分）。
- 揮発値は持たない（time_sync のような `_volatile` 除外は不要）。

出力はカテゴリ駆動レポートにそのまま反映される（既存 compare 基盤を活用）。

---

## 7. 設定ファイル `middleware.conf`（INI ライク・log-collector 準拠）

`tools/server-snapshot/middleware.conf`（同梱・LF）。`%SID%` はプレースホルダ。

```ini
# 自動検出を基本とし、ここでの列挙は「追加」または「明示指定」。
# 各 *s/*es を空にすると自動検出のみ。

[hana]
sids =                         # 例: PRD,DEV（空=自動検出）
config_globs = /usr/sap/%SID%/SYS/global/hdb/custom/config/*.ini

[sap]
sids =
profile_globs = /usr/sap/%SID%/SYS/profile/*

[sqlserver]
instances =                    # 例: MSSQLSERVER,SQLEXPRESS（空=自動検出）
connect = auto                 # auto | off

[tomcat]
bases =                        # 例: /opt/tomcat9,D:\apache-tomcat-9
config_names = server.xml,web.xml,context.xml,catalina.properties,setenv.sh,setenv.bat

[masking]
patterns = password,passwd,pwd,secret,key,credential,token,connectionstring

[limits]
max_file_kb = 256
```

---

## 8. 実装単位（責務分離）

- **PS (`ServerSnapshot.ps1`)**: `Get-MiddlewareInfo`（ディスパッチ）→ 製品別ヘルパ
  `Get-MwHana` / `Get-MwSap` / `Get-MwSqlServer` / `Get-MwTomcat`、共通の
  `Read-MwConfigFile`（マスク + サイズ + sha256 + 権限を FileEntry 化）、`Read-MwConf`（conf パーサ）。
- **sh (`server_snapshot.sh` 埋め込み python3)**: `collect_middleware` → `_mw_hana` / `_mw_sap`
  / `_mw_sqlserver` / `_mw_tomcat`、共通 `_mw_read_file`（FileEntry 化）、`_mw_load_conf`。
- 各製品ヘルパは「検出 → インスタンス配列を返す」単一責務。`Read-MwConfigFile` / `_mw_read_file` が
  マスク・サイズ・sha256・権限の単一実装点（重複を避ける）。

---

## 9. テスト

### 9.1 Pester（Windows 実機 + fixtures）
- `middleware` がキーを持ち、各製品が配列であること。
- fixtures: 擬似 `CATALINA_BASE`（server.xml に `<Connector port="8080">` とダミー
  `password="..."`）を作り、`Get-MwTomcat` 相当が version/ports/config_files を返し、
  password がマスクされること（`content` に `***`、`masked=true`）。
- サイズ上限・権限不能時の FileEntry（`reason` セット）を検証。
- compare: 2 スナップショットで config sha256 変化が `changed` として出ること。

### 9.2 bats（Linux、既存スキップガード踏襲）
- 擬似 `/tmp` 配下に SID/プロファイルを作り、`collect --category middleware` が dict を返し
  `middleware` キーが存在すること。
- マスクと FileEntry 構造の検証。

### 9.3 既存回帰
- 全 Pester / bats / `ci/template-check` を pass、新規 violation なし。

---

## 10. ドキュメント
- `tools/server-snapshot/README.md`: `middleware` カテゴリ、製品別収集内容、`middleware.conf`
  サンプル、機密マスク・権限・サイズの注意、`--category middleware` 実行例。
- `CHANGELOG.md` `[Unreleased]` `### Added` に追記。

---

## 11. 自己レビュー観点（仕様の網羅）

| 仕様項目 | 反映箇所 |
|---|---|
| middleware カテゴリ追加（hana/sap/sqlserver/tomcat） | 3章 / 8章 |
| 自動検出 + conf 上書き | 4.1 / 7章 |
| バージョン/状態/ポート | 4.2 |
| 設定ファイル全文 + マスク | 3.1 / 5.1 |
| SQL Server sp_configure best-effort・資格情報非保存 | 4.3 |
| 権限・サイズのフォールバック | 5.2 / 5.3 / 3.1 |
| compare（sha256 ベース） | 6章 |
| 両OS 1:1・自己完結 | 2.3 / 3.3 |
| テスト・docs | 9章 / 10章 |
