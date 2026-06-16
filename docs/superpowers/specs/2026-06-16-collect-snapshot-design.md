# collect-snapshot 設計仕様書

**作成日**: 2026-06-16  
**ステータス**: 承認済み

---

## 1. 概要

基盤テスト実施前に、サーバーの断面情報（スナップショット）を1コマンドで収集するラッパーツール。
既存の `tools/` 配下のツールを順番に呼び出し、結果を1つの ZIP ファイルにまとめる。

---

## 2. 対象ツール

以下の3ツールを **この順番に** 実行する。

| 順序 | ツール | 収集内容 |
|---|---|---|
| 1 | `server-snapshot` | OS・サービス・パッケージ・ネットワーク設定・ユーザー・環境変数・ファイルシステム |
| 2 | `port-inventory` | 待受ポート（TCP/UDP）とプロセスの対応 |
| 3 | `aws-instance-audit` | EC2 の IAM ロール・Security Group・VPC/Subnet 構成（EC2 環境のみ有効） |

---

## 3. ファイル構成

```
tools/collect-snapshot/
├── CollectSnapshot.ps1      # Windows 本体（CUI + TUI）
├── collect_snapshot.sh      # Linux 本体（CUI + TUI）
├── collect_snapshot.bat     # Windows 起動バッチ（--menu 付きで PS1 を呼ぶ）
└── README.md
```

各ツールの実体（`ServerSnapshot.ps1` 等）は `../server-snapshot/` など**相対パスで参照**する。
コピーはしない（自己完結ルールの例外：本ツールはリポジトリ内ツールへのオーケストレータとして機能する）。

---

## 4. インターフェース

### 4.1 CUI モード（デフォルト）

引数なし、または `--label` / `--output` のみ指定した場合に動作。
インタラクションなしで全3ツールを自動実行する。

```bash
# 全自動実行（ラベルなし）
bash collect_snapshot.sh

# ラベル付き
bash collect_snapshot.sh --label pre-upgrade

# 保存先指定
bash collect_snapshot.sh --label pre-upgrade --output /mnt/snapshots
```

```powershell
# 全自動実行
.\CollectSnapshot.ps1

# ラベル付き
.\CollectSnapshot.ps1 -Label pre-upgrade

# 保存先指定
.\CollectSnapshot.ps1 -Label pre-upgrade -Output D:\snapshots
```

**実行時の標準出力例:**

```
[collect-snapshot] host=web01  start=2026-06-16 14:30:00
[collect-snapshot] output=./snapshots/web01_pre-upgrade_20260616-143000/
[1/3] server-snapshot     ... done (exit=0)
[2/3] port-inventory      ... done (exit=0)
[3/3] aws-instance-audit  ... done (exit=0)
[collect-snapshot] compressing ... web01_pre-upgrade_20260616-143000.zip
[collect-snapshot] all done.
```

### 4.2 TUI モード（`--menu` フラグ）

`--menu` フラグ指定時、または `collect_snapshot.bat` ダブルクリック時に動作。
端末上に対話メニューを表示して操作する。

```bash
bash collect_snapshot.sh --menu
```

```powershell
.\CollectSnapshot.ps1 --menu
# bat ダブルクリックでも同様
```

**TUI の4ステップ:**

```
Step 1: ラベル入力
  ラベル > pre-upgrade_          （空 Enter でスキップ）

Step 2: 保存先確認・変更
  保存先 [Enter でデフォルト ./snapshots/] > _

Step 3: 実行ツール選択（スペースで ON/OFF、Enter で確定）
  [x] 1. server-snapshot       — OS・サービス・パッケージ等
  [x] 2. port-inventory        — 待受ポート棚卸し
  [x] 3. aws-instance-audit    — EC2 IAM/SG/VPC 構成

Step 4: 実行・進捗表示
  [1/3] server-snapshot     ... 完了
  [2/3] port-inventory      ... 完了
  [3/3] aws-instance-audit  ... 実行中...
  完了: web01_pre-upgrade_20260616-143000.zip を作成しました。
```

---

## 5. 出力仕様

### 5.1 フォルダ命名規則

```
<保存先>/snapshots/<hostname>_<label>_<timestamp>/
```

| 要素 | 内容 |
|---|---|
| `hostname` | `hostname` コマンド / `$env:COMPUTERNAME` の値 |
| `label` | `--label` / `-Label` 指定値。省略時はフォルダ名から除外 |
| `timestamp` | `YYYYMMDD-HHMMSS` 形式（JST） |

例: `web01_pre-upgrade_20260616-143000/`  
例（ラベルなし）: `web01_20260616-143000/`

### 5.2 出力ファイル構成

```
web01_pre-upgrade_20260616-143000/
├── server-snapshot/
│   └── web01_20260616-143000.json
├── port-inventory/
│   └── web01_20260616-143000.json
├── aws-instance-audit/
│   └── web01_20260616-143000.json
└── collect-snapshot.log              # 実行ログ（exit code・所要時間）
```

### 5.3 ZIP ファイル

全ツール完了後、上記フォルダを ZIP 圧縮して同じ場所に保存。
元フォルダは ZIP 作成後に削除する。

```
./snapshots/web01_pre-upgrade_20260616-143000.zip
```

- Windows: `Compress-Archive` を使用
- Linux: `zip -r`（利用不可の場合は `tar czf` にフォールバック）

---

## 6. エラーハンドリング

### ツール失敗時

| 状況 | 動作 |
|---|---|
| ツールが exit 1（業務エラー） | WARN ログを出して**次のツールへ続行** |
| ツールが exit 10（前提コマンド不在） | WARN ログを出して**次のツールへ続行** |
| ツールスクリプト自体が見つからない | ERROR ログを出してそのツールをスキップ |
| 全ツール失敗 | 空の構造でも ZIP を作り **exit 1** で終了 |
| ZIP 圧縮失敗 | ERROR ログ + **exit 1**（元フォルダは残す） |

失敗ツールの出力フォルダは空で ZIP に含まれる（欠損が視認できる）。

### 前提チェック（起動時）

| 環境 | チェック対象 |
|---|---|
| Windows | PowerShell 5.1+、`Compress-Archive` |
| Linux | `bash` 4+、`python3`（server-snapshot 比較エンジン用）、`zip` または `tar` |

---

## 7. 終了コード

| Code | 意味 |
|---|---|
| 0 | 全ツール正常完了 |
| 1 | 1つ以上のツールが失敗、または ZIP 圧縮失敗 |
| 10 | 前提コマンド不足（zip/tar が両方ない等） |

---

## 8. テスト方針

`tests/bats/collect_snapshot.bats` と `tests/pester/CollectSnapshot.Tests.ps1` を追加。

| テストケース | 検証内容 |
|---|---|
| CUI 全実行 | 3ツールが順番に呼ばれ、ZIP が生成されること |
| ラベルあり | ZIP ファイル名にラベルが含まれること |
| ラベルなし | ZIP ファイル名にラベルが含まれないこと |
| 1ツール失敗 | exit code が 1、残り2ツールの出力は ZIP に含まれること |
| 全ツール失敗 | ZIP が生成され exit 1 |
| 保存先指定 | 指定ディレクトリに ZIP が作られること |
| ツールスクリプト不在 | スキップされて処理が続くこと |

---

## 9. CHANGELOG への追記

`CHANGELOG.md` の `[Unreleased]` セクションに以下を追加する:

```markdown
### Added
- `tools/collect-snapshot` — 断面情報収集ラッパー（server-snapshot / port-inventory / aws-instance-audit を一括実行し ZIP で保存）
```
