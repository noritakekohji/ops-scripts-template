#!/usr/bin/env bats

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO_ROOT/scripts_linux/os/service_wait.sh"
    FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/service_wait"
    export OPS_LIB="$REPO_ROOT/scripts_linux/lib"
    export OPS_CONFIG_DIR="$REPO_ROOT/config"
    export TZ=Asia/Tokyo
}

@test "rejects missing target list argument" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "rejects non-existent list file" {
    run bash "$SCRIPT" /does/not/exist.lst
    [ "$status" -eq 2 ]
}

@test "rejects list with unknown type" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
foo, 127.0.0.1, bad type
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    rm -f "$tmp"
}

@test "rejects list with unknown override key" {
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
ping, 127.0.0.1, ok, success_threshold=99
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    rm -f "$tmp"
}

@test "parses sample.lst and reports start (timeout 1s)" {
    # Force quick failure so test does not hang.
    export OPS_OVERRIDE_TIMEOUT_SEC=1
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    run bash "$SCRIPT" "$FIXTURE_DIR/sample.lst"
    # 3 = timeout (expected since http://127.0.0.1/health is not up here)
    [ "$status" -eq 3 ]
    [[ "$output" == *"start targets=3"* ]]
}
