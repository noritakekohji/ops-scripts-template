#!/usr/bin/env bash
# ============================================================================
# deploy_scripts.sh
#   リポジトリの scripts / config / lib / tests から指定対象だけを
#   <opt_root> 配下にローカル配備（インストール）する。
#
# 使い方:
#   deploy_scripts.sh -L <list-file> [-d <opt-root>] [-e <envs>]
#                     [-m <mode>] [-b] [-n]
#
# オプション:
#   -L  デプロイ対象リストファイル（必須、1 行 1 スクリプト）
#   -d  配備先 root（既定 /opt/ops-scripts、config 可）
#   -e  含める env 群: common（既定）、dev、staging、production、all、カンマ区切り
#   -m  既定 mode: script-only / with-config（既定）/ with-tests / all
#   -b  既存ファイルをタイムスタンプ付きでバックアップしてから上書き
#   -n  Dry-run（実際の操作なし、ログのみ）
#   -h  usage 表示
#
# 配備後レイアウト:
#   <opt_root>/script/<file>.sh       (mode 0755)
#   <opt_root>/conf/<env>/<file>.conf (mode 0644)
#   <opt_root>/tests/<file>.bats      (mode 0755)
#   <opt_root>/lib/bash/<file>.sh     (必須付帯)
#
# 配備時にスクリプト内の lib import パスを ../../../lib/ → ../lib/ に書換え。
#
# 終了コード: 0 成功/skipped/partial、1 usage、2 リスト不在、4 全件失敗、
#             5 配備先書込み不可
# ============================================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../lib/bash/config.sh"

usage() { sed -n '2,30p' "$0" >&2; exit 1; }

# Phase 5 ステート
deployed=0
unchanged=0
backed_up=0
failed=0
status="unknown"
opt_root="/opt/ops-scripts"
backup_existing=0
dry_run=0

