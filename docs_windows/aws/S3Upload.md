# `S3Upload.ps1` / `s3upload.sh`

> ローカルファイルを S3 にアップロード。リストファイルで複数対象 + 行内オプションをサポート。Windows / Linux 共通仕様。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

## 1. 配置

| OS | スクリプト |
|---|---|
| Windows | `scripts_windows/aws/S3Upload.ps1` |
| Linux | `scripts_linux/aws/s3upload.sh` |

設定ファイル `config/<env>/s3upload.conf`（PS / Bash 共有、小文字）。

## 2. 動作モード

| Mode | S3 キー | 用途 |
|---|---|---|
| `archive`（既定） | `<prefix>/<filename>.<UTC yyyyMMdd-HHmmss>` | バックアップ（タイムスタンプで世代保持） |
| `mirror` | `<prefix>/<filename>` | 設定ファイルなどの上書き sync |

## 3. 前提

| 項目 | Windows | Linux |
|---|---|---|
| ランタイム | PowerShell 5.1+ | Bash 4+ |
| 必須 | `AWS.Tools.S3` モジュール | `aws` CLI v2 |
| 認証 | デフォルト AWS credential chain |
| IAM | `s3:PutObject`、（`aws:kms` 使用時）`kms:GenerateDataKey` 等 |

## 4. 引数 / オプション

| 項目 | PowerShell | Bash | 必須 | 既定 | 説明 |
|---|---|---|---|---|---|
| Path | `-Path` | `-p` | △ | — | 単一ローカルパス。`-PathList` と併用可 |
| PathList | `-PathList` | `-L` | △ | — | リストファイル。1 行 = 1 アップロード |
| Bucket | `-Bucket` | `-b` | ✅* | — | S3 バケット名（CLI / config / 行内のいずれかで必須） |
| Prefix | `-Prefix` | `-x` | — | 空 | S3 キー prefix |
| Region | `-Region` | `-r` | — | プロファイル既定 | バケットのリージョン |
| StorageClass | `-StorageClass` | `-c` | — | `STANDARD` | `STANDARD` / `STANDARD_IA` / `ONEZONE_IA` / `INTELLIGENT_TIERING` / `GLACIER` / `GLACIER_IR` / `DEEP_ARCHIVE` |
| ServerSideEncryption | `-ServerSideEncryption` | `-e` | — | `none` | `none` / `AES256` / `aws:kms` |
| KmsKeyId | `-KmsKeyId` | `-k` | — | — | SSE が `aws:kms` のとき（KMS キー ID / ARN / alias） |
| Mode | `-Mode` | `-m` | — | `archive` | `archive` / `mirror` |
| WhatIf / dry-run | `-WhatIf` | — | — | — | PS のみ |

\* `-Path` と `-PathList` の少なくとも一方が必須。`Bucket` は CLI / config / 行内のいずれかで必ず解決可能であること。

## 5. リストファイル形式

各行は `<local_path> [Key=Value ...]`。`Key` は CLI と同じ名前（PascalCase、case-sensitive）。

```
# 行頭 '#' はコメント、空行は無視
# <local_path> [Key=Value ...]
# Recognised keys:
#   Bucket, Prefix, Region, StorageClass, ServerSideEncryption,
#   KmsKeyId, Mode

# 既定（CLI / config）をそのまま使う
/var/backups/db/full.bak

# DB バックアップ → 専用バケットに IA で archive
/var/backups/db/full.bak Bucket=my-backups Prefix=db/prod StorageClass=STANDARD_IA Mode=archive

# ログを KMS 暗号化で archive
/var/log/myapp/app.log.20260510-030000.gz Bucket=my-backups Prefix=logs/myapp ServerSideEncryption=aws:kms KmsKeyId=alias/ops Mode=archive

# 設定ファイルを mirror 同期
/etc/myapp/config.yml Bucket=my-config Prefix=prod/myapp Mode=mirror
```

### 解決順位（高 → 低）

```
1. 行内の Key=Value
2. CLI 引数
3. config/<env>/s3upload.conf
4. config/default/s3upload.conf
5. スクリプトの既定値
```

不明なキー / 不正な値 → WARN で当該キーだけ無視。Bucket が解決できないエントリ / ファイル不在 → WARN で当該エントリだけスキップ。

## 6. 設定ファイルでサポートされる項目

