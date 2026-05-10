#!/usr/bin/env bash
# ============================================================================
# tomcatctl.sh
#   Tomcat 繝ｩ繧､繝輔し繧､繧ｯ繝ｫ蛻ｶ蠕｡・嘖tart / stop / restart / status・亥・遲会ｼ・#
# 菴ｿ縺・婿:
#   tomcatctl.sh <action> <service_name> [-w] [-t <sec>]
#
# 繧｢繧ｯ繧ｷ繝ｧ繝ｳ:
#   start    譌｢縺ｫ active 縺ｪ繧峨せ繧ｭ繝・・縲ゅ◎繧御ｻ･螟悶・ systemctl start
#   stop     譌｢縺ｫ inactive 縺ｪ繧峨せ繧ｭ繝・・縲ゅ◎繧御ｻ･螟悶・ systemctl stop
#   restart  systemctl restart・亥ｸｸ縺ｫ螳溯｡後∝・遲峨せ繧ｭ繝・・縺ｪ縺暦ｼ・#   status   迥ｶ諷九・縺ｿ陦ｨ遉ｺ・・ead-only・・#
# 繧ｪ繝励す繝ｧ繝ｳ:
#   -w  Wait until target state (start->active, stop->inactive)
#   -t  Wait timeout seconds (default 60, range 5..600)
#   -h  usage 陦ｨ遉ｺ
#
# 謖吝虚繧ｪ繝励す繝ｧ繝ｳ縺ｯ config/<env>/tomcatctl.conf 縺ｫ險ｭ螳壼庄閭ｽ縲・# 隱崎ｨｼ: systemctl 縺ｮ縺溘ａ sudo / root 讓ｩ髯舌′蠢・ｦ・# 邨ゆｺ・さ繝ｼ繝・ 0 謌仙粥/繧ｹ繧ｭ繝・・, 1 usage, 2 繧ｵ繝ｼ繝薙せ荳榊惠,
#             3 蠕・ｩ溘ち繧､繝繧｢繧ｦ繝・ 4 systemctl 螟ｱ謨・ 10 systemctl 荳榊惠
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

# --- 繝輔ぉ繝ｼ繧ｺ 1: 菴咲ｽｮ蠑墓焚 + 繧ｪ繝励す繝ｧ繝ｳ ------------------------------------------
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

# --- 繝輔ぉ繝ｼ繧ｺ 2: 險ｭ螳壹ヵ繧｡繧､繝ｫ隱ｭ霎ｼ縺ｿ ---------------------------------------------------
load_ops_config "tomcatctl"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"

# --- 繝輔ぉ繝ｼ繧ｺ 1・育ｶ壹″・・ 繝舌Μ繝・・繧ｷ繝ｧ繝ｳ ---------------------------------------------
if ! [[ "$service_name" =~ ^[A-Za-z0-9._@\-]+$ ]]; then
    log_error "Invalid service name: $service_name"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 5 ]] || [[ "$wait_timeout" -gt 600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 5..600)"
    status="failed"; exit 1
fi

log_info "Args validated: action=$action service=$service_name wait=$wait_for_completion timeoutSec=$wait_timeout"

# --- 繝輔ぉ繝ｼ繧ｺ 3: 繝励Ξ繝√ぉ繝・け -----------------------------------------------------
log_info "Pre-check start"

if ! command -v systemctl >/dev/null 2>&1; then
    log_error "systemctl not installed (this script requires systemd)"
    status="failed"; exit 10
fi

# unit 縺悟ｭ伜惠縺吶ｋ縺薙→・・oaded 繧ゅ＠縺上・ systemd 縺瑚ｪ崎ｭ假ｼ・if ! systemctl list-unit-files --no-legend "${service_name}.service" 2>/dev/null | grep -q . \
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

# --- 繝輔ぉ繝ｼ繧ｺ 4: 繝｡繧､繝ｳ蜃ｦ逅・-----------------------------------------------
log_info "Main start"

# systemctl start/stop/restart 縺ｯ譌｢螳壹〒繝悶Ο繝・く繝ｳ繧ｰ縲・w 譎ゅ・ timeout 縺ｧ蝗ｲ繧
sysctl_args=( "$action" "$service_name" )
if [[ "$wait_for_completion" -eq 1 ]]; then
    if ! timeout "$wait_timeout" systemctl "${sysctl_args[@]}"; then
        after_state=$(systemctl is-active "$service_name" 2>/dev/null || echo "unknown")
        log_error "systemctl $action did not complete within timeout: service=$service_name timeoutSec=$wait_timeout actual=$after_state"
        status="failed"; exit 3
    fi
else
    # -w 縺ｪ縺励〒繧・systemd 縺ｯ蜷梧悄螳溯｡後Ｕimeout 縺ｧ縺上ｋ縺ｾ縺ｪ縺・□縺・    if ! systemctl "${sysctl_args[@]}"; then
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
