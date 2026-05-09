# 共通ログヘルパ（プレーンテキスト出力）
#
# 使い方：呼び出し側スクリプトの先頭で source する
#   source "$(dirname "$0")/<...>/lib/bash/logging.sh"
#
# 出力フォーマット: [YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message
#   - タイムゾーン: Asia/Tokyo (JST、UTC+9) 固定。OS 設定には依存しない
#   - レベル: 5 文字左詰め（INFO , WARN , ERROR, DEBUG）
#   - ストリーム: WARN/ERROR は stderr、INFO/DEBUG は stdout
#
# 構造化プロパティ引数は意図的にサポートしていない。"key=value" の組み立ては
# 呼び出し側で行い、メッセージ文字列に埋め込むこと。

# ----------------------------------------------------------------------------
# JST タイムスタンプを生成して標準出力に書き出す
# 引数: $1 = date(1) のフォーマット文字列（省略時 %Y%m%d-%H%M%S）
# 用途: リソース名・タグ値・S3 キー suffix 等
# ----------------------------------------------------------------------------
ops_jst_stamp() {
    TZ=Asia/Tokyo date +"${1:-%Y%m%d-%H%M%S}"
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
}

log_debug() { _ops_log DEBUG "$@"; }
log_info()  { _ops_log INFO  "$@"; }
log_warn()  { _ops_log WARN  "$@"; }
log_error() { _ops_log ERROR "$@"; }
