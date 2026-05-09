#!/usr/bin/env bash
# ============================================================================
# template_script.sh
#   <一行サマリ：このスクリプトが何をするか>
#
# Usage:
#   template_script.sh -p <param> [-n]
#
# Options:
#   -p  <パラメータの意味と制約>
#   -n  Dry-run (optional)
#   -h  Show this usage
#
# Authentication: <認証要件：IAM ロール / Vault 参照 / 不要 など>
# Exit codes: 0 = 成功, 1 = usage / バリデーション, 2 = リソース不在,
#             3 = リソース状態不正, 4 = 操作失敗,
#             10+ = 環境前提（必須 CLI / モジュール 未インストール）
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# TEMPLATE: adjust the number of '..' segments based on script depth.
#   scripts/aws/linux/ami/foo.sh    -> 4 ups
#   scripts/linux/log/bar.sh        -> 3 ups
#   scripts/common/notify/baz.sh    -> 3 ups
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../lib/bash/logging.sh"

usage() { sed -n '2,17p' "$0" >&2; exit 1; }

param=""
dry_run=0

while getopts "p:nh" opt; do
    case "$opt" in
        p) param="$OPTARG" ;;
        n) dry_run=1 ;;
        h|*) usage ;;
    esac
done

# --- input validation -------------------------------------------------------
[[ -z "$param" ]] && usage
if ! [[ "$param" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_error "Invalid param: $param"
    exit 1
fi

# --- main -------------------------------------------------------------------
log_info "Script start: param=$param dryRun=$dry_run"

if [[ "$dry_run" -eq 1 ]]; then
    log_info "[DRY-RUN] would do work: param=$param"
else
    # TODO: replace with the real implementation
    log_info "Doing work: param=$param"
fi

log_info "Script complete: param=$param"
exit 0
