---
description: "ローカルで単体テスト (bats + Pester) を実行。引数で linux|windows|both|all|coverage を指定（既定: both）"
argument-hint: "[linux|windows|both|all|coverage]"
allowed-tools: Bash, PowerShell
---

引数 $ARGUMENTS に応じてテストを走らせます（未指定なら `both`）:

- **linux**:    `bash tests/run_unit.sh`
- **windows**:  `powershell -NoProfile -File tests\run_unit.ps1`
- **both**:     上記両方を並列実行
- **all**:      `tests/run_all.sh` と `tests/run_all.ps1` で単体 + 結合を走らせる
- **coverage**: `tests/run_unit.sh --coverage` と `tests/run_unit.ps1 -Coverage`

実行後、合格 / 不合格件数と失敗理由の要約を出し、生成された結果ファイル
(`tests/results/`) のパスを提示してください。bats / Pester が
インストールされていない場合は、README の手順を参照する形で案内してください。
