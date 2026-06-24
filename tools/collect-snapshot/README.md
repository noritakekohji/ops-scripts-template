# collect-snapshot

断面情報収集ラッパー。基盤テスト実施前に、サーバーの状態スナップショットを
1コマンドで収集して ZIP ファイルにまとめます。

## ファイル構成

```
tools/collect-snapshot/
├── CollectSnapshot.ps1      # Windows 本体（CUI + TUI）
├── collect_snapshot.sh      # Linux 本体（CUI + TUI）
├── collect_snapshot.bat     # Windows 起動バッチ（ダブルクリックで TUI）
├── ReportSnapshot.ps1       # ZIP 解凍 + HTML レポート生成（Windows）
├── report_snapshot.bat      # レポート起動バッチ
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

## レポート生成（ReportSnapshot）

収集済み ZIP を解凍し、JSON から HTML レポートを一括生成します（Windows のみ）。

### 単一スナップショットレポート

```powershell
# ZIP からサマリ HTML を生成
.\ReportSnapshot.ps1 -ZipPath .\snapshots\host_label_20260617.zip

# 出力先を指定
.\ReportSnapshot.ps1 -ZipPath .\snapshots\host_label_20260617.zip -OutputDir .\reports

# bat 経由
.\report_snapshot.bat .\snapshots\host_label_20260617.zip
```

### 2 つのスナップショットを比較

2 つの ZIP を指定すると `server-snapshot/compare_server_info.py` を使って差分レポートを生成します。

```powershell
# before / after の差分レポート
.\ReportSnapshot.ps1 -ZipPath before.zip -CompareWith after.zip

# 差分のみ表示
.\ReportSnapshot.ps1 -ZipPath before.zip -CompareWith after.zip -DiffOnly
```

### オプション

| パラメータ | 説明 |
|---|---|
| `-ZipPath` | 対象 ZIP ファイルパス（必須） |
| `-CompareWith` | 比較対象の ZIP。指定すると差分レポートモード |
| `-OutputDir` | レポート出力先。既定は ZIP と同じディレクトリ |
| `-DiffOnly` | Compare モードで差分のみ表示 |
| `-KeepExtracted` | 解凍ファイルを削除せず残す |

### レポート出力例

```
snapshots/
├── host_label_20260617.zip
├── report_host_label_20260617.html              # 単一レポート
└── compare_before_vs_after.html                  # 差分レポート
```

### 前提（レポート生成）

| モード | 必要なもの |
|---|---|
| 単一レポート | PowerShell 5.1+ のみ |
| 差分レポート | PowerShell 5.1+ + `python3`（compare_server_info.py 用） |

### 終了コード（ReportSnapshot）

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 1 | 引数不正 / ZIP 未検出 |
| 2 | ZIP 内に JSON が見つからない |
| 10 | 前提コマンド不足（compare モードで python3 なし） |

## テスト

```bash
# Linux
bats tests/bats/collect_snapshot.bats

# Windows
powershell.exe -NoProfile -Command "Invoke-Pester tests\pester\CollectSnapshot.Tests.ps1"
```
