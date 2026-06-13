#!/usr/bin/env bats
# cert_check.sh unit tests

load test_helper

CTL="${TOOLS_DIR}/cert-check/cert_check.sh"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

# Helper: create a minimal target list fixture in $WORK
create_target_list() {
    cat > "$WORK/cert_targets.lst" <<'EOF'
google.com, 443, 30, Google HTTPS
EOF
}

# Helper: check if network + openssl are available
can_run_network_tests() {
    command -v openssl &>/dev/null || return 1
    # Quick DNS check to verify network connectivity
    timeout 3 openssl s_client -connect google.com:443 </dev/null &>/dev/null || return 1
    return 0
}

# ── Test 1: No arguments → exit 1 (usage) ────────────────────────────────

@test "cert_check: no arguments exits with 1 (usage)" {
    run bash "$CTL"
    [ "$status" -eq 1 ]
}

# ── Test 2: Target list not found → exit 2 ───────────────────────────────

@test "cert_check: nonexistent target list exits with 2" {
    run bash "$CTL" -t "$WORK/nonexistent.lst"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "Target list not found" ]]
}

# ── Test 3: Valid target list → exit 0, output contains host info ────────

@test "cert_check: valid target list with real host exits 0" {
    if ! can_run_network_tests; then skip "network or openssl unavailable"; fi
    create_target_list
    run bash "$CTL" -t "$WORK/cert_targets.lst"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "google.com" ]]
}

# ── Test 4: --json flag → output is valid JSON ──────────────────────────

@test "cert_check: --json produces valid JSON" {
    if ! can_run_network_tests; then skip "network or openssl unavailable"; fi
    create_target_list
    run bash "$CTL" -t "$WORK/cert_targets.lst" --json
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

# ── Test 5: --html flag → HTML file is generated ────────────────────────

@test "cert_check: --html generates an HTML report file" {
    if ! can_run_network_tests; then skip "network or openssl unavailable"; fi
    create_target_list
    local html="$WORK/report.html"
    run bash "$CTL" -t "$WORK/cert_targets.lst" --html "$html"
    [ "$status" -eq 0 ]
    [ -f "$html" ]
    [[ "$(cat "$html")" =~ "TLS Certificate Check Report" ]]
}

# ── Test 6: --fail-only with all-OK targets → no data rows ──────────────

@test "cert_check: --fail-only hides OK entries" {
    if ! can_run_network_tests; then skip "network or openssl unavailable"; fi
    create_target_list
    run bash "$CTL" -t "$WORK/cert_targets.lst" --fail-only
    [ "$status" -eq 0 ]
    # Output should have the header line but no google.com data row
    [[ "$output" =~ "HOST" ]]
    [[ ! "$output" =~ "google.com" ]]
}
