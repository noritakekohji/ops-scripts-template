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
#   CONF, <filename>       config/default/<filename> → <opt_root_dir>/config/<filename>
#   SRC,  <repo_filepath>  scripts/<repo_filepath>   → <opt_root_dir>/bin/<basename>
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
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

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

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

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

# CONF エントリ：config/default/<filename> → <opt_root_dir>/config/<filename>
# env 指定時は config/<env>/<filename> で上書き
deploy_conf() {
    local filepath="$1"
    local filename; filename=$(basename "$filepath")
    local dst="$opt_root/config/$filename"

    local src_default="$REPO_ROOT/config/default/$filepath"
    if [[ -f "$src_default" ]]; then
        copy_file "$src_default" "$dst" 644 || true
    else
        log_warn "Default config not found: src=$src_default"
        failed=$((failed+1))
    fi

    if [[ -n "$env_name" ]]; then
        local src_env="$REPO_ROOT/config/$env_name/$filepath"
        if [[ -f "$src_env" ]]; then
            copy_file "$src_env" "$dst" 644 || true
        fi
    fi
}

# SRC エントリ：scripts/<repo_filepath> → <opt_root_dir>/bin/<basename>
deploy_src() {
    local filepath="$1"
    local filename; filename=$(basename "$filepath")
    local src="$REPO_ROOT/scripts/$filepath"
    local dst="$opt_root/bin/$filename"
    copy_file "$src" "$dst" 755 || true
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
        CONF|SRC)
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
    esac
done

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
