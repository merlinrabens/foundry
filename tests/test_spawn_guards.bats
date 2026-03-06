#!/usr/bin/env bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/spawn_guards.bash"
}

# ─── check_concurrent_limit ──────────────────────────────────────────

@test "check_concurrent_limit: 2 running, max 4 returns 0 (ok)" {
  run check_concurrent_limit 2 4
  [ "$status" -eq 0 ]
}

@test "check_concurrent_limit: 4 running, max 4 returns 1 (full)" {
  run check_concurrent_limit 4 4
  [ "$status" -eq 1 ]
}

@test "check_concurrent_limit: 5 running, max 4 returns 1 (over)" {
  run check_concurrent_limit 5 4
  [ "$status" -eq 1 ]
}

@test "check_concurrent_limit: 0 running, max 4 returns 0 (ok)" {
  run check_concurrent_limit 0 4
  [ "$status" -eq 0 ]
}

# ─── detect_parallel_conflict ─────────────────────────────────────────

@test "detect_parallel_conflict: no running in same repo gives empty output" {
  local registry='[{"id":"task-1","status":"merged","repoPath":"/tmp/myrepo"}]'
  run detect_parallel_conflict "/tmp/myrepo" "$registry"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "detect_parallel_conflict: one running in same repo outputs task id" {
  local registry='[{"id":"task-1","status":"running","repoPath":"/tmp/myrepo"},{"id":"task-2","status":"merged","repoPath":"/tmp/myrepo"}]'
  run detect_parallel_conflict "/tmp/myrepo" "$registry"
  [ "$status" -eq 0 ]
  [ "$output" = "task-1" ]
}

@test "detect_parallel_conflict: running in different repo gives empty output" {
  local registry='[{"id":"task-1","status":"running","repoPath":"/tmp/other-repo"}]'
  run detect_parallel_conflict "/tmp/myrepo" "$registry"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "detect_parallel_conflict: empty registry gives empty output" {
  local registry='[]'
  run detect_parallel_conflict "/tmp/myrepo" "$registry"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# ─── parse_spawn_flags ────────────────────────────────────────────────

@test "parse_spawn_flags: no flags gives empty PROMPT_FILE_OVERRIDE and all positional" {
  parse_spawn_flags "myrepo" "task-name" "codex"
  [ "$PROMPT_FILE_OVERRIDE" = "" ]
  [ "${#POSITIONAL_ARGS[@]}" -eq 3 ]
  [ "${POSITIONAL_ARGS[0]}" = "myrepo" ]
  [ "${POSITIONAL_ARGS[1]}" = "task-name" ]
  [ "${POSITIONAL_ARGS[2]}" = "codex" ]
}

@test "parse_spawn_flags: --prompt-file /tmp/p.md sets override" {
  parse_spawn_flags "myrepo" "--prompt-file" "/tmp/p.md" "codex"
  [ "$PROMPT_FILE_OVERRIDE" = "/tmp/p.md" ]
  [ "${#POSITIONAL_ARGS[@]}" -eq 2 ]
  [ "${POSITIONAL_ARGS[0]}" = "myrepo" ]
  [ "${POSITIONAL_ARGS[1]}" = "codex" ]
}

@test "parse_spawn_flags: --prompt-file=/tmp/p.md (= form) sets override" {
  parse_spawn_flags "myrepo" "--prompt-file=/tmp/p.md" "codex"
  [ "$PROMPT_FILE_OVERRIDE" = "/tmp/p.md" ]
  [ "${#POSITIONAL_ARGS[@]}" -eq 2 ]
  [ "${POSITIONAL_ARGS[0]}" = "myrepo" ]
  [ "${POSITIONAL_ARGS[1]}" = "codex" ]
}

@test "parse_spawn_flags: mixed flags and positional gives correct separation" {
  parse_spawn_flags "myrepo" "task-name" "--prompt-file" "/tmp/custom.md" "claude" "extra-arg"
  [ "$PROMPT_FILE_OVERRIDE" = "/tmp/custom.md" ]
  [ "${#POSITIONAL_ARGS[@]}" -eq 4 ]
  [ "${POSITIONAL_ARGS[0]}" = "myrepo" ]
  [ "${POSITIONAL_ARGS[1]}" = "task-name" ]
  [ "${POSITIONAL_ARGS[2]}" = "claude" ]
  [ "${POSITIONAL_ARGS[3]}" = "extra-arg" ]
}
