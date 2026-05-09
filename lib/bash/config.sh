# 共通の設定ローダ（key=value 形式）
#
# 使い方：呼び出し側スクリプトから logging.sh の後に source する
#   source "$(dirname "$0")/<...>/lib/bash/config.sh"
#
# 関数を呼び出す：
#   load_ops_config <script-name> [<env>]
#
# 連想配列 OPS_CONFIG に次のファイルをマージした結果を格納する：
#
#   config/common/ops.conf
#   config/common/<script-name>.conf
#   config/<env>/ops.conf
#   config/<env>/<script-name>.conf
#
# 後のファイルが先のキーを上書きする。存在しないファイルは黙ってスキップ。
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

# 内部: 与えられた起点から親ディレクトリを辿り、リポジトリ root を検出
_ops_find_repo_root() {
    local current="$1"
    while [[ -n "$current" && "$current" != "/" ]]; do
        if [[ -d "$current/.git" || -f "$current/shell-specification.md" ]]; then
            printf '%s\n' "$current"
            return 0
        fi
        current=$(dirname -- "$current")
    done
    return 1
}

load_ops_config() {
    local name="$1"
    local env="${2:-${OPS_ENV:-common}}"
    # 第 3 引数を渡すと、リポジトリ root の自動検出を上書きできる
    # （主にユニットテスト用。PS 版 Get-OpsConfig の -RepoRoot と対応）
    local override_root="${3:-}"

    local repo_root
    if [[ -n "$override_root" ]]; then
        repo_root="$override_root"
    else
        # config.sh の位置を起点にリポジトリ root を見つける
        local lib_dir
        lib_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
        if ! repo_root=$(_ops_find_repo_root "$lib_dir"); then
            echo "config.sh: cannot determine repo root from $lib_dir" >&2
            return 1
        fi
    fi

    # 連想配列を初期化（呼び出すたびにリセット）
    declare -gA OPS_CONFIG=()
    OPS_CONFIG_ENV="$env"

    # 読み込み対象ファイルを優先度の低い順に列挙
    local sources=(
        "$repo_root/config/common/ops.conf"
        "$repo_root/config/common/$name.conf"
    )
    if [[ "$env" != "common" ]]; then
        sources+=( "$repo_root/config/$env/ops.conf" )
        sources+=( "$repo_root/config/$env/$name.conf" )
    fi

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
}
