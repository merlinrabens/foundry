# commands/design.bash — Gemini-first design pipeline

# design calls cmd_spawn to launch the Gemini agent
type cmd_spawn &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spawn.bash"

cmd_design() {
  local repo_dir="$1" spec_or_task="$2" then_agent="${3:-$CLAUDE_DEFAULT}"

  if [ -z "$repo_dir" ] || [ -z "$spec_or_task" ]; then
    echo "Usage: foundry design <repo-path> <spec-file | task-description> [then-agent]"
    echo ""
    echo "Gemini creates HTML/CSS spec, then-agent implements it."
    echo "Default then-agent: $CLAUDE_DEFAULT"
    echo ""
    echo "Examples:"
    echo "  foundry design ~/projects/your-repo specs/backlog/05-dashboard.md"
    echo "  foundry design ~/projects/your-repo specs/backlog/05-dashboard.md codex:high"
    return 1
  fi

  # Check Gemini is available
  if ! command -v "${GEMINI_BIN}" >/dev/null 2>&1; then
    log_err "Gemini CLI not found. Install: npm install -g @google/gemini-cli"
    return 1
  fi

  # Determine task content
  local task_content
  repo_dir=$(cd "$repo_dir" 2>/dev/null && pwd) || { log_err "Not found: $repo_dir"; return 1; }
  if [ -f "$spec_or_task" ]; then
    task_content=$(cat "$spec_or_task")
  elif [ -f "$repo_dir/$spec_or_task" ]; then
    task_content=$(cat "$repo_dir/$spec_or_task")
  else
    task_content="$spec_or_task"
  fi

  local task_name
  if [ -f "$spec_or_task" ]; then
    task_name=$(basename "$spec_or_task" .md)
  else
    task_name=$(echo "$spec_or_task" | head -c 40)
    task_name=$(sanitize "$task_name")
  fi

  log "Step 1: Spawning Gemini for design spec..."
  log "  When Gemini finishes, run:"
  log "  ${BOLD}foundry spawn $repo_dir $spec_or_task $then_agent${NC}"
  echo ""

  # Spawn Gemini with design template
  local design_template="${FOUNDRY_DIR}/templates/design.md"
  if [ ! -f "$design_template" ]; then
    log_err "Missing template: $design_template"
    return 1
  fi

  cmd_spawn "$repo_dir" "$spec_or_task" "gemini"

  log "Design agent spawned. Monitor with: foundry status"
  log "When design completes, implement with:"
  log "  foundry spawn $repo_dir $spec_or_task $then_agent"
}
