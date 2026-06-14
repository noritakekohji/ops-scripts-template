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

@test "tcp check succeeds against bash's own bound port" {
    # Listen on an ephemeral port using nc.
    port=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
    nc -l 127.0.0.1 "$port" >/dev/null 2>&1 &
    nc_pid=$!
    sleep 0.2
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
tcp, 127.0.0.1:${port}, listener
EOF
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    export OPS_OVERRIDE_TIMEOUT_SEC=5
    export OPS_OVERRIDE_SUCCESS_THRESHOLD=1
    run bash "$SCRIPT" "$tmp"
    kill "$nc_pid" 2>/dev/null || true
    [ "$status" -eq 0 ]
}

@test "tcp check fails on closed port and times out" {
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
tcp, 127.0.0.1:1, closed
EOF
    export OPS_OVERRIDE_INITIAL_WAIT_SEC=0
    export OPS_OVERRIDE_INTERVAL_SEC=1
    export OPS_OVERRIDE_TIMEOUT_SEC=2
    export OPS_OVERRIDE_SUCCESS_THRESHOLD=1
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 3 ]
}

# ---------- v2: .lst header tests ----------

@test "lst header timeout_sec=1 makes the script time out without env override" {
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
initial_wait_sec = 0
interval_sec     = 1
timeout_sec      = 1

tcp, 127.0.0.1:1, closed
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 3 ]
}

@test "lst header with unknown key exits 2" {
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
no_such_setting = 99
tcp, 127.0.0.1:1, closed
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown_header_key"* ]]
}

@test "lst header with non-integer value exits 2" {
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
timeout_sec = abc
tcp, 127.0.0.1:1, closed
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    [[ "$output" == *"bad_header_value"* ]]
}

@test "key=value line appearing after targets is rejected" {
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
tcp, 127.0.0.1:1, closed
interval_sec = 5
EOF
    run bash "$SCRIPT" "$tmp"
    [ "$status" -eq 2 ]
    [[ "$output" == *"header_after_targets"* ]]
}

@test "monitoring keys lingering in conf produce a WARN and are ignored" {
    # OPS_CONFIG_DIR points directly at the dir containing service_wait.conf
    # (not at a tree with default/ subdir; see load_ops_config in lib/config.sh).
    work=$(mktemp -d)
    cat > "$work/service_wait.conf" <<EOF
interval_sec = 999
timeout_sec  = 999
LogLevel     = INFO
EOF
    tmp=$(new_tmp)
    cat > "$tmp" <<EOF
timeout_sec = 1

tcp, 127.0.0.1:1, closed
EOF
    OPS_CONFIG_DIR="$work" run bash "$SCRIPT" "$tmp"
    rm -rf "$work"
    [ "$status" -eq 3 ]
    [[ "$output" == *"no longer used"* ]]
}
