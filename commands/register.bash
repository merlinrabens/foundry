# commands/register.bash — Track an existing PR for monitoring + respawn

cmd_register() {
  local repo_path="$1" pr_number="$2" agent_override="$3"
  if [ -z "$repo_path" ] || [ -z "$pr_number" ]; then
    log_err "Usage: foundry register <repo-path> <pr-number> [agent]"
    log_err "  Example: foundry register ~/projects/your-org/your-repo 884"
    log_err "  Example: foundry register ~/projects/your-org/your-repo 884 claude"
    exit 1
  fi

  repo_path="$(cd "$repo_path" 2>/dev/null && pwd)" || {
    log_err "Repository not found: $repo_path"
    exit 1
  }

  # Fetch PR details via gh
  local pr_json
  pr_json=$(cd "$repo_path" && gh pr view "$pr_number" --json number,headRefName,title 2>&1) || {
    log_err "Could not fetch PR #${pr_number}: $pr_json"
    exit 1
  }

  local branch title
  branch=$(echo "$pr_json" | jq -r '.headRefName')
  title=$(echo "$pr_json" | jq -r '.title')

  local project_name
  project_name=$(basename "$repo_path")

  # Derive task ID using same generate_task_id as spawn (sanitizes both parts)
  local id_suffix="${branch#foundry/}"
  id_suffix="${id_suffix#swarm/}"  # backward compat
  local task_id
  task_id=$(generate_task_id "$id_suffix" "$project_name")

  # Check if already registered
  local existing
  existing=$(registry_read | jq --arg id "$task_id" '.[] | select(.id == $id) | .id' -r 2>/dev/null)
  if [ -n "$existing" ]; then
    log_warn "Task '$task_id' already registered. Updating PR number."
    registry_update_field "$task_id" "pr" "$pr_number"
    registry_update_field "$task_id" "status" "pr-open"
    registry_update_field "$task_id" "checks.prCreated" "true"
    log_ok "Updated: $task_id -> PR #$pr_number"
    return
  fi

  # ── Create isolated worktree (same convention as spawn) ──
  local worktree_dir
  worktree_dir="$(dirname "$repo_path")/${project_name}-foundry/${id_suffix}"
  mkdir -p "$(dirname "$worktree_dir")" "${FOUNDRY_DIR}/logs"

  log "Creating worktree at ${worktree_dir}..."
  cd "$repo_path"
  git fetch origin "$branch" 2>/dev/null || git fetch origin 2>/dev/null || true

  if [ -d "$worktree_dir" ]; then
    log "Reusing existing worktree: $worktree_dir"
    # Pull latest from remote
    (cd "$worktree_dir" && git pull origin "$branch" --ff-only 2>/dev/null) || true
  else
    # Clean up stale local branch if it exists (could be leftover from previous worktree)
    git branch -D "$branch" 2>/dev/null || true

    git worktree add "$worktree_dir" "$branch" || {
      log_err "Failed to create worktree — falling back to repo path"
      worktree_dir="$repo_path"
    }
  fi

  # ── Determine agent + model (same as spawn) ──
  local agent_backend="${agent_override:-codex}"
  local model=""
  if type detect_model_backend &>/dev/null; then
    detect_model_backend "$agent_backend"
    agent_backend="$AGENT_BACKEND_OUT"
    model="$MODEL_OUT"
  fi
  # Fallback model names
  case "$agent_backend" in
    codex) model="${model:-gpt-5.3-codex}" ;;
    claude) model="${model:-claude-sonnet-4-6}" ;;
    gemini) model="${model:-gemini-2.5-pro}" ;;
    *) model="${model:-$agent_backend}" ;;
  esac

  local session_name=""

  local now
  now=$(date +%s)

  local task_json
  task_json=$(jq -n \
    --arg id "$task_id" \
    --arg repo "$project_name" \
    --arg repoPath "$repo_path" \
    --arg worktree "$worktree_dir" \
    --arg branch "$branch" \
    --arg session "$session_name" \
    --arg agent "$agent_backend" \
    --arg model "$model" \
    --arg desc "$id_suffix (registered from PR #$pr_number)" \
    --argjson pr "$pr_number" \
    --argjson now "$now" \
    --argjson mrf "${MAX_REVIEW_FIXES:-20}" \
    '{
      id: $id,
      repo: $repo,
      repoPath: $repoPath,
      worktree: $worktree,
      branch: $branch,
      tmuxSession: $session,
      pid: null,
      agent: $agent,
      model: $model,
      spec: null,
      description: $desc,
      startedAt: $now,
      status: "pr-open",
      attempts: 1,
      maxAttempts: 3,
      pr: $pr,
      reviewFixAttempts: 0,
      maxReviewFixes: ($mrf),
      checks: {
        agentAlive: null,
        prCreated: true,
        branchSynced: false,
        ciPassed: false,
        codexReview: null,
        claudeReview: null,
        geminiReview: null,
        screenshotsIncluded: null
      },
      lastCheckedAt: null,
      completedAt: null,
      failureReason: null,
      respawnContext: null,
      notifyOnComplete: true,
      lastNotifiedState: null
    }')

  registry_add_task "$task_json"
  log_ok "Registered: $task_id (PR #$pr_number: $title)"
  log "  Branch:    $branch"
  log "  Worktree:  $worktree_dir"
  log "  Agent:     $agent_backend ($model)"
  log "  Session:   $session_name"
  log "  foundry check will now monitor this PR"
}
