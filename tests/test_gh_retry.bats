#!/usr/bin/env bats
# Tests for gh_retry wrapper and tg_notify edge cases

load test_helper

# ============================================================================
# gh_retry() — retry logic with exponential backoff
# ============================================================================

@test "gh_retry: succeeds on first try" {
  # Mock: a command that always succeeds
  result=$(gh_retry echo "hello world")
  [ "$result" = "hello world" ]
}

@test "gh_retry: returns stdout on success" {
  result=$(gh_retry echo '{"state":"MERGED"}')
  [ "$result" = '{"state":"MERGED"}' ]
}

@test "gh_retry: returns failure after 3 attempts" {
  # Mock: a command that always fails
  run gh_retry false
  [ "$status" -ne 0 ]
}

@test "gh_retry: captures multiline output" {
  result=$(gh_retry printf "line1\nline2\nline3")
  echo "$result" | grep -q "line1"
  echo "$result" | grep -q "line3"
}

# ============================================================================
# tg_notify() — Telegram notification (with no token = graceful skip)
# ============================================================================

@test "tg_notify: gracefully skips when no bot token" {
  export OPENCLAW_TG_BOT_TOKEN=""
  # Mock python3 to return empty (no token found)
  python3() { echo ""; }
  export -f python3
  run tg_notify "test message"
  # Should return 0 (graceful skip) — the function logs a warning but doesn't fail
  [ "$status" -eq 0 ]
  unset -f python3
}
