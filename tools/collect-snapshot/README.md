# collect-snapshot

断面情報収集ラッパー。基盤テスト実施前に、サーバーの状態スナップショットを
1コマンドで収集して ZIP ファイルにまとめます。

## ファイル構成

```
tools/collect-snapshot/
├── CollectSnapshot.ps1      # Windows 本体（CUI + TUI）
├── collect_snapshot.sh      # Linux 本体（CUI + TUI）
├── collect_snapshot.bat     # Windows 起動バッチ（ダブルクリックで TUI）
└── README.md
```

## 収集ツール

| 順序 | ツール | 収集内容 |
|---|---|---|
| 1 | server-snapshot | OS・サービス・パッケージ・ネットワーク・環境変数 |
| 2 | port-inventory | 待受ポート（TCP/UDP）とプロセス対応 |
| 3 | aws-instance-audit | EC2 の IAM/SG/VPC 構成（EC2 環境のみ） |

## 前提

| 環境 | 必要なもの |
|---|---|
| Windows | PowerShell 5.1+、`Compress-Archive` |
| Linux | Bash 4+、`python3`（server-snapshot 比較エンジン用）、`zip` または `tar` |

## 使い方

### CUI モード（全自動）

```powershell
# Windows: 全ツール自動実行
.\CollectSnapshot.ps1

# ラベル付き
.\CollectSnapshot.ps1 -Label pre-upgrade

# 保存先指定
.\CollectSnapshot.ps1 -Label pre-upgrade -Output D:\snapshots
```

```bash
# Linux: 全ツール自動実行
bash collect_snapshot.sh

# ラベル付き
bash collect_snapshot.sh --label pre-upgrade

# 保存先指定
bash collect_snapshot.sh --label pre-upgrade --output /mnt/snapshots
```

### TUI モード（対話メニュー）

```powershell
# Windows
.\collect_snapshot.bat          # ダブルクリック起動
.\CollectSnapshot.ps1 -Menu    # 明示指定
```

```bash
# Linux
bash collect_snapshot.sh --menu
```

## 出力

```
snapshots/
└── web01_pre-upgrade_20260616-143000.zip
    ├── server-snapshot/
    │   └── web01_20260616-143000.json
    ├── port-inventory/
    │   └── web01_20260616-143000.json
    ├── aws-instance-audit/
    │   └── web01_20260616-143000.json
    └── collect-snapshot.log
```

ZIP ファイル名: `<hostname>_<label>_<timestamp>.zip`（ラベルなし時: `<hostname>_<timestamp>.zip`）

## 終了コード

| Code | 意味 |
|---|---|
| 0 | 全ツール正常完了 |
| 1 | 1つ以上のツールが失敗、または ZIP 圧縮失敗 |
| 10 | 前提コマンド不足 |

## テスト

```bash
# Linux
bats tests/bats/collect_snapshot.bats

# Windows
powershell.exe -NoProfile -Command "Invoke-Pester tests\pester\CollectSnapshot.Tests.ps1"
```
