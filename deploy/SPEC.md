# ops-scripts 自動配布 仕様書

## 目次

1. [概要](#1-概要)
2. [アーキテクチャ](#2-アーキテクチャ)
3. [ファイル構成](#3-ファイル構成)
4. [台帳ファイル仕様 (`servers.yaml`)](#4-台帳ファイル仕様-serversyaml)
5. [パス変換ルール](#5-パス変換ルール)
6. [コピールール](#6-コピールール)
7. [CI パイプライン仕様](#7-ci-パイプライン仕様)
8. [同期スクリプト仕様 (`sync.py`)](#8-同期スクリプト仕様-syncpy)
9. [MR の内容](#9-mr-の内容)
10. [サーバー・ターゲットの追加手順](#10-サーバーターゲットの追加手順)
11. [運用手順](#11-運用手順)
12. [トラブルシューティング](#12-トラブルシューティング)

---

## 1. 概要

`ops-scripts-template` リポジトリで開発・管理する共通運用スクリプトを、
各サーバーの資源を管理するターゲットリポジトリへ自動的に配布する仕組み。

### 目的

| 目的 | 詳細 |
|------|------|
| 一元管理 | スクリプトの開発・修正・テストをこのリポジトリだけで行う |
| 自動配布 | メインブランチへのマージを契機に各リポジトリへ MR を自動作成 |
| レビュー保証 | 直接 push せず MR 経由にすることで変更内容のレビューを必須化 |
| コンフィグ保護 | 環境固有のコンフィグは上書きせず、各リポジトリで独自管理 |

---

## 2. アーキテクチャ

```
┌─────────────────────────────────────────────┐
│        ops-scripts-template                  │
│  (このリポジトリ)                             │
│                                              │
│  scripts_linux/   scripts_windows/           │
│  tools/           config/default/            │
│  deploy/                                     │
│    ├── servers.yaml  ← サーバー台帳           │
│    └── sync.py       ← 同期スクリプト        │
└────────────────────┬────────────────────────┘
                     │ main ブランチへ push
                     ▼
             GitLab CI Pipeline
                     │
        ┌────────────┴────────────┐
        │                         │
        ▼                         ▼
┌──────────────┐          ┌──────────────┐
│ infra-tokyo  │          │ infra-osaka  │
│ (project_id) │          │ (project_id) │
│              │          │              │
│ server-web01 │  MR作成  │ server-web02 │
│ server-db01  │ ───────▶ │              │
└──────────────┘          └──────────────┘
```

### 処理フロー

```
1. main ブランチへの push をトリガーに CI が起動
2. deploy/servers.yaml を読み取りサーバー一覧を取得
3. サーバーをターゲットリポジトリ別にグループ化
4. ターゲットリポジトリごとに（1 回のクローンで複数サーバーを処理）：
   a. リポジトリをクローン
   b. 各サーバーごとに sync/ops-{server名} ブランチを作成
   c. スクリプトをコピー（上書き）
   d. コンフィグをコピー（新規のみ）
   e. コミット & force push
   f. GitLab API で MR を作成（既存 MR がある場合はコメント追加）
```

---

## 3. ファイル構成

```
ops-scripts-template/
├── .gitlab-ci.yml               ← CI パイプライン定義（sync ステージ追加済み）
├── ci/
│   └── deploy/
│       └── sync.gitlab-ci.yml  ← 同期 CI ジョブ定義
└── deploy/
    ├── servers.yaml             ← サーバー台帳（メンテナンス対象）
    ├── sync.py                  ← 同期スクリプト本体
    └── SPEC.md                  ← 本仕様書
```

---

## 4. 台帳ファイル仕様 (`servers.yaml`)

### 全体構造

```yaml
targets:          # ターゲットリポジトリ一覧
  - id: ...
    ...

servers:          # サーバー定義一覧
  - name: ...
    target: ...   # targets[].id を参照
    ...
```

### `targets` セクション

```yaml
targets:
  - id: infra-tokyo              # 識別子（任意の文字列、servers から参照）
    project_id: 101              # GitLab project ID（必須）
    branch: main                 # MR のマージ先ブランチ（デフォルト: main）
    mr_labels:                   # MR に付与するラベル（省略可）
      - ops-sync
      - automated
    mr_assignee_id: null         # MR アサイン先ユーザーID（省略可）
```

| フィールド | 必須 | 型 | 説明 |
|-----------|------|----|------|
| `id` | ✅ | string | サーバー定義から参照する識別子 |
| `project_id` | ✅ | integer | ターゲットリポジトリの GitLab project ID |
| `branch` | — | string | MR のマージ先ブランチ（デフォルト: `main`） |
| `mr_labels` | — | list | MR に付与するラベルのリスト |
| `mr_assignee_id` | — | integer / null | MR のアサイン先ユーザー ID |

### `servers` セクション

```yaml
servers:
  - name: server-web01           # サーバー識別名（必須、一意）
    target: infra-tokyo          # ターゲット ID（必須、targets[].id を指定）
    os: windows                  # OS 種別: windows / linux（必須）
    description: "説明文"         # 説明（MR 本文に表示）
    enabled: true                # false にすると同期スキップ（デフォルト: true）

    scripts_dir: server-web01/scripts  # スクリプトのコピー先（ターゲットリポジトリ内の相対パス）
    config_dir:  server-web01/config   # コンフィグのコピー先

    scripts:                     # コピーするスクリプト（上書き更新）
      - scripts_windows/lib/     # ディレクトリ: 配下を再帰コピー
      - scripts_windows/os/Get-ServerInfo.ps1  # ファイル: 単体コピー

    configs:                     # コピーするコンフィグ（存在しない場合のみ）
      - config/default/global.conf
```

| フィールド | 必須 | 型 | 説明 |
|-----------|------|----|------|
| `name` | ✅ | string | サーバー識別名（ブランチ名に使用: `sync/ops-{name}`） |
| `target` | ✅ | string | `targets[].id` への参照 |
| `os` | ✅ | string | `windows` または `linux` |
| `description` | — | string | 説明（MR 本文に表示） |
| `enabled` | — | boolean | `false` で同期対象から除外（デフォルト: `true`） |
| `scripts_dir` | ✅ | string | ターゲットリポジトリ内のスクリプトコピー先 |
| `config_dir` | ✅ | string | ターゲットリポジトリ内のコンフィグコピー先 |
| `scripts` | — | list | コピーするスクリプトのパス（ファイルまたはディレクトリ） |
| `configs` | — | list | コピーするコンフィグのパス |

---

## 5. パス変換ルール

`scripts` / `configs` に指定したパスは、以下のルールで先頭プレフィックスを除去した上で
`scripts_dir` / `config_dir` 配下に配置される。

| ソースパス | 除去されるプレフィックス | ターゲット相対パス |
|-----------|----------------------|-----------------|
| `scripts_windows/lib/Logging.psm1` | `scripts_windows/` | `lib/Logging.psm1` |
| `scripts_windows/os/Get-ServerInfo.ps1` | `scripts_windows/` | `os/Get-ServerInfo.ps1` |
| `scripts_linux/lib/logging.sh` | `scripts_linux/` | `lib/logging.sh` |
| `scripts_linux/os/rotate_log.sh` | `scripts_linux/` | `os/rotate_log.sh` |
| `config/default/global.conf` | `config/default/` | `global.conf` |
| `tools/server-snapshot/` | なし（そのまま） | `tools/server-snapshot/` |

### ディレクトリ指定時の展開例

```
scripts: [scripts_windows/lib/]   →   scripts_dir/lib/
                                         ├── Logging.psm1
                                         └── Config.psm1
```

---

## 6. コピールール

### スクリプト (`scripts`)

- **常に上書き**する（既存ファイルがあっても最新版で置き換える）
- ソースリポジトリで削除されたファイルは **自動削除されない**（MR 内で手動削除が必要）

### コンフィグ (`configs`)

- ターゲットリポジトリに **ファイルが存在しない場合のみコピー**する
- 既存ファイルは **一切変更しない**
- 初回デプロイ時のデフォルト値として機能する

```
初回デプロイ:  global.conf が存在しない → コピー      → MR に「新規作成」として記録
2回目以降:     global.conf が存在する   → スキップ    → MR に「スキップ」として記録
```

---

## 7. CI パイプライン仕様

### ステージ構成

```
lint → security → test → sync
```

`sync` ステージは `test` が成功した後にのみ実行される。

### ジョブ定義

| ジョブ名 | トリガー | 用途 |
|---------|---------|------|
| `sync-scripts` | main ブランチへの push | 全サーバーを自動同期 |
| `sync-scripts-manual` | Web UI からの手動実行 | 特定サーバー・ターゲットの選択実行 |

### 必要な CI/CD 変数

Settings > CI/CD > Variables に以下を登録する。

| 変数名 | 説明 | Protected | Masked |
|--------|------|-----------|--------|
| `GITLAB_URL` | GitLab のベース URL（例: `https://gitlab.example.com`） | ✅ | — |
| `GITLAB_TOKEN` | Personal Access Token（スコープ: `api`, `write_repository`） | ✅ | ✅ |

### オプション変数（手動実行時に Web UI で上書き可能）

| 変数名 | デフォルト | 説明 |
|--------|----------|------|
| `DEPLOY_SERVERS` | `""` | コンマ区切りのサーバー名（空 = 全有効サーバー） |
| `DEPLOY_TARGETS` | `""` | コンマ区切りのターゲット ID（空 = 全ターゲット） |
| `DRY_RUN` | `"false"` | `"true"` でドライラン（コミット・MR 作成なし） |

### 使用例

```bash
# 特定サーバーのみ同期（Web UI 手動実行）
DEPLOY_SERVERS=server-web01

# 特定ターゲットリポジトリのみ同期
DEPLOY_TARGETS=infra-osaka

# 組み合わせ（東京リポジトリの DB サーバーのみ）
DEPLOY_TARGETS=infra-tokyo
DEPLOY_SERVERS=server-db01

# ドライラン（差分確認のみ、実際の変更なし）
DRY_RUN=true
```

---

## 8. 同期スクリプト仕様 (`sync.py`)

### 実行方法

```bash
python3 deploy/sync.py                          # 全サーバー同期
python3 deploy/sync.py --server server-web01    # 特定サーバーのみ
python3 deploy/sync.py --target infra-tokyo     # 特定ターゲットのみ
python3 deploy/sync.py --dry-run                # ドライラン
```

### ブランチ命名規則

```
sync/ops-{server名}
例: sync/ops-server-web01
```

同じサーバー名では **常に同じブランチ名** を使用する（force push で更新）。
これにより MR が累積せず、常に最新の変更だけが 1 つの MR として表示される。

### MR 作成ロジック

```
既存の open MR あり → force push 後にコメントを追加（MR は再利用）
既存の open MR なし → 新規 MR を作成
変更ファイルなし    → MR 作成をスキップ
```

### 終了コード

| コード | 意味 |
|--------|------|
| `0` | 全サーバーが正常完了（変更なしを含む） |
| `1` | 1 台以上でエラーが発生 |

### 依存関係

```
python >= 3.9
pyyaml >= 6.0
requests >= 2.28
git（PATH が通っていること）
```

---

## 9. MR の内容

### タイトル形式

```
[Ops Sync] {server名} スクリプト更新 ({コミットSHA})
例: [Ops Sync] server-web01 スクリプト更新 (abc1234)
```

### 本文に含まれる情報

- コミット SHA（どのバージョンのスクリプトか）
- ターゲット ID・OS・説明
- 更新されたスクリプトのファイルリスト
- 新規作成されたコンフィグのリスト
- スキップされたコンフィグのリスト（既存ファイル）

### 付与されるラベル

`servers.yaml` の `targets[].mr_labels` で設定したラベルが自動付与される。

---

## 10. サーバー・ターゲットの追加手順

### 新しいターゲットリポジトリを追加する

1. `deploy/servers.yaml` の `targets:` に追加

```yaml
targets:
  - id: infra-new             # 新しい識別子
    project_id: 404           # 追加先の GitLab project ID
    branch: main
    mr_labels:
      - ops-sync
```

2. ターゲットリポジトリの GitLab 設定で `GITLAB_TOKEN` アカウントに `Developer` 以上の権限を付与

### 新しいサーバーを追加する

1. `deploy/servers.yaml` の `servers:` に追加

```yaml
servers:
  - name: server-app03         # 一意なサーバー名
    target: infra-tokyo        # 既存の targets[].id を指定
    os: linux
    description: "APサーバー (Tomcat)"
    enabled: true
    scripts_dir: server-app03/scripts
    config_dir:  server-app03/config
    scripts:
      - scripts_linux/lib/
      - scripts_linux/os/get_server_info.sh
      - scripts_linux/tomcat/tomcatctl.sh
    configs:
      - config/default/global.conf
```

2. ターゲットリポジトリに `server-app03/` ディレクトリが存在することを確認  
   （存在しない場合は `sync.py` が自動作成する）

3. MR をマージ（または手動でパイプラインをトリガー）

### サーバーを無効化する

`enabled: false` に変更するだけ。次回以降の同期でスキップされる。

```yaml
  - name: server-old01
    enabled: false             # ← 変更
```

---

## 11. 運用手順

### 通常フロー（スクリプト更新時）

```
1. ops-scripts-template でスクリプトを修正・レビュー・マージ
2. CI が自動実行（lint → security → test → sync）
3. 各ターゲットリポジトリに MR が作成される
4. 各リポジトリの担当者が MR をレビュー・マージ
5. 完了（スクリプトが最新化）
```

### 特定サーバーへの緊急デプロイ

```bash
# Web UI から手動パイプライン実行
# DEPLOY_SERVERS=server-web01
# DRY_RUN=false
```

### デプロイ前の差分確認（ドライラン）

```bash
# Web UI から手動パイプライン実行
# DRY_RUN=true
```

ドライランでは変更ファイルの一覧を CI ログに出力するが、
コミット・MR 作成は行わない。

---

## 12. トラブルシューティング

### MR が作成されない

| 原因 | 対処 |
|------|------|
| 変更ファイルがない | 正常（スキップ）。スクリプト内容が既に最新 |
| `GITLAB_TOKEN` の権限不足 | `api` + `write_repository` スコープを確認 |
| `project_id` が誤っている | `servers.yaml` の `targets[].project_id` を確認 |

### スクリプトが期待通りにコピーされない

| 原因 | 対処 |
|------|------|
| `scripts:` のパスが存在しない | CI ログの `[WARN]` を確認 |
| プレフィックスが除去されない | [パス変換ルール](#5-パス変換ルール) を参照 |

### `GITLAB_TOKEN` の設定

Personal Access Token は以下の手順で作成する。

```
GitLab → User Settings → Access Tokens
  → Token name: ops-scripts-sync
  → Scopes: api, write_repository
  → Expiration: 1年以内
```

作成したトークンを `GITLAB_URL` リポジトリの  
`Settings > CI/CD > Variables > GITLAB_TOKEN` に登録する（**Protected & Masked**）。
