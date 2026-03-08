# commands/orchestrate.bash — Jerry's primary command: smart routing + spawn + JSON output

cmd_orchestrate() {
  local repo_dir="$1" spec_or_task="$2" hint="${3:-auto}"

  if [ -z "$repo_dir" ] || [ -z "$spec_or_task" ]; then
    echo "Usage: foundry orchestrate <repo-path> <spec-file | task-description | issue-N> [hint]"
    echo ""
    echo "Jerry's orchestrator command. Picks the best agent, spawns it, returns JSON."
    echo ""
    echo "Hints: auto (default), codex, claude, gemini"
    echo ""
    echo "Examples:"
    echo "  foundry orchestrate ~/projects/aura-shopify specs/backlog/05-dashboard.md"
    echo "  foundry orchestrate ~/projects/aura-shopify 'Add dark mode' codex"
    echo "  foundry orchestrate ~/projects/lead-gen issue-6          # GitHub Issue #6"
    echo "  foundry orchestrate ~/projects/lead-gen issue:6 codex    # with agent hint"
    return 1
  fi

  # Resolve repo
  repo_dir=$(cd "$repo_dir" 2>/dev/null && pwd) || { log_err "Not found: $repo_dir"; return 1; }

  # ── Detect GitHub Issue reference: "issue-6", "issue:6", "#6" ─────────
  local issue_number=""
  local issue_spec_file=""
  if [[ "$spec_or_task" =~ ^issue[-:]([0-9]+)$ ]] || [[ "$spec_or_task" =~ ^#([0-9]+)$ ]]; then
    issue_number="${BASH_REMATCH[1]}"

    # Fetch the issue from the repo's GitHub remote
    local gh_slug
    gh_slug=$(_get_gh_repo_slug "$repo_dir") || {
      log_err "Cannot determine GitHub remote for: $repo_dir"
      return 1
    }
    log "Fetching GitHub Issue #${issue_number} from ${gh_slug}..."

    local issue_data
    issue_data=$(gh issue view "$issue_number" -R "$gh_slug" \
      --json number,title,body 2>/dev/null) || {
      log_err "Issue #${issue_number} not found in ${gh_slug}"
      return 1
    }

    # Verify issue is still open
    local issue_state
    issue_state=$(gh issue view "$issue_number" -R "$gh_slug" \
      --json state --jq '.state' 2>/dev/null || echo "unknown")
    if [ "$issue_state" != "OPEN" ] && [ "$issue_state" != "open" ]; then
      log_err "Issue #${issue_number} is not open (state: $issue_state)"
      return 1
    fi

    local issue_title issue_body
    issue_title=$(echo "$issue_data" | jq -r '.title')
    issue_body=$(echo "$issue_data" | jq -r '.body // ""')

    # Write combined spec to a temp file (cleaned up after spawn)
    issue_spec_file=$(mktemp "/tmp/foundry-issue-${issue_number}-XXXXX.md")
    printf '# Issue #%s: %s\n\n%s\n' \
      "$issue_number" "$issue_title" "$issue_body" > "$issue_spec_file"

    # Use the issue spec for routing decisions
    spec_or_task="$issue_spec_file"
    log "Issue #${issue_number}: ${issue_title}"
  fi

  # Read task content for routing
  local task_content
  if [ -f "$spec_or_task" ]; then
    task_content=$(cat "$spec_or_task")
  elif [ -f "$repo_dir/$spec_or_task" ]; then
    task_content=$(cat "$repo_dir/$spec_or_task")
  else
    task_content="$spec_or_task"
  fi

  # ── Planning Stage: enrich spec with repo reconnaissance ─────────────
  # If spec is a file, enrich in-place. If it's a text description, create
  # a temp spec file with the description + recon hints.
  source "${FOUNDRY_DIR}/lib/preflight_recon.bash" 2>/dev/null || true
  if type enrich_spec_with_recon &>/dev/null; then
    if [ -f "$spec_or_task" ]; then
      enrich_spec_with_recon "$repo_dir" "$spec_or_task"
    else
      # Text description — create enriched temp spec
      local recon_spec_file
      recon_spec_file=$(mktemp "/tmp/foundry-recon-XXXXX.md")
      printf '# %s\n\n%s\n' "$(echo "$task_content" | head -1)" "$task_content" > "$recon_spec_file"
      enrich_spec_with_recon "$repo_dir" "$recon_spec_file"
      spec_or_task="$recon_spec_file"
      task_content=$(cat "$recon_spec_file")
      # Mark for cleanup
      [ -z "$issue_spec_file" ] && issue_spec_file="$recon_spec_file"
    fi
  fi

  # Jerry selects the agent
  _jerry_select_agent "$repo_dir" "$task_content" "$hint"
  local selected_backend="$JERRY_BACKEND"
  local selected_model="$JERRY_MODEL"

  log "Jerry selected: $selected_backend (model: $selected_model, hint: $hint)"

  # Spawn using the selected backend
  # Source spawn if not already loaded
  source "${FOUNDRY_DIR}/commands/spawn.bash" 2>/dev/null || true

  # Build spawn args — pass --issue-number when spawning from a GitHub Issue
  local spawn_extra_args=()
  [ -n "$issue_number" ] && spawn_extra_args+=("--issue-number" "$issue_number")

  cmd_spawn "$repo_dir" "$spec_or_task" "$selected_model" "${spawn_extra_args[@]}"
  local spawn_result=$?

  # Clean up temp issue spec file
  [ -n "$issue_spec_file" ] && rm -f "$issue_spec_file"

  if [ "$spawn_result" -ne 0 ]; then
    # Output error JSON
    jq -n \
      --arg error "spawn failed (exit $spawn_result)" \
      --arg agent "$selected_backend" \
      --arg hint "$hint" \
      '{error: $error, agent: $agent, hint: $hint}'
    return "$spawn_result"
  fi

  # Find the task ID we just created (most recent running task)
  local task_id task_info
  task_info=$(registry_read | jq -r '
    [.[] | select(.status == "running")]
    | sort_by(-.startedAt)
    | .[0]
  ')
  task_id=$(echo "$task_info" | jq -r '.id // "unknown"')

  # Output structured JSON
  jq -n \
    --arg task_id "$task_id" \
    --arg agent "$selected_backend" \
    --arg model "$(echo "$task_info" | jq -r '.model // "unknown"')" \
    --arg hint "$hint" \
    --arg worktree "$(echo "$task_info" | jq -r '.worktree // ""')" \
    --arg branch "$(echo "$task_info" | jq -r '.branch // ""')" \
    '{task_id: $task_id, agent: $agent, model: $model, hint: $hint, worktree: $worktree, branch: $branch}'
}
