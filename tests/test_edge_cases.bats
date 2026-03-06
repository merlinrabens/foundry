#!/usr/bin/env bats
# Edge cases and boundary conditions across lib modules.

setup() {
  # Unset source guards so libs can be re-sourced fresh
  unset _LIB_MODEL_ROUTING_LOADED
  unset _LIB_NOTIFICATIONS_LOADED
  unset _LIB_REVIEW_PIPELINE_LOADED
  unset _LIB_RISK_TIER_LOADED
  unset _LIB_SPAWN_GUARDS_LOADED
  unset _LIB_STATE_MACHINE_LOADED
  unset _LIB_VIDEO_EVIDENCE_LOADED

  for f in "$(dirname "$BATS_TEST_FILENAME")/../lib/"*.bash; do
    source "$f"
  done

  export CLAUDE_DEFAULT="claude-sonnet-4-6"
  export CLAUDE_COMPLEX="claude-opus-4-6"
  export CODEX_MODEL="gpt-5.3-codex"
  export CODEX_REASONING="high"
  export GEMINI_MODEL="gemini-3.5-pro"
  export AUTO_MERGE_LOW_RISK="false"
}

# ============================================================================
# detect_model_backend edge cases
# ============================================================================

@test "detect_model_backend: empty string defaults to claude backend" {
  detect_model_backend ""
  [ "$AGENT_BACKEND_OUT" = "claude" ]
  [ "$MODEL_OUT" = "" ]
}

# ============================================================================
# classify_risk_tier edge cases
# ============================================================================

@test "classify_risk_tier: single newline yields LOW" {
  run classify_risk_tier $'\n'
  [ "$output" = "LOW" ]
}

@test "classify_risk_tier: HIGH takes priority over MEDIUM" {
  run classify_risk_tier "src/api/routes.ts
src/auth/login.ts
README.md"
  [ "$output" = "HIGH" ]
}

# ============================================================================
# is_stale boundary
# ============================================================================

@test "is_stale: exactly at threshold is NOT stale" {
  run is_stale 7200 7200 "false"
  [ "$status" -eq 1 ]
}

@test "is_stale: one second over threshold IS stale" {
  run is_stale 7201 7200 "false"
  [ "$status" -eq 0 ]
}

# ============================================================================
# is_idle edge cases
# ============================================================================

@test "is_idle: one second over threshold with zero changes IS idle" {
  run is_idle 1 0 0
  [ "$status" -eq 0 ]
}

# ============================================================================
# determine_next_status terminal states
# ============================================================================

@test "determine_next_status: exhausted is terminal" {
  run determine_next_status "exhausted" "true" "1" "true" "5" "3" "0" "1800" "false"
  [ "$output" = "exhausted" ]
}

@test "determine_next_status: merged is terminal" {
  run determine_next_status "merged" "true" "0" "true" "1" "3" "0" "1800" "false"
  [ "$output" = "merged" ]
}

@test "determine_next_status: closed is terminal" {
  run determine_next_status "closed" "true" "0" "true" "1" "3" "0" "1800" "false"
  [ "$output" = "closed" ]
}

# ============================================================================
# can_auto_merge edge cases
# ============================================================================

@test "can_auto_merge: AUTO_PASSED counts as approved" {
  run can_auto_merge "APPROVED" "APPROVED" "AUTO_PASSED" "LOW" "true"
  [ "$status" -eq 0 ]
}

# ============================================================================
# review_pipeline edge cases
# ============================================================================

@test "filter_workflow_checks: empty JSON array returns 0" {
  run filter_workflow_checks "[]" "0"
  [ "$output" = "0" ]
}

@test "count_pending_checks: mixed states counts PENDING and QUEUED" {
  local checks='[{"state":"SUCCESS"},{"state":"PENDING"},{"state":"FAILURE"},{"state":"QUEUED"}]'
  run count_pending_checks "$checks"
  [ "$output" = "2" ]
}

@test "build_checks_summary: string true and numeric 1 both work" {
  run build_checks_summary "true" "1" "true" "1"
  [ "$output" = "CRKG" ]
}

# ============================================================================
# video_evidence edge cases
# ============================================================================

@test "has_frontend_changes: .html file matches" {
  has_frontend_changes "index.html"
}

@test "check_screenshots_in_pr: HTML video tag matches" {
  check_screenshots_in_pr '<video src="demo.mp4"></video>'
}

@test "get_screenshot_status: video URL in PR body counts as true" {
  run get_screenshot_status "src/components/Button.tsx" "Check the demo: https://example.com/demo.mp4"
  [ "$output" = "true" ]
}
