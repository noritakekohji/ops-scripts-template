# `rotate_log.sh`

> サイズまたは経過時間でログをローテートする（Linux / Bash 版）。リストファイルによる一括処理、gzip 圧縮、世代保持に対応。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

```
scripts/linux/bash/rotate_log.sh
```

| 項目 | 値 |
|---|---|
| 言語 | Bash 4+（`set -euo pipefail`） |
| OS | Linux |
| ペア（Windows 版） | [`Rotate-Log.ps1`](Rotate-Log.md) |

## 2. 概要

[`Rotate-Log.ps1`](Rotate-Log.md) と同等の機能を Linux で実装したもの。動作・命名規則・リストファイル仕様・世代保持ロジックはすべて Windows 版と同じ。

## 3. 前提条件

| 項目 | 内容 |
|---|---|
| ランタイム | Bash 4+（連想配列を使用） |
| 必須 CLI | `find`、`stat`（GNU coreutils）、`gzip`（圧縮利用時）、`mv` / `cp` / `chmod` |
| 認証 | 不要（ローカル FS 操作のみ） |
| 必要権限 | 対象ファイル・ディレクトリの読み書き、削除 |

## 4. オプション

### 対象指定

| Flag | 引数 | 必須 | デフォルト | 説明 |
|---|---|---|---|---|
| `-p` | `<path>` | △ | — | 単一ファイル or ディレクトリ。`-L` と併用可 |
| `-L` | `<list-file>` | △ | — | パスリストファイル。`-p` と併用可 |
| `-P` | `<pattern>` | — | `*.log` | ディレクトリ展開時の glob |

`-p` と `-L` の少なくとも一方が必須。

### ローテート発動条件（少なくとも一方が必須）

| Flag | 引数 | 説明 |
|---|---|---|
| `-s` | `<MB>` | サイズが MB 以上で発動。0 で無効 |
| `-a` | `<days>` | mtime が N 日以上前で発動。0 で無効 |

### ローテート挙動

| Flag | 引数 | 説明 |
|---|---|---|
| `-c` | — | gzip 圧縮 |
| `-k` | `<count>` | 世代保持数（0 で無効、最大 10000） |
| `-T` | — | rename ではなく copy + truncate |
| `-n` | — | Dry-run（実操作なし、ログのみ） |
| `-h` | — | usage 表示 |

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 1 | usage / バリデーション失敗 |
| 2 | `-L` で指定したリストファイルが存在しない |

個別ファイルの失敗はスクリプト全体に波及しない（ログ出力して次へ）。

## 6. リストファイル形式

