#!/usr/bin/env bats
# log_collector.sh unit tests

load test_helper

CTL="${TOOLS_DIR}/log-collector/log_collector.sh"

setup()    { WORK=$(make_test_workdir); }
teardown() { rm -rf "$WORK"; }

# Helper: skip if not on Linux
require_linux() {
    [[ "$(uname -s)" == "Linux" ]] || skip "Linux only"
}

# Helper: skip if zip is not available
require_zip() {
    command -v zip &>/dev/null || skip "zip not available"
}

# Helper: skip if sha256sum/shasum is not available
require_sha256() {
    command -v sha256sum &>/dev/null || command -v shasum &>/dev/null || skip "sha256sum/shasum not available"
}

# Helper: create a config and log fixtures in $WORK
create_fixtures() {
    mkdir -p "$WORK/logs"
    echo "line1 of app.log" > "$WORK/logs/app.log"
    echo "line2 of error.log" > "$WORK/logs/error.log"
    # Ensure files have recent mtime (touch to now)
    touch "$WORK/logs/app.log" "$WORK/logs/error.log"

    cat > "$WORK/collect_targets.conf" <<EOF
[testapp]
path = $WORK/logs/*.log
max_file_size_mb = 10
EOF
}

# ── Test 1: No arguments → exit 1 (usage) ───────────────────────────────

@test "log_collector: no arguments exits with 1 (usage)" {
    require_linux
    run bash "$CTL"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "required" ]]
}

# ── Test 2: Config file not found → exit 1 ──────────────────────────────

@test "log_collector: nonexistent config file exits with 1" {
    require_linux
    run bash "$CTL" -t testapp -c "$WORK/nonexistent.conf"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Config file not found" ]]
}

# ── Test 3: Valid config + matching files → exit 0, zip created ─────────

@test "log_collector: valid config with matching files creates zip" {
    require_linux
    require_zip
    require_sha256
    create_fixtures

    run bash "$CTL" -t testapp -c "$WORK/collect_targets.conf" -o "$WORK" -s 24h
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Evidence Collection Complete" ]]

    # Verify a zip file was created in the output directory
    local zip_count
    zip_count=$(find "$WORK" -maxdepth 1 -name 'evidence_*.zip' -type f | wc -l)
    [ "$zip_count" -eq 1 ]
}

# ── Test 4: Unknown preset → exit 1 ─────────────────────────────────────

@test "log_collector: unknown preset exits with 1" {
    require_linux
    require_zip
    require_sha256
    create_fixtures

    run bash "$CTL" -t nosuchpreset -c "$WORK/collect_targets.conf"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Unknown preset" ]]
}

# ── Test 5: No files match time window → exit 2 ─────────────────────────

@test "log_collector: no files in time window exits with 2" {
    require_linux
    require_zip
    require_sha256
    create_fixtures

    # Set file mtime to 2 hours ago so that -s 1m excludes them
    touch -d '2 hours ago' "$WORK/logs/app.log" "$WORK/logs/error.log"

    run bash "$CTL" -t testapp -c "$WORK/collect_targets.conf" -o "$WORK" -s 1m
    [ "$status" -eq 2 ]
    [[ "$output" =~ "No files matched" ]]
}
