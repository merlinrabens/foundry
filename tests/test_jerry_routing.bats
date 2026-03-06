#!/usr/bin/env bats
# Tests for lib/jerry_routing.bash — Jerry's smart agent selection

setup() {
  unset _LIB_JERRY_ROUTING_LOADED _LIB_MODEL_ROUTING_LOADED
  export FOUNDRY_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  source "${FOUNDRY_DIR}/lib/model_routing.bash"
  source "${FOUNDRY_DIR}/lib/jerry_routing.bash"

  export CLAUDE_DEFAULT="claude-sonnet-4-6"
  export CLAUDE_COMPLEX="claude-opus-4-6"
  export CODEX_MODEL="gpt-5.3-codex"
  export CODEX_REASONING="high"
  export GEMINI_MODEL="gemini-3.5-pro"
}

# ── Hint-based routing ──

@test "explicit codex hint selects codex" {
  _jerry_select_agent "/tmp/repo" "any task" "codex"
  [ "$JERRY_BACKEND" = "codex" ]
}

@test "explicit claude hint selects claude" {
  _jerry_select_agent "/tmp/repo" "any task" "claude"
  [ "$JERRY_BACKEND" = "claude" ]
}

@test "explicit gemini hint selects gemini" {
  _jerry_select_agent "/tmp/repo" "any task" "gemini"
  [ "$JERRY_BACKEND" = "gemini" ]
}

@test "claude-complex hint selects claude" {
  _jerry_select_agent "/tmp/repo" "any task" "claude-complex"
  [ "$JERRY_BACKEND" = "claude" ]
  [ "$JERRY_MODEL" = "claude-complex" ]
}

@test "codex:medium hint selects codex" {
  _jerry_select_agent "/tmp/repo" "any task" "codex:medium"
  [ "$JERRY_BACKEND" = "codex" ]
}

# ── Content heuristic routing ──

@test "design keywords route to gemini" {
  _jerry_select_agent "/tmp/repo" "Redesign the landing page with beautiful visuals" "auto"
  [ "$JERRY_BACKEND" = "gemini" ]
}

@test "frontend file patterns route to claude" {
  _jerry_select_agent "/tmp/repo" "Build a React component in src/components/Button.tsx" "auto"
  [ "$JERRY_BACKEND" = "claude" ]
}

@test "styling keywords route to claude" {
  _jerry_select_agent "/tmp/repo" "Fix the frontend styling and add tailwind classes" "auto"
  [ "$JERRY_BACKEND" = "claude" ]
}

@test "backend task defaults to codex" {
  _jerry_select_agent "/tmp/repo" "Add a new API endpoint for user authentication" "auto"
  [ "$JERRY_BACKEND" = "codex" ]
}

@test "generic task defaults to codex" {
  _jerry_select_agent "/tmp/repo" "Fix the bug in the data pipeline" "auto"
  [ "$JERRY_BACKEND" = "codex" ]
}

@test "empty task content defaults to codex" {
  _jerry_select_agent "/tmp/repo" "" "auto"
  [ "$JERRY_BACKEND" = "codex" ]
}

# ── Pattern-based routing ──

@test "patterns best returns empty when no patterns file" {
  local result
  result=$(_jerry_patterns_best "/tmp/nonexistent-patterns.jsonl" "myproject")
  [ -z "$result" ]
}

@test "patterns best returns empty with insufficient data" {
  local tmpfile
  tmpfile=$(mktemp)
  echo '{"project":"myproject","agent":"codex","success":true}' > "$tmpfile"
  echo '{"project":"myproject","agent":"codex","success":true}' >> "$tmpfile"
  # Only 2 entries — below 3-entry threshold
  local result
  result=$(_jerry_patterns_best "$tmpfile" "myproject")
  [ -z "$result" ]
  rm -f "$tmpfile"
}

# ── Integration with model_routing ──

@test "openclaw resolves to jerry meta-backend" {
  detect_model_backend "openclaw"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "auto" ]
}

@test "openclaw:codex resolves to jerry with codex hint" {
  detect_model_backend "openclaw:codex"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]
  [ "$MODEL_OUT" = "codex" ]
}

@test "full jerry routing flow: openclaw → jerry → codex" {
  detect_model_backend "openclaw"
  [ "$AGENT_BACKEND_OUT" = "jerry" ]

  _jerry_select_agent "/tmp/repo" "Add database migration" "$MODEL_OUT"
  [ "$JERRY_BACKEND" = "codex" ]
}