cleanup() {
    local rc=$?
    if [[ "$status" == "unknown" && "$rc" -eq 0 ]]; then status="success"; fi
    log_info "Script end: status=$status exitCode=$rc deployed=$deployed unchanged=$unchanged backedUp=$backed_up failed=$failed"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# ヘルパ
# ----------------------------------------------------------------------------

# 単一ファイルを冪等にコピー（既存と一致なら skip、異なれば backup → 上書き）
# 引数: $1=src, $2=dst, $3=permission（例 0755）
copy_file() {
    local src="$1" dst="$2" perm="$3"
    if [[ -f "$dst" ]]; then
        if [[ "$(sha256sum "$src" | awk '{print $1}')" == "$(sha256sum "$dst" | awk '{print $1}')" ]]; then
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
                log_info "[DRY-RUN] would backup: from=$dst to=$backup_path"
            fi
            backed_up=$((backed_up+1))
        else
            log_warn "Overwriting without backup: dst=$dst"
        fi
    fi
    if [[ "$dry_run" -eq 1 ]]; then
        log_info "[DRY-RUN] would deploy: src=$src dst=$dst mode=$perm"
        deployed=$((deployed+1))
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    if cp -p -- "$src" "$dst" && chmod "$perm" -- "$dst"; then
        log_info "Deployed: src=$src dst=$dst mode=$perm"
        deployed=$((deployed+1))
        return 0
    else
        log_error "Copy failed: src=$src dst=$dst"
        failed=$((failed+1))
        return 1
    fi
}

# 配備済み Bash スクリプトの lib import パスを書換え
# ../../../lib/  →  ../lib/   （任意の 2+ '../' をまとめて 1 つにする）
rewrite_bash_lib_path() {
    local f="$1"
    [[ "$dry_run" -eq 1 ]] && return 0
    [[ ! -f "$f" ]] && return 0
    sed -i -E 's|(\.\./){2,}lib/|../lib/|g' "$f"
}

# リスト中のスクリプト名から実体パスを解決
# 引数: $1=name, $2=明示 Path（省略可）
# 出力: 実体の絶対パス（見つからなければ空）
resolve_script_source() {
    local name="$1" explicit="$2"
    if [[ -n "$explicit" ]]; then
        if [[ -f "$REPO_ROOT/$explicit" ]]; then printf '%s\n' "$REPO_ROOT/$explicit"; return 0; fi
        if [[ -f "$explicit" ]]; then printf '%s\n' "$explicit"; return 0; fi
        return 1
    fi
    local search="$name"
    if [[ "$search" != *.sh ]]; then search="${name}.sh"; fi
    local m
    m=$(find "$REPO_ROOT/scripts" -type f -name "$search" 2>/dev/null)
    if [[ -z "$m" ]]; then return 1; fi
    local count
    count=$(printf '%s\n' "$m" | wc -l)
    if [[ "$count" -gt 1 ]]; then
        log_warn "Multiple matches for '$name' (using first): $(echo "$m" | tr '\n' ' ')"
    fi
    printf '%s\n' "$(echo "$m" | head -n1)"
}

# 1 つのスクリプト + 関連 conf / tests を配備
deploy_entry() {
    local name="$1" entry_mode="$2" exp_path="$3" exp_conf="$4" exp_tests="$5"
    local src
    if ! src=$(resolve_script_source "$name" "$exp_path"); then
        log_warn "Script not found in repo, skipping: name=$name"
        failed=$((failed+1))
        return 1
    fi
    local base stem
    base=$(basename "$src")
    stem="${base%.sh}"

    # (1) 本体スクリプト
    local dst_script="$opt_root/script/$base"
    if copy_file "$src" "$dst_script" 755; then
        rewrite_bash_lib_path "$dst_script"
    fi

    # (2) 設定ファイル
    if [[ "$entry_mode" == "with-config" || "$entry_mode" == "all" ]]; then
        local conf_name="${exp_conf:-${stem}.conf}"
        local envs
        if [[ "$include_envs" == "all" ]]; then
            envs="common dev staging production"
        else
            envs="${include_envs//,/ }"
        fi
        local env src_conf src_ops
        for env in $envs; do
            src_conf="$REPO_ROOT/config/$env/$conf_name"
            if [[ -f "$src_conf" ]]; then
                copy_file "$src_conf" "$opt_root/conf/$env/$conf_name" 644
            fi
            # 各 env の ops.conf も付帯（重複は copy_file の unchanged チェックで吸収）
            src_ops="$REPO_ROOT/config/$env/ops.conf"
            if [[ -f "$src_ops" ]]; then
                copy_file "$src_ops" "$opt_root/conf/$env/ops.conf" 644
            fi
        done
    fi

    # (3) テスト
    if [[ "$entry_mode" == "with-tests" || "$entry_mode" == "all" ]]; then
        local test_name="${exp_tests:-${stem}.bats}"
        local test_src="$REPO_ROOT/tests/bats/$test_name"
        if [[ -f "$test_src" ]]; then
            copy_file "$test_src" "$opt_root/tests/$(basename "$test_src")" 755
        fi
    fi
}

# lib/bash/ を配備（スクリプトが必須）
deploy_lib() {
    log_info "Deploying lib/bash"
    local libf
    for libf in "$REPO_ROOT"/lib/bash/*.sh; do
        [[ -f "$libf" ]] || continue
        copy_file "$libf" "$opt_root/lib/bash/$(basename "$libf")" 644
    done
}

# ----------------------------------------------------------------------------
# --- フェーズ 1: 引数パース ---
# ----------------------------------------------------------------------------
list_file=""
include_envs="common"
mode="with-config"

opt_root_set=0
include_envs_set=0
mode_set=0

while getopts "L:d:e:m:bnh" opt; do
    case "$opt" in
        L) list_file="$OPTARG" ;;
        d) opt_root="$OPTARG"; opt_root_set=1 ;;
        e) include_envs="$OPTARG"; include_envs_set=1 ;;
        m) mode="$OPTARG"; mode_set=1 ;;
        b) backup_existing=1 ;;
        n) dry_run=1 ;;
        h|*) usage ;;
    esac
done

# ----------------------------------------------------------------------------
# --- フェーズ 2: 設定ファイル読込み、未指定値へ反映 ---
# ----------------------------------------------------------------------------
load_ops_config "deploy_scripts"
[[ "$opt_root_set" -eq 0     && -n "${OPS_CONFIG[OptRoot]:-}"     ]] && opt_root="${OPS_CONFIG[OptRoot]}"
[[ "$include_envs_set" -eq 0 && -n "${OPS_CONFIG[IncludeEnvs]:-}" ]] && include_envs="${OPS_CONFIG[IncludeEnvs]}"
[[ "$mode_set" -eq 0         && -n "${OPS_CONFIG[Mode]:-}"        ]] && mode="${OPS_CONFIG[Mode]}"
# -L 未指定なら config の PathList を採用。相対パスは repo root 起点で絶対化。
if [[ -z "$list_file" && -n "${OPS_CONFIG[PathList]:-}" ]]; then
    list_file="${OPS_CONFIG[PathList]}"
    if [[ "$list_file" != /* ]]; then
        list_file="$(ops_repo_root)/$list_file"
    fi
fi

log_info "Config loaded: env=${OPS_CONFIG_ENV:-common} keys=${#OPS_CONFIG[@]}"

# 入力検証
[[ -z "$list_file" ]] && { log_error "Specify -L or set PathList in config"; status="failed"; exit 1; }
case "$mode" in script-only|with-config|with-tests|all) ;;
    *) log_error "Invalid mode: $mode"; status="failed"; exit 1 ;;
esac

log_info "Args validated: listFile=$list_file optRoot=$opt_root includeEnvs=$include_envs mode=$mode backup=$backup_existing dryRun=$dry_run"

# ----------------------------------------------------------------------------
# --- フェーズ 3: プレチェック（リストパース、配備先確認）---
# ----------------------------------------------------------------------------
log_info "Pre-check start"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
log_info "Repo root: $REPO_ROOT"

if [[ ! -f "$list_file" ]]; then
    log_error "List file not found: $list_file"
    status="failed"; exit 2
fi

if [[ "$dry_run" -eq 0 ]]; then
    if ! mkdir -p "$opt_root" 2>/dev/null; then
        log_error "Cannot create or write to opt_root: $opt_root"
        status="failed"; exit 5
    fi
    if [[ ! -w "$opt_root" ]]; then
        log_error "Not writable: $opt_root"
        status="failed"; exit 5
    fi
fi

# リストをパース（タブ区切りレコードに変換して entries に蓄積）
declare -a entries=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    # shellcheck disable=SC2206
    tok=( $line )
    e_name="${tok[0]}"
    e_mode="$mode"
    e_path=""
    e_conf=""
    e_tests=""
    for ((i=1; i<${#tok[@]}; i++)); do
        kv="${tok[$i]}"
        if [[ "$kv" =~ ^([^=]+)=(.*)$ ]]; then
            k="${BASH_REMATCH[1]}"
            v="${BASH_REMATCH[2]}"
            case "$k" in
                Mode)
                    case "$v" in script-only|with-config|with-tests|all) e_mode="$v" ;;
                        *) log_warn "Invalid Mode: line='$line' value='$v'" ;;
                    esac ;;
                Path)  e_path="$v" ;;
                Conf)  e_conf="$v" ;;
                Tests) e_tests="$v" ;;
                *) log_warn "Unknown key: line='$line' key='$k'" ;;
            esac
        fi
    done
    entries+=( "${e_name}"$'\t'"${e_mode}"$'\t'"${e_path}"$'\t'"${e_conf}"$'\t'"${e_tests}" )
done < "$list_file"

if [[ "${#entries[@]}" -eq 0 ]]; then
    log_warn "No entries to deploy (skipped)"
    status="skipped"
    exit 0
fi

log_info "Pre-check passed: entryCount=${#entries[@]}"

# ----------------------------------------------------------------------------
# --- フェーズ 4: メイン処理 ---
# ----------------------------------------------------------------------------
log_info "Main start"

for entry in "${entries[@]}"; do
    IFS=$'\t' read -r e_name e_mode e_path e_conf e_tests <<< "$entry"
    deploy_entry "$e_name" "$e_mode" "$e_path" "$e_conf" "$e_tests"
done

deploy_lib

if [[ "$failed" -gt 0 && "$deployed" -eq 0 ]]; then
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
