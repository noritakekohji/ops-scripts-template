#!/usr/bin/env bash
# ============================================================================
# check_template.sh
#   Verify that every script under scripts_linux/ and scripts_windows/
#   conforms to the template / shell-specification.md rules.
#
# Usage: check_template.sh
#
# Exit codes:
#   0 = all scripts conform
#   1 = one or more violations found
# ============================================================================
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
violations=0

# Directories that are excluded from the strict library-import rule.
# These are stand-alone runtime tools that intentionally do not depend on
# scripts_*/lib (they ship inside tools/ and must remain self-contained).
EXCLUDE_LIB_RULE_REGEX='/tools/(perf-monitor|network-check|change-detect|server-compare|templates)/'

violation() {
    echo "VIOLATION: $1 -- $2" >&2
    violations=$((violations + 1))
}

# Check that $file contains a line matching $pattern (extended regex).
require_pattern() {
    local file="$1" rule="$2" pattern="$3"
    if ! grep -Eq -- "$pattern" "$file"; then
        violation "$file" "$rule"
    fi
}

# Check that $file's first non-empty line equals $expected verbatim.
require_first_line() {
    local file="$1" rule="$2" expected="$3"
    local actual
    actual=$(awk 'NF { print; exit }' "$file")
    if [[ "$actual" != "$expected" ]]; then
        violation "$file" "$rule (expected first line: '$expected'; got: '$actual')"
    fi
}

ps_count=0
sh_count=0

# --- PowerShell scripts -----------------------------------------------------
echo "==> Checking PowerShell scripts under scripts_windows/..." >&2
while IFS= read -r -d '' f; do
    ps_count=$((ps_count + 1))
    require_pattern    "$f" "PS: must declare #Requires -Version 5.1"        '^#Requires -Version 5\.1'
    require_pattern    "$f" "PS: must have comment-based help (<# ... #>)"   '^<#'
    require_pattern    "$f" "PS: must have [CmdletBinding(...)] attribute"   '\[CmdletBinding'
    require_pattern    "$f" "PS: must set \$ErrorActionPreference = 'Stop'"  "ErrorActionPreference[[:space:]]*=[[:space:]]*'Stop'"
    require_pattern    "$f" "PS: must set Set-StrictMode -Version Latest"    'Set-StrictMode -Version Latest'
    if [[ ! "$f" =~ $EXCLUDE_LIB_RULE_REGEX ]]; then
        require_pattern "$f" "PS: must import Logging.psm1"                  'Logging\.psm1'
    fi
done < <(find "$REPO_ROOT/scripts_windows" -type f -name '*.ps1' -print0 2>/dev/null || true)

# --- Bash scripts -----------------------------------------------------------
echo "==> Checking Bash scripts under scripts_linux/..." >&2
while IFS= read -r -d '' f; do
    sh_count=$((sh_count + 1))
    require_first_line "$f" "Bash: first non-empty line must be the bash shebang" '#!/usr/bin/env bash'
    require_pattern    "$f" "Bash: must enable safe mode (set -euo pipefail)"     'set -euo pipefail'
    if [[ ! "$f" =~ $EXCLUDE_LIB_RULE_REGEX ]]; then
        require_pattern "$f" "Bash: must source lib/logging.sh"                   'lib/logging\.sh'
    fi
    if [[ ! -x "$f" ]]; then
        violation "$f" "Bash: must be executable (chmod +x / git update-index --chmod=+x)"
    fi
done < <(find "$REPO_ROOT/scripts_linux" -type f -name '*.sh' -print0 2>/dev/null || true)

# --- result -----------------------------------------------------------------
echo "" >&2
echo "Scanned: ps1=$ps_count sh=$sh_count" >&2

if [[ "$violations" -gt 0 ]]; then
    echo "FAILED: $violations violation(s)." >&2
    exit 1
fi

echo "OK: all scripts conform to the template." >&2
exit 0
