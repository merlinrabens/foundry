# core/registry_sqlite.bash — SQLite-backed registry (drop-in replacement for registry.bash)
# Foundry v4: Atomic operations, queryable history, no jq race conditions.
# Requires: sqlite3 (pre-installed on macOS)
[ "${_CORE_REGISTRY_SQLITE_LOADED:-}" = "1" ] && return 0
_CORE_REGISTRY_SQLITE_LOADED=1

REGISTRY_DB="${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}"

# ─── Init DB ─────────────────────────────────────────────────────────────
_registry_db_init() {
  [ -f "$REGISTRY_DB" ] && return 0
  sqlite3 "$REGISTRY_DB" >/dev/null 2>&1 <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    repo TEXT NOT NULL,
    repo_path TEXT NOT NULL,
    worktree TEXT,
    branch TEXT,
    tmux_session TEXT,
    pid INTEGER,
    agent TEXT DEFAULT 'codex',
    model TEXT,
    spec TEXT,
    description TEXT,
    status TEXT DEFAULT 'running',
    pr TEXT,
    pr_url TEXT,
    attempts INTEGER DEFAULT 1,
    max_attempts INTEGER DEFAULT 3,
    review_fix_attempts INTEGER DEFAULT 0,
    max_review_fixes INTEGER DEFAULT 20,
    gemini_addressed INTEGER DEFAULT 0,
    notify_on_complete INTEGER DEFAULT 1,
    last_notified_state TEXT,
    failure_reason TEXT,
    respawn_context TEXT,
    checks TEXT DEFAULT '{}',
    started_at INTEGER,
    completed_at INTEGER,
    last_checked_at INTEGER,
    openclaw_session TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT NOT NULL,
    event TEXT NOT NULL,
    details TEXT,
    created_at INTEGER DEFAULT (strftime('%s','now'))
);

CREATE TABLE IF NOT EXISTS patterns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT,
    agent TEXT,
    model TEXT,
    retries INTEGER,
    success INTEGER,
    duration_secs INTEGER,
    project TEXT,
    task_type TEXT,
    cost_estimate REAL,
    created_at INTEGER DEFAULT (strftime('%s','now'))
);

CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id);
CREATE INDEX IF NOT EXISTS idx_patterns_task ON patterns(task_id);
SQL
}

# Ensure DB exists on source
_registry_db_init

# ─── Migrations (additive, idempotent) ────────────────────────────────────
_registry_db_migrate() {
  # Add openclaw_session column if missing (legacy, kept for backward compat)
  local has_col
  has_col=$(sqlite3 "$REGISTRY_DB" "PRAGMA table_info(tasks);" 2>/dev/null | grep -c 'openclaw_session' || true)
  if [ "${has_col:-0}" -eq 0 ]; then
    sqlite3 "$REGISTRY_DB" "ALTER TABLE tasks ADD COLUMN openclaw_session TEXT;" 2>/dev/null || true
  fi

  # Add tg_topic_id column for Telegram forum topic per task
  local has_topic_col
  has_topic_col=$(sqlite3 "$REGISTRY_DB" "PRAGMA table_info(tasks);" 2>/dev/null | grep -c 'tg_topic_id' || true)
  if [ "${has_topic_col:-0}" -eq 0 ]; then
    sqlite3 "$REGISTRY_DB" "ALTER TABLE tasks ADD COLUMN tg_topic_id TEXT;" 2>/dev/null || true
  fi
}
_registry_db_migrate

# ─── Helpers ──────────────────────────────────────────────────────────────
_db() {
  sqlite3 -batch "$REGISTRY_DB" ".timeout 5000" "$@"
}

_db_json() {
  sqlite3 -json -batch "$REGISTRY_DB" ".timeout 5000" "$@"
}

