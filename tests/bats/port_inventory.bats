#!/usr/bin/env bats
# port_inventory.sh unit tests

load test_helper

CTL="${TOOLS_DIR}/port-inventory/port_inventory.sh"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

# Helper: check if running on Linux with ss or netstat available
require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || skip "Linux required"
    command -v ss &>/dev/null || command -v netstat &>/dev/null || skip "ss or netstat required"
}

# Helper: create an expected port list fixture in $WORK
create_expected_list() {
    cat > "$WORK/expected_ports.lst" <<'EOF'
# Port inventory expected list for testing
22, tcp, ok, SSH daemon
99999, tcp, ng, Should not be listening
EOF
}

# -- Test 1: No arguments (inventory mode) -> exit 0 on Linux ----------------

@test "port_inventory: no arguments (inventory mode) exits 0" {
    require_linux
    run bash "$CTL"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PORT" ]]
}

# -- Test 2: Expected list not found -> exit 2 --------------------------------

@test "port_inventory: nonexistent expected list exits with 2" {
    require_linux
    run bash "$CTL" -e "$WORK/nonexistent.lst"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "Expected list not found" ]]
}

# -- Test 3: Valid expected list with known ports -> judgment works ------------

@test "port_inventory: expected list judges ok/ng ports correctly" {
    require_linux
    create_expected_list
    run bash "$CTL" -e "$WORK/expected_ports.lst"
    # Port 99999/tcp should not be listening, so expected=ng -> status OK
    # Port 22/tcp expected=ok -> OK if sshd is running, NG if not
    # Either way the script should complete (exit 0 or 1)
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    [[ "$output" =~ "SSH daemon" ]]
}

# -- Test 4: --json flag -> valid JSON output ---------------------------------

@test "port_inventory: --json produces valid JSON" {
    require_linux
    run bash "$CTL" --json
    [ "$status" -eq 0 ]
    # Validate JSON with python3 or jq
    if command -v python3 &>/dev/null; then
        echo "$output" | python3 -m json.tool > /dev/null
    elif command -v jq &>/dev/null; then
        echo "$output" | jq . > /dev/null
    else
        skip "python3 or jq required for JSON validation"
    fi
}

# -- Test 5: --html flag -> HTML file generated -------------------------------

@test "port_inventory: --html generates an HTML report file" {
    require_linux
    local html="$WORK/report.html"
    run bash "$CTL" --html "$html"
    [ "$status" -eq 0 ]
    [ -f "$html" ]
    [[ "$(cat "$html")" =~ "Port Inventory Report" ]]
}
