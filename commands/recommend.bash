# commands/recommend.bash — Pattern-driven model routing recommendation

cmd_recommend() {
  local spec_input="$1"

  if [ -z "$spec_input" ]; then
    echo "Usage: foundry recommend <spec-file | task-description>"
    echo ""
    echo "Analyzes the task and recommends the best model based on:"
    echo "  1. Task category (frontend, backend, infra, design, docs, test)"
    echo "  2. Historical success rates from patterns.jsonl"
    echo "  3. Agent capability matching (MCP, design, etc.)"
    echo ""
    echo "Examples:"
    echo "  foundry recommend specs/backlog/05-dashboard.md"
    echo "  foundry recommend 'Add Supabase RLS policies for orders table'"
    echo "  foundry recommend 'Redesign the onboarding flow with beautiful animations'"
    return 1
  fi

  # Get spec content
  local spec_content
  if [ -f "$spec_input" ]; then
    spec_content=$(cat "$spec_input")
    log "Analyzing spec: $(basename "$spec_input")"
  else
    spec_content="$spec_input"
    log "Analyzing task description..."
  fi

  echo ""

  # ── Categorize by keywords ──
  local category="backend"  # default
  if echo "$spec_content" | grep -qi "component\|\.tsx\|\.jsx\|css\|tailwind\|frontend\|ui\|page\|layout\|styled\|theme\|responsive"; then
    category="frontend"
  fi
  if echo "$spec_content" | grep -qi "design\|mockup\|visual\|wireframe\|beautiful\|animation\|aesthetic\|redesign\|landing page"; then
    category="design"
  fi
  if echo "$spec_content" | grep -qi "test\|spec\|coverage\|e2e\|playwright\|jest\|vitest\|pytest"; then
    category="test"
  fi
  if echo "$spec_content" | grep -qi "docs\|readme\|agents\.md\|documentation\|changelog\|jsdoc\|typedoc"; then
    category="docs"
  fi
  if echo "$spec_content" | grep -qi "workflow\|ci\|deploy\|infra\|docker\|terraform\|github actions\|\.yml"; then
    category="infra"
  fi

  log "Category: ${BOLD}${category}${NC}"

  # ── Agent capability matching ──
  # Some tasks REQUIRE specific agents regardless of success rates
  local required_agent=""
  local requirement_reason=""

  # MCP-dependent tasks -> must use Claude
  if echo "$spec_content" | grep -qi "supabase\|database query\|rls\|row level security\|mcp\|playwright browser"; then
    required_agent="claude"
    requirement_reason="Task requires MCP server access (Supabase/Playwright) — only Claude supports MCP"
  fi

  # Design-heavy tasks -> Gemini first
  if echo "$spec_content" | grep -qi "beautiful.*dashboard\|redesign.*onboarding\|new.*landing.*page\|visual.*overhaul\|ui.*polish"; then
    required_agent="gemini"
    requirement_reason="Design-heavy task — Gemini has best visual/design sensibility"
  fi

  if [ -n "$required_agent" ]; then
    echo ""
    log "${BOLD}REQUIRED:${NC} $required_agent"
    log "Reason: $requirement_reason"
    echo ""

    # Print the recommended command
    local model_flag="$required_agent"
    [ "$required_agent" = "claude" ] && model_flag="claude"
    [ "$required_agent" = "gemini" ] && model_flag="gemini"
    [ "$required_agent" = "codex" ] && model_flag="codex"
    log "Recommended: foundry spawn <repo> <spec> ${BOLD}${model_flag}${NC}"
    return 0
  fi

  # ── Query patterns.jsonl for success rates ──
  local has_patterns=false
  if [ -f "$PATTERNS_FILE" ] && [ -s "$PATTERNS_FILE" ]; then
    has_patterns=true
  fi

  if [ "$has_patterns" = "true" ]; then
    echo ""
    log "${BOLD}Historical success rates by agent:${NC}"
    echo ""

    # Per-agent stats
    for a in codex claude gemini; do
      local a_total a_success a_rate avg_dur
      a_total=$(jq -s "[.[] | select(.agent == \"$a\")] | length" "$PATTERNS_FILE" 2>/dev/null || echo "0")
      if [ "$a_total" -gt 0 ]; then
        a_success=$(jq -s "[.[] | select(.agent == \"$a\" and .success == true)] | length" "$PATTERNS_FILE")
        a_rate=$((a_success * 100 / a_total))
        avg_dur=$(jq -s "[.[] | select(.agent == \"$a\" and .success == true)] | if length > 0 then (map(.duration_s) | add / length | . / 60 | . * 10 | floor / 10) else 0 end" "$PATTERNS_FILE")
        printf "  %-10s %d/%d (%d%%) success | avg %sm per success\n" "$a" "$a_success" "$a_total" "$a_rate" "$avg_dur"
      else
        printf "  %-10s (no data)\n" "$a"
      fi
    done

    echo ""

    # Find best agent from patterns (highest success rate with at least 2 data points)
    local best_agent best_rate
    best_agent=$(jq -s '
      group_by(.agent) | map({
        agent: .[0].agent,
        total: length,
        successes: [.[] | select(.success)] | length,
        rate: (([.[] | select(.success)] | length) * 100 / length)
      }) | [.[] | select(.total >= 2)] | sort_by(-.rate) | .[0].agent // "codex"
    ' "$PATTERNS_FILE" 2>/dev/null || echo "codex")
    best_rate=$(jq -s "
      group_by(.agent) | map({
        agent: .[0].agent,
        total: length,
        rate: (([.[] | select(.success)] | length) * 100 / length)
      }) | [.[] | select(.total >= 2)] | sort_by(-.rate) | .[0].rate // 0
    " "$PATTERNS_FILE" 2>/dev/null || echo "0")

    log "Best overall: ${BOLD}${best_agent}${NC} (${best_rate}% success rate)"
  else
    log "No pattern data yet — using capability-based routing."
  fi

  # ── Final recommendation based on category + capabilities ──
  echo ""
  local recommended="codex"
  local rec_reason="Default workhorse — backend, refactors, bugs"

  case "$category" in
    frontend)
      recommended="claude"
      rec_reason="Frontend code — Claude handles TSX/CSS/components well"
      ;;
    design)
      recommended="gemini"
      rec_reason="Design-heavy task — use Gemini design pipeline (foundry design)"
      ;;
    docs)
      recommended="codex"
      rec_reason="Documentation — Codex is fast and cheap for docs"
      ;;
    test)
      recommended="codex"
      rec_reason="Tests — Codex handles test writing reliably"
      ;;
    infra)
      recommended="codex"
      rec_reason="Infrastructure/CI — Codex handles workflow files well"
      ;;
    backend)
      recommended="codex"
      rec_reason="Backend logic — Codex is the workhorse"
      ;;
  esac

  log "${BOLD}Recommendation: ${recommended}${NC}"
  log "Reason: ${rec_reason}"
  echo ""

  # Print the recommended command
  if [ "$category" = "design" ]; then
    log "Recommended: foundry design <repo> <spec>"
  else
    log "Recommended: foundry spawn <repo> <spec> ${BOLD}${recommended}${NC}"
  fi
}
