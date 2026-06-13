# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- server-snapshot: server-compare と change-detect を統合した自己完結ツール
  （ServerSnapshot.ps1 / server_snapshot.sh / server_snapshot.bat + compare_server_info.py）
  - 5 サブコマンド: collect / before / after / compare / list
- cert-check: TLS 証明書有効期限チェックツール
  （CertCheck.ps1 / cert_check.sh / cert_check.bat + cert_targets.lst サンプル）
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
