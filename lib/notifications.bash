#!/bin/bash
# lib/notifications.bash — Notification dedup + beautiful PR status formatting
[[ -n "${_LIB_NOTIFICATIONS_LOADED:-}" ]] && return 0
_LIB_NOTIFICATIONS_LOADED=1

# should_notify <current_state> <last_notified_state>
# Returns 0 (should notify) if state changed since last notification.
# Returns 1 (skip) if already notified about this state.
#
# The foundry uses "claim then send" pattern: write lastNotifiedState BEFORE
# sending to prevent race conditions in concurrent cron cycles.
should_notify() {
  local current="$1" last="$2"
  [ "$current" != "$last" ]
}

# build_checks_summary <ci_passed> <claude_approved> <codex_approved> <gemini_approved>
# Builds the CRKG status string shown in notifications.
# C = CI passed, R = Claude approved, K = Codex (codeK) approved, G = Gemini approved
# Echoes: string like "CRKG" or "C" etc.
build_checks_summary() {
  local ci_passed="$1"
  local claude_approved="$2"
  local codex_approved="$3"
  local gemini_approved="$4"

  local summary=""
  [ "$ci_passed" = "true" ] || [ "$ci_passed" = "1" ] && summary="${summary}C"
  [ "$claude_approved" = "true" ] || [ "$claude_approved" = "1" ] && summary="${summary}R"
  [ "$codex_approved" = "true" ] || [ "$codex_approved" = "1" ] && summary="${summary}K"
  [ "$gemini_approved" = "true" ] || [ "$gemini_approved" = "1" ] && summary="${summary}G"
  echo "$summary"
}

# ─── Beautiful PR Status Notifications ────────────────────────────
# Replaces both the raw `foundry-nudge` from CI and `pr-review-notify.yml`.
# Uses _PR_* globals set by _evaluate_pr in check_helpers.bash.

# _build_pr_status_html <check_dir> <pr_ref>
# Builds an HTML-formatted Telegram message like:
#   ❌ PR #928
#   feat: ESLint major upgrade (v8 → v10)
#
#   ✗ Review: Changes Requested
#   ✓ Vercel Preview Comments
#   ✓ CI
#
#   → PR (link)
#
# Sets global: _PR_STATUS_HTML
_build_pr_status_html() {
  local check_dir="$1" pr_ref="$2"

  # Fetch PR title + number (one gh call)
  local pr_info pr_title pr_number
  pr_info=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr view ${pr_ref:+"$pr_ref"} --json title,number 2>/dev/null || echo '{}')
  pr_title=$(echo "$pr_info" | jq -r '.title // "PR"')
  pr_number=$(echo "$pr_info" | jq -r '.number // ""')

  # Fallback chain for PR number when gh pr view fails (e.g., pruned worktree)
  if [ -z "$pr_number" ] && [ -n "$_PR_URL" ]; then
    pr_number=$(echo "$_PR_URL" | grep -oE '[0-9]+$' || echo "")
  fi
  if [ -z "$pr_number" ] && echo "$pr_ref" | grep -qE '^[0-9]+$' 2>/dev/null; then
    pr_number="$pr_ref"
  fi
  # Fallback: extract number from pr_ref if it's a URL (e.g., https://github.com/.../pull/123)
  if [ -z "$pr_number" ] && echo "$pr_ref" | grep -qE 'pull/[0-9]+' 2>/dev/null; then
    pr_number=$(echo "$pr_ref" | grep -oE '[0-9]+$' || echo "")
  fi

  # Fallback: if _PR_URL is empty but pr_ref is a URL, use it
  if [ -z "$_PR_URL" ] && echo "$pr_ref" | grep -qE '^https://' 2>/dev/null; then
    _PR_URL="$pr_ref"
  fi

  # Last resort: try gh pr view with the URL directly (works without check_dir context)
  if [ -z "$pr_number" ] || [ "$pr_title" = "PR" ]; then
    if [ -n "$_PR_URL" ]; then
      local url_info
      url_info=$(gh_retry gh pr view "$_PR_URL" --json title,number 2>/dev/null || echo '{}')
      local url_title url_number
      url_title=$(echo "$url_info" | jq -r '.title // ""')
      url_number=$(echo "$url_info" | jq -r '.number // ""')
      [ -n "$url_number" ] && [ -z "$pr_number" ] && pr_number="$url_number"
      [ -n "$url_title" ] && [ "$pr_title" = "PR" ] && pr_title="$url_title"
    fi
  fi

  # Determine overall status
  local all_green=true
  [ "$_PR_ANY_FAIL" -gt 0 ] && all_green=false
  [ "$_PR_CHANGES_REQUESTED" -gt 0 ] && all_green=false
  local emoji="✅"
  [ "$all_green" = "false" ] && emoji="❌"

  # Skip notification if we couldn't resolve PR number (avoids empty "PR #\nPR" messages)
  if [ -z "$pr_number" ]; then
    _PR_STATUS_HTML=""
    return 1
  fi

  # Build HTML message
  local msg
  msg="${emoji} <b>PR #${pr_number}</b>"$'\n'"${pr_title}"$'\n'

  # Review status
  [ "$_PR_CHANGES_REQUESTED" -gt 0 ] && msg+=$'\n'"✗ Review: Changes Requested"

  # Failing checks (CI + deploy)
  if [ -n "$_PR_CI_FAIL_NAMES" ] && [ "$_PR_CI_FAIL_NAMES" != "null" ]; then
    local IFS=','
    for name in $_PR_CI_FAIL_NAMES; do
      [ -n "$name" ] && msg+=$'\n'"✗ ${name}"
    done
    unset IFS
  fi
  if [ -n "$_PR_DEPLOY_FAIL_NAMES" ] && [ "$_PR_DEPLOY_FAIL_NAMES" != "null" ]; then
    local IFS=','
    for name in $_PR_DEPLOY_FAIL_NAMES; do
      [ -n "$name" ] && msg+=$'\n'"✗ ${name}"
    done
    unset IFS
  fi

  # Passing items
  [ "$_PR_ANY_FAIL" -eq 0 ] && [ "$_PR_ANY_PENDING" -eq 0 ] && msg+=$'\n'"✓ CI"
  [ "$_PR_CLAUDE_APPROVED" -gt 0 ] && msg+=$'\n'"✓ Claude Review"
  [ "$_PR_CODEX_APPROVED" -gt 0 ] && msg+=$'\n'"✓ Codex Review"
  [ "$_PR_GEMINI_APPROVED" -gt 0 ] && msg+=$'\n'"✓ Gemini Review"

  msg+=$'\n'$'\n'"<a href=\"${_PR_URL}\">→ PR</a>"

  _PR_STATUS_HTML="$msg"
}

# tg_notify_pr_status <task_id> <check_dir> <pr_ref>
# Sends the beautiful HTML-formatted PR status notification.
# Must be called AFTER _evaluate_pr. Handles dedup via lastNotifiedState.
tg_notify_pr_status() {
  local task_id="$1" check_dir="$2" pr_ref="$3" state="$4"

  _build_pr_status_html "$check_dir" "$pr_ref"
  tg_notify_task "$task_id" "$_PR_STATUS_HTML" "HTML"
}
