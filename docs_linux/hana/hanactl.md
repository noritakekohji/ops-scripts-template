# `hanactl.sh`

> SAP HANA Database ライフサイクル制御。`<sid>adm` ユーザに su して HDB / sapcontrol を実行。

[← 仕様書一覧](../../shell-specification.md) | [← 設計書](../../ops-scripts-structure.md)

---

> **本ドキュメントはスタブです**。コマンド一覧と主要なオプションを記載しています。詳細はソース（`scripts_linux/hana/hanactl.sh`）のヘッダコメントおよびヘルプ (`-h`) を参照してください。

## 1. 配置

```
scripts_linux/hana/hanactl.sh
```

| 項目 | 値 |
|---|---|
| 言語 | Bash 4+ |
| OS | Linux |
| ペア | （Windows 版は未提供） |

## 2. 概要

SAP HANA Database ライフサイクル制御。`<sid>adm` ユーザに su して HDB / sapcontrol を実行。 Linux 版と Windows 版は同じコマンド体系・終了コード規約・引数命名を持ちます。

## 3. アクション

| アクション | 動作 |
|---|---|
| `start` | HANA インスタンスを起動（既に稼働中ならスキップ） |
| `stop` | HANA インスタンスを停止（既に停止中ならスキップ） |
| `restart` | 常に実行 |
| `status` | プロセスリストを参照 |

## 4. 共通ルール

- 設定の優先順位: **CLI 引数 > `config/<env>/hanactl.conf` > `config/<env>/global.conf` > `config/default/...` > スクリプト既定値**
- ロギング: 共通 lib（`scripts_linux/lib/logging.sh` または `scripts_windows/lib/Logging.psm1`）経由で JST タイムスタンプ + 5 文字レベルの 1 行ログ。
- 構造化情報は `key=value` 形式でメッセージに埋め込みます。

## 5. 終了コード

| Code | 意味 |
|---|---|
| 0  | 成功（または skipped） |
| 1  | 引数不正 |
| 2  | 業務エラー（前提リソースが見つからない等） |
| 10 | 前提コマンド不足 |
| 20 | 一時障害（タイムアウト、外部 API 失敗） |

## 6. 関連

- Linux 版 / Windows 版の対応関係: （Windows 版は未提供）
- 共通仕様: [`shell-specification.md`](../../shell-specification.md)
- リポジトリ構成: [`ops-scripts-structure.md`](../../ops-scripts-structure.md)
- 開発上の注意: [`development-rules.md`](../../development-rules.md)
