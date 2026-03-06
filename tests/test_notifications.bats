#!/usr/bin/env bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/notifications.bash"
}

# ─── should_notify ────────────────────────────────────────────────────

@test "should_notify: different states returns 0 (should notify)" {
  run should_notify "merged" "running"
  [ "$status" -eq 0 ]
}

@test "should_notify: same state returns 1 (skip)" {
  run should_notify "running" "running"
  [ "$status" -eq 1 ]
}

@test "should_notify: empty last state returns 0 (first notification)" {
  run should_notify "running" ""
  [ "$status" -eq 0 ]
}

@test "should_notify: both empty returns 1 (skip)" {
  run should_notify "" ""
  [ "$status" -eq 1 ]
}

# ─── build_checks_summary ────────────────────────────────────────────

@test "build_checks_summary: all true gives CRKG" {
  run build_checks_summary "true" "true" "true" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "CRKG" ]
}

@test "build_checks_summary: only CI gives C" {
  run build_checks_summary "true" "false" "false" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "C" ]
}

@test "build_checks_summary: none gives empty" {
  run build_checks_summary "false" "false" "false" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "build_checks_summary: claude + codex gives CRK" {
  run build_checks_summary "true" "true" "true" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "CRK" ]
}
