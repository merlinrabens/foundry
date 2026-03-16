#!/usr/bin/env bats
# Tests for registry_cas_status — atomic compare-and-swap on task status

setup() {
  export FOUNDRY_DIR="$(mktemp -d)"
  export REGISTRY="${FOUNDRY_DIR}/active-tasks.json"
  export REGISTRY_DB="${FOUNDRY_DIR}/test-foundry.db"
  export USE_SQLITE_REGISTRY="true"

  unset _CORE_REGISTRY_SQLITE_LOADED
  unset _CORE_LOGGING_LOADED
  unset _CORE_PATTERNS_LOADED

  log() { echo "$*"; }
  log_ok() { echo "OK: $*"; }
  log_warn() { echo "WARN: $*"; }
  log_err() { echo "ERR: $*"; }
  tg_notify() { return 0; }
  export -f log log_ok log_warn log_err tg_notify

  source "$(dirname "$BATS_TEST_FILENAME")/../core/registry_sqlite.bash"
}

teardown() {
  rm -rf "$FOUNDRY_DIR"
}

_insert_test_task() {
  local id="$1" status="$2" exit_code="${3:-}"
  _db "INSERT INTO tasks (id, repo, repo_path, status, agent_exit_code) VALUES ('$id', 'test', '/tmp/test', '$status', $([ -n "$exit_code" ] && echo "$exit_code" || echo "NULL"));"
}

# ── CAS basics ──

@test "CAS succeeds when status matches expected" {
  _insert_test_task "t1" "agent-done" "0"
  run registry_cas_status "t1" "agent-done" "evaluating"
  [ "$status" -eq 0 ]
  # Verify status changed
  result=$(_db "SELECT status FROM tasks WHERE id = 't1'")
  [ "$result" = "evaluating" ]
}

@test "CAS fails when status does not match expected" {
  _insert_test_task "t2" "running"
  run registry_cas_status "t2" "agent-done" "evaluating"
  [ "$status" -eq 1 ]
  # Verify status unchanged
  result=$(_db "SELECT status FROM tasks WHERE id = 't2'")
  [ "$result" = "running" ]
}

@test "CAS fails on non-existent task" {
  run registry_cas_status "nonexistent" "agent-done" "evaluating"
  [ "$status" -eq 1 ]
}

@test "Double CAS: first wins, second fails" {
  _insert_test_task "t3" "agent-done" "0"
  # First CAS succeeds
  run registry_cas_status "t3" "agent-done" "evaluating"
  [ "$status" -eq 0 ]
  # Second CAS fails (status is now evaluating, not agent-done)
  run registry_cas_status "t3" "agent-done" "evaluating"
  [ "$status" -eq 1 ]
}

# ── agent_exit_code column ──

@test "agent_exit_code column exists after migration" {
  local col_count
  col_count=$(sqlite3 "$REGISTRY_DB" "PRAGMA table_info(tasks);" | grep -c 'agent_exit_code')
  [ "$col_count" -ge 1 ]
}

@test "agent_exit_code persists through registry_get_task" {
  _insert_test_task "t4" "agent-done" "99"
  local task_json
  task_json=$(registry_get_task "t4")
  local exit_code
  exit_code=$(echo "$task_json" | jq -r '.agentExitCode')
  [ "$exit_code" = "99" ]
}

# ── registry_remove alias ──

@test "registry_remove deletes task" {
  _insert_test_task "t5" "done-no-pr"
  registry_remove "t5"
  local count
  count=$(_db "SELECT COUNT(*) FROM tasks WHERE id = 't5'")
  [ "$count" = "0" ]
}
