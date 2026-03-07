#!/bin/bash
# check-agents.sh — Zero-token health monitor for the Foundry
# Standalone. No AI calls. No tokens consumed. Runs in <2 seconds for 10 tasks.
# Reads active-tasks.json, checks each running/pr-open/ready task, updates state.
#
# Usage: check-agents.sh [--quiet] [--no-notify] [--json]
#   --quiet     Suppress status line output
#   --no-notify Skip Telegram notifications
#   --json      Output JSON summary instead of formatted lines

set -eo pipefail

# ─── Options ──────────────────────────────────────────────────────────────
QUIET=0
NO_NOTIFY=0
JSON_OUTPUT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)     QUIET=1; shift ;;
    --no-notify) NO_NOTIFY=1; shift ;;
    --json)      JSON_OUTPUT=1; shift ;;
    *)           shift ;;
  esac
done

# ─── Resolve paths ────────────────────────────────────────────────────────
_SCRIPT="${BASH_SOURCE[0]}"
while [ -L "$_SCRIPT" ]; do
  _DIR="$(cd "$(dirname "$_SCRIPT")" && pwd)"
  _SCRIPT="$(readlink "$_SCRIPT")"
  [[ "$_SCRIPT" != /* ]] && _SCRIPT="$_DIR/$_SCRIPT"
done
FOUNDRY_DIR="$(cd "$(dirname "$_SCRIPT")" && pwd)"
SWARM_DIR="${FOUNDRY_DIR}"  # backward compat alias
unset _SCRIPT _DIR

source "${FOUNDRY_DIR}/config.env"

# ─── Preflight ────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required"; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh required"; exit 1; }

REGISTRY="${FOUNDRY_DIR}/active-tasks.json"
REGISTRY_LOCKDIR="${REGISTRY}.lockdir"
LOGS_DIR="${FOUNDRY_DIR}/logs"
NOW=$(date +%s)

# ─── Colors ───────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Locking (same mkdir-based as foundry CLI) ──────────────────────────────
_lock() {
  local tries=0
  while ! mkdir "$REGISTRY_LOCKDIR" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -gt 50 ] && { rm -rf "$REGISTRY_LOCKDIR"; mkdir "$REGISTRY_LOCKDIR" 2>/dev/null || true; break; }
    sleep 0.1
  done
  # Auto-cleanup stale locks (older than 30s)
  if [ -d "$REGISTRY_LOCKDIR" ]; then
    local lock_age
    lock_age=$(( NOW - $(stat -f %m "$REGISTRY_LOCKDIR" 2>/dev/null || echo "0") ))
    [ "$lock_age" -gt 30 ] && rm -rf "$REGISTRY_LOCKDIR" && mkdir "$REGISTRY_LOCKDIR" 2>/dev/null || true
  fi
}
_unlock() { rmdir "$REGISTRY_LOCKDIR" 2>/dev/null || true; }

# ─── gh retry wrapper ────────────────────────────────────────────────────
gh_retry() {
  local max=3 delay=1 out
  for ((i=1; i<=max; i++)); do
    out=$("$@" 2>/dev/null) && { echo "$out"; return 0; }
    [ "$i" -lt "$max" ] && sleep "$delay" && delay=$((delay * 2))
  done
  return 1
}

# ─── Telegram ─────────────────────────────────────────────────────────────
TG_CHAT_ID="${TG_CHAT_ID:-}"

tg_notify() {
  [ "$NO_NOTIFY" -eq 1 ] && return 0
  local message="$1"
  local bot_token="${OPENCLAW_TG_BOT_TOKEN:-}"

  if [ -z "$bot_token" ]; then
    bot_token=$(python3 -c "
import json
try:
    cfg = json.loads(open('$HOME/.openclaw/openclaw.json').read())
    v = cfg.get('env',{}).get('vars',{})
    print(v.get('OPENCLAW_TG_BOT_TOKEN','') or v.get('TELEGRAM_BOT_TOKEN',''))
except: pass
" 2>/dev/null)
  fi

  [ -z "$bot_token" ] && return 0

  curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=$message" \
    --data-urlencode "parse_mode=Markdown" \
    --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || true
}

# ─── Smart Skip: bail fast when no active tasks ──────────────────────────
# SQLite path: single query, no jq overhead. JSON path: quick jq check.
if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ] && [ -f "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" ]; then
  ACTIVE_COUNT=$(sqlite3 -batch "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" \
    "SELECT COUNT(*) FROM tasks WHERE status IN ('running','pr-open','ready','deploy-failed','ci-failed','review-failed','needs-respawn');" 2>/dev/null || echo "0")

  # Normalize unknown statuses: tasks with a PR but unrecognized status → pr-open
  sqlite3 -batch "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" "
    UPDATE tasks SET status='pr-open'
    WHERE status NOT IN ('running','pr-open','ready','deploy-failed','ci-failed',
      'review-failed','needs-respawn','merged','closed','exhausted','done-no-pr',
      'failed','cancelled','killed','queued')
    AND pr IS NOT NULL AND pr != '';
  " 2>/dev/null || true
  # Tasks with unknown status and no PR → failed
  sqlite3 -batch "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" "
    UPDATE tasks SET status='failed'
    WHERE status NOT IN ('running','pr-open','ready','deploy-failed','ci-failed',
      'review-failed','needs-respawn','merged','closed','exhausted','done-no-pr',
      'failed','cancelled','killed','queued')
    AND (pr IS NULL OR pr = '');
  " 2>/dev/null || true

  if [ "$ACTIVE_COUNT" -eq 0 ]; then
    [ "$QUIET" -eq 0 ] && echo "No active tasks (smart-skip)."
    exit 0
  fi
fi

# ─── Read registry ────────────────────────────────────────────────────────
if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ] && [ -f "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" ]; then
  # Read from SQLite, convert to legacy JSON format for the rest of the script
  _SQLITE_ROWS=$(sqlite3 -json -batch "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" "SELECT * FROM tasks;" 2>/dev/null || echo "[]")
  TASKS=$(echo "$_SQLITE_ROWS" | jq '
    [ .[] | {
      id, repo, repoPath: .repo_path, worktree, branch,
      tmuxSession: .tmux_session, pid: (.pid // null), agent, model,
      spec, description, status, pr, prUrl: .pr_url,
      attempts, maxAttempts: .max_attempts,
      reviewFixAttempts: .review_fix_attempts, maxReviewFixes: .max_review_fixes,
      geminiAddressed: (if .gemini_addressed == 1 then true else false end),
      notifyOnComplete: (if .notify_on_complete == 1 then true else false end),
      lastNotifiedState: .last_notified_state, failureReason: .failure_reason,
      respawnContext: (if .respawn_context then (.respawn_context | fromjson? // null) else null end),
      checks: (if .checks then (.checks | fromjson? // {}) else {} end),
      startedAt: .started_at, completedAt: .completed_at, lastCheckedAt: .last_checked_at
    }]' 2>/dev/null || echo "[]")
else
  if [ ! -f "$REGISTRY" ]; then
    echo "No active-tasks.json found. Run migrate-to-sqlite.sh first."
    exit 0
  fi
  TASKS=$(cat "$REGISTRY")
fi

TASK_COUNT=$(echo "$TASKS" | jq 'length')

if [ "$TASK_COUNT" -eq 0 ]; then
  [ "$QUIET" -eq 0 ] && echo "No tasks in registry."
  exit 0
fi

# ─── Get GitHub org for each repo (cached per repoPath) ───────────────────
# Cache via temp files (macOS default bash 3.x lacks associative arrays)
_SLUG_CACHE_DIR=$(mktemp -d)
trap "rm -rf '$_SLUG_CACHE_DIR'" EXIT

get_repo_slug() {
  local repo_path="$1"
  local cache_key
  cache_key=$(echo "$repo_path" | sed 's/[^a-zA-Z0-9]/_/g')
  local cache_file="${_SLUG_CACHE_DIR}/${cache_key}"
  if [ -f "$cache_file" ]; then
    cat "$cache_file"
    return
  fi
  local slug=""
  if [ -d "$repo_path" ]; then
    slug=$(cd "$repo_path" 2>/dev/null && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
  fi
  echo "$slug" > "$cache_file"
  echo "$slug"
}

# ─── Collect output for JSON mode ─────────────────────────────────────────
JSON_RESULTS="[]"

# ─── Registry update helper (batched — one lock per task) ─────────────────
# Routes to SQLite when available, falls back to JSON
registry_update() {
  local task_id="$1"
  shift

  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ] && [ -f "${REGISTRY_DB:-${FOUNDRY_DIR}/foundry.db}" ]; then
    # SQLite path: use core registry functions
    # Source them if not already loaded
    if ! type registry_batch_update &>/dev/null; then
      source "${FOUNDRY_DIR}/core/registry_sqlite.bash"
    fi
    registry_batch_update "$task_id" "$@"
    return
  fi

  # JSON fallback path
  local filter='.'
  while [ $# -gt 0 ]; do
    local field="${1%%=*}" value="${1#*=}"
    if [[ "$field" == checks.* ]]; then
      local check_field="${field#checks.}"
      if [ "$value" = "true" ] || [ "$value" = "false" ] || [ "$value" = "null" ]; then
        filter="${filter} | (.[] | select(.id == \"${task_id}\")).checks.${check_field} = ${value}"
      elif [[ "$value" =~ ^[0-9]+$ ]]; then
        filter="${filter} | (.[] | select(.id == \"${task_id}\")).checks.${check_field} = ${value}"
      else
        filter="${filter} | (.[] | select(.id == \"${task_id}\")).checks.${check_field} = \"${value}\""
      fi
    elif [ "$value" = "true" ] || [ "$value" = "false" ] || [ "$value" = "null" ]; then
      filter="${filter} | (.[] | select(.id == \"${task_id}\")).${field} = ${value}"
    elif [[ "$value" =~ ^[0-9]+$ ]]; then
      filter="${filter} | (.[] | select(.id == \"${task_id}\")).${field} = ${value}"
    else
      local escaped_value="${value//\"/\\\"}"
      filter="${filter} | (.[] | select(.id == \"${task_id}\")).${field} = \"${escaped_value}\""
    fi
    shift
  done

  _lock
  local current
  current=$(cat "$REGISTRY")
  echo "$current" | jq "$filter" > "$REGISTRY"
  _unlock
}

# ─── Safe jq field extraction (one jq call per task) ──────────────────────
# Returns a bash-eval-safe assignment block
extract_task_fields() {
  local task_json="$1"
  echo "$task_json" | jq -r '
    @sh "T_ID=\(.id) T_STATUS=\(.status) T_REPO=\(.repo) T_REPO_PATH=\(.repoPath) T_WORKTREE=\(.worktree) T_BRANCH=\(.branch) T_TMUX=\(.tmuxSession) T_PID_REG=\(.pid // "") T_AGENT=\(.agent) T_MODEL=\(.model) T_STARTED=\(.startedAt) T_ATTEMPTS=\(.attempts) T_MAX_ATTEMPTS=\(.maxAttempts) T_PR=\(.pr) T_PR_URL=\(.prUrl) T_LAST_NOTIFIED=\(.lastNotifiedState) T_NOTIFY=\(.notifyOnComplete)"
  '
}

# ─── Output helper ─────────────────────────────────────────────────────────
emit() {
  local status_tag="$1" task_id="$2" details="$3"
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    JSON_RESULTS=$(echo "$JSON_RESULTS" | jq --arg s "$status_tag" --arg id "$task_id" --arg d "$details" \
      '. + [{status: $s, id: $id, details: $d}]')
  elif [ "$QUIET" -eq 0 ]; then
    local color
    case "$status_tag" in
      RUNNING)   color="$BLUE" ;;
      READY)     color="$GREEN" ;;
      MERGED)    color="$GREEN" ;;
      FAILED)    color="$RED" ;;
      EXHAUSTED) color="$RED" ;;
      NEEDS-RESPAWN) color="$YELLOW" ;;
      PR-OPEN)   color="$CYAN" ;;
      *)         color="$NC" ;;
    esac
    printf "[${color}%-13s${NC}] %-40s %s\n" "$status_tag" "$task_id" "— $details"
  fi
}

# ─── Process each monitorable task ────────────────────────────────────────
MONITORABLE_STATUSES='["running", "pr-open", "ready", "deploy-failed", "ci-failed", "review-failed", "needs-respawn"]'

for idx in $(seq 0 $((TASK_COUNT - 1))); do
  TASK=$(echo "$TASKS" | jq ".[$idx]")
  T_STATUS=$(echo "$TASK" | jq -r '.status')

  # Skip non-monitorable statuses
  if ! echo "$MONITORABLE_STATUSES" | jq -e "index(\"$T_STATUS\")" >/dev/null 2>&1; then
    continue
  fi

  # Extract all fields in one jq call
  eval "$(extract_task_fields "$TASK")"

  # Normalize null strings
  [ "$T_TMUX" = "null" ] && T_TMUX=""
  [ "$T_PR" = "null" ] && T_PR=""
  [ "$T_PR_URL" = "null" ] && T_PR_URL=""
  [ "$T_LAST_NOTIFIED" = "null" ] && T_LAST_NOTIFIED=""
  [ "$T_WORKTREE" = "null" ] && T_WORKTREE=""

  # Derive log/done file paths from ID
  LOG_FILE="${LOGS_DIR}/${T_ID}.log"
  DONE_FILE="${LOGS_DIR}/${T_ID}.done"

  # Get repo slug (cached)
  REPO_SLUG=$(get_repo_slug "$T_REPO_PATH")

  # ─── Check 1: Agent process alive? (PID-based liveness) ──
  AGENT_ALIVE=false
  T_PID=$(echo "$TASK" | jq -r '.pid // empty')
  [ "$T_PID" = "null" ] && T_PID=""

  if [ -n "$T_PID" ] && kill -0 "$T_PID" 2>/dev/null; then
    AGENT_ALIVE=true
  fi

  # ─── Check 2: Agent finished? (done marker) ────────────────────────
  AGENT_DONE=false
  AGENT_EXIT_CODE=""
  if [ -f "$DONE_FILE" ]; then
    AGENT_DONE=true
    AGENT_EXIT_CODE=$(cat "$DONE_FILE" 2>/dev/null || echo "")
  fi

  # ─── Check 3: PR exists? ──────────────────────────────────────────
  PR_NUMBER=""
  PR_STATE=""
  PR_URL="${T_PR_URL:-}"  # Seed from registry prUrl (handles cross-repo PRs)
  if [ -n "$T_PR" ] && [[ "$T_PR" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="$T_PR"
  elif [ -n "$T_PR" ] && [[ "$T_PR" =~ ^https:// ]]; then
    PR_NUMBER=$(echo "$T_PR" | grep -o '[0-9]*$' || echo "")
  fi

  # If no PR in registry, try to find it from branch
  if [ -z "$PR_NUMBER" ] && [ -n "$REPO_SLUG" ]; then
    local_pr=$(gh_retry gh pr list --head "$T_BRANCH" --repo "$REPO_SLUG" --json number,state,url --jq 'if length > 0 then .[0] | "\(.number) \(.state) \(.url)" else empty end' 2>/dev/null || echo "")
    if [ -n "$local_pr" ]; then
      PR_NUMBER=$(echo "$local_pr" | awk '{print $1}')
      PR_STATE=$(echo "$local_pr" | awk '{print $2}')
      PR_URL=$(echo "$local_pr" | awk '{print $3}')
    fi
  fi
  # Guard against jq returning literal "null" strings
  [ "$PR_NUMBER" = "null" ] && PR_NUMBER=""
  [ "$PR_STATE" = "null" ] && PR_STATE=""
  [ "$PR_URL" = "null" ] && PR_URL=""

  # If we have a PR number, get its state
  # Use repo slug from prUrl if available (handles cross-repo PRs like primal-theme vs aura-shopify)
  pr_repo_slug="$REPO_SLUG"
  if [ -n "$T_PR_URL" ] && [[ "$T_PR_URL" =~ github\.com/([^/]+/[^/]+)/pull ]]; then
    pr_repo_slug="${BASH_REMATCH[1]}"
  fi
  if [ -n "$PR_NUMBER" ] && [ -z "$PR_STATE" ] && [ -n "$pr_repo_slug" ]; then
    pr_info=$(gh_retry gh pr view "$PR_NUMBER" --repo "$pr_repo_slug" --json state,url --jq '"\(.state) \(.url)"' 2>/dev/null || echo "")
    if [ -n "$pr_info" ]; then
      PR_STATE=$(echo "$pr_info" | awk '{print $1}')
      PR_URL=$(echo "$pr_info" | awk '{print $2}')
    fi
  fi

  # ─── Handle merged/closed PRs immediately ──────────────────────────
  if [ "$PR_STATE" = "MERGED" ]; then
    registry_update "$T_ID" "status=merged" "completedAt=$NOW" "lastCheckedAt=$NOW" "checks.prCreated=true"
    [ "$T_LAST_NOTIFIED" != "merged" ] && {
      tg_notify "Merged: \`$T_ID\` — [PR #$PR_NUMBER](${PR_URL:-https://github.com})"
      registry_update "$T_ID" "lastNotifiedState=merged"
    }
    emit "MERGED" "$T_ID" "PR:#$PR_NUMBER merged"
    continue
  fi

  if [ "$PR_STATE" = "CLOSED" ]; then
    registry_update "$T_ID" "status=closed" "completedAt=$NOW" "lastCheckedAt=$NOW"
    emit "CLOSED" "$T_ID" "PR:#$PR_NUMBER closed without merge"
    continue
  fi

  # ─── Check 4: CI status ────────────────────────────────────────────
  CI_PASSED=""
  CI_FAILING=""
  CI_PENDING=""
  CI_FAIL_NAMES=""
  if [ -n "$PR_NUMBER" ] && [ -n "$REPO_SLUG" ]; then
    checks_raw=$(gh_retry gh pr checks "$PR_NUMBER" --repo "$REPO_SLUG" --json name,state,completedAt 2>/dev/null || echo "[]")
    # Deduplicate by name, keep latest
    checks_deduped=$(echo "$checks_raw" | jq '[group_by(.name)[] | sort_by(.completedAt // "") | last]' 2>/dev/null || echo "$checks_raw")

    # Check if PR modifies workflow files (chicken-and-egg: review workflows fail on PRs that change them)
    modifies_workflows=0
    changed_files=$(gh_retry gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json files --jq '[.files[].path] | join("\n")' 2>/dev/null || echo "")
    if echo "$changed_files" | grep -q '\.github/workflows/'; then
      modifies_workflows=1
    fi

    # Exclude review-derived status checks from CI failure count.
    # "Claude Code Review - Approval Status" reports failure when Claude requests changes —
    # that's a REVIEW signal handled by the review-fix budget, not a CI failure.
    review_check_pattern="Approval Status|Review Status"
    if [ "$modifies_workflows" -eq 1 ]; then
      fail_count=$(echo "$checks_deduped" | jq --arg rp "$review_check_pattern" '[.[] | select(.state == "FAILURE" and (.name | test("claude-review|codex-review") | not) and (.name | test($rp) | not))] | length' 2>/dev/null || echo "0")
    else
      fail_count=$(echo "$checks_deduped" | jq --arg rp "$review_check_pattern" '[.[] | select(.state == "FAILURE" and (.name | test($rp) | not))] | length' 2>/dev/null || echo "0")
    fi
    pending_count=$(echo "$checks_deduped" | jq '[.[] | select(.state == "PENDING" or .state == "QUEUED")] | length' 2>/dev/null || echo "0")

    if [ "$fail_count" -gt 0 ]; then
      CI_FAILING="true"
      CI_FAIL_NAMES=$(echo "$checks_deduped" | jq -r --arg rp "$review_check_pattern" '[.[] | select(.state == "FAILURE" and (.name | test($rp) | not))] | map(.name) | join(", ")' 2>/dev/null || echo "unknown")
    elif [ "$pending_count" -gt 0 ]; then
      CI_PENDING="true"
    else
      CI_PASSED="true"
    fi
  fi

  # ─── Check 5: Review status (all 3 reviewers) ──────────────────────
  CLAUDE_REVIEW=""
  CODEX_REVIEW=""
  GEMINI_REVIEW=""
  if [ -n "$PR_NUMBER" ] && [ -n "$REPO_SLUG" ]; then
    reviews_json=$(gh_retry gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json reviews --jq '.reviews' 2>/dev/null || echo "[]")
    review_decision=$(gh_retry gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json reviewDecision --jq '.reviewDecision' 2>/dev/null || echo "")

    # Get latest review per reviewer
    latest_reviews=$(echo "$reviews_json" | jq '[
      group_by(.author.login)[] |
      sort_by(.submittedAt) | last |
      {login: .author.login, state: .state}
    ]' 2>/dev/null || echo "[]")

    # Claude
    CLAUDE_REVIEW=$(echo "$latest_reviews" | jq -r '[.[] | select(.login == "claude[bot]" or .login == "claude")] | .[0].state // ""' 2>/dev/null || echo "")

    # Codex (github-actions[bot])
    CODEX_REVIEW=$(echo "$latest_reviews" | jq -r '[.[] | select(.login == "github-actions[bot]" or .login == "github-actions")] | .[0].state // ""' 2>/dev/null || echo "")

    # Gemini Code Assist (advisory — only reviews on PR open)
    GEMINI_REVIEW=$(echo "$latest_reviews" | jq -r '[.[] | select(.login | startswith("gemini-code-assist"))] | .[0].state // ""' 2>/dev/null || echo "")

    # Gemini special handling: if no review posted, auto-pass (expected on non-open events)
    if [ -z "$GEMINI_REVIEW" ]; then
      GEMINI_REVIEW="AUTO_PASSED"
    elif [ "$GEMINI_REVIEW" = "COMMENTED" ]; then
      # Check the Gemini workflow result
      gemini_check=$(echo "$checks_deduped" | jq -r '[.[] | select(.name | test("Gemini Code Review"))] | .[0].state // ""' 2>/dev/null || echo "")
      if [ "$gemini_check" = "SUCCESS" ]; then
        GEMINI_REVIEW="APPROVED"
      elif [ -z "$gemini_check" ]; then
        # Check inline comments for findings
        gemini_findings=$(gh api "repos/${REPO_SLUG}/pulls/${PR_NUMBER}/comments" \
          --jq '[.[] | select(.user.login | startswith("gemini-code-assist"))] | length' 2>/dev/null || echo "0")
        if [ "$gemini_findings" -eq 0 ]; then
          GEMINI_REVIEW="APPROVED"
        else
          GEMINI_REVIEW="HAS_FINDINGS"
        fi
      fi
    fi
  fi

  # ─── Check 6: Branch synced to main? ───────────────────────────────
  BRANCH_SYNCED=""
  if [ -n "$T_WORKTREE" ] && [ -d "$T_WORKTREE" ]; then
    git -C "$T_WORKTREE" fetch origin main --quiet 2>/dev/null || true
    if git -C "$T_WORKTREE" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      BRANCH_SYNCED="true"
    else
      BRANCH_SYNCED="false"
    fi
  elif [ -n "$T_REPO_PATH" ] && [ -d "$T_REPO_PATH" ]; then
    # Try from main repo if worktree is gone
    git -C "$T_REPO_PATH" fetch origin main --quiet 2>/dev/null || true
    if git -C "$T_REPO_PATH" rev-parse --verify "$T_BRANCH" >/dev/null 2>&1; then
      if git -C "$T_REPO_PATH" merge-base --is-ancestor origin/main "$T_BRANCH" 2>/dev/null; then
        BRANCH_SYNCED="true"
      else
        BRANCH_SYNCED="false"
      fi
    fi
  fi

  # ─── Check 7: Screenshots included? (if frontend changes) ──────────
  SCREENSHOTS=""
  if [ -n "$PR_NUMBER" ] && [ -n "$REPO_SLUG" ]; then
    # Check if PR touches frontend files
    has_frontend=false
    if echo "$changed_files" | grep -qE '\.(tsx|jsx|vue|svelte|css|scss)$'; then
      has_frontend=true
    fi
    if echo "$changed_files" | grep -qE '^(frontend|src/components|src/app|app)/'; then
      has_frontend=true
    fi

    if [ "$has_frontend" = "true" ]; then
      # Check PR body for image/video markdown
      pr_body=$(gh_retry gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json body --jq '.body' 2>/dev/null || echo "")
      if echo "$pr_body" | grep -qE '!\[.*\]\(.*\.(png|jpg|gif|mp4|webp)'; then
        SCREENSHOTS="true"
      else
        SCREENSHOTS="false"
      fi
    else
      SCREENSHOTS="n/a"
    fi
  fi

  # ─── Build check display string ─────────────────────────────────────
  # Format: agent:X PR:X CI:X Reviews:X/X/X Sync:X Shots:X
  agent_disp="—"
  if [ "$AGENT_ALIVE" = "true" ]; then
    agent_disp="Y"
  elif [ -n "$T_PID" ]; then
    agent_disp="N"
  fi

  pr_disp="—"
  [ -n "$PR_NUMBER" ] && pr_disp="#$PR_NUMBER"

  ci_disp="—"
  [ "$CI_PASSED" = "true" ] && ci_disp="Y"
  [ "$CI_FAILING" = "true" ] && ci_disp="N"
  [ "$CI_PENDING" = "true" ] && ci_disp="..."

  claude_disp="—"
  [ "$CLAUDE_REVIEW" = "APPROVED" ] && claude_disp="Y"
  [ "$CLAUDE_REVIEW" = "CHANGES_REQUESTED" ] && claude_disp="N"

  codex_disp="—"
  [ "$CODEX_REVIEW" = "APPROVED" ] && codex_disp="Y"
  [ "$CODEX_REVIEW" = "CHANGES_REQUESTED" ] && codex_disp="N"

  gemini_disp="—"
  [ "$GEMINI_REVIEW" = "APPROVED" ] || [ "$GEMINI_REVIEW" = "AUTO_PASSED" ] && gemini_disp="Y"
  [ "$GEMINI_REVIEW" = "HAS_FINDINGS" ] && gemini_disp="N"

  sync_disp="—"
  [ "$BRANCH_SYNCED" = "true" ] && sync_disp="Y"
  [ "$BRANCH_SYNCED" = "false" ] && sync_disp="N"

  shots_disp="—"
  [ "$SCREENSHOTS" = "true" ] && shots_disp="Y"
  [ "$SCREENSHOTS" = "false" ] && shots_disp="N"
  [ "$SCREENSHOTS" = "n/a" ] && shots_disp="—"

  DETAILS="agent:${agent_disp} PR:${pr_disp} CI:${ci_disp} Reviews:${claude_disp}/${codex_disp}/${gemini_disp} Sync:${sync_disp} Shots:${shots_disp}"

  # ─── Status transitions ─────────────────────────────────────────────
  UPDATES=("lastCheckedAt=$NOW")

  # Update check fields
  [ "$AGENT_ALIVE" = "true" ] && UPDATES+=("checks.agentAlive=true") || UPDATES+=("checks.agentAlive=false")
  [ -n "$PR_NUMBER" ] && UPDATES+=("checks.prCreated=true")
  [ "$CI_PASSED" = "true" ] && UPDATES+=("checks.ciPassed=true")
  [ "$BRANCH_SYNCED" = "true" ] && UPDATES+=("checks.branchSynced=true")
  [ "$BRANCH_SYNCED" = "false" ] && UPDATES+=("checks.branchSynced=false")

  # Review fields — store the actual state string
  if [ -n "$CLAUDE_REVIEW" ] && [ "$CLAUDE_REVIEW" != "" ]; then
    UPDATES+=("checks.claudeReview=$CLAUDE_REVIEW")
  fi
  if [ -n "$CODEX_REVIEW" ] && [ "$CODEX_REVIEW" != "" ]; then
    UPDATES+=("checks.codexReview=$CODEX_REVIEW")
  fi
  if [ -n "$GEMINI_REVIEW" ] && [ "$GEMINI_REVIEW" != "" ]; then
    UPDATES+=("checks.geminiReview=$GEMINI_REVIEW")
  fi

  # Screenshots
  if [ "$SCREENSHOTS" = "true" ]; then
    UPDATES+=("checks.screenshotsIncluded=true")
  elif [ "$SCREENSHOTS" = "false" ]; then
    UPDATES+=("checks.screenshotsIncluded=false")
  fi

  # Store PR number if found
  if [ -n "$PR_NUMBER" ] && [ -z "$T_PR" ]; then
    UPDATES+=("pr=$PR_NUMBER")
  fi

  # ─── Decision logic ─────────────────────────────────────────────────

  # CASE: Task is "running" and agent process is dead
  if [ "$T_STATUS" = "running" ] && [ "$AGENT_ALIVE" = "false" ]; then

    # Check if agent finished normally
    if [ "$AGENT_DONE" = "true" ] && [ "$AGENT_EXIT_CODE" = "0" ]; then
      # Agent finished successfully — check for PR
      if [ -n "$PR_NUMBER" ]; then
        UPDATES+=("status=pr-open")
        emit "PR-OPEN" "$T_ID" "$DETAILS"
      else
        # Check if agent actually produced any commits (empty completion = likely rate limit/auth error)
        commit_count=0
        if [ -n "$T_WORKTREE" ] && [ -d "$T_WORKTREE" ]; then
          merge_base=$(git -C "$T_WORKTREE" merge-base HEAD main 2>/dev/null || echo "main")
          commit_count=$(git -C "$T_WORKTREE" rev-list --count "${merge_base}..HEAD" 2>/dev/null || echo "0")
        fi
        if [ "$commit_count" = "0" ]; then
          UPDATES+=("status=needs-respawn" "failureReason=Agent produced no changes (exit 0, zero commits)")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (exit 0, zero commits — likely rate limit or auth error)"
        else
          # Last-resort: agent may have created PR but DB missed it. Check GitHub directly.
          if [ -n "$REPO_SLUG" ] && [ -n "$T_BRANCH" ]; then
            _late_pr=$(gh_retry gh pr list --head "$T_BRANCH" --repo "$REPO_SLUG" --json number,state,url --jq 'if length > 0 then .[0] | "\(.number) \(.state) \(.url)" else empty end' 2>/dev/null || echo "")
            if [ -n "$_late_pr" ]; then
              PR_NUMBER=$(echo "$_late_pr" | awk '{print $1}')
              PR_STATE=$(echo "$_late_pr" | awk '{print $2}')
              PR_URL=$(echo "$_late_pr" | awk '{print $3}')
              UPDATES+=("status=pr-open" "pr=$PR_NUMBER" "prUrl=$PR_URL")
              emit "PR-OPEN" "$T_ID" "$DETAILS (late PR discovery: #$PR_NUMBER)"
            fi
          fi
          # Only mark no-pr if we still haven't found one
          if [ -z "$PR_NUMBER" ]; then
            if [ "$T_ATTEMPTS" -lt "$T_MAX_ATTEMPTS" ]; then
              UPDATES+=("status=needs-respawn" "failureReason=Agent completed but no PR was created ($commit_count commits on branch)")
              emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (no PR, $commit_count commits — will respawn)"
              tg_notify "NO-PR: \`$T_ID\` completed with $commit_count commits but no PR. Respawning (attempt $T_ATTEMPTS/$T_MAX_ATTEMPTS)."
            else
              UPDATES+=("status=done-no-pr" "failureReason=Agent completed but no PR was created ($commit_count commits on branch)")
              emit "FAILED" "$T_ID" "$DETAILS (no PR, $commit_count commits on branch)"
              tg_notify "EXHAUSTED: \`$T_ID\` completed $commit_count commits but never created a PR after $T_ATTEMPTS attempts. Needs human."
            fi
          fi
        fi
      fi

    elif [ "$AGENT_DONE" = "true" ] && [ "$AGENT_EXIT_CODE" != "0" ]; then
      # Agent exited with error
      if [ -n "$PR_NUMBER" ]; then
        # PR exists but agent failed — check CI/reviews
        if [ "$CI_FAILING" = "true" ]; then
          UPDATES+=("status=needs-respawn" "failureReason=CI failed: $CI_FAIL_NAMES")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (CI failed: $CI_FAIL_NAMES)"
        else
          UPDATES+=("status=pr-open")
          emit "PR-OPEN" "$T_ID" "$DETAILS (agent exited non-zero but PR exists)"
        fi
      else
        # No PR, agent failed
        if [ "$T_ATTEMPTS" -ge "$T_MAX_ATTEMPTS" ]; then
          UPDATES+=("status=exhausted" "failureReason=Agent failed after $T_ATTEMPTS attempts, exit code: $AGENT_EXIT_CODE")
          emit "EXHAUSTED" "$T_ID" "$DETAILS (${T_ATTEMPTS}/${T_MAX_ATTEMPTS} attempts used)"
          [ "$T_LAST_NOTIFIED" != "exhausted" ] && {
            tg_notify "EXHAUSTED: \`$T_ID\` failed after $T_ATTEMPTS attempts. Needs human intervention."
            UPDATES+=("lastNotifiedState=exhausted")
          }
        else
          UPDATES+=("status=needs-respawn" "failureReason=Agent exited with code $AGENT_EXIT_CODE")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (exit code: $AGENT_EXIT_CODE)"
        fi
      fi

    else
      # agent dead, no done file — died without clean exit
      if [ -n "$PR_NUMBER" ]; then
        UPDATES+=("status=pr-open")
        emit "PR-OPEN" "$T_ID" "$DETAILS (agent died but PR exists)"
      else
        if [ "$T_ATTEMPTS" -ge "$T_MAX_ATTEMPTS" ]; then
          UPDATES+=("status=exhausted" "failureReason=Agent died without creating PR after $T_ATTEMPTS attempts")
          emit "EXHAUSTED" "$T_ID" "$DETAILS (died, no output)"
          [ "$T_LAST_NOTIFIED" != "exhausted" ] && {
            tg_notify "EXHAUSTED: \`$T_ID\` died without PR after $T_ATTEMPTS attempts. Needs human."
            UPDATES+=("lastNotifiedState=exhausted")
          }
        else
          UPDATES+=("status=needs-respawn" "failureReason=Agent died without creating PR")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (agent died, no PR)"
        fi
      fi
    fi

  # CASE: Task is "running" and agent process is alive
  elif [ "$T_STATUS" = "running" ] && [ "$AGENT_ALIVE" = "true" ]; then

    # Agent may have finished — check the done file first
    if [ "$AGENT_DONE" = "true" ]; then
      if [ "$AGENT_EXIT_CODE" = "0" ]; then
        if [ -n "$PR_NUMBER" ]; then
          UPDATES+=("status=pr-open")
          emit "PR-OPEN" "$T_ID" "$DETAILS (agent finished)"
        else
          # Check if agent actually produced any commits
          commit_count=0
          if [ -n "$T_WORKTREE" ] && [ -d "$T_WORKTREE" ]; then
            merge_base=$(git -C "$T_WORKTREE" merge-base HEAD main 2>/dev/null || echo "main")
            commit_count=$(git -C "$T_WORKTREE" rev-list --count "${merge_base}..HEAD" 2>/dev/null || echo "0")
          fi
          if [ "$commit_count" = "0" ]; then
            UPDATES+=("status=needs-respawn" "failureReason=Agent produced no changes (exit 0, zero commits)")
            emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (exit 0, zero commits — likely rate limit or auth error)"
          else
            # Last-resort: agent may have created PR but DB missed it. Check GitHub directly.
            if [ -n "$REPO_SLUG" ] && [ -n "$T_BRANCH" ]; then
              _late_pr=$(gh_retry gh pr list --head "$T_BRANCH" --repo "$REPO_SLUG" --json number,state,url --jq 'if length > 0 then .[0] | "\(.number) \(.state) \(.url)" else empty end' 2>/dev/null || echo "")
              if [ -n "$_late_pr" ]; then
                PR_NUMBER=$(echo "$_late_pr" | awk '{print $1}')
                PR_STATE=$(echo "$_late_pr" | awk '{print $2}')
                PR_URL=$(echo "$_late_pr" | awk '{print $3}')
                UPDATES+=("status=pr-open" "pr=$PR_NUMBER" "prUrl=$PR_URL")
                emit "PR-OPEN" "$T_ID" "$DETAILS (late PR discovery: #$PR_NUMBER)"
              fi
            fi
            # Only mark no-pr if we still haven't found one
            if [ -z "$PR_NUMBER" ]; then
              if [ "$T_ATTEMPTS" -lt "$T_MAX_ATTEMPTS" ]; then
                UPDATES+=("status=needs-respawn" "failureReason=Agent completed but no PR was created ($commit_count commits on branch)")
                emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (no PR, $commit_count commits — will respawn)"
                tg_notify "NO-PR: \`$T_ID\` completed with $commit_count commits but no PR. Respawning (attempt $T_ATTEMPTS/$T_MAX_ATTEMPTS)."
              else
                UPDATES+=("status=done-no-pr" "failureReason=Agent completed but no PR was created ($commit_count commits on branch)")
                emit "FAILED" "$T_ID" "$DETAILS (no PR, $commit_count commits on branch)"
                tg_notify "EXHAUSTED: \`$T_ID\` completed $commit_count commits but never created a PR after $T_ATTEMPTS attempts. Needs human."
              fi
            fi
          fi
        fi
      else
        if [ -n "$PR_NUMBER" ]; then
          if [ "$CI_FAILING" = "true" ]; then
            UPDATES+=("status=needs-respawn" "failureReason=CI failed: $CI_FAIL_NAMES")
            emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (CI failed: $CI_FAIL_NAMES)"
          else
            UPDATES+=("status=pr-open")
            emit "PR-OPEN" "$T_ID" "$DETAILS (agent exited non-zero but PR exists)"
          fi
        else
          if [ "$T_ATTEMPTS" -ge "$T_MAX_ATTEMPTS" ]; then
            UPDATES+=("status=exhausted" "failureReason=Agent failed after $T_ATTEMPTS attempts, exit code: $AGENT_EXIT_CODE")
            emit "EXHAUSTED" "$T_ID" "$DETAILS (${T_ATTEMPTS}/${T_MAX_ATTEMPTS} attempts used)"
            [ "$T_LAST_NOTIFIED" != "exhausted" ] && {
              tg_notify "EXHAUSTED: \`$T_ID\` failed after $T_ATTEMPTS attempts. Needs human intervention."
              UPDATES+=("lastNotifiedState=exhausted")
            }
          else
            UPDATES+=("status=needs-respawn" "failureReason=Agent exited with code $AGENT_EXIT_CODE")
            emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (exit code: $AGENT_EXIT_CODE)"
          fi
        fi
      fi

    # Agent still running — check timeouts/staleness
    else

    elapsed=$(( NOW - T_STARTED ))
    mins=$((elapsed / 60))

    # Timeout check
    if [ "$elapsed" -gt "${AGENT_TIMEOUT:-1800}" ]; then
      UPDATES+=("status=needs-respawn" "failureReason=Agent timed out after ${mins}m")
      emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (timed out: ${mins}m)"
    else
      # ── Phase 1.5: Stale Detection ──
      stale_threshold="${STALE_THRESHOLD_SECS:-7200}"
      idle_threshold="${IDLE_THRESHOLD_SECS:-1800}"

      # Flag: running > STALE_THRESHOLD without creating a PR
      if [ "$elapsed" -gt "$stale_threshold" ] && [ -z "$PR_NUMBER" ]; then
        emit "RUNNING" "$T_ID" "$DETAILS (${mins}m elapsed, STALE: no PR after ${stale_threshold}s)"
        [ "$T_LAST_NOTIFIED" != "stale" ] && {
          tg_notify "STALE: \`$T_ID\` running for ${mins}m with no PR. May be stuck."
          UPDATES+=("lastNotifiedState=stale")
        }
      # Flag: running > IDLE_THRESHOLD with no code changes in worktree
      elif [ "$elapsed" -gt "$idle_threshold" ] && [ -n "$T_WORKTREE" ] && [ -d "$T_WORKTREE" ]; then
        wt_changes=$(git -C "$T_WORKTREE" diff --stat 2>/dev/null | wc -l | tr -d ' ')
        wt_untracked=$(git -C "$T_WORKTREE" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        if [ "${wt_changes:-0}" -eq 0 ] && [ "${wt_untracked:-0}" -eq 0 ]; then
          emit "RUNNING" "$T_ID" "$DETAILS (${mins}m elapsed, IDLE: no code changes)"
          [ "$T_LAST_NOTIFIED" != "idle" ] && {
            tg_notify "IDLE: \`$T_ID\` running ${mins}m with no code changes. May be stuck."
            UPDATES+=("lastNotifiedState=idle")
          }
        else
          emit "RUNNING" "$T_ID" "$DETAILS (${mins}m elapsed)"
        fi
      else
        emit "RUNNING" "$T_ID" "$DETAILS (${mins}m elapsed)"
      fi
    fi

    fi  # end agent-done vs still-running

  # CASE: Task is "needs-respawn" — just emit status, orchestrator handles respawn
  elif [ "$T_STATUS" = "needs-respawn" ]; then
    emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (awaiting orchestrator respawn)"

  # CASE: Task is "pr-open", "ready", or a *-failed status — monitor PR health
  elif [ "$T_STATUS" = "pr-open" ] || [ "$T_STATUS" = "ready" ] || [ "$T_STATUS" = "deploy-failed" ] || [ "$T_STATUS" = "ci-failed" ] || [ "$T_STATUS" = "review-failed" ]; then

    if [ -z "$PR_NUMBER" ]; then
      emit "FAILED" "$T_ID" "$DETAILS (pr-open but no PR found)"
      UPDATES+=("status=failed" "failureReason=PR not found for branch $T_BRANCH")
    else
      # Check review decision (ground truth from GitHub)
      CHANGES_REQUESTED=false
      if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
        CHANGES_REQUESTED=true
      fi

      # All checks passing?
      ALL_GOOD=false
      if [ "$CI_PASSED" = "true" ]; then
        # Need at least Claude OR Codex approved, and no CHANGES_REQUESTED
        if [ "$CHANGES_REQUESTED" = "false" ]; then
          if [ "$CLAUDE_REVIEW" = "APPROVED" ] || [ "$CODEX_REVIEW" = "APPROVED" ]; then
            # Block if Gemini has unaddressed findings
            gemini_addressed=$(echo "$TASK" | jq -r '.checks.geminiAddressed // "false"')
            if [ "$GEMINI_REVIEW" = "HAS_FINDINGS" ] && [ "$gemini_addressed" != "true" ]; then
              ALL_GOOD=false
            else
              ALL_GOOD=true
            fi
          fi
        fi
      fi

      if [ "$ALL_GOOD" = "true" ]; then
        if [ "$T_STATUS" != "ready" ]; then
          UPDATES+=("status=ready" "completedAt=$NOW")
        fi
        emit "READY" "$T_ID" "$DETAILS"
        [ "$T_LAST_NOTIFIED" != "ready" ] && {
          tg_notify "READY TO MERGE: \`$T_ID\` — PR #$PR_NUMBER all checks passing${PR_URL:+
[View PR](${PR_URL})}"
          UPDATES+=("lastNotifiedState=ready")
        }

        # ── Phase 1.5: Auto-merge for LOW risk PRs ──
        # Only when AUTO_MERGE_LOW_RISK=true in config.env
        if [ "${AUTO_MERGE_LOW_RISK:-false}" = "true" ] && [ -n "$PR_NUMBER" ] && [ -n "$REPO_SLUG" ]; then
          # Determine risk tier from changed files
          local risk_tier="MEDIUM"  # default
          local all_low_risk=true
          local pr_changed_files
          pr_changed_files=$(gh_retry gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json files --jq '[.files[].path] | .[]' 2>/dev/null || echo "")

          if [ -n "$pr_changed_files" ]; then
            while IFS= read -r cf; do
              # HIGH risk patterns — never auto-merge
              if echo "$cf" | grep -qiE '(migration|auth|security|payment|\.env|secret|credential)'; then
                risk_tier="HIGH"
                all_low_risk=false
                break
              fi
              # LOW risk patterns: docs, tests, UI components, CSS, README, configs
              if ! echo "$cf" | grep -qiE '\.(md|test\.[jt]sx?|spec\.[jt]sx?|css|scss|less|svg|png|jpg|gif)$|^(README|CHANGELOG|LICENSE|docs/|test/|tests/|__tests__/)'; then
                all_low_risk=false
              fi
            done <<< "$pr_changed_files"
          else
            all_low_risk=false
          fi

          if [ "$all_low_risk" = "true" ] && [ "$risk_tier" != "HIGH" ]; then
            risk_tier="LOW"
          fi

          if [ "$risk_tier" = "LOW" ]; then
            # All 3 reviews should be approved (or auto-passed for Gemini)
            local can_auto_merge=true
            [ "$CLAUDE_REVIEW" != "APPROVED" ] && can_auto_merge=false
            [ "$CODEX_REVIEW" != "APPROVED" ] && can_auto_merge=false
            if [ "$GEMINI_REVIEW" != "APPROVED" ] && [ "$GEMINI_REVIEW" != "AUTO_PASSED" ]; then
              can_auto_merge=false
            fi

            if [ "$can_auto_merge" = "true" ] && [ "$CI_PASSED" = "true" ]; then
              tg_notify "Auto-merging LOW risk [PR #$PR_NUMBER](${PR_URL:-https://github.com}) (\`$T_ID\`)"
              if gh pr merge "$PR_NUMBER" --repo "$REPO_SLUG" --squash 2>/dev/null; then
                UPDATES+=("status=merged" "completedAt=$NOW")
                emit "MERGED" "$T_ID" "$DETAILS (auto-merged: LOW risk)"
                tg_notify "Merged (auto): \`$T_ID\` — PR #$PR_NUMBER"
              else
                tg_notify "Auto-merge failed for PR #$PR_NUMBER (\`$T_ID\`). Manual merge needed."
              fi
            fi
          fi
        fi

      elif [ "$CI_FAILING" = "true" ]; then
        # CI failures on an existing PR use review-fix budget (not crash budget).
        # The agent produced working code; it just needs to fix lint/test errors.
        review_fixes=$(echo "$TASK" | jq -r '.reviewFixAttempts // 0')
        max_review_fixes=$(echo "$TASK" | jq -r ".maxReviewFixes // ${MAX_REVIEW_FIXES:-20}")
        if [ "$review_fixes" -ge "$max_review_fixes" ]; then
          UPDATES+=("status=exhausted" "failureReason=CI fix exhausted after $review_fixes cycles: $CI_FAIL_NAMES")
          emit "EXHAUSTED" "$T_ID" "$DETAILS (CI fix exhausted: $review_fixes/$max_review_fixes)"
          [ "$T_LAST_NOTIFIED" != "exhausted" ] && {
            tg_notify "EXHAUSTED: \`$T_ID\` CI fix exhausted after $review_fixes cycles: $CI_FAIL_NAMES"
            UPDATES+=("lastNotifiedState=exhausted")
          }
        else
          UPDATES+=("status=needs-respawn" "failureReason=CI failed: $CI_FAIL_NAMES" "reviewFixAttempts=$((review_fixes + 1))")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (CI fix $((review_fixes + 1))/$max_review_fixes: $CI_FAIL_NAMES)"
        fi

      elif [ "$CHANGES_REQUESTED" = "true" ]; then
        # Review-fix uses separate budget from crash retries
        review_fixes=$(echo "$TASK" | jq -r '.reviewFixAttempts // 0')
        max_review_fixes=$(echo "$TASK" | jq -r ".maxReviewFixes // ${MAX_REVIEW_FIXES:-20}")
        if [ "$review_fixes" -ge "$max_review_fixes" ]; then
          UPDATES+=("status=exhausted" "failureReason=Review-fix exhausted after $review_fixes cycles")
          emit "EXHAUSTED" "$T_ID" "$DETAILS (review-fix exhausted: $review_fixes/$max_review_fixes)"
          [ "$T_LAST_NOTIFIED" != "exhausted" ] && {
            tg_notify "EXHAUSTED: \`$T_ID\` review-fix exhausted after $review_fixes cycles${PR_URL:+
[View PR](${PR_URL})}"
            UPDATES+=("lastNotifiedState=exhausted")
          }
        else
          UPDATES+=("status=needs-respawn" "failureReason=Reviewers requested changes" "reviewFixAttempts=$((review_fixes + 1))")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (review-fix $((review_fixes + 1))/$max_review_fixes)"
        fi

      elif [ "$GEMINI_REVIEW" = "HAS_FINDINGS" ]; then
        # Gemini findings — one fix attempt, then mark addressed (won't loop)
        gemini_addressed=$(echo "$TASK" | jq -r '.checks.geminiAddressed // "false"')
        if [ "$gemini_addressed" = "true" ]; then
          # Already attempted fix — treat as awaiting reviews (fall through)
          emit "PR-OPEN" "$T_ID" "$DETAILS (Gemini findings addressed, awaiting reviews)"
        else
          review_fixes=$(echo "$TASK" | jq -r '.reviewFixAttempts // 0')
          max_review_fixes=$(echo "$TASK" | jq -r ".maxReviewFixes // ${MAX_REVIEW_FIXES:-20}")
          UPDATES+=("status=needs-respawn" "failureReason=Gemini review findings need fixing" "checks.geminiAddressed=true" "reviewFixAttempts=$((review_fixes + 1))")
          emit "NEEDS-RESPAWN" "$T_ID" "$DETAILS (Gemini findings, fix $((review_fixes + 1))/$max_review_fixes)"
        fi

      elif [ "$CI_PENDING" = "true" ]; then
        emit "PR-OPEN" "$T_ID" "$DETAILS (CI pending)"
        # Keep current status

      else
        # CI passed but waiting for reviews
        emit "PR-OPEN" "$T_ID" "$DETAILS (awaiting reviews)"
        [ "$T_LAST_NOTIFIED" != "awaiting-reviews" ] && [ "$CI_PASSED" = "true" ] && {
          tg_notify "CI passed, awaiting reviews — \`$T_ID\`${PR_URL:+
[PR #$PR_NUMBER](${PR_URL})}"
          UPDATES+=("lastNotifiedState=awaiting-reviews")
        }
      fi
    fi
  fi

  # ─── Apply all updates for this task ─────────────────────────────────
  if [ ${#UPDATES[@]} -gt 0 ]; then
    registry_update "$T_ID" "${UPDATES[@]}"
  fi

done

# ─── Phase 1.5: Parallel Conflict Detection ────────────────────────────
# After checking all tasks, detect file overlap between running agents
# on the same repo and warn about potential merge conflicts.
_detect_conflicts() {
  local updated_tasks
  updated_tasks=$(cat "$REGISTRY")
  local running_ids
  running_ids=$(echo "$updated_tasks" | jq -r '.[] | select(.status == "running" or .status == "pr-open") | .id')

  # Build array of id:repoPath:worktree
  local agents=()
  for rid in $running_ids; do
    local rpath rwt
    rpath=$(echo "$updated_tasks" | jq -r --arg id "$rid" '.[] | select(.id == $id) | .repoPath')
    rwt=$(echo "$updated_tasks" | jq -r --arg id "$rid" '.[] | select(.id == $id) | .worktree')
    [ -d "$rwt" ] && agents+=("${rid}|${rpath}|${rwt}")
  done

  # For each pair on the same repo, check file overlap
  local conflict_found=false
  for ((i=0; i<${#agents[@]}; i++)); do
    local id_a repo_a wt_a
    IFS='|' read -r id_a repo_a wt_a <<< "${agents[$i]}"
    for ((j=i+1; j<${#agents[@]}; j++)); do
      local id_b repo_b wt_b
      IFS='|' read -r id_b repo_b wt_b <<< "${agents[$j]}"

      # Only check agents on the same repo
      [ "$repo_a" != "$repo_b" ] && continue

      local files_a files_b overlap
      files_a=$(git -C "$wt_a" diff --name-only origin/main 2>/dev/null || echo "")
      files_b=$(git -C "$wt_b" diff --name-only origin/main 2>/dev/null || echo "")

      [ -z "$files_a" ] || [ -z "$files_b" ] && continue

      overlap=$(comm -12 <(echo "$files_a" | sort) <(echo "$files_b" | sort) 2>/dev/null || echo "")
      if [ -n "$overlap" ]; then
        conflict_found=true
        local overlap_count
        overlap_count=$(echo "$overlap" | wc -l | tr -d ' ')
        local overlap_preview
        overlap_preview=$(echo "$overlap" | head -5 | tr '\n' ', ' | sed 's/,$//')

        if [ "$QUIET" -eq 0 ]; then
          echo -e "${YELLOW}[CONFLICT RISK]${NC} $id_a and $id_b modify $overlap_count same file(s): $overlap_preview"
        fi

        # Notify via Telegram (once per pair per check cycle — dedup via emit)
        if [ "$NO_NOTIFY" -eq 0 ]; then
          tg_notify "CONFLICT RISK: $id_a and $id_b modify $overlap_count same file(s): $overlap_preview"
        fi

        if [ "$JSON_OUTPUT" -eq 1 ]; then
          JSON_RESULTS=$(echo "$JSON_RESULTS" | jq \
            --arg a "$id_a" --arg b "$id_b" --arg files "$overlap_preview" \
            '. + [{status: "CONFLICT_RISK", id: ($a + " vs " + $b), details: ("overlapping files: " + $files)}]')
        fi
      fi
    done
  done

  if [ "$conflict_found" = "false" ] && [ "$QUIET" -eq 0 ]; then
    local agent_count=${#agents[@]}
    [ "$agent_count" -gt 1 ] && echo "No file conflicts detected among $agent_count active agents."
  fi
  return 0
}

# Only run conflict detection if there are tasks to check
[ "$TASK_COUNT" -gt 1 ] && _detect_conflicts

# ─── JSON output mode ──────────────────────────────────────────────────
if [ "$JSON_OUTPUT" -eq 1 ]; then
  echo "$JSON_RESULTS" | jq .
fi

# ─── Summary ───────────────────────────────────────────────────────────
if [ "$QUIET" -eq 0 ] && [ "$JSON_OUTPUT" -eq 0 ]; then
  echo ""
  # Count by status from the original tasks (we may have changed some)
  running=$(echo "$TASKS" | jq '[.[] | select(.status == "running")] | length')
  pr_open=$(echo "$TASKS" | jq '[.[] | select(.status == "pr-open")] | length')
  ready=$(echo "$TASKS" | jq '[.[] | select(.status == "ready")] | length')
  echo "Checked: running=$running pr-open=$pr_open ready=$ready"
fi
