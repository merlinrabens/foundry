#!/bin/bash
# Test helper — sets up isolated environment for foundry tests.
# Sources core/, lib/, and commands/ modules directly.

export FOUNDRY_TEST_DIR
FOUNDRY_TEST_DIR="$(mktemp -d)"

# Isolated registry + patterns in temp dir
export FOUNDRY_DIR="$FOUNDRY_TEST_DIR"
export SWARM_DIR="$FOUNDRY_TEST_DIR"  # backward compat alias
export REGISTRY="$FOUNDRY_TEST_DIR/active-tasks.json"
export PATTERNS_FILE="$FOUNDRY_TEST_DIR/patterns.jsonl"
export REGISTRY_LOCKDIR="${REGISTRY}.lockdir"

# Stub out Telegram
export TG_CHAT_ID="test"
export OPENCLAW_TG_BOT_TOKEN=""

# Source config defaults (model names, limits, etc.)
export CLAUDE_DEFAULT="claude-sonnet-4-6"
export CLAUDE_COMPLEX="claude-opus-4-6"
export CODEX_MODEL="gpt-5.3-codex"
export CODEX_REASONING="high"
export GEMINI_MODEL="gemini-3.5-pro"
export DEFAULT_MODEL="codex"
export MAX_RETRIES=5
export AGENT_TIMEOUT=1800
export MAX_CONCURRENT=4
export PREFLIGHT_ENABLED="true"
export PREFLIGHT_TIMEOUT=120
export AUTO_MERGE_LOW_RISK="false"
export STALE_THRESHOLD_SECS=7200
export IDLE_THRESHOLD_SECS=1800
export KNOWN_PROJECTS=()

# CLI tool paths (stubs — not used in tests)
export CLAUDE_BIN="claude"
export CODEX_BIN="codex"
export GEMINI_BIN="gemini"

# Suppress colors in test output
export RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''

# Existing tests use JSON registry — disable SQLite unless explicitly enabled
export USE_SQLITE_REGISTRY="${USE_SQLITE_REGISTRY:-false}"

# Path to the real foundry directory
_FOUNDRY_REAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source core/ modules (logging, registry, gh, patterns, templates)
# Skip registry_sqlite.bash for JSON-based tests (it overrides registry functions)
for _core_file in "$_FOUNDRY_REAL_DIR/core/"*.bash; do
  [ -f "$_core_file" ] || continue
  [[ "$_core_file" == *registry_sqlite.bash ]] && continue
  source "$_core_file"
done

# Source lib/ modules (model_routing, state_machine, etc.)
for _lib_file in "$_FOUNDRY_REAL_DIR/lib/"*.bash; do
  [ -f "$_lib_file" ] && source "$_lib_file"
done

# Source all command files (so tests can call cmd_* functions directly)
for _cmd_file in "$_FOUNDRY_REAL_DIR/commands/"*.bash; do
  [ -f "$_cmd_file" ] && source "$_cmd_file"
done

# Override log functions AFTER sourcing (simplified for tests — no colors)
log()      { echo "[foundry] $*"; }
log_ok()   { echo "[foundry] $*"; }
log_warn() { echo "[foundry] $*"; }
log_err()  { echo "[foundry] $*"; }
export -f log log_ok log_warn log_err

# Helper: create a sample registry with tasks
create_sample_registry() {
  cat > "$REGISTRY" << 'JSONEOF'
[
  {
    "id": "myproject-feature-auth",
    "repo": "myproject",
    "repoPath": "/tmp/myproject",
    "worktree": "/tmp/myproject-foundry/feature-auth",
    "branch": "foundry/feature-auth",
    "tmuxSession": "foundry-myproject-feature-auth",
    "agent": "codex",
    "model": "gpt-5.3-codex",
    "spec": "specs/backlog/01-feature-auth.md",
    "description": "feature-auth",
    "startedAt": 1772000000,
    "status": "running",
    "attempts": 1,
    "maxAttempts": 3,
    "pr": null,
    "checks": {
      "agentAlive": true,
      "prCreated": false,
      "branchSynced": false,
      "ciPassed": false,
      "codexReview": null,
      "claudeReview": null,
      "geminiReview": null,
      "screenshotsIncluded": null
    },
    "lastCheckedAt": null,
    "completedAt": null,
    "failureReason": null,
    "respawnContext": null,
    "notifyOnComplete": true,
    "lastNotifiedState": null
  },
  {
    "id": "myproject-fix-login-bug",
    "repo": "myproject",
    "repoPath": "/tmp/myproject",
    "worktree": "/tmp/myproject-foundry/fix-login-bug",
    "branch": "foundry/fix-login-bug",
    "tmuxSession": "foundry-myproject-fix-login-bug",
    "agent": "claude",
    "model": "claude-sonnet-4-6",
    "spec": "specs/backlog/02-fix-login-bug.md",
    "description": "fix-login-bug",
    "startedAt": 1772000100,
    "status": "merged",
    "attempts": 1,
    "maxAttempts": 3,
    "pr": "https://github.com/test/myproject/pull/42",
    "checks": {
      "agentAlive": false,
      "prCreated": true,
      "branchSynced": true,
      "ciPassed": true,
      "codexReview": "APPROVED",
      "claudeReview": "APPROVED",
      "geminiReview": "AUTO_PASSED",
      "screenshotsIncluded": null
    },
    "lastCheckedAt": 1772001000,
    "completedAt": 1772001000,
    "failureReason": null,
    "respawnContext": null,
    "notifyOnComplete": true,
    "lastNotifiedState": "merged"
  }
]
JSONEOF
}

# Helper: create sample patterns file
create_sample_patterns() {
  cat > "$PATTERNS_FILE" << 'JSONLEOF'
{"ts":1772000000,"id":"proj-task-a","agent":"codex","model":"gpt-5.3-codex","retries":0,"success":true,"duration_s":600,"project":"proj","task_type":"feature","estimated_cost_usd":"1.20"}
{"ts":1772000100,"id":"proj-task-b","agent":"codex","model":"gpt-5.3-codex","retries":1,"success":true,"duration_s":900,"project":"proj","task_type":"feature","estimated_cost_usd":"1.80"}
{"ts":1772000200,"id":"proj-task-c","agent":"codex","model":"gpt-5.3-codex","retries":3,"success":false,"duration_s":300,"project":"proj","task_type":"feature","estimated_cost_usd":"0.60"}
{"ts":1772000300,"id":"proj-task-d","agent":"claude","model":"claude-sonnet-4-6","retries":0,"success":true,"duration_s":400,"project":"proj","task_type":"feature","estimated_cost_usd":"2.00"}
{"ts":1772000400,"id":"proj-task-e","agent":"claude","model":"claude-sonnet-4-6","retries":0,"success":true,"duration_s":500,"project":"proj","task_type":"feature","estimated_cost_usd":"2.50"}
{"ts":1772000500,"id":"proj-task-f","agent":"claude","model":"claude-sonnet-4-6","retries":2,"success":false,"duration_s":200,"project":"proj","task_type":"feature","estimated_cost_usd":"1.00"}
{"ts":1772000600,"id":"proj-task-g","agent":"gemini","model":"gemini-3.5-pro","retries":0,"success":true,"duration_s":350,"project":"proj","task_type":"design","estimated_cost_usd":"0.35"}
JSONLEOF
}

# Cleanup
teardown() {
  rm -rf "$FOUNDRY_TEST_DIR"
  rmdir "$REGISTRY_LOCKDIR" 2>/dev/null || true
}
