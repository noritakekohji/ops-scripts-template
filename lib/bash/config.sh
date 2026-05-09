# Shared key=value config loader for ops scripts.
#
# Source this file from your script after logging.sh:
#   source "$(dirname "$0")/<...>/lib/bash/config.sh"
#
# Then call:
#   load_ops_config <script-name> [<env>]
#
# Populates the global associative array OPS_CONFIG with the merged result of:
#
#   config/common/ops.conf
#   config/common/<script-name>.conf
#   config/<env>/ops.conf
#   config/<env>/<script-name>.conf
#
# Later files override earlier ones. Missing files are skipped silently.
# Lines: key=value. '#' lines and blank lines ignored. Whitespace trimmed.
# Matching single / double quotes around the value are stripped.
#
# Requires Bash 4+ (associative arrays).

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

    local lib_dir
    lib_dir=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    local repo_root
    if ! repo_root=$(_ops_find_repo_root "$lib_dir"); then
        echo "config.sh: cannot determine repo root from $lib_dir" >&2
        return 1
    fi

    declare -gA OPS_CONFIG=()
    OPS_CONFIG_ENV="$env"

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
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[2]}"
                key="${key#"${key%%[![:space:]]*}"}"
                key="${key%"${key##*[![:space:]]}"}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
                    val="${BASH_REMATCH[1]}"
                fi
                OPS_CONFIG["$key"]="$val"
            fi
        done < "$f"
    done
}
