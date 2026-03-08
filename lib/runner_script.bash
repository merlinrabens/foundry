#!/bin/bash
# lib/runner_script.bash — Shared runner script generator (used by spawn + respawn)
[[ "${_LIB_RUNNER_SCRIPT_LOADED:-}" == "1" ]] && return 0
_LIB_RUNNER_SCRIPT_LOADED=1

# Generates .foundry-run.sh for any backend (claude/codex/gemini).
# Delegates to acp_orchestrator.py for structured JSON-RPC agent management.
_write_runner_script() {
  local backend="$1" worktree_dir="$2" model="$3" log_file="$4" done_file="$5"
  local env_block="$6" codex_reasoning="$7"

  # Pre-cache token from credentials.json (freshest source at spawn time)
  python3 -c "
import json, os, time
try:
    c = json.load(open(os.path.expanduser('~/.claude/.credentials.json')))
    o = c.get('claudeAiOauth', {})
    t, exp = o.get('accessToken',''), o.get('expiresAt',0)
    if t and (not exp or int(time.time()*1000) < exp - 300000):
        open(os.path.expanduser('~/.claude/.foundry-token'), 'w').write(t)
except: pass
" 2>/dev/null

  cat > "${worktree_dir}/.foundry-run.sh" << 'RUNNER_EOF'
#!/bin/bash
unset CLAUDECODE
# OAuth token resolution with expiry check
# Priority: 1) credentials.json (skip if expired) 2) foundry-token cache 3) Keychain
_oauth_token=$(python3 << 'PYEOF'
import json, os, time, sys

cred_path = os.path.expanduser("~/.claude/.credentials.json")
token_cache = os.path.expanduser("~/.claude/.foundry-token")

# 1) credentials.json — freshest source, check expiry
try:
    creds = json.load(open(cred_path))
    oauth = creds.get("claudeAiOauth", {})
    token = oauth.get("accessToken", "")
    expires_at = oauth.get("expiresAt", 0)
    if token:
        now_ms = int(time.time() * 1000)
        if not expires_at or now_ms < (expires_at - 300000):  # >5min remaining
            print(token)
            sys.exit(0)
        # Expired — fall through to other sources
except:
    pass

# 2) foundry-token cache (written by active CLI sessions)
try:
    t = open(token_cache).read().strip()
    if t and len(t) > 50:
        print(t)
        sys.exit(0)
except:
    pass

# 3) Keychain (may be stale but worth trying)
import subprocess
try:
    r = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                       capture_output=True, text=True)
    c = json.loads(r.stdout.strip())
    t = c.get("claudeAiOauth", {}).get("accessToken", "")
    if t and "oat01" in t:
        print(t)
        sys.exit(0)
except:
    pass

# All sources exhausted — fail loudly
print("ERROR: All OAuth tokens expired. Start a Claude CLI session to refresh.", file=sys.stderr)
sys.exit(1)
PYEOF
)
if [ -z "$_oauth_token" ]; then
  echo "[foundry-runner] FATAL: No valid OAuth token. Open a Claude CLI session to refresh." >&2
  exit 1
fi
export CLAUDE_CODE_OAUTH_TOKEN="$_oauth_token"
unset _oauth_token
RUNNER_EOF
  # Switch to non-quoted heredoc for variable expansion in env block + paths
  cat >> "${worktree_dir}/.foundry-run.sh" << RUNNER_EOF
${env_block}
cd "${worktree_dir}"
export FOUNDRY_DIR="${FOUNDRY_DIR}"
python3 "${FOUNDRY_DIR}/lib/acp_orchestrator.py" \\
  --backend "${backend}" \\
  --model "${model}" \\
  --worktree "${worktree_dir}" \\
  --prompt-file ".foundry-prompt.md" \\
  --log-file "${log_file}" \\
  --done-file "${done_file}" \\
  --timeout "${AGENT_TIMEOUT:-1800}" \\
  --foundry-dir "${FOUNDRY_DIR}"
RUNNER_EOF
  chmod +x "${worktree_dir}/.foundry-run.sh"
}
