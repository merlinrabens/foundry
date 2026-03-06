#!/usr/bin/env bats
# Tests for CI template files: existence, structure, and deploy-ci.sh behavior

setup() {
  TEMPLATES_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../ci-templates" && pwd)"
}

# ============================================================================
# Template file existence
# ============================================================================

@test "claude-code-review.yml exists" {
  [ -f "$TEMPLATES_DIR/claude-code-review.yml" ]
}

@test "codex-review.yml exists" {
  [ -f "$TEMPLATES_DIR/codex-review.yml" ]
}

@test "gemini-check.yml exists" {
  [ -f "$TEMPLATES_DIR/gemini-check.yml" ]
}

@test "test-runner.yml exists" {
  [ -f "$TEMPLATES_DIR/test-runner.yml" ]
}

@test "visual-evidence.yml exists" {
  [ -f "$TEMPLATES_DIR/visual-evidence.yml" ]
}

@test "deploy-ci.sh exists and is executable" {
  [ -x "$TEMPLATES_DIR/deploy-ci.sh" ]
}

# ============================================================================
# Template content validation
# ============================================================================

@test "claude-code-review.yml triggers on pull_request" {
  grep -q "pull_request" "$TEMPLATES_DIR/claude-code-review.yml"
}

@test "codex-review.yml references OPENAI_API_KEY secret" {
  grep -q "OPENAI_API_KEY" "$TEMPLATES_DIR/codex-review.yml"
}

@test "claude-code-review.yml references CLAUDE_CODE_OAUTH_TOKEN secret" {
  grep -q "CLAUDE_CODE_OAUTH_TOKEN" "$TEMPLATES_DIR/claude-code-review.yml"
}

@test "visual-evidence.yml detects frontend changes" {
  grep -q "frontend" "$TEMPLATES_DIR/visual-evidence.yml"
}

@test "visual-evidence.yml uses Playwright" {
  grep -q "playwright" "$TEMPLATES_DIR/visual-evidence.yml"
}

@test "visual-evidence.yml captures desktop and mobile" {
  grep -q "1440" "$TEMPLATES_DIR/visual-evidence.yml"
  grep -qiE "mobile|iPhone" "$TEMPLATES_DIR/visual-evidence.yml"
}

@test "deploy-ci.sh includes all 5 templates" {
  run grep -c '\.yml"' "$TEMPLATES_DIR/deploy-ci.sh"
  [ "$output" -ge 5 ]
}

@test "all YAML templates are valid YAML" {
  for yml in "$TEMPLATES_DIR"/*.yml; do
    python3 -c "import yaml; yaml.safe_load(open('$yml'))" || return 1
  done
}

@test "deploy-ci.sh shows usage without args" {
  run bash "$TEMPLATES_DIR/deploy-ci.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}
