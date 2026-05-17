# Server Compare Tools

サーバー設定の現新比較ツール。**このフォルダ一式をコピーするだけで動きます。**

```
tools/server-compare/
├── Get-ServerInfo.ps1         # Windows 情報収集
├── Get-ServerInfo.bat         # Windows 起動用バッチ
├── get_server_info.sh         # Linux  情報収集
├── Compare-ServerInfo.ps1     # 比較ラッパー（python3 があれば共通エンジンへ委譲）
├── Compare-ServerInfo.bat     # Windows 起動用バッチ
├── compare_server_info.sh     # Linux 用 比較ラッパー
└── compare_server_info.py     # 共通比較エンジン（カテゴリ/HTML 出力の真実の源）
```

> **比較ロジックの一元化**: 比較カテゴリ・volatile 値の除外ルール・HTML レポートは
> `compare_server_info.py` に集約しています。`change_detect.sh compare`、
> `compare_server_info.sh`、`Compare-ServerInfo.ps1`（python3 が利用可能な場合）
> はすべて同じエンジンを呼び出すため、OS によらず同じ結果が得られます。
>
> python3 が制限された Windows 環境では Compare-ServerInfo.ps1 が PowerShell
> ネイティブ実装に自動フォールバックします（カテゴリ・出力は若干簡略化されます）。

---

## 前提

| ツール | 必要なもの |
|---|---|
| `Get-ServerInfo.ps1` | Windows PowerShell 5.1+ |
| `get_server_info.sh` | Bash 4+、python3 |
| `Compare-ServerInfo.ps1` | Windows PowerShell 5.1+ |

---

## 使い方

### 手順 1：情報収集（旧サーバー・新サーバーで各自実行）

```powershell
# Windows
.\Get-ServerInfo.ps1 -OutputPath before.json
.\Get-ServerInfo.ps1 -OutputPath after.json
```

```bash
# Linux（実行権限付与が必要な場合）
chmod +x get_server_info.sh
./get_server_info.sh -o before.json
./get_server_info.sh -o after.json
```

カテゴリを絞る場合：

```powershell
.\Get-ServerInfo.ps1 -Category os,network,services -OutputPath before.json
```

```bash
./get_server_info.sh -c os,network,services -o before.json
```

### 手順 2：比較

```powershell
# コンソールのみ
.\Compare-ServerInfo.ps1 -Before before.json -After after.json

# HTML レポートも生成
.\Compare-ServerInfo.ps1 -Before before.json -After after.json -HtmlReport report.html

# 差分のみ表示
.\Compare-ServerInfo.ps1 -Before before.json -After after.json -DiffOnly

# カテゴリ絞り込み
.\Compare-ServerInfo.ps1 -Before before.json -After after.json -Category services,packages
```

---

## 収集カテゴリ

| カテゴリ | 内容 |
|---|---|
| `os` | OS バージョン、ホスト名、タイムゾーン |
| `network` | IP、ルーティング、DNS、hosts |
| `services` | サービス一覧（状態・起動設定） |
| `packages` | インストール済みパッケージ |
| `users` | ローカルユーザー・グループ |
| `filesystem` | ドライブ使用状況 |
| `environment` | システム環境変数 |
| `security` | ファイアウォール設定 |
