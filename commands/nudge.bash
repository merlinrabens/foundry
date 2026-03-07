# commands/nudge.bash — Handle foundry-nudge: messages from CI review workflows
# Parses the nudge format, looks up task ID by repo + PR number, runs targeted check.
# Usage: foundry nudge "foundry-nudge: owner/repo PR#123 reviewer=claude status=success"
#        foundry nudge owner/repo 123

cmd_nudge() {
  local input="$*"

  if [ -z "$input" ]; then
    echo "Usage: foundry nudge <nudge-message>"
    echo "       foundry nudge <owner/repo> <pr-number>"
    echo ""
    echo "Examples:"
    echo "  foundry nudge 'foundry-nudge: primal-meat-club/aura-shopify PR#906 reviewer=claude status=success'"
    echo "  foundry nudge primal-meat-club/aura-shopify 906"
    return 1
  fi

  local repo_slug pr_number reviewer nudge_status

  # Parse: either "foundry-nudge: owner/repo PR#123 reviewer=X status=Y"
  #        or just "owner/repo 123"
  if [[ "$input" == foundry-nudge:* ]]; then
    # Full nudge message format
    repo_slug=$(echo "$input" | grep -oE '[^ ]+/[^ ]+' | head -1)
    pr_number=$(echo "$input" | grep -oE 'PR#([0-9]+)' | sed 's/PR#//')
    reviewer=$(echo "$input" | grep -oE 'reviewer=([^ ]+)' | sed 's/reviewer=//')
    nudge_status=$(echo "$input" | grep -oE 'status=([^ ]+)' | sed 's/status=//')
  elif [[ "$2" =~ ^[0-9]+$ ]]; then
    # Short form: owner/repo PR#
    repo_slug="$1"
    pr_number="$2"
  else
    # Try to extract from freeform text
    repo_slug=$(echo "$input" | grep -oE '[^ ]+/[^ ]+' | head -1)
    pr_number=$(echo "$input" | grep -oE '[0-9]+' | head -1)
  fi

  if [ -z "$repo_slug" ] || [ -z "$pr_number" ]; then
    log_err "Could not parse repo or PR number from: $input"
    return 1
  fi

  log "Nudge received: ${repo_slug} PR#${pr_number}${reviewer:+ reviewer=$reviewer}${nudge_status:+ status=$nudge_status}"

  # Look up task ID from registry by matching PR URL
  local task_id=""

  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ]; then
    # SQLite: query by PR URL containing the PR number and repo slug
    task_id=$(_db "SELECT id FROM tasks WHERE (pr LIKE '%/${pr_number}' OR pr LIKE '%/pull/${pr_number}') AND (repo_path LIKE '%${repo_slug}' OR repo LIKE '%$(echo "$repo_slug" | awk -F/ '{print $NF}')') AND status NOT IN ('merged','done','done-no-pr','killed','closed') LIMIT 1;")

    # Fallback: just match PR number (in case repo path format differs)
    if [ -z "$task_id" ]; then
      task_id=$(_db "SELECT id FROM tasks WHERE (pr LIKE '%/pull/${pr_number}' OR pr LIKE '%/${pr_number}') AND status NOT IN ('merged','done','done-no-pr','killed','closed') LIMIT 1;")
    fi
  else
    # JSON registry: search with jq
    local registry_file="${FOUNDRY_DIR}/active-tasks.json"
    if [ -f "$registry_file" ]; then
      task_id=$(jq -r --arg pr "$pr_number" --arg repo "$(echo "$repo_slug" | awk -F/ '{print $NF}')" \
        '[.[] | select((.pr // "" | test("/pull/" + $pr + "$"; "")) or (.pr // "" | endswith("/" + $pr))) | select(.repo == $repo or (.repoPath // "" | endswith($repo)))] | .[0].id // empty' \
        "$registry_file" 2>/dev/null)

      # Fallback: just PR number
      if [ -z "$task_id" ]; then
        task_id=$(jq -r --arg pr "$pr_number" \
          '[.[] | select((.pr // "" | test("/pull/" + $pr + "$"; "")) or (.pr // "" | endswith("/" + $pr)))] | .[0].id // empty' \
          "$registry_file" 2>/dev/null)
      fi
    fi
  fi

  if [ -z "$task_id" ]; then
    log_warn "No active task found for ${repo_slug} PR#${pr_number}"
    log "Running full check instead..."
    source "${FOUNDRY_DIR}/commands/check.bash"
    cmd_check
    return $?
  fi

  log_ok "Matched task: $task_id"

  # Log nudge event
  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ]; then
    registry_log_event "$task_id" "nudge" "CI nudge: reviewer=${reviewer:-unknown} status=${nudge_status:-unknown} PR#${pr_number}"
  fi

  # Run targeted check on this specific task
  source "${FOUNDRY_DIR}/commands/check.bash"
  cmd_check "$task_id"
}
