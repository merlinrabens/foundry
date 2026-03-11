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

# _link_openclaw_skill — auto-symlink skill into OpenClaw workspace if present
_link_openclaw_skill() {
  local oc_skills="${HOME}/.openclaw/workspace/skills"
  local skill_source="${FOUNDRY_DIR}/openclaw"

  [ ! -d "$oc_skills" ] && return 0
  [ ! -d "$skill_source" ] && return 0

  local target="${oc_skills}/foundry"

  if [ -L "$target" ]; then
    # Already a symlink — check it points to the right place
    local current
    current=$(readlink "$target" 2>/dev/null || echo "")
    if [ "$current" = "$skill_source" ]; then
      return 0  # Already correct
    fi
    rm -f "$target"
  elif [ -d "$target" ]; then
    # Real directory (old copy) — back it up and replace with symlink
    mv "$target" "${target}.bak.$(date +%s)"
    log "Backed up old skill dir to ${target}.bak.*"
  fi

  ln -s "$skill_source" "$target"
  log_ok "Linked OpenClaw skill: $target -> $skill_source"
}
