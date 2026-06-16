#!/usr/bin/env bats
# collect_snapshot.sh unit tests
# Uses COLLECT_SNAPSHOT_TOOLS_DIR env var to inject mock tool scripts.
# MOCK_CALL_LOG env var tells mock scripts where to append call records.

load test_helper

CTL="${TOOLS_DIR}/collect-snapshot/collect_snapshot.sh"

# ── Mock tool setup helpers ────────────────────────────────────────────────────

# Create mock tool scripts under $MOCK_TOOLS_DIR.
# Each mock reads $MOCK_CALL_LOG from the environment at call time.
setup_mock_tools() {
    MOCK_TOOLS_DIR=$(mktemp -d)
    MOCK_CALL_LOG="${MOCK_TOOLS_DIR}/_calls.log"
    : > "$MOCK_CALL_LOG"
    export MOCK_TOOLS_DIR MOCK_CALL_LOG

    # server-snapshot mock: bash <script> collect -o <file>
    mkdir -p "${MOCK_TOOLS_DIR}/server-snapshot"
    cat > "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh" <<'MOCK'
#!/usr/bin/env bash
echo "server-snapshot: $*" >> "$MOCK_CALL_LOG"
out_file=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out_file="$a"
    prev="$a"
done
if [[ -n "$out_file" ]]; then
    printf '{"tool":"server-snapshot"}\n' > "$out_file"
fi
exit 0
MOCK
    chmod +x "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh"

    # port-inventory mock: bash <script> --json
    mkdir -p "${MOCK_TOOLS_DIR}/port-inventory"
    cat > "${MOCK_TOOLS_DIR}/port-inventory/port_inventory.sh" <<'MOCK'
#!/usr/bin/env bash
echo "port-inventory: $*" >> "$MOCK_CALL_LOG"
if [[ "$*" == *"--json"* ]]; then
    printf '[{"tool":"port-inventory"}]\n'
fi
exit 0
MOCK
    chmod +x "${MOCK_TOOLS_DIR}/port-inventory/port_inventory.sh"

    # aws-instance-audit mock: bash <script> -o <file>
    mkdir -p "${MOCK_TOOLS_DIR}/aws-instance-audit"
    cat > "${MOCK_TOOLS_DIR}/aws-instance-audit/aws_instance_audit.sh" <<'MOCK'
#!/usr/bin/env bash
echo "aws-instance-audit: $*" >> "$MOCK_CALL_LOG"
out_file=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out_file="$a"
    prev="$a"
done
if [[ -n "$out_file" ]]; then
    printf '{"tool":"aws-instance-audit"}\n' > "$out_file"
fi
exit 0
MOCK
    chmod +x "${MOCK_TOOLS_DIR}/aws-instance-audit/aws_instance_audit.sh"
}

teardown_mock_tools() {
    [[ -n "${MOCK_TOOLS_DIR:-}" && -d "$MOCK_TOOLS_DIR" ]] && rm -rf "$MOCK_TOOLS_DIR"
    unset MOCK_TOOLS_DIR MOCK_CALL_LOG
}

# ── Setup / Teardown ──────────────────────────────────────────────────────────

setup() {
    WORK=$(make_test_workdir)
    setup_mock_tools
}

teardown() {
    teardown_mock_tools
    rm -rf "$WORK"
}

# Helper: skip if neither zip nor tar is available
require_compress() {
    command -v zip &>/dev/null || command -v tar &>/dev/null || skip "zip or tar not available"
}

# ── Test 1: --label causes ZIP/tar name to contain the label ─────────────────

@test "collect_snapshot: --label pre-upgrade → archive name contains pre-upgrade" {
    require_compress
    local out_dir="$WORK/out"
    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
        bash "$CTL" --label pre-upgrade --output "$out_dir"
    [ "$status" -eq 0 ]
    local found
    found=$(find "$out_dir" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) 2>/dev/null | head -1)
    [ -n "$found" ]
    [[ "$found" == *pre-upgrade* ]]
}

# ── Test 2: No label → exactly 1 archive generated, name has no label token ──

@test "collect_snapshot: no --label → 1 archive generated, name has no label" {
    require_compress
    local out_dir="$WORK/out"
    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
        bash "$CTL" --output "$out_dir"
    [ "$status" -eq 0 ]
    local count
    count=$(find "$out_dir" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
    # Name format without label: <hostname>_<YYYYMMDD-HHMMSS>.zip/.tar.gz
    # Exactly 2 underscore-delimited segments (basename without extension)
    local archive_name
    archive_name=$(find "$out_dir" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) 2>/dev/null | head -1 | xargs basename)
    # Strip extension(s)
    local stem="${archive_name%.tar.gz}"
    stem="${stem%.zip}"
    local seg_count
    seg_count=$(echo "$stem" | tr '_' '\n' | wc -l)
    [ "$seg_count" -eq 2 ]
}

# ── Test 3: No --output → defaults to ./snapshots/ ───────────────────────────

