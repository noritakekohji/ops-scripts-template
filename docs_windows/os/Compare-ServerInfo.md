# `Compare-ServerInfo.ps1`

> 2 つのサーバー設定 JSON（現行・新規）を比較し、差分をコンソールと HTML レポートで出力する。

[← 仕様書一覧](README.md) | [← 共通仕様](../../shell-specification.md)

---

## 1. 配置

```
scripts_windows/os/Compare-ServerInfo.ps1
```

Windows・Linux どちらの JSON も読み取れる（PowerShell 5.1+）。

---

## 2. パラメータ

| パラメータ | 型 | 必須 | 説明 |
|---|---|---|---|
| `-Before` | string | ✅ | 比較元（旧サーバー）の JSON ファイルパス |
| `-After` | string | ✅ | 比較先（新サーバー）の JSON ファイルパス |
| `-HtmlReport` | string | — | HTML レポートの出力先パス |
| `-Category` | string[] | — | 比較するカテゴリ（省略時: 両 JSON にあるすべて） |
| `-DiffOnly` | switch | — | 差分のある行のみ表示（コンソール） |

---

## 3. コンソール出力

差分ステータスを色分けで表示します。

| 状態 | 色 | 意味 |
|---|---|---|
| `SAME` | グレー | 一致 |
| `CHANGED` | 黄色 | 値が異なる（Before → After） |
| `REMOVED` | 赤 | Before にのみ存在 |
| `ADDED` | シアン | After にのみ存在 |

```
=== SERVICES ===
  same=45  changed=2  removed=1  added=3

  CHANGED  Tomcat10                        before: status=stopped  after: status=running
  REMOVED  IIS                             status=running, start_type=auto
  ADDED    nginx                           status=running, start_type=auto
  SAME     sshd                            status=running, start_type=enabled
```

---

## 4. HTML レポート

`-HtmlReport` を指定すると自己完結型の HTML ファイルを生成します。

- **サマリーカード**: 差分数・一致数・変更・削除・追加の集計
- **サーバー情報**: 比較前後のホスト名と収集日時
- **カテゴリ別テーブル**: 色分け行（同一=薄灰、変更=黄、削除=赤、追加=青）
- **フィルターボタン**: All / Changed / Removed / Added / Differences only

---

## 5. 使用例

### 全カテゴリ比較（コンソールのみ）

```powershell
.\Compare-ServerInfo.ps1 -Before server-old.json -After server-new.json
```

### HTML レポートも生成

```powershell
.\Compare-ServerInfo.ps1 `
    -Before  C:\temp\server-before.json `
    -After   C:\temp\server-after.json `
    -HtmlReport C:\temp\compare-report.html
```

### 差分のみ表示

```powershell
.\Compare-ServerInfo.ps1 -Before before.json -After after.json -DiffOnly
```

### 特定カテゴリのみ比較

```powershell
.\Compare-ServerInfo.ps1 -Before before.json -After after.json -Category services,packages
```

---

## 6. ワークフロー（移行前後の確認）

```
【旧サーバー】                       【新サーバー】
Get-ServerInfo.ps1          →  Get-ServerInfo.ps1
または get_server_info.sh        または get_server_info.sh
       ↓                                   ↓
  server-before.json             server-after.json
       ↓                                   ↓
       └──────── Compare-ServerInfo.ps1 ────┘
                        ↓
               コンソール差分 + report.html
```

---

## 7. 終了コード

| Code | 意味 |
|---|---|
| 0 | 成功 |
| 2 | 入力ファイルが見つからない |
| 4 | 比較処理エラー |

---

## 8. 関連

- 収集ツール: [`Get-ServerInfo.md`](Get-ServerInfo.md)
- 共通仕様: [shell-specification.md](../../shell-specification.md)
