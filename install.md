# インストール手順

リポジトリの `scripts/` と `config/` を指定サーバへ配備するための手順です。

---

## 1. 前提条件

| OS | 必要なもの |
|---|---|
| Windows | Windows PowerShell 5.1（Windows 10 / Server 2016 以降に標準搭載） |
| Linux | Bash 4 以上 |

---

## 2. 初回準備（ZIP でダウンロードした場合）

GitHub から ZIP でダウンロード・展開したファイルは Windows のセキュリティマークが付き、
そのままでは PowerShell スクリプトが実行できません。
**リポジトリルートで一度だけ**以下を実行してブロックを解除してください。

```powershell
Get-ChildItem -Path "." -Recurse -Filter "*.ps1" | Unblock-File
```

> `git clone` で取得した場合はこの手順は不要です。

---

## 3. 配備リストの準備

配備するファイルをリストファイルに記載します。

**既定のリストファイルパス：**
- env 未指定時： `config\default\deploy_scripts.lst`
- env 指定時：   `config\<env>\deploy_scripts.lst`

**リストファイルの書き方：**

```
# 行頭 # はコメント、空行は無視

# CONF: config/<env>/<filename> を <配備先>/config/<filename> にコピー
CONF, global.conf
CONF, ec2ctl.conf

# SRC: scripts/<repo_filepath> を <配備先>/bin/<basename> にコピー
SRC, aws/powershell/Backup-Ami.ps1
SRC, aws/bash/ec2ctl.sh
```

---

## 4. 配備の実行

### Windows

```bat
install.bat
install.bat dev
install.bat production
install.bat staging -Backup
install.bat dev -WhatIf
```

| 引数 / オプション | 説明 |
|---|---|
| `<env>` | 環境名（省略時は `default`） |
| `-Backup` | 上書き前に既存ファイルをバックアップ |
| `-WhatIf` | Dry-run（実際の変更なし、ログのみ） |

### Linux

```bash
./install.sh
./install.sh dev
./install.sh production
./install.sh staging -b
./install.sh dev -n
```

| 引数 / オプション | 説明 |
|---|---|
| `<env>` | 環境名（省略時は `default`） |
| `-b` | 上書き前に既存ファイルをバックアップ |
| `-n` | Dry-run（実際の変更なし、ログのみ） |

---

## 5. 配備先のレイアウト

```
C:\ProgramData\ops-scripts\      (Linux: /opt/ops-scripts/)
├── bin\                          # スクリプト本体
│   ├── Backup-Ami.ps1
│   └── ec2ctl.sh
└── config\                       # 設定ファイル（フラット配置）
    ├── global.conf
    └── ec2ctl.conf
```

配備先のルートは設定ファイルで変更できます。

```ini
# config/<env>/deploy_scripts.conf
opt_root_dir = D:\ops
```

---

## 6. 設定ファイルの解決ルール

| 実行方法 | 読み込むフォルダ |
|---|---|
| `install.bat`（env なし） | `config\default\` のみ |
| `install.bat dev` | `config\dev\` のみ |
| `install.bat production` | `config\production\` のみ |

env を指定した場合、`config\default\` はマージされません。

---

## 7. 終了コード

| コード | 意味 |
|---|---|
| 0 | 成功（全件配備 / 一部スキップ） |
| 1 | 引数エラー |
| 2 | リストファイルが見つからない |
| 4 | 全件失敗 |
| 5 | 配備先への書き込み権限なし |

---

## 8. 詳細仕様

→ [`docs/scripts/Deploy-Scripts.md`](docs/scripts/Deploy-Scripts.md)
