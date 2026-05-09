# スクリプトテンプレート

新規スクリプトを追加するときの **出発点となる骨組み**。CI の `template-check` ジョブはここで定義された必須要素が含まれているかを `scripts/**` 配下の全スクリプトで検証します。

| ファイル | 用途 |
|---|---|
| [`Template-Script.ps1`](Template-Script.ps1) | PowerShell 7+ 用 |
| [`template_script.sh`](template_script.sh) | Bash 用 |

## 使い方

1. 適切な配置先にコピー（例：`scripts/aws/windows/ami/Backup-Foo.ps1`）
2. ファイル名と内部のヘッダ（`SYNOPSIS` / `DESCRIPTION` / `Usage` 等）を実際の用途に書き換え
3. **lib のインポートパスを配置深さに合わせて調整**（テンプレ内に "TEMPLATE: adjust ..." コメントあり）
4. パラメータと `# TODO` を実装
5. 実行権限を付与（Bash のみ、`git update-index --chmod=+x`）
6. （推奨）`docs/scripts/<filename>.md` の個別仕様書も追加

## CI チェック内容

`ci/template-check/check_template.sh` が走査して以下を検証します。

### PowerShell（`scripts/**/*.ps1`）
- `#Requires -Version 7` の宣言
- コメントベースヘルプ（`<# ... #>`）の存在
- `[CmdletBinding(...)]` 属性
- `$ErrorActionPreference = 'Stop'` の設定
- `Set-StrictMode -Version Latest` の設定
- `lib/powershell/Logging.psm1` の import

### Bash（`scripts/**/*.sh`）
- 1 行目が `#!/usr/bin/env bash`
- `set -euo pipefail` の設定
- `lib/bash/logging.sh` の source
- 実行ビット（`100755`）が立っていること

## ローカルでチェックを走らせる

```bash
bash ci/template-check/check_template.sh
```

違反があれば `VIOLATION: <file> -- <rule>` 形式で stderr に列挙され、exit 1 になります。

## 違反時の典型的な対処

| メッセージ例 | 対処 |
|---|---|
| `PS: must declare #Requires -Version 7` | スクリプトの 1 行目に `#Requires -Version 7` を追加 |
| `PS: must import lib/powershell/Logging.psm1` | `lib` の Import-Module ブロックをテンプレートからコピー |
| `Bash: first non-empty line must be the bash shebang` | 1 行目を `#!/usr/bin/env bash` に変更（`#!/bin/sh` や `#!/bin/bash` は NG） |
| `Bash: must be executable` | `git update-index --chmod=+x <file>` で実行ビット付与 |
