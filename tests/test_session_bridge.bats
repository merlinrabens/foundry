#!/usr/bin/env bats
# Tests for lib/session_bridge.bash — OpenClaw native session bridge

setup() {
  export FOUNDRY_DIR="$(mktemp -d)"
  export REGISTRY_DB="${FOUNDRY_DIR}/test-foundry.db"
  export USE_SQLITE_REGISTRY="true"
  export AGENT_TIMEOUT="30"

  # Unset source guards
  unset _LIB_SESSION_BRIDGE_LOADED
  unset _CORE_REGISTRY_SQLITE_LOADED
  unset _CORE_LOGGING_LOADED

  # Minimal logging stubs
  log() { echo "$*"; }
  log_ok() { echo "OK: $*"; }
  log_warn() { echo "WARN: $*"; }
  log_err() { echo "ERR: $*"; }
  tg_notify() { return 0; }
  export -f log log_ok log_warn log_err tg_notify

  # Create mock openclaw binary
  export OPENCLAW_BIN="${FOUNDRY_DIR}/mock-openclaw"
  mkdir -p "${FOUNDRY_DIR}/logs"

  source "$(dirname "$BATS_TEST_FILENAME")/../lib/session_bridge.bash"
}

teardown() {
  rm -rf "$FOUNDRY_DIR"
}

# ─── Helper: create mock openclaw ─────────────────────────────────────────

_create_mock_openclaw() {
  local behavior="$1"
  cat > "$OPENCLAW_BIN" << MOCK_EOF
#!/bin/bash
# Mock openclaw CLI for testing
case "$behavior" in
  spawn-ok)
    echo '{"sessionId":"ses_abc123","runId":"run_xyz","reply":"Task completed"}'
    exit 0
    ;;
  spawn-fail)
    echo '{"error":"agent not found"}' >&2
    exit 1
    ;;
  send-ok)
    echo '{"reply":"I am making progress on the task"}'
    exit 0
    ;;
  send-fail)
    exit 1
    ;;
  status-list-active)
    echo '{"sessions":[{"sessionId":"ses_abc123","updatedAt":1773600000,"totalTokens":5000,"model":"codex"}]}'
    exit 0
    ;;
  status-list-empty)
    echo '{"sessions":[]}'
    exit 0
    ;;
  cancel-ok)
    exit 0
    ;;
esac
MOCK_EOF
  chmod +x "$OPENCLAW_BIN"
}

# Create a mock that inspects arguments
_create_arg_capture_mock() {
  cat > "$OPENCLAW_BIN" << 'MOCK_EOF'
#!/bin/bash
# Capture all args to a file for inspection
echo "$@" >> "${FOUNDRY_DIR}/mock-args.log"
echo '{"sessionId":"ses_test","runId":"run_test","reply":"ok"}'
exit 0
MOCK_EOF
  chmod +x "$OPENCLAW_BIN"
}

# ─── oc_spawn_bg tests ───────────────────────────────────────────────────

@test "oc_spawn_bg writes exit code to done file" {
  _create_mock_openclaw "spawn-ok"
  local log_file="${FOUNDRY_DIR}/logs/test.log"
  local done_file="${FOUNDRY_DIR}/logs/test.done"
  touch "$log_file"

  pid=$(oc_spawn_bg "ses_pre123" "codex" "test prompt" "$log_file" "${FOUNDRY_DIR}" 5)
  [ -n "$pid" ]

  wait "$pid" 2>/dev/null || true

  [ -f "$done_file" ]
  [ "$(cat "$done_file")" = "0" ]
}

@test "oc_spawn_bg passes session-id to openclaw agent" {
  _create_arg_capture_mock
  local log_file="${FOUNDRY_DIR}/logs/test.log"
  touch "$log_file"

  pid=$(oc_spawn_bg "ses_myid_456" "codex" "test prompt" "$log_file" "${FOUNDRY_DIR}" 5)
  wait "$pid" 2>/dev/null || true

  grep -q "ses_myid_456" "${FOUNDRY_DIR}/mock-args.log"
}

@test "oc_spawn_bg writes non-zero exit code on failure" {
  _create_mock_openclaw "spawn-fail"
  local log_file="${FOUNDRY_DIR}/logs/test.log"
  local done_file="${FOUNDRY_DIR}/logs/test.done"
  touch "$log_file"

  pid=$(oc_spawn_bg "ses_pre123" "codex" "test prompt" "$log_file" "${FOUNDRY_DIR}" 5)
  wait "$pid" 2>/dev/null || true

  [ -f "$done_file" ]
  [ "$(cat "$done_file")" != "0" ]
}

@test "oc_gen_session_id returns a UUID" {
  local sid
  sid=$(oc_gen_session_id)
  # UUID format: 8-4-4-4-12 hex chars
  [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# ─── oc_send tests ────────────────────────────────────────────────────────

@test "oc_send returns reply text" {
  _create_mock_openclaw "send-ok"
  result=$(oc_send "ses_abc123" "What's your progress?")
  [ "$result" = "I am making progress on the task" ]
}

@test "oc_send returns error on failure" {
  _create_mock_openclaw "send-fail"
  run oc_send "ses_abc123" "test"
  [ "$status" -eq 1 ]
  error=$(echo "$output" | jq -r '.error' 2>/dev/null)
  [ "$error" = "oc_send failed" ]
}

# ─── oc_status tests ─────────────────────────────────────────────────────

@test "oc_status returns alive=true for active session" {
  cat > "$OPENCLAW_BIN" << 'EOF'
#!/bin/bash
echo '{"sessions":[{"sessionId":"ses_abc123","updatedAt":1773600000,"totalTokens":5000,"model":"codex"}]}'
EOF
  chmod +x "$OPENCLAW_BIN"
  result=$(oc_status "ses_abc123")
  alive=$(echo "$result" | jq -r '.alive')
  [ "$alive" = "true" ]
}

@test "oc_status returns alive=false for completed session" {
  cat > "$OPENCLAW_BIN" << 'EOF'
#!/bin/bash
echo '{"sessions":[]}'
EOF
  chmod +x "$OPENCLAW_BIN"
  result=$(oc_status "ses_abc123")
  alive=$(echo "$result" | jq -r '.alive')
  [ "$alive" = "false" ]
}

# ─── oc_is_native tests ──────────────────────────────────────────────────

@test "oc_is_native returns true for task with sessionId" {
  local task='{"id":"test","sessionId":"ses_abc123"}'
  oc_is_native "$task"
}

@test "oc_is_native returns false for task without sessionId" {
  local task='{"id":"test","sessionId":null}'
  run oc_is_native "$task"
  [ "$status" -ne 0 ]
}

@test "oc_is_native returns false for legacy task" {
  local task='{"id":"test","pid":12345}'
  run oc_is_native "$task"
  [ "$status" -ne 0 ]
}
