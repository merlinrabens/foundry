#!/usr/bin/env bats
# Integration tests: agent lifecycle — registry operations, state tracking,
# pattern logging, and helper utilities exercised end-to-end.

load test_helper

# ============================================================================
# Registry lifecycle (empty -> add -> query -> update -> batch)
# ============================================================================

@test "registry starts empty when file is initialized" {
  echo "[]" > "$REGISTRY"
  result=$(registry_read)
  [ "$result" = "[]" ]
}

@test "add task JSON to registry" {
  rm -f "$REGISTRY"
  local task='{"id":"test-task-1","repo":"myrepo","status":"running","agent":"codex","model":"gpt-5.3-codex","attempts":1}'
  registry_add_task "$task"
  local count
  count=$(jq 'length' "$REGISTRY")
  [ "$count" = "1" ]
}

@test "registry preserves task fields after add" {
  rm -f "$REGISTRY"
  local task='{"id":"test-task-2","repo":"myrepo","status":"running","agent":"claude","model":"claude-sonnet-4-6"}'
  registry_add_task "$task"
  local agent
  agent=$(jq -r '.[0].agent' "$REGISTRY")
  [ "$agent" = "claude" ]
}

@test "update task status via registry_update_field" {
  create_sample_registry
  registry_update_field "myproject-feature-auth" "status" "ready"
  local status
  status=$(jq -r '.[] | select(.id=="myproject-feature-auth") | .status' "$REGISTRY")
  [ "$status" = "ready" ]
}

@test "batch update multiple fields atomically" {
  create_sample_registry
  registry_batch_update "myproject-feature-auth" \
    "status=pr-open" \
    "pr=https://github.com/test/pr/1"
  local task
  task=$(registry_get_task "myproject-feature-auth")
  [ "$(echo "$task" | jq -r '.status')" = "pr-open" ]
  [ "$(echo "$task" | jq -r '.pr')" = "https://github.com/test/pr/1" ]
}

@test "get nonexistent task returns empty" {
  create_sample_registry
  result=$(registry_get_task "nonexistent-task")
  [ -z "$result" ]
}

# ============================================================================
# Pattern logging
# ============================================================================

@test "pattern_log writes to patterns file" {
  rm -f "$PATTERNS_FILE"
  pattern_log "test-id" "codex" "gpt-5.3-codex" 0 "true" 600 "myproject" "feature"
  [ -f "$PATTERNS_FILE" ]
  local count
  count=$(wc -l < "$PATTERNS_FILE" | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "pattern_log records correct agent field" {
  rm -f "$PATTERNS_FILE"
  pattern_log "test-id2" "claude" "claude-sonnet-4-6" 1 "false" 300 "proj" "bugfix"
  local agent
  agent=$(tail -1 "$PATTERNS_FILE" | jq -r '.agent')
  [ "$agent" = "claude" ]
}

# ============================================================================
# detect_pkg_manager
# ============================================================================

@test "detect_pkg_manager finds pnpm" {
  local tmpdir
  tmpdir=$(mktemp -d)
  touch "$tmpdir/pnpm-lock.yaml"
  run detect_pkg_manager "$tmpdir"
  [ "$output" = "pnpm" ]
  rm -rf "$tmpdir"
}

@test "detect_pkg_manager finds npm" {
  local tmpdir
  tmpdir=$(mktemp -d)
  touch "$tmpdir/package-lock.json"
  run detect_pkg_manager "$tmpdir"
  [ "$output" = "npm" ]
  rm -rf "$tmpdir"
}

@test "detect_pkg_manager returns none for empty dir" {
  local tmpdir
  tmpdir=$(mktemp -d)
  run detect_pkg_manager "$tmpdir"
  [ "$output" = "none" ]
  rm -rf "$tmpdir"
}

# ============================================================================
# sanitize + generate_task_id
# ============================================================================

@test "sanitize converts to lowercase kebab" {
  run sanitize "Hello World_Test"
  [ "$output" = "hello-world-test" ]
}

@test "generate_task_id combines project and name" {
  run generate_task_id "feature-auth" "myproject"
  [ "$output" = "myproject-feature-auth" ]
}
