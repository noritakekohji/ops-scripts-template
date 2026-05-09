# 設定ファイル

スクリプトの挙動を決める変数（リージョン、保持日数、冪等性ウィンドウ 等）をリポジトリ管理する場所。

## レイアウト

```
config/
├── common/                          # 全環境共通の既定値
│   ├── ops.conf                     # 全スクリプト共通（Region 等）
│   ├── Backup-Ami.conf              # スクリプト別の既定値
│   ├── Backup-EbsSnapshot.conf
│   └── Rotate-Log.conf
├── dev/                             # 環境固有の上書き
├── stg/
└── prd/
    ├── ops.conf
    └── Backup-Ami.conf
```

## 解決の優先順位（高優先 → 低優先）

1. **CLI 引数**（`-Region ap-northeast-1` 等）
2. `config/<env>/<script-name>.conf`
3. `config/<env>/ops.conf`
4. `config/common/<script-name>.conf`
5. `config/common/ops.conf`
6. **スクリプトのハードコード既定値**

CLI で明示されたものは常に勝つ（運用中の緊急上書きが効く）。

## 環境の選択

`OPS_ENV` 環境変数で切り替え。未設定なら `common` のみ参照されます。

```bash
OPS_ENV=prd ./scripts/aws/linux/backup_ami.sh -i i-0abc -p prod-web
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
| `<ScriptName>.conf` | そのスクリプト固有の既定値（PowerShell：PascalCase、Bash：snake_case をそのまま） |

PowerShell スクリプト名と Bash スクリプト名はファイル拡張子なしの名前で識別されます：

| スクリプト | config ファイル名 |
|---|---|
| `Backup-Ami.ps1` | `Backup-Ami.conf` |
| `backup_ami.sh` | `backup_ami.conf` |
| `Rotate-Log.ps1` | `Rotate-Log.conf` |
| `rotate_log.sh` | `rotate_log.conf` |

PowerShell / Bash で同じ機能を持つペアでも、**設定ファイルは別々**になります。これは命名規約が違うためで、両方を維持するのが負担なら片方だけ書いてください（ペアの片方だけ運用するケースが多い前提）。

## セキュリティ

- **シークレットを書かない**（パスワード、トークン、API キー）。Vault 参照のみ可
- 機密になりうる値があれば、参照キー形式（例：`Password = ref://vault/prd/db/password`）で書き、スクリプト側が `lib/secrets.{psm1,sh}` 経由で実値を取得する設計を v1.1+ で導入予定
- gitleaks の allowlist は `config/<env>/secrets.ref.yml` を既に除外。`.conf` も今後参照キーが増えてきたら追加検討

## 例

```ini
# config/prd/Backup-Ami.conf
# 本番環境の AMI バックアップ既定値（運用ルール）

Region             = ap-northeast-1
RetentionDays      = 7
MinIntervalMinutes = 5
NoReboot           = true
Wait               = true
```

```ini
# config/common/ops.conf
# どの環境でも有効な既定（リージョンは Tokyo を既定にする）

Region = ap-northeast-1
```

これにより、cron 登録は短く済みます：

```bash
# Before
./backup_ami.sh -i i-0abc -p prod-web -r ap-northeast-1 -d 7 -m 5 -w

# After
OPS_ENV=prd ./backup_ami.sh -i i-0abc -p prod-web
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
