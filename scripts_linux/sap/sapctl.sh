#!/usr/bin/env bash
# ============================================================================
# sapctl.sh
#   SAP システム（S/4HANA / NetWeaver / ECC）ライフサイクル統合制御
#   start / stop / restart / status（1本で）
#
# 使い方:
#   sapctl.sh <action> -S <SID> -N <NN> [-w] [-t <sec>]
#
# アクション:
#   start    SAP システムを起動（既に running ならスキップ）
#   stop     SAP システムを停止（既に stopped ならスキップ）
#   restart  停止してから起動
#   status   プロセスリストを表示（read-only）
#
# オプション:
#   -S  SAP System ID（SID）例: S4H, ECC, PRD  ※必須
#   -N  インスタンス番号 2桁  例: 00, 01       ※必須
#   -w  目的状態到達まで待機
#   -t  待機タイムアウト秒（既定: 600、許容範囲 60..3600）
#   -h  usage 表示
#
# 制御方法（優先順位）:
#   1. sapcontrol -nr <NN> -function Start/Stop/RestartInstance/GetProcessList
#   2. su - <sid>adm -c "startsap ALL" / "stopsap ALL"（sapcontrol 不在時）
#
# 前提:
#   - <SID>adm ユーザーが存在し sudo 等で切り替え可能なこと
#   - sapcontrol が PATH 上にあること（/usr/sap/hostctrl/exe/ 等）
#     または startsap / stopsap が <sid>adm の PATH に存在すること
#
# 挙動オプションは config/<env>/sapctl.conf に設定可能。
# 終了コード: 0 成功/スキップ, 1 usage, 2 <sid>adm 不在,
#             3 待機タイムアウト, 4 起動/停止失敗, 5 状態取得失敗,
#             10 sapcontrol/startsap 不在
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

usage() { sed -n '2,37p' "$0" >&2; exit 1; }

before_state=""
after_state=""
status="unknown"
action=""
sap_sid=""
inst_nr=""
adm_user=""
ctrl_method=""   # "sapcontrol" or "legacy"

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc action=$action sid=$sap_sid nr=$inst_nr before=$before_state after=$after_state"
}
trap cleanup EXIT

# ── アクション ────────────────────────────────────────────────────────────────
action="${1:-}"
case "$action" in
    start|stop|restart|status) shift ;;
    ""|-h|--help) usage ;;
    *) log_error "Invalid action: $action"; status="failed"; exit 1 ;;
esac

# ── オプション ────────────────────────────────────────────────────────────────
wait_for_completion=0
wait_timeout=600
wait_set=0
wait_timeout_set=0

while getopts "S:N:wt:h" opt; do
    case "$opt" in
        S) sap_sid="$OPTARG" ;;
        N) inst_nr="$OPTARG" ;;
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        h|*) usage ;;
    esac
done

load_ops_config "sapctl"
[[ -z "$sap_sid"  && -n "${OPS_CONFIG[SID]:-}"              ]] && sap_sid="${OPS_CONFIG[SID]}"
[[ -z "$inst_nr"  && -n "${OPS_CONFIG[InstanceNumber]:-}"   ]] && inst_nr="${OPS_CONFIG[InstanceNumber]}"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

# ── バリデーション ────────────────────────────────────────────────────────────
if [[ -z "$sap_sid" ]]; then
    log_error "SAP SID is required: -S <SID>"
    status="failed"; exit 1
fi
if [[ -z "$inst_nr" ]]; then
    log_error "Instance number is required: -N <NN>"
    status="failed"; exit 1
fi
if ! [[ "$sap_sid" =~ ^[A-Z][A-Z0-9]{2}$ ]]; then
    log_error "Invalid SID (must be 3 uppercase alphanumeric, start with letter): $sap_sid"
    status="failed"; exit 1
