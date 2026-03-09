# commands/spawn.bash — Launch agent in isolated worktree
# _write_runner_script is in lib/runner_script.bash (shared with respawn.bash)

cmd_spawn() {
  # Parse flags
  local prompt_file_override=""
  local issue_number=""
  local create_topic=""
  local topic_id_override=""
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file)
        prompt_file_override="$2"
        shift 2
        ;;
      --prompt-file=*)
        prompt_file_override="${1#*=}"
        shift
        ;;
      --issue-number)
        issue_number="$2"
        shift 2
        ;;
      --issue-number=*)
        issue_number="${1#*=}"
        shift
        ;;
      --topic)
        create_topic="1"
        shift
        ;;
      --topic-id)
        topic_id_override="$2"
        shift 2
        ;;
      --topic-id=*)
        topic_id_override="${1#*=}"
        shift
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  set -- "${positional[@]}"

  local repo_dir="$1" spec_or_task="$2" model="${3:-$DEFAULT_MODEL}"

  if [ -z "$repo_dir" ] || [ -z "$spec_or_task" ]; then
    echo "Usage: foundry spawn <repo-path> <spec-file | task-description> [model] [--prompt-file <file>] [--topic] [--topic-id <id>]"
    echo ""
    echo "Options:"
    echo "  --prompt-file <file>  Use custom prompt instead of template (for orchestrator-driven spawns)"
    echo "  --topic               Create a Telegram forum topic for this task (streams all updates there)"
    echo "  --topic-id <id>       Use an existing Telegram topic ID instead of creating a new one"
    echo ""
    echo "Examples:"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/05-dashboard.md"
    echo "  foundry spawn ~/projects/growthpulse 'Add dark mode support'"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md claude-opus-4-6"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md codex"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md codex:high"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md gemini"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md openclaw          # Jerry picks best agent"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md openclaw:codex   # Jerry hint: use codex"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/04-admin.md codex --prompt-file /tmp/my-prompt.md"
    echo "  foundry spawn ~/projects/aura-shopify specs/backlog/05-dashboard.md --topic       # with TG topic"
    return 1
  fi

  # ── Determine agent backend ──
  detect_model_backend "$model"
  local agent_backend="$AGENT_BACKEND_OUT"
  local codex_reasoning="$CODEX_REASONING_OUT"
  local gemini_model="$GEMINI_MODEL_OUT"
  model="$MODEL_OUT"

  # ── Jerry smart routing: resolve meta-backend to concrete agent ──
  if [ "$agent_backend" = "jerry" ]; then
    # Determine task content early for routing (may read spec file)
    local routing_content="$spec_or_task"
    [ -f "$spec_or_task" ] && routing_content=$(head -100 "$spec_or_task")
    [ -f "$repo_dir/$spec_or_task" ] && routing_content=$(head -100 "$repo_dir/$spec_or_task")

    _jerry_select_agent "$repo_dir" "$routing_content" "$model"
    log "Jerry routing: selected $JERRY_BACKEND (hint: $model)"
    detect_model_backend "$JERRY_MODEL"
    agent_backend="$AGENT_BACKEND_OUT"
    codex_reasoning="$CODEX_REASONING_OUT"
    gemini_model="$GEMINI_MODEL_OUT"
    model="$MODEL_OUT"
  fi

  # Resolve to absolute path
  repo_dir=$(cd "$repo_dir" 2>/dev/null && pwd) || { log_err "Not found: $repo_dir"; return 1; }

  # Validate git repo
  if [ ! -d "$repo_dir/.git" ] && [ ! -f "$repo_dir/.git" ]; then
    log_err "Not a git repo: $repo_dir"
    return 1
  fi

  local project_name
  project_name=$(basename "$repo_dir")

  # Determine task content
  local task_content task_name task_id
  if [ -f "$spec_or_task" ]; then
    task_content=$(cat "$spec_or_task")
    task_name=$(basename "$spec_or_task" .md)
    task_id=$(generate_task_id "$task_name" "$project_name")
  elif [ -f "$repo_dir/$spec_or_task" ]; then
    task_content=$(cat "$repo_dir/$spec_or_task")
    task_name=$(basename "$spec_or_task" .md)
    task_id=$(generate_task_id "$task_name" "$project_name")
  else
    task_content="$spec_or_task"
    task_name=$(echo "$spec_or_task" | head -c 40)
    task_name=$(sanitize "$task_name")
    task_id=$(generate_task_id "$task_name" "$project_name")
  fi

  # ── GitHub Issue override ────────────────────────────────────────────────
  # When --issue-number N is provided (set by orchestrate or called directly):
  #  - task_id  → <proj>-issue-<N>  (stable, dedup-safe)
  #  - task_name → issue-<N>        (drives branch + worktree names)
  #  - task_content gets a mandatory PR instruction appended
  # ── Linear prefix resolution (used for PR title + body) ──────────────────
  local _linear_id=""
  if [ "${LINEAR_INTEGRATION:-false}" = "true" ] && [ -n "${LINEAR_PREFIX_MAP:-}" ]; then
    local _gh_slug _linear_prefix
    _gh_slug=$(_get_gh_repo_slug "$repo_dir" 2>/dev/null || echo "")
    if [ -n "$_gh_slug" ]; then
      _linear_prefix=$(echo "$LINEAR_PREFIX_MAP" | jq -r \
        --arg slug "$_gh_slug" \
        'to_entries[] | select(.key | ascii_downcase == ($slug | ascii_downcase)) | .value // empty' 2>/dev/null || echo "")
      if [ -n "$_linear_prefix" ] && [ -n "$issue_number" ]; then
        _linear_id="${_linear_prefix}-${issue_number}"
        log "Linear integration: will use ${_linear_id}"
      fi
    fi
  fi

  if [ -n "$issue_number" ]; then
    task_name="issue-${issue_number}"
    task_id="$(sanitize "$project_name")-issue-${issue_number}"

    # Build PR closing instructions
    local pr_closes_example="fixes #${issue_number}"
    if [ -n "$_linear_id" ]; then
      pr_closes_example="fixes ${_linear_id}
