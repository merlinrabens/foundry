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
RUNNER_EOF

  # Only add OAuth token resolution for Claude backend (Codex/Gemini use API keys)
  if [[ "$backend" == "claude" ]]; then
    cat >> "${worktree_dir}/.foundry-run.sh" << 'RUNNER_EOF'
# Claude auth: read setup-token and set CLAUDE_CODE_OAUTH_TOKEN.
# IMPORTANT: Use ONLY .foundry-setup-token as the single token source.
# The SDK's multi-source resolver concatenates tokens from credentials.json +
# .foundry-token + Keychain into one invalid Authorization header.
# Keeping only setup-token prevents this (Single Token Source Rule).
_token_file="$HOME/.claude/.foundry-setup-token"
if [ ! -f "$_token_file" ]; then
  echo "[foundry-runner] FATAL: No setup-token at $_token_file" >&2
  echo "[foundry-runner] Run: claude setup-token > ~/.claude/.foundry-setup-token" >&2
  exit 1
fi
_token=$(cat "$_token_file")
if [ -z "$_token" ] || [ ${#_token} -lt 50 ]; then
  echo "[foundry-runner] FATAL: Setup-token too short or empty" >&2
  exit 1
fi
export CLAUDE_CODE_OAUTH_TOKEN="$_token"
unset _token _token_file
RUNNER_EOF
  fi
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
