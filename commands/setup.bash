#!/bin/bash
# commands/setup.bash — Interactive setup wizard
# Configures repos, agents, notifications, CI templates, and database.

cmd_setup() {
  # ─── Color helpers ──────────────────────────────────────────────────
  local BOLD DIM GREEN YELLOW RED CYAN RESET
  if [ -t 1 ] && [ -t 0 ]; then
    BOLD="\033[1m" DIM="\033[2m" GREEN="\033[32m" YELLOW="\033[33m"
    RED="\033[31m" CYAN="\033[36m" RESET="\033[0m"
  else
    BOLD="" DIM="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
  fi

  local interactive=true
  if [ ! -t 0 ]; then
    interactive=false
  fi

  _info()  { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
  _warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
  _fail()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
  _step()  { printf "  ${CYAN}→${RESET} %s\n" "$*"; }
  _ask()   { printf "  ${CYAN}?${RESET} %s " "$*"; }

  echo ""
  printf "  ${BOLD}╔═══════════════════════╗${RESET}\n"
  printf "  ${BOLD}║    Foundry  Setup     ║${RESET}\n"
  printf "  ${BOLD}╚═══════════════════════╝${RESET}\n"
  echo ""

  if ! $interactive; then
    _warn "Non-interactive mode detected (stdin is not a terminal)"
    _warn "Run this command in an interactive terminal for full setup"
    _warn "Skipping to validation checks..."
    echo ""
    _validate_install
    return 0
  fi

  local config_file="${FOUNDRY_DIR}/config.local.env"
  if [ ! -f "$config_file" ]; then
    cp "${FOUNDRY_DIR}/config.env" "$config_file"
    _info "Created config.local.env from template"
  fi

  # Track what was configured for summary
  local summary_repos=0
  local summary_agents=0
  local summary_telegram=false
  local summary_ci_repos=()
  local summary_agents_md=()

  # ─── 1. Repos ───────────────────────────────────────────────────────
  printf "  ${BOLD}Step 1: Repositories${RESET}\n"
  echo ""
  echo "  Which repos should Foundry manage?"
  echo "  Enter full paths, one per line. Empty line when done."
  echo ""

  local repos=()
  while true; do
    _ask "repo path:"
    read -r repo_path
    [ -z "$repo_path" ] && break

    # Expand ~ to $HOME
    repo_path="${repo_path/#\~/$HOME}"

    # Resolve to absolute path
    if [ -d "$repo_path" ]; then
      repo_path="$(cd "$repo_path" && pwd)"
    fi

    if [ ! -d "$repo_path" ]; then
      _fail "Directory not found: $repo_path"
      continue
    fi
    if [ ! -d "$repo_path/.git" ]; then
      _fail "Not a git repo: $repo_path"
      continue
    fi
    repos+=("$repo_path")
    _info "Added: $repo_path"
  done

  if [ ${#repos[@]} -gt 0 ]; then
    summary_repos=${#repos[@]}

    # Build KNOWN_PROJECTS array
    local projects_block="KNOWN_PROJECTS=("
    for r in "${repos[@]}"; do
      projects_block+=$'\n'"  \"$r\""
    done
    projects_block+=$'\n'")"

    # Remove existing KNOWN_PROJECTS block
    if grep -q "^KNOWN_PROJECTS=" "$config_file" 2>/dev/null; then
      local tmp; tmp=$(mktemp)
      awk '/^KNOWN_PROJECTS=\(/{skip=1} skip && /\)/{skip=0; next} !skip' "$config_file" > "$tmp"
      mv "$tmp" "$config_file"
    fi
    echo "$projects_block" >> "$config_file"
    echo ""
    _info "Saved ${#repos[@]} repo(s) to config.local.env"
  else
    echo ""
    _warn "No repos added — you can add them later in config.local.env"
  fi

  # ─── 2. AGENTS.md generation ───────────────────────────────────────
  echo ""
  printf "  ${BOLD}Step 2: AGENTS.md${RESET}\n"
  echo ""

  if [ ${#repos[@]} -gt 0 ]; then
    for r in "${repos[@]}"; do
      local repo_name; repo_name=$(basename "$r")
      if [ ! -f "$r/AGENTS.md" ]; then
        _ask "Generate AGENTS.md in $repo_name? (y/n):"
        read -r yn
        if [[ "$yn" =~ ^[Yy] ]]; then
          _generate_agents_md "$r"
          summary_agents_md+=("$repo_name")
          _info "Created AGENTS.md in $repo_name"
        fi
      else
        _info "$repo_name already has AGENTS.md"
      fi
    done
  else
    _warn "No repos to configure — skipping"
  fi

  # ─── 3. Agent config ────────────────────────────────────────────────
  echo ""
  printf "  ${BOLD}Step 3: AI Agents${RESET}\n"
  echo ""

  # Claude
  if command -v claude >/dev/null 2>&1; then
    local claude_path; claude_path=$(command -v claude)
    _info "Claude Code: $claude_path"
    summary_agents=$((summary_agents + 1))
  else
    _warn "Claude Code: not installed"
    printf "       Install: ${DIM}npm i -g @anthropic-ai/claude-code${RESET}\n"
  fi

  # Codex
  if command -v codex >/dev/null 2>&1; then
    _info "Codex CLI: $(command -v codex)"
    summary_agents=$((summary_agents + 1))
    if [ -n "${OPENAI_API_KEY:-}" ]; then
      _info "OpenAI API key: set"
    else
      _warn "OpenAI API key: not set"
      printf "       ${DIM}export OPENAI_API_KEY=sk-...${RESET}\n"
    fi
  else
    _warn "Codex CLI: not installed"
    printf "       Install: ${DIM}npm i -g @openai/codex${RESET}\n"
  fi

  # Gemini
  if command -v gemini >/dev/null 2>&1; then
    _info "Gemini CLI: $(command -v gemini)"
    summary_agents=$((summary_agents + 1))
    if [ -n "${GOOGLE_API_KEY:-}" ]; then
      _info "Google API key: set"
    else
      _warn "Google API key: not set"
      printf "       ${DIM}export GOOGLE_API_KEY=AIza...${RESET}\n"
    fi
  else
    _warn "Gemini CLI: not installed"
    printf "       Install: ${DIM}npm i -g @google/gemini-cli${RESET}\n"
  fi

  if [ "$summary_agents" -eq 0 ]; then
    echo ""
    _fail "No agents found. Install at least one to use Foundry."
  fi

  # ─── 4. Notifications (optional) ────────────────────────────────────
  echo ""
  printf "  ${BOLD}Step 4: Telegram Notifications (optional)${RESET}\n"
  echo ""
  _ask "Set up Telegram notifications? (y/n):"
  read -r yn
  if [[ "$yn" =~ ^[Yy] ]]; then
    _ask "Bot token:"
    read -r tg_token
    _ask "Chat ID:"
    read -r tg_chat

    # Validate token format (looks like 123456:ABC-DEF...)
    if [ -n "$tg_token" ] && [[ ! "$tg_token" =~ ^[0-9]+:.+ ]]; then
      _warn "Token doesn't look like a Telegram bot token (expected format: 123456:ABC...)"
      _ask "Use anyway? (y/n):"
      read -r use_anyway
      if [[ ! "$use_anyway" =~ ^[Yy] ]]; then
        tg_token=""
      fi
    fi

    # Validate chat ID (should be numeric, possibly negative)
    if [ -n "$tg_chat" ] && [[ ! "$tg_chat" =~ ^-?[0-9]+$ ]]; then
      _warn "Chat ID doesn't look numeric (expected format: -1001234567890)"
      _ask "Use anyway? (y/n):"
      read -r use_anyway
      if [[ ! "$use_anyway" =~ ^[Yy] ]]; then
        tg_chat=""
      fi
    fi

    if [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
      # Remove existing TG entries
      local tmp; tmp=$(mktemp)
      grep -v "^export TG_CHAT_ID=" "$config_file" | grep -v "^export OPENCLAW_TG_BOT_TOKEN=" | grep -v "^# Telegram notifications$" > "$tmp"
      mv "$tmp" "$config_file"

      {
        echo ""
        echo "# Telegram notifications"
        echo "export TG_CHAT_ID=\"$tg_chat\""
        echo "export OPENCLAW_TG_BOT_TOKEN=\"$tg_token\""
      } >> "$config_file"
      _info "Telegram configured"
      summary_telegram=true
    else
      _warn "Skipped — missing token or chat ID"
    fi
  fi

  # ─── 5. CI templates ────────────────────────────────────────────────
  echo ""
  printf "  ${BOLD}Step 5: CI Review Workflows${RESET}\n"
  echo ""

  if [ ${#repos[@]} -gt 0 ]; then
    _ask "Deploy CI review workflows to your repos? (y/n):"
    read -r yn
    if [[ "$yn" =~ ^[Yy] ]]; then
      for r in "${repos[@]}"; do
        local repo_name; repo_name=$(basename "$r")
        _step "Deploying to $repo_name..."
        if [ -x "${FOUNDRY_DIR}/ci-templates/deploy-ci.sh" ]; then
          if bash "${FOUNDRY_DIR}/ci-templates/deploy-ci.sh" "$r" 2>/dev/null; then
            _info "Done: $repo_name"
            summary_ci_repos+=("$repo_name")
          else
            _fail "Failed: $repo_name"
            printf "       Run manually: ${DIM}bash ci-templates/deploy-ci.sh $r${RESET}\n"
          fi
        else
          _warn "ci-templates/deploy-ci.sh not found — skipping"
          break
        fi
      done
    fi
  else
    _warn "No repos configured — skipping CI deployment"
  fi

  # ─── 6. SQLite database ─────────────────────────────────────────────
  echo ""
  printf "  ${BOLD}Step 6: Database${RESET}\n"
  echo ""

  local db_path="${FOUNDRY_DIR}/foundry.db"
  if [ -f "$db_path" ]; then
    local task_count
    task_count=$(sqlite3 "$db_path" "SELECT COUNT(*) FROM tasks;" 2>/dev/null || echo "?")
    _info "foundry.db exists ($task_count tasks)"
  else
    _step "Creating SQLite database..."
    if command -v sqlite3 >/dev/null 2>&1; then
      sqlite3 "$db_path" "
        CREATE TABLE IF NOT EXISTS tasks (
          task_id TEXT PRIMARY KEY,
          repo TEXT,
          spec TEXT,
          branch TEXT,
          pr_number INTEGER,
          status TEXT DEFAULT 'spawned',
          agent TEXT,
          model TEXT,
          worktree TEXT,
          pid INTEGER,
          attempts INTEGER DEFAULT 1,
          review_fix_attempts INTEGER DEFAULT 0,
          ci_status TEXT,
          claude_review TEXT,
          codex_review TEXT,
          gemini_review TEXT,
          synced INTEGER DEFAULT 0,
          tg_topic_id INTEGER,
          risk_tier TEXT,
          created_at TEXT DEFAULT (datetime('now')),
          updated_at TEXT DEFAULT (datetime('now')),
          error TEXT,
          metadata TEXT
        );
        PRAGMA journal_mode=WAL;
      "
      _info "Created foundry.db"
    else
      _fail "sqlite3 not found — cannot create database"
    fi
  fi

  # ─── 7. Self-test ──────────────────────────────────────────────────
  echo ""
  printf "  ${BOLD}Step 7: Verification${RESET}\n"
  echo ""

  if "${FOUNDRY_DIR}/foundry" help >/dev/null 2>&1; then
    _info "foundry CLI works"
  else
    _fail "foundry CLI failed — check config.local.env"
  fi

  # ─── Summary ────────────────────────────────────────────────────────
  echo ""
  printf "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  printf "  ${BOLD}Setup Complete${RESET}\n"
  printf "  ${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  echo ""
  printf "  Repos:          ${CYAN}%d configured${RESET}\n" "$summary_repos"
  printf "  Agents:         ${CYAN}%d found${RESET}\n" "$summary_agents"
  printf "  Telegram:       %s\n" "$($summary_telegram && printf "${GREEN}configured${RESET}" || printf "${DIM}skipped${RESET}")"
  if [ ${#summary_ci_repos[@]} -gt 0 ]; then
    printf "  CI workflows:   ${GREEN}deployed to ${summary_ci_repos[*]}${RESET}\n"
  else
    printf "  CI workflows:   ${DIM}skipped${RESET}\n"
  fi
  if [ ${#summary_agents_md[@]} -gt 0 ]; then
    printf "  AGENTS.md:      ${GREEN}created in ${summary_agents_md[*]}${RESET}\n"
  fi
  printf "  Database:       ${GREEN}ready${RESET}\n"
  printf "  Config:         ${DIM}%s${RESET}\n" "$config_file"
  echo ""
  echo "  Get started:"
  echo ""
  printf "    ${CYAN}foundry status${RESET}                              Dashboard\n"
  printf "    ${CYAN}foundry scan ~/projects/my-repo${RESET}             Find labeled issues\n"
  printf "    ${CYAN}foundry spawn ~/projects/my-repo issue-1${RESET}    Launch an agent\n"
  echo ""
}

# ─── Generate AGENTS.md ──────────────────────────────────────────────
_generate_agents_md() {
  local repo_path="$1"
  local repo_name; repo_name=$(basename "$repo_path")
  cat > "$repo_path/AGENTS.md" << 'AGENTSMD'
# AGENTS.md

## Foundry Configuration

foundry.issues: true

## Coding Guidelines

- Follow existing code style and conventions
- Write tests for new functionality
- Keep commits focused and atomic
- Use descriptive variable and function names

## Repository Context

This repository is managed by Foundry. Add the `foundry` label to a GitHub Issue
to have an AI agent pick it up and create a pull request.

### Spec-based workflow
Drop a markdown spec in `specs/backlog/` and run `foundry orchestrate` to auto-spawn agents.

### Issue-based workflow
Label any GitHub Issue with `foundry` and it will be picked up by `foundry scan`.
AGENTSMD
}

# ─── Non-interactive validation ──────────────────────────────────────
_validate_install() {
  local ok=true

  if [ -f "${FOUNDRY_DIR}/config.local.env" ]; then
    printf "  ✓ config.local.env exists\n"
  else
    printf "  ✗ config.local.env missing — run setup interactively\n"
    ok=false
  fi

  if [ -f "${FOUNDRY_DIR}/foundry.db" ]; then
    printf "  ✓ foundry.db exists\n"
  else
    printf "  ✗ foundry.db missing\n"
    ok=false
  fi

  local agents=0
  command -v claude >/dev/null 2>&1 && { printf "  ✓ claude found\n"; agents=$((agents+1)); }
  command -v codex  >/dev/null 2>&1 && { printf "  ✓ codex found\n";  agents=$((agents+1)); }
  command -v gemini >/dev/null 2>&1 && { printf "  ✓ gemini found\n"; agents=$((agents+1)); }
  [ "$agents" -eq 0 ] && { printf "  ✗ no agents installed\n"; ok=false; }

  if "${FOUNDRY_DIR}/foundry" help >/dev/null 2>&1; then
    printf "  ✓ foundry CLI works\n"
  else
    printf "  ✗ foundry CLI broken\n"
    ok=false
  fi

  echo ""
  if $ok; then
    echo "  All checks passed."
  else
    echo "  Some checks failed. Run 'foundry setup' interactively to fix."
  fi
}
