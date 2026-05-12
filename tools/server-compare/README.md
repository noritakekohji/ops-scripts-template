# Server Compare Tools

サーバー設定の現新比較ツール。**このフォルダの 3 ファイルだけコピーすれば動きます。**

```
tools/server-compare/
├── Get-ServerInfo.ps1     # Windows 情報収集
├── get_server_info.sh     # Linux  情報収集
└── Compare-ServerInfo.ps1 # 比較（コンソール + HTML）
```

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
