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

  # Only add OAuth token resolution for Claude backend (Codex/Gemini use cached sign-in)
  if [[ "$backend" == "claude" ]]; then
    cat >> "${worktree_dir}/.foundry-run.sh" << 'RUNNER_EOF'
# Claude auth fallback chain (OAuth first, API key last):
#   1. ~/.foundry/.setup-token  (explicit setup token, highest priority)
#   2. CLAUDE_CODE_OAUTH_TOKEN env var (pre-configured OAuth)
#   3. OS credential store: macOS Keychain or Linux secret-tool (cached from 'claude /login')
#   4. ANTHROPIC_API_KEY env var (pay-per-use, lowest priority)
_claude_token=""
_claude_auth_type=""

# 1. Setup token file (OAuth)
if [ -f "$HOME/.foundry/.setup-token" ]; then
  _claude_token=$(cat "$HOME/.foundry/.setup-token")
  if [ -n "$_claude_token" ] && [ ${#_claude_token} -ge 50 ]; then
    _claude_auth_type="setup-token"
  else
    _claude_token=""
  fi
fi

# 2. Env var OAuth token
if [ -z "$_claude_token" ] && [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  _claude_token="$CLAUDE_CODE_OAUTH_TOKEN"
  _claude_auth_type="env:CLAUDE_CODE_OAUTH_TOKEN"
fi

# 3. OS credential store (OAuth)
# macOS: Keychain via `security` CLI
# Linux: secret-tool (GNOME Keyring) or credential file
if [ -z "$_claude_token" ]; then
  _keychain_json=""
  if command -v security >/dev/null 2>&1; then
    _keychain_json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || echo "")
  elif command -v secret-tool >/dev/null 2>&1; then
    _keychain_json=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null || echo "")
  fi
  if [ -n "$_keychain_json" ]; then
    _claude_token=$(echo "$_keychain_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('claudeAiOauth',{}).get('accessToken',''))" 2>/dev/null || echo "")
    if [ -n "$_claude_token" ]; then
      _claude_auth_type="credential-store"
    fi
  fi
  unset _keychain_json
fi

# 4. API key (pay-per-use, last resort)
if [ -z "$_claude_token" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  export ANTHROPIC_API_KEY
  _claude_auth_type="env:ANTHROPIC_API_KEY (pay-per-use)"
  echo "[foundry-runner] Claude auth: $_claude_auth_type" >&2
  unset _claude_auth_type
  # Skip CLAUDE_CODE_OAUTH_TOKEN export — claude-agent-acp reads ANTHROPIC_API_KEY directly
else
  if [ -z "$_claude_token" ]; then
    echo "[foundry-runner] FATAL: No Claude auth found." >&2
    echo "[foundry-runner] Fix: run 'claude /login' or 'claude setup-token > ~/.foundry/.setup-token'" >&2
    exit 1
  fi
  echo "[foundry-runner] Claude auth: $_claude_auth_type" >&2
  export CLAUDE_CODE_OAUTH_TOKEN="$_claude_token"
fi
unset _claude_token _claude_auth_type
RUNNER_EOF
  fi

  # Codex auth: cached sign-in first, API key fallback
  if [[ "$backend" == "codex" ]]; then
    cat >> "${worktree_dir}/.foundry-run.sh" << 'RUNNER_EOF'
# Codex auth (OAuth first, API key fallback):
#   1. ~/.codex/auth.json (cached ChatGPT sign-in)
#   2. OPENAI_API_KEY env var (pay-per-use)
if [ -f "$HOME/.codex/auth.json" ]; then
  echo "[foundry-runner] Codex auth: cached sign-in" >&2
elif [ -n "${OPENAI_API_KEY:-}" ]; then
  echo "[foundry-runner] Codex auth: OPENAI_API_KEY (pay-per-use)" >&2
else
  echo "[foundry-runner] FATAL: No Codex auth found." >&2
  echo "[foundry-runner] Fix: run 'codex' to sign in, or export OPENAI_API_KEY" >&2
  exit 1
fi
RUNNER_EOF
  fi

  # Gemini auth: cached sign-in first, API key fallback
  if [[ "$backend" == "gemini" ]]; then
    cat >> "${worktree_dir}/.foundry-run.sh" << 'RUNNER_EOF'
# Gemini auth (OAuth first, API key fallback):
#   1. ~/.gemini/oauth_creds.json (cached Google sign-in)
#   2. GOOGLE_API_KEY env var (pay-per-use)
if [ -f "$HOME/.gemini/oauth_creds.json" ]; then
  echo "[foundry-runner] Gemini auth: cached sign-in" >&2
elif [ -n "${GOOGLE_API_KEY:-}" ]; then
  echo "[foundry-runner] Gemini auth: GOOGLE_API_KEY (pay-per-use)" >&2
else
  echo "[foundry-runner] FATAL: No Gemini auth found." >&2
  echo "[foundry-runner] Fix: run 'gemini' to sign in, or export GOOGLE_API_KEY" >&2
  exit 1
fi
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
