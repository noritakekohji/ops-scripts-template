#!/usr/bin/env bash
# ============================================================================
# install.sh
#   deploy_scripts.sh を呼び出す薄いラッパ。
#   リポジトリルートから実行し、第 1 引数に環境名を渡す。
#
# Usage:
#   install.sh <env> [deploy_scripts.sh のオプション...]
#
# Examples:
#   install.sh dev
#   install.sh production
#   install.sh staging -b          # 上書き前にバックアップ
#   install.sh dev -n              # Dry-run（実操作なし）
#
# 配備対象は config/default/deploy_scripts.lst（または
# config/<env>/deploy_scripts.lst で上書き）を参照。
# 配備先は /opt/ops-scripts（config で変更可）。
#
# Exit codes: deploy_scripts.sh の終了コードをそのまま返す
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DEPLOY="$SCRIPT_DIR/scripts/linux/bash/deploy_scripts.sh"

usage() {
    cat >&2 <<'EOF'
Usage: install.sh <env> [options]

  <env>  環境名（dev / staging / production など）

Options（deploy_scripts.sh に透過）:
  -d <path>  配備先 root（既定: /opt/ops-scripts）
  -m <mode>  script-only / with-config / with-tests / all（既定: with-config）
  -b         上書き前に既存ファイルをバックアップ
  -n         Dry-run（実際の操作なし、ログのみ）

Examples:
  install.sh dev
  install.sh production -b
  install.sh staging -n
EOF
    exit 1
}

if [[ $# -eq 0 ]]; then
    usage
fi

env_name="$1"
shift

exec "$DEPLOY" -e "$env_name" "$@"
