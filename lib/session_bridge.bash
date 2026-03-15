#!/bin/bash
# lib/session_bridge.bash — OpenClaw native ACPX session bridge
#
# Replaces: acp_orchestrator.py (642 lines), .foundry-run.sh generation,
#           file-based IPC (.steer, .status.json, .pid)
#
# Architecture:
#   foundry spawn → oc_spawn_bg() → openclaw agent --session-id <uuid> --agent <backend>
#                                        ↓
#                                   Gateway manages ACPX session
#                                        ↓
#                                   codex-acp / claude-agent-acp / gemini CLI
#                                        ↑
#   foundry steer → oc_send()  → openclaw agent --session-id <uuid> --message "steer msg"
#   foundry ask   → oc_send()  → same, returns reply
#   foundry check → oc_status() → openclaw gateway call sessions.list
#   foundry peek  → oc_status() → session token/activity data
#   foundry kill  → oc_cancel() → openclaw acp stop / kill PID
#
# Session ID is pre-generated (UUID) and stored in registry BEFORE the agent starts.
# This gives immediate control: steer, ask, status, cancel work from moment of spawn.
[[ "${_LIB_SESSION_BRIDGE_LOADED:-}" == "1" ]] && return 0
_LIB_SESSION_BRIDGE_LOADED=1

OPENCLAW_BIN="${OPENCLAW_BIN:-/usr/local/bin/openclaw}"

# Gateway password for RPC calls (sessions.list, etc.)
_oc_gw_password() {
  python3 -c "import json; print(json.load(open('$HOME/.openclaw/openclaw.json'))['env']['vars']['OPENCLAW_GATEWAY_PASSWORD'])" 2>/dev/null || echo ""
}

# ─── oc_gen_session_id ────────────────────────────────────────────────────
oc_gen_session_id() {
  python3 -c "import uuid; print(str(uuid.uuid4()))" 2>/dev/null \
    || uuidgen | tr '[:upper:]' '[:lower:]'
}

# ─── oc_spawn_bg ──────────────────────────────────────────────────────────
# Spawn a coding agent via OpenClaw ACPX in the background.
#
# The session runs through the Gateway. While it's running:
#   - sessions.list shows it (oc_status works)
#   - oc_send can steer or ask questions
#   - OpenClaw tracks token usage, activity, errors
#
# On completion, writes exit code to .done file (check.bash picks it up).
# The .done file is NOT cross-process IPC. It's a local "background job finished" marker.
# All real communication goes through OpenClaw's session layer.
#
# Args: session_id agent_id prompt_text log_file cwd [timeout_secs]
# Stdout: background PID
oc_spawn_bg() {
  local session_id="$1" agent_id="$2" prompt_text="$3" log_file="$4" cwd="$5"
  local timeout_secs="${6:-${AGENT_TIMEOUT:-1800}}"
  local done_file="${log_file%.log}.done"

  (
    local exit_code

    # Write prompt to temp file (avoids ARG_MAX for large prompts)
    local prompt_tmp
    prompt_tmp=$(mktemp "${TMPDIR:-/tmp}/foundry-prompt.XXXXXX")
    echo "$prompt_text" > "$prompt_tmp"

    # Run agent through OpenClaw Gateway
    # --session-id: pre-generated UUID, stored in registry, queryable immediately
    # --agent: backend (codex, claude, gemini)
    # --timeout: max runtime in seconds
    "$OPENCLAW_BIN" agent \
      --agent "$agent_id" \
      --session-id "$session_id" \
      --timeout "$timeout_secs" \
      --message "$(cat "$prompt_tmp")" \
      >>"$log_file" 2>&1
    exit_code=$?

    rm -f "$prompt_tmp"

    # Signal completion (local marker for check.bash)
    echo "$exit_code" > "$done_file"
  ) &

  echo $!
}

