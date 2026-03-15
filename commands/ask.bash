# commands/ask.bash — Bidirectional communication with running agents
# Uses oc_send for native sessions, falls back to steer for legacy

cmd_ask() {
  local task_id="$1"
  shift
  local question="$*"
  if [ -z "$task_id" ] || [ -z "$question" ]; then
    echo "Usage: foundry ask <task-id> <question>"
    echo ""
    echo "Send a question to a running agent and get a reply."
    echo "Works only with native OpenClaw sessions (has sessionId)."
    echo ""
    echo "Example: foundry ask aura-dashboard 'What is your current progress?'"
    return 1
  fi

  local task
  task=$(registry_get_task "$task_id")
  if [ -z "$task" ] || [ "$task" = "null" ]; then
    log_err "Task not found: $task_id"
    return 1
  fi

  local sid
  sid=$(echo "$task" | jq -r '.sessionId // empty')
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    source "${FOUNDRY_DIR}/lib/session_bridge.bash"
    log "Asking $task_id (session: $sid)..."
    local reply
    reply=$(oc_send "$sid" "$question" 45)
    if [ $? -eq 0 ]; then
      echo "$reply"
    else
      log_err "Failed to reach agent: $task_id"
      return 1
    fi
  else
    log_err "Task $task_id has no native session (legacy task). Use 'foundry steer' instead."
    return 1
  fi
}
