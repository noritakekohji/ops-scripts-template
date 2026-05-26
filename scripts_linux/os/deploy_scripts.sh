#!/usr/bin/env bash
# ============================================================================
# deploy_scripts.sh
#   リポジトリの scripts/ / config/ から指定対象だけを
#   <opt_root_dir> 配下にローカル配備（インストール）する。
#
# Usage:
#   deploy_scripts.sh -L <listfile> [-d <opt_root_dir>] [-e <env>] [-b] [-n]
#
# Options:
#   -L <file>   対象リストファイル（必須）
#   -d <path>   配備先 root（既定: /opt/ops-scripts、config で変更可）
#   -e <env>    環境名（dev / staging / production 等）
#               省略時は $OPS_ENV、それも未設定なら config/default/ のみ参照
#   -b          上書き前に既存ファイルをバックアップ
#   -n          Dry-run（実際の操作なし、ログのみ）
#
# List file format:
#   # コメント（行頭 # またはインラインコメントは無視）
#   CONF, <filename>                config/default/<filename>        → <opt_root_dir>/config/<filename>
#   SRC,  <repo_filepath>           <repo_filepath>                  → <opt_root_dir>/bin/<basename>
#   LIB,  linux/<file>|windows/<f>  scripts_<platform>/lib/<file>   → <opt_root_dir>/lib/<platform>/<file>
#
#   env が指定された場合、CONF は default を先に配備し、その後
#   config/<env>/<filename> が存在すれば上書きする。
#
# Authentication: 配備先パスへの書込み権（必要なら sudo）
# Exit codes:
#   0 = success / partial / skipped
#   1 = 入力バリデーション失敗
#   2 = リストファイル不在
#   4 = 全件失敗
#   5 = 配備先への書込み不可
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

# ---------- デフォルト ----------
list_file=""
opt_root="/opt/ops-scripts"
opt_root_set=0
env_name="${OPS_ENV:-}"
backup_existing=0
dry_run=0

deployed=0
unchanged=0
backed_up=0
failed=0
status="unknown"

cleanup() {
    local rc=$?
    [[ "$status" == "unknown" && "$rc" -eq 0 ]] && status="success"
    log_info "Script end: status=$status exitCode=$rc deployed=$deployed unchanged=$unchanged backedUp=$backed_up failed=$failed"
}
trap cleanup EXIT

# ---------- 引数解析 ----------
while getopts "L:d:e:bn" opt; do
    case "$opt" in
        L) list_file="$OPTARG" ;;
        d) opt_root="$OPTARG"; opt_root_set=1 ;;
        e) env_name="$OPTARG" ;;
        b) backup_existing=1 ;;
        n) dry_run=1 ;;
        *) log_error "Unknown option: -$OPTARG"; status="failed"; exit 1 ;;
    esac
done

# ---------- 設定ファイル ----------
load_ops_config "deploy_scripts" "$env_name"
cfg_env="${OPS_CONFIG_ENV:-default}"

