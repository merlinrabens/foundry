# commands/lifecycle.bash — attach, logs, kill, steer

cmd_attach() {
  local task_id="$1"
  if [ -z "$task_id" ]; then
    echo "Usage: foundry attach <task-id>"
    return 1
  fi
  local log_file="${FOUNDRY_DIR}/logs/${task_id}.log"
  if [ -f "$log_file" ]; then
    log "Streaming log (Ctrl-C to stop):"
    tail -f "$log_file"
  else
    log_err "No log file for: $task_id"
  fi
}

cmd_logs() {
  local task_id="$1"
  if [ -z "$task_id" ]; then
    echo "Usage: foundry logs <task-id>"
    return 1
  fi
  # Derive log path from task ID
  local log_file="${FOUNDRY_DIR}/logs/${task_id}.log"
  if [ -f "$log_file" ]; then
    tail -f "$log_file"
  else
    log_err "No log file for: $task_id (expected at $log_file)"
  fi
}

cmd_kill() {
  local task_id="$1"
  if [ -z "$task_id" ]; then
    echo "Usage: foundry kill <task-id>"
    return 1
  fi
  local task
  task=$(registry_get_task "$task_id")
  local killed=0

  # PID-based kill
  local pid
  pid=$(echo "$task" | jq -r '.pid // empty')
  if [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    killed=1
  fi

  if [ "$killed" -eq 1 ]; then
    registry_update_field "$task_id" "status" "killed"
    log_ok "Killed: $task_id"
  else
    # Mark as killed even if no process found (cleanup)
    registry_update_field "$task_id" "status" "killed"
    log_warn "No running process found for $task_id (marked as killed)"
  fi
}

cmd_open() {
  local task_id="$1"
  if [ -z "$task_id" ]; then
    echo "Usage: foundry open <task-id>"
    return 1
  fi
  local task
  task=$(registry_get_task "$task_id")
  if [ -z "$task" ] || [ "$task" = "null" ]; then
    log_err "Task not found: $task_id"
    return 1
  fi

  # Try prUrl first (explicit URL), then construct from pr number
  local pr_url
  pr_url=$(echo "$task" | jq -r '.prUrl // empty')
  if [ -z "$pr_url" ]; then
    local pr_num repo_path
    pr_num=$(echo "$task" | jq -r '.pr // empty')
    repo_path=$(echo "$task" | jq -r '.repoPath')
    if [ -n "$pr_num" ] && [ "$pr_num" != "null" ]; then
      local slug
      slug=$(cd "$repo_path" 2>/dev/null && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
      if [ -n "$slug" ]; then
        pr_url="https://github.com/${slug}/pull/${pr_num}"
      fi
    fi
  fi

  if [ -n "$pr_url" ]; then
    log_ok "Opening: $pr_url"
    open "$pr_url"
  else
    log_err "No PR found for: $task_id"
  fi
}

cmd_steer() {
  local task_id="$1"
  shift
  local message="$*"
  if [ -z "$task_id" ] || [ -z "$message" ]; then
    echo "Usage: foundry steer <task-id> <message>"
    echo ""
    echo "Example: foundry steer aura-dashboard 'Focus on API first, not UI'"
    return 1
  fi
  local task
  task=$(registry_get_task "$task_id")

  # Write steer file + signal orchestrator via USR1
  local pid
  pid=$(echo "$task" | jq -r '.pid // empty')
  if [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then
    local steer_file="${FOUNDRY_DIR}/logs/${task_id}.steer"
    echo "$message" > "$steer_file"
    kill -USR1 "$pid" 2>/dev/null || true
    log_ok "Sent steer to $task_id (PID: $pid): $message"
  else
    log_err "Agent not running: $task_id"
  fi
}

cmd_steer_wait() {
  local task_id="$1"
  shift
  local message="$*"
  if [ -z "$task_id" ] || [ -z "$message" ]; then
    echo "Usage: foundry steer-wait <task-id> <message>"
    echo ""
    echo "Sends steer, then polls status.json for up to 30s and returns updated status."
    return 1
  fi

  # Send the steer
  cmd_steer "$task_id" "$message" || return $?

  # Poll status.json for response (up to 30s)
  local status_file="${FOUNDRY_DIR}/logs/${task_id}.status.json"
  local before_ts=0
  [ -f "$status_file" ] && before_ts=$(jq -r '.last_activity_ts // 0' "$status_file")

  local waited=0
  while [ "$waited" -lt 30 ]; do
    sleep 2
    waited=$((waited + 2))
    if [ -f "$status_file" ]; then
      local current_ts
      current_ts=$(jq -r '.last_activity_ts // 0' "$status_file")
      if [ "$current_ts" -gt "$before_ts" ]; then
        # Activity detected after steer — return peek output
        source "${FOUNDRY_DIR}/commands/peek.bash" 2>/dev/null || true
        cmd_peek "$task_id"
        return 0
      fi
    fi
  done

  log_warn "No activity detected within 30s after steer"
  # Return current peek anyway
  source "${FOUNDRY_DIR}/commands/peek.bash" 2>/dev/null || true
  cmd_peek "$task_id"
}
