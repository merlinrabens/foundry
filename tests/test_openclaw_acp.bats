#!/usr/bin/env bats
# Tests for openclaw → jerry routing (formerly OpenClaw ACP backend)

setup() {
  export FOUNDRY_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REGISTRY_DB="/tmp/foundry-test-openclaw-$$.db"
  export USE_SQLITE_REGISTRY="true"

  # Source just what we need
  unset _LIB_MODEL_ROUTING_LOADED _LIB_JERRY_ROUTING_LOADED
  source "${FOUNDRY_DIR}/lib/model_routing.bash"
  source "${FOUNDRY_DIR}/lib/jerry_routing.bash"
}

teardown() {
  rm -f "$REGISTRY_DB" "${REGISTRY_DB}-wal" "${REGISTRY_DB}-shm"
}

# ── Model Routing: openclaw → jerry ──

@test "openclaw routes to jerry meta-backend" {
  detect_model_backend "openclaw"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
}

@test "openclaw model defaults to 'auto'" {
  detect_model_backend "openclaw"
  [ "$MODEL_OUT" = "auto" ]
}

@test "openclaw:codex passes hint through" {
  detect_model_backend "openclaw:codex"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "codex" ]
}

@test "openclaw:claude passes hint through" {
  detect_model_backend "openclaw:claude"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "claude" ]
}

@test "openclaw:gemini passes hint through" {
  detect_model_backend "openclaw:gemini"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "gemini" ]
}

@test "openclaw does not interfere with codex routing" {
  detect_model_backend "codex"
  [ "$AGENT_BACKEND_OUT" = "codex" ]
}

@test "openclaw does not interfere with claude routing" {
  detect_model_backend "claude"
  [ "$AGENT_BACKEND_OUT" = "claude" ]
}

@test "openclaw does not interfere with gemini routing" {
  detect_model_backend "gemini"
  [ "$AGENT_BACKEND_OUT" = "gemini" ]
}

# ── Jerry routing with hints ──

@test "jerry resolves openclaw:codex hint to codex backend" {
  _jerry_select_agent "/tmp/repo" "build something" "codex"
  [ "$JERRY_BACKEND" = "codex" ]
}

@test "jerry resolves openclaw:claude hint to claude backend" {
  _jerry_select_agent "/tmp/repo" "build something" "claude"
  [ "$JERRY_BACKEND" = "claude" ]
}

@test "jerry resolves openclaw:gemini hint to gemini backend" {
  _jerry_select_agent "/tmp/repo" "build something" "gemini"
  [ "$JERRY_BACKEND" = "gemini" ]
}

# ── ACP adapter: openclaw no longer valid ──

@test "acp_orchestrator rejects openclaw as backend" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  run python3 "$real_dir/lib/acp_orchestrator.py" \
    --backend openclaw --model default --worktree /tmp --log-file /tmp/l --done-file /tmp/d
  [ "$status" -ne 0 ]
}

@test "acp_orchestrator accepts only claude, codex, gemini" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  run python3 "$real_dir/lib/acp_orchestrator.py" --help
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"gemini"* ]]
  [[ "$output" != *"openclaw"* ]]
}

# ── Startup Drain (kept — still used by other adapters) ──

@test "STARTUP_DRAIN_TIMEOUT constant exists" {
  local result
  result=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$(dirname "$BATS_TEST_FILENAME")', '..', 'lib'))
from acp_orchestrator import STARTUP_DRAIN_TIMEOUT
print(STARTUP_DRAIN_TIMEOUT)
")
  [ "$result" -gt 0 ]
}

# ── Backend unchanged ──

@test "codex adapter args unchanged" {
  local result
  result=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$(dirname "$BATS_TEST_FILENAME")', '..', 'lib'))
from acp_orchestrator import get_adapter_args
print(' '.join(get_adapter_args('codex', 'gpt-5.3-codex', '/tmp/wt')))
")
  [[ "$result" == "codex-acp"* ]]
}

@test "claude adapter args unchanged" {
  local result
  result=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$(dirname "$BATS_TEST_FILENAME")', '..', 'lib'))
from acp_orchestrator import get_adapter_args
print(' '.join(get_adapter_args('claude', 'claude-sonnet-4-6', '/tmp/wt')))
")
  [[ "$result" == "claude-agent-acp"* ]]
}
