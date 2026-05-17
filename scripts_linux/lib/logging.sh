# 共通ログヘルパ（プレーンテキスト出力）
#
# 使い方：呼び出し側スクリプトの先頭で source する
#   source "$(dirname "$0")/../lib/logging.sh"
#
# 出力フォーマット: [YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message
#   - タイムゾーン: Asia/Tokyo (JST、UTC+9) 固定。OS 設定には依存しない
#   - レベル: 5 文字左詰め（INFO , WARN , ERROR, DEBUG）
#   - ストリーム: WARN/ERROR は stderr、INFO/DEBUG は stdout
#   - ファイル出力: set_ops_log_config で有効化（PowerShell 版 Set-OpsLogConfig と対応）
#
# 構造化プロパティ引数は意図的にサポートしていない。"key=value" の組み立ては
# 呼び出し側で行い、メッセージ文字列に埋め込むこと。

# ----------------------------------------------------------------------------
# ファイル出力設定（既定: 無効）
# ----------------------------------------------------------------------------
# レベル優先度
_OPS_LOG_LEVEL_DEBUG=0
_OPS_LOG_LEVEL_INFO=1
_OPS_LOG_LEVEL_WARN=2
_OPS_LOG_LEVEL_ERROR=3

# 現在のファイル出力先と最小レベル（空のとき無効）
OPS_LOG_FILE_PATH=""
OPS_LOG_FILE_MIN_LEVEL="$_OPS_LOG_LEVEL_INFO"

# ----------------------------------------------------------------------------
# set_ops_log_config <file> [level]
#   ファイル出力を有効にする。level 省略時は INFO。level は DEBUG/INFO/WARN/ERROR。
#   既存ファイルには追記。親ディレクトリが存在しなければ作成を試みる。
# 戻り値:
#   0 = OK / 1 = 引数不正 / 2 = 書き込み失敗
# ----------------------------------------------------------------------------
set_ops_log_config() {
    local file="${1:-}"
    local level="${2:-INFO}"
    if [[ -z "$file" ]]; then
        OPS_LOG_FILE_PATH=""
        return 0
    fi
    local lv
    case "$level" in
        DEBUG) lv="$_OPS_LOG_LEVEL_DEBUG" ;;
        INFO)  lv="$_OPS_LOG_LEVEL_INFO" ;;
        WARN)  lv="$_OPS_LOG_LEVEL_WARN" ;;
        ERROR) lv="$_OPS_LOG_LEVEL_ERROR" ;;
        *)     return 1 ;;
    esac
    # 親ディレクトリを作成（既に存在すれば no-op）
    local dir
    dir=$(dirname -- "$file")
    if [[ ! -d "$dir" ]]; then
        mkdir -p -- "$dir" 2>/dev/null || return 2
    fi
    # 書き込めるか確認
    : >> "$file" 2>/dev/null || return 2
    OPS_LOG_FILE_PATH="$file"
    OPS_LOG_FILE_MIN_LEVEL="$lv"
    return 0
}

# ----------------------------------------------------------------------------
# 互換ヘルパ: 設定読み込み後に呼ぶと、LogFile/LogLevel キーを反映する。
# PowerShell 版の Apply-LogConfig 相当。
#   apply_ops_log_config_from_env [config_dir_for_relative]
# OPS_CONFIG (連想配列) から LogFile / LogLevel を取り出して set_ops_log_config。
# ----------------------------------------------------------------------------
apply_ops_log_config_from_env() {
    local base_dir="${1:-}"
    local lf="${OPS_CONFIG[LogFile]:-}"
    local ll="${OPS_CONFIG[LogLevel]:-INFO}"
    [[ -z "$lf" ]] && return 0
    # 相対パスは base_dir 起点（指定なしなら CWD）に解決
    if [[ "$lf" != /* && -n "$base_dir" ]]; then
        lf="${base_dir%/}/$lf"
    fi
    set_ops_log_config "$lf" "$ll" || true
}

# ----------------------------------------------------------------------------
# JST タイムスタンプを生成して標準出力に書き出す
# 引数: $1 = date(1) のフォーマット文字列（省略時 %Y%m%d-%H%M%S）
# 用途: リソース名・タグ値・S3 キー suffix 等
# ----------------------------------------------------------------------------
ops_jst_stamp() {
    TZ=Asia/Tokyo date +"${1:-%Y%m%d-%H%M%S}"
}

# ----------------------------------------------------------------------------
# 内部: レベル名 -> 数値
# ----------------------------------------------------------------------------
_ops_level_value() {
    case "$1" in
        DEBUG) echo "$_OPS_LOG_LEVEL_DEBUG" ;;
        INFO)  echo "$_OPS_LOG_LEVEL_INFO" ;;
        WARN)  echo "$_OPS_LOG_LEVEL_WARN" ;;
        ERROR) echo "$_OPS_LOG_LEVEL_ERROR" ;;
        *)     echo "$_OPS_LOG_LEVEL_INFO" ;;
    esac
}

# ----------------------------------------------------------------------------
# 内部: 1 行のログレコードを組み立てて適切なストリームに書き出す
# ----------------------------------------------------------------------------
_ops_log() {
    local level="$1"; shift
    local msg="$*"

    # JST 固定のタイムスタンプ
    local ts
    ts=$(TZ=Asia/Tokyo date +"%Y-%m-%d %H:%M:%S")

    # 呼び出し元スクリプトの basename を取得
    # BASH_SOURCE[2] は log_xxx ラッパを呼んだファイル（log_xxx は本ファイル内）
    local caller="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-$0}}"
    local shell
    shell=$(basename "$caller")

    # レベルを 5 文字に左詰め
    local padded
    printf -v padded "%-5s" "$level"

    # 1 行 1 イベントを保証するため改行を空白に置換
    msg=${msg//$'\n'/ }
    msg=${msg//$'\r'/ }

    local line="[${ts}] [${padded}] (${shell}:$$) ${msg}"

    case "$level" in
        WARN|ERROR) printf '%s\n' "$line" >&2 ;;
        *)          printf '%s\n' "$line" ;;
    esac

    # ファイル出力（有効かつレベル閾値以上のとき）
    if [[ -n "$OPS_LOG_FILE_PATH" ]]; then
        local lvNum
        lvNum=$(_ops_level_value "$level")
        if (( lvNum >= OPS_LOG_FILE_MIN_LEVEL )); then
            # 書き込み失敗時はログ機構の二次障害を避けるため握りつぶす
            printf '%s\n' "$line" >> "$OPS_LOG_FILE_PATH" 2>/dev/null || true
        fi
    fi
}

log_debug() { _ops_log DEBUG "$@"; }
log_info()  { _ops_log INFO  "$@"; }
log_warn()  { _ops_log WARN  "$@"; }
log_error() { _ops_log ERROR "$@"; }