fi
if ! [[ "$inst_nr" =~ ^[0-9]{2}$ ]]; then
    log_error "Invalid instance number (must be 2 digits): $inst_nr"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 60 ]] || [[ "$wait_timeout" -gt 3600 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 60..3600)"
    status="failed"; exit 1
fi

adm_user="${sap_sid,,}adm"   # 小文字 SID + "adm"  例: s4hadm, eccadm

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"
log_info "Args validated: action=$action SID=$sap_sid NR=$inst_nr adm=$adm_user wait=$wait_for_completion timeoutSec=$wait_timeout"

# ── プレチェック ─────────────────────────────────────────────────────────────
log_info "Pre-check start"

# <sid>adm ユーザーの存在確認
if ! id "$adm_user" >/dev/null 2>&1; then
    log_error "SAP admin user not found: $adm_user"
    status="failed"; exit 2
fi

# 制御方法の決定
if command -v sapcontrol >/dev/null 2>&1; then
    ctrl_method="sapcontrol"
elif su - "$adm_user" -c "command -v startsap" >/dev/null 2>&1; then
    ctrl_method="legacy"
else
    log_error "Neither sapcontrol nor startsap found in PATH"
    status="failed"; exit 10
fi

log_info "Control method: $ctrl_method"

# ── 状態取得ヘルパー ─────────────────────────────────────────────────────────
sap_get_state() {
    local rc=0
    if [[ "$ctrl_method" == "sapcontrol" ]]; then
        local out
        # set -e 下では sapcontrol 失敗で関数が落ちるのを避けるため `|| true`。
        # 旧コードは $exit_code を取得していたが未使用だったので削除。
        out=$(sapcontrol -nr "$inst_nr" -function GetSystemInstanceList 2>/dev/null) || true
        # sapcontrol の戻り値: 0=成功, 1=エラー
        if echo "$out" | grep -qiE 'GREEN|RUNNING'; then echo "running"
        elif echo "$out" | grep -qiE 'GRAY|STOPPED'; then echo "stopped"
        else echo "unknown"
        fi
    else
        # startsap/stopsap 環境では直接確認コマンドがないため
        # ps で SAP プロセスを確認する（ポータブルな方法）
        if pgrep -u "$adm_user" -f "msg_server|disp+work|enserver" >/dev/null 2>&1; then
            echo "running"
        else
            echo "stopped"
        fi
    fi
}

before_state=$(sap_get_state)
log_info "Current state: SID=$sap_sid NR=$inst_nr state=$before_state"

# ── status アクション ────────────────────────────────────────────────────────
if [[ "$action" == "status" ]]; then
    if [[ "$ctrl_method" == "sapcontrol" ]]; then
        log_info "--- GetProcessList ---"
        sapcontrol -nr "$inst_nr" -function GetProcessList 2>/dev/null || true
        log_info "--- GetSystemInstanceList ---"
        sapcontrol -nr "$inst_nr" -function GetSystemInstanceList 2>/dev/null || true
    else
        log_info "--- Process list for $adm_user ---"
        ps -u "$adm_user" -f 2>/dev/null || true
    fi
    after_state="$before_state"
    status="success"
    exit 0
fi

# ── 冪等チェック ─────────────────────────────────────────────────────────────
if [[ "$action" == "start" && "$before_state" == "running" ]]; then
    log_info "Skipped (idempotent): SID=$sap_sid state=running"
    after_state="$before_state"; status="skipped"; exit 0
fi
if [[ "$action" == "stop" && "$before_state" == "stopped" ]]; then
    log_info "Skipped (idempotent): SID=$sap_sid state=stopped"
    after_state="$before_state"; status="skipped"; exit 0
fi

log_info "Pre-check passed"

# ── 制御ヘルパー ─────────────────────────────────────────────────────────────
sap_start() {
    if [[ "$ctrl_method" == "sapcontrol" ]]; then
        sapcontrol -nr "$inst_nr" -function Start
    else
        su - "$adm_user" -c "startsap ALL"
    fi
}

sap_stop() {
    if [[ "$ctrl_method" == "sapcontrol" ]]; then
        sapcontrol -nr "$inst_nr" -function Stop
    else
        su - "$adm_user" -c "stopsap ALL"
    fi
}

# ── メイン処理 ────────────────────────────────────────────────────────────────
log_info "Main start"

case "$action" in
    start)
        sap_start || {
            log_error "SAP start command failed: SID=$sap_sid NR=$inst_nr"
            status="failed"; exit 4
        }
        ;;
    stop)
        sap_stop || {
            log_error "SAP stop command failed: SID=$sap_sid NR=$inst_nr"
            status="failed"; exit 4
        }
        ;;
    restart)
        if [[ "$ctrl_method" == "sapcontrol" ]]; then
            sapcontrol -nr "$inst_nr" -function RestartInstance || {
                log_error "SAP RestartInstance failed: SID=$sap_sid NR=$inst_nr"
                status="failed"; exit 4
            }
        else
            log_info "Restart: stop phase"
            sap_stop || { log_error "SAP stop (restart) failed: SID=$sap_sid"; status="failed"; exit 4; }
            sleep 10   # SAP プロセスの安定待ち
            log_info "Restart: start phase"
            sap_start || { log_error "SAP start (restart) failed: SID=$sap_sid"; status="failed"; exit 4; }
        fi
        ;;
esac

log_info "$action initiated: SID=$sap_sid NR=$inst_nr"

# ── 完了待機 ─────────────────────────────────────────────────────────────────
if [[ "$wait_for_completion" -eq 1 ]]; then
    target_state="running"
    [[ "$action" == "stop" ]] && target_state="stopped"
    log_info "Waiting for state: SID=$sap_sid target=$target_state timeoutSec=$wait_timeout"
    deadline=$(( $(date +%s) + wait_timeout ))
    while true; do
        current=$(sap_get_state)
        if [[ "$current" == "$target_state" ]]; then
            log_info "Reached target state: SID=$sap_sid state=$current"
            break
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
            log_error "Timeout waiting for state: SID=$sap_sid target=$target_state actual=$current timeoutSec=$wait_timeout"
            after_state="$current"; status="failed"; exit 3
        fi
        sleep 15
    done
fi

after_state=$(sap_get_state)
log_info "Main complete: SID=$sap_sid state=$after_state"
status="success"
exit 0
