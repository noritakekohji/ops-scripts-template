#!/usr/bin/env bats
load test_helper
load systemd_ctl_helpers

CTL="${SCRIPTS_DIR}/sqlserver/sqlserverctl.sh"
SVC="mssql-server"

setup()    { setup_mock_bin; }
teardown() { teardown_mock_bin; }

@test "sqlserverctl: usage"              { ctl_assert_usage             "$CTL"; }
@test "sqlserverctl: invalid action"     { ctl_assert_invalid_action    "$CTL" "$SVC"; }
@test "sqlserverctl: missing service"    { ctl_assert_missing_service   "$CTL"; }
@test "sqlserverctl: no systemctl"       { ctl_assert_no_systemctl      "$CTL" "$SVC"; }
@test "sqlserverctl: service not found"  { ctl_assert_service_not_found "$CTL"; }
@test "sqlserverctl: idempotent start"   { ctl_assert_idempotent_start  "$CTL" "$SVC"; }
@test "sqlserverctl: idempotent stop"    { ctl_assert_idempotent_stop   "$CTL" "$SVC"; }
@test "sqlserverctl: restart always runs" { ctl_assert_restart_always_runs "$CTL" "$SVC"; }
@test "sqlserverctl: status readonly"    { ctl_assert_status_readonly   "$CTL" "$SVC"; }
@test "sqlserverctl: -w uses timeout"    { ctl_assert_wait_uses_timeout "$CTL" "$SVC"; }