# ─── oc_send ──────────────────────────────────────────────────────────────
# Send a message to a running ACPX session. Used for:
#   - Steer: redirect agent mid-task ("focus on API first")
#   - Ask:   query agent status ("what's your progress?")
#   - Callback: agent-to-orchestrator reply
#
# The message arrives as a new user turn in the agent's conversation.
#
# Args: session_id message [timeout_secs]
# Stdout: agent's reply text
oc_send() {
  local session_id="$1" message="$2" timeout_secs="${3:-45}"

  local result
  result=$("$OPENCLAW_BIN" agent \
    --session-id "$session_id" \
    --message "$message" \
    --json \
    --timeout "$timeout_secs" 2>/dev/null)
  local exit_code=$?

  if [ $exit_code -ne 0 ]; then
    echo '{"error":"oc_send failed","exitCode":'$exit_code'}'
    return 1
  fi

  echo "$result" | jq -r '.reply // .message // .text // empty' 2>/dev/null || echo "$result"
}

# ─── oc_status ────────────────────────────────────────────────────────────
# Query session liveness and metrics from the Gateway.
# Replaces: kill -0 $pid + .status.json reads
#
# Args: session_id
# Stdout: JSON { alive, status, updatedAt, totalTokens, model }
oc_status() {
  local session_id="$1"
  local gw_pw
  gw_pw=$(_oc_gw_password)

  local raw_result
  raw_result=$(timeout 10 "$OPENCLAW_BIN" gateway call sessions.list \
    ${gw_pw:+--password "$gw_pw"} 2>/dev/null)

  if [ $? -ne 0 ] || [ -z "$raw_result" ]; then
    echo '{"alive":false,"status":"unknown","error":"gateway query failed"}'
    return 1
  fi

  echo "$raw_result" | python3 -c "
import json, sys, re
try:
    raw = sys.stdin.read()
    raw = re.sub(r'\x1b\[[0-9;]*m', '', raw)
    idx = raw.find('{')
    if idx < 0:
        print(json.dumps({'alive': False, 'status': 'parse_error'}))
        sys.exit()
    d = json.loads(raw[idx:])
    target = '$session_id'
    for s in d.get('sessions', []):
        if s.get('sessionId') == target:
            print(json.dumps({
                'alive': True,
                'status': 'active',
                'updatedAt': s.get('updatedAt', 0),
                'totalTokens': s.get('totalTokens', 0),
                'inputTokens': s.get('inputTokens', 0),
                'outputTokens': s.get('outputTokens', 0),
                'model': s.get('model', '')
            }))
            sys.exit()
    # Not in sessions.list = completed or never existed
    print(json.dumps({'alive': False, 'status': 'completed'}))
except Exception as e:
    print(json.dumps({'alive': False, 'status': 'parse_error', 'error': str(e)}))
" 2>/dev/null || echo '{"alive":false,"status":"parse_error"}'
}

# ─── oc_cancel ────────────────────────────────────────────────────────────
# Cancel a running ACPX session.
#
# Args: session_id
oc_cancel() {
  local session_id="$1"
  local gw_pw
  gw_pw=$(_oc_gw_password)

  timeout 10 "$OPENCLAW_BIN" acp stop \
    --session "$session_id" \
    ${gw_pw:+--password "$gw_pw"} 2>/dev/null \
  || timeout 10 "$OPENCLAW_BIN" gateway call sessions.cancel \
       --params "{\"sessionId\":\"$session_id\"}" \
       ${gw_pw:+--password "$gw_pw"} 2>/dev/null \
  || true
}

# ─── oc_is_native ─────────────────────────────────────────────────────────
# Check if a task uses native OpenClaw sessions.
#
# Args: task_json
# Returns: 0 if native (has sessionId), 1 if legacy (PID-only)
oc_is_native() {
  local task="$1"
  local sid
  sid=$(echo "$task" | jq -r '.sessionId // empty')
  [ -n "$sid" ] && [ "$sid" != "null" ]
}
