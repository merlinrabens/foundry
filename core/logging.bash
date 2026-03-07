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

tg_notify() {
  local message="$1"
  local bot_token="${OPENCLAW_TG_BOT_TOKEN:-}"

  # Fallback: read from openclaw.json env vars
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

  if [ -z "$bot_token" ]; then
    log_warn "No Telegram bot token (set OPENCLAW_TG_BOT_TOKEN or check openclaw.json)"
    return 0
  fi

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