fixes #${issue_number}"
    fi

    task_content="${task_content}

## PR Requirement

When you open the pull request:
- The PR title MUST start with \`${_linear_id:-}${_linear_id:+: }\` (e.g. \`${_linear_id:-issue-${issue_number}}: Short description\`)
- The PR description body MUST include these lines:

\`\`\`
${pr_closes_example}
\`\`\`

This updates the project board and auto-closes the GitHub Issue on merge."
  fi

  # Check if already running
  local existing
  existing=$(registry_get_task "$task_id" 2>/dev/null || echo "")
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    local status
    status=$(echo "$existing" | jq -r '.status')
    if [ "$status" = "running" ]; then
      log_err "Task '$task_id' is already running. Use 'foundry kill $task_id' first."
      return 1
    fi
  fi

  # Check concurrent limit
  local running_count
  running_count=$(registry_read | jq '[.[] | select(.status == "running")] | length')
  if ! check_concurrent_limit "$running_count" "$MAX_CONCURRENT"; then
    log_err "Max concurrent agents ($MAX_CONCURRENT) reached. Use 'foundry status' to check."
    return 1
  fi

  # ── Phase 1.5: Parallel Conflict Detection ──
  local conflicting_agents
  conflicting_agents=$(detect_parallel_conflict "$repo_dir" "$(registry_read)")
  if [ -n "$conflicting_agents" ]; then
    log_warn "CONFLICT WARNING: Other agents running on same repo ($project_name):"
    for cid in $conflicting_agents; do
      local c_worktree c_files
      c_worktree=$(registry_read | jq -r --arg id "$cid" '.[] | select(.id == $id) | .worktree')
      if [ -d "$c_worktree" ]; then
        c_files=$(git -C "$c_worktree" diff --name-only origin/main 2>/dev/null | head -10)
        if [ -n "$c_files" ]; then
          log_warn "  $cid is modifying: $(echo "$c_files" | tr '\n' ', ' | sed 's/,$//')"
        else
          log_warn "  $cid (no file changes detected yet)"
        fi
      else
        log_warn "  $cid (worktree not accessible)"
      fi
    done
    log_warn "Agents on the same repo may cause merge conflicts. Proceeding anyway."
    echo ""
  fi

  local branch_name="foundry/${task_name}"
  local worktree_dir
  worktree_dir="$(dirname "$repo_dir")/${project_name}-foundry/${task_name}"
  # Legacy tmux session name — kept for DB schema compat, always empty in ACP mode
  local session_name=""
  local log_file="${FOUNDRY_DIR}/logs/${task_id}.log"
  local done_file="${FOUNDRY_DIR}/logs/${task_id}.done"

  mkdir -p "$(dirname "$worktree_dir")" "${FOUNDRY_DIR}/logs"
  rm -f "$done_file" "$log_file"

  # ── Create worktree ──
  log "Creating worktree at ${worktree_dir}..."
  cd "$repo_dir"
  git fetch origin main 2>/dev/null || git fetch origin 2>/dev/null || true

  # Clean up stale worktree/branch
  if [ -d "$worktree_dir" ]; then
    git worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
  fi
  git branch -D "$branch_name" 2>/dev/null || true

  # Detect default branch
  local default_branch
  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

  git worktree add "$worktree_dir" -b "$branch_name" "origin/${default_branch}" || {
    log_err "Failed to create worktree"
    return 1
  }

  # ── Install dependencies ──
  local pkg_mgr
  pkg_mgr=$(detect_pkg_manager "$worktree_dir")
  if [ "$pkg_mgr" != "none" ]; then
    log "Installing dependencies ($pkg_mgr)..."
    (
      cd "$worktree_dir"
      case "$pkg_mgr" in
        pnpm) pnpm install --frozen-lockfile 2>/dev/null || pnpm install ;;
        npm)  npm ci 2>/dev/null || npm install ;;
        yarn) yarn install --frozen-lockfile 2>/dev/null || yarn install ;;
        pip)  pip install -r requirements.txt 2>/dev/null ;;
        uv)   uv sync 2>/dev/null ;;
      esac
    ) || log_warn "Dependency install had warnings (continuing anyway)"
  fi

  # ── Generate prompt ──
  local commit_msg="feat: ${task_name}"
  local pr_title
  if [ -n "$_linear_id" ]; then
    pr_title="${_linear_id}: ${task_name}"
  else
    pr_title="[foundry] ${task_name}"
  fi
  local pr_body="One-shot agent build for: ${task_name}"
  local prompt_file="${worktree_dir}/.foundry-prompt.md"

  if [ -n "$prompt_file_override" ] && [ -f "$prompt_file_override" ]; then
    # Orchestrator-written custom prompt (Zoe pattern)
    cp "$prompt_file_override" "$prompt_file"
    log "Using custom prompt: $prompt_file_override"
  else
    # Default: render from template
    render_template "${FOUNDRY_DIR}/templates/one-shot.md" \
      "TASK_CONTENT=${task_content}" \
      "COMMIT_MSG=${commit_msg}" \
      "PR_TITLE=${pr_title}" \
      "PR_BODY=${pr_body}" \
      "DEFAULT_BRANCH=${default_branch}" \
      "SPEC_PATH=${spec_or_task}" \
      > "$prompt_file"

    # Inject repo's CLAUDE.md for codebase conventions (token-efficient: agent reads it anyway)
    if [ -f "${worktree_dir}/CLAUDE.md" ]; then
      local claude_md
      claude_md=$(head -100 "${worktree_dir}/CLAUDE.md")
      printf '\n# Codebase Conventions (from CLAUDE.md)\n\n%s\n' "$claude_md" >> "$prompt_file"
    fi
  fi

  # ── Build env block (snapshot critical vars for agent process) ──
  local env_block=""
  [ -n "${OPENAI_API_KEY:-}" ]             && env_block+="export OPENAI_API_KEY='${OPENAI_API_KEY}'"$'\n'
  # Claude OAuth token is refreshed at launch time in runner_script.bash (not baked here)
  [ -n "${GOOGLE_API_KEY:-}" ]             && env_block+="export GOOGLE_API_KEY='${GOOGLE_API_KEY}'"$'\n'
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]   && env_block+="export OP_SERVICE_ACCOUNT_TOKEN='${OP_SERVICE_ACCOUNT_TOKEN}'"$'\n'
  [ -n "${GITHUB_TOKEN:-}" ]               && env_block+="export GITHUB_TOKEN='${GITHUB_TOKEN}'"$'\n'
  [ -n "${GH_TOKEN:-}" ]                   && env_block+="export GH_TOKEN='${GH_TOKEN}'"$'\n'
  # Also source profile as fallback for any other vars
  env_block+='[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile" 2>/dev/null'$'\n'
  env_block+='[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null'$'\n'

  # ── Write runner script (supports Claude + Codex + Gemini backends) ──
  _write_runner_script "$agent_backend" "$worktree_dir" "$model" "$log_file" "$done_file" "$env_block" "$codex_reasoning"

  # ── Launch agent ──
  log "Launching agent: ${task_id}"
  nohup bash "${worktree_dir}/.foundry-run.sh" \
    > "${log_file}.stderr" 2>&1 &
  local agent_pid=$!
  echo "$agent_pid" > "${FOUNDRY_DIR}/logs/${task_id}.pid"
  log "Agent PID: $agent_pid"

  # ── Register task ──
  local now
  now=$(date +%s)
  local task_json
  task_json=$(jq -n \
    --arg id "$task_id" \
    --arg repo "$project_name" \
    --arg repoPath "$repo_dir" \
    --arg worktree "$worktree_dir" \
    --arg branch "$branch_name" \
    --arg session "$session_name" \
    --argjson pid "${agent_pid:-null}" \
    --arg agent "$agent_backend" \
    --arg model "$model" \
    --arg spec "$spec_or_task" \
    --arg desc "$task_name" \
    --argjson started "$now" \
    '{
      id: $id,
      repo: $repo,
      repoPath: $repoPath,
      worktree: $worktree,
      branch: $branch,
      tmuxSession: $session,
      pid: $pid,
      agent: $agent,
      model: $model,
      spec: $spec,
      description: $desc,
      startedAt: $started,
      status: "running",
      attempts: 1,
      maxAttempts: ($ENV.MAX_RETRIES // "5" | tonumber),
      pr: null,
      checks: {
        agentAlive: true,
        prCreated: false,
        branchSynced: false,
        ciPassed: false,
        codexReview: null,
        claudeReview: null,
        geminiReview: null,
        screenshotsIncluded: null
      },
      lastCheckedAt: null,
      completedAt: null,
      failureReason: null,
      respawnContext: null,
      notifyOnComplete: true,
      lastNotifiedState: null
    }')

  # Remove old entry if exists, then add new
  if [ "${USE_SQLITE_REGISTRY:-false}" = "true" ]; then
    # SQLite: delete + insert in one operation
    local escaped_id
    escaped_id=$(echo "$task_id" | sed "s/'/''/g")
    _db "DELETE FROM tasks WHERE id = '${escaped_id}';" 2>/dev/null || true
    registry_add_task "$task_json"
  else
    _registry_lock
    local reg
    if [ -f "$REGISTRY" ]; then reg=$(cat "$REGISTRY"); else reg='[]'; fi
    echo "$reg" | jq --arg id "$task_id" '[.[] | select(.id != $id)]' \
      | jq --argjson task "$task_json" '. += [$task]' > "$REGISTRY"
    _registry_unlock
  fi

  # ── Telegram topic creation ──
  local tg_topic_id=""
  if [ -n "$topic_id_override" ]; then
    tg_topic_id="$topic_id_override"
  elif [ -n "$create_topic" ]; then
    local topic_name="${project_name}/${task_name}"
    tg_topic_id=$(tg_create_topic "$topic_name" 2>/dev/null || echo "")
    if [ -n "$tg_topic_id" ]; then
      log "Created Telegram topic: $tg_topic_id"
    else
      log_warn "Failed to create Telegram topic (continuing without)"
    fi
  fi
  if [ -n "$tg_topic_id" ]; then
    registry_update_field "$task_id" "tgTopicId" "$tg_topic_id"
    tg_notify_topic "$tg_topic_id" "Agent spawned: $task_id
Backend: $agent_backend | Model: $model
Branch: $branch_name
Repo: $project_name"
    # Brief notice in main chat
    tg_notify "Spawned \`$task_id\` ($agent_backend) — tracking in topic"
  fi

  echo ""
  log_ok "Agent spawned: ${BOLD}${task_id}${NC}"
  log "  Backend:   $agent_backend"
  log "  Worktree:  $worktree_dir"
  log "  Branch:    $branch_name"
  log "  Model:     $model"
  log "  PID:       $agent_pid"
  [ -n "$tg_topic_id" ] && log "  TG Topic:  $tg_topic_id"
  log "  Log:       tail -f $log_file"
  echo ""
}
