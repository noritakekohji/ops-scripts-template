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
#
# Flow:
#   1. Argument parsing & validation
#   2. Environment setup           (logger / safe mode / cleanup trap)
#   3. Pre-check                   (prerequisites + idempotency)
#   4. Main processing             (the actual work)
#   5. Post-processing             (always runs via trap EXIT)
#
# Exit codes:
#   0  = success or idempotent skip
#   1  = usage / validation
#   2  = target resource not found
#   3  = resource state invalid (timeout etc.)
#   4  = main operation failed
#   5  = external dependency unreachable
#   10+= environment prerequisite (CLI / module missing)
#   20+= authentication / permission
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Phase 2 (early): environment setup — logger
# ----------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# TEMPLATE: adjust the number of '..' segments to your script depth.
#   scripts/aws/linux/ami/foo.sh    -> 4 ups
#   scripts/linux/log/bar.sh        -> 3 ups
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../lib/bash/logging.sh"

# State for Phase 5 cleanup
tmp_file=""
exit_code=0
status="unknown"

cleanup() {
    # Capture the exit code being returned right now
    local rc=$?

    # Remove temp artifacts
    if [[ -n "$tmp_file" && -f "$tmp_file" ]]; then
        rm -f -- "$tmp_file" || log_warn "Cleanup failed: file=$tmp_file"
    fi

    # If we're exiting through the natural end and status is still unknown,
    # treat it as success.
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then
        status="success"
    fi

    log_info "Script end: status=$status exitCode=$rc"
}
trap cleanup EXIT

usage() { sed -n '2,28p' "$0" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Phase 1: Argument parsing & validation
# ----------------------------------------------------------------------------
param=""
dry_run=0

while getopts "p:nh" opt; do
    case "$opt" in
        p) param="$OPTARG" ;;
        n) dry_run=1 ;;
        h|*) usage ;;
    esac
done

if [[ -z "$param" ]]; then
    log_error "Missing required arg: -p"
    status="failed"; exit_code=1
    exit 1
fi
if ! [[ "$param" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_error "Invalid param: $param"
    status="failed"; exit_code=1
    exit 1
fi

log_info "Args validated: param=$param dryRun=$dry_run"

# ----------------------------------------------------------------------------
# Phase 3: Pre-check (prerequisites + idempotency)
# All checks here MUST be side-effect free (read-only).
# ----------------------------------------------------------------------------
log_info "Pre-check start"

# 3-a: Required CLIs present
# if ! command -v aws >/dev/null 2>&1; then
#     log_error "aws CLI not installed"
#     status="failed"; exit_code=10
#     exit 10
# fi

# 3-b: Authentication usable
# if ! aws sts get-caller-identity >/dev/null 2>&1; then
#     log_error "AWS auth failed"
#     status="failed"; exit_code=20
#     exit 20
# fi

# 3-c: Target resource exists / reachable
# if [[ ! -e "$target" ]]; then
#     log_error "Target not found: target=$target"
#     status="failed"; exit_code=2
#     exit 2
# fi

# 3-d: Idempotency — already in desired state? If yes, skip cleanly.
# if [[ <already_done> ]]; then
#     log_info "Skipped (idempotent): reason=already_completed"
#     status="skipped"; exit_code=0
#     exit 0
# fi

# 3-e: External dependency reachable
# if ! curl -sfo /dev/null --max-time 5 https://example.internal/health; then
#     log_error "External dependency unreachable"
#     status="failed"; exit_code=5
#     exit 5
# fi

log_info "Pre-check passed"

# ----------------------------------------------------------------------------
# Phase 4: Main processing (side-effects allowed)
# ----------------------------------------------------------------------------
log_info "Main start"

if [[ "$dry_run" -eq 1 ]]; then
    log_info "[DRY-RUN] would do work: param=$param"
else
    # TODO: replace with the real implementation
    # Example: tmp_file=$(mktemp); ...

    log_info "Doing work: param=$param"
fi

log_info "Main complete"
status="success"
exit_code=0
exit 0

# Phase 5 (post-processing) runs automatically via `trap cleanup EXIT`.