各行は `<path> [Key=Value ...]` の形式で、**エントリ単位でオプションを上書き**できる。詳細は [`Rotate-Log.md`](Rotate-Log.md#6-リストファイル形式) と同一。

### 例

```
# 行頭 '#' はコメント、空行は無視
# <path> [Key=Value ...]
#
# Recognised keys (CLI と同じ名前、case-sensitive):
#   Pattern, MaxSizeMB, MaxAgeDays, Compress, RetentionCount, CopyTruncate

# CLI / config の既定をそのまま使う
/var/log/myapp/app.log

# size と retention だけ上書き
/var/log/critical/audit.log MaxSizeMB=200 RetentionCount=90

# Tomcat: 大きいファイル、copy+truncate
/opt/tomcat/logs/catalina.out MaxSizeMB=500 CopyTruncate=true Compress=true RetentionCount=14

# ディレクトリで pattern 上書き
/var/log/nginx Pattern=access*.log MaxAgeDays=1 Compress=true RetentionCount=30
```

### 解決順位（高 → 低）

```
1. 行内の Key=Value
2. CLI 引数（-s / -a / -c / -k / -P / -T）
3. config/<env>/rotate_log.conf
4. config/common/rotate_log.conf
5. スクリプトの既定値
```

不明なキー / 不正な値 → WARN で当該キーだけ無視。両トリガが effective=0 のエントリ → そのエントリだけスキップ。他は継続。

## 7. ローテート命名規則

```
<original>.YYYYMMDD-HHMMSS        ← rename / copy 直後
<original>.YYYYMMDD-HHMMSS.gz     ← -c 指定時
```

タイムスタンプは UTC。

## 8. 使用例

### 単一ファイル：100MB 超で rotate、gzip、7 世代保持
```bash
./scripts/linux/bash/rotate_log.sh -p /var/log/myapp/app.log -s 100 -c -k 7
```

### ディレクトリ一括：1 日経過で全 *.log を rotate
```bash
./rotate_log.sh -p /var/log/myapp -P "*.log" -a 1 -c -k 30
```

### リストファイル：複数対象を一括処理
```bash
./rotate_log.sh -L /etc/ops-scripts/logs.txt -a 1 -c -k 14
```

`/etc/ops-scripts/logs.txt` の例：
```
# Tomcat
/opt/tomcat/logs/catalina.out
/opt/tomcat/logs/localhost_access_log.txt

# Application
/var/log/myapp

# Nginx
/var/log/nginx/access.log
/var/log/nginx/error.log
```

### `-p` と `-L` の併用
```bash
./rotate_log.sh -p /var/log/critical.log -L /etc/ops-scripts/logs.txt -s 200 -c
```

### 開きっぱなしのプロセス向け（copy + truncate）
```bash
./rotate_log.sh -p /opt/tomcat/logs/catalina.out -s 500 -T -c -k 14
```

### Dry-run
```bash
./rotate_log.sh -L /etc/ops-scripts/logs.txt -a 1 -c -k 7 -n
```

### cron 例（毎日 03:00）
```cron
0 3 * * *  /opt/ops-scripts/scripts/linux/bash/rotate_log.sh -L /etc/ops-scripts/logs.txt -a 1 -c -k 30 >> /var/log/ops/rotate.log 2>&1
```

### systemd timer 例
```ini
# /etc/systemd/system/ops-rotate-logs.service
[Unit]
Description=ops-scripts log rotation

[Service]
Type=oneshot
ExecStart=/opt/ops-scripts/scripts/linux/bash/rotate_log.sh -L /etc/ops-scripts/logs.txt -a 1 -c -k 30
```

```ini
# /etc/systemd/system/ops-rotate-logs.timer
[Unit]
Description=Daily log rotation

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

## 9. 出力例

### 通常成功
```
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Args validated: path='' pathList='/etc/ops-scripts/logs.txt' pattern='*.log' maxSizeMB=0 maxAgeDays=1 compress=1 retention=30 copyTruncate=0 dryRun=0
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Pre-check start
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Loaded paths from list: pathList=/etc/ops-scripts/logs.txt count=5
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Pre-check passed: matched=8
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Main start
[2026-05-09 03:00:02] [INFO ] (rotate_log.sh:18342) Rotated (rename): from=/opt/tomcat/logs/catalina.out to=/opt/tomcat/logs/catalina.out.20260509-030002 reason=mtime_older_than_1d
[2026-05-09 03:00:03] [INFO ] (rotate_log.sh:18342) Compressed: file=/opt/tomcat/logs/catalina.out.20260509-030002.gz
[2026-05-09 03:00:05] [INFO ] (rotate_log.sh:18342) Pruned: file=/opt/tomcat/logs/catalina.out.20260408-030002.gz
[2026-05-09 03:00:05] [INFO ] (rotate_log.sh:18342) Main complete
[2026-05-09 03:00:05] [INFO ] (rotate_log.sh:18342) Script end: status=success exitCode=0 rotated=6 skipped=2
```

### 冪等スキップ（対象ファイルなし）
```
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Args validated: path='/var/log/myapp' pathList='' pattern='*.log' maxSizeMB=100 maxAgeDays=0 compress=0 retention=0 copyTruncate=0 dryRun=0
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Pre-check start
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Skipped (idempotent): reason=no_matching_files
[2026-05-09 03:00:01] [INFO ] (rotate_log.sh:18342) Script end: status=skipped exitCode=0 rotated=0 skipped=0
```

## 10. 注意事項

- **ファイルが書き込み中のプロセスに掴まれた状態で `mv`** すると、プロセスは古い inode に書き続ける。reopen に対応していない場合は `-T`（copytruncate）を使用
- **CopyTruncate は厳密にアトミックではない**（コピー中の書き込みは重複し得る）
- **`mv` 後の新規ファイル**は元の mode を chmod で復元するが、所有者・SELinux ラベル等は復元しない（必要に応じて呼び出し側で対応）
- **GNU `stat` 前提**（`stat -c %s` / `-c %Y` / `-c %a`）。BSD（macOS）では動作しない
- **シンボリックリンク**は `find -type f` で除外済み

## 11. 関連

- ペア（Windows 版）: [`Rotate-Log.md`](Rotate-Log.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)

