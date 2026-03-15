# commands/respawn.bash — Retry a failed agent with failure context

cmd_respawn() {
  # Parse flags
  local prompt_file_override=""
  local force=false
  local max_fixes_override=""
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file)
        prompt_file_override="$2"
        shift 2
        ;;
      --prompt-file=*)
        prompt_file_override="${1#*=}"
        shift
        ;;
      --force)
        force=true
        shift
        ;;
      --max-fixes)
        max_fixes_override="$2"
        shift 2
        ;;
      --max-fixes=*)
        max_fixes_override="${1#*=}"
        shift
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  set -- "${positional[@]}"

  local task_id="$1"
  if [ -z "$task_id" ]; then
    echo "Usage: foundry respawn <task-id> [--force] [--max-fixes N]"
    return 1
  fi

  local task
  task=$(registry_get_task "$task_id")
  if [ -z "$task" ] || [ "$task" = "null" ]; then
    log_err "Task not found: $task_id"
    return 1
  fi

  # Apply --max-fixes override if provided
  if [ -n "$max_fixes_override" ]; then
    registry_batch_update "$task_id" "maxReviewFixes=$max_fixes_override"
    task=$(registry_get_task "$task_id")
    log "Review fix budget raised to $max_fixes_override"
    force=true  # auto-force when raising budget
  fi

  local attempts max_attempts worktree log_file done_file branch spec repo agent model
  attempts=$(echo "$task" | jq -r '.attempts // 1')
  max_attempts=$(echo "$task" | jq -r '.maxAttempts // 3')
  worktree=$(echo "$task" | jq -r '.worktree')
  branch=$(echo "$task" | jq -r '.branch')
  spec=$(echo "$task" | jq -r '.spec')
  repo=$(echo "$task" | jq -r '.repoPath')
  agent=$(echo "$task" | jq -r '.agent')
  model=$(echo "$task" | jq -r '.model')
  # Derive log/done paths from task ID
  log_file="${FOUNDRY_DIR}/logs/${task_id}.log"
  done_file="${FOUNDRY_DIR}/logs/${task_id}.done"

  if [ "$force" != "true" ] && [ "$attempts" -ge "$max_attempts" ]; then
    log_err "Max attempts ($max_attempts) reached for: $task_id"
    return 1
  fi

  # ── Ensure worktree exists (may have been pruned by cleanup) ──
  if [ ! -d "$worktree" ]; then
    log_warn "Worktree missing, recreating: $worktree"
    mkdir -p "$(dirname "$worktree")"
    if [ ! -d "$repo" ]; then
      log_err "Repo not found: $repo"
      return 1
    fi
    git -C "$repo" worktree prune 2>/dev/null || true
    git -C "$repo" branch -D "$branch" 2>/dev/null || true
    git -C "$repo" fetch origin 2>/dev/null || true
    local default_branch
    default_branch=$(git -C "$repo" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
    git -C "$repo" worktree add "$worktree" -b "$branch" "origin/${default_branch}" || {
      log_err "Failed to recreate worktree for: $task_id"
      return 1
    }
  fi

  # ── Regenerate runner script ──
  log "Regenerating runner script..."
  local env_block=""
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]   && env_block+="export OP_SERVICE_ACCOUNT_TOKEN='${OP_SERVICE_ACCOUNT_TOKEN}'"$'\n'
  env_block+='[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile" 2>/dev/null'$'\n'
  env_block+='[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null'$'\n'
  _write_runner_script "$agent" "$worktree" "$model" "$log_file" "$done_file" "$env_block" "high"

  # ── Gather failure context (delegated to lib/respawn_helpers.bash) ──
  local status
  status=$(echo "$task" | jq -r '.status')

  local stored_failure_reason
  stored_failure_reason=$(echo "$task" | jq -r '.failureReason // empty')
  _gather_failure_context "$status" "$done_file" "$log_file" "$worktree" "$stored_failure_reason"
  local failure_reason="$_FAILURE_REASON"
  local failure_details="$_FAILURE_DETAILS"

  # Append PR review feedback if a PR exists
  # PR field may be a number or URL — construct URL if needed
  local pr_val pr_url
  pr_val=$(echo "$task" | jq -r '.pr // empty')
  if [ -n "$pr_val" ] && echo "$pr_val" | grep -qE '^[0-9]+$'; then
    # It's a PR number, construct the URL from repo
    local repo_slug_r
    repo_slug_r=$(cd "$repo" 2>/dev/null && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    [ -n "$repo_slug_r" ] && pr_url="https://github.com/${repo_slug_r}/pull/${pr_val}" || pr_url="$pr_val"
  else
    pr_url="$pr_val"
  fi
  _gather_review_feedback "$pr_url" "$repo"
  failure_details="$_FAILURE_DETAILS"

  # ── Get original task content ──
  local task_content=""
  if [ -f "$spec" ]; then
    task_content=$(cat "$spec")
  elif [ -f "$repo/$spec" ]; then
    task_content=$(cat "$repo/$spec")
  else
    task_content="$spec"
  fi

  # ── Render fix prompt ──
  local prompt_file="${worktree}/.foundry-prompt.md"
  local fix_summary
  fix_summary=$(echo "$failure_reason" | head -c 60)

  if [ -n "$prompt_file_override" ] && [ -f "$prompt_file_override" ]; then
    # Orchestrator-written custom fix prompt (Zoe pattern)
    cp "$prompt_file_override" "$prompt_file"
    log "Using custom fix prompt: $prompt_file_override"
  elif [ "$status" = "review-failed" ] && [ -f "${FOUNDRY_DIR}/templates/review-fix.md" ]; then
    # Review-fix: frame as "address reviewer feedback", not "fix a failure"
    log "Using review-fix template (status=$status)"
    render_template "${FOUNDRY_DIR}/templates/review-fix.md" \
      "TASK_CONTENT=${task_content}" \
      "FAILURE_DETAILS=${failure_details}" \
      > "$prompt_file"
  else
    render_template "${FOUNDRY_DIR}/templates/fix.md" \
      "TASK_CONTENT=${task_content}" \
      "FAILURE_REASON=${failure_reason}" \
      "FAILURE_DETAILS=${failure_details}" \
      "FIX_SUMMARY=${fix_summary}" \
      > "$prompt_file"
  fi

  # ── Build structured respawnContext ──
  local respawn_context
  respawn_context=$(jq -n \
    --argjson attempt "$((attempts + 1))" \
    --arg previousFailure "$failure_reason" \
    --arg logTail "$(tail -50 "$log_file" 2>/dev/null | head -c 2000 || echo "(no log)")" \
    '{
      attempt: $attempt,
      previousFailure: $previousFailure,
      logTail: $logTail
    }' 2>/dev/null || echo '{}')

  # ── Remove visual evidence label (will be re-added when ready again) ──
  if [ -n "$pr_val" ]; then
    (cd "$worktree" 2>/dev/null && gh pr edit --remove-label "ready-for-evidence" 2>/dev/null) || true
  fi

  # ── Clean up old process/session ──
  # Cancel native session if exists
  local old_session_id
  old_session_id=$(echo "$task" | jq -r '.sessionId // empty')
  if [ -n "$old_session_id" ] && [ "$old_session_id" != "null" ]; then
    source "${FOUNDRY_DIR}/lib/session_bridge.bash"
    oc_cancel "$old_session_id" 2>/dev/null || true
  fi

  local old_pid
  old_pid=$(echo "$task" | jq -r '.pid // empty')
  [ "$old_pid" = "null" ] && old_pid=""

  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    kill -TERM "$old_pid" 2>/dev/null || true
    sleep 2
    kill -0 "$old_pid" 2>/dev/null && kill -KILL "$old_pid" 2>/dev/null || true
  fi
  rm -f "$done_file"

  # Increment attempts — but NOT for review-fix respawns (separate budget)
  local rfx
  rfx=$(echo "$task" | jq -r '.reviewFixAttempts // 0')
  if [ "$force" = "true" ] || [ "$rfx" -gt 0 ]; then
    # Review-fix respawn — don't burn crash budget
    registry_batch_update "$task_id" \
      "status=running" "startedAt=$(date +%s)" \
      "failureReason=$failure_reason" "checks.agentAlive=true"
  else
    local new_attempts=$((attempts + 1))
    registry_batch_update "$task_id" \
      "attempts=$new_attempts" "status=running" \
      "startedAt=$(date +%s)" "failureReason=$failure_reason" \
      "checks.agentAlive=true"
  fi

  # Store respawnContext in SQLite
  registry_update_field "$task_id" "respawn_context" "$respawn_context"

  # Relaunch agent
  nohup bash "${worktree}/.foundry-run.sh" \
    > "${log_file}.stderr" 2>&1 &
  local new_pid=$!

  echo "$new_pid" > "${FOUNDRY_DIR}/logs/${task_id}.pid"
  registry_update_field "$task_id" "pid" "$new_pid"
  log "Agent PID: $new_pid"

  local display_attempts=$((attempts + 1))
  log_ok "Respawned: ${BOLD}${task_id}${NC} (attempt ${display_attempts}/${max_attempts})"
}
