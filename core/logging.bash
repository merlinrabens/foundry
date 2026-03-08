# core/logging.bash — Colors, logging, Telegram notifications
[ "${_CORE_LOGGING_LOADED:-}" = "1" ] && return 0
_CORE_LOGGING_LOADED=1

# ─── Colors & Logging ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()      { echo -e "${CYAN}[foundry]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[foundry]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[foundry]${NC} $*"; }
log_err()  { echo -e "${RED}[foundry]${NC} $*"; }

# ─── Telegram Notifications ──────────────────────────────────────────
TG_CHAT_ID="${TG_CHAT_ID:-}"

# Resolve Telegram bot token (cached for session)
_tg_bot_token_cache=""
_tg_resolve_bot_token() {
  [ -n "$_tg_bot_token_cache" ] && { echo "$_tg_bot_token_cache"; return 0; }
  local token="${OPENCLAW_TG_BOT_TOKEN:-}"
  if [ -z "$token" ]; then
    token=$(python3 -c "
import json
try:
    cfg = json.loads(open('$HOME/.openclaw/openclaw.json').read())
    v = cfg.get('env',{}).get('vars',{})
    print(v.get('OPENCLAW_TG_BOT_TOKEN','') or v.get('TELEGRAM_BOT_TOKEN',''))
except: pass
" 2>/dev/null)
  fi
  if [ -z "$token" ]; then
    return 1
  fi
  _tg_bot_token_cache="$token"
  echo "$token"
}

tg_notify() {
  local message="$1"
  local bot_token
  bot_token=$(_tg_resolve_bot_token) || {
    log_warn "No Telegram bot token (set OPENCLAW_TG_BOT_TOKEN or check openclaw.json)"
    return 0
  }

  # Use --data-urlencode to properly handle newlines and special chars
  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "text=$message" 2>&1)
  if echo "$response" | grep -q '"ok":true'; then
    return 0
  else
    log_warn "Telegram send failed: $response"
    return 1
  fi
}

# ─── Telegram Topic (Forum) Support ────────────────────────────────

# tg_create_topic <topic_name> [icon_color]
# Creates a forum topic in the supergroup and echoes the topic_id (message_thread_id).
# Requires the chat to be a supergroup with topics enabled.
# icon_color: optional color ID (7322096=green, 16766590=yellow, 13338331=red, 9367192=blue, 16749490=orange, 16478047=purple)
tg_create_topic() {
  local topic_name="$1"
  local icon_color="${2:-7322096}"  # default: green
  local bot_token
  bot_token=$(_tg_resolve_bot_token) || {
    log_warn "Cannot create topic: no Telegram bot token"
    return 1
  }

  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${bot_token}/createForumTopic" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "name=$topic_name" \
    --data-urlencode "icon_color=$icon_color" 2>&1)
  if echo "$response" | grep -q '"ok":true'; then
    local topic_id
    topic_id=$(echo "$response" | jq -r '.result.message_thread_id')
    echo "$topic_id"
    return 0
  else
    log_warn "Failed to create topic '$topic_name': $response"
    return 1
  fi
}

# tg_notify_topic <topic_id> <message>
# Sends a message to a specific forum topic (thread) in the supergroup.
tg_notify_topic() {
  local topic_id="$1"
  local message="$2"
  local bot_token
  bot_token=$(_tg_resolve_bot_token) || {
    log_warn "Cannot send to topic: no Telegram bot token"
    return 0
  }

  local response
  response=$(curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT_ID" \
    --data-urlencode "message_thread_id=$topic_id" \
    --data-urlencode "text=$message" 2>&1)
  if echo "$response" | grep -q '"ok":true'; then
    return 0
  else
    log_warn "Telegram topic send failed (topic=$topic_id): $response"
    return 1
  fi
}

# tg_notify_task <task_id> <message>
# Smart router: sends to topic if task has a tg_topic_id, otherwise falls back to tg_notify.
# Also sends a brief summary to main chat when using topic (keeps Jerry informed).
tg_notify_task() {
  local task_id="$1"
  local message="$2"

  # Look up topic_id from registry
  local topic_id=""
  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ] && command -v sqlite3 &>/dev/null; then
    topic_id=$(_db "SELECT tg_topic_id FROM tasks WHERE id = '$(echo "$task_id" | sed "s/'/''/g")';" 2>/dev/null || echo "")
  fi

  if [ -n "$topic_id" ] && [ "$topic_id" != "null" ] && [ "$topic_id" != "" ]; then
    # Send full update to the task's topic
    tg_notify_topic "$topic_id" "$message"
  else
    # No topic — fall back to main chat
    tg_notify "$message"
  fi
}