# Convert a SQLite JSON row array to the legacy JSON format (camelCase keys, nested checks)
_rows_to_legacy_json() {
  local rows="$1"
  [ -z "$rows" ] || [ "$rows" = "[]" ] && { echo '[]'; return; }
  echo "$rows" | jq '
    [ .[] | {
      id,
      repo,
      repoPath: .repo_path,
      worktree,
      branch,
      tmuxSession: .tmux_session,
      pid: (.pid // null),
      agent,
      model,
      spec,
      description,
      status,
      pr,
      prUrl: .pr_url,
      attempts,
      maxAttempts: .max_attempts,
      reviewFixAttempts: .review_fix_attempts,
      maxReviewFixes: .max_review_fixes,
      geminiAddressed: (if .gemini_addressed == 1 then true elif .gemini_addressed == 0 then false else null end),
      notifyOnComplete: (if .notify_on_complete == 1 then true elif .notify_on_complete == 0 then false else null end),
      lastNotifiedState: .last_notified_state,
      failureReason: .failure_reason,
      respawnContext: (if .respawn_context then (.respawn_context | fromjson? // null) else null end),
      checks: (if .checks then (.checks | fromjson? // {}) else {} end),
      startedAt: .started_at,
      completedAt: .completed_at,
      lastCheckedAt: .last_checked_at,
      openclawSession: .openclaw_session,
      tgTopicId: .tg_topic_id
    }]'
}

_single_row_to_legacy() {
  local rows="$1"
  [ -z "$rows" ] || [ "$rows" = "[]" ] && return
  _rows_to_legacy_json "$rows" | jq '.[0]'
}

# ─── Locking (no-op for SQLite — WAL + busy_timeout handles concurrency) ─
_registry_lock() { :; }
_registry_unlock() { :; }

# ─── Public API (same signatures as registry.bash) ───────────────────────

registry_read() {
  local rows
  rows=$(_db_json "SELECT * FROM tasks;")
  _rows_to_legacy_json "$rows"
}

registry_locked_write() {
  # Full replace: delete all tasks and re-insert from JSON array
  # This is the nuclear option — used sparingly (e.g., cleanup pruning)
  local content="$1"
  local count
  count=$(echo "$content" | jq 'length')
  _db "DELETE FROM tasks;"
  if [ "$count" -gt 0 ]; then
    echo "$content" | jq -c '.[]' | while IFS= read -r task; do
      _registry_insert_task_json "$task"
    done
  fi
}

_registry_insert_task_json() {
  local t="$1"
  local id repo repo_path worktree branch tmux_session pid agent model spec description
  local status pr pr_url attempts max_attempts review_fix_attempts max_review_fixes
  local gemini_addressed notify_on_complete last_notified_state failure_reason
  local respawn_context checks started_at completed_at last_checked_at tg_topic_id

  id=$(echo "$t" | jq -r '.id')
  repo=$(echo "$t" | jq -r '.repo // ""')
  repo_path=$(echo "$t" | jq -r '.repoPath // .repo_path // ""')
  worktree=$(echo "$t" | jq -r '.worktree // ""')
  branch=$(echo "$t" | jq -r '.branch // ""')
  tmux_session=$(echo "$t" | jq -r '.tmuxSession // .tmux_session // ""')
  pid=$(echo "$t" | jq -r '.pid // ""')
  agent=$(echo "$t" | jq -r '.agent // "codex"')
  model=$(echo "$t" | jq -r '.model // ""')
  spec=$(echo "$t" | jq -r '.spec // ""')
  description=$(echo "$t" | jq -r '.description // ""')
  status=$(echo "$t" | jq -r '.status // "running"')
  pr=$(echo "$t" | jq -r '.pr // ""')
  pr_url=$(echo "$t" | jq -r '.prUrl // .pr_url // ""')
  attempts=$(echo "$t" | jq -r '.attempts // .attempts // 1')
  max_attempts=$(echo "$t" | jq -r '.maxAttempts // .max_attempts // 3')
  review_fix_attempts=$(echo "$t" | jq -r '.reviewFixAttempts // .review_fix_attempts // 0')
  max_review_fixes=$(echo "$t" | jq -r ".maxReviewFixes // .max_review_fixes // ${MAX_REVIEW_FIXES:-20}")
  gemini_addressed=$(echo "$t" | jq -r 'if (.geminiAddressed // .gemini_addressed) == true then 1 elif (.geminiAddressed // .gemini_addressed) == false then 0 else 0 end')
  notify_on_complete=$(echo "$t" | jq -r 'if (.notifyOnComplete // .notify_on_complete) == true then 1 elif (.notifyOnComplete // .notify_on_complete) == false then 0 else 1 end')
  last_notified_state=$(echo "$t" | jq -r '.lastNotifiedState // .last_notified_state // ""')
  failure_reason=$(echo "$t" | jq -r '.failureReason // .failure_reason // ""')
  respawn_context=$(echo "$t" | jq -c '.respawnContext // .respawn_context // null')
  checks=$(echo "$t" | jq -c '.checks // {}')
  started_at=$(echo "$t" | jq -r '.startedAt // .started_at // ""')
  completed_at=$(echo "$t" | jq -r '.completedAt // .completed_at // ""')
  last_checked_at=$(echo "$t" | jq -r '.lastCheckedAt // .last_checked_at // ""')
  tg_topic_id=$(echo "$t" | jq -r '.tgTopicId // .tg_topic_id // ""')

  # Normalize nulls/empty to SQL-friendly values
  [ "$pid" = "null" ] || [ "$pid" = "" ] && pid=""
  [ "$started_at" = "null" ] && started_at=""
  [ "$completed_at" = "null" ] && completed_at=""
  [ "$last_checked_at" = "null" ] && last_checked_at=""
  [ "$respawn_context" = "null" ] && respawn_context=""
  [ "$spec" = "null" ] && spec=""
  [ "$pr" = "null" ] && pr=""
  [ "$pr_url" = "null" ] && pr_url=""
  [ "$failure_reason" = "null" ] && failure_reason=""
  [ "$last_notified_state" = "null" ] && last_notified_state=""
  [ "$tg_topic_id" = "null" ] && tg_topic_id=""

  _db "INSERT OR REPLACE INTO tasks (
    id, repo, repo_path, worktree, branch, tmux_session, pid, agent, model,
    spec, description, status, pr, pr_url, attempts, max_attempts,
    review_fix_attempts, max_review_fixes, gemini_addressed, notify_on_complete,
    last_notified_state, failure_reason, respawn_context, checks,
    started_at, completed_at, last_checked_at, tg_topic_id
  ) VALUES (
    '$(echo "$id" | sed "s/'/''/g")',
    '$(echo "$repo" | sed "s/'/''/g")',
    '$(echo "$repo_path" | sed "s/'/''/g")',
    '$(echo "$worktree" | sed "s/'/''/g")',
    '$(echo "$branch" | sed "s/'/''/g")',
    '$(echo "$tmux_session" | sed "s/'/''/g")',
    $([ -n "$pid" ] && echo "$pid" || echo "NULL"),
    '$(echo "$agent" | sed "s/'/''/g")',
    '$(echo "$model" | sed "s/'/''/g")',
    $([ -n "$spec" ] && echo "'$(echo "$spec" | sed "s/'/''/g")'" || echo "NULL"),
    '$(echo "$description" | sed "s/'/''/g")',
    '$(echo "$status" | sed "s/'/''/g")',
    $([ -n "$pr" ] && echo "'$(echo "$pr" | sed "s/'/''/g")'" || echo "NULL"),
    $([ -n "$pr_url" ] && echo "'$(echo "$pr_url" | sed "s/'/''/g")'" || echo "NULL"),
    $attempts, $max_attempts, $review_fix_attempts, $max_review_fixes,
    $gemini_addressed, $notify_on_complete,
    $([ -n "$last_notified_state" ] && echo "'$(echo "$last_notified_state" | sed "s/'/''/g")'" || echo "NULL"),
    $([ -n "$failure_reason" ] && echo "'$(echo "$failure_reason" | sed "s/'/''/g")'" || echo "NULL"),
    $([ -n "$respawn_context" ] && echo "'$(echo "$respawn_context" | sed "s/'/''/g")'" || echo "NULL"),
    '$(echo "$checks" | sed "s/'/''/g")',
    $([ -n "$started_at" ] && echo "$started_at" || echo "NULL"),
    $([ -n "$completed_at" ] && echo "$completed_at" || echo "NULL"),
    $([ -n "$last_checked_at" ] && echo "$last_checked_at" || echo "NULL"),
    $([ -n "$tg_topic_id" ] && echo "'$(echo "$tg_topic_id" | sed "s/'/''/g")'" || echo "NULL")
  );"
}

registry_add_task() {
  local task_json="$1"
  _registry_insert_task_json "$task_json"
  # Log event
  local id
  id=$(echo "$task_json" | jq -r '.id')
  registry_log_event "$id" "spawned" "Task added to registry"
}

# Map camelCase field names to snake_case columns
_field_to_column() {
  local field="$1"
  case "$field" in
    repoPath)            echo "repo_path" ;;
    tmuxSession)         echo "tmux_session" ;;
    prUrl)               echo "pr_url" ;;
    maxAttempts)         echo "max_attempts" ;;
    reviewFixAttempts)   echo "review_fix_attempts" ;;
    maxReviewFixes)      echo "max_review_fixes" ;;
    geminiAddressed)     echo "gemini_addressed" ;;
    notifyOnComplete)    echo "notify_on_complete" ;;
    lastNotifiedState)   echo "last_notified_state" ;;
    failureReason)       echo "failure_reason" ;;
    respawnContext)      echo "respawn_context" ;;
    openclawSession)     echo "openclaw_session" ;;
    tgTopicId)           echo "tg_topic_id" ;;
    startedAt)           echo "started_at" ;;
    completedAt)         echo "completed_at" ;;
    lastCheckedAt)       echo "last_checked_at" ;;
    # Nested checks fields: checks.ciPassed → checks JSON blob update
    checks.*)            echo "$field" ;;
    *)                   echo "$field" ;;
  esac
}

