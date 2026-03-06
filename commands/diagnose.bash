# commands/diagnose.bash — Self-repair diagnostics for Foundry infrastructure
#
# Usage: foundry diagnose [--fix]
#   --fix    Auto-repair: mark stuck→crashed, delete stale logs, report orphans

cmd_diagnose() {
  local FIX=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix)  FIX=1; shift ;;
      *)      shift ;;
    esac
  done

  local issues=0 fixed=0
  echo "=== Foundry Diagnostics ==="
  echo ""

  # ─── 1. Stuck Tasks ──────────────────────────────────────────────────────
  # Status "running" but process dead AND no .done file
  echo "▸ Checking for stuck tasks..."
  local tasks
  tasks=$(registry_read)
  local count
  count=$(echo "$tasks" | jq 'length')

  for i in $(seq 0 $((count - 1))); do
    local task
    task=$(echo "$tasks" | jq ".[$i]")
    local id task_status pid
    id=$(echo "$task" | jq -r '.id')
    task_status=$(echo "$task" | jq -r '.status')
    pid=$(echo "$task" | jq -r '.pid // empty')

    [ "$task_status" != "running" ] && continue

    local done_file="${FOUNDRY_DIR}/logs/${id}.done"
    local alive=0

    # Check PID liveness
    if [ -n "$pid" ] && [ "$pid" != "null" ] && kill -0 "$pid" 2>/dev/null; then
      alive=1
    fi

    if [ "$alive" -eq 0 ] && [ ! -f "$done_file" ]; then
      echo -e "  ${RED}STUCK${NC}: $id (status=running, no process, no .done file)"
      issues=$((issues + 1))
      if [ "$FIX" -eq 1 ]; then
        registry_update_field "$id" "status" "crashed"
        registry_update_field "$id" "failureReason" "Diagnosed as stuck: no process or done file"
        if type registry_log_event &>/dev/null; then
          registry_log_event "$id" "diagnosed-stuck" "Auto-marked crashed by foundry diagnose --fix"
        fi
        echo -e "  ${GREEN}FIXED${NC}: Marked as crashed (will auto-respawn on next check)"
        fixed=$((fixed + 1))
      fi
    fi
  done

  # ─── 2. Orphaned Worktrees ──────────────────────────────────────────────
  echo "▸ Checking for orphaned worktrees..."
  local known_worktrees
  known_worktrees=$(echo "$tasks" | jq -r '.[].worktree // empty' | sort)

  for project_dir in "$HOME"/projects/*/; do
    [ ! -d "$project_dir" ] && continue
    for foundry_dir in "${project_dir}"*-foundry/*/; do
      [ ! -d "$foundry_dir" ] && continue
      local normalized
      normalized=$(cd "$foundry_dir" 2>/dev/null && pwd)
      if ! echo "$known_worktrees" | grep -qF "$normalized"; then
        local size
        size=$(du -sh "$foundry_dir" 2>/dev/null | cut -f1)
        echo -e "  ${YELLOW}ORPHAN${NC}: $foundry_dir ($size)"
        issues=$((issues + 1))
      fi
    done
  done

  # ─── 3. Missing CI Secrets ──────────────────────────────────────────────
  echo "▸ Checking CI secrets on known repos..."
  for repo_path in "${KNOWN_PROJECTS[@]}"; do
    [ ! -d "$repo_path" ] && continue
    local repo_name
    repo_name=$(basename "$repo_path")
    local slug
    slug=$(cd "$repo_path" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    [ -z "$slug" ] && continue

    for secret in OPENAI_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
      if ! gh secret list -R "$slug" 2>/dev/null | grep -q "^$secret"; then
        echo -e "  ${YELLOW}MISSING${NC}: $slug → $secret"
        issues=$((issues + 1))
      fi
    done
  done

  # ─── 4. Registry Integrity ─────────────────────────────────────────────
  echo "▸ Checking registry integrity..."

  # Duplicate IDs
  local dupes
  dupes=$(echo "$tasks" | jq '[.[].id] | group_by(.) | map(select(length > 1)) | map(.[0])' 2>/dev/null)
  local dupe_count
  dupe_count=$(echo "$dupes" | jq 'length')
  if [ "$dupe_count" -gt 0 ]; then
    echo -e "  ${RED}DUPLICATE IDs${NC}: $(echo "$dupes" | jq -r '.[]')"
    issues=$((issues + 1))
  fi

  # Invalid statuses
  local valid_statuses='["running","pr-open","ready","merged","closed","ci-failed","review-failed","deploy-failed","needs-respawn","exhausted","crashed","timeout","done","done-no-pr","killed","completed"]'
  local invalid
  invalid=$(echo "$tasks" | jq --argjson valid "$valid_statuses" '[.[] | select(.status as $s | $valid | index($s) | not) | .id + "=" + .status]')
  local invalid_count
  invalid_count=$(echo "$invalid" | jq 'length')
  if [ "$invalid_count" -gt 0 ]; then
    echo -e "  ${RED}INVALID STATUS${NC}: $(echo "$invalid" | jq -r '.[]')"
    issues=$((issues + 1))
  fi

  # Missing required fields
  local missing_fields
  missing_fields=$(echo "$tasks" | jq '[.[] | select(.id == null or .id == "" or .repo == null or .repo == "") | .id // "unknown"]')
  local missing_count
  missing_count=$(echo "$missing_fields" | jq 'length')
  if [ "$missing_count" -gt 0 ]; then
    echo -e "  ${RED}MISSING FIELDS${NC}: Tasks without id or repo"
    issues=$((issues + 1))
  fi

  # ─── 5. Disk Usage ─────────────────────────────────────────────────────
  echo "▸ Checking disk usage..."
  for i in $(seq 0 $((count - 1))); do
    local wt
    wt=$(echo "$tasks" | jq -r ".[$i].worktree // empty")
    [ -z "$wt" ] || [ ! -d "$wt" ] && continue
    local size_bytes
    size_bytes=$(du -s "$wt" 2>/dev/null | cut -f1)
    if [ "${size_bytes:-0}" -gt 1048576 ]; then  # >1GB (in 512-byte blocks on macOS)
      local size_human
      size_human=$(du -sh "$wt" 2>/dev/null | cut -f1)
      local task_id
      task_id=$(echo "$tasks" | jq -r ".[$i].id")
      echo -e "  ${YELLOW}LARGE${NC}: $task_id → $size_human ($wt)"
      issues=$((issues + 1))
    fi
  done

  # ─── 6. Stale Logs ─────────────────────────────────────────────────────
  echo "▸ Checking for stale logs..."
  local stale_count=0
  local stale_size=0
  local now
  now=$(date +%s)
  local seven_days=$((7 * 86400))

  local _stale_files=()
  for _pattern in "${FOUNDRY_DIR}/logs/"*.done "${FOUNDRY_DIR}/logs/"*.log; do
    [ -f "$_pattern" ] && _stale_files+=("$_pattern")
  done
  for f in "${_stale_files[@]}"; do
    local file_age
    file_age=$(( now - $(stat -f %m "$f" 2>/dev/null || echo "$now") ))
    if [ "$file_age" -gt "$seven_days" ]; then
      stale_count=$((stale_count + 1))
      if [ "$FIX" -eq 1 ]; then
        rm -f "$f"
        fixed=$((fixed + 1))
      fi
    fi
  done
  if [ "$stale_count" -gt 0 ]; then
    echo -e "  ${YELLOW}STALE${NC}: $stale_count log/done files older than 7 days"
    issues=$((issues + 1))
    if [ "$FIX" -eq 1 ]; then
      echo -e "  ${GREEN}FIXED${NC}: Deleted $stale_count stale files"
    fi
  fi

  # ─── 7. ACP Adapters ───────────────────────────────────────────────────
  echo "▸ Checking ACP adapters..."
  for adapter in claude-agent-acp codex-acp gemini openclaw; do
    if ! command -v "$adapter" >/dev/null 2>&1; then
      echo -e "  ${YELLOW}MISSING${NC}: $adapter not found in PATH"
      issues=$((issues + 1))
    else
      echo -e "  ${GREEN}OK${NC}: $adapter"
    fi
  done

  # ─── 8. SQLite Registry Health ──────────────────────────────────────────
  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ] && [ -f "${REGISTRY_DB:-}" ]; then
    echo "▸ Checking SQLite registry..."
    local integrity
    integrity=$(sqlite3 "$REGISTRY_DB" "PRAGMA integrity_check;" 2>/dev/null || echo "error")
    if [ "$integrity" = "ok" ]; then
      echo -e "  ${GREEN}OK${NC}: Database integrity check passed"
      local db_size
      db_size=$(du -sh "$REGISTRY_DB" 2>/dev/null | cut -f1)
      echo "  Size: $db_size | Tasks: $(sqlite3 "$REGISTRY_DB" 'SELECT COUNT(*) FROM tasks;') | Events: $(sqlite3 "$REGISTRY_DB" 'SELECT COUNT(*) FROM events;') | Patterns: $(sqlite3 "$REGISTRY_DB" 'SELECT COUNT(*) FROM patterns;')"
    else
      echo -e "  ${RED}CORRUPT${NC}: Database integrity check failed"
      issues=$((issues + 1))
    fi
  fi

  # ─── Summary ────────────────────────────────────────────────────────────
  echo ""
  if [ "$issues" -eq 0 ]; then
    echo -e "${GREEN}All clear — no issues found.${NC}"
  else
    echo -e "${YELLOW}Found $issues issue(s)."
    if [ "$FIX" -eq 1 ]; then
      echo -e "Fixed $fixed.${NC}"
    else
      echo -e "Run 'foundry diagnose --fix' to auto-repair.${NC}"
    fi
  fi

  return "$issues"
}
