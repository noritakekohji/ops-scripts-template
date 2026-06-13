#!/usr/bin/env bats

load test_helper

setup() {
    SCRIPT="$SCRIPTS_DIR/os/service_wait.sh"
    FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/service_wait"
    export OPS_LIB="$LIB_DIR"
    export OPS_CONFIG_DIR="$REPO_ROOT/config"
    export TZ=Asia/Tokyo
    TMPS=()
}

teardown() {
    for f in "${TMPS[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f"
    done
    unset OPS_OVERRIDE_TIMEOUT_SEC OPS_OVERRIDE_INITIAL_WAIT_SEC \
          OPS_OVERRIDE_INTERVAL_SEC OPS_OVERRIDE_SUCCESS_THRESHOLD
}

new_tmp() {
    local t
    t=$(mktemp)
    TMPS+=("$t")
    printf '%s' "$t"
}

@test "exit 1 when target list argument is missing" {
    run bash "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" =~ Usage|usage ]]
}

@test "exit 2 when list file does not exist" {
    run bash "$SCRIPT" /does/not/exist.lst
    [ "$status" -eq 2 ]
    [[ "$output" == *"not found"* ]]
}

@test "exit 2 when list contains unknown type" {
    tmp=$(new_tmp)
    printf 'foo, 127.0.0.1, bad type\n' > "$tmp"
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown_type"* ]]
}

@test "exit 2 when list contains unknown override key" {
    tmp=$(new_tmp)
    printf 'ping, 127.0.0.1, ok, success_threshold=99\n' > "$tmp"
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown_key"* ]]
}

@test "sample.lst is parsed and start line is logged (1s timeout)" {
    export OPS_OVERRIDE_TIMEOUT_SEC=1
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    run bash "$SCRIPT" "$FIXTURE_DIR/sample.lst"
    [ "$status" -eq 3 ]
    [[ "$output" == *"start targets=3"* ]]
}
