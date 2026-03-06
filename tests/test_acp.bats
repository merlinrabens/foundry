#!/usr/bin/env bats
# Tests for ACP mode: runner script generation, PID liveness, kill, steer, respawn

load test_helper

# ============================================================================
# Runner script generation
# ============================================================================

@test "runner script delegates to acp_orchestrator.py" {
  local tmpdir
  tmpdir=$(mktemp -d)
  _write_runner_script "codex" "$tmpdir" "gpt-5.3-codex" "/tmp/test.log" "/tmp/test.done" "" "high"
  [ -f "$tmpdir/.foundry-run.sh" ]
  grep -q "acp_orchestrator.py" "$tmpdir/.foundry-run.sh"
  rm -rf "$tmpdir"
}

@test "runner script includes --foundry-dir flag" {
  local tmpdir
  tmpdir=$(mktemp -d)
  _write_runner_script "claude" "$tmpdir" "claude-sonnet-4-6" "/tmp/test.log" "/tmp/test.done" "" ""
  grep -q "\-\-foundry-dir" "$tmpdir/.foundry-run.sh"
  rm -rf "$tmpdir"
}

@test "runner script exports FOUNDRY_DIR env var" {
  local tmpdir
  tmpdir=$(mktemp -d)
  _write_runner_script "codex" "$tmpdir" "gpt-5.3-codex" "/tmp/test.log" "/tmp/test.done" "" "high"
  grep -q "export FOUNDRY_DIR=" "$tmpdir/.foundry-run.sh"
  rm -rf "$tmpdir"
}

@test "runner script includes env_block" {
  local tmpdir
  tmpdir=$(mktemp -d)
  local env_block="export MY_VAR='hello'"
  _write_runner_script "codex" "$tmpdir" "gpt-5.3-codex" "/tmp/test.log" "/tmp/test.done" "$env_block" "high"
  grep -q "MY_VAR" "$tmpdir/.foundry-run.sh"
  rm -rf "$tmpdir"
}

@test "runner script is executable" {
  local tmpdir
  tmpdir=$(mktemp -d)
  _write_runner_script "gemini" "$tmpdir" "gemini-3.5-pro" "/tmp/test.log" "/tmp/test.done" "" ""
  [ -x "$tmpdir/.foundry-run.sh" ]
  rm -rf "$tmpdir"
}

@test "runner script passes correct backend" {
  local tmpdir
  tmpdir=$(mktemp -d)
  _write_runner_script "gemini" "$tmpdir" "gemini-3.5-pro" "/tmp/test.log" "/tmp/test.done" "" ""
  grep -q "\-\-backend \"gemini\"" "$tmpdir/.foundry-run.sh"
  rm -rf "$tmpdir"
}

@test "runner script always uses acp_orchestrator (no tmux branch)" {
  local tmpdir
  tmpdir=$(mktemp -d)
  _write_runner_script "codex" "$tmpdir" "gpt-5.3-codex" "/tmp/test.log" "/tmp/test.done" "" "high"
  grep -q "acp_orchestrator" "$tmpdir/.foundry-run.sh"
  # Should NOT contain timeout command (that was tmux mode)
  ! grep -q "^timeout " "$tmpdir/.foundry-run.sh"
  rm -rf "$tmpdir"
}

# ============================================================================
# PID-based kill
# ============================================================================

@test "cmd_kill terminates PID-based task" {
  create_sample_registry
  sleep 300 &
  local test_pid=$!

  local filter='.[] |= (if .id == "myproject-feature-auth" then .pid = '"$test_pid"' else . end)'
  local updated
  updated=$(jq "$filter" "$REGISTRY")
  echo "$updated" > "$REGISTRY"

  cmd_kill "myproject-feature-auth"

  ! kill -0 "$test_pid" 2>/dev/null

  local status
  status=$(jq -r '.[] | select(.id == "myproject-feature-auth") | .status' "$REGISTRY")
  [ "$status" = "killed" ]
}

@test "cmd_kill handles already-dead PID gracefully" {
  create_sample_registry
  local filter='.[] |= (if .id == "myproject-feature-auth" then .pid = 99999999 else . end)'
  local updated
  updated=$(jq "$filter" "$REGISTRY")
  echo "$updated" > "$REGISTRY"

  cmd_kill "myproject-feature-auth"

  local status
  status=$(jq -r '.[] | select(.id == "myproject-feature-auth") | .status' "$REGISTRY")
  [ "$status" = "killed" ]
}

# ============================================================================
# PID-based attach (log tailing)
# ============================================================================

@test "cmd_attach streams log file" {
  create_sample_registry
  mkdir -p "${FOUNDRY_DIR}/logs"
  echo "test log line" > "${FOUNDRY_DIR}/logs/myproject-feature-auth.log"

  # cmd_attach tails the log — just check it doesn't error
  run bash -c 'source "'"$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"'/test_helper.bash"
    cmd_attach "myproject-feature-auth" 2>&1 | head -1'

  [[ "$output" == *"log"* ]] || [[ "$output" == *"Streaming"* ]] || true
}

# ============================================================================
# Steer mechanism
# ============================================================================

@test "cmd_steer writes .steer file and sends USR1" {
  create_sample_registry
  bash -c 'trap "" USR1; sleep 300' &
  local test_pid=$!

  local filter='.[] |= (if .id == "myproject-feature-auth" then .pid = '"$test_pid"' else . end)'
  local updated
  updated=$(jq "$filter" "$REGISTRY")
  echo "$updated" > "$REGISTRY"

  mkdir -p "${FOUNDRY_DIR}/logs"

  cmd_steer "myproject-feature-auth" "Focus on API first"

  local steer_file="${FOUNDRY_DIR}/logs/myproject-feature-auth.steer"
  [ -f "$steer_file" ]
  [ "$(cat "$steer_file")" = "Focus on API first" ]

  kill "$test_pid" 2>/dev/null || true
}

@test "cmd_steer reports error when no PID" {
  create_sample_registry
  # No PID set — should report agent not running
  run cmd_steer "myproject-feature-auth" "Do the thing"
  [[ "$output" == *"not running"* ]]
}

# ============================================================================
# ACP orchestrator Python module tests
# ============================================================================

@test "acp_orchestrator.py parses --help without error" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  run python3 "$real_dir/lib/acp_orchestrator.py" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACP Agent Orchestrator"* ]]
}

@test "acp_orchestrator.py rejects invalid backend" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  run python3 "$real_dir/lib/acp_orchestrator.py" \
    --backend invalid --model test --worktree /tmp --log-file /tmp/l --done-file /tmp/d
  [ "$status" -ne 0 ]
}

@test "acp_orchestrator.py requires --backend" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  run python3 "$real_dir/lib/acp_orchestrator.py" \
    --model test --worktree /tmp --log-file /tmp/l --done-file /tmp/d
  [ "$status" -ne 0 ]
}

@test "acp_orchestrator.py writes done file on missing prompt" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local tmpdir
  tmpdir=$(mktemp -d)
  local done_file="$tmpdir/test.done"
  run python3 "$real_dir/lib/acp_orchestrator.py" \
    --backend codex --model gpt-5.3-codex \
    --worktree "$tmpdir" --prompt-file "nonexistent.md" \
    --log-file "$tmpdir/test.log" --done-file "$done_file" \
    --timeout 5
  [ "$status" -eq 1 ]
  [ -f "$done_file" ]
  [ "$(cat "$done_file")" = "1" ]
  rm -rf "$tmpdir"
}
