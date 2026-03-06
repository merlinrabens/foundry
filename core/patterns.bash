# core/patterns.bash — JSONL pattern logging + cost estimation
[ "${_CORE_PATTERNS_LOADED:-}" = "1" ] && return 0
_CORE_PATTERNS_LOADED=1

PATTERNS_FILE="${FOUNDRY_DIR}/patterns.jsonl"

pattern_log() {
  local task_id="$1" agent="$2" model="$3" retries="$4" success="$5" duration="$6" project="$7" task_type="$8"
  local ts
  ts=$(date +%s)

  # Estimate cost based on agent and duration
  local estimated_cost="0"
  if command -v bc >/dev/null 2>&1 && [ "$duration" -gt 0 ]; then
    case "$agent" in
      codex)  estimated_cost=$(echo "scale=2; $duration * 0.002" | bc 2>/dev/null || echo "0") ;;
      claude) estimated_cost=$(echo "scale=2; $duration * 0.005" | bc 2>/dev/null || echo "0") ;;
      gemini) estimated_cost=$(echo "scale=2; $duration * 0.001" | bc 2>/dev/null || echo "0") ;;
      *)      estimated_cost="0" ;;
    esac
  fi

  # Write to SQLite if available, otherwise JSONL
  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ] && type pattern_log_sqlite &>/dev/null; then
    pattern_log_sqlite "$task_id" "$agent" "$model" "$retries" "$success" "$duration" "$project" "$task_type"
  fi

  # Always write JSONL too (backward compat + backup)
  jq -n -c \
    --argjson ts "$ts" \
    --arg id "$task_id" \
    --arg agent "$agent" \
    --arg model "$model" \
    --argjson retries "$retries" \
    --argjson success "$success" \
    --argjson duration_s "$duration" \
    --arg project "$project" \
    --arg task_type "$task_type" \
    --arg estimated_cost_usd "$estimated_cost" \
    '{ts:$ts, id:$id, agent:$agent, model:$model, retries:$retries, success:$success, duration_s:$duration_s, project:$project, task_type:$task_type, estimated_cost_usd:$estimated_cost_usd}' \
    >> "$PATTERNS_FILE"
}
