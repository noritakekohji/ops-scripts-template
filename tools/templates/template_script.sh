#!/usr/bin/env bash
# ============================================================================
# template_script.sh
#   Runnable template demonstrating the 5-phase script structure.
#
# Usage:
#   template_script.sh -p <param> [-n]
#
# Options:
#   -p  Identifier used to name the per-run idempotency marker (required)
#   -n  Dry-run (skip the actual file writes, still log)
#   -h  Show this usage
#
# Authentication: <REAL: IAM role / Vault reference / none>
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
#   3  = resource state invalid
#   4  = main operation failed
#   5  = external dependency unreachable
#   10+= environment prerequisite (CLI / module missing)
#   20+= authentication / permission
#
# This file is a runnable demonstration. Each phase has placeholder logic so
# you can run it as-is and observe all five phases in the log, including an
# idempotent skip when re-run within IDEMPOTENCY_WINDOW_SEC seconds.
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# Phase 2 (early): environment setup — logger
# ----------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# TEMPLATE: adjust the number of '..' segments to your script depth.
#   scripts/aws/linux/foo.sh        -> 3 ups (../../../lib/...)
#   scripts/linux/bar.sh            -> 2 ups (../../lib/...)
#   scripts/sqlserver/linux/baz.sh  -> 3 ups
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

# State for Phase 5 cleanup
tmp_file=""
exit_code=0
status="unknown"

# Demo-only: idempotency window. Re-runs within this window skip.
IDEMPOTENCY_WINDOW_SEC=60

cleanup() {
    local rc=$?
    if [[ -n "$tmp_file" && -f "$tmp_file" ]]; then
        if rm -f -- "$tmp_file"; then
            log_info "Cleanup: removed temp file=$tmp_file"
        else
            log_warn "Cleanup failed: file=$tmp_file"
        fi
    fi
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then
        status="success"
    fi
    log_info "Script end: status=$status exitCode=$rc"
}
trap cleanup EXIT

usage() { sed -n '2,33p' "$0" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Phase 1: Argument parsing & validation
# ----------------------------------------------------------------------------
param=""
dry_run=0

# TEMPLATE: track which behavior options the user explicitly set, so config
# is only consulted for the unset ones. Per-run targets (e.g. -p) typically
# don't need _set tracking since their default is empty.
# dry_run_set=0

while getopts "p:nh" opt; do
    case "$opt" in
        p) param="$OPTARG" ;;
        n) dry_run=1 ;;  # ; dry_run_set=1
        h|*) usage ;;
    esac
done

# Load config and apply to unspecified behavior parameters.
# Resolution: CLI > config/<env>/<name>.conf > config/<env>/ops.conf
#           > config/common/<name>.conf > config/common/ops.conf > script default.
# TEMPLATE: change 'template_script' to your script's name (no extension).
load_ops_config "template_script"
# TEMPLATE: for each behavior option, copy this pattern:
# [[ "$<option>_set" -eq 0 && -n "${OPS_CONFIG[<Key>]:-}" ]] && <option>="${OPS_CONFIG[<Key>]}"
# For booleans:
# if [[ "$<option>_set" -eq 0 && -n "${OPS_CONFIG[<Key>]:-}" ]]; then
#     case "${OPS_CONFIG[<Key>]}" in true|TRUE|True|1) <option>=1 ;; *) <option>=0 ;; esac
# fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

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
# Replace each demo check with the relevant real check for your script.
# ----------------------------------------------------------------------------
log_info "Pre-check start"

# 3-a: Required CLIs present.
# DEMO: ensure 'cat' is available. REAL: e.g. command -v aws.
if ! command -v cat >/dev/null 2>&1; then
    log_error "Required tool not found: cat"
    status="failed"; exit_code=10
    exit 10
fi

# 3-b: Authentication usable.
# DEMO: confirm we have an actor name. REAL: e.g. aws sts get-caller-identity.
actor="${USER:-${LOGNAME:-}}"
if [[ -z "$actor" ]]; then
    log_error "Cannot determine identity (USER / LOGNAME both empty)"
    status="failed"; exit_code=20
    exit 20
fi

# 3-c: Target resource exists / reachable.
# DEMO: working directory exists. REAL: target file or host.
work_dir="${TMPDIR:-/tmp}"
if [[ ! -d "$work_dir" ]]; then
    log_error "Working dir not found: dir=$work_dir"
    status="failed"; exit_code=2
    exit 2
fi

# 3-d: Idempotency — already in desired state? If yes, skip cleanly.
# DEMO: skip if a per-param marker file was touched within the window.
# REAL: check whether the action was recently performed.
marker="$work_dir/template-demo-${param}.marker"
if [[ -f "$marker" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y -- "$marker") ))
    if [[ "$age" -lt "$IDEMPOTENCY_WINDOW_SEC" ]]; then
        log_info "Skipped (idempotent): reason=marker_recent marker=$marker ageSec=$age"
        status="skipped"; exit_code=0
        exit 0
    fi
fi

# 3-e: External dependency reachability.
# DEMO: skipped (no external dependency).
# REAL: e.g. curl -sfo /dev/null --max-time 5 https://example.internal/health.

log_info "Pre-check passed"

# ----------------------------------------------------------------------------
# Phase 4: Main processing (side-effects allowed)
# ----------------------------------------------------------------------------
log_info "Main start"

if [[ "$dry_run" -eq 1 ]]; then
    log_info "[DRY-RUN] would write demo payload: param=$param"
else
    # DEMO: write a payload to a scratch temp file, then update the
    # idempotency marker. REAL: replace with the actual operation.

    tmp_file=$(mktemp)
    printf 'Demo payload for %s written at %s\n' "$param" "$(date)" > "$tmp_file"
    size=$(stat -c %s -- "$tmp_file")
    log_info "Wrote scratch file: file=$tmp_file bytes=$size"

    date +%s > "$marker"
    log_info "Marker updated: marker=$marker"
fi

log_info "Main complete"
status="success"
exit_code=0
exit 0

# Phase 5 (post-processing) runs automatically via `trap cleanup EXIT`.