# Convert value for SQLite (booleans → 0/1 for columns, or JSON update for checks)
_sql_value() {
  local col="$1" value="$2"
  case "$value" in
    "")  echo "NULL" ;;
    true)
      case "$col" in
        gemini_addressed|notify_on_complete) echo "1" ;;
        *) echo "'true'" ;;
      esac
      ;;
    false)
      case "$col" in
        gemini_addressed|notify_on_complete) echo "0" ;;
        *) echo "'false'" ;;
      esac
      ;;
    null) echo "NULL" ;;
    *[!0-9]*) echo "'$(echo "$value" | sed "s/'/''/g")'" ;;
    *) echo "$value" ;;
  esac
}

registry_update_field() {
  local task_id="$1" field="$2" value="$3"
  local col
  col=$(_field_to_column "$field")

  if [[ "$col" == checks.* ]]; then
    # Update nested checks JSON: checks.ciPassed = true → json_set(checks, '$.ciPassed', true)
    local check_key="${col#checks.}"
    local json_val
    case "$value" in
      true|false) json_val="$value" ;;
      null)       json_val="null" ;;
      *[!0-9]*)  json_val="\"$(echo "$value" | sed 's/"/\\"/g')\"" ;;
      *)          json_val="$value" ;;
    esac
    _db "UPDATE tasks SET checks = json_set(checks, '\$.${check_key}', json('${json_val}')) WHERE id = '$(echo "$task_id" | sed "s/'/''/g")';"
  else
    local sql_val
    sql_val=$(_sql_value "$col" "$value")
    _db "UPDATE tasks SET ${col} = ${sql_val} WHERE id = '$(echo "$task_id" | sed "s/'/''/g")';"
  fi
}

