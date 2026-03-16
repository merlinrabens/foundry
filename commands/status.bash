# commands/status.bash — Show task overview with check status

# Print a colored string padded to exact visible width
# Usage: _pad_color <width> <color_code> <text>
_pad_color() {
  local width="$1" color="$2" text="$3"
  local visible_len=${#text}
  local pad=$((width - visible_len))
  [ "$pad" -lt 0 ] && pad=0
  printf "%b%s%b%*s" "$color" "$text" "$NC" "$pad" ""
}

cmd_status() {
  local tasks
  tasks=$(registry_read)
  local total
  total=$(echo "$tasks" | jq '. | length')

  if [ "$total" -eq 0 ]; then
    log "No tasks. Use 'foundry spawn' to create one."
    return 0
  fi

  # Auto-size columns to fit longest values (with sensible minimums for headers)
  local task_w=4 repo_w=4 agent_w=7 status_w=6 try_w=9
  local max_len
  max_len=$(echo "$tasks" | jq -r '.[].id' | awk '{ if (length > m) m = length } END { print m+0 }')
  [ "$max_len" -gt "$task_w" ] && task_w=$max_len
  max_len=$(echo "$tasks" | jq -r '.[].repo' | awk '{ if (length > m) m = length } END { print m+0 }')
  [ "$max_len" -gt "$repo_w" ] && repo_w=$max_len
  max_len=$(echo "$tasks" | jq -r '.[].agent // "?"' | awk '{ if (length > m) m = length } END { print m+0 }')
  [ "$max_len" -gt "$agent_w" ] && agent_w=$max_len
  max_len=$(echo "$tasks" | jq -r '.[].status' | awk '{ if (length > m) m = length } END { print m+0 }')
  [ "$max_len" -gt "$status_w" ] && status_w=$max_len
  max_len=$(echo "$tasks" | jq -r '.[] | (("\(.attempts // 1)/\(.maxAttempts // 3)" + "     ")[:5]) + (if (.reviewFixAttempts // 0) > 0 then " | \(.reviewFixAttempts)/\(.maxReviewFixes // 20)" else "" end)' | awk '{ if (length > m) m = length } END { print m+0 }')
  [ "$max_len" -gt "$try_w" ] && try_w=$max_len
  # Add 2-char gutter to each column
  task_w=$((task_w + 2)); repo_w=$((repo_w + 2)); agent_w=$((agent_w + 2)); status_w=$((status_w + 2)); try_w=$((try_w + 2))

  echo ""
  printf "${BOLD}%-${task_w}s %-${repo_w}s %-${agent_w}s %-${status_w}s %-${try_w}s %-9s %s${NC}\n" "TASK" "REPO" "BACKEND" "STATUS" "SPAWN | FIX" "CHECKS" "PR"
  printf "%-${task_w}s %-${repo_w}s %-${agent_w}s %-${status_w}s %-${try_w}s %-9s %s\n" "----" "----" "-------" "------" "-----------" "------" "--"

  local ids
  ids=$(echo "$tasks" | jq -r '.[].id')
  for id in $ids; do
    local task
    task=$(echo "$tasks" | jq --arg id "$id" '.[] | select(.id == $id)')
    local repo_name agent status attempts max_attempts pr repo_path checks_summary
    repo_name=$(echo "$task" | jq -r '.repo')
    agent=$(echo "$task" | jq -r '.agent // "?"')
    status=$(echo "$task" | jq -r '.status')
    attempts=$(echo "$task" | jq -r '.attempts // 1')
    max_attempts=$(echo "$task" | jq -r '.maxAttempts // 3')
    pr=$(echo "$task" | jq -r '.pr // "-"')
    repo_path=$(echo "$task" | jq -r '.repoPath // ""')

    # Construct full PR URL if only a number is stored
    if echo "$pr" | grep -qE '^[0-9]+$' && [ -n "$repo_path" ] && [ -d "$repo_path" ]; then
      local remote_url slug
      remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
      if [ -n "$remote_url" ]; then
        slug=$(echo "$remote_url" | sed -E 's#^https://github\.com/##; s#^git@[^:]+:##; s#^[^:]+:##; s#\.git$##')
        pr="https://github.com/${slug}/pull/${pr}"
      fi
    fi

    # Build checks summary (C=CI, R=Claude, K=Codex, G=Gemini, S=Synced)
    local p c r k g s
    local ga
    eval "$(echo "$task" | jq -r '@sh "p=\(.checks.prCreated // false) c=\(.checks.ciPassed // false) s=\(.checks.branchSynced // false) r=\(.checks.claudeReview // "null") k=\(.checks.codexReview // "null") g=\(.checks.geminiReview // "null") ga=\(.checks.geminiAddressed // false)"')"
    checks_summary=""
    [ "$c" = "true" ] && checks_summary+="C" || checks_summary+="."
    [ "$r" = "APPROVED" ] && checks_summary+="R" || checks_summary+="."
    [ "$k" = "APPROVED" ] && checks_summary+="K" || checks_summary+="."
    if [ "$g" = "APPROVED" ] || [ "$g" = "AUTO_PASSED" ] || [ "$ga" = "true" ]; then
      checks_summary+="G"
    else
      checks_summary+="."
    fi
    [ "$s" = "true" ] && checks_summary+="S" || checks_summary+="."

    # Pad spawn part to 5 chars so pipe aligns with "SPAWN | FIX" header
    local spawn_part
    spawn_part=$(printf "%-5s" "${attempts}/${max_attempts}")
    local try_str="$spawn_part"
    local rfx max_rfx
    rfx=$(echo "$task" | jq -r '.reviewFixAttempts // 0')
    max_rfx=$(echo "$task" | jq -r '.maxReviewFixes // 20')
    [ "$rfx" -gt 0 ] && try_str="${spawn_part} | ${rfx}/${max_rfx}"

    # Color status
    local status_color=""
    case "$status" in
      running|pr-open)                         status_color="$BLUE" ;;
      ready|merged|done|completed|ci-passed)   status_color="$GREEN" ;;
      review-ready|done-no-pr)                 status_color="$GREEN" ;;
      failed|crashed|exhausted)                status_color="$RED" ;;
      needs-respawn|ci-failed|timeout|deploy-failed) status_color="$YELLOW" ;;
    esac

    # Print row with ANSI-aware padding for status column
    printf "%-${task_w}s %-${repo_w}s %-${agent_w}s " "$id" "$repo_name" "$agent"
    _pad_color "$status_w" "$status_color" "$status"
    printf " %-${try_w}s %-9s %s\n" "$try_str" "$checks_summary" "$pr"
  done

  echo ""
  echo "  Spawn | Fix: crash-retries | review-fix-cycles"
  echo "  Checks: C=CI R=Claude K=Codex G=Gemini S=Synced"
  echo ""
  local running monitoring ready failed
  running=$(echo "$tasks" | jq '[.[] | select(.status == "running")] | length')
  monitoring=$(echo "$tasks" | jq '[.[] | select(.status == "pr-open")] | length')
  ready=$(echo "$tasks" | jq '[.[] | select(.status == "ready")] | length')
  failed=$(echo "$tasks" | jq '[.[] | select(.status | test("failed|crashed|timeout|ci-failed|exhausted"))] | length')
  local summary="Running: $running"
  [ "$monitoring" -gt 0 ] && summary="$summary | Monitoring: $monitoring"
  summary="$summary | Ready: $ready | Failed: $failed | Total: $total"
  log "$summary"
}
