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
_oauth_token=$(python3 -c "import json; print(json.load(open('$HOME/.claude/.credentials.json'))['claudeAiOauth']['accessToken'])" 2>/dev/null || true)
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
