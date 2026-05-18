---
description: "ローカルでテンプレ準拠検査（CI と同じ ci/template-check/check_template.sh）を実行"
allowed-tools: Bash
---

`ci/template-check/check_template.sh` を実行して、`scripts_linux/` と `scripts_windows/`
配下のすべての制御スクリプトが下記の規約に準拠しているか検査してください:

- PowerShell: `#Requires -Version 5.1` / コメントヘルプ / `[CmdletBinding(...)]` /
  `$ErrorActionPreference = 'Stop'` / `Set-StrictMode -Version Latest` / `Logging.psm1` import
- Bash: `#!/usr/bin/env bash` / `set -euo pipefail` / `lib/logging.sh` source / 実行ビット

違反が出たら、ファイル名と該当ルールをまとめて報告し、自動修正可能な項目（BOM、実行ビット、
ヘッダ行）はその場で修正の許可を求めてください。`tools/` 配下は library-import 規則の対象外
であることに注意。
