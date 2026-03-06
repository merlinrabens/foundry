#!/usr/bin/env bats
# Tests for queue scoring algorithm and recommend categorization

load test_helper

# ============================================================================
# Queue scoring — we test the scoring logic by creating sample spec files
# and exercising the frontmatter parsing + score computation
# ============================================================================

setup() {
  # Create a fake project with backlog specs
  export TEST_PROJECT="$FOUNDRY_TEST_DIR/myproject"
  mkdir -p "$TEST_PROJECT/specs/backlog"
  export KNOWN_PROJECTS=("$TEST_PROJECT")
  # Empty registry so nothing is "already started"
  echo '[]' > "$REGISTRY"
}

# Helper: create a spec file with given frontmatter
create_spec() {
  local name="$1" priority="$2" complexity="$3" depends="$4"
  local file="$TEST_PROJECT/specs/backlog/${name}.md"
  {
    [ -n "$priority" ] && echo "priority: $priority"
    [ -n "$complexity" ] && echo "estimated_complexity: $complexity"
    [ -n "$depends" ] && echo "depends_on: [$depends]"
    echo ""
    echo "# $name"
    echo "Task description here."
  } > "$file"
}

# Helper: compute score for a single spec (replicates queue scoring logic)
compute_score() {
  local spec_file="$1"
  local score=50
  local frontmatter
  frontmatter=$(head -20 "$spec_file")

  # Priority
  local priority
  priority=$(echo "$frontmatter" | grep -i "^priority:" | awk '{print $2}' | tr -d ' ' || true)
  case "$priority" in
    critical) score=$((score + 30)) ;;
    high)     score=$((score + 20)) ;;
    medium)   score=$((score + 10)) ;;
    low)      score=$((score + 0)) ;;
  esac

  # Spec number
  local spec_name
  spec_name=$(basename "$spec_file" .md)
  local num
  num=$(echo "$spec_name" | grep -o '^[0-9]*' || true)
  num=$(echo "$num" | sed 's/^0*//' || true)
  if [ -n "$num" ] && [ "$num" -gt 0 ]; then
    local num_bonus=$((100 - num))
    [ "$num_bonus" -lt 0 ] && num_bonus=0
    score=$((score + num_bonus))
  fi

  # Complexity
  local complexity
  complexity=$(echo "$frontmatter" | grep -i "^estimated_complexity:" | awk '{print $2}' | tr -d ' ' || true)
  case "$complexity" in
    small)  score=$((score + 10)) ;;
    medium) score=$((score + 5)) ;;
    large)  score=$((score + 0)) ;;
  esac

  # Dependencies (simplified: assume all ok for unit testing)
  score=$((score + 15))

  echo "$score"
}

@test "scoring: base score is 50" {
  create_spec "no-frontmatter" "" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/no-frontmatter.md")
  # 50 (base) + 15 (deps ok) = 65
  [ "$score" -eq 65 ]
}

@test "scoring: critical priority adds 30" {
  create_spec "task-critical" "critical" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-critical.md")
  # 50 + 30 + 15 = 95
  [ "$score" -eq 95 ]
}

@test "scoring: high priority adds 20" {
  create_spec "task-high" "high" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-high.md")
  # 50 + 20 + 15 = 85
  [ "$score" -eq 85 ]
}

@test "scoring: medium priority adds 10" {
  create_spec "task-medium" "medium" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-medium.md")
  # 50 + 10 + 15 = 75
  [ "$score" -eq 75 ]
}

@test "scoring: low priority adds 0" {
  create_spec "task-low" "low" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-low.md")
  # 50 + 0 + 15 = 65
  [ "$score" -eq 65 ]
}

@test "scoring: spec number 01 adds 99" {
  create_spec "01-first-task" "high" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/01-first-task.md")
  # 50 + 20(high) + 99(100-1) + 15(deps) = 184
  [ "$score" -eq 184 ]
}

@test "scoring: spec number 50 adds 50" {
  create_spec "50-middle-task" "" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/50-middle-task.md")
  # 50 + 50(100-50) + 15 = 115
  [ "$score" -eq 115 ]
}

@test "scoring: spec number 99 adds 1" {
  create_spec "99-last-task" "" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/99-last-task.md")
  # 50 + 1(100-99) + 15 = 66
  [ "$score" -eq 66 ]
}

@test "scoring: spec number > 100 gets 0 bonus" {
  create_spec "150-overflow" "" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/150-overflow.md")
  # 50 + 0(clamped) + 15 = 65
  [ "$score" -eq 65 ]
}

@test "scoring: small complexity adds 10" {
  create_spec "task-small" "" "small" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-small.md")
  # 50 + 10 + 15 = 75
  [ "$score" -eq 75 ]
}

@test "scoring: medium complexity adds 5" {
  create_spec "task-med-complex" "" "medium" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-med-complex.md")
  # 50 + 5 + 15 = 70
  [ "$score" -eq 70 ]
}

