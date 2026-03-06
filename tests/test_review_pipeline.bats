#!/usr/bin/env bats
# Tests for lib/review_pipeline.bash — PR review parsing and workflow check filtering

setup() {
  unset _LIB_REVIEW_PIPELINE_LOADED
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/review_pipeline.bash"
}

# ── parse_latest_reviews ──

@test "parse_latest_reviews: single reviewer → returns their state" {
  local json='[{"author":{"login":"alice"},"state":"APPROVED","submittedAt":"2026-02-28T10:00:00Z"}]'
  run parse_latest_reviews "$json"
  [ "$status" -eq 0 ]
  local login state
  login=$(echo "$output" | jq -r '.[0].login')
  state=$(echo "$output" | jq -r '.[0].state')
  [ "$login" = "alice" ]
  [ "$state" = "APPROVED" ]
}

@test "parse_latest_reviews: multiple reviews from same reviewer → latest wins" {
  local json='[
    {"author":{"login":"alice"},"state":"CHANGES_REQUESTED","submittedAt":"2026-02-28T10:00:00Z"},
    {"author":{"login":"alice"},"state":"APPROVED","submittedAt":"2026-02-28T11:00:00Z"}
  ]'
  run parse_latest_reviews "$json"
  [ "$status" -eq 0 ]
  local count state
  count=$(echo "$output" | jq 'length')
  state=$(echo "$output" | jq -r '.[0].state')
  [ "$count" -eq 1 ]
  [ "$state" = "APPROVED" ]
}

@test "parse_latest_reviews: multiple reviewers → one entry each" {
  local json='[
    {"author":{"login":"alice"},"state":"APPROVED","submittedAt":"2026-02-28T10:00:00Z"},
    {"author":{"login":"bob"},"state":"COMMENTED","submittedAt":"2026-02-28T10:30:00Z"}
  ]'
  run parse_latest_reviews "$json"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 2 ]
}

@test "parse_latest_reviews: empty array → empty array" {
  run parse_latest_reviews "[]"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | jq 'length')
  [ "$count" -eq 0 ]
}

@test "parse_latest_reviews: malformed JSON → fallback []" {
  run parse_latest_reviews "not valid json at all"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "parse_latest_reviews: DISMISSED reviews are excluded → no false respawn" {
  # Real scenario: codex requested changes, human dismissed it. GitHub API marks
  # the review state as DISMISSED. Without filtering, the dismissed review would
  # still trigger a respawn on already-fixed code.
  local json='[
    {"author":{"login":"codex"},"state":"DISMISSED","submittedAt":"2026-03-01T10:00:00Z"},
    {"author":{"login":"claude[bot]"},"state":"APPROVED","submittedAt":"2026-03-01T11:00:00Z"}
  ]'
  run parse_latest_reviews "$json"
  [ "$status" -eq 0 ]
  # codex's only review was DISMISSED → codex should be absent from results
  local codex_count
  codex_count=$(echo "$output" | jq '[.[] | select(.login == "codex")] | length')
  [ "$codex_count" -eq 0 ]
  local claude_state
  claude_state=$(echo "$output" | jq -r '.[] | select(.login == "claude[bot]") | .state')
  [ "$claude_state" = "APPROVED" ]
}

@test "parse_latest_reviews: DISMISSED then re-reviewed → latest non-dismissed wins" {
  local json='[
    {"author":{"login":"codex"},"state":"DISMISSED","submittedAt":"2026-03-01T10:00:00Z"},
    {"author":{"login":"codex"},"state":"APPROVED","submittedAt":"2026-03-01T14:00:00Z"}
  ]'
  run parse_latest_reviews "$json"
  [ "$status" -eq 0 ]
  local codex_state
  codex_state=$(echo "$output" | jq -r '.[] | select(.login == "codex") | .state')
  [ "$codex_state" = "APPROVED" ]
}

# ── get_reviewer_state ──

@test "get_reviewer_state: claude[bot] APPROVED → APPROVED" {
  local reviews='[{"login":"claude[bot]","state":"APPROVED"},{"login":"codex[bot]","state":"COMMENTED"}]'
  run get_reviewer_state "$reviews" '.login == "claude[bot]"'
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVED" ]
}

