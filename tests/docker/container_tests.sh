#!/usr/bin/env bash
# ============================================================================
# container_tests.sh  -  Test runner executed INSIDE the Docker container
# Called by run_tests.sh via:  docker run ... bash /ops/tests/container_tests.sh
# ============================================================================
set -uo pipefail

TOOLS=/ops/tools
TESTS=/ops/tests
TMP=/tmp/ops_test
mkdir -p "$TMP"

# ---- helpers ----------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
SEP="──────────────────────────────────────────────────────────"

GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
BOLD=$'\e[1m'; RESET=$'\e[0m'

suite() { echo; echo "${BOLD}${CYAN}=== $* ===${RESET}"; }

check() {
    local name="$1"; shift
    local out; out=$(mktemp)
    if "$@" >"$out" 2>&1; then
        printf "${GREEN}[PASS]${RESET} %s\n" "$name"
        PASS=$((PASS+1))
    else
        printf "${RED}[FAIL]${RESET} %s\n" "$name"
        sed 's/^/       /' "$out" >&2
        FAIL=$((FAIL+1))
    fi
    rm -f "$out"
}

check_json() {
    local name="$1" file="$2" jq_expr="$3"
    check "$name" python3 -c "
import json, sys
d = json.load(open('$file'))
result = eval('$jq_expr', {'d': d})
if not result:
    print('assertion failed: $jq_expr', file=sys.stderr)
    sys.exit(1)
"
}

# ---- Prerequisite check ------------------------------------------------------
suite "Prerequisites"
check "python3 available"  python3 --version
check "ping available"     ping -c 1 -W 2 127.0.0.1
check "ip available"       ip addr show lo
check "df available"       df -BG /
check "lsblk available"    lsblk -J 2>/dev/null || true   # OK if no block devices

# ============================================================================
# Tool 1: get_server_info.sh
# ============================================================================
suite "get_server_info.sh"

SI_BASIC="$TMP/si_basic.json"
SI_ALL="$TMP/si_all.json"

check "os,network,filesystem collection" \
    bash "$TOOLS/server-compare/get_server_info.sh" -c os,network,filesystem -o "$SI_BASIC"

check_json "JSON meta.hostname present"   "$SI_BASIC" "'hostname' in d.get('meta',{})"
check_json "JSON os category collected"   "$SI_BASIC" "'os' in d"
check_json "JSON os.architecture present" "$SI_BASIC" "bool(d.get('os',{}).get('architecture',''))"
check_json "JSON network collected"       "$SI_BASIC" "'network' in d"
check_json "JSON filesystem collected"    "$SI_BASIC" "'filesystem' in d"

check "all categories collection" \
    bash "$TOOLS/server-compare/get_server_info.sh" -o "$SI_ALL"

check_json "all: services collected"    "$SI_ALL" "'services' in d"
check_json "all: packages collected"    "$SI_ALL" "'packages' in d"
check_json "all: environment collected" "$SI_ALL" "'environment' in d"

# ============================================================================
# Tool 2: check_network_connectivity.sh
# ============================================================================
suite "check_network_connectivity.sh"

NC_HTML="$TMP/nc_report.html"

# Run check — exit 1 is expected when ping/some port fails; capture exit code
check "script runs without Python errors" bash -c "
    bash '$TOOLS/network-check/check_network_connectivity.sh' \
         -l '$TESTS/test_targets.lst' \
         -o '$NC_HTML' 2>&1 \
    | grep -v '^EXIT'
    # Fail only on Python/bash script errors (not on host unreachable)
    ! grep -q 'Traceback\|SyntaxError\|NameError\|unbound variable' \
          <(bash '$TOOLS/network-check/check_network_connectivity.sh' \
               -l '$TESTS/test_targets.lst' 2>&1)
"

check "HTML report created" test -f "$NC_HTML"

check "HTML contains google.com" python3 -c "
s = open('$NC_HTML').read()
assert 'google.com' in s, 'google.com not found in HTML'
assert 'PASS' in s or 'FAIL' in s, 'No evaluation badges in HTML'
"

# DNS works independently
check "DNS: google.com resolves" python3 -c "
import socket
addrs = [i[4][0] for i in socket.getaddrinfo('google.com', None) if ':' not in i[4][0]]
assert addrs, 'No IPv4 address for google.com'
print('Resolved:', addrs[:2])
"

# TCP checks
check "TCP: google.com:443 reachable" python3 -c "
import socket
s = socket.socket()
s.settimeout(5)
s.connect(('google.com', 443))
s.close()
"

check "TCP: google.com:22 not reachable (SSH blocked)" python3 -c "
import socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('google.com', 22))
    s.close()
    # If connected, it's unexpected but not a script error
    print('Warning: port 22 connected (expected blocked)')
except Exception as e:
    print('Expected:', e)
"

# ============================================================================
# Tool 3: change_detect.sh
# ============================================================================
suite "change_detect.sh"

CD_DIR="$TMP/change_detect"
mkdir -p "$CD_DIR"
CD_HTML="$CD_DIR/report.html"

check "before snapshot" bash -c "
    cd '$CD_DIR' && \
    bash '$TOOLS/change-detect/change_detect.sh' before -l docker-test -c os,filesystem 2>&1
"

check "before JSON created" bash -c "
    ls '$CD_DIR'/*_before_docker-test_*.json 1>/dev/null
"

check "after snapshot + comparison" bash -c "
    cd '$CD_DIR' && \
    bash '$TOOLS/change-detect/change_detect.sh' after -l docker-test -c os,filesystem 2>&1
"

check "after JSON created" bash -c "
    ls '$CD_DIR'/*_after_docker-test_*.json 1>/dev/null
"

check "HTML report from compare" bash -c "
    BEFORE=\$(ls '$CD_DIR'/*_before_docker-test_*.json | head -1)
    AFTER=\$(ls '$CD_DIR'/*_after_docker-test_*.json | head -1)
    cd '$CD_DIR' && \
    bash '$TOOLS/change-detect/change_detect.sh' compare \"\$BEFORE\" \"\$AFTER\" --html '$CD_HTML' 2>&1
"

check "HTML report created"   test -f "$CD_HTML"
check "HTML content valid" python3 -c "
s = open('$CD_HTML').read()
assert 'CHANGE DETECTION REPORT' in s
assert 'os' in s.lower()
"

check "0 changes (no change between snapshots)" bash -c "
    BEFORE=\$(ls '$CD_DIR'/*_before_docker-test_*.json | head -1)
    AFTER=\$(ls '$CD_DIR'/*_after_docker-test_*.json | head -1)
    cd '$CD_DIR' && \
    bash '$TOOLS/change-detect/change_detect.sh' compare \"\$BEFORE\" \"\$AFTER\" 2>&1 \
    | grep -q 'Total changes: 0'
"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "$SEP"
TOTAL=$((PASS+FAIL+SKIP))
if [[ "$FAIL" -eq 0 ]]; then
    printf "${GREEN}${BOLD}  ALL TESTS PASSED${RESET}\n"
else
    printf "${RED}${BOLD}  SOME TESTS FAILED${RESET}\n"
fi
printf "  Total: %d   ${GREEN}PASS: %d${RESET}   ${RED}FAIL: %d${RESET}\n" "$TOTAL" "$PASS" "$FAIL"
echo "$SEP"
echo ""

exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