@test "scoring: large complexity adds 0" {
  create_spec "task-large" "" "large" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/task-large.md")
  # 50 + 0 + 15 = 65
  [ "$score" -eq 65 ]
}

@test "scoring: all bonuses combine correctly" {
  create_spec "01-top-priority" "critical" "small" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/01-top-priority.md")
  # 50 + 30(critical) + 99(spec#1) + 10(small) + 15(deps) = 204
  [ "$score" -eq 204 ]
}

@test "scoring: leading zeros in spec number handled" {
  create_spec "005-zero-padded" "" "" ""
  local score
  score=$(compute_score "$TEST_PROJECT/specs/backlog/005-zero-padded.md")
  # 50 + 95(100-5) + 15 = 160
  [ "$score" -eq 160 ]
}

# ============================================================================
# Recommend categorization
# ============================================================================

# Helper: categorize spec content (replicates recommend logic)
categorize() {
  local content="$1"
  local category="backend"
  if echo "$content" | grep -qi "component\|\.tsx\|\.jsx\|css\|tailwind\|frontend\|ui\|page\|layout\|styled\|theme\|responsive"; then
    category="frontend"
  fi
  if echo "$content" | grep -qi "design\|mockup\|visual\|wireframe\|beautiful\|animation\|aesthetic\|redesign\|landing page"; then
    category="design"
  fi
  if echo "$content" | grep -qi "test\|spec\|coverage\|e2e\|playwright\|jest\|vitest\|pytest"; then
    category="test"
  fi
  if echo "$content" | grep -qi "docs\|readme\|agents\.md\|documentation\|changelog\|jsdoc\|typedoc"; then
    category="docs"
  fi
  if echo "$content" | grep -qi "workflow\|ci\|deploy\|infra\|docker\|terraform\|github actions\|\.yml"; then
    category="infra"
  fi
  echo "$category"
}

@test "categorize: backend by default" {
  result=$(categorize "Add database migration for orders table")
  [ "$result" = "backend" ]
}

@test "categorize: frontend from TSX" {
  result=$(categorize "Create new ProductCard.tsx component with responsive layout")
  [ "$result" = "frontend" ]
}

@test "categorize: frontend from CSS" {
  result=$(categorize "Fix tailwind styling on the dashboard page")
  [ "$result" = "frontend" ]
}

@test "categorize: design from keywords" {
  result=$(categorize "Redesign the onboarding flow with beautiful animations")
  [ "$result" = "design" ]
}

@test "categorize: test from pytest" {
  result=$(categorize "Add pytest coverage for the auth module")
  [ "$result" = "test" ]
}

@test "categorize: test from e2e" {
  result=$(categorize "Write e2e tests with Playwright for checkout")
  [ "$result" = "test" ]
}

@test "categorize: docs from documentation" {
  result=$(categorize "Update README documentation with API examples")
  [ "$result" = "docs" ]
}

@test "categorize: docs from agents.md" {
  result=$(categorize "Slim down AGENTS.md to reduce token overhead")
  [ "$result" = "docs" ]
}

@test "categorize: infra from CI" {
  result=$(categorize "Set up GitHub Actions CI workflow for the repo")
  [ "$result" = "infra" ]
}

@test "categorize: infra from Docker" {
  result=$(categorize "Create Docker compose for local development")
  [ "$result" = "infra" ]
}

@test "categorize: later match overrides (infra overrides test)" {
  # "infra" keywords checked AFTER "test", so infra wins
  result=$(categorize "Add CI workflow for running tests")
  [ "$result" = "infra" ]
}

# ============================================================================
# Agent requirement detection
# ============================================================================

detect_required_agent() {
  local content="$1"
  local required=""
  if echo "$content" | grep -qi "supabase\|database query\|rls\|row level security\|mcp\|playwright browser"; then
    required="claude"
  fi
  if echo "$content" | grep -qi "beautiful.*dashboard\|redesign.*onboarding\|new.*landing.*page\|visual.*overhaul\|ui.*polish"; then
    required="gemini"
  fi
  echo "$required"
}

@test "required_agent: MCP task requires claude" {
  result=$(detect_required_agent "Add Supabase RLS policies for the orders table")
  [ "$result" = "claude" ]
}

@test "required_agent: Playwright requires claude" {
  result=$(detect_required_agent "Use Playwright browser to test login flow")
  [ "$result" = "claude" ]
}

@test "required_agent: design-heavy requires gemini" {
  result=$(detect_required_agent "Redesign the onboarding flow with beautiful animations")
  [ "$result" = "gemini" ]
}

@test "required_agent: landing page requires gemini" {
  result=$(detect_required_agent "Create a new landing page for the product")
  [ "$result" = "gemini" ]
}

@test "required_agent: normal backend has no requirement" {
  result=$(detect_required_agent "Fix the payment processing logic")
  [ "$result" = "" ]
}
