# 設定ファイル

スクリプトの挙動を決める変数（リージョン、保持日数、冪等性ウィンドウ 等）をリポジトリ管理する場所。

## レイアウト

```
config/
├── common/                       # 全環境共通の既定値（基本コメントアウト）
│   ├── ops.conf                  # 全スクリプト共通の既定（Region 等）
│   ├── backup_ami.conf           # スクリプト別の既定値（PS / Bash 共有）
│   ├── backup_ebs_snapshot.conf
│   ├── ec2ctl.conf
│   ├── rotate_log.conf
│   ├── s3upload.conf
│   ├── sqlserverctl.conf
│   └── tomcatctl.conf
├── dev/                          # 開発：短い retention、待機なし、暗号化なし
├── staging/                      # ステージング：本番に近いが短期保持
└── production/                   # 本番：長期 retention、KMS 暗号化、長い待機
```

各環境ディレクトリには **差分のみ** 配置すれば良い（CLI / 行内 / `<env>/<script>.conf` / `<env>/ops.conf` / `common/<script>.conf` / `common/ops.conf` / 既定値、の順で解決）。

`OPS_ENV` で切替：`OPS_ENV=dev` / `staging` / `production`。未設定なら `common/` のみ参照。

## 解決の優先順位（高優先 → 低優先）

1. **CLI 引数**（`-Region ap-northeast-1` 等）
2. `config/<env>/<script-name>.conf`
3. `config/<env>/ops.conf`
4. `config/default/<script-name>.conf`
5. `config/default/ops.conf`
6. **スクリプトのハードコード既定値**

CLI で明示されたものは常に勝つ（運用中の緊急上書きが効く）。

## 環境の選択

`OPS_ENV` 環境変数で切り替え。未設定なら `common` のみ参照されます。

```bash
OPS_ENV=production ./scripts/aws/bash/backup_ami.sh -i i-0abc -p prod-web
```

## ファイルフォーマット

```ini
# 行頭 '#' はコメント、空行は無視

# キー = 値（前後空白は trim される）
Region        = ap-northeast-1
RetentionDays = 7

# 値に空白を含めたいときはクォート
Description = "production weekly backup"

# bool は true / false（小文字推奨）
NoReboot = true
```

| ルール | 内容 |
|---|---|
| 1 行 1 設定 | `Key = Value` |
| コメント | 行頭 `#` のみ（行末コメントは非対応） |
| 空行 | 無視 |
| 前後空白 | キー・値ともに自動 trim |
| クォート | `"..."` / `'...'` で囲った場合は除去 |
| 文字コード | UTF-8 |

## 命名規約

| ファイル | 役割 |
|---|---|
| `ops.conf` | 全スクリプト共通の既定値（Region 等） |
| `<feature>.conf` | その機能固有の既定値（**Windows / Linux 共有、snake_case 小文字**） |

**PowerShell と Bash のペアは同じ config ファイルを共有**します（snake_case の小文字に統一）。

| 機能 | スクリプト | 共有 config |
|---|---|---|
| AMI バックアップ | `Backup-Ami.ps1` / `backup_ami.sh` | `backup_ami.conf` |
| EBS スナップショット | `Backup-EbsSnapshot.ps1` / `backup_ebs_snapshot.sh` | `backup_ebs_snapshot.conf` |
| ログローテーション | `Rotate-Log.ps1` / `rotate_log.sh` | `rotate_log.conf` |
| EC2 ライフサイクル | `Ec2Ctl.ps1` / `ec2ctl.sh` | `ec2ctl.conf` |

config 内のキーは **PascalCase**（PowerShell の CLI オプション名と一致：`Region`、`RetentionDays`、`MaxSizeMB` 等）。Bash 側もこの PascalCase キーを参照する。

## セキュリティ

- **シークレットを書かない**（パスワード、トークン、API キー）。Vault 参照のみ可
- 機密になりうる値があれば、参照キー形式（例：`Password = ref://vault/production/db/password`）で書き、スクリプト側が `lib/secrets.{psm1,sh}` 経由で実値を取得する設計を v1.1+ で導入予定
- gitleaks の allowlist は `config/<env>/secrets.ref.yml` を既に除外。`.conf` も今後参照キーが増えてきたら追加検討

## 例

```ini
# config/production/Backup-Ami.conf
# 本番環境の AMI バックアップ既定値（運用ルール）

Region             = ap-northeast-1
RetentionDays      = 7
MinIntervalMinutes = 5
NoReboot           = true
Wait               = true
```

```ini
# config/default/ops.conf
# どの環境でも有効な既定（リージョンは Tokyo を既定にする）

Region = ap-northeast-1
```

これにより、cron 登録は短く済みます：

```bash
# Before
./backup_ami.sh -i i-0abc -p prod-web -r ap-northeast-1 -d 7 -m 5 -w

# After
OPS_ENV=production ./backup_ami.sh -i i-0abc -p prod-web
```

## 取得 API

### PowerShell（`lib/powershell/Config.psm1`）

```powershell
Import-Module (Resolve-Path "<repo>/lib/powershell/Config.psm1").Path -Force

$cfg = Get-OpsConfig -Name 'Backup-Ami'
# $cfg は @{ Region='ap-northeast-1'; RetentionDays='7'; ... } のハッシュテーブル
```

### Bash（`lib/bash/config.sh`）

```bash
source "<repo>/lib/bash/config.sh"

load_ops_config "backup_ami"
echo "${OPS_CONFIG[Region]:-default}"
```
