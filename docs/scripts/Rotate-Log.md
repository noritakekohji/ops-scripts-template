# `Rotate-Log.ps1`

> サイズまたは経過時間でログをローテートする（Windows / PowerShell 版）。リストファイルによる一括処理、gzip 圧縮、世代保持に対応。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/windows/Rotate-Log.ps1
```

| 項目 | 値 |
|---|---|
| 言語 | PowerShell 7+ |
| OS | Windows |
| ペア（Linux 版） | [`rotate_log.sh`](rotate_log.md) |

## 2. 概要

- 単一ファイル / ディレクトリ / **リストファイル** を受け取り、対象ログを複数まとめて処理
- 発動条件はサイズまたは時間（OR 条件、少なくとも一方が必須）
- ローテート後に gzip 圧縮（任意）
- 古い rotated ファイルを世代数ベースで削除（任意）
- アクティブなプロセスがファイルを掴んでいる場合は CopyTruncate モード可

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | PowerShell 7+ |
| 必須モジュール | なし（標準 .NET の `System.IO.Compression.GZipStream` を使用） |
| 認証 | 不要（ローカル FS 操作のみ） |
| 必要権限 | 対象ファイル・ディレクトリの読み書き、削除 |

## 4. パラメータ

### 対象指定

| 名前 | 型 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-Path` | string | △ | — | 単一ファイル or ディレクトリ。`-PathList` と併用可 |
| `-PathList` | string | △ | — | 対象パスを列挙したテキストファイル。`-Path` と併用可 |
| `-Pattern` | string | — | `*.log` | ディレクトリ展開時の glob |

`-Path` と `-PathList` の少なくとも一方が必須。両方併用すると結果はマージ＋重複排除。

### ローテート発動条件（少なくとも一方が必須）

| 名前 | 型 | デフォルト | 説明 |
|---|---|---|---|
| `-MaxSizeMB` | int | `0` | サイズが MB 以上で発動。0 で無効。範囲 0〜1048576 |
| `-MaxAgeDays` | int | `0` | 最終更新が N 日以上前で発動。0 で無効。範囲 0〜3650 |

両方指定時は **OR 条件**。

### ローテート挙動

| 名前 | 型 | デフォルト | 説明 |
|---|---|---|---|
| `-Compress` | switch | off | gzip 圧縮（`.gz`）。Optimal レベル |
| `-RetentionCount` | int | `0` | 各 source につき rotated ファイルを最新 N 件に制限。0 で無効。範囲 0〜10000 |
| `-CopyTruncate` | switch | off | rename + 新規作成ではなく copy + truncate。プロセスがファイル open 継続する場合に使う |
| `-WhatIf` / `-Confirm` | switch | — | 標準の dry-run / 確認 |

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功（処理対象が無くても 0） |
| 1 | バリデーション失敗（トリガー未指定 等） |
| 2 | `-PathList` で指定したファイルが存在しない |

個別ファイルのローテート失敗は ERROR ログに出すが、スクリプト全体は継続する（他のファイルへの波及を防ぐ）。

## 6. リストファイル形式

`-PathList` で指定するテキストファイルの仕様：

```
# 行頭 # はコメント
# 空行は無視
# 前後の空白は trim される

C:\logs\app.log
C:\logs\nginx                     # ディレクトリは -Pattern で glob 展開
D:\app\logs\error.log
```

| ルール | 内容 |
|---|---|
| 1 行 1 パス | 単一ファイル or ディレクトリ |
| `#` で始まる行 | コメント（無視） |
| 空行 | 無視 |
| 前後空白 | 自動 trim |
| 相対パス | 不可（絶対パス推奨） |
| 文字コード | UTF-8 |

## 7. ローテート命名規則

```
<original>.YYYYMMDD-HHMMSS        ← rename / copy 直後
<original>.YYYYMMDD-HHMMSS.gz     ← -Compress 指定時
```

タイムスタンプは **UTC**。命名衝突しないため同一秒内の連続実行も安全。

## 8. 使用例

