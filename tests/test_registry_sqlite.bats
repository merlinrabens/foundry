#!/usr/bin/env bats
# Tests for core/registry_sqlite.bash — SQLite-backed registry

setup() {
  export FOUNDRY_DIR="$(mktemp -d)"
  export REGISTRY="${FOUNDRY_DIR}/active-tasks.json"
  export REGISTRY_DB="${FOUNDRY_DIR}/test-foundry.db"
  export USE_SQLITE_REGISTRY="true"

  # Unset source guards
  unset _CORE_REGISTRY_SQLITE_LOADED
  unset _CORE_LOGGING_LOADED
  unset _CORE_PATTERNS_LOADED

  # Minimal logging stubs
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

# ─── DB Init ──────────────────────────────────────────────────────────────

@test "DB is created on source" {
  [ -f "$REGISTRY_DB" ]
}

@test "DB has tasks table" {
  result=$(sqlite3 "$REGISTRY_DB" ".tables" | grep -c "tasks")
  [ "$result" -ge 1 ]
}

@test "DB has events table" {
  result=$(sqlite3 "$REGISTRY_DB" ".tables" | grep -c "events")
  [ "$result" -ge 1 ]
}

@test "DB has patterns table" {
  result=$(sqlite3 "$REGISTRY_DB" ".tables" | grep -c "patterns")
  [ "$result" -ge 1 ]
}

@test "DB uses WAL journal mode" {
  mode=$(sqlite3 "$REGISTRY_DB" "PRAGMA journal_mode;")
  [ "$mode" = "wal" ]
}

# ─── registry_read ────────────────────────────────────────────────────────

@test "registry_read returns empty array when no tasks" {
  result=$(registry_read)
  [ "$(echo "$result" | jq 'length')" -eq 0 ]
}

# ─── registry_add_task ────────────────────────────────────────────────────

@test "registry_add_task adds a task" {
  local task='{"id":"test-1","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","checks":{}}'
  registry_add_task "$task"
  result=$(registry_read)
  [ "$(echo "$result" | jq 'length')" -eq 1 ]
  [ "$(echo "$result" | jq -r '.[0].id')" = "test-1" ]
}

@test "registry_add_task creates spawn event" {
  local task='{"id":"test-evt","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","checks":{}}'
  registry_add_task "$task"
  count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM events WHERE task_id='test-evt' AND event='spawned';")
  [ "$count" -eq 1 ]
}

# ─── registry_get_task ────────────────────────────────────────────────────

@test "registry_get_task returns task by ID" {
  local task='{"id":"get-test","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"claude","model":"claude-sonnet-4-6","checks":{}}'
  registry_add_task "$task"
  result=$(registry_get_task "get-test")
  [ "$(echo "$result" | jq -r '.id')" = "get-test" ]
  [ "$(echo "$result" | jq -r '.agent')" = "claude" ]
}

@test "registry_get_task returns empty for missing ID" {
  result=$(registry_get_task "nonexistent")
  [ -z "$result" ] || [ "$result" = "null" ]
}

# ─── registry_update_field ────────────────────────────────────────────────

@test "registry_update_field updates status" {
  local task='{"id":"upd-1","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","checks":{}}'
  registry_add_task "$task"
  registry_update_field "upd-1" "status" "pr-open"
  result=$(registry_get_task "upd-1")
  [ "$(echo "$result" | jq -r '.status')" = "pr-open" ]
}

@test "registry_update_field updates numeric field" {
  local task='{"id":"upd-num","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","attempts":1,"checks":{}}'
  registry_add_task "$task"
  registry_update_field "upd-num" "attempts" "3"
  result=$(registry_get_task "upd-num")
  [ "$(echo "$result" | jq '.attempts')" -eq 3 ]
}

@test "registry_update_field updates nested checks field" {
  local task='{"id":"upd-chk","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","checks":{"ciPassed":false}}'
  registry_add_task "$task"
  registry_update_field "upd-chk" "checks.ciPassed" "true"
  result=$(registry_get_task "upd-chk")
  [ "$(echo "$result" | jq '.checks.ciPassed')" = "true" ]
}

@test "registry_update_field handles null value" {
  local task='{"id":"upd-null","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","failureReason":"some error","checks":{}}'
  registry_add_task "$task"
  registry_update_field "upd-null" "failureReason" "null"
  result=$(registry_get_task "upd-null")
  [ "$(echo "$result" | jq -r '.failureReason')" = "null" ]
}

# ─── registry_batch_update ────────────────────────────────────────────────

@test "registry_batch_update updates multiple fields atomically" {
  local task='{"id":"batch-1","repo":"myrepo","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","attempts":1,"checks":{}}'
  registry_add_task "$task"
  registry_batch_update "batch-1" "status=pr-open" "attempts=2" "checks.ciPassed=true"
  result=$(registry_get_task "batch-1")
  [ "$(echo "$result" | jq -r '.status')" = "pr-open" ]
  [ "$(echo "$result" | jq '.attempts')" -eq 2 ]
  [ "$(echo "$result" | jq '.checks.ciPassed')" = "true" ]
}

# ─── camelCase mapping ────────────────────────────────────────────────────

@test "_field_to_column maps camelCase to snake_case" {
  [ "$(_field_to_column "repoPath")" = "repo_path" ]
  [ "$(_field_to_column "tmuxSession")" = "tmux_session" ]
  [ "$(_field_to_column "maxAttempts")" = "max_attempts" ]
  [ "$(_field_to_column "reviewFixAttempts")" = "review_fix_attempts" ]
  [ "$(_field_to_column "lastNotifiedState")" = "last_notified_state" ]
  [ "$(_field_to_column "status")" = "status" ]
}

# ─── Legacy JSON format ──────────────────────────────────────────────────

@test "registry_read returns camelCase keys (legacy compat)" {
  local task='{"id":"legacy-1","repo":"myrepo","repoPath":"/tmp/repo","tmuxSession":"foundry-test","status":"running","agent":"codex","model":"gpt-5.3-codex","startedAt":1234567890,"checks":{"ciPassed":false}}'
  registry_add_task "$task"
  result=$(registry_read)
  # Check camelCase keys exist
  echo "$result" | jq '.[0].repoPath' >/dev/null
  echo "$result" | jq '.[0].tmuxSession' >/dev/null
  echo "$result" | jq '.[0].startedAt' >/dev/null
  echo "$result" | jq '.[0].maxAttempts' >/dev/null
  # Check nested checks is an object
  [ "$(echo "$result" | jq '.[0].checks | type')" = '"object"' ]
}

# ─── registry_locked_write ────────────────────────────────────────────────

@test "registry_locked_write replaces all tasks" {
  local task1='{"id":"rw-1","repo":"a","repoPath":"/tmp/a","status":"running","agent":"codex","model":"m","checks":{}}'
  local task2='{"id":"rw-2","repo":"b","repoPath":"/tmp/b","status":"done","agent":"claude","model":"m","checks":{}}'
  registry_add_task "$task1"
  registry_add_task "$task2"

  # Replace with single task
  local new_content='[{"id":"rw-3","repo":"c","repoPath":"/tmp/c","status":"merged","agent":"gemini","model":"m","checks":{}}]'
  registry_locked_write "$new_content"

  result=$(registry_read)
  [ "$(echo "$result" | jq 'length')" -eq 1 ]
  [ "$(echo "$result" | jq -r '.[0].id')" = "rw-3" ]
}

# ─── Event logging ────────────────────────────────────────────────────────

@test "registry_log_event records events" {
  registry_log_event "task-evt" "status-change" "running → pr-open"
  registry_log_event "task-evt" "respawn" "attempt 2"
  count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM events WHERE task_id='task-evt';")
  [ "$count" -eq 2 ]
}

@test "registry_recent_events returns latest events" {
  registry_log_event "recent-evt" "a" "first"
  registry_log_event "recent-evt" "b" "second"
  result=$(registry_recent_events "recent-evt" 1)
  [ "$(echo "$result" | jq 'length')" -eq 1 ]
}

# ─── Pattern logging ─────────────────────────────────────────────────────

@test "pattern_log_sqlite inserts pattern" {
  pattern_log_sqlite "pat-1" "codex" "gpt-5.3-codex" "2" "1" "300" "myproject" "feature"
  count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM patterns WHERE task_id='pat-1';")
  [ "$count" -eq 1 ]
}

# ─── Query helpers ────────────────────────────────────────────────────────

@test "registry_count_by_status returns correct count" {
  local task1='{"id":"cnt-1","repo":"a","repoPath":"/tmp/a","status":"running","agent":"codex","model":"m","checks":{}}'
  local task2='{"id":"cnt-2","repo":"b","repoPath":"/tmp/b","status":"running","agent":"codex","model":"m","checks":{}}'
  local task3='{"id":"cnt-3","repo":"c","repoPath":"/tmp/c","status":"merged","agent":"codex","model":"m","checks":{}}'
  registry_add_task "$task1"
  registry_add_task "$task2"
  registry_add_task "$task3"
  [ "$(registry_count_by_status "running")" -eq 2 ]
  [ "$(registry_count_by_status "merged")" -eq 1 ]
}

@test "registry_active_count counts active statuses" {
  local task1='{"id":"act-1","repo":"a","repoPath":"/tmp/a","status":"running","agent":"codex","model":"m","checks":{}}'
  local task2='{"id":"act-2","repo":"b","repoPath":"/tmp/b","status":"pr-open","agent":"codex","model":"m","checks":{}}'
  local task3='{"id":"act-3","repo":"c","repoPath":"/tmp/c","status":"merged","agent":"codex","model":"m","checks":{}}'
  registry_add_task "$task1"
  registry_add_task "$task2"
  registry_add_task "$task3"
  [ "$(registry_active_count)" -eq 2 ]
}

@test "registry_delete_task removes task and logs event" {
  local task='{"id":"del-1","repo":"a","repoPath":"/tmp/a","status":"running","agent":"codex","model":"m","checks":{}}'
  registry_add_task "$task"
  registry_delete_task "del-1"
  count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM tasks WHERE id='del-1';")
  [ "$count" -eq 0 ]
  # Delete event logged
  evt_count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM events WHERE task_id='del-1' AND event='deleted';")
  [ "$evt_count" -eq 1 ]
}

# ─── Concurrency safety ──────────────────────────────────────────────────

@test "concurrent writes don't corrupt DB (WAL mode)" {
  # Spawn 5 parallel writes
  for i in $(seq 1 5); do
    (
      local task="{\"id\":\"conc-$i\",\"repo\":\"a\",\"repoPath\":\"/tmp/a\",\"status\":\"running\",\"agent\":\"codex\",\"model\":\"m\",\"checks\":{}}"
      registry_add_task "$task"
    ) &
  done
  wait

  count=$(sqlite3 "$REGISTRY_DB" "SELECT COUNT(*) FROM tasks WHERE id LIKE 'conc-%';")
  [ "$count" -eq 5 ]
}

# ─── SQL injection safety ────────────────────────────────────────────────

@test "single quotes in values don't cause SQL errors" {
  local task='{"id":"sql-inj","repo":"O'\''Reilly","repoPath":"/tmp/repo","status":"running","agent":"codex","model":"gpt-5.3-codex","description":"fix don'\''t break","checks":{}}'
  registry_add_task "$task"
  result=$(registry_get_task "sql-inj")
  [ "$(echo "$result" | jq -r '.id')" = "sql-inj" ]
}