@test "get_reviewer_state: no matching reviewer → empty string" {
  local reviews='[{"login":"alice","state":"APPROVED"}]'
  run get_reviewer_state "$reviews" '.login == "nonexistent"'
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "get_reviewer_state: CHANGES_REQUESTED → CHANGES_REQUESTED" {
  local reviews='[{"login":"codex[bot]","state":"CHANGES_REQUESTED"}]'
  run get_reviewer_state "$reviews" '.login == "codex[bot]"'
  [ "$status" -eq 0 ]
  [ "$output" = "CHANGES_REQUESTED" ]
}

# ── detect_gemini_approval ──

@test "detect_gemini_approval: empty state → approved (return 0)" {
  run detect_gemini_approval ""
  [ "$status" -eq 0 ]
}

@test "detect_gemini_approval: check SUCCESS but has findings → NOT approved" {
  run detect_gemini_approval "COMMENTED" "2" "SUCCESS"
  [ "$status" -eq 1 ]
}

@test "detect_gemini_approval: check SUCCESS + 0 findings → approved" {
  run detect_gemini_approval "COMMENTED" "0" "SUCCESS"
  [ "$status" -eq 0 ]
}

@test "detect_gemini_approval: COMMENTED + 0 findings → approved" {
  run detect_gemini_approval "COMMENTED" "0" ""
  [ "$status" -eq 0 ]
}

@test "detect_gemini_approval: COMMENTED + 3 findings → not approved (return 1)" {
  run detect_gemini_approval "COMMENTED" "3" ""
  [ "$status" -eq 1 ]
}

@test "detect_gemini_approval: COMMENTED + no check + 0 findings → approved" {
  run detect_gemini_approval "COMMENTED" "0"
  [ "$status" -eq 0 ]
}

@test "detect_gemini_approval: low-priority finding (1 inline) → NOT approved" {
  run detect_gemini_approval "COMMENTED" "1" "SUCCESS"
  [ "$status" -eq 1 ]
}

# ── filter_workflow_checks ──

@test "filter_workflow_checks: no failures → 0" {
  local checks='[{"name":"build","state":"SUCCESS"},{"name":"test","state":"SUCCESS"}]'
  run filter_workflow_checks "$checks" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "filter_workflow_checks: 2 failures, no workflow mod → 2" {
  local checks='[{"name":"build","state":"FAILURE"},{"name":"claude-review","state":"FAILURE"}]'
  run filter_workflow_checks "$checks" "0"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "filter_workflow_checks: 2 failures (1 is claude-review), workflow mod → 1 (excluded)" {
  local checks='[{"name":"build","state":"FAILURE"},{"name":"claude-review","state":"FAILURE"}]'
  run filter_workflow_checks "$checks" "1"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

# ── count_pending_checks ──

@test "count_pending_checks: 0 pending → 0" {
  local checks='[{"name":"build","state":"SUCCESS"},{"name":"test","state":"FAILURE"}]'
  run count_pending_checks "$checks"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "count_pending_checks: 3 pending → 3" {
  local checks='[{"name":"a","state":"PENDING"},{"name":"b","state":"QUEUED"},{"name":"c","state":"PENDING"}]'
  run count_pending_checks "$checks"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# ── classify_failed_checks ──

@test "classify_failed_checks: Railway deploy fail (workflow='') → deploy_fails=1, ci_fails=0" {
  local checks='[
    {"name":"Aura AI Assistant","state":"FAILURE","workflow":""},
    {"name":"Unit Tests","state":"SUCCESS","workflow":"Backend Tests"}
  ]'
  run classify_failed_checks "$checks"
  [ "$status" -eq 0 ]
  local df cf dn
  df=$(echo "$output" | jq -r '.deploy_fails')
  cf=$(echo "$output" | jq -r '.ci_fails')
  dn=$(echo "$output" | jq -r '.deploy_names')
  [ "$df" = "1" ]
  [ "$cf" = "0" ]
  [ "$dn" = "Aura AI Assistant" ]
}

@test "classify_failed_checks: CI test fail (workflow set) → deploy_fails=0, ci_fails=1" {
  local checks='[
    {"name":"Unit Tests","state":"FAILURE","workflow":"Backend Tests"},
    {"name":"Vercel","state":"SUCCESS","workflow":""}
  ]'
  run classify_failed_checks "$checks"
  [ "$status" -eq 0 ]
  local df cf cn
  df=$(echo "$output" | jq -r '.deploy_fails')
  cf=$(echo "$output" | jq -r '.ci_fails')
  cn=$(echo "$output" | jq -r '.ci_names')
  [ "$df" = "0" ]
  [ "$cf" = "1" ]
  [ "$cn" = "Unit Tests" ]
}

@test "classify_failed_checks: mixed deploy + CI fails → counts both" {
  local checks='[
    {"name":"Railway Deploy","state":"FAILURE","workflow":""},
    {"name":"codex-review","state":"FAILURE","workflow":"Codex Code Review"},
    {"name":"Unit Tests","state":"SUCCESS","workflow":"Backend Tests"}
  ]'
  run classify_failed_checks "$checks"
  [ "$status" -eq 0 ]
  local df cf
  df=$(echo "$output" | jq -r '.deploy_fails')
  cf=$(echo "$output" | jq -r '.ci_fails')
  [ "$df" = "1" ]
  [ "$cf" = "1" ]
}

@test "classify_failed_checks: no failures → zeros" {
  local checks='[
    {"name":"Unit Tests","state":"SUCCESS","workflow":"Backend Tests"},
    {"name":"Vercel","state":"SUCCESS","workflow":""}
  ]'
  run classify_failed_checks "$checks"
  [ "$status" -eq 0 ]
  local df cf
  df=$(echo "$output" | jq -r '.deploy_fails')
  cf=$(echo "$output" | jq -r '.ci_fails')
  [ "$df" = "0" ]
  [ "$cf" = "0" ]
}

@test "classify_failed_checks: null workflow treated as deploy" {
  local checks='[{"name":"Supabase Preview","state":"FAILURE","workflow":null}]'
  run classify_failed_checks "$checks"
  [ "$status" -eq 0 ]
  local df
  df=$(echo "$output" | jq -r '.deploy_fails')
  [ "$df" = "1" ]
}

@test "classify_failed_checks: extracts descriptions and links" {
  local checks='[{"name":"Railway","state":"FAILURE","workflow":"","description":"Build failed","link":"https://railway.com/deploy/123"}]'
  run classify_failed_checks "$checks"
  [ "$status" -eq 0 ]
  local dd dl
  dd=$(echo "$output" | jq -r '.deploy_descriptions')
  dl=$(echo "$output" | jq -r '.deploy_links')
  [ "$dd" = "Build failed" ]
  [ "$dl" = "https://railway.com/deploy/123" ]
}

# ── is_transient_deploy_failure ──

@test "is_transient_deploy_failure: 502 error → transient (return 0)" {
  run is_transient_deploy_failure "HTTP 502 Bad Gateway"
  [ "$status" -eq 0 ]
}

@test "is_transient_deploy_failure: timeout → transient (return 0)" {
  run is_transient_deploy_failure "Connection timed out"
  [ "$status" -eq 0 ]
}

@test "is_transient_deploy_failure: no deployment needed → transient (return 0)" {
  run is_transient_deploy_failure "No deployment needed - watched paths not modified"
  [ "$status" -eq 0 ]
}

@test "is_transient_deploy_failure: build failed → code issue (return 1)" {
  run is_transient_deploy_failure "Build failed"
  [ "$status" -eq 1 ]
}

@test "is_transient_deploy_failure: deployment failed → code issue (return 1)" {
  run is_transient_deploy_failure "Deployment failed"
  [ "$status" -eq 1 ]
}

@test "is_transient_deploy_failure: empty description → code issue (return 1)" {
  run is_transient_deploy_failure ""
  [ "$status" -eq 1 ]
}

@test "is_transient_deploy_failure: rate limit → transient (return 0)" {
  run is_transient_deploy_failure "Rate limit exceeded"
  [ "$status" -eq 0 ]
}