registry_batch_update() {
  local task_id="$1"
  shift
  # Build a single transaction for all updates
  local sql="BEGIN TRANSACTION;"
  local escaped_id
  escaped_id=$(echo "$task_id" | sed "s/'/''/g")

  while [ $# -gt 0 ]; do
    local field="${1%%=*}" value="${1#*=}"
    local col
    col=$(_field_to_column "$field")

    if [[ "$col" == checks.* ]]; then
      local check_key="${col#checks.}"
      local json_val
      case "$value" in
        true|false) json_val="$value" ;;
        null)       json_val="null" ;;
        *[!0-9]*)  json_val="\"$(echo "$value" | sed 's/"/\\"/g')\"" ;;
        *)          json_val="$value" ;;
      esac
      sql+=" UPDATE tasks SET checks = json_set(checks, '\$.${check_key}', json('${json_val}')) WHERE id = '${escaped_id}';"
    else
      local sql_val
      sql_val=$(_sql_value "$col" "$value")
      sql+=" UPDATE tasks SET ${col} = ${sql_val} WHERE id = '${escaped_id}';"
    fi
    shift
  done

  sql+=" COMMIT;"
  _db "$sql"
}

registry_get_task() {
  local task_id="$1"
  local rows
  rows=$(_db_json "SELECT * FROM tasks WHERE id = '$(echo "$task_id" | sed "s/'/''/g")';")
  _single_row_to_legacy "$rows"
}

# ─── Event Logging ───────────────────────────────────────────────────────

registry_log_event() {
  local task_id="$1" event="$2" details="${3:-}"
  local escaped_id escaped_event escaped_details
  escaped_id=$(echo "$task_id" | sed "s/'/''/g")
  escaped_event=$(echo "$event" | sed "s/'/''/g")
  escaped_details=$(echo "$details" | sed "s/'/''/g")
  _db "INSERT INTO events (task_id, event, details) VALUES ('${escaped_id}', '${escaped_event}', '${escaped_details}');"
}

# ─── Pattern Logging (SQLite version) ────────────────────────────────────

pattern_log_sqlite() {
  local task_id="$1" agent="$2" model="$3" retries="$4" success="$5"
  local duration="$6" project="$7" task_type="$8"

  local estimated_cost="0"
  if command -v bc >/dev/null 2>&1 && [ "$duration" -gt 0 ]; then
    case "$agent" in
      codex)  estimated_cost=$(echo "scale=2; $duration * 0.002" | bc 2>/dev/null || echo "0") ;;
      claude) estimated_cost=$(echo "scale=2; $duration * 0.005" | bc 2>/dev/null || echo "0") ;;
      gemini) estimated_cost=$(echo "scale=2; $duration * 0.001" | bc 2>/dev/null || echo "0") ;;
    esac
  fi

  _db "INSERT INTO patterns (task_id, agent, model, retries, success, duration_secs, project, task_type, cost_estimate)
    VALUES ('$(echo "$task_id" | sed "s/'/''/g")', '$(echo "$agent" | sed "s/'/''/g")', '$(echo "$model" | sed "s/'/''/g")',
    $retries, $success, $duration, '$(echo "$project" | sed "s/'/''/g")', '$(echo "$task_type" | sed "s/'/''/g")', $estimated_cost);"
}

# ─── Query Helpers (new capabilities) ────────────────────────────────────

registry_count_by_status() {
  local status="$1"
  _db "SELECT COUNT(*) FROM tasks WHERE status = '$(echo "$status" | sed "s/'/''/g")';"
}

registry_active_count() {
  _db "SELECT COUNT(*) FROM tasks WHERE status IN ('running', 'pr-open', 'ready', 'deploy-failed');"
}

registry_task_ids_by_status() {
  local status="$1"
  _db "SELECT id FROM tasks WHERE status = '$(echo "$status" | sed "s/'/''/g")';" | tr '\n' ' '
}

registry_recent_events() {
  local task_id="$1" limit="${2:-10}"
  _db_json "SELECT * FROM events WHERE task_id = '$(echo "$task_id" | sed "s/'/''/g")' ORDER BY created_at DESC LIMIT $limit;"
}

registry_delete_task() {
  local task_id="$1"
  local escaped_id
  escaped_id=$(echo "$task_id" | sed "s/'/''/g")
  _db "DELETE FROM tasks WHERE id = '${escaped_id}';"
  registry_log_event "$task_id" "deleted" "Task removed from registry"
}
