#!/bin/bash
# respawn_helpers.bash — Failure context gathering for respawns
# Extracted from cmd_respawn to reduce its size and make context gathering reusable.
[[ "${_LIB_RESPAWN_HELPERS_LOADED:-}" == "1" ]] && return 0
_LIB_RESPAWN_HELPERS_LOADED=1

# _fetch_deploy_build_log <link>
# Attempts to fetch build logs from the deployment platform based on URL pattern.
# Supports Railway (CLI), Vercel (API), Supabase (branches CLI).
# Echoes log text (may be empty if fetch fails).
_fetch_deploy_build_log() {
  local link="$1"
  [ -z "$link" ] && return 0

  if echo "$link" | grep -q "railway.com"; then
    # Railway: extract deployment UUID, fetch build logs via CLI
    local deploy_id
    deploy_id=$(echo "$link" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)
    [ -n "$deploy_id" ] && railway logs --build "$deploy_id" --lines 30 2>/dev/null
  elif echo "$link" | grep -q "vercel.com"; then
    # Vercel: extract deployment ID from URL, fetch via API
    local vercel_token vercel_deploy_id
    vercel_token=$(python3 -c "
import json, os, pathlib
# macOS: ~/Library/Application Support/com.vercel.cli/auth.json
# Linux: ~/.config/com.vercel.cli/auth.json (XDG)
for p in [
    pathlib.Path.home() / 'Library/Application Support/com.vercel.cli/auth.json',
    pathlib.Path.home() / '.config/com.vercel.cli/auth.json',
    pathlib.Path(os.environ.get('XDG_CONFIG_HOME', '')) / 'com.vercel.cli/auth.json',
]:
    if p.is_file():
        print(json.load(open(p)).get('token', ''))
        break
" 2>/dev/null)
    # URL format: https://vercel.com/team/project/DEPLOY_ID or vercel.com/github
    vercel_deploy_id=$(echo "$link" | grep -oE '/[A-Za-z0-9]{20,}$' | tr -d '/')
    if [ -n "$vercel_token" ] && [ -n "$vercel_deploy_id" ]; then
      curl -s -H "Authorization: Bearer $vercel_token" \
        "https://api.vercel.com/v13/deployments/dpl_${vercel_deploy_id}/events?limit=30&direction=backward" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for e in reversed(data.get('events', data) if isinstance(data, dict) else data):
        t = e.get('text','')
        if t: print(t)
except: pass
" 2>/dev/null
    fi
  elif echo "$link" | grep -q "supabase.com"; then
    # Supabase: extract project ref, try branches list for error details
    local project_ref
    project_ref=$(echo "$link" | grep -oE 'project/[a-z]+' | sed 's|project/||')
    if [ -n "$project_ref" ]; then
      supabase branches list --project-ref "$project_ref" 2>/dev/null | head -20
    fi
  fi
}

# _gather_failure_context <status> <done_file> <log_file> <worktree>
# Sets: _FAILURE_REASON, _FAILURE_DETAILS
_gather_failure_context() {
  local status="$1" done_file="$2" log_file="$3" worktree="$4"

  _FAILURE_REASON="Unknown failure"
  _FAILURE_DETAILS=""

  # Last 100 lines of agent log
  if [ -f "$log_file" ]; then
    _FAILURE_DETAILS=$(tail -100 "$log_file" 2>/dev/null || echo "(no log)")
  fi

  case "$status" in
    ci-failed)
      _FAILURE_REASON="CI checks failed"
      local ci_details
      ci_details=$(cd "$worktree" 2>/dev/null && gh pr checks --json name,state,link,description,workflow 2>/dev/null || echo "")
      if [ -n "$ci_details" ]; then
        local failed_checks
        failed_checks=$(echo "$ci_details" | jq -r '.[] | select(.state == "FAILURE") | "\(.name): \(.description // "no details") (\(.link // "no link"))"')
        _FAILURE_DETAILS="CI Failures:\n${failed_checks}\n\nLast agent output:\n${_FAILURE_DETAILS}"

        # For deployment build failures, fetch platform-specific build logs
        local deploy_links
        deploy_links=$(echo "$ci_details" | jq -r '.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null)) | .link // empty')
        for link in $deploy_links; do
          local build_log
          build_log=$(_fetch_deploy_build_log "$link")
          [ -n "$build_log" ] && _FAILURE_DETAILS="${_FAILURE_DETAILS}\n\n── Deploy Build Log ($(echo "$link" | grep -oE '(railway|vercel|supabase)' | head -1)) ──\n${build_log}"
        done
      fi
      ;;
    deploy-failed)
      _FAILURE_REASON="External deployment failed (possible build error)"
      local deploy_details
      deploy_details=$(cd "$worktree" 2>/dev/null && gh pr checks --json name,state,link,description,workflow 2>/dev/null || echo "")
      if [ -n "$deploy_details" ]; then
        local deploy_info
        deploy_info=$(echo "$deploy_details" | jq -r '.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null)) | "\(.name): \(.description // "no details") (\(.link // "no link"))"')
        _FAILURE_DETAILS="Deploy Failures:\n${deploy_info}\n\nLast agent output:\n${_FAILURE_DETAILS}"
        # Fetch platform-specific build logs
        local deploy_links_df
        deploy_links_df=$(echo "$deploy_details" | jq -r '.[] | select(.state == "FAILURE" and (.workflow == "" or .workflow == null)) | .link // empty')
        for link in $deploy_links_df; do
          local build_log
          build_log=$(_fetch_deploy_build_log "$link")
          [ -n "$build_log" ] && _FAILURE_DETAILS="${_FAILURE_DETAILS}\n\n── Deploy Build Log ($(echo "$link" | grep -oE '(railway|vercel|supabase)' | head -1)) ──\n${build_log}"
        done
      fi
      ;;
    review-failed|needs-respawn)
      # Read failureReason from registry if available (set by check-agents.sh)
      local stored_reason
      stored_reason=$(echo "${5:-}" 2>/dev/null || echo "")
      if [ -n "$stored_reason" ] && [ "$stored_reason" != "null" ]; then
        _FAILURE_REASON="$stored_reason"
      elif [ "$status" = "review-failed" ]; then
        _FAILURE_REASON="Reviewer(s) requested changes — fix the issues below"
      else
        _FAILURE_REASON="Agent needs respawn (check failure details below)"
      fi
      ;;
    crashed)
      _FAILURE_REASON="Agent crashed (process died)"
      ;;
    failed)
      local exit_code="unknown"
      [ -f "$done_file" ] && exit_code=$(cat "$done_file")
      _FAILURE_REASON="Agent exited with code $exit_code"
      ;;
  esac
}