### 単一ファイル：100MB 超で rotate、gzip、7 世代保持
```powershell
.\Rotate-Log.ps1 -Path C:\logs\app.log -MaxSizeMB 100 -Compress -RetentionCount 7
```

### ディレクトリ一括：1 日経過で全 *.log を rotate
```powershell
.\Rotate-Log.ps1 -Path C:\logs -Pattern *.log -MaxAgeDays 1 -Compress -RetentionCount 30
```

### リストファイル：複数の対象を一括処理
```powershell
.\Rotate-Log.ps1 -PathList C:\ops\logs.txt -MaxAgeDays 1 -Compress -RetentionCount 14
```

`C:\ops\logs.txt` の例：
```
# Tomcat
D:\tomcat\logs\catalina.out
D:\tomcat\logs\localhost_access_log.txt

# Application
C:\apps\myapp\logs

# Nginx
D:\nginx\logs\access.log
D:\nginx\logs\error.log
```

### `-Path` と `-PathList` の併用
```powershell
.\Rotate-Log.ps1 -Path C:\logs\critical.log -PathList C:\ops\logs.txt -MaxSizeMB 200 -Compress
```

### 開きっぱなしのプロセス向け（CopyTruncate）
```powershell
.\Rotate-Log.ps1 -Path D:\tomcat\logs\catalina.out -MaxSizeMB 500 -CopyTruncate -Compress -RetentionCount 14
```

### Dry-run（実操作なし、ログのみ）
```powershell
.\Rotate-Log.ps1 -PathList C:\ops\logs.txt -MaxAgeDays 1 -Compress -RetentionCount 7 -WhatIf
```

### タスクスケジューラ（毎日 03:00）
```
schtasks /Create /TN "RotateLogs" /TR "pwsh -NoProfile -ExecutionPolicy Bypass -File C:\ops-scripts\scripts\windows\Rotate-Log.ps1 -PathList C:\ops\logs.txt -MaxAgeDays 1 -Compress -RetentionCount 30" /SC DAILY /ST 03:00 /RU SYSTEM
```

## 9. 出力例

```
[2026-05-09 03:00:01] [INFO ] (Rotate-Log.ps1:8421) Loaded paths from list: pathList=C:\ops\logs.txt count=4
[2026-05-09 03:00:01] [INFO ] (Rotate-Log.ps1:8421) Rotation start: targets=4 matched=6 maxSizeMB=0 maxAgeDays=1 compress=True retention=30 copyTruncate=False
[2026-05-09 03:00:02] [INFO ] (Rotate-Log.ps1:8421) Rotated (rename): from=D:\tomcat\logs\catalina.out to=D:\tomcat\logs\catalina.out.20260509-030002 reason=mtime=2026-05-08_03:00:05_older_than_1d
[2026-05-09 03:00:03] [INFO ] (Rotate-Log.ps1:8421) Compressed: file=D:\tomcat\logs\catalina.out.20260509-030002.gz
[2026-05-09 03:00:05] [INFO ] (Rotate-Log.ps1:8421) Pruned: file=D:\tomcat\logs\catalina.out.20260408-030002.gz
[2026-05-09 03:00:05] [INFO ] (Rotate-Log.ps1:8421) Rotation complete: rotated=4 skipped=2
```

## 10. 注意事項

- **ファイルがプロセスにロックされている場合、デフォルトの rename は失敗する**。`-CopyTruncate` を使うこと
- **CopyTruncate は厳密にはアトミックではない**（コピー中にも書き込みが発生し得る）。短時間のログ重複を許容できる場合に限る
- **ACL は引き継がれない**（rename 後の新規ファイルは親ディレクトリの既定 ACL）。重要なら別途 `Set-Acl` で復元
- **シンボリックリンクは追跡しない**（PowerShell 既定）

## 11. 関連

- ペア（Linux 版）: [`rotate_log.md`](rotate_log.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)

## 12. 改訂履歴

| 版 | 日付 | 内容 |
|---|---|---|
| v1.1 | 2026-05-09 | `-PathList` 追加（リストファイルによる複数対象一括処理） |
| v1.0 | 2026-05-09 | 初版 |
