#!/usr/bin/env bats
# Tests for lib/state_machine.bash — Agent lifecycle state transitions

setup() {
  unset _LIB_STATE_MACHINE_LOADED
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/state_machine.bash"
}

# ── Running path: agent done ──

@test "running + done + exit=0 + PR → pr-open" {
  run determine_next_status "running" "true" "0" "true" "1" "3" "100" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "pr-open" ]
}

@test "running + done + exit=0 + no PR → done-no-pr" {
  run determine_next_status "running" "true" "0" "false" "1" "3" "100" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "done-no-pr" ]
}

@test "running + done + exit!=0 + attempts<max → needs-respawn" {
  run determine_next_status "running" "true" "1" "false" "1" "3" "100" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "needs-respawn" ]
}

@test "running + done + exit!=0 + attempts>=max → exhausted" {
  run determine_next_status "running" "true" "1" "false" "3" "3" "100" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "exhausted" ]
}

# ── Running path: agent died ──

@test "running + agent dead → crashed" {
  run determine_next_status "running" "false" "0" "false" "1" "3" "100" "1800" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "crashed" ]
}

@test "running + agent dead + attempts>=max → exhausted" {
  run determine_next_status "running" "false" "0" "false" "3" "3" "100" "1800" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "exhausted" ]
}

# ── Running path: timeout ──

@test "running + timeout → timeout" {
  run determine_next_status "running" "false" "0" "false" "1" "3" "2000" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "timeout" ]
}

@test "running + timeout + attempts>=max → exhausted" {
  run determine_next_status "running" "false" "0" "false" "3" "3" "2000" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "exhausted" ]
}

# ── Running path: still alive ──

@test "running + still alive → running" {
  run determine_next_status "running" "false" "0" "false" "1" "3" "100" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

# ── PR-open path ──

@test "pr-open + MERGED → merged" {
  run determine_next_status "pr-open" "true" "0" "true" "1" "3" "500" "1800" "false" "" "" "" "MERGED"
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
}

@test "pr-open + CLOSED → closed" {
  run determine_next_status "pr-open" "true" "0" "true" "1" "3" "500" "1800" "false" "" "" "" "CLOSED"
  [ "$status" -eq 0 ]
  [ "$output" = "closed" ]
}

@test "pr-open + CI fail + attempts<max → ci-failed" {
  run determine_next_status "pr-open" "true" "0" "true" "1" "3" "500" "1800" "false" "false" "" "" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "ci-failed" ]
}

@test "pr-open + CI fail + attempts>=max → exhausted" {
  run determine_next_status "pr-open" "true" "0" "true" "3" "3" "500" "1800" "false" "false" "" "" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "exhausted" ]
}

@test "pr-open + changes_requested + attempts<max → review-failed" {
  run determine_next_status "pr-open" "true" "0" "true" "1" "3" "500" "1800" "false" "" "" "true" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "review-failed" ]
}

@test "pr-open + CI pass + reviews approved → ready" {
  run determine_next_status "pr-open" "true" "0" "true" "1" "3" "500" "1800" "false" "true" "true" "false" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
}

# ── Terminal states ──

@test "merged → merged (terminal, no transition)" {
  run determine_next_status "merged" "true" "0" "true" "1" "3" "500" "1800" "false" "true" "true" "false" "MERGED"
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
}

@test "exhausted → exhausted (terminal)" {
  run determine_next_status "exhausted" "true" "0" "true" "3" "3" "500" "1800" "false"
  [ "$status" -eq 0 ]
  [ "$output" = "exhausted" ]
}

# ── is_stale ──

@test "is_stale: elapsed>threshold + no PR → true (return 0)" {
  run is_stale "8000" "7200" "false"
  [ "$status" -eq 0 ]
}

@test "is_stale: elapsed<threshold → false (return 1)" {
  run is_stale "3000" "7200" "false"
  [ "$status" -eq 1 ]
}

@test "is_stale: elapsed>threshold + has PR → false (return 1)" {
  run is_stale "8000" "7200" "true"
  [ "$status" -eq 1 ]
}

# ── is_idle ──

@test "is_idle: elapsed>threshold + 0 changes → true (return 0)" {
  run is_idle "2000" "1800" "0"
  [ "$status" -eq 0 ]
}

@test "is_idle: has changes → false (return 1)" {
  run is_idle "2000" "1800" "5"
  [ "$status" -eq 1 ]
}

@test "is_idle: elapsed<threshold → false (return 1)" {
  run is_idle "100" "1800" "0"
  [ "$status" -eq 1 ]
}

# ── done-no-pr: note that the state machine itself doesn't distinguish ──
# ── empty completions — that logic lives in check.bash. The state ──
# ── machine still emits done-no-pr; check.bash inspects commit count. ──

@test "running + done + exit=0 + no PR still → done-no-pr in state machine" {
  # State machine is pure: it doesn't know about commits.
  # check.bash handles reclassification to 'failed' for zero-commit cases.
  run determine_next_status "running" "true" "0" "false" "1" "3" "100" "1800" "true"
  [ "$status" -eq 0 ]
  [ "$output" = "done-no-pr" ]
}

# ── deploy-failed: re-evaluates like pr-open (may self-heal) ──

@test "deploy-failed + CI passes + reviews approved → ready" {
  run determine_next_status "deploy-failed" "" "" "" "1" "3" "" "" "" "true" "true" "false" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
}

@test "deploy-failed + CI still failing → ci-failed (respawn)" {
  run determine_next_status "deploy-failed" "" "" "" "1" "3" "" "" "" "false" "" "" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "ci-failed" ]
}

@test "deploy-failed + PR merged → merged" {
  run determine_next_status "deploy-failed" "" "" "" "1" "3" "" "" "" "" "" "" "MERGED"
  [ "$status" -eq 0 ]
  [ "$output" = "merged" ]
}

@test "deploy-failed + no new info → stays deploy-failed" {
  run determine_next_status "deploy-failed" "" "" "" "1" "3" "" "" "" "" "" "" "OPEN"
  [ "$status" -eq 0 ]
  [ "$output" = "deploy-failed" ]
}
