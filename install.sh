#!/bin/bash
# Foundry Installer
# One-liner: curl -fsSL https://raw.githubusercontent.com/merlinrabens/foundry/main/install.sh | bash
# Uninstall: curl -fsSL https://raw.githubusercontent.com/merlinrabens/foundry/main/install.sh | bash -s -- --uninstall
set -eo pipefail

FOUNDRY_VERSION="0.4.0"
FOUNDRY_HOME="${FOUNDRY_HOME:-$HOME/.foundry}"
REPO="https://github.com/merlinrabens/foundry.git"

# ─── Color helpers (degrade if no tty) ────────────────────────────────
if [ -t 1 ] && [ -t 2 ]; then
  BOLD="\033[1m"
  DIM="\033[2m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  RED="\033[31m"
  CYAN="\033[36m"
  RESET="\033[0m"
else
  BOLD="" DIM="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

info()  { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
fail()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
step()  { printf "  ${CYAN}→${RESET} %s\n" "$*"; }

# ─── Uninstall ─────────────────────────────────────────────────────────
if [ "${1:-}" = "--uninstall" ]; then
  echo ""
  printf "  ${BOLD}Foundry — Uninstall${RESET}\n"
  echo ""

  if [ -d "$FOUNDRY_HOME" ]; then
    step "Removing $FOUNDRY_HOME..."
    rm -rf "$FOUNDRY_HOME"
    info "Removed $FOUNDRY_HOME"
  else
    warn "$FOUNDRY_HOME not found — nothing to remove"
  fi

  # Clean up shell RC files
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$rc" ] && grep -q "FOUNDRY_HOME" "$rc" 2>/dev/null; then
      step "Cleaning $rc..."
      tmp=$(mktemp)
      grep -v "FOUNDRY_HOME" "$rc" | grep -v "^# Foundry$" > "$tmp"
      # Remove trailing blank lines left behind
      sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" > "$rc"
      rm -f "$tmp"
      info "Removed Foundry entries from $(basename "$rc")"
    fi
  done

  echo ""
  info "Foundry uninstalled. Goodbye."
  echo ""
  exit 0
fi

# ─── Banner ────────────────────────────────────────────────────────────
echo ""
printf "  ${BOLD}╔══════════════════════════════════════╗${RESET}\n"
printf "  ${BOLD}║  Foundry — Multi-Agent Code Factory  ║${RESET}\n"
printf "  ${BOLD}╚══════════════════════════════════════╝${RESET}\n"
printf "  ${DIM}v${FOUNDRY_VERSION}${RESET}\n"
echo ""

# ─── Prerequisites ──────────────────────────────────────────────────
step "Checking prerequisites..."
missing=()
command -v git      >/dev/null 2>&1 || missing+=("git")
command -v jq       >/dev/null 2>&1 || missing+=("jq")
command -v gh       >/dev/null 2>&1 || missing+=("gh")
command -v sqlite3  >/dev/null 2>&1 || missing+=("sqlite3")

if [ ${#missing[@]} -gt 0 ]; then
  fail "Missing: ${missing[*]}"
  echo ""

  # Auto-install on Linux if apt-get available
  if command -v apt-get >/dev/null 2>&1; then
    step "Detected apt-get — attempting install..."
    # gh CLI needs special repo on Debian/Ubuntu
    needs_gh=false
    apt_pkgs=()
    for pkg in "${missing[@]}"; do
      if [ "$pkg" = "gh" ]; then
        needs_gh=true
      else
        apt_pkgs+=("$pkg")
      fi
    done

    if [ ${#apt_pkgs[@]} -gt 0 ]; then
      sudo apt-get update -qq
      sudo apt-get install -y -qq "${apt_pkgs[@]}" || {
        fail "apt-get install failed. Install manually: sudo apt-get install ${apt_pkgs[*]}"
        exit 1
      }
    fi

    if $needs_gh; then
      if ! command -v gh >/dev/null 2>&1; then
        step "Installing GitHub CLI..."
        (type -p wget >/dev/null || sudo apt-get install -y -qq wget) \
          && sudo mkdir -p -m 755 /etc/apt/keyrings \
          && out=$(mktemp) \
          && wget -qO "$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          && cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
          && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
          && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
          && sudo apt-get update -qq \
          && sudo apt-get install -y -qq gh \
          && rm -f "$out" \
          || {
            fail "Could not install gh CLI. See https://cli.github.com/"
            exit 1
          }
      fi
    fi

    info "Prerequisites installed via apt-get"
  elif command -v brew >/dev/null 2>&1; then
    echo "  Fix: brew install ${missing[*]}"
    exit 1
  else
    echo "  Install these manually and re-run the installer."
    exit 1
  fi
fi

info "All prerequisites found"

# ─── GitHub CLI auth check ──────────────────────────────────────────
if ! gh auth status >/dev/null 2>&1; then
  warn "GitHub CLI not authenticated"
  echo "       Run: gh auth login"
  echo "       Then re-run this installer."
  exit 1
fi
info "GitHub CLI authenticated"

# ─── Install or Update ──────────────────────────────────────────────
if [ -d "$FOUNDRY_HOME/.git" ]; then
  step "Updating existing installation at $FOUNDRY_HOME..."
  # Stash any local changes (config.local.env, foundry.db)
  git -C "$FOUNDRY_HOME" stash --quiet 2>/dev/null || true
  git -C "$FOUNDRY_HOME" pull --ff-only --quiet 2>/dev/null || {
    # ff-only failed, force reset to origin
    warn "Fast-forward failed — resetting to latest..."
    git -C "$FOUNDRY_HOME" fetch --quiet origin
    git -C "$FOUNDRY_HOME" reset --hard origin/main --quiet
  }
  # Restore local changes
  git -C "$FOUNDRY_HOME" stash pop --quiet 2>/dev/null || true
  info "Updated to latest"
elif [ -d "$FOUNDRY_HOME" ]; then
  # Directory exists but not a git repo — partial install
  warn "$FOUNDRY_HOME exists but is not a git repo"
  step "Backing up to ${FOUNDRY_HOME}.bak and re-cloning..."
  mv "$FOUNDRY_HOME" "${FOUNDRY_HOME}.bak.$(date +%s)"
  git clone --quiet "$REPO" "$FOUNDRY_HOME"
  info "Fresh install (old files backed up)"
else
  step "Cloning to $FOUNDRY_HOME..."
  git clone --quiet "$REPO" "$FOUNDRY_HOME"
  info "Installed to $FOUNDRY_HOME"
fi

chmod +x "$FOUNDRY_HOME/foundry"

# ─── Initialize config.local.env if missing ────────────────────────
if [ ! -f "$FOUNDRY_HOME/config.local.env" ]; then
  cp "$FOUNDRY_HOME/config.env" "$FOUNDRY_HOME/config.local.env"
  # Clear the example KNOWN_PROJECTS so user starts fresh
  tmp=$(mktemp)
  awk '/^KNOWN_PROJECTS=\(/{skip=1} skip && /\)/{skip=0; next} !skip' "$FOUNDRY_HOME/config.local.env" > "$tmp"
  echo 'KNOWN_PROJECTS=()' >> "$tmp"
  mv "$tmp" "$FOUNDRY_HOME/config.local.env"
  info "Created config.local.env"
fi

# ─── Initialize SQLite database if missing ─────────────────────────
if [ ! -f "$FOUNDRY_HOME/foundry.db" ] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$FOUNDRY_HOME/foundry.db" "
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
  info "Created foundry.db (SQLite registry)"
fi

# ─── PATH ───────────────────────────────────────────────────────────
in_path=false
case ":$PATH:" in *":$FOUNDRY_HOME:"*) in_path=true ;; esac

if ! $in_path; then
  SHELL_RC=""
  # Prefer the user's current shell
  case "${SHELL:-}" in
    */zsh)  [ -f "$HOME/.zshrc" ]  && SHELL_RC="$HOME/.zshrc" ;;
    */bash) [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc" ;;
  esac
  # Fallback: try both
  [ -z "$SHELL_RC" ] && [ -f "$HOME/.zshrc" ]  && SHELL_RC="$HOME/.zshrc"
  [ -z "$SHELL_RC" ] && [ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"
  [ -z "$SHELL_RC" ] && [ -f "$HOME/.bash_profile" ] && SHELL_RC="$HOME/.bash_profile"

  if [ -n "$SHELL_RC" ] && ! grep -q "FOUNDRY_HOME" "$SHELL_RC" 2>/dev/null; then
    {
      echo ""
      echo "# Foundry — Multi-Agent Code Factory"
      echo "export FOUNDRY_HOME=\"$FOUNDRY_HOME\""
      echo "export PATH=\"\$FOUNDRY_HOME:\$PATH\""
    } >> "$SHELL_RC"
    info "Added to PATH in $(basename "$SHELL_RC")"
  elif [ -n "$SHELL_RC" ]; then
    info "PATH already configured in $(basename "$SHELL_RC")"
  else
    warn "Could not detect shell RC file — add manually:"
    echo "       export PATH=\"$FOUNDRY_HOME:\$PATH\""
  fi
  # Make available in this session
  export PATH="$FOUNDRY_HOME:$PATH"
fi

# ─── OpenClaw Integration ─────────────────────────────────────────────
OC_SKILLS="$HOME/.openclaw/workspace/skills"
if [ -d "$OC_SKILLS" ]; then
  step "Detected OpenClaw — linking skill..."
  OC_TARGET="$OC_SKILLS/foundry"
  OC_SOURCE="$FOUNDRY_HOME/openclaw"

  # Copy instead of symlink — OpenClaw rejects skills whose realpath
  # escapes the workspace root (~/.openclaw/workspace)
  if [ -L "$OC_TARGET" ]; then
    rm -f "$OC_TARGET"
  elif [ -d "$OC_TARGET" ]; then
    rm -rf "$OC_TARGET"
  fi

  cp -r "$OC_SOURCE" "$OC_TARGET"
  info "Installed OpenClaw skill: foundry"
fi

# ─── Detect Agents ──────────────────────────────────────────────────
echo ""
printf "  ${BOLD}Agents:${RESET}\n"
found=0
for agent in claude codex gemini; do
  if command -v "$agent" >/dev/null 2>&1; then
    printf "    ${GREEN}%-12s${RESET} found\n" "$agent"
    found=$((found + 1))
  else
    case "$agent" in
      claude) hint="npm i -g @anthropic-ai/claude-code" ;;
      codex)  hint="npm i -g @openai/codex" ;;
      gemini) hint="npm i -g @google/gemini-cli" ;;
    esac
    printf "    ${DIM}%-12s${RESET} missing  ${DIM}(%s)${RESET}\n" "$agent" "$hint"
  fi
done

if [ "$found" -eq 0 ]; then
  echo ""
  warn "No agents found. Install at least one to get started."
fi

# ─── Done ───────────────────────────────────────────────────────────
echo ""
printf "  ${GREEN}${BOLD}Foundry v${FOUNDRY_VERSION} installed!${RESET}\n"
echo ""
echo "  Next steps:"
echo ""
printf "    ${CYAN}foundry setup${RESET}     Interactive config wizard\n"
printf "    ${CYAN}foundry status${RESET}    Dashboard\n"
printf "    ${CYAN}foundry help${RESET}      All commands\n"
echo ""
if ! $in_path; then
  printf "  ${YELLOW}Open a new terminal first, or:${RESET} source $SHELL_RC\n"
  echo ""
fi