@test "collect_snapshot: no --output → saved in ./snapshots/" {
    require_compress
    local wrapper="${WORK}/run_from_work.sh"
    printf '#!/usr/bin/env bash\ncd "%s" && exec bash "%s" "$@"\n' "$WORK" "$CTL" > "$wrapper"
    chmod +x "$wrapper"
    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
            MOCK_CALL_LOG="$MOCK_CALL_LOG" \
            bash "$wrapper"
    [ "$status" -eq 0 ]
    [ -d "$WORK/snapshots" ]
    local count
    count=$(find "$WORK/snapshots" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
}

# ── Test 4: --output changes the save directory ──────────────────────────────

@test "collect_snapshot: --output changes output directory" {
    require_compress
    local out_dir="$WORK/custom-out"
    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
        bash "$CTL" --output "$out_dir"
    [ "$status" -eq 0 ]
    [ -d "$out_dir" ]
    local count
    count=$(find "$out_dir" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
}

# ── Test 5: 1 tool fails → others run, exit 1, archive still generated ───────

@test "collect_snapshot: 1 tool failure → remaining tools run, exit 1, archive generated" {
    require_compress
    # Override server-snapshot mock to fail
    cat > "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh" <<'MOCK'
#!/usr/bin/env bash
echo "server-snapshot: $*" >> "$MOCK_CALL_LOG"
exit 1
MOCK
    chmod +x "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh"

    local out_dir="$WORK/out"
    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
        bash "$CTL" --output "$out_dir"
    [ "$status" -eq 1 ]
    # Other tools should still have been called
    grep -q "port-inventory" "$MOCK_CALL_LOG"
    grep -q "aws-instance-audit" "$MOCK_CALL_LOG"
    # Archive should still be generated
    local count
    count=$(find "$out_dir" -maxdepth 1 \( -name "*.zip" -o -name "*.tar.gz" \) 2>/dev/null | wc -l)
    [ "$count" -eq 1 ]
}

# ── Test 6: Tool script not found → continue, exit 1 ────────────────────────

@test "collect_snapshot: missing tool script → continues, exits 1" {
    require_compress
    # Remove server-snapshot mock script
    rm -f "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh"

    local out_dir="$WORK/out"
    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
        bash "$CTL" --output "$out_dir"
    [ "$status" -eq 1 ]
    # Remaining tools should still have run
    grep -q "port-inventory" "$MOCK_CALL_LOG"
    grep -q "aws-instance-audit" "$MOCK_CALL_LOG"
}

# ── Test 6b: All tools fail → ZIP generated + exit 1 ─────────────────────────

@test "collect_snapshot: all tools fail → ZIP generated, exit 1" {
    require_compress
    # Make all 3 mock tools fail
    mkdir -p "${MOCK_TOOLS_DIR}/server-snapshot" \
             "${MOCK_TOOLS_DIR}/port-inventory" \
             "${MOCK_TOOLS_DIR}/aws-instance-audit"
    printf '#!/usr/bin/env bash\necho "server-snapshot mock: forced fail" >&2\nexit 1\n' \
        > "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh"
    chmod +x "${MOCK_TOOLS_DIR}/server-snapshot/server_snapshot.sh"
    printf '#!/usr/bin/env bash\necho "port-inventory mock: forced fail" >&2\nexit 1\n' \
        > "${MOCK_TOOLS_DIR}/port-inventory/port_inventory.sh"
    chmod +x "${MOCK_TOOLS_DIR}/port-inventory/port_inventory.sh"
    printf '#!/usr/bin/env bash\necho "aws-instance-audit mock: forced fail" >&2\nexit 1\n' \
        > "${MOCK_TOOLS_DIR}/aws-instance-audit/aws_instance_audit.sh"
    chmod +x "${MOCK_TOOLS_DIR}/aws-instance-audit/aws_instance_audit.sh"

    run env COLLECT_SNAPSHOT_TOOLS_DIR="$MOCK_TOOLS_DIR" \
        bash "$CTL" --output "$WORK/out"
    [ "$status" -eq 1 ]
    # ZIP (or tar.gz) must still be generated
    local count
    count=$(find "$WORK/out" \( -name "*.zip" -o -name "*.tar.gz" \) | wc -l)
    [ "$count" -ge 1 ]
}

# ── Test 7: --menu flag accepted (TUI reads defaults and exits 0) ─────────────

@test "collect_snapshot: --menu flag accepted, TUI reads defaults and exits 0" {
    require_compress
    local out_dir="$WORK/menu-out"
    # Supply 3 empty Enter presses for each read prompt in do_menu (label, dir, tools)
    run bash -c "
        printf '\n\n\n' | \
        COLLECT_SNAPSHOT_TOOLS_DIR='$MOCK_TOOLS_DIR' \
        MOCK_CALL_LOG='$MOCK_CALL_LOG' \
        bash '$CTL' --menu --output '$out_dir'
    "
    [ "$status" -eq 0 ]
    # Verify tools were invoked
    grep -q "server-snapshot" "$MOCK_CALL_LOG"
    grep -q "port-inventory" "$MOCK_CALL_LOG"
    grep -q "aws-instance-audit" "$MOCK_CALL_LOG"
    # Verify archive was created
    local count
    count=$(find "$out_dir" \( -name "*.zip" -o -name "*.tar.gz" \) | wc -l)
    [ "$count" -ge 1 ]
}
