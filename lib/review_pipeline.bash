#!/bin/bash
# lib/review_pipeline.bash — PR review parsing and workflow check filtering
[[ -n "${_LIB_REVIEW_PIPELINE_LOADED:-}" ]] && return 0
_LIB_REVIEW_PIPELINE_LOADED=1

# parse_latest_reviews <reviews_json>
# Takes raw GitHub reviews JSON (array of {author:{login}, state, submittedAt}).
# Returns JSON array of {login, state} with only the LATEST review per reviewer.
# This is critical because a reviewer may post multiple reviews — only the last matters.
parse_latest_reviews() {
  local reviews_json="$1"
  # Filter out DISMISSED reviews BEFORE grouping — a dismissed review means the
  # maintainer invalidated that feedback. Without this filter, a dismissed
  # CHANGES_REQUESTED review still triggers respawns on already-fixed code.
  echo "$reviews_json" | jq '[
    [.[] | select(.state != "DISMISSED")] |
    group_by(.author.login)[] |
    sort_by(.submittedAt) | last |
    {login: .author.login, state: .state}
  ]' 2>/dev/null || echo "[]"
}

# get_reviewer_state <latest_reviews_json> <login_pattern>
# Extracts the review state for a specific reviewer from parsed latest reviews.
# login_pattern: jq select expression fragment (e.g., '.login == "claude[bot]"')
# Echoes the state string (APPROVED, CHANGES_REQUESTED, COMMENTED, or "")
get_reviewer_state() {
  local reviews="$1" pattern="$2"
  echo "$reviews" | jq -r "[.[] | select($pattern)] | .[0].state // \"\"" 2>/dev/null || echo ""
}

# detect_gemini_approval <gemini_review_state> <gemini_findings_count> <gemini_check_state>
# Determines if Gemini has approved the PR.
# Returns 0 (approved) or 1 (not approved).
#
# Gemini approval logic:
# - No review at all → approved (Gemini only reviews on PR open, not synchronize)
# - ANY inline findings → NOT approved (even low-priority ones need addressing)
# - COMMENTED + 0 findings → approved (review summary only, no code issues)
# - Anything else → not approved
detect_gemini_approval() {
  local state="$1"
  local findings="${2:-0}"
  local check_state="${3:-}"

  # No Gemini review = don't block (expected on non-open events)
  [ -z "$state" ] && return 0
  # Any inline findings = NOT approved, regardless of check state
  [ "$findings" -gt 0 ] 2>/dev/null && return 1
  # COMMENTED with no inline findings = clean (review summary only)
  [ "$state" = "COMMENTED" ] && return 0
  # Check workflow passed with no findings = clean
  [ "$check_state" = "SUCCESS" ] && return 0
  # Otherwise not approved
  return 1
}

# filter_workflow_checks <checks_json> <modifies_workflows>
# Counts CI failures, optionally excluding review checks for workflow-modifying PRs.
# This handles the chicken-and-egg problem: when a PR modifies .github/workflows/,
# the claude-review and codex-review checks may fail because they need the workflow
# to exist on the default branch first.
#
# Arguments:
#   checks_json        — JSON array of {name, state} check objects
#   modifies_workflows — "1" if PR touches .github/workflows/, "0" otherwise
#
# Echoes: failure count (integer)
filter_workflow_checks() {
  local checks_json="$1" modifies_workflows="$2"

  # Always exclude review-infrastructure checks — these are review-posting
  # workflows and check-runs, not build/test CI. A GitHub API 500 on review
  # posting is not a code problem and should never trigger a respawn.
  local always_exclude="post-review|pre-review|Approval Status"

  if [ "$modifies_workflows" = "1" ]; then
    echo "$checks_json" | jq --arg excl "$always_exclude|claude-review|codex-review" '[.[] | select(.state == "FAILURE" and (.name | test($excl) | not))] | length' 2>/dev/null || echo "0"
  else
    echo "$checks_json" | jq --arg excl "$always_exclude" '[.[] | select(.state == "FAILURE" and (.name | test($excl) | not))] | length' 2>/dev/null || echo "0"
  fi
}

# count_pending_checks <checks_json>
# Counts checks still in PENDING or QUEUED state.
# Echoes: pending count (integer)
count_pending_checks() {
  local checks_json="$1"
  echo "$checks_json" | jq '[.[] | select(.state == "PENDING" or .state == "QUEUED")] | length' 2>/dev/null || echo "0"
}

# classify_failed_checks <checks_json_with_workflow>
# Separates failed checks into deployment (external) vs CI (GitHub Actions).
# External deployment checks (Railway, Vercel, Supabase) have workflow="" in gh pr checks output.
# Echoes JSON with deploy_fails, ci_fails, names, and descriptions for context.
classify_failed_checks() {
  local checks_json="$1"
  # Pre-filter: remove review-infrastructure checks (same exclusion as filter_workflow_checks)
  local filtered
  filtered=$(echo "$checks_json" | jq '[.[] | select(.name | test("post-review|pre-review") | not)]' 2>/dev/null || echo "$checks_json")
  echo "$filtered" | jq '{
    deploy_fails: [.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null))] | length,
    ci_fails: [.[] | select(.state == "FAILURE" and .workflow != "" and .workflow != null)] | length,
    deploy_names: ([.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null)) | .name] | join(", ")),
    ci_names: ([.[] | select(.state == "FAILURE" and .workflow != "" and .workflow != null) | .name] | join(", ")),
    deploy_descriptions: ([.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null)) | .description // ""] | join("; ")),
    deploy_links: ([.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null)) | .link // ""] | join(" "))
  }' 2>/dev/null || echo '{"deploy_fails":0,"ci_fails":0,"deploy_names":"","ci_names":"","deploy_descriptions":"","deploy_links":""}'
}

# is_transient_deploy_failure <description>
# Heuristic: checks if a deploy failure description suggests transient infra vs code issue.
# Returns 0 (transient) or 1 (likely code issue).
# When uncertain, returns 1 (treat as code issue — safer to investigate).
is_transient_deploy_failure() {
  local desc="$1"
  # Empty description = unknown = treat as code issue
  [ -z "$desc" ] && return 1
  local lower
  lower=$(echo "$desc" | tr '[:upper:]' '[:lower:]')
  # Transient patterns: network errors, platform outages, CDN issues
  if echo "$lower" | grep -qE '502|503|504|timeout|timed.out|rate.limit|network|cdn|temporarily|unavailable|no deployment needed'; then
    return 0
  fi
  # Code issue patterns: build failed, compilation error, missing module
  return 1
}
