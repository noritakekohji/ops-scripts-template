#!/usr/bin/env bash
# ============================================================================
# sqlserverctl.sh
#   SQL Server ライフサイクル統合制御: start / stop / restart / status（1本で）
#
# 使い方:
#   sqlserverctl.sh <action> <service_name> [-w] [-t <sec>]
#
# Linux のサービス名は通常 'mssql-server'。SQL Server Agent は
# 別 unit（例: 'mssql-server@<instance>'）。本スクリプトの対象外。
# 必要なら別呼び出しで制御すること
#
# アクション:
#   start    既に active ならスキップ。それ以外は systemctl start
#   stop     既に inactive ならスキップ。それ以外は systemctl stop
#   restart  systemctl restart（直に実行）
#   status   状態のみ表示（read-only）
#
# オプション:
#   -w  Wait until target state
#   -t  Wait timeout seconds (default 120, range 5..600)
#   -h  usage 表示
#
# 終了コード: 0 成功/スキップ, 1 usage, 2 サービス不在,
#             3 待機タイムアウト, 4 systemctl 失敗数, 10 systemctl 不在
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# --- lib resolution -----------------------------------------------------------
# OPS_LIB env var takes precedence. Otherwise walk up from SCRIPT_DIR looking
# for lib/logging.sh (flat) or lib/linux/logging.sh (OS-split layout). Stop at
# .ops-deploy-root marker so we never walk out of the install tree.
_ops_find_lib() {
    local d="$1"
    while [[ -n "$d" && "$d" != "/" ]]; do
        [[ -f "$d/lib/logging.sh" ]]       && { echo "$d/lib";       return 0; }
        [[ -f "$d/lib/linux/logging.sh" ]] && { echo "$d/lib/linux"; return 0; }
        [[ -f "$d/.ops-deploy-root" ]] && return 1
        d=$(dirname -- "$d")
    done
    return 1
}
if [[ -n "${OPS_LIB:-}" ]]; then
    _ops_lib="$OPS_LIB"
elif ! _ops_lib=$(_ops_find_lib "$SCRIPT_DIR"); then
    echo "[ERROR] lib/logging.sh not found from $SCRIPT_DIR (set OPS_LIB to override)" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$_ops_lib/logging.sh"
# shellcheck source=/dev/null
source "$_ops_lib/config.sh"

# Helper: systemctl is-active の戻り値を安全に文字列化する。
# 実 systemctl は inactive のときに stdout="inactive" + exit=3 を返す。
# $(... || echo unknown) で捕捉すると "inactive" の後に "unknown" が改行付きで
# 連結されてしまうため、失敗を握りつぶしつつ空のときだけ "unknown" を返す。
_systemctl_state() {
    local s
    s=$(systemctl is-active "$1" 2>/dev/null) || true
    [[ -z "$s" ]] && s="unknown"
    printf '%s' "$s"
}

usage() { sed -n '2,25p' "$0" >&2; exit 1; }

before_state=""
after_state=""
status="unknown"
action=""
service_name=""

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc action=$action service=$service_name before=$before_state after=$after_state"
}
trap cleanup EXIT

action="${1:-}"
case "$action" in
    start|stop|restart|status) shift ;;
    ""|-h|--help) usage ;;
    *) log_error "Invalid action: $action"; status="failed"; exit 1 ;;
esac

service_name="${1:-}"
if [[ -z "$service_name" || "$service_name" =~ ^- ]]; then
    log_error "Missing service name (second positional arg)"
    status="failed"; exit 1
fi
shift

wait_for_completion=0
wait_timeout=120
wait_set=0
wait_timeout_set=0

while getopts "wt:h" opt; do
    case "$opt" in
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        h|*) usage ;;
    esac
done

load_ops_config "sqlserverctl"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"

if ! [[ "$service_name" =~ ^[A-Za-z0-9._@\-]+$ ]]; then
    log_error "Invalid service name: $service_name"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 5 ]] || [[ "$wait_timeout" -gt 600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 5..600)"
    status="failed"; exit 1
fi

log_info "Args validated: action=$action service=$service_name wait=$wait_for_completion timeoutSec=$wait_timeout"

log_info "Pre-check start"

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not installed"
    status="failed"; exit 10
fi

if ! systemctl list-unit-files --no-legend "${service_name}.service" 2>/dev/null | grep -q . \
   && ! systemctl status "${service_name}" >/dev/null 2>&1; then
    log_error "Service not found: service=$service_name"
    status="failed"; exit 2
fi

before_state=$(_systemctl_state "$service_name")
log_info "Current state: service=$service_name state=$before_state"

if [[ "$action" == "status" ]]; then
    sub_state=$(systemctl show -p SubState --value "$service_name" 2>/dev/null || echo "")
    log_info "Status: service=$service_name state=$before_state sub=$sub_state"
    after_state="$before_state"
    status="success"
    exit 0
fi

if [[ "$action" == "start" && "$before_state" == "active" ]]; then
    log_info "Skipped (idempotent): service=$service_name state=active"
    after_state="$before_state"; status="skipped"; exit 0
fi
if [[ "$action" == "stop" && "$before_state" == "inactive" ]]; then
    log_info "Skipped (idempotent): service=$service_name state=inactive"
    after_state="$before_state"; status="skipped"; exit 0
fi

log_info "Pre-check passed"

log_info "Main start"

if [[ "$wait_for_completion" -eq 1 ]]; then
    if ! timeout "$wait_timeout" systemctl "$action" "$service_name"; then
        after_state=$(_systemctl_state "$service_name")
        log_error "systemctl $action did not complete within timeout: service=$service_name timeoutSec=$wait_timeout actual=$after_state"
        status="failed"; exit 3
    fi
else
    if ! systemctl "$action" "$service_name"; then
        after_state=$(_systemctl_state "$service_name")
        log_error "systemctl $action failed: service=$service_name actual=$after_state"
        status="failed"; exit 4
    fi
fi
log_info "$action initiated: service=$service_name"

after_state=$(_systemctl_state "$service_name")
log_info "Main complete: service=$service_name state=$after_state"
status="success"
exit 0
