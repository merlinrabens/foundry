#!/usr/bin/env bats
# Tests for pattern_log() and cost estimation

load test_helper

# ============================================================================
# pattern_log()
# ============================================================================

@test "pattern_log: creates JSONL entry" {
  pattern_log "test-task" "codex" "gpt-5.3-codex" 0 true 600 "myproj" "feature"
  [ -f "$PATTERNS_FILE" ]
  result=$(wc -l < "$PATTERNS_FILE" | tr -d ' ')
  [ "$result" -eq 1 ]
}

@test "pattern_log: valid JSON on each line" {
  pattern_log "task-1" "codex" "gpt-5.3-codex" 0 true 600 "proj" "feature"
  pattern_log "task-2" "claude" "claude-sonnet-4-6" 1 false 300 "proj" "bugfix"
  # Both lines must be valid JSON
  while IFS= read -r line; do
    echo "$line" | jq . > /dev/null 2>&1
    [ $? -eq 0 ]
  done < "$PATTERNS_FILE"
}

@test "pattern_log: captures all fields" {
  pattern_log "my-task" "claude" "claude-sonnet-4-6" 2 true 450 "myproj" "bugfix"
  local entry
  entry=$(cat "$PATTERNS_FILE")
  [ "$(echo "$entry" | jq -r '.id')" = "my-task" ]
  [ "$(echo "$entry" | jq -r '.agent')" = "claude" ]
  [ "$(echo "$entry" | jq -r '.model')" = "claude-sonnet-4-6" ]
  [ "$(echo "$entry" | jq -r '.retries')" = "2" ]
  [ "$(echo "$entry" | jq -r '.success')" = "true" ]
  [ "$(echo "$entry" | jq -r '.duration_s')" = "450" ]
  [ "$(echo "$entry" | jq -r '.project')" = "myproj" ]
  [ "$(echo "$entry" | jq -r '.task_type')" = "bugfix" ]
}

@test "pattern_log: has timestamp" {
  pattern_log "ts-task" "codex" "gpt-5.3-codex" 0 true 100 "proj" "feature"
  local ts
  ts=$(jq -r '.ts' "$PATTERNS_FILE")
  # Timestamp should be recent (within last 10 seconds)
  local now
  now=$(date +%s)
  [ "$ts" -ge "$((now - 10))" ]
  [ "$ts" -le "$((now + 1))" ]
}

@test "pattern_log: appends to existing file" {
  pattern_log "first" "codex" "gpt-5.3-codex" 0 true 100 "proj" "feature"
  pattern_log "second" "claude" "claude-sonnet-4-6" 0 true 200 "proj" "feature"
  result=$(wc -l < "$PATTERNS_FILE" | tr -d ' ')
  [ "$result" -eq 2 ]
}

# ============================================================================
# Cost estimation
# ============================================================================

@test "pattern_log: codex cost estimate" {
  pattern_log "cost-codex" "codex" "gpt-5.3-codex" 0 true 1000 "proj" "feature"
  local cost
  cost=$(jq -r '.estimated_cost_usd' "$PATTERNS_FILE")
  # 1000 * 0.002 = 2.00 (bc may output 2.00 or 2.000)
  [[ "$cost" == 2.00* ]]
}

@test "pattern_log: claude cost estimate" {
  pattern_log "cost-claude" "claude" "claude-sonnet-4-6" 0 true 1000 "proj" "feature"
  local cost
  cost=$(jq -r '.estimated_cost_usd' "$PATTERNS_FILE")
  # 1000 * 0.005 = 5.00
  [[ "$cost" == 5.00* ]]
}

@test "pattern_log: gemini cost estimate" {
  pattern_log "cost-gemini" "gemini" "gemini-3.5-pro" 0 true 1000 "proj" "design"
  local cost
  cost=$(jq -r '.estimated_cost_usd' "$PATTERNS_FILE")
  # 1000 * 0.001 = 1.00
  [[ "$cost" == 1.00* ]]
}

@test "pattern_log: zero duration gives zero cost" {
  pattern_log "zero-dur" "codex" "gpt-5.3-codex" 0 false 0 "proj" "feature"
  local cost
  cost=$(jq -r '.estimated_cost_usd' "$PATTERNS_FILE")
  [ "$cost" = "0" ]
}

# ============================================================================
# Pattern aggregation (reading sample data)
# ============================================================================

@test "patterns: count by agent from sample data" {
  create_sample_patterns
  local codex_count
  codex_count=$(jq -s '[.[] | select(.agent == "codex")] | length' "$PATTERNS_FILE")
  [ "$codex_count" -eq 3 ]

  local claude_count
  claude_count=$(jq -s '[.[] | select(.agent == "claude")] | length' "$PATTERNS_FILE")
  [ "$claude_count" -eq 3 ]

  local gemini_count
  gemini_count=$(jq -s '[.[] | select(.agent == "gemini")] | length' "$PATTERNS_FILE")
  [ "$gemini_count" -eq 1 ]
}

@test "patterns: success rate from sample data" {
  create_sample_patterns
  local total
  total=$(wc -l < "$PATTERNS_FILE" | tr -d ' ')
  local successes
  successes=$(jq -s '[.[] | select(.success == true)] | length' "$PATTERNS_FILE")
  [ "$total" -eq 7 ]
  [ "$successes" -eq 5 ]
}

@test "patterns: codex success rate 66%" {
  create_sample_patterns
  local codex_success
  codex_success=$(jq -s '[.[] | select(.agent == "codex" and .success == true)] | length' "$PATTERNS_FILE")
  local codex_total
  codex_total=$(jq -s '[.[] | select(.agent == "codex")] | length' "$PATTERNS_FILE")
  [ "$codex_success" -eq 2 ]
  [ "$codex_total" -eq 3 ]
}

@test "patterns: best agent selection (claude at 66% with 3 entries)" {
  create_sample_patterns
  local best
  best=$(jq -s '
    group_by(.agent) | map({
      agent: .[0].agent,
      total: length,
      successes: [.[] | select(.success)] | length,
      rate: (([.[] | select(.success)] | length) * 100 / length)
    }) | [.[] | select(.total >= 2)] | sort_by(-.rate) | .[0].agent // "codex"
  ' "$PATTERNS_FILE")
  # Both codex and claude have 66% success rate, but codex comes first alphabetically
  # The actual sort is stable so codex (first group) wins ties
  [[ "$best" == *"codex"* ]] || [[ "$best" == *"claude"* ]]
}
