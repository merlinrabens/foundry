# commands/update.bash — Self-update foundry from upstream

cmd_update() {
  local foundry_home="${FOUNDRY_DIR}"

  if [ ! -d "$foundry_home/.git" ]; then
    log_err "Not a git install — cannot auto-update. Re-install with:"
    echo "  curl -fsSL https://raw.githubusercontent.com/merlinrabens/foundry/main/install.sh | bash"
    return 1
  fi

  log "Updating Foundry from upstream..."

  # Stash local changes (config.local.env, foundry.db)
  local had_stash=false
  if ! git -C "$foundry_home" diff --quiet 2>/dev/null; then
    git -C "$foundry_home" stash --quiet 2>/dev/null && had_stash=true
  fi

  # Pull latest
  if git -C "$foundry_home" pull --ff-only --quiet 2>/dev/null; then
    log_ok "Updated to latest"
  else
    log_warn "Fast-forward failed — fetching and resetting..."
    git -C "$foundry_home" fetch --quiet origin
    git -C "$foundry_home" reset --hard origin/main --quiet
    log_ok "Reset to origin/main"
  fi

  # Restore local changes
  if $had_stash; then
    git -C "$foundry_home" stash pop --quiet 2>/dev/null || log_warn "Could not restore local changes (check git stash)"
  fi

  # Re-link OpenClaw skill if applicable
  _link_openclaw_skill

  local version
  version=$(grep -m1 'FOUNDRY_VERSION=' "$foundry_home/install.sh" 2>/dev/null | cut -d'"' -f2 || echo "unknown")
  log_ok "Foundry v${version} ready"
}

# _install_openclaw_skill — copy skill files into OpenClaw workspace
# Uses cp instead of symlink because OpenClaw rejects skills whose
# realpath escapes the workspace root (~/.openclaw/workspace).
_install_openclaw_skill() {
  local oc_skills="${HOME}/.openclaw/workspace/skills"
  local skill_source="${FOUNDRY_DIR}/openclaw"

  [ ! -d "$oc_skills" ] && return 0
  [ ! -d "$skill_source" ] && return 0

  local target="${oc_skills}/foundry"

  # Remove old symlink (pre-v4.6 installs) or stale copy
  if [ -L "$target" ]; then
    rm -f "$target"
  elif [ -d "$target" ]; then
    # Check if already up-to-date (compare SKILL.md content)
    if diff -q "$skill_source/SKILL.md" "$target/SKILL.md" >/dev/null 2>&1; then
      return 0  # Already current
    fi
  fi

  rm -rf "$target"
  cp -r "$skill_source" "$target"
  log_ok "Installed OpenClaw skill: $target"
}

# Backward compat alias
_link_openclaw_skill() { _install_openclaw_skill; }
