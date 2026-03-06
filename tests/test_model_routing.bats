#!/usr/bin/env bats
# Tests for lib/model_routing.bash — Model string → backend resolution

setup() {
  # Clear the loaded guard so re-sourcing works across tests
  unset _LIB_MODEL_ROUTING_LOADED
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/model_routing.bash"

  # Set config defaults (same as test_helper.bash)
  export CLAUDE_DEFAULT="claude-sonnet-4-6"
  export CLAUDE_COMPLEX="claude-opus-4-6"
  export CODEX_MODEL="gpt-5.3-codex"
  export CODEX_REASONING="high"
  export GEMINI_MODEL="gemini-3.5-pro"
}

# ── Codex backend ──

@test "codex → backend=codex, model=CODEX_MODEL" {
  detect_model_backend "codex"
  [ "$AGENT_BACKEND_OUT" = "codex" ]
  [ "$MODEL_OUT" = "gpt-5.3-codex" ]
}

@test "codex:medium → backend=codex, reasoning=medium" {
  detect_model_backend "codex:medium"
  [ "$AGENT_BACKEND_OUT" = "codex" ]
  [ "$MODEL_OUT" = "gpt-5.3-codex" ]
  [ "$CODEX_REASONING_OUT" = "medium" ]
}

@test "codex:high → backend=codex, reasoning=high" {
  detect_model_backend "codex:high"
  [ "$AGENT_BACKEND_OUT" = "codex" ]
  [ "$CODEX_REASONING_OUT" = "high" ]
}

@test "codex without colon preserves default CODEX_REASONING" {
  export CODEX_REASONING="low"
  detect_model_backend "codex"
  [ "$AGENT_BACKEND_OUT" = "codex" ]
  [ "$CODEX_REASONING_OUT" = "low" ]
}

# ── Claude backend ──

@test "claude → backend=claude, model=CLAUDE_DEFAULT" {
  detect_model_backend "claude"
  [ "$AGENT_BACKEND_OUT" = "claude" ]
  [ "$MODEL_OUT" = "claude-sonnet-4-6" ]
}

@test "claude-complex → backend=claude, model=CLAUDE_COMPLEX" {
  detect_model_backend "claude-complex"
  [ "$AGENT_BACKEND_OUT" = "claude" ]
  [ "$MODEL_OUT" = "claude-opus-4-6" ]
}

# ── Gemini backend ──

@test "gemini → backend=gemini, model=GEMINI_MODEL" {
  detect_model_backend "gemini"
  [ "$AGENT_BACKEND_OUT" = "gemini" ]
  [ "$MODEL_OUT" = "gemini-3.5-pro" ]
  [ "$GEMINI_MODEL_OUT" = "gemini-3.5-pro" ]
}

@test "gemini:custom-model → backend=gemini, model=custom-model" {
  detect_model_backend "gemini:custom-model"
  [ "$AGENT_BACKEND_OUT" = "gemini" ]
  [ "$MODEL_OUT" = "custom-model" ]
  [ "$GEMINI_MODEL_OUT" = "custom-model" ]
}

@test "gemini without colon preserves default GEMINI_MODEL" {
  export GEMINI_MODEL="gemini-2.5-flash"
  detect_model_backend "gemini"
  [ "$AGENT_BACKEND_OUT" = "gemini" ]
  [ "$MODEL_OUT" = "gemini-2.5-flash" ]
  [ "$GEMINI_MODEL_OUT" = "gemini-2.5-flash" ]
}

# ── Passthrough / fallback ──

@test "explicit claude-sonnet-4-6 → backend=claude, model passthrough" {
  detect_model_backend "claude-sonnet-4-6"
  [ "$AGENT_BACKEND_OUT" = "claude" ]
  [ "$MODEL_OUT" = "claude-sonnet-4-6" ]
}

@test "empty string → backend=claude (fallback)" {
  detect_model_backend ""
  [ "$AGENT_BACKEND_OUT" = "claude" ]
}

@test "unknown model string → backend=claude, model=passthrough" {
  detect_model_backend "some-random-model-v3"
  [ "$AGENT_BACKEND_OUT" = "claude" ]
  [ "$MODEL_OUT" = "some-random-model-v3" ]
}

# ── OpenClaw → Jerry routing ──

@test "openclaw → backend=jerry, model=auto" {
  detect_model_backend "openclaw"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "auto" ]
}

@test "openclaw:codex → backend=jerry, model=codex" {
  detect_model_backend "openclaw:codex"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "codex" ]
}

@test "openclaw:claude → backend=jerry, model=claude" {
  detect_model_backend "openclaw:claude"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "claude" ]
}

@test "openclaw without colon sets model=auto" {
  detect_model_backend "openclaw"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "auto" ]
}
