#!/usr/bin/env bats
# Tests for registry operations: read, write, add, update, get, batch, jq_update

load test_helper

# ============================================================================
# registry_read()
# ============================================================================

@test "registry_read: returns empty array when no file" {
  rm -f "$REGISTRY"
  result=$(registry_read)
  [ "$result" = "[]" ]
}

@test "registry_read: returns file contents when file exists" {
  echo '[{"id":"test"}]' > "$REGISTRY"
  result=$(registry_read)
  [ "$(echo "$result" | jq length)" -eq 1 ]
}

# ============================================================================
# registry_locked_write()
# ============================================================================

@test "registry_locked_write: creates file with content" {
  registry_locked_write '[{"id":"written"}]'
  result=$(cat "$REGISTRY")
  [ "$(echo "$result" | jq -r '.[0].id')" = "written" ]
}

@test "registry_locked_write: overwrites existing content" {
  echo '[{"id":"old"}]' > "$REGISTRY"
  registry_locked_write '[{"id":"new"}]'
  result=$(jq -r '.[0].id' "$REGISTRY")
  [ "$result" = "new" ]
}

@test "registry_locked_write: lock is released after write" {
  registry_locked_write '[]'
  # Lock dir should NOT exist after write completes
  [ ! -d "$REGISTRY_LOCKDIR" ]
}

# ============================================================================
# registry_add_task()
# ============================================================================

@test "registry_add_task: adds to empty registry" {
  rm -f "$REGISTRY"
  local task='{"id":"new-task","status":"running"}'
  registry_add_task "$task"
  result=$(jq length "$REGISTRY")
  [ "$result" -eq 1 ]
}

@test "registry_add_task: appends to existing registry" {
  echo '[{"id":"existing","status":"merged"}]' > "$REGISTRY"
  local task='{"id":"second","status":"running"}'
  registry_add_task "$task"
  result=$(jq length "$REGISTRY")
  [ "$result" -eq 2 ]
}

@test "registry_add_task: preserves existing tasks" {
  echo '[{"id":"keep-me","status":"running"}]' > "$REGISTRY"
  registry_add_task '{"id":"new-one","status":"running"}'
  result=$(jq -r '.[0].id' "$REGISTRY")
  [ "$result" = "keep-me" ]
}

# ============================================================================
# registry_get_task()
# ============================================================================

@test "registry_get_task: finds existing task by id" {
  create_sample_registry
  result=$(registry_get_task "myproject-feature-auth")
  [ "$(echo "$result" | jq -r '.status')" = "running" ]
}

@test "registry_get_task: returns empty for missing task" {
  create_sample_registry
  result=$(registry_get_task "nonexistent-task")
  [ -z "$result" ]
}

@test "registry_get_task: returns correct task from multiple" {
  create_sample_registry
  result=$(registry_get_task "myproject-fix-login-bug")
  [ "$(echo "$result" | jq -r '.agent')" = "claude" ]
}

# ============================================================================
# _jq_update()
# ============================================================================

@test "_jq_update: updates string field" {
  local reg='[{"id":"t1","status":"running"},{"id":"t2","status":"merged"}]'
  result=$(_jq_update "$reg" "t1" "status" "failed")
  [ "$(echo "$result" | jq -r '.[] | select(.id=="t1") | .status')" = "failed" ]
}

@test "_jq_update: updates boolean field (true)" {
  local reg='[{"id":"t1","checks":{"ciPassed":false}}]'
  result=$(_jq_update "$reg" "t1" "checks.ciPassed" "true")
  [ "$(echo "$result" | jq -r '.[0].checks.ciPassed')" = "true" ]
}

@test "_jq_update: updates boolean field (false)" {
  local reg='[{"id":"t1","checks":{"agentAlive":true}}]'
  result=$(_jq_update "$reg" "t1" "checks.agentAlive" "false")
  [ "$(echo "$result" | jq -r '.[0].checks.agentAlive')" = "false" ]
}

@test "_jq_update: updates numeric field" {
  local reg='[{"id":"t1","attempts":1}]'
  result=$(_jq_update "$reg" "t1" "attempts" "2")
  [ "$(echo "$result" | jq -r '.[0].attempts')" = "2" ]
}

@test "_jq_update: sets field to null" {
  local reg='[{"id":"t1","failureReason":"timeout"}]'
  result=$(_jq_update "$reg" "t1" "failureReason" "null")
  [ "$(echo "$result" | jq -r '.[0].failureReason')" = "null" ]
}

@test "_jq_update: leaves other tasks untouched" {
  local reg='[{"id":"t1","status":"running"},{"id":"t2","status":"merged"}]'
  result=$(_jq_update "$reg" "t1" "status" "failed")
  [ "$(echo "$result" | jq -r '.[] | select(.id=="t2") | .status')" = "merged" ]
}

@test "_jq_update: nested field with dot notation" {
  local reg='[{"id":"t1","checks":{"codexReview":null}}]'
  result=$(_jq_update "$reg" "t1" "checks.codexReview" "APPROVED")
  [ "$(echo "$result" | jq -r '.[0].checks.codexReview')" = "APPROVED" ]
}

# ============================================================================
# registry_update_field()
# ============================================================================

@test "registry_update_field: updates field in file" {
  create_sample_registry
  registry_update_field "myproject-feature-auth" "status" "pr-open"
  result=$(jq -r '.[] | select(.id=="myproject-feature-auth") | .status' "$REGISTRY")
  [ "$result" = "pr-open" ]
}

@test "registry_update_field: preserves other tasks" {
  create_sample_registry
  registry_update_field "myproject-feature-auth" "status" "failed"
  result=$(jq -r '.[] | select(.id=="myproject-fix-login-bug") | .status' "$REGISTRY")
  [ "$result" = "merged" ]
}

# ============================================================================
# registry_batch_update()
# ============================================================================

@test "registry_batch_update: updates multiple fields" {
  create_sample_registry
  registry_batch_update "myproject-feature-auth" \
    "status=pr-open" \
    "checks.prCreated=true" \
    "checks.branchSynced=true"

  result=$(jq -r '.[] | select(.id=="myproject-feature-auth")' "$REGISTRY")
  [ "$(echo "$result" | jq -r '.status')" = "pr-open" ]
  [ "$(echo "$result" | jq -r '.checks.prCreated')" = "true" ]
  [ "$(echo "$result" | jq -r '.checks.branchSynced')" = "true" ]
}

@test "registry_batch_update: single field works too" {
  create_sample_registry
  registry_batch_update "myproject-feature-auth" "attempts=2"
  result=$(jq -r '.[] | select(.id=="myproject-feature-auth") | .attempts' "$REGISTRY")
  [ "$result" = "2" ]
}

# ============================================================================
# Locking
# ============================================================================

@test "lock: acquired and released cleanly" {
  _registry_lock
  [ -d "$REGISTRY_LOCKDIR" ]
  _registry_unlock
  [ ! -d "$REGISTRY_LOCKDIR" ]
}

@test "lock: stale lock auto-cleaned" {
  # Create a lock dir with old timestamp
  mkdir -p "$REGISTRY_LOCKDIR"
  # Touch it to be old (35 seconds ago)
  touch -t "$(date -v-35S +%Y%m%d%H%M.%S)" "$REGISTRY_LOCKDIR" 2>/dev/null || \
    touch -d "35 seconds ago" "$REGISTRY_LOCKDIR" 2>/dev/null || true

  # Should acquire despite stale lock
  _registry_lock
  [ -d "$REGISTRY_LOCKDIR" ]
  _registry_unlock
}
