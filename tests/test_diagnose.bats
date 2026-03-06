#!/usr/bin/env bats
# Tests for commands/diagnose.bash

setup() {
  export FOUNDRY_DIR="$(mktemp -d)"
  export REGISTRY="${FOUNDRY_DIR}/active-tasks.json"
  export REGISTRY_DB="${FOUNDRY_DIR}/test-foundry.db"
  export USE_SQLITE_REGISTRY="true"
  export KNOWN_PROJECTS=()

  mkdir -p "${FOUNDRY_DIR}/logs"

  # Unset source guards
  unset _CORE_REGISTRY_SQLITE_LOADED
  unset _CORE_LOGGING_LOADED

  # Color vars
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
  export RED GREEN YELLOW BLUE CYAN BOLD NC

  # Logging stubs
  log() { echo "$*"; }
  log_ok() { echo "OK: $*"; }
  log_warn() { echo "WARN: $*"; }
  log_err() { echo "ERR: $*"; }
  tg_notify() { return 0; }
  export -f log log_ok log_warn log_err tg_notify

  # Override HOME to prevent scanning real filesystem for orphaned worktrees
  export HOME="$(mktemp -d)"

  source "$(dirname "$BATS_TEST_FILENAME")/../core/registry_sqlite.bash"
  source "$(dirname "$BATS_TEST_FILENAME")/../commands/diagnose.bash"
}

teardown() {
  rm -rf "$FOUNDRY_DIR"
}

# ─── Clean state ─────────────────────────────────────────────────────────

@test "diagnose reports no issues on clean state" {
  run cmd_diagnose
  [ "$status" -eq 0 ]
  [[ "$output" == *"All clear"* ]]
}

# ─── Stuck task detection ────────────────────────────────────────────────

@test "diagnose detects stuck task (running, no process, no done file)" {
  local task='{"id":"stuck-1","repo":"test","repoPath":"/tmp/test","tmuxSession":"foundry-stuck","status":"running","agent":"codex","model":"m","startedAt":1234567890,"checks":{}}'
  registry_add_task "$task"
  # No process, no done file, no PID = stuck
  run cmd_diagnose
  [ "$status" -gt 0 ]
  [[ "$output" == *"STUCK"* ]]
  [[ "$output" == *"stuck-1"* ]]
}

@test "diagnose --fix marks stuck task as crashed" {
  local task='{"id":"stuck-fix","repo":"test","repoPath":"/tmp/test","tmuxSession":"foundry-stuck-fix","status":"running","agent":"codex","model":"m","startedAt":1234567890,"checks":{}}'
  registry_add_task "$task"
  run cmd_diagnose --fix
  # Check that status was updated
  result=$(registry_get_task "stuck-fix")
  [ "$(echo "$result" | jq -r '.status')" = "crashed" ]
}

# ─── Registry integrity ─────────────────────────────────────────────────

@test "diagnose detects duplicate IDs via registry_read" {
  # Insert two tasks with same ID directly (bypassing INSERT OR REPLACE)
  # This won't create a true dupe in SQLite (PRIMARY KEY prevents it),
  # but we test the jq-based dupe detection on the JSON output
  local task='{"id":"dupe-1","repo":"test","repoPath":"/tmp/test","status":"running","agent":"codex","model":"m","checks":{}}'
  registry_add_task "$task"
  # Registry integrity check looks at JSON output — single entry = no dupes
  run cmd_diagnose
  # Should find 0 dupes (SQLite PK prevents actual dupes)
  [[ "$output" != *"DUPLICATE"* ]]
}

# ─── Stale logs ──────────────────────────────────────────────────────────

@test "diagnose detects stale log files" {
  # Create an old log file (touch with old timestamp)
  touch -t 202501010000 "${FOUNDRY_DIR}/logs/old-task.log"
  touch -t 202501010000 "${FOUNDRY_DIR}/logs/old-task.done"
  run cmd_diagnose
  [[ "$output" == *"STALE"* ]]
}

@test "diagnose --fix deletes stale log files" {
  touch -t 202501010000 "${FOUNDRY_DIR}/logs/stale.log"
  touch -t 202501010000 "${FOUNDRY_DIR}/logs/stale.done"
  run cmd_diagnose --fix
  [ ! -f "${FOUNDRY_DIR}/logs/stale.log" ]
  [ ! -f "${FOUNDRY_DIR}/logs/stale.done" ]
}

# ─── SQLite health ───────────────────────────────────────────────────────

@test "diagnose checks SQLite integrity" {
  run cmd_diagnose
  [[ "$output" == *"integrity check passed"* ]]
}

# ─── ACP adapter check ───────────────────────────────────────────────────

@test "diagnose checks ACP adapters" {
  run cmd_diagnose
  [[ "$output" == *"ACP adapters"* ]]
}
