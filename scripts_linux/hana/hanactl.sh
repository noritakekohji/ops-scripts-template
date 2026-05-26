#!/usr/bin/env bash
# ============================================================================
# hanactl.sh
#   SAP HANA Database ライフサイクル統合制御: start / stop / restart / status
#   （Linux 専用 — SAP HANA は Linux のみサポート）
#
# 使い方:
#   hanactl.sh <action> -S <SID> -N <NN> [-w] [-t <sec>]
#
# アクション:
#   start    HANA を起動（既に running ならスキップ）
#   stop     HANA を停止（既に stopped ならスキップ）
#   restart  停止してから起動
#   status   稼働状態を表示（read-only）
#
# オプション:
#   -S  HANA System ID（SID）例: HDB, PRD, QAS  ※必須
#   -N  インスタンス番号 2桁  例: 00, 01        ※必須
#   -w  目的状態到達まで待機
#   -t  待機タイムアウト秒（既定: 300、許容範囲 30..1800）
#   -h  usage 表示
#
# 前提:
#   - <SID>adm ユーザーが存在し sudo 等で切り替え可能なこと
#   - HDB コマンドが /usr/sap/<SID>/HDB<NN>/exe/ に存在すること
#   - または sapcontrol が PATH 上にあること
#
# 挙動オプションは config/<env>/hanactl.conf に設定可能。
# 終了コード: 0 成功/スキップ, 1 usage, 2 <sid>adm 不在,
#             3 待機タイムアウト, 4 起動/停止失敗, 5 状態取得失敗,
#             10 HDB/sapcontrol 不在
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

usage() { sed -n '2,32p' "$0" >&2; exit 1; }

before_state=""
after_state=""
status="unknown"
action=""
hana_sid=""
inst_nr=""
adm_user=""
hdb_exe=""

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc action=$action sid=$hana_sid nr=$inst_nr before=$before_state after=$after_state"
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
wait_timeout=300
wait_set=0
wait_timeout_set=0

while getopts "S:N:wt:h" opt; do
    case "$opt" in
        S) hana_sid="$OPTARG" ;;
        N) inst_nr="$OPTARG" ;;
        w) wait_for_completion=1; wait_set=1 ;;
        t) wait_timeout="$OPTARG"; wait_timeout_set=1 ;;
        h|*) usage ;;
    esac
done

load_ops_config "hanactl"
[[ -z "$hana_sid"  && -n "${OPS_CONFIG[SID]:-}"              ]] && hana_sid="${OPS_CONFIG[SID]}"
[[ -z "$inst_nr"   && -n "${OPS_CONFIG[InstanceNumber]:-}"   ]] && inst_nr="${OPS_CONFIG[InstanceNumber]}"
[[ "$wait_timeout_set" -eq 0 && -n "${OPS_CONFIG[WaitTimeoutSec]:-}" ]] && wait_timeout="${OPS_CONFIG[WaitTimeoutSec]}"
if [[ "$wait_set" -eq 0 && -n "${OPS_CONFIG[Wait]:-}" ]]; then
    case "${OPS_CONFIG[Wait]}" in true|TRUE|True|1) wait_for_completion=1 ;; *) wait_for_completion=0 ;; esac
fi

# ── バリデーション ────────────────────────────────────────────────────────────
if [[ -z "$hana_sid" ]]; then
    log_error "HANA SID is required: -S <SID>"
    status="failed"; exit 1
fi
if [[ -z "$inst_nr" ]]; then
    log_error "Instance number is required: -N <NN>"
    status="failed"; exit 1
fi
if ! [[ "$hana_sid" =~ ^[A-Z][A-Z0-9]{2}$ ]]; then
    log_error "Invalid SID (must be 3 uppercase alphanumeric, start with letter): $hana_sid"
    status="failed"; exit 1
fi
if ! [[ "$inst_nr" =~ ^[0-9]{2}$ ]]; then
    log_error "Invalid instance number (must be 2 digits): $inst_nr"
    status="failed"; exit 1
fi
if ! [[ "$wait_timeout" =~ ^[0-9]+$ ]] || [[ "$wait_timeout" -lt 30 ]] || [[ "$wait_timeout" -gt 1800 ]]; then
    log_error "Invalid wait timeout: $wait_timeout (range 30..1800)"
    status="failed"; exit 1
fi

adm_user="${hana_sid,,}adm"   # 小文字 SID + "adm"  例: hdbadm, prdadm

log_info "Config loaded: env=${OPS_CONFIG_ENV:-default} keys=${#OPS_CONFIG[@]}"
log_info "Args validated: action=$action SID=$hana_sid NR=$inst_nr adm=$adm_user wait=$wait_for_completion timeoutSec=$wait_timeout"

# ── プレチェック ─────────────────────────────────────────────────────────────
log_info "Pre-check start"

# <sid>adm ユーザーの存在確認
if ! id "$adm_user" >/dev/null 2>&1; then
    log_error "HANA admin user not found: $adm_user"
    status="failed"; exit 2
fi