| キー | 型 | 説明 |
|---|---|---|
| `Bucket` | string | バケット名 |
| `Prefix` | string | キー prefix |
| `Region` | string | リージョン |
| `StorageClass` | enum | ストレージクラス |
| `ServerSideEncryption` | enum | 暗号化方式 |
| `KmsKeyId` | string | KMS キー（SSE=aws:kms 時） |
| `Mode` | enum | archive / mirror |

## 7. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功（uploaded > 0、失敗ゼロ）/ partial（一部失敗あり）/ skipped（処理対象ゼロ） |
| 1 | 入力バリデーション失敗 |
| 2 | リストファイルが見つからない |
| 4 | すべてのアップロードが失敗 |
| 10 | aws CLI / AWS.Tools.S3 未インストール |

`partial` は終了コード 0 だが、最終ログの `failed=N` で確認できる。

## 8. 使用例

### PowerShell：単発
```powershell
.\S3Upload.ps1 -Path C:\backup\db.bak -Bucket my-backups -Prefix db/prod
```

### PowerShell：リスト一括
```powershell
.\S3Upload.ps1 -PathList C:\ops\s3-list.txt
```

### Bash：単発
```bash
./s3upload.sh -p /var/backups/db/full.bak -b my-backups -x db/prod
```

### Bash：リスト一括（cron）
```cron
0 4 * * *  OPS_ENV=production /opt/ops-scripts/scripts_linux/aws/s3upload.sh -L /etc/ops-scripts/s3-list.txt >> /var/log/ops/s3upload.log 2>&1
```

### rotate_log との組み合わせ
1. `rotate_log.sh -L logs.txt -a 1 -c -k 7` で日次ローテート + gzip
2. `s3upload.sh -L s3-list.txt` で `*.gz` を S3 にアーカイブ
3. ローカルは `-k 7` で 7 世代保持、S3 で長期保管

## 9. 出力例

### 通常成功（複数アップロード）
```
[... ] Config loaded: env=production keys=4
[... ] Args validated: path='' pathList='/etc/ops-scripts/s3-list.txt' bucket='my-backups' ...
[... ] Pre-check passed: entryCount=3
[... ] Main start
[... ] Uploaded: file=/var/backups/db/full.bak bucket=my-backups key=db/prod/full.bak.20260510-040000 bytes=1048576000 storageClass=STANDARD_IA sse=none mode=archive
[... ] Uploaded: file=/var/log/myapp/app.log.gz bucket=my-backups key=logs/myapp/app.log.gz.20260510-040000 bytes=2097152 storageClass=STANDARD sse=aws:kms mode=archive
[... ] Uploaded: file=/etc/myapp/config.yml bucket=my-config key=prod/myapp/config.yml bytes=512 storageClass=STANDARD sse=none mode=mirror
[... ] Main complete
[... ] Script end: status=success exitCode=0 uploaded=3 skipped=0 failed=0
```

### 一部失敗
```
[... ] Uploaded: file=/var/backups/db/full.bak ...
[... ] Upload failed: file=/missing.txt bucket=my-backups key=... error=...
[... ] Script end: status=partial exitCode=0 uploaded=1 skipped=0 failed=1
```

## 10. 注意事項

- **シークレットのアップロード禁止**：パスワード・秘密鍵入りファイルを S3 に上げる際は **必ず** `ServerSideEncryption=aws:kms` + 適切な `KmsKeyId` を指定（バケットポリシーでも強制推奨）
- **PowerShell の `aws:kms`**：パラメータ名は `ServerSideEncryptionKeyManagementServiceKeyId`（スクリプトが内部で変換済み）
- **archive モードでのキー衝突**：UTC 秒精度のため、同じ NamePrefix で同一秒内に複数回呼ぶと衝突。通常運用では問題にならない
- **mirror モードでの上書き**：S3 バケットのバージョニングを ON にすれば履歴が残る（推奨）
- **大容量ファイル**：v1 ではマルチパートアップロードを明示制御していない（`aws s3 cp` 既定の閾値で自動切替）

## 11. 関連

- 共通仕様: [shell-specification.md](../../shell-specification.md)
- 設定ファイル: [config/README.md](../../config/README.md)
- ローテーションと組み合わせ: [Rotate-Log.md](Rotate-Log.md) / [rotate_log.md](rotate_log.md)
