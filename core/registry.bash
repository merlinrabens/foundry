# core/registry.bash — Lock-protected JSON registry operations
[ "${_CORE_REGISTRY_LOADED:-}" = "1" ] && return 0
_CORE_REGISTRY_LOADED=1

REGISTRY_LOCKDIR="${REGISTRY}.lockdir"

# mkdir-based lock: atomic on all POSIX systems (works on macOS + Linux)
_registry_lock() {
  local tries=0
  while ! mkdir "$REGISTRY_LOCKDIR" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 50 ] && { log_warn "Registry lock timeout"; rm -rf "$REGISTRY_LOCKDIR"; mkdir "$REGISTRY_LOCKDIR" 2>/dev/null || true; break; }
    sleep 0.1
  done
  # Auto-cleanup stale locks (older than 30s)
  if [ -d "$REGISTRY_LOCKDIR" ]; then
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -f %m "$REGISTRY_LOCKDIR" 2>/dev/null || echo "0") ))
    [ "$lock_age" -gt 30 ] && rm -rf "$REGISTRY_LOCKDIR" && mkdir "$REGISTRY_LOCKDIR" 2>/dev/null || true
  fi
}
_registry_unlock() { rmdir "$REGISTRY_LOCKDIR" 2>/dev/null || true; }

registry_read() {
  if [ -f "$REGISTRY" ]; then cat "$REGISTRY"
  else echo '[]'; fi
}

registry_locked_write() {
  local content="$1"
  _registry_lock
  echo "$content" > "$REGISTRY"
  _registry_unlock
}

registry_add_task() {
  local task_json="$1"
  _registry_lock
  local reg
  if [ -f "$REGISTRY" ]; then reg=$(cat "$REGISTRY"); else reg='[]'; fi
  echo "$reg" | jq --argjson task "$task_json" '. += [$task]' > "$REGISTRY"
  _registry_unlock
}

_jq_update() {
  # Apply a single field=value update to a jq expression (bare array format)
  local reg="$1" task_id="$2" field="$3" value="$4"
  if [[ "$field" == *.* ]]; then
    local parent="${field%%.*}" child="${field#*.}"
    if [ "$value" = "true" ] || [ "$value" = "false" ]; then
      echo "$reg" | jq --arg id "$task_id" --arg p "$parent" --arg c "$child" --argjson v "$value" \
        '(.[] | select(.id == $id))[$p][$c] = $v'
    else
      echo "$reg" | jq --arg id "$task_id" --arg p "$parent" --arg c "$child" --arg v "$value" \
        '(.[] | select(.id == $id))[$p][$c] = $v'
    fi
  elif [ "$value" = "true" ] || [ "$value" = "false" ]; then
    echo "$reg" | jq --arg id "$task_id" --arg f "$field" --argjson v "$value" \
      '(.[] | select(.id == $id))[$f] = $v'
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$reg" | jq --arg id "$task_id" --arg f "$field" --argjson v "$value" \
      '(.[] | select(.id == $id))[$f] = $v'
  elif [ "$value" = "null" ]; then
    echo "$reg" | jq --arg id "$task_id" --arg f "$field" \
      '(.[] | select(.id == $id))[$f] = null'
  else
    echo "$reg" | jq --arg id "$task_id" --arg f "$field" --arg v "$value" \
      '(.[] | select(.id == $id))[$f] = $v'
  fi
}

registry_update_field() {
  local task_id="$1" field="$2" value="$3"
  _registry_lock
  local reg
  if [ -f "$REGISTRY" ]; then reg=$(cat "$REGISTRY"); else reg='[]'; fi
  _jq_update "$reg" "$task_id" "$field" "$value" > "$REGISTRY"
  _registry_unlock
}

# Batch update: apply multiple field=value pairs in a single lock
registry_batch_update() {
  local task_id="$1"
  shift
  _registry_lock
  local reg
  if [ -f "$REGISTRY" ]; then reg=$(cat "$REGISTRY"); else reg='[]'; fi
  while [ $# -gt 0 ]; do
    local field="${1%%=*}" value="${1#*=}"
    reg=$(_jq_update "$reg" "$task_id" "$field" "$value")
    shift
  done
  echo "$reg" > "$REGISTRY"
  _registry_unlock
}

registry_get_task() {
  local task_id="$1"
  registry_read | jq --arg id "$task_id" '.[] | select(.id == $id)'
}
