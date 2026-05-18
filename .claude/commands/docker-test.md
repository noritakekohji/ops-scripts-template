---
description: "Docker テストスイートを起動（引数で linux / windows / both を指定。既定: both）"
argument-hint: "[linux|windows|both]"
allowed-tools: Bash, PowerShell
---

Docker コンテナで実環境テストを実行します。引数: $ARGUMENTS（未指定なら both）。

実行する内容:

- **linux**: `bash tests/docker/run_tests.sh` を実行（Ubuntu コンテナで `linux_tests.sh`）
- **windows**: `powershell -NoProfile -File tests/docker/run_tests.ps1` を実行（PowerShell コンテナで `powershell_tests.ps1`）
- **both**: 両方を並列で実行

ターゲットコンテナで必要な capability（ping 用 `--cap-add=NET_RAW` 等）は run_tests スクリプト
側で設定済みです。ルートファイルシステムは read-only なので、テスト中の一時ファイルは
`${TMPDIR:-/tmp}` を使うこと。

完了後、合格 / 不合格を要約し、失敗があれば失敗理由のログ抜粋を提示してください。
