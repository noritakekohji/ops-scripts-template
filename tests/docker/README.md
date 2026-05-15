# Docker-based Test Suite

Docker コンテナを使って **Linux bash** と **PowerShell** のスクリプト・ツールを
実機相当の環境でテストします。

## 前提

- Docker Desktop が **Linux コンテナモード** で起動していること
- インターネット接続があること（ネットワークチェックのテストに使用）

## コンテナ構成

| イメージ | ベース | 用途 |
|---|---|---|
| `ops-test-linux` | Ubuntu 22.04 | bash スクリプト全般 |
| `ops-test-powershell` | PS 7.4 / Ubuntu | PowerShell スクリプト全般 |

## 実行

```bash
cd tests/docker

# 全スイート実行（初回はイメージビルドあり）
bash run_tests.sh

# Linux bash のみ
bash run_tests.sh --linux-only

# PowerShell のみ
bash run_tests.sh --ps-only

# イメージ強制再ビルド
bash run_tests.sh --build

# デバッグ: コンテナ内シェルに入る
bash run_tests.sh --shell-linux
bash run_tests.sh --shell-ps
```

## テストスイート一覧

### Linux bash (`linux_tests.sh`)

| スイート | 内容 |
|---|---|
| Prerequisites | bash 4+, python3, ping, ip, df, lsblk, traceroute |
| scripts_linux/lib — logging.sh | source, log_info, log_error, ops_jst_stamp |
| scripts_linux/lib — config.sh | source, load_ops_config, ops_repo_root |
| scripts_linux/os — get_server_info.sh | 収集 + JSON 構造検証 |
| scripts_linux/os — rotate_log.sh | dry-run（サイズ・日数基準） |
| scripts_linux/os — deploy_scripts.sh | dry-run（-n フラグ） |
| scripts_linux/aws | 構文チェック（AWS 認証不要） |
| scripts_linux/sqlserver + tomcat | 構文チェック |
| tools/server-compare | get_server_info 収集・JSON 検証 |
| tools/network-check | DNS・TCP チェック・HTML 生成 |
| tools/change-detect | before/after/compare・HTML 生成 |

### PowerShell (`powershell_tests.ps1`)

| スイート | 内容 |
|---|---|
| Prerequisites | PS バージョン, python3 |
| scripts_windows/lib — Logging.psm1 | Import, Write-OpsLog, ログファイル書き込み |
| scripts_windows/lib — Config.psm1 | Import, Get-OpsConfig, Get-OpsRepoRoot |
| scripts_windows/os — Get-ServerInfo.ps1 | 構文 + 部分実行（PS7/Linux 対応分） |
| scripts_windows/os — Compare-ServerInfo.ps1 | テスト JSON で比較・HTML 生成 |
| scripts_windows/os — Rotate-Log.ps1 | 構文 + -WhatIf dry-run |
| scripts_windows/os — Deploy-Scripts.ps1 | 構文 + -WhatIf dry-run |
| scripts_windows/aws | 構文チェック |
| scripts_windows/sqlserver + tomcat | 構文チェック |
| tools/server-compare (PS) | 構文 + Compare-ServerInfo 実行 |
| tools/network-check (PS) | 構文 + 実行・HTML 生成 |
| tools/change-detect (PS) | 構文チェック |

## 注意事項

### PowerShell テストについて

PowerShell 7 は Linux 上で動作するため、以下の Windows 専用コマンドレットは使用不可です：
`Get-CimInstance`, `Get-Service`, `Get-LocalUser`, `Get-NetIPAddress`, など。

テストでは以下を検証します：
- **全スクリプト**: 構文解析エラーなし
- **lib モジュール**: Import + 関数の動作確認
- **PS7/Linux で動く部分**: 実行確認
- **Windows 専用部分**: -WhatIf / -ErrorAction SilentlyContinue で安全実行

### Ping について

`--cap-add=NET_RAW` を付けて実行するため ICMP ping が使えます。

## 出力例

```
════════════════════════════════════════════════════════════
  Docker Test Runner
  Repo : /path/to/ops-scripts-template
════════════════════════════════════════════════════════════
  Docker  : 29.4.2 [linux containers]

── Building Docker images ──────────────────────────────────
  Building ops-test-linux:latest from Dockerfile.linux ...
  Building ops-test-powershell:latest from Dockerfile.powershell ...

── Linux bash tests ────────────────────────────────────────

══════════════════════════════════════════════════════════
  SUITE: Prerequisites
══════════════════════════════════════════════════════════
  [PASS] bash 4+
  [PASS] python3
  [PASS] ping
  ...

  [PASS] ALL TESTS PASSED
  Total: 45   PASS: 45   FAIL: 0

── PowerShell tests ────────────────────────────────────────

  [PASS] ALL TESTS PASSED
  Total: 38   PASS: 38   FAIL: 0

════════════════════════════════════════════════════════════
  ✓ ALL SUITES PASSED
  Total time: 142s
════════════════════════════════════════════════════════════
```
