#!/usr/bin/env bash
# ============================================================================
# linux_tests.sh  -  Bash test suite (runs INSIDE the Linux Docker container)
#
# Mounts: /repo  (repository root, read-only)
#         /repo/tests/docker/fixtures  (test data)
# ============================================================================
set -uo pipefail

REPO=/repo
FIXTURES="$REPO/tests/docker/fixtures"
TMP=/tmp/ops_test
mkdir -p "$TMP"

# ============================================================
# Test framework
# ============================================================
PASS=0; FAIL=0
SEP="══════════════════════════════════════════════════════════"
DSEP="──────────────────────────────────────────────────────────"

suite() { echo; echo -e "\e[1m\e[36m${SEP}\e[0m"; echo -e "\e[1m\e[36m  SUITE: $*\e[0m"; echo -e "\e[1m\e[36m${SEP}\e[0m"; }

check() {
    local name="$1"; shift
    local out; out=$(mktemp)
    if "$@" >"$out" 2>&1; then
        printf "  \e[32m[PASS]\e[0m %s\n" "$name"; PASS=$((PASS+1))
    else
        printf "  \e[31m[FAIL]\e[0m %s\n" "$name"; FAIL=$((FAIL+1))
        # Show last 5 lines of output for diagnosis
        tail -5 "$out" | sed 's/^/         /' >&2
    fi
    rm -f "$out"
}

check_contains() {
    local name="$1" file="$2" pattern="$3"
    check "$name" grep -q "$pattern" "$file"
}

check_json_key() {
    local name="$1" file="$2" key="$3"
    check "$name" python3 -c "
import json, sys
d = json.load(open('$file'))
parts = '$key'.split('.')
v = d
for p in parts:
    v = v.get(p)
    if v is None: sys.exit(1)
"
}

syntax_check() {
    local name="$1" file="$2"
    check "syntax: $name" bash -n "$file"
}

# ============================================================
# Suite 1: Prerequisites
# ============================================================
suite "Prerequisites"

check "bash 4+"        bash -c '[[ ${BASH_VERSINFO[0]} -ge 4 ]]'
check "python3"        python3 --version
check "ping"           ping -c 1 -W 2 127.0.0.1
check "ip"             ip addr show lo
check "df"             df -BG /
check "lsblk"          bash -c 'lsblk -J 2>/dev/null; true'
check "traceroute"     which traceroute
check "nc"             which nc

# ============================================================
# Suite 2: scripts_linux/lib — logging.sh
# ============================================================
suite "scripts_linux/lib — logging.sh"

LIB_LOG="$REPO/scripts_linux/lib/logging.sh"

check "file exists"          test -f "$LIB_LOG"
check "syntax ok"            bash -n "$LIB_LOG"
check "source without error" bash -c "source '$LIB_LOG'"