# _gather_review_feedback <pr_url> <repo_path> [<since_timestamp>]
# Appends PR review feedback to _FAILURE_DETAILS.
# If since_timestamp is provided (ISO 8601), only includes reviews/comments
# submitted AFTER that timestamp (prevents feeding stale reviews to agents).
# If omitted, fetches the latest push timestamp from the PR and uses that.
_gather_review_feedback() {
  local pr_url="$1" repo_path="$2" since_ts="${3:-}"

  [ -z "$pr_url" ] && return 0

  local pr_num repo_slug
  pr_num=$(echo "$pr_url" | grep -o '[0-9]*$')
  repo_slug=$(cd "$repo_path" 2>/dev/null && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")

  [ -z "$repo_slug" ] || [ -z "$pr_num" ] && return 0

  # Auto-detect cutoff: use the latest force-push / push event timestamp
  # This ensures we only feed reviews that were written AFTER the latest code push
  if [ -z "$since_ts" ]; then
    since_ts=$(gh api "repos/${repo_slug}/pulls/${pr_num}" \
      --jq '.updated_at // empty' 2>/dev/null || echo "")
    # Better: get the latest commit's committer date from the PR head
    local head_sha
    head_sha=$(gh api "repos/${repo_slug}/pulls/${pr_num}" \
      --jq '.head.sha // empty' 2>/dev/null || echo "")
    if [ -n "$head_sha" ]; then
      local commit_date
      commit_date=$(gh api "repos/${repo_slug}/commits/${head_sha}" \
        --jq '.commit.committer.date // empty' 2>/dev/null || echo "")
      [ -n "$commit_date" ] && since_ts="$commit_date"
    fi
  fi

  # Build jq timestamp filter — only include items submitted after the cutoff
  local ts_filter=""
  if [ -n "$since_ts" ]; then
    ts_filter="and (.submitted_at // .created_at // .updated_at | . != null and (. >= \"${since_ts}\"))"
  fi

  # 1. PR reviews (Claude uses gh pr review --request-changes)
  local review_bodies
  review_bodies=$(gh api "repos/${repo_slug}/pulls/${pr_num}/reviews" \
    --jq "[.[] | select(.body != \"\" and .body != null and .state != \"APPROVED\" ${ts_filter:+and (.submitted_at // \"\" | . >= \"${since_ts}\")})] | .[] | \"[\\(.user.login) - \\(.state)]:\\n\\(.body)\"" \
    2>/dev/null || echo "")
  [ -n "$review_bodies" ] && _FAILURE_DETAILS="${_FAILURE_DETAILS}\n\n── PR Reviews ──\n${review_bodies}"

  # 2. PR comments (Codex review posts via issues.createComment)
  local pr_comments
  pr_comments=$(gh api "repos/${repo_slug}/issues/${pr_num}/comments" \
    --jq "[.[] | select(.body | test(\"Codex Review|Review|Finding|Bug|Issue\"; \"i\")) | select(true ${since_ts:+and (.created_at >= \"${since_ts}\")})] | .[] | \"[\\(.user.login)]:\\n\\(.body)\"" \
    2>/dev/null || echo "")
  [ -n "$pr_comments" ] && _FAILURE_DETAILS="${_FAILURE_DETAILS}\n\n── PR Comments (Codex/bot reviews) ──\n${pr_comments}"

  # 3. Inline review comments (code-level feedback)
  local inline_comments
  inline_comments=$(gh api "repos/${repo_slug}/pulls/${pr_num}/comments" \
    --jq "[.[] | select(.body != \"\" ${since_ts:+and (.created_at >= \"${since_ts}\")}) ] | .[] | \"\\(.path):\\(.line // .original_line) [\\(.user.login)]: \\(.body)\"" \
    2>/dev/null || echo "")
  [ -n "$inline_comments" ] && _FAILURE_DETAILS="${_FAILURE_DETAILS}\n\n── Inline Code Comments ──\n${inline_comments}"
  return 0
}
