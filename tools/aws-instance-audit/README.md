# AWS Instance Audit

EC2 インスタンス上の OS から、**自分自身の AWS コンテキスト** を IMDSv2 + AWS CLI で
収集して JSON / HTML にまとめるツールです。「このインスタンスにはどの IAM ロールが付いて
いて、どんな Security Group / VPC 構成なのか」を 1 コマンドで棚卸しできます。

**このフォルダ一式をコピーすれば動きます。**

```
tools/aws-instance-audit/
├── aws_instance_audit.sh       # Linux 本体（JSON 組み立てまで自己完結）
├── Get-AwsInstanceAudit.ps1    # Windows 本体（JSON 組み立てまで自己完結）
├── aws_instance_audit.bat      # Windows 起動用バッチ
├── render_report.py            # HTML レポート生成（--html / -HtmlReport 指定時のみ使用）
└── README.md
```

---

## 収集する情報

| カテゴリ (`-c` / `-Category`) | 内容 |
|---|---|
| `instance` | instance-id / type / AMI / AZ / region / private・public IP / VPC / Subnet / **タグ** |
| `iam`      | インスタンスプロファイルの **IAM ロール名**、アタッチされた managed / inline ポリシー一覧 |
| `sg`       | インスタンスにアタッチされた **Security Group の ingress / egress ルール** |
| `network`  | **VPC / Subnet / ENI / Route Table** の構成 |
| `all`      | 上記すべて（既定） |

---

## 前提

| 項目 | 内容 |
|---|---|
| 実行場所 | **EC2 インスタンス上**（IMDS `169.254.169.254` に到達できること） |
| 必須 | AWS CLI v2 |
| 任意 | `python3`（**HTML レポート `--html` / `-HtmlReport` を出すときだけ** 必要。JSON 出力には不要） |
| Linux | Bash 4.4+、`curl` |
| Windows | PowerShell 5.1+ |
| IAM 権限 | インスタンスプロファイルのロールに読み取り権限が必要：<br>`ec2:DescribeSecurityGroups`, `ec2:DescribeVpcs`, `ec2:DescribeSubnets`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeRouteTables`, `ec2:DescribeTags`, `iam:GetRole`, `iam:ListAttachedRolePolicies`, `iam:ListRolePolicies`, `sts:GetCallerIdentity` |

> IMDSv2（トークン必須）に対応しています。IMDSv1 のみ許可の環境でも動作します。

> **JSON 出力は python3 / jq に依存しません。** Linux 版は `aws --query`（JMESPath）+
> `--output text` で値を抽出し、Windows 版は `ConvertFrom-Json` / `ConvertTo-Json` で
> 組み立てます。python3 が制限される環境でも JSON 棚卸しはそのまま使えます
> （`--html` / `-HtmlReport` を付けたときだけ python3 が必要）。

---

## 使い方

### Linux

```bash
chmod +x aws_instance_audit.sh           # 初回のみ

# 全カテゴリを収集して自動命名の JSON に出力
./aws_instance_audit.sh

# カテゴリを絞り、HTML レポートも生成
./aws_instance_audit.sh -c iam,sg -o audit.json --html audit.html

# リージョン上書き
./aws_instance_audit.sh -r ap-northeast-1
```

### Windows

```cmd
:: バッチ起動（推奨）
aws_instance_audit.bat
aws_instance_audit.bat -Category iam,sg -HtmlReport audit.html
```

```powershell
# PowerShell 直接実行
.\Get-AwsInstanceAudit.ps1 -Category all -OutputPath audit.json -HtmlReport audit.html
```

### 保存済み JSON からレポート再生成（Windows のみ）

過去に保存した監査 JSON を読み込み、aws CLI を呼ばずに HTML レポートを再生成できます。

```powershell
# HTML レポートを生成（python3 が必要）
.\Get-AwsInstanceAudit.ps1 -FromJson saved.json -HtmlReport report.html

# JSON を別パスへコピー
.\Get-AwsInstanceAudit.ps1 -FromJson saved.json -OutputPath copy.json
```

---

## 出力 JSON の構造（抜粋）

```json
{
  "meta": { "tool": "aws_instance_audit", "collected_at": "...", "region": "ap-northeast-1", "instance_id": "i-0abc..." },
  "instance": {
    "instance_id": "i-0abc...", "instance_type": "t3.micro", "ami_id": "ami-0...",
    "availability_zone": "ap-northeast-1a", "private_ip": "10.0.1.23",
    "vpc_id": "vpc-0...", "subnet_id": "subnet-0...", "tags": { "Name": "web01", "Env": "prod" }
  },
  "iam": {
    "role_name": "web-instance-role", "role_arn": "arn:aws:iam::...:role/web-instance-role",
    "attached_policies": [ { "name": "AmazonS3ReadOnlyAccess", "arn": "arn:aws:iam::aws:policy/..." } ],
    "inline_policies": [ "app-secrets-read" ]
  },
  "security_groups": [
    { "group_id": "sg-0...", "group_name": "web-sg", "description": "web tier",
      "ingress": [ { "protocol": "tcp", "from_port": 443, "to_port": 443, "cidrs": ["0.0.0.0/0"], "sg_refs": [] } ],
      "egress":  [ { "protocol": "all", "from_port": null, "to_port": null, "cidrs": ["0.0.0.0/0"], "sg_refs": [] } ] }
  ],
  "network": {
    "vpc":    { "vpc_id": "vpc-0...", "cidr": "10.0.0.0/16", "is_default": false },
    "subnet": { "subnet_id": "subnet-0...", "cidr": "10.0.1.0/24", "az": "ap-northeast-1a" },
    "enis":   [ { "eni_id": "eni-0...", "private_ip": "10.0.1.23", "groups": ["sg-0..."] } ],
    "route_tables": [ { "route_table_id": "rtb-0...", "routes": [ { "dest": "0.0.0.0/0", "target": "igw-0..." } ] } ]
  }
}
```

> 上記は整形例です。Linux 版（Bash ネイティブ）は依存を増やさないため **1 行のコンパクト
> JSON** を出力します（内容・スキーマは同一）。Windows 版（`ConvertTo-Json`）はインデント
> 付きで出力します。いずれも `render_report.py` で同じ HTML になります。

HTML レポート（`--html` / `-HtmlReport`）は同じ内容を表形式で見やすく整形します。

---

## 終了コード

| Code | 意味 |
|---|---|
| 0  | 成功 |
| 1  | 引数不正 |
| 2  | IMDS 到達不可（EC2 外 or IMDS 無効）|
| 5  | 出力書き込み / HTML 生成失敗 |
| 10 | 前提コマンド不在（aws CLI / `--html` 指定時のみ python3）|
| 20 | AWS 認証・権限エラー |

---

## 注意

- 取得できる範囲は **インスタンスプロファイルのロールに付与された権限** に依存します。
  権限不足のカテゴリは WARN ログを出して空のまま続行します（全体は失敗しません）。
- 出力 JSON にはアカウント ID・ARN・IP・SG ルールなどが含まれます。共有時は取り扱いに注意してください。
- `server-snapshot` と組み合わせれば、**変更前後の AWS 構成差分** も取れます。