# HDB コマンドのパス解決
# /usr/sap/<SID>/HDB<NN>/exe/HDB が標準パス
hdb_path="/usr/sap/${hana_sid}/HDB${inst_nr}/exe/HDB"
if [[ -x "$hdb_path" ]]; then
    hdb_exe="$hdb_path"
elif command -v sapcontrol >/dev/null 2>&1; then
    hdb_exe="sapcontrol"
else
    log_error "Neither HDB ($hdb_path) nor sapcontrol found"
    status="failed"; exit 10
fi

log_info "Control method: $hdb_exe"

# ── 状態取得ヘルパー ─────────────────────────────────────────────────────────
hana_get_state() {
    local rc=0
    if [[ "$hdb_exe" == "sapcontrol" ]]; then
        # sapcontrol GetSystemInstanceList で稼働確認
        local out
        out=$(sapcontrol -nr "$inst_nr" -function GetSystemInstanceList 2>/dev/null) || rc=$?
        if [[ "$rc" -ne 0 ]]; then echo "unknown"; return; fi
        if echo "$out" | grep -qiE 'GREEN|RUNNING'; then echo "running"
        elif echo "$out" | grep -qiE 'GRAY|STOPPED'; then echo "stopped"
        else echo "unknown"
        fi
    else
        # HDB info で稼働確認（<sid>adm として実行）
        local out
        out=$(su - "$adm_user" -c "${hdb_exe} info" 2>/dev/null) || rc=$?
        if [[ "$rc" -ne 0 ]]; then echo "unknown"; return; fi
        if echo "$out" | grep -qiE 'running|active'; then echo "running"
        elif echo "$out" | grep -qiE 'not running|stopped'; then echo "stopped"
        else echo "unknown"
        fi
    fi
}

before_state=$(hana_get_state)
log_info "Current state: SID=$hana_sid NR=$inst_nr state=$before_state"

# ── status アクション ────────────────────────────────────────────────────────
if [[ "$action" == "status" ]]; then
    if [[ "$hdb_exe" == "sapcontrol" ]]; then
        sapcontrol -nr "$inst_nr" -function GetProcessList 2>/dev/null || true
    else
        su - "$adm_user" -c "${hdb_exe} info" 2>/dev/null || true
    fi
    after_state="$before_state"
    status="success"
    exit 0
fi

# ── 冪等チェック ─────────────────────────────────────────────────────────────
if [[ "$action" == "start" && "$before_state" == "running" ]]; then
    log_info "Skipped (idempotent): SID=$hana_sid state=running"
    after_state="$before_state"; status="skipped"; exit 0
fi
if [[ "$action" == "stop" && "$before_state" == "stopped" ]]; then
    log_info "Skipped (idempotent): SID=$hana_sid state=stopped"
    after_state="$before_state"; status="skipped"; exit 0
fi

log_info "Pre-check passed"

# ── 制御ヘルパー ─────────────────────────────────────────────────────────────
hana_do() {
    local cmd="$1"
    if [[ "$hdb_exe" == "sapcontrol" ]]; then
        sapcontrol -nr "$inst_nr" -function "$cmd"
    else
        su - "$adm_user" -c "${hdb_exe} ${cmd}"
    fi
}

# ── メイン処理 ────────────────────────────────────────────────────────────────
log_info "Main start"

case "$action" in
    start)
        hana_do "start" || {
            log_error "HANA start command failed: SID=$hana_sid"
            status="failed"; exit 4
        }
        ;;
    stop)
        hana_do "stop" || {
            log_error "HANA stop command failed: SID=$hana_sid"
            status="failed"; exit 4
        }
        ;;
    restart)
        log_info "Restart: stop phase"
        hana_do "stop" || {
            log_error "HANA stop (restart) failed: SID=$hana_sid"
            status="failed"; exit 4
        }
        sleep 5   # 短い安定待ち
        log_info "Restart: start phase"
        hana_do "start" || {
            log_error "HANA start (restart) failed: SID=$hana_sid"
            status="failed"; exit 4
        }
        ;;
esac

log_info "$action initiated: SID=$hana_sid NR=$inst_nr"

# ── 完了待機 ─────────────────────────────────────────────────────────────────
if [[ "$wait_for_completion" -eq 1 ]]; then
    target_state="running"
    [[ "$action" == "stop" ]] && target_state="stopped"
    log_info "Waiting for state: SID=$hana_sid target=$target_state timeoutSec=$wait_timeout"
    deadline=$(( $(date +%s) + wait_timeout ))
    while true; do
        current=$(hana_get_state)
        if [[ "$current" == "$target_state" ]]; then
            log_info "Reached target state: SID=$hana_sid state=$current"
            break
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
            log_error "Timeout waiting for state: SID=$hana_sid target=$target_state actual=$current timeoutSec=$wait_timeout"
            after_state="$current"; status="failed"; exit 3
        fi
        sleep 10
    done
fi

after_state=$(hana_get_state)
log_info "Main complete: SID=$hana_sid state=$after_state"
status="success"
exit 0
