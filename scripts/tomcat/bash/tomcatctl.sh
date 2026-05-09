#!/usr/bin/env bash
# ============================================================================
# tomcatctl.sh
#   Tomcat ライフサイクル制御：start / stop / restart / status（冪等）
#
# 使い方:
#   tomcatctl.sh <action> <service_name> [-w] [-t <sec>]
#
# アクション:
#   start    既に active ならスキップ。それ以外は systemctl start
#   stop     既に inactive ならスキップ。それ以外は systemctl stop
#   restart  systemctl restart（常に実行、冪等スキップなし）
#   status   状態のみ表示（read-only）
#
# オプション:
#   -w  Wait until target state (start->active, stop->inactive)
#   -t  Wait timeout seconds (default 60, range 5..600)
#   -h  usage 表示
#
# 挙動オプションは config/<env>/tomcatctl.conf に設定可能。
# 認証: systemctl のため sudo / root 権限が必要
# 終了コード: 0 成功/スキップ, 1 usage, 2 サービス不在,
#             3 待機タイムアウト, 4 systemctl 失敗, 10 systemctl 不在
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

usage() { sed -n '2,22p' "$0" >&2; exit 1; }

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

# --- フェーズ 1: 位置引数 + オプション ------------------------------------------
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
wait_timeout=60
wait_set=0
wait_timeout_set=0

while getopts "wt:h" opt; do
    case "$opt" in
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        h|*) usage ;;
    esac
done

# --- フェーズ 2: 設定ファイル読込み ---------------------------------------------------
load_ops_config "tomcatctl"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

# --- フェーズ 1（続き）: バリデーション ---------------------------------------------
if ! [[ "$service_name" =~ ^[A-Za-z0-9._@\-]+$ ]]; then
    log_error "Invalid service name: $service_name"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 5 ]] || [[ "$wait_timeout" -gt 600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 5..600)"
    status="failed"; exit 1
fi

log_info "Args validated: action=$action service=$service_name wait=$wait_for_completion timeoutSec=$wait_timeout"

# --- フェーズ 3: プレチェック -----------------------------------------------------
log_info "Pre-check start"

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not installed (this script requires systemd)"
    status="failed"; exit 10
fi

# unit が存在すること（loaded もしくは systemd が認識）
if ! systemctl list-unit-files --no-legend "${service_name}.service" 2>/dev/null | grep -q . \
   && ! systemctl status "${service_name}" >/dev/null 2>&1; then
    log_error "Service not found: service=$service_name"
    status="failed"; exit 2
fi

before_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
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

# --- フェーズ 4: メイン処理 -----------------------------------------------
log_info "Main start"

# systemctl start/stop/restart は既定でブロッキング。-w 時は timeout で囲む
sysctl_args=( "$action" "$service_name" )
if [[ "$wait_for_completion" -eq 1 ]]; then
    if ! timeout "$wait_timeout" systemctl "${sysctl_args[@]}"; then
        after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        log_error "systemctl $action did not complete within timeout: service=$service_name timeoutSec=$wait_timeout actual=$after_state"
        status="failed"; exit 3
    fi
else
    # -w なしでも systemd は同期実行。timeout でくるまないだけ
    if ! systemctl "${sysctl_args[@]}"; then
        after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        log_error "systemctl $action failed: service=$service_name actual=$after_state"
        status="failed"; exit 4
    fi
fi
log_info "$action initiated: service=$service_name"

after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
log_info "Main complete: service=$service_name state=$after_state"
status="success"
exit 0
