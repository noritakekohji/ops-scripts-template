# `NginxCtl.ps1`

> nginx ライフサイクル統合制御（start / stop / restart / status）。Windows サービス（nssm 等で登録）経由で制御し、Linux 版と同じコマンド体系・終了コード規約を持つ。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

> **本ドキュメントはスタブです**。コマンド一覧と主要なオプションを記載しています。詳細はソース（`scripts_windows/nginx/NginxCtl.ps1`）のヘッダコメントおよびヘルプ (`-h`) を参照してください。

## 1. 配置

```
scripts_windows/nginx/NginxCtl.ps1
```

| 項目 | 値 |
|---|---|
| 言語 | PowerShell 5.1+ |
| OS | Windows |
| ペア | [`nginxctl.sh`](../../docs_linux/nginx/nginxctl.md) |

## 2. 概要

nginx ライフサイクル統合制御（start / stop / restart / status）。Windows サービス（nssm 等で登録）経由で制御し、Linux 版と同じコマンド体系・終了コード規約を持つ。

`TomcatCtl.ps1` / `tomcatctl.sh` と同じ「Windows サービス or systemd ユニットを薄くラップした制御スクリプト」のパターンに従います。

## 3. アクション

| アクション | 動作 |
|---|---|
| `start` | 既に稼働中／Running ならスキップ（冪等） |
| `stop` | 既に停止中／Stopped ならスキップ（冪等） |
| `restart` | 常に実行（冪等スキップなし） |
| `status` | 状態のみ参照（副作用なし） |

## 4. 共通ルール

- 設定の優先順位: **CLI 引数 > `config/<env>/nginxctl.conf` > `config/<env>/global.conf` > `config/default/...` > スクリプト既定値**
- ロギング: 共通 lib（`scripts_linux/lib/logging.sh` または `scripts_windows/lib/Logging.psm1`）経由で JST タイムスタンプ + 5 文字レベルの 1 行ログ。
- 構造化情報は `key=value` 形式でメッセージに埋め込みます。
- 設定可能な挙動キー: `Wait`（`true`/`false`）、`WaitTimeoutSec`（5-600）

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0  | 成功（または skipped） |
| 1  | 引数不正 |
| 2  | サービス不在 |
| 3  | 待機タイムアウト |
| 4  | サービス制御失敗 |
| 10 | 前提コマンド不足（systemctl 不在等） |

## 6. 関連

- Linux 版 / Windows 版の対応関係: [`nginxctl.sh`](../../docs_linux/nginx/nginxctl.md)
- 同パターンのミドル: TomcatCtl / SqlServerCtl / MySQLCtl / PostgreSQLCtl
- 共通仕様: [`shell-specification.md`](../../shell-specification.md)
- リポジトリ構成: [`ops-scripts-structure.md`](../../ops-scripts-structure.md)
- 開発上の注意: [`development-rules.md`](../../development-rules.md)
