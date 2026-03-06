#!/bin/bash
# lib/jerry_routing.bash — Foundry smart agent selection
# Resolves the "auto" meta-backend into a concrete backend (codex/claude/gemini).
[[ -n "${_LIB_JERRY_ROUTING_LOADED:-}" ]] && return 0
_LIB_JERRY_ROUTING_LOADED=1

# _jerry_select_agent <repo_dir> <task_content> <model_hint>
#
# Sets in caller's scope:
#   JERRY_BACKEND  — resolved backend: "codex", "claude", or "gemini"
#   JERRY_MODEL    — resolved model string for detect_model_backend
#
# Decision order:
#   1. If model_hint is a known backend name (codex/claude/gemini), use it directly
#   2. Check patterns DB for repo's best-performing agent (if enough data)
#   3. Heuristic: classify task content by file patterns / keywords
#   4. Default: codex (the workhorse)
_jerry_select_agent() {
  local repo_dir="$1" task_content="$2" model_hint="${3:-auto}"

  JERRY_BACKEND=""
  JERRY_MODEL=""

  # ── 1. Respect explicit hints ──
  case "$model_hint" in
    codex|codex:*)
      JERRY_BACKEND="codex"
      JERRY_MODEL="codex"
      return 0
      ;;
    claude|claude:*|claude-complex)
      JERRY_BACKEND="claude"
      JERRY_MODEL="$model_hint"
      return 0
      ;;
    gemini|gemini:*)
      JERRY_BACKEND="gemini"
      JERRY_MODEL="$model_hint"
      return 0
      ;;
  esac

  # ── 2. Pattern-based selection (if patterns DB available) ──
  local project_name
  project_name=$(basename "$repo_dir" 2>/dev/null || echo "unknown")
  local patterns_file="${FOUNDRY_DIR}/patterns.jsonl"

  if [ -f "$patterns_file" ] && command -v jq >/dev/null 2>&1; then
    local best_agent
    best_agent=$(_jerry_patterns_best "$patterns_file" "$project_name")
    if [ -n "$best_agent" ]; then
      JERRY_BACKEND="$best_agent"
      JERRY_MODEL="$best_agent"
      return 0
    fi
  fi

  # ── 3. Content heuristic ──
  local content_lower
  content_lower=$(echo "$task_content" | tr '[:upper:]' '[:lower:]')

  # Design / UI polish → gemini
  if echo "$content_lower" | grep -qE '(beautiful|redesign|landing page|visual|design system|look.and.feel|polish|aesthetic)'; then
    JERRY_BACKEND="gemini"
    JERRY_MODEL="gemini"
    return 0
  fi

  # Frontend-heavy → claude
  if echo "$content_lower" | grep -qE '\.(tsx|jsx|vue|svelte|css|scss)\b|react component|frontend|styling|tailwind|ui component'; then
    JERRY_BACKEND="claude"
    JERRY_MODEL="claude"
    return 0
  fi

  # ── 4. Default: codex ──
  JERRY_BACKEND="codex"
  JERRY_MODEL="codex"
}

# _jerry_patterns_best <patterns_file> <project_name>
# Query patterns.jsonl for the agent with highest success rate for this project.
# Requires at least 3 completed tasks to have signal. Echoes agent name or empty.
_jerry_patterns_best() {
  local patterns_file="$1" project="$2"

  # jq: group by agent, filter project, compute success rate, pick best
  local result
  result=$(jq -r --arg proj "$project" '
    select(.project == $proj)
  ' "$patterns_file" 2>/dev/null | jq -s '
    group_by(.agent)
    | map(select(length >= 3))
    | map({
        agent: .[0].agent,
        success_rate: ([.[] | select(.success)] | length) / length
      })
    | sort_by(-.success_rate)
    | .[0].agent // empty
  ' 2>/dev/null)

  echo "$result"
}
