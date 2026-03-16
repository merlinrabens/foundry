#!/bin/bash
# check_helpers.bash — Shared PR evaluation + respawn-or-exhaust pattern
# Extracted from cmd_check to eliminate duplication between pr-open and running→PR paths.
[[ "${_LIB_CHECK_HELPERS_LOADED:-}" == "1" ]] && return 0
_LIB_CHECK_HELPERS_LOADED=1

# Ensure video_evidence is loaded (get_screenshot_status dependency)
_FOUNDRY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "${_FOUNDRY_LIB_DIR}/video_evidence.bash" ] && source "${_FOUNDRY_LIB_DIR}/video_evidence.bash"

# _evaluate_pr <check_dir> <pr_ref> <task_json>
# Fetches CI checks, reviews, screenshot evidence for a PR.
# Sets global result vars: _PR_ANY_FAIL, _PR_ANY_PENDING, _PR_CLAUDE_APPROVED,
# _PR_CODEX_APPROVED, _PR_GEMINI_APPROVED, _PR_CLAUDE_REVIEWED, _PR_CODEX_REVIEWED,
# _PR_ALL_REVIEWS_IN, _PR_CHANGES_REQUESTED, _PR_BRANCH_SYNCED,
# _PR_CHECKS_SUMMARY (CRKGS), _PR_SCREENSHOT_STATUS, _PR_URL, _PR_MODIFIES_WORKFLOWS
_evaluate_pr() {
  local check_dir="$1" pr_ref="$2" task_json="$3"

  # Reset all output vars
  _PR_ANY_FAIL=0; _PR_ANY_PENDING=0
  _PR_CLAUDE_APPROVED=0; _PR_CODEX_APPROVED=0; _PR_GEMINI_APPROVED=0
  _PR_CLAUDE_REVIEWED=0; _PR_CODEX_REVIEWED=0
  _PR_GEMINI_PENDING=0; _PR_ALL_REVIEWS_IN=0
  _PR_CHANGES_REQUESTED=0; _PR_CHECKS_SUMMARY=""
  _PR_SCREENSHOT_STATUS="null"; _PR_URL=""
  _PR_MODIFIES_WORKFLOWS=0
  _PR_DEPLOY_FAILS=0; _PR_CI_FAILS=0
  _PR_DEPLOY_FAIL_NAMES=""; _PR_CI_FAIL_NAMES=""
  _PR_BRANCH_SYNCED=""

  # Fetch PR URL
  _PR_URL=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr view ${pr_ref:+"$pr_ref"} --json url --jq '.url' || echo "")
  # Fallback: construct URL from pr_ref if it's a number
  if [ -z "$_PR_URL" ] && echo "$pr_ref" | grep -qE '^[0-9]+$' 2>/dev/null; then
    local _repo_slug
    _repo_slug=$(cd "$check_dir" 2>/dev/null && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    [ -n "$_repo_slug" ] && _PR_URL="https://github.com/${_repo_slug}/pull/${pr_ref}"
  fi

  # Fetch checks — deduplicate by name, keeping latest
  # Include workflow, description, link fields for failure classification
  local checks_raw checks_json
  checks_raw=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr checks ${pr_ref:+"$pr_ref"} --json name,state,completedAt,workflow,description,link || echo "[]")
  checks_json=$(echo "$checks_raw" | jq '[group_by(.name)[] | sort_by(.completedAt // "") | last]' 2>/dev/null || echo "$checks_raw")

  # Detect workflow file changes
  local changed_files
  changed_files=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr diff ${pr_ref:+"$pr_ref"} --name-only 2>/dev/null || echo "")
  if echo "$changed_files" | grep -q '\.github/workflows/'; then
    _PR_MODIFIES_WORKFLOWS=1
  fi

  _PR_ANY_FAIL=$(filter_workflow_checks "$checks_json" "$_PR_MODIFIES_WORKFLOWS")
  _PR_ANY_PENDING=$(count_pending_checks "$checks_json")

  # Classify failures: deployment (external) vs CI (GitHub Actions)
  _PR_DEPLOY_DESCS=""; _PR_DEPLOY_LINKS=""
  if [ "$_PR_ANY_FAIL" -gt 0 ]; then
    local fail_class
    fail_class=$(classify_failed_checks "$checks_json")
    _PR_DEPLOY_FAILS=$(echo "$fail_class" | jq -r '.deploy_fails')
    _PR_CI_FAILS=$(echo "$fail_class" | jq -r '.ci_fails')
    _PR_DEPLOY_FAIL_NAMES=$(echo "$fail_class" | jq -r '.deploy_names')
    _PR_CI_FAIL_NAMES=$(echo "$fail_class" | jq -r '.ci_names')
    _PR_DEPLOY_DESCS=$(echo "$fail_class" | jq -r '.deploy_descriptions')
    _PR_DEPLOY_LINKS=$(echo "$fail_class" | jq -r '.deploy_links')
  fi

  # Fetch reviews
  local reviews_json latest_reviews
  reviews_json=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr view ${pr_ref:+"$pr_ref"} --json reviews --jq '.reviews' || echo "[]")
  latest_reviews=$(parse_latest_reviews "$reviews_json")

  # Claude
  local claude_state
  claude_state=$(get_reviewer_state "$latest_reviews" '.login == "claude[bot]" or .login == "claude"')
  [ "$claude_state" = "APPROVED" ] && _PR_CLAUDE_APPROVED=1
  [ -n "$claude_state" ] && [ "$claude_state" != "null" ] && _PR_CLAUDE_REVIEWED=1

  # Codex
  local codex_state
  codex_state=$(get_reviewer_state "$latest_reviews" '.login == "github-actions[bot]" or .login == "github-actions"')
  [ "$codex_state" = "APPROVED" ] && _PR_CODEX_APPROVED=1
  [ -n "$codex_state" ] && [ "$codex_state" != "null" ] && _PR_CODEX_REVIEWED=1

  # Gemini — always count inline findings (even low-priority ones need addressing)
  local gemini_state gemini_check_state="" gemini_findings=0
  gemini_state=$(get_reviewer_state "$latest_reviews" '.login | startswith("gemini-code-assist")')
  if [ -z "$gemini_state" ] || [ "$gemini_state" = "null" ]; then
    # Check if Gemini Code Review check-run exists — if so, Gemini will review
    # but hasn't posted yet (race condition on fresh PRs). Wait instead of auto-approving.
    local gemini_check_exists
    gemini_check_exists=$(echo "$checks_json" | jq '[.[] | select(.name | test("Gemini Code Review"; "i"))] | length' 2>/dev/null || echo "0")
    if [ "$gemini_check_exists" -gt 0 ]; then
      _PR_GEMINI_APPROVED=0
      _PR_GEMINI_PENDING=1
    else
      _PR_GEMINI_APPROVED=1
    fi
  elif [ "$gemini_state" = "COMMENTED" ]; then
    gemini_check_state=$(echo "$checks_json" | jq -r '[.[] | select(.name | test("Gemini Code Review"))] | .[0].state // ""' 2>/dev/null || echo "")
    # Always fetch inline findings count — low-priority findings need fixing too
    local repo_slug pr_num_for_gem
    repo_slug=$(cd "$check_dir" 2>/dev/null && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    pr_num_for_gem=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr view ${pr_ref:+"$pr_ref"} --json number --jq '.number' || echo "")
    if [ -n "$repo_slug" ] && [ -n "$pr_num_for_gem" ] && [ "$pr_num_for_gem" != "null" ]; then
      gemini_findings=$(gh api "repos/${repo_slug}/pulls/${pr_num_for_gem}/comments" \
        --jq '[.[] | select(.user.login | startswith("gemini-code-assist"))] | length' 2>/dev/null || echo "0")
    fi
    detect_gemini_approval "$gemini_state" "$gemini_findings" "$gemini_check_state" && _PR_GEMINI_APPROVED=1
  fi

  # Determine if all reviewers have submitted
  # First cycle: wait for Claude + Codex + Gemini (Gemini only reviews on open, not synchronize)
  # Subsequent cycles (reviewFixAttempts > 0): only wait for Claude + Codex
  # If a reviewer is disabled (no workflow run = no review), treat as reviewed
  local rfx_count
  rfx_count=$(echo "$task_json" | jq -r '.reviewFixAttempts // 0' 2>/dev/null || echo "0")
  local gemini_reviewed=1
  [ "${_PR_GEMINI_PENDING:-0}" -eq 1 ] && gemini_reviewed=0

  # If Claude review never ran (disabled via DISABLE_CLAUDE_REVIEW), treat as reviewed+approved
  local claude_check_exists
  claude_check_exists=$(echo "$checks_json" | jq '[.[] | select(.name == "claude-review")] | length' 2>/dev/null || echo "0")
  if [ "$_PR_CLAUDE_REVIEWED" -eq 0 ] && [ "$claude_check_exists" -eq 0 ]; then
    _PR_CLAUDE_REVIEWED=1
    _PR_CLAUDE_APPROVED=1
  fi

  # If Codex review never ran (disabled via DISABLE_CODEX_REVIEW), treat as reviewed+approved
  local codex_check_exists
  codex_check_exists=$(echo "$checks_json" | jq '[.[] | select(.name == "codex-review")] | length' 2>/dev/null || echo "0")
  if [ "$_PR_CODEX_REVIEWED" -eq 0 ] && [ "$codex_check_exists" -eq 0 ]; then
    _PR_CODEX_REVIEWED=1
    _PR_CODEX_APPROVED=1
  fi

  if [ "$_PR_CLAUDE_REVIEWED" -eq 1 ] && [ "$_PR_CODEX_REVIEWED" -eq 1 ]; then
    if [ "$rfx_count" -gt 0 ] || [ "$gemini_reviewed" -eq 1 ]; then
      _PR_ALL_REVIEWS_IN=1
    fi
  fi

  # Determine CHANGES_REQUESTED from our parsed reviews (not GitHub's reviewDecision,
  # which stays stale after dismissals and doesn't reset until a new APPROVED review).
  local has_changes_requested
  has_changes_requested=$(echo "$latest_reviews" | jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' 2>/dev/null || echo "0")
  [ "$has_changes_requested" -gt 0 ] && _PR_CHANGES_REQUESTED=1

  # Branch synced to main? (no merge conflicts)
  if [ -d "$check_dir" ]; then
    git -C "$check_dir" fetch origin main --quiet 2>/dev/null || true
    if git -C "$check_dir" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      _PR_BRANCH_SYNCED="true"
    else
      _PR_BRANCH_SYNCED="false"
    fi
  fi

  # Screenshot evidence
  local pr_body
  pr_body=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr view ${pr_ref:+"$pr_ref"} --json body --jq '.body' || echo "")
  _PR_SCREENSHOT_STATUS=$(get_screenshot_status "$changed_files" "$pr_body")

  # Build checks summary (CRKGS)
  _PR_CHECKS_SUMMARY=""
  [ "$_PR_ANY_FAIL" -eq 0 ] && [ "$_PR_ANY_PENDING" -eq 0 ] && _PR_CHECKS_SUMMARY="${_PR_CHECKS_SUMMARY}C"
  [ "$_PR_CLAUDE_APPROVED" -gt 0 ] && _PR_CHECKS_SUMMARY="${_PR_CHECKS_SUMMARY}R"
  [ "$_PR_CODEX_APPROVED" -gt 0 ] && _PR_CHECKS_SUMMARY="${_PR_CHECKS_SUMMARY}K"
  [ "$_PR_GEMINI_APPROVED" -gt 0 ] && _PR_CHECKS_SUMMARY="${_PR_CHECKS_SUMMARY}G"
  [ "$_PR_BRANCH_SYNCED" = "true" ] && _PR_CHECKS_SUMMARY="${_PR_CHECKS_SUMMARY}S"
}

