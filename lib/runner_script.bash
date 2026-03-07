#!/bin/bash
# lib/runner_script.bash — Shared runner script generator (used by spawn + respawn)
[[ "${_LIB_RUNNER_SCRIPT_LOADED:-}" == "1" ]] && return 0
_LIB_RUNNER_SCRIPT_LOADED=1

# Generates .foundry-run.sh for any backend (claude/codex/gemini).
# Delegates to acp_orchestrator.py for structured JSON-RPC agent management.
_write_runner_script() {
  local backend="$1" worktree_dir="$2" model="$3" log_file="$4" done_file="$5"
  local env_block="$6" codex_reasoning="$7"

  cat > "${worktree_dir}/.foundry-run.sh" << 'RUNNER_EOF'
#!/bin/bash
unset CLAUDECODE
# Refresh OAuth token at launch time (not stale from spawn time)
# Priority: 1) credentials file 2) Keychain 3) token cache
_oauth_token=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.claude/.credentials.json')))['claudeAiOauth']['accessToken'])" 2>/dev/null || true)
if [ -z "$_oauth_token" ]; then
  _oauth_token=$(python3 -c "import subprocess,json; r=subprocess.run(['security','find-generic-password','-s','Claude Code-credentials','-w'],capture_output=True,text=True); c=json.loads(r.stdout.strip()); t=c.get('claudeAiOauth',{}).get('accessToken',''); assert t and 'oat01' in t; print(t)" 2>/dev/null || true)
fi
if [ -z "$_oauth_token" ]; then
  _oauth_token=$(python3 -c "import os; print(open(os.path.expanduser('~/.claude/.foundry-token')).read().strip())" 2>/dev/null || true)
fi
[ -n "$_oauth_token" ] && export CLAUDE_CODE_OAUTH_TOKEN="$_oauth_token"
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