[[ "$opt_root_set" -eq 0 && -n "${OPS_CONFIG[opt_root_dir]:-}" ]] && opt_root="${OPS_CONFIG[opt_root_dir]}"
if [[ -z "$list_file" && -n "${OPS_CONFIG[PathList]:-}" ]]; then
    list_file="${OPS_CONFIG[PathList]}"
    [[ "$list_file" != /* ]] && list_file="$(ops_repo_root)/$list_file"
fi

log_info "Config loaded: env=$cfg_env keys=${#OPS_CONFIG[@]}"
log_info "Args validated: listFile=$list_file optRoot=$opt_root env=${env_name:-default} backup=$backup_existing dryRun=$dry_run"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ---------- ヘルパ ----------

_sha256() { sha256sum "$1" | awk '{print $1}'; }

# 冪等コピー
copy_file() {
    local src="$1" dst="$2" perm="$3"

    if [[ ! -f "$src" ]]; then
        log_warn "Source not found, skipping: src=$src"
        failed=$((failed+1))
        return 1
    fi

    if [[ -f "$dst" ]]; then
        if [[ "$(_sha256 "$src")" == "$(_sha256 "$dst")" ]]; then
            log_info "Unchanged: dst=$dst"
            unchanged=$((unchanged+1))
            return 0
        fi
        if [[ "$backup_existing" -eq 1 ]]; then
            local stamp backup_dir backup_path
            stamp=$(ops_jst_stamp)
            backup_dir="$opt_root/.backup"
            backup_path="$backup_dir/$(basename "$dst").$stamp"
            if [[ "$dry_run" -eq 0 ]]; then
                mkdir -p "$backup_dir"
                cp -p -- "$dst" "$backup_path"
                log_info "Backed up: from=$dst to=$backup_path"
            else
                log_info "[DRY-RUN] Would backup: from=$dst to=$backup_path"
            fi
            backed_up=$((backed_up+1))
        else
            log_warn "Overwriting without backup: dst=$dst"
        fi
    fi

    if [[ "$dry_run" -eq 1 ]]; then
        log_info "[DRY-RUN] Would deploy: src=$src dst=$dst mode=$perm"
        deployed=$((deployed+1))
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    if cp -p -- "$src" "$dst" && chmod "$perm" -- "$dst"; then
        log_info "Deployed: src=$src dst=$dst mode=$perm"
        deployed=$((deployed+1))
    else
        log_error "Copy failed: src=$src dst=$dst"
        failed=$((failed+1))
        return 1
    fi
}

# CONF エントリ：
#   env 未指定 → config/default/<filename> → <opt_root_dir>/config/<filename>
#   env 指定時 → config/<env>/<filename>   → <opt_root_dir>/config/<filename>
deploy_conf() {
    local filepath="$1"
    local filename; filename=$(basename "$filepath")
    local dst="$opt_root/config/$filename"

    local config_dir
    if [[ -n "$env_name" ]]; then
        config_dir="$REPO_ROOT/config/$env_name"
    else
        config_dir="$REPO_ROOT/config/default"
    fi

    local src="$config_dir/$filepath"
    if [[ -f "$src" ]]; then
        copy_file "$src" "$dst" 644 || true
    else
        log_warn "Config not found: src=$src"
        failed=$((failed+1))
    fi
}

# SRC エントリ：<repo_filepath> → <opt_root_dir>/bin/<basename>
deploy_src() {
    local filepath="$1"
    local filename; filename=$(basename "$filepath")
    local src="$REPO_ROOT/$filepath"
    local dst="$opt_root/bin/$filename"
    copy_file "$src" "$dst" 755 || true
}

# LIB エントリ：linux/<file> or windows/<file> → <opt_root_dir>/lib/linux/<file> or lib/windows/<file>
deploy_lib() {
    local filepath="$1"
    local platform="${filepath%%/*}"
    local filename; filename=$(basename "$filepath")
    local src="$REPO_ROOT/scripts_${platform}/lib/$filename"
    local dst="$opt_root/lib/$filepath"
    copy_file "$src" "$dst" 644 || true
}

# ---------- プレチェック ----------
log_info "Pre-check start"

if [[ -z "$list_file" ]]; then
    log_error "Specify -L <listfile> or set PathList in deploy_scripts.conf"
    status="failed"; exit 1
fi
if [[ ! -f "$list_file" ]]; then
    log_error "List file not found: $list_file"
    status="failed"; exit 2
fi

if [[ "$dry_run" -eq 0 ]]; then
    mkdir -p "$opt_root" 2>/dev/null || true
    if ! touch "$opt_root/.probe.$$" 2>/dev/null; then
        log_error "Cannot write to opt_root_dir: $opt_root"
        status="failed"; exit 5
    fi
    rm -f "$opt_root/.probe.$$"
fi

# リスト解析
declare -a entry_types=()
declare -a entry_paths=()

_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local_line="${raw_line%%#*}"                  # インラインコメント除去
    local_line="${local_line//$'\r'/}"            # CR 除去
    local_line=$(_trim "$local_line")
    [[ -z "$local_line" ]] && continue

    local_type=$(_trim "${local_line%%,*}")
    local_path=$(_trim "${local_line#*,}")

    # TYPE を大文字化（bash 4+）
    local_type="${local_type^^}"

    case "$local_type" in
        CONF|SRC|LIB)
            entry_types+=("$local_type")
            entry_paths+=("$local_path")
            ;;
        *)
            log_warn "Unknown type, skipping: line='$raw_line'"
            ;;
    esac
done < "$list_file"

entry_count=${#entry_types[@]}
if [[ "$entry_count" -eq 0 ]]; then
    log_warn "No entries to deploy (skipped)"
    status="skipped"
    exit 0
fi

log_info "Pre-check passed: entryCount=$entry_count"

# ---------- メイン ----------
log_info "Main start"

for ((i = 0; i < entry_count; i++)); do
    t="${entry_types[$i]}"
    p="${entry_paths[$i]}"
    case "$t" in
        CONF) deploy_conf "$p" ;;
        SRC)  deploy_src  "$p" ;;
        LIB)  deploy_lib  "$p" ;;
    esac
done

# ---------- マーカー作成 ----------
# 配備が 1 件でも成功（または unchanged）したら、配備ルートに
# .ops-deploy-root マーカーを置く。配備先スクリプトの lib / config
# 解決はこのマーカーを使って「配備ルートをどこで止めるか」を判定する。
if [[ "$dry_run" -eq 0 && ( "$deployed" -gt 0 || "$unchanged" -gt 0 ) ]]; then
    marker="$opt_root/.ops-deploy-root"
    {
        echo "deployed_at=$(ops_jst_stamp '%Y-%m-%dT%H:%M:%S')"
        echo "env=${env_name:-default}"
        echo "deployed_by=${SUDO_USER:-${USER:-unknown}}"
        echo "host=$(hostname)"
        echo "list_file=$list_file"
    } > "$marker" 2>/dev/null || log_warn "Could not write deploy-root marker: $marker"
    [[ -f "$marker" ]] && log_info "Deploy-root marker: $marker"
fi

# ---------- 終了判定 ----------
if [[ "$failed" -gt 0 && "$deployed" -eq 0 && "$unchanged" -eq 0 ]]; then
    log_error "All entries failed"
    status="failed"; exit 4
elif [[ "$failed" -gt 0 ]]; then
    log_info "Main complete (with failures)"
    status="partial"
else
    log_info "Main complete"
    status="success"
fi
exit 0