# _update_pr_checks <task_id>
# Writes the evaluated PR state to registry (call after _evaluate_pr)
_update_pr_checks() {
  local task_id="$1"
  local updates=()
  [ "$_PR_ANY_FAIL" -eq 0 ] && [ "$_PR_ANY_PENDING" -eq 0 ] && updates+=("checks.ciPassed=true")
  [ "$_PR_CLAUDE_APPROVED" -gt 0 ] && updates+=("checks.claudeReview=APPROVED")
  [ "$_PR_CODEX_APPROVED" -gt 0 ] && updates+=("checks.codexReview=APPROVED")
  [ "$_PR_GEMINI_APPROVED" -gt 0 ] && updates+=("checks.geminiReview=APPROVED")
  [ "$_PR_SCREENSHOT_STATUS" != "null" ] && updates+=("checks.screenshotsIncluded=$_PR_SCREENSHOT_STATUS")
  [ "$_PR_BRANCH_SYNCED" = "true" ] && updates+=("checks.branchSynced=true")
  [ "$_PR_BRANCH_SYNCED" = "false" ] && updates+=("checks.branchSynced=false")
  [ ${#updates[@]} -gt 0 ] && registry_batch_update "$task_id" "${updates[@]}"
}

# _try_respawn_or_exhaust <task_id> <attempts> <max_attempts> <reason_msg> <agent> <model> <retries> <started> <project>
# Returns 0 if respawned, 1 if exhausted
_try_respawn_or_exhaust() {
  local task_id="$1" attempts="$2" max_attempts="$3" reason_msg="$4"
  local agent="$5" model="$6" retries="$7" started="$8" project="$9"
  local pr_url="${10:-}"

  if [ "$attempts" -lt "$max_attempts" ]; then
    # Exponential backoff: 30s, 60s, 120s, 240s between respawns
    # Prevents burning all retries in seconds when agents crash immediately
    local backoff_secs=$(( 30 * (1 << (attempts > 4 ? 4 : attempts)) ))
    [ "$backoff_secs" -gt 300 ] && backoff_secs=300
    log_warn "  Auto-respawning (attempt $((attempts + 1))/$max_attempts) after ${backoff_secs}s backoff..."
    sleep "$backoff_secs"
    # No TG notification for intermediate respawn cycles — only notify on exhaustion or ready
    if cmd_respawn "$task_id"; then
      return 0
    else
      log_err "  Respawn failed for $task_id, marking exhausted"
      registry_update_field "$task_id" "status" "exhausted"
      return 1
    fi
  else
    # Before exhausting, check if task has a PR and unused review-fix budget
    local task_data rfx max_rfx task_pr
    task_data=$(registry_get_task "$task_id")
    rfx=$(echo "$task_data" | jq -r '.reviewFixAttempts // 0')
    max_rfx=$(echo "$task_data" | jq -r ".maxReviewFixes // ${MAX_REVIEW_FIXES:-20}")
    task_pr=$(echo "$task_data" | jq -r '.pr // empty')
    if [ -n "$task_pr" ] && [ "$rfx" -lt "$max_rfx" ]; then
      log_warn "  Crash budget exhausted but review-fix budget available ($rfx/$max_rfx), delegating..."
      _try_review_fix "$task_id" "$reason_msg" "$agent" "$model" "$retries" "$started" "$project" "$pr_url"
      return $?
    fi
    registry_update_field "$task_id" "status" "exhausted"
    local now_ts; now_ts=$(date +%s)
    local duration=$(( now_ts - started ))
    pattern_log "$task_id" "$agent" "$model" "$retries" "false" "$duration" "$project" "feature"
    tg_notify_task "$task_id" "🚨 <b>Agent exhausted</b>
<code>${task_id}</code>
Failed after ${max_attempts} attempts — needs human intervention${pr_url:+

<a href=\"${pr_url}\">→ PR</a>}" "HTML"
    return 1
  fi
}

# _try_review_fix <task_id> <reason_msg> <agent> <model> <retries> <started> <project> <pr_url>
# Like _try_respawn_or_exhaust but uses a separate review-fix budget.
# Review-fix cycles (Codex/Gemini CHANGES_REQUESTED) are fundamentally different from
# crash retries — a review can generate new findings each round, so we need more budget.
# Uses reviewFixAttempts/maxReviewFixes (default MAX_REVIEW_FIXES) instead of attempts/maxAttempts.
_try_review_fix() {
  local task_id="$1" reason_msg="$2"
  local agent="$3" model="$4" retries="$5" started="$6" project="$7"
  local pr_url="${8:-}"

  local task_data
  task_data=$(registry_get_task "$task_id")
  local review_fixes max_review_fixes
  review_fixes=$(echo "$task_data" | jq -r '.reviewFixAttempts // 0')
  max_review_fixes=$(echo "$task_data" | jq -r ".maxReviewFixes // ${MAX_REVIEW_FIXES:-20}")

  if [ "$review_fixes" -lt "$max_review_fixes" ]; then
    local next_fix=$((review_fixes + 1))
    registry_update_field "$task_id" "reviewFixAttempts" "$next_fix"
    log_warn "  Review-fix cycle ($next_fix/$max_review_fixes)..."
    # No TG notification for intermediate fix cycles — only notify on exhaustion or ready
    if cmd_respawn --force "$task_id"; then
      return 0
    else
      log_err "  Review-fix respawn failed for $task_id"
      return 1
    fi
  else
    registry_update_field "$task_id" "status" "exhausted"
    local now_ts; now_ts=$(date +%s)
    local duration=$(( now_ts - started ))
    pattern_log "$task_id" "$agent" "$model" "$retries" "false" "$duration" "$project" "feature"
    tg_notify_task "$task_id" "🚨 <b>Review-fix exhausted</b>
<code>${task_id}</code>
Failed after ${max_review_fixes} review-fix cycles — needs human intervention${pr_url:+

<a href=\"${pr_url}\">→ PR</a>}" "HTML"
    return 1
  fi
}

# _try_auto_merge <task_id> <check_dir>
# Attempts auto-merge if AUTO_MERGE_LOW_RISK=true and PR qualifies.
# Returns 0 if merged, 1 if skipped/failed.
_try_auto_merge() {
  local task_id="$1" check_dir="$2"
  [ "$AUTO_MERGE_LOW_RISK" != "true" ] && return 1

  local task_data
  task_data=$(registry_get_task "$task_id")

  local claude_review codex_review gemini_review
  claude_review=$(echo "$task_data" | jq -r '.checks.claudeReview // ""')
  codex_review=$(echo "$task_data" | jq -r '.checks.codexReview // ""')
  gemini_review=$(echo "$task_data" | jq -r '.checks.geminiReview // ""')
  # Gemini no-review = pass
  [ -z "$gemini_review" ] || [ "$gemini_review" = "null" ] && gemini_review="AUTO_PASSED"

  local changed_files risk_tier
  changed_files=$(cd "$check_dir" 2>/dev/null && gh pr diff --name-only 2>/dev/null || echo "")
  risk_tier=$(classify_risk_tier "$changed_files")

  if can_auto_merge "$claude_review" "$codex_review" "$gemini_review" "$risk_tier"; then
    local pr_url
    pr_url=$(echo "$task_data" | jq -r '.pr // ""')
    log "Auto-merging LOW risk PR: $pr_url"
    if cd "$check_dir" 2>/dev/null && gh pr merge --squash 2>/dev/null; then
      registry_batch_update "$task_id" "status=merged" "completedAt=$(date +%s)"
      tg_notify_task "$task_id" "✅ <b>Auto-merged</b> (LOW risk)
<code>${task_id}</code>

<a href=\"${pr_url}\">→ PR</a>" "HTML"
      return 0
    else
      log_warn "Auto-merge failed for $task_id (branch protection?)"
      return 1
    fi
  fi
  return 1
}

# _all_checks_pass <task_id>
# Returns 0 if PR + CI + at least Claude OR Codex review approved
_all_checks_pass() {
  local task_id="$1"
  local result
  result=$(registry_read | jq --arg id "$task_id" '
    .[] | select(.id == $id) | .checks |
    (.prCreated and .ciPassed and (.claudeReview == "APPROVED" or .codexReview == "APPROVED"))
  ')
  [ "$result" = "true" ]
}