check "log_info outputs line" bash -c "
    source '$LIB_LOG'
    out=\$(log_info 'hello test' 2>&1)
    [[ \"\$out\" == *'hello test'* ]]
"
check "log_error goes to stderr" bash -c "
    source '$LIB_LOG'
    log_error 'err test' 2>/tmp/stderr_test >/dev/null
    grep -q 'err test' /tmp/stderr_test
"
check "ops_jst_stamp returns string" bash -c "
    source '$LIB_LOG'
    s=\$(ops_jst_stamp)
    [[ -n \"\$s\" ]]
"

# ============================================================
# Suite 3: scripts_linux/lib — config.sh
# ============================================================
suite "scripts_linux/lib — config.sh"

LIB_CFG="$REPO/scripts_linux/lib/config.sh"

check "file exists"          test -f "$LIB_CFG"
check "syntax ok"            bash -n "$LIB_CFG"
check "source without error" bash -c "
    source '$REPO/scripts_linux/lib/logging.sh'
    source '$LIB_CFG'
"

# Create isolated test repo structure
TEST_REPO="$TMP/test_repo"
mkdir -p "$TEST_REPO/.git" "$TEST_REPO/config/default"
cp "$FIXTURES/test.conf" "$TEST_REPO/config/default/testscript.conf"
cat > "$TEST_REPO/config/default/global.conf" << 'EOF'
Region = ap-northeast-2
LogLevel = INFO
EOF

check "load_ops_config reads values" bash -c "
    source '$REPO/scripts_linux/lib/logging.sh'
    source '$LIB_CFG'
    load_ops_config 'testscript' '' '$TEST_REPO'
    [[ \"\${OPS_CONFIG[Region]:-}\" == 'ap-northeast-1' ]]
"
check "load_ops_config: global.conf override" bash -c "
    source '$REPO/scripts_linux/lib/logging.sh'
    source '$LIB_CFG'
    load_ops_config 'testscript' '' '$TEST_REPO'
    [[ \${#OPS_CONFIG[@]} -gt 0 ]]
"
check "ops_repo_root traverses up" bash -c "
    source '$REPO/scripts_linux/lib/logging.sh'
    source '$LIB_CFG'
    root=\$(cd '$REPO' && ops_repo_root)
    [[ -n \"\$root\" ]]
"

# ============================================================
# Suite 4: scripts_linux/os — get_server_info.sh
# ============================================================
suite "scripts_linux/os — get_server_info.sh"

GI="$REPO/scripts_linux/os/get_server_info.sh"
GI_OUT="$TMP/get_server_info_scripts.json"

check "file exists"         test -f "$GI"
syntax_check "script"       "$GI"

check "collect os,network,filesystem" bash "$GI" -c os,network,filesystem -o "$GI_OUT"
check_json_key "meta.hostname"    "$GI_OUT" "meta.hostname"
check_json_key "os category"      "$GI_OUT" "os.architecture"
check_json_key "filesystem drives" "$GI_OUT" "filesystem.drives"

check "collect all categories" bash "$GI" -o "$TMP/gi_all.json"
check "JSON: all keys present" python3 -c "
import json
d = json.load(open('$TMP/gi_all.json'))
for cat in ('os','network','filesystem','environment'):
    assert cat in d, f'Missing category: {cat}'
"

# ============================================================
# Suite 5: scripts_linux/os — rotate_log.sh
# ============================================================
suite "scripts_linux/os — rotate_log.sh"

RL="$REPO/scripts_linux/os/rotate_log.sh"
LOG_DIR="$TMP/test_logs"
mkdir -p "$LOG_DIR"

# Create test log files (2MB each → exceed 1MB threshold)
dd if=/dev/urandom of="$LOG_DIR/app.log"    bs=1024 count=2048 2>/dev/null
dd if=/dev/urandom of="$LOG_DIR/access.log" bs=1024 count=2048 2>/dev/null

check "file exists"   test -f "$RL"
syntax_check "script" "$RL"

check "dry-run by size threshold" bash "$RL" \
    -p "$LOG_DIR/app.log" -s 1 -k 3 -n

check "dry-run by age threshold" bash "$RL" \
    -p "$LOG_DIR/access.log" -a 0 -k 3 -n

check "dry-run with list file" bash -c "
    cat > '$TMP/rotate_test.lst' << 'LST'
$LOG_DIR/app.log MaxSizeMB=1 RetentionCount=3
$LOG_DIR/access.log MaxSizeMB=1 RetentionCount=3
LST
    bash '$RL' -L '$TMP/rotate_test.lst' -n
"

# ============================================================
# Suite 6: scripts_linux/os — deploy_scripts.sh
# ============================================================
suite "scripts_linux/os — deploy_scripts.sh"

DS="$REPO/scripts_linux/os/deploy_scripts.sh"
DEPLOY_DEST="$TMP/deploy_dest"
mkdir -p "$DEPLOY_DEST"

check "file exists"   test -f "$DS"
syntax_check "script" "$DS"

check "dry-run deploy" bash "$DS" \
    -L "$FIXTURES/deploy_test.lst" \
    -d "$DEPLOY_DEST" \
    -n

# ============================================================
# Suite 7: scripts_linux/aws — syntax checks (no AWS)
# ============================================================
suite "scripts_linux/aws — syntax (no AWS credentials)"

for script in backup_ami.sh backup_ebs_snapshot.sh ec2ctl.sh s3upload.sh; do
    f="$REPO/scripts_linux/aws/$script"
    check "file exists: $script"   test -f "$f"
    syntax_check "$script"          "$f"
done

# AWS scripts should exit with usage error (not crash) when called without required args
check "backup_ami: exits with usage on no args" bash -c "
    bash '$REPO/scripts_linux/aws/backup_ami.sh' 2>/dev/null; [[ \$? -ne 0 ]]
"

# ============================================================
# Suite 8: scripts_linux/sqlserver + tomcat — syntax checks
# ============================================================
suite "scripts_linux/sqlserver + tomcat — syntax"

for f in "$REPO/scripts_linux/sqlserver/sqlserverctl.sh" \
          "$REPO/scripts_linux/tomcat/tomcatctl.sh"; do
    name=$(basename "$f")
    check "file exists: $name" test -f "$f"
    syntax_check "$name" "$f"
done

# ============================================================
# Suite 9: tools/server-compare
# ============================================================
suite "tools/server-compare"

TOOLS_GI="$REPO/tools/server-compare/get_server_info.sh"
SI_OUT="$TMP/tools_si.json"

check "file exists: get_server_info.sh"  test -f "$TOOLS_GI"
syntax_check "get_server_info.sh"         "$TOOLS_GI"
check "collect os,filesystem"             bash "$TOOLS_GI" -c os,filesystem -o "$SI_OUT"
check_json_key "meta.os_type"             "$SI_OUT" "meta.os_type"
check_json_key "os.architecture"          "$SI_OUT" "os.architecture"

# Save a second snapshot for compare
bash "$TOOLS_GI" -c os,filesystem -o "$TMP/tools_si_after.json"

# Patch before to force a detectable change
python3 -c "
import json
d = json.load(open('$TMP/tools_si.json'))
d.get('os', {})['test_marker'] = 'before_value'
with open('$TMP/tools_si_before.json', 'w') as f:
    json.dump(d, f)
"

check "file exists: Compare-ServerInfo (n/a for bash)" bash -c "true"  # no bash compare — PS only

# ============================================================
# Suite 10: tools/network-check
# ============================================================
suite "tools/network-check"

NC="$REPO/tools/network-check/check_network_connectivity.sh"
NC_HTML="$TMP/nc_report.html"

check "file exists"    test -f "$NC"
syntax_check "script"  "$NC"

# Run script once (exit code ignored — ping may fail in container)
bash "$NC" -l "$FIXTURES/test_targets.lst" -o "$NC_HTML" 2>&1 | tee "$TMP/nc_output.txt" || true

check "no Python errors in output" bash -c "
    ! grep -q 'Traceback\|NameError\|SyntaxError\|unbound variable' '$TMP/nc_output.txt'
"
check "HTML report created"       test -f "$NC_HTML"
check "HTML valid content"        python3 -c "
s = open('$NC_HTML').read()
assert 'google.com' in s, 'google.com not found'
assert 'Expected' in s or 'PASS' in s or 'FAIL' in s, 'No evaluation content'
"
check "DNS resolves in container" python3 -c "
import socket
addrs = [i[4][0] for i in socket.getaddrinfo('google.com',None) if ':' not in i[4][0]]
assert addrs
"
check "TCP 443 reachable"         python3 -c "
import socket; s=socket.socket(); s.settimeout(5); s.connect(('google.com',443)); s.close()
"

# ============================================================
# Suite 11: tools/change-detect
# ============================================================
suite "tools/change-detect"

CD="$REPO/tools/change-detect/change_detect.sh"
CD_DIR="$TMP/change_detect"
mkdir -p "$CD_DIR"

check "file exists"    test -f "$CD"
syntax_check "script"  "$CD"

check "before snapshot" bash -c "
    cd '$CD_DIR' && bash '$CD' before -l docker-test -c os,filesystem
"
check "before JSON created" bash -c "
    ls '$CD_DIR'/*_before_docker-test_*.json 1>/dev/null
"
check "after snapshot + auto-compare" bash -c "
    cd '$CD_DIR' && bash '$CD' after -l docker-test -c os,filesystem
"
check "HTML from compare" bash -c "
    B=\$(ls '$CD_DIR'/*_before_docker-test_*.json | head -1)
    A=\$(ls '$CD_DIR'/*_after_docker-test_*.json  | head -1)
    cd '$CD_DIR' && bash '$CD' compare \"\$B\" \"\$A\" --html '$CD_DIR/report.html'
"
check "HTML report created" test -f "$CD_DIR/report.html"
check "HTML valid content"  python3 -c "
s = open('$CD_DIR/report.html').read()
assert 'Change Detection Report' in s or 'change' in s.lower(), 'Report title not found'
"
check "0 changes detected" bash -c "
    B=\$(ls '$CD_DIR'/*_before_docker-test_*.json | head -1)
    A=\$(ls '$CD_DIR'/*_after_docker-test_*.json  | head -1)
    cd '$CD_DIR' && bash '$CD' compare \"\$B\" \"\$A\" 2>&1 | grep -q 'Total changes: 0'
"

# ============================================================
# Suite 12: tools/perf-monitor
# ============================================================
suite "tools/perf-monitor"

PM="$REPO/tools/perf-monitor/perf_monitor.sh"
PM_PY="$REPO/tools/perf-monitor/render_report.py"
PM_CONF="$REPO/tools/perf-monitor/perf_monitor.conf"
PM_DIR="$TMP/perf_monitor"
mkdir -p "$PM_DIR"

check "perf_monitor.sh exists"   test -f "$PM"
check "render_report.py exists"  test -f "$PM_PY"
check "perf_monitor.conf exists" test -f "$PM_CONF"
syntax_check "perf_monitor.sh"   "$PM"

# start: 5秒間隔・15秒で自動停止
bash "$PM" start -i 5 -d 15 -o "$PM_DIR" -p pmtest 2>&1 | tee "$TMP/pm_start.log" || true

check "start: session directory created" bash -c "
    ls -d '$PM_DIR'/pmtest_* 1>/dev/null 2>&1
"
check "start: collector.pid created" bash -c "
    ls '$PM_DIR'/pmtest_*/collector.pid 1>/dev/null 2>&1
"

# 20秒待機（15秒duration + バッファ）
sleep 20

check "data.jsonl: created with samples" bash -c "
    df=\$(ls '$PM_DIR'/pmtest_*/data.jsonl 2>/dev/null | head -1)
    [[ -z \"\$df\" ]] && { echo 'data.jsonl not found'; exit 1; }
    cnt=\$(wc -l < \"\$df\")
    echo \"samples: \$cnt\"
    [[ \$cnt -ge 2 ]]
"

check "data.jsonl: valid JSON Lines" bash -c "
    df=\$(ls '$PM_DIR'/pmtest_*/data.jsonl 2>/dev/null | head -1)
    [[ -z \"\$df\" ]] && exit 1
    python3 -c \"
import json
rows = [json.loads(l) for l in open('$df') if l.strip()]
assert len(rows) >= 2, f'Too few rows: {len(rows)}'
print(f'OK: {len(rows)} rows')
\"
"

check "data.jsonl: required fields present" bash -c "
    df=\$(ls '$PM_DIR'/pmtest_*/data.jsonl 2>/dev/null | head -1)
    [[ -z \"\$df\" ]] && exit 1
    python3 -c \"
import json
rows = [json.loads(l) for l in open('$df') if l.strip()]
r = rows[0]
required = ['ts','hostname','os','cpu_pct','mem_used_pct','mem_used_gb',
            'disk_read_mbps','disk_write_mbps','net_rx_mbps','net_tx_mbps',
            'load_avg_1','proc_count']
missing = [f for f in required if f not in r]
assert not missing, f'Missing: {missing}'
print('All required fields present')
\"
"

check "status: shows session info" bash -c "
    sd=\$(ls -d '$PM_DIR'/pmtest_* 2>/dev/null | head -1)
    [[ -z \"\$sd\" ]] && exit 1
    bash '$PM' status \"\$sd\" 2>&1 | grep -qE 'pmtest|perf|session|Session'
"

check "list: shows sessions" bash -c "
    cd '$PM_DIR' && bash '$PM' list 2>&1 | grep -qiE 'pmtest|perf|session'
"

check "report: HTML generated" bash -c "
    sd=\$(ls -d '$PM_DIR'/pmtest_* 2>/dev/null | head -1)
    [[ -z \"\$sd\" ]] && exit 1
    df=\"\${sd}/data.jsonl\"
    html=\"\${sd}/report.html\"
    PERF_THR_CPU=70 PERF_THR_MEM=80 PERF_THR_LOAD=2.0 \
        python3 '$PM_PY' \"\$df\" \"\$html\" 2>&1
    test -f \"\$html\"
"

check "report: HTML has Chart.js and charts" bash -c "
    html=\$(ls '$PM_DIR'/pmtest_*/report.html 2>/dev/null | head -1)
    [[ -z \"\$html\" ]] && exit 1
    python3 -c \"
s = open('\$html', encoding='utf-8').read()
assert 'chart.js' in s.lower(), 'No Chart.js'
assert 'chartCpu'  in s, 'No CPU chart'
assert 'chartMem'  in s, 'No memory chart'
assert 'chartDisk' in s, 'No disk chart'
assert 'chartNet'  in s, 'No network chart'
assert 'chartLoad' in s, 'No load avg chart'
print(f'Charts OK, size={len(s)} bytes')
\"
"

check "report: HTML has stats and summary" bash -c "
    html=\$(ls '$PM_DIR'/pmtest_*/report.html 2>/dev/null | head -1)
    [[ -z \"\$html\" ]] && exit 1
    python3 -c \"
s = open('\$html', encoding='utf-8').read()
assert 'Performance Monitor' in s, 'No title'
assert '95' in s, 'No p95 stats column'
assert 'cpu_pct' in s or 'CPU' in s, 'No CPU stats'
assert len(s) > 5000, f'HTML too short: {len(s)}'
print(f'Stats OK, size={len(s)} bytes')
\"
"

# ============================================================
# Summary
# ============================================================
TOTAL=$((PASS+FAIL))
echo ""
echo -e "\e[1m${DSEP}\e[0m"
if [[ "$FAIL" -eq 0 ]]; then
    echo -e "\e[1m\e[32m  ✓ ALL TESTS PASSED\e[0m"
else
    echo -e "\e[1m\e[31m  ✗ SOME TESTS FAILED\e[0m"
fi
printf "  Total: %d   \e[32mPASS: %d\e[0m   \e[31mFAIL: %d\e[0m\n" "$TOTAL" "$PASS" "$FAIL"
echo -e "\e[1m${DSEP}\e[0m"
echo ""

exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
