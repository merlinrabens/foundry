# commands/cleanup.bash — Remove completed worktrees + registry entries

# _archive_spec <repo_path> <spec_filename>
# Moves a completed spec from specs/backlog/ to specs/done/.
# Tries direct push to main; falls back to chore branch + PR.
_archive_spec() {
  local repo_path="$1" spec_file="$2"
  local backlog_path="$repo_path/specs/backlog/$spec_file"

  [ -f "$backlog_path" ] || return 0  # already moved

  (
    cd "$repo_path" || return 1
    local orig_branch
    orig_branch=$(git branch --show-current 2>/dev/null || echo "main")

    # Ensure clean state
    git stash -q 2>/dev/null || true

    git checkout main -q 2>/dev/null && git pull --ff-only -q 2>/dev/null || true
    [ -f "specs/backlog/$spec_file" ] || { git checkout "$orig_branch" -q 2>/dev/null; git stash pop -q 2>/dev/null; return 0; }

    mkdir -p specs/done
    git mv "specs/backlog/$spec_file" "specs/done/$spec_file" 2>/dev/null || return 1
    git commit -q -m "chore: archive completed spec $spec_file" 2>/dev/null || return 1

    # Try direct push first
    if git push -q origin main 2>/dev/null; then
      log "  Archived spec: $spec_file (pushed to main)"
    else
      # Branch protection — create chore branch + PR
      git reset --soft HEAD~1 -q 2>/dev/null
      git checkout -b "chore/archive-${spec_file%.md}" -q 2>/dev/null || return 1
      git commit -q -m "chore: archive completed spec $spec_file" 2>/dev/null || return 1
      git push -u origin "chore/archive-${spec_file%.md}" -q 2>/dev/null || return 1
      gh pr create --title "chore: archive spec $spec_file" \
        --body "Auto-archive: move completed spec from backlog to done." \
        --base main 2>/dev/null || true
      log "  Archived spec: $spec_file (PR created, main is protected)"
      git checkout main -q 2>/dev/null
    fi

    git checkout "$orig_branch" -q 2>/dev/null
    git stash pop -q 2>/dev/null
  ) 2>/dev/null
}

_cleanup_task() {
  local task="$1" all_tasks="$2"
  local worktree repo_path branch agent_name model_name task_attempts task_status started_at completed_at repo_short id
  id=$(echo "$task" | jq -r '.id')
  worktree=$(echo "$task" | jq -r '.worktree')
  repo_path=$(echo "$task" | jq -r '.repoPath')
  branch=$(echo "$task" | jq -r '.branch')
  agent_name=$(echo "$task" | jq -r '.agent')
  model_name=$(echo "$task" | jq -r '.model')
  task_attempts=$(echo "$task" | jq -r '.attempts // 1')
  task_status=$(echo "$task" | jq -r '.status')
  started_at=$(echo "$task" | jq -r '.startedAt // 0')
  completed_at=$(echo "$task" | jq -r '.completedAt // 0')
  repo_short=$(echo "$task" | jq -r '.repo')

  # Archive to patterns.jsonl before removing
  local success_val="false"
  [ "$task_status" = "merged" ] || [ "$task_status" = "ready" ] && success_val="true"
  local duration_val=0
  if [ "$completed_at" != "0" ] && [ "$completed_at" != "null" ] && [ "$started_at" != "0" ]; then
    completed_at=${completed_at%%.*}
    started_at=${started_at%%.*}
    duration_val=$((completed_at - started_at))
  fi
  pattern_log "$id" "$agent_name" "$model_name" "$((task_attempts - 1))" "$success_val" "$duration_val" "$repo_short" "feature"

  # Archive spec from backlog → done (safety net for merged tasks)
  if [ "$success_val" = "true" ]; then
    local spec_path
    spec_path=$(echo "$task" | jq -r '.spec // ""')
    if [[ "$spec_path" == *"specs/backlog/"* ]] && [ -d "$repo_path" ]; then
      local spec_file
      spec_file=$(basename "$spec_path")
      _archive_spec "$repo_path" "$spec_file"
    fi
  fi

  # Kill agent process if alive
  local task_pid
  task_pid=$(echo "$task" | jq -r '.pid // empty')
  if [ -n "$task_pid" ] && [ "$task_pid" != "null" ]; then
    kill -TERM "$task_pid" 2>/dev/null || true
  fi

  # Remove worktree
  if [ -d "$worktree" ] && [ "$worktree" != "$repo_path" ]; then
    (cd "$repo_path" && git worktree remove "$worktree" --force 2>/dev/null) || rm -rf "$worktree"
  fi

  # Delete branch (local only)
  [ -d "$repo_path" ] && (cd "$repo_path" && git branch -D "$branch" 2>/dev/null) || true

  # Clean log files (but NOT patterns.jsonl)
  rm -f "${FOUNDRY_DIR}/logs/${id}.log" "${FOUNDRY_DIR}/logs/${id}.done" "${FOUNDRY_DIR}/logs/${id}.pid" "${FOUNDRY_DIR}/logs/${id}.steer" "${FOUNDRY_DIR}/logs/${id}.stderr"
}

cmd_cleanup() {
  local tasks
  tasks=$(registry_read)

  # Targeted cleanup: foundry cleanup <task-id> [task-id...]
  # Forces removal of specific tasks regardless of status
  if [ $# -gt 0 ]; then
    local cleaned=0
    for target_id in "$@"; do
      local task
      task=$(echo "$tasks" | jq --arg id "$target_id" '.[] | select(.id == $id)')
      if [ -z "$task" ] || [ "$task" = "null" ]; then
        log "Not found: $target_id"
        continue
      fi
      local task_status
      task_status=$(echo "$task" | jq -r '.status')
      if [ "$task_status" = "running" ]; then
        log "SKIP: $target_id is running. Use 'foundry kill $target_id' first."
        continue
      fi
      _cleanup_task "$task" "$tasks"
      log "Cleaned: $target_id (was $task_status)"
      cleaned=$((cleaned + 1))
    done
    # Remove cleaned tasks from registry
    if [ "$cleaned" -gt 0 ]; then
      local updated="$tasks"
      for target_id in "$@"; do
        updated=$(echo "$updated" | jq --arg id "$target_id" '[.[] | select(.id != $id)]')
      done
      registry_locked_write "$updated"
      log_ok "Force-cleaned $cleaned task(s)."
    fi
    return 0
  fi

  # Auto cleanup: only clean truly finished work — preserve anything needing attention
  # Clean: done, merged, ready (PR merged or approved)
  # Preserve: running, pr-open, ci-failed, needs-respawn, deploy-failed,
  #           exhausted (needs human), done-no-pr (suspicious — agent produced nothing)
  local stale_ids
  stale_ids=$(echo "$tasks" | jq -r '.[] | select(.status == "done" or .status == "merged" or .status == "ready") | .id')

  if [ -z "$stale_ids" ]; then
    log "Nothing to clean up."
    return 0
  fi

  local cleaned=0
  for id in $stale_ids; do
    local task
    task=$(echo "$tasks" | jq --arg id "$id" '.[] | select(.id == $id)')
    _cleanup_task "$task" "$tasks"
    log "Cleaned: $id"
    cleaned=$((cleaned + 1))
  done

  # Update registry — keep everything except cleanly finished tasks (locked write)
  local updated
  updated=$(echo "$tasks" | jq '[.[] | select(.status != "done" and .status != "merged" and .status != "ready")]')
  registry_locked_write "$updated"

  log_ok "Cleaned up $cleaned task(s)."
}
