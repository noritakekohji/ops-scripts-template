# Shared plain-text log helpers for ops scripts.
#
# Source from your script:
#   source "$(dirname "$0")/../../../../lib/bash/logging.sh"
#
# Output format: [YYYY-MM-DD hh:mm:ss] [Level] (shellname:pid) Message
#   - Timezone: local OS setting
#   - Level:    5-char left-padded (INFO , WARN , ERROR, DEBUG)
#   - Streams:  WARN/ERROR -> stderr, INFO/DEBUG -> stdout
#
# Structured properties are intentionally NOT supported — the caller is
# responsible for embedding any "key=value" pairs into the message itself.

_ops_log() {
    local level="$1"; shift
    local msg="$*"

    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")

    # Caller script basename: BASH_SOURCE[2] is the script that called the
    # public log_xxx wrapper, which itself called _ops_log.
    local caller="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-$0}}"
    local shell
    shell=$(basename "$caller")

    # Pad level to 5 chars
    local padded
    printf -v padded "%-5s" "$level"

    # Strip newlines so each entry stays on one line
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
