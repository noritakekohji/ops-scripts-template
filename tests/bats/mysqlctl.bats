#!/usr/bin/env bats
load test_helper
load systemd_ctl_helpers

CTL="${SCRIPTS_DIR}/mysql/mysqlctl.sh"
SVC="mysql"

setup()    { setup_mock_bin; }
teardown() { teardown_mock_bin; }

@test "mysqlctl: usage"             { ctl_assert_usage              "$CTL"; }
@test "mysqlctl: invalid action"    { ctl_assert_invalid_action     "$CTL" "$SVC"; }
@test "mysqlctl: missing service"   { ctl_assert_missing_service    "$CTL"; }
@test "mysqlctl: no systemctl"      { ctl_assert_no_systemctl       "$CTL" "$SVC"; }
@test "mysqlctl: service not found" { ctl_assert_service_not_found  "$CTL"; }
@test "mysqlctl: idempotent start"  { ctl_assert_idempotent_start   "$CTL" "$SVC"; }
@test "mysqlctl: idempotent stop"   { ctl_assert_idempotent_stop    "$CTL" "$SVC"; }
@test "mysqlctl: restart always runs"  { ctl_assert_restart_always_runs "$CTL" "$SVC"; }
@test "mysqlctl: status readonly"   { ctl_assert_status_readonly    "$CTL" "$SVC"; }
@test "mysqlctl: -w uses timeout"   { ctl_assert_wait_uses_timeout  "$CTL" "$SVC"; }
