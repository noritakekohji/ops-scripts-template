# 共通の設定ローダ（key=value 形式）
#
# 使い方：呼び出し側スクリプトから logging.sh の後に source する
#   source "$(dirname "$0")/<...>/lib/bash/config.sh"
#
# 関数を呼び出す：
#   load_ops_config <script-name> [<env>]
#
# 連想配列 OPS_CONFIG に次のファイルを格納する：
#
#   env 未指定: config/default/global.conf + config/default/<script-name>.conf
#   env 指定時: config/<env>/global.conf   + config/<env>/<script-name>.conf
#
# 存在しないファイルは黙ってスキップ。
# 1 行 1 設定（key=value）、行頭 '#' 行と空行は無視、前後空白は trim。
# 値を囲む "..." / '...' は除去される。
#
# 必要環境: Bash 4+（連想配列）

# config 内の相対パスを絶対化する用のヘルパ：
# 本ファイルの位置から親を辿って `.git` または `shell-specification.md`
# を持つディレクトリを repo root として返す。
ops_repo_root() {
    local lib_dir
    lib_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    _ops_find_repo_root "$lib_dir"
}

# 内部: 与えられた起点から親ディレクトリを辿り、リポジトリ root を検出。
#
# 検出順位:
#   1. .ops-deploy-root マーカー（install 時に <OptRoot>/.ops-deploy-root が touch される）
#   2. .git ディレクトリ（ソースリポジトリ作業ツリー）
#   3. shell-specification.md（テンプレ内ユニットテスト用）
_ops_find_repo_root() {
    local current="$1"
    while [[ -n "$current" && "$current" != "/" ]]; do
        if [[ -f "$current/.ops-deploy-root" ]]; then
            printf '%s\n' "$current"; return 0
        fi
        if [[ -d "$current/.git" ]]; then
            printf '%s\n' "$current"; return 0
        fi
        if [[ -f "$current/shell-specification.md" ]]; then
            printf '%s\n' "$current"; return 0
        fi
        current=$(dirname -- "$current")
    done
    return 1
}

load_ops_config() {
    local name="$1"
    # OPS_ENV 未設定なら空文字（default のみ読む）
    local env="${2:-${OPS_ENV:-}}"
    # 第 3 引数を渡すと、リポジトリ root の自動検出を上書きできる
    # （主にユニットテスト用。PS 版 Get-OpsConfig の -RepoRoot と対応）
    local override_root="${3:-}"

    local repo_root
    if [[ -n "$override_root" ]]; then
        repo_root="$override_root"
    elif [[ -n "${OPS_CONFIG_DIR:-}" ]]; then
        # OPS_CONFIG_DIR が明示されていれば、それを config_dir 直下として扱う
        # （repo_root は OPS_CONFIG_DIR の親と推定。env 階層は無視）
        repo_root=""  # 後段で config_dir を直接設定
    else
        local lib_dir
        lib_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        if ! repo_root=$(_ops_find_repo_root "$lib_dir"); then
            echo "config.sh: cannot determine repo root from $lib_dir" >&2
            return 1
        fi
    fi

    # 連想配列を初期化（呼び出すたびにリセット）
    declare -gA OPS_CONFIG=()
    OPS_CONFIG_ENV="${env:-default}"

    # 候補ディレクトリの組み立て:
    #   1) OPS_CONFIG_DIR 明示時は最優先
    #   2) <repo_root>/config/<env>/ または <repo_root>/config/default/
    #   3) <repo_root>/config/                  （配備先のフラット構造用フォールバック）
    local -a config_dirs=()
    if [[ -n "${OPS_CONFIG_DIR:-}" ]]; then
        config_dirs+=( "$OPS_CONFIG_DIR" )
    fi
    if [[ -n "$repo_root" ]]; then
        if [[ -n "$env" ]]; then
            config_dirs+=( "$repo_root/config/$env" )
        else
            config_dirs+=( "$repo_root/config/default" )
        fi
        # 配備先のフラットレイアウト（<OptRoot>/config/<name>.conf）
        config_dirs+=( "$repo_root/config" )
    fi

    local sources=()
    local d
    for d in "${config_dirs[@]}"; do
        sources+=( "$d/global.conf" "$d/$name.conf" )
    done

    local f line key val
    for f in "${sources[@]}"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            # 前後の空白を trim
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            # 空行とコメント行はスキップ
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                # キーと値それぞれの前後空白を trim
                key="${key#"${key%%[![:space:]]*}"}"
                key="${key%"${key##*[![:space:]]}"}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                # 値を囲む引用符を除去
                if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
                    val="${BASH_REMATCH[1]}"
                fi
                OPS_CONFIG["$key"]="$val"
            fi
        done < "$f"
    done

    # logging.sh が読み込まれていれば、LogFile/LogLevel を自動で反映する。
    # PowerShell 版の Apply-LogConfig と対応（こちらは bash でも同じ挙動を実現）。
    if declare -f apply_ops_log_config_from_env >/dev/null 2>&1; then
        # 相対パスは repo_root 起点で解決する
        apply_ops_log_config_from_env "$repo_root"
    fi
}
