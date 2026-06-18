# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `cert-check` / `port-inventory` / `aws-instance-audit` に `-FromJson` を追加。保存済み JSON を読み込み、収集を再実行せずにレポート（コンソール / JSON / HTML）を再生成できる（Windows / PowerShell のみ）
- `tools/collect-snapshot` — 断面情報収集ラッパー（server-snapshot / port-inventory / aws-instance-audit を一括実行し ZIP で保存）。CUI（全自動）と TUI（対話メニュー）に対応
- service-wait: type=service / type=process のローカルノードチェックを追加 (v3 仕様)。
  Linux は `systemctl is-active` / `pgrep -x`、Windows は `Get-Service` / `Get-Process`
  を使用。OS ごとに別 .lst を用意する前提（service / process 名は OS 固有）。

### Removed
- aws-instance-audit: 内部ヘルパー `_assemble_json.py` を削除（JSON 組み立てが
  両 OS でネイティブ化され不要になったため）。`render_report.py`(HTML) は維持。
- service-wait: 行レベルオーバーライド (`per_check_timeout_sec=N` を 4 列目に書く形式)
  を **v3.1 で廃止**。タイミング設定はすべて `.lst` ヘッダで完結させる。
  4 列目以降の文字列を含む行は `extra_columns` で exit 2。

### Changed
- aws-instance-audit: **JSON 出力を python3 / jq に非依存化**。Linux 版は
  `aws --query`(JMESPath) + `--output text` で値を抽出し bash ネイティブで JSON を
  組み立て、Windows 版は `ConvertFrom-Json` / `ConvertTo-Json` で組み立てる。
  python3 は HTML レポート (`--html` / `-HtmlReport`) を出すときだけ必要になった。
  終了コード 10 の意味を「aws CLI 不在（--html 指定時のみ python3 不在）」に変更。
  Bash 版は依存を増やさないため 1 行のコンパクト JSON を出力する（スキーマは従来と同一）。
- service-wait: 監視パラメータ (initial_wait_sec / interval_sec / success_threshold /
  timeout_sec / per_check_timeout_sec) を `.conf` から **.lst ヘッダに移動 (v2 仕様)**。
  `.conf` は LogFile / LogLevel のみを保持。同じスクリプトで監視タイミングごとに
  異なるパラメータの `.lst` を渡せるようになった。古い `.conf` に監視キーが残って
  いれば WARN を出して無視する。
- network-check: targets-editor.xlsm に Enabled 列（A 列、on/off ドロップダウン）を追加。
  `on` の行のみ targets.lst に出力されるようになった。行を削除せずに一時的なスキップが可能。

### Added
- `scripts_*/os/service-wait` ヘルスチェック待ちスクリプト。Ping / TCP / HTTP の連続成功でブロック解除、タイムアウト時 exit 3。
- server-snapshot: server-compare と change-detect を統合した自己完結ツール
  （ServerSnapshot.ps1 / server_snapshot.sh / server_snapshot.bat + compare_server_info.py）
  - 5 サブコマンド: collect / before / after / compare / list
- cert-check: TLS 証明書有効期限チェックツール
  （CertCheck.ps1 / cert_check.sh / cert_check.bat + cert_targets.lst サンプル）
- port-inventory: 待受ポート棚卸し・監査ツール
  （PortInventory.ps1 / port_inventory.sh / port_inventory.bat + expected_ports.lst サンプル）
- log-collector: 障害時の証跡（ログファイル）収集ツール
  （LogCollector.ps1 / log_collector.sh / log_collector.bat + collect_targets.conf プリセット定義）
- network-check: targets.lst 編集用の Excel マクロブック targets-editor.xlsm
  （VBA ソース targets-editor.bas + ビルドスクリプト build_targets_editor.ps1）

### Deprecated
- server-compare: server-snapshot に統合。既存スクリプトは委譲ラッパーとして動作
- change-detect: server-snapshot に統合。既存スクリプトは委譲ラッパーとして動作

## [0.1.0] - 2026-06-10

### Added
- 初回バージョン（開発中）

[Unreleased]: https://github.com/noritakekohji/ops-scripts-template/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/noritakekohji/ops-scripts-template/releases/tag/v0.1.0
