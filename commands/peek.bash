# commands/peek.bash — Structured JSON status for Jerry's monitoring

cmd_peek() {
  local task_id="$1"
  if [ -z "$task_id" ]; then
    echo "Usage: foundry peek <task-id>"
    echo ""
    echo "Returns structured JSON merging registry state + live agent status."
    return 1
  fi

  local task
  task=$(registry_get_task "$task_id")
  if [ -z "$task" ] || [ "$task" = "null" ]; then
    jq -n --arg id "$task_id" '{error: "task not found", id: $id}'
    return 1
  fi

  local status agent model pr started_at worktree
  status=$(echo "$task" | jq -r '.status')
  agent=$(echo "$task" | jq -r '.agent')
  model=$(echo "$task" | jq -r '.model')
  pr=$(echo "$task" | jq -r '.pr // empty')
  started_at=$(echo "$task" | jq -r '.startedAt')
  worktree=$(echo "$task" | jq -r '.worktree')

  # Calculate elapsed time
  local now elapsed_min
  now=$(date +%s)
  elapsed_min=$(( (now - started_at) / 60 ))

  # Check if steer is available (PID alive or session active)
  local steer_available="false"
  local pid session_id_peek
  pid=$(echo "$task" | jq -r '.pid // empty')
  session_id_peek=$(echo "$task" | jq -r '.sessionId // empty')

  if [ -n "$session_id_peek" ] && [ "$session_id_peek" != "null" ]; then
    # Native path: steer available if background process is alive
    if [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then
      steer_available="true"
    fi
  elif [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then
    steer_available="true"
  fi

  # Read status.json if it exists (written by acp_orchestrator.py for legacy tasks)
  local status_file="${FOUNDRY_DIR}/logs/${task_id}.status.json"
  local phase="unknown" tools_used="[]" files_modified=0 last_tool="null" last_activity_ts=0 error="null"

  if [ -f "$status_file" ]; then
    # Legacy path: read from .status.json (written by acp_orchestrator.py)
    phase=$(jq -r '.phase // "unknown"' "$status_file")
    tools_used=$(jq -c '.tools_used // []' "$status_file")
    files_modified=$(jq -r '.files_modified // 0' "$status_file")
    last_tool=$(jq -r '.last_tool // "null"' "$status_file")
    last_activity_ts=$(jq -r '.last_activity_ts // 0' "$status_file")
    error=$(jq -r '.error // "null"' "$status_file")
  elif [ -n "$session_id_peek" ] && [ "$session_id_peek" != "null" ]; then
    # Native path: query session status from gateway
    source "${FOUNDRY_DIR}/lib/session_bridge.bash" 2>/dev/null || true
    if type oc_status &>/dev/null; then
      local sess_info
      sess_info=$(oc_status "$session_id_peek" 2>/dev/null)
      local sess_alive
      sess_alive=$(echo "$sess_info" | jq -r '.alive' 2>/dev/null)
      if [ "$sess_alive" = "true" ]; then
        phase="running"
        last_activity_ts=$(echo "$sess_info" | jq -r '.updatedAt // 0' 2>/dev/null)
      else
        phase="completed"
      fi
    fi
  fi

  # Merge into structured output
  jq -n \
    --arg id "$task_id" \
    --arg status "$status" \
    --arg agent "$agent" \
    --arg model "$model" \
    --arg phase "$phase" \
    --argjson elapsed_min "$elapsed_min" \
    --argjson files_modified "$files_modified" \
    --arg last_tool "$last_tool" \
    --argjson last_activity_ts "$last_activity_ts" \
    --arg pr "${pr:-null}" \
    --argjson steer_available "$steer_available" \
    --argjson tools_used "$tools_used" \
    --arg error "$error" \
    '{
      id: $id,
      status: $status,
      agent: $agent,
      model: $model,
      phase: $phase,
      elapsed_min: $elapsed_min,
      files_modified: $files_modified,
      last_tool: (if $last_tool == "null" then null else $last_tool end),
      last_activity_ts: $last_activity_ts,
      pr: (if $pr == "null" or $pr == "" then null else $pr end),
      steer_available: $steer_available,
      tools_used: $tools_used,
      error: (if $error == "null" then null else $error end)
    }'
}
