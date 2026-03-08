# commands/check.bash — Monitor all agents (zero AI tokens)

# check calls cmd_respawn for auto-respawn on failure
type cmd_respawn &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/respawn.bash"

# Kill a task's PID if still alive (prevents zombie processes on terminal transitions)
_kill_task_pid() {
  local task_pid="$1"
  if [ -n "$task_pid" ] && [ "$task_pid" != "null" ]; then
    if kill -0 "$task_pid" 2>/dev/null; then
      kill -TERM "$task_pid" 2>/dev/null || true
      log "Killed orphan PID $task_pid"
    fi
  fi
}

# Shared helper: evaluate a PR and display/notify status
_check_pr_status() {
  local id="$1" check_dir="$2" pr_ref="$3" task="$4"
  local attempts="$5" max_attempts="$6" agent="$7" model="$8"
  local retries="$9" started="${10}" project="${11}"

  _evaluate_pr "$check_dir" "$pr_ref" "$task"
  _update_pr_checks "$id"

  local last_notified
  last_notified=$(echo "$task" | jq -r '.lastNotifiedState // ""')

  if [ "$_PR_ANY_FAIL" -gt 0 ]; then
    # Deployment-ONLY failures: classify as transient (wait) vs build error (respawn)
    if [ "$_PR_DEPLOY_FAILS" -gt 0 ] && [ "$_PR_CI_FAILS" -eq 0 ]; then
      if is_transient_deploy_failure "$_PR_DEPLOY_DESCS"; then
        # Transient (502, timeout, CDN) — wait for self-heal
        echo -e "${YELLOW}Deploy failing (transient): $_PR_DEPLOY_FAIL_NAMES${NC}"
        if [ "$last_notified" != "deploy-failing" ]; then
          registry_update_field "$id" "lastNotifiedState" "deploy-failing"
          tg_notify_task "$id" "PR $pr_ref: deployment failing ($_PR_DEPLOY_FAIL_NAMES) — transient infra issue, waiting for retry. $_PR_URL" \
            || registry_update_field "$id" "lastNotifiedState" ""
        fi
        return 5  # Transient deploy failure (don't respawn)
      else
        # Build error (code issue) — treat as CI failure, respawn to fix
        echo -e "${YELLOW}Deploy BUILD failing: $_PR_DEPLOY_FAIL_NAMES${NC}"
        if [ "$last_notified" != "deploy-build-failing" ]; then
          registry_update_field "$id" "lastNotifiedState" "deploy-build-failing"
          tg_notify_task "$id" "PR $pr_ref: deployment BUILD error ($_PR_DEPLOY_FAIL_NAMES) — needs code fix. $_PR_URL" \
            || registry_update_field "$id" "lastNotifiedState" ""
        fi
        _PR_CI_FAIL_NAMES="deploy:${_PR_DEPLOY_FAIL_NAMES}"
        return 1  # Code issue — respawn to fix
      fi
    fi
    # CI test/lint failures (or mixed deploy+CI): respawn
    local fail_detail="$_PR_CI_FAIL_NAMES"
    [ "$_PR_DEPLOY_FAILS" -gt 0 ] && fail_detail="$fail_detail + deploy: $_PR_DEPLOY_FAIL_NAMES"
    echo -e "${YELLOW}CI failing ($_PR_ANY_FAIL check(s): ${fail_detail:-unknown})${NC}"
    if [ "$last_notified" != "ci-failing" ]; then
      registry_update_field "$id" "lastNotifiedState" "ci-failing"
      tg_notify_task "$id" "PR $pr_ref: CI failing [${fail_detail:-checks}] [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
        || registry_update_field "$id" "lastNotifiedState" ""
    fi
    return 1  # CI failing
  elif [ "$_PR_ANY_PENDING" -gt 0 ]; then
    echo -e "${BLUE}CI pending ($_PR_ANY_PENDING check(s))${NC}"
    return 2  # CI pending
  elif [ "$_PR_CHANGES_REQUESTED" -gt 0 ]; then
    # Wait for all reviewers before starting fix cycle (collect ALL feedback first)
    if [ "${_PR_ALL_REVIEWS_IN:-0}" -eq 0 ]; then
      echo -e "${BLUE}Changes requested, waiting for remaining reviews [$_PR_CHECKS_SUMMARY]${NC}"
      if [ "$last_notified" != "awaiting-all-reviews" ]; then
        registry_update_field "$id" "lastNotifiedState" "awaiting-all-reviews"
        tg_notify_task "$id" "PR $pr_ref: changes requested, waiting for all reviewers [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
          || registry_update_field "$id" "lastNotifiedState" ""
      fi
      return 4  # Wait for all reviews before fixing
    fi
    echo -e "${YELLOW}CI passed, all reviews in, changes requested${NC}"
    if [ "$last_notified" != "changes-requested" ]; then
      registry_update_field "$id" "lastNotifiedState" "changes-requested"
      tg_notify_task "$id" "PR $pr_ref: all reviews in, changes requested [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
        || registry_update_field "$id" "lastNotifiedState" ""
    fi
    return 3  # Changes requested (all reviews collected)
  elif [ "${_PR_GEMINI_PENDING:-0}" -eq 1 ]; then
    # Gemini check-run exists but review not posted yet (fresh PR race condition)
    echo -e "${BLUE}Awaiting Gemini review [$_PR_CHECKS_SUMMARY]${NC}"
    return 4  # Awaiting reviews (Gemini pending)
  elif [ "$_PR_GEMINI_APPROVED" -eq 0 ]; then
    # Gemini has unaddressed findings — check if we already attempted a fix
    local gemini_addressed
    gemini_addressed=$(echo "$task" | jq -r '.checks.geminiAddressed // false')
    if [ "$gemini_addressed" = "true" ]; then
      # Already attempted fix — mark Gemini as resolved, fall through to ready check
      :
    else
      # Wait for Claude + Codex before fixing Gemini findings (first cycle only)
      if [ "${_PR_ALL_REVIEWS_IN:-0}" -eq 0 ]; then
        echo -e "${BLUE}Gemini has findings, waiting for remaining reviews [$_PR_CHECKS_SUMMARY]${NC}"
        if [ "$last_notified" != "awaiting-all-reviews" ]; then
          registry_update_field "$id" "lastNotifiedState" "awaiting-all-reviews"
          tg_notify_task "$id" "PR $pr_ref: Gemini findings, waiting for all reviewers [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
            || registry_update_field "$id" "lastNotifiedState" ""
        fi
        return 4  # Wait for all reviews before fixing
      fi
      echo -e "${YELLOW}Gemini findings need fixing (all reviews in) [$_PR_CHECKS_SUMMARY]${NC}"
      if [ "$last_notified" != "gemini-findings" ]; then
        registry_update_field "$id" "lastNotifiedState" "gemini-findings"
        tg_notify_task "$id" "PR $pr_ref: all reviews in, Gemini findings to fix [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
          || registry_update_field "$id" "lastNotifiedState" ""
      fi
      return 6  # Gemini findings need fix
    fi
  fi
  # Ready check (Gemini either approved or findings addressed)
  if [ "$_PR_CLAUDE_APPROVED" -gt 0 ] || [ "$_PR_CODEX_APPROVED" -gt 0 ]; then
    echo -e "${GREEN}READY TO MERGE -> $_PR_URL${NC}"
    registry_update_field "$id" "status" "ready"
    # Add label to trigger visual evidence workflow
    (cd "$check_dir" 2>/dev/null && gh label create "ready-for-evidence" \
      --color 0E8A16 --description "Foundry: triggers visual evidence" \
      --force 2>/dev/null) || true
    (cd "$check_dir" 2>/dev/null && gh pr edit ${pr_ref:+"$pr_ref"} \
      --add-label "ready-for-evidence" 2>/dev/null) || true
    if [ "$last_notified" != "ready" ]; then
      registry_update_field "$id" "lastNotifiedState" "ready"
      tg_notify_task "$id" "PR $pr_ref ready to merge [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
        || registry_update_field "$id" "lastNotifiedState" ""
    fi
    return 0  # Ready
  else
    echo -e "${BLUE}CI passed, awaiting reviews${NC}"
    if [ "$last_notified" != "awaiting-reviews" ]; then
      registry_update_field "$id" "lastNotifiedState" "awaiting-reviews"
      tg_notify_task "$id" "PR $pr_ref: CI passed, awaiting reviews [$_PR_CHECKS_SUMMARY] - $_PR_URL" \
        || registry_update_field "$id" "lastNotifiedState" ""
    fi
    return 4  # Awaiting reviews
  fi
}

cmd_check() {
  local target_task_id="${1:-}"

  local tasks
  tasks=$(registry_read)

  # Targeted single-task check: foundry check <task-id>
  if [ -n "$target_task_id" ]; then
    local target_task
    target_task=$(echo "$tasks" | jq --arg id "$target_task_id" '.[] | select(.id == $id)')
    if [ -z "$target_task" ] || [ "$target_task" = "null" ]; then
      log_err "Task not found: $target_task_id"
      return 1
    fi
    log "Targeted check: $target_task_id"
    # Rewrite tasks to contain only this task for the check loop below
    tasks=$(echo "$tasks" | jq --arg id "$target_task_id" '[.[] | select(.id == $id)]')
  fi

  local running_count monitoring_count respawn_count
  running_count=$(echo "$tasks" | jq '[.[] | select(.status == "running")] | length')
  monitoring_count=$(echo "$tasks" | jq '[.[] | select(.status == "pr-open" or .status == "ready" or .status == "deploy-failed")] | length')
  respawn_count=$(echo "$tasks" | jq '[.[] | select(.status == "needs-respawn" or .status == "ci-failed" or .status == "review-failed" or .status == "failed" or .status == "crashed")] | length')

  if [ "$running_count" -eq 0 ] && [ "$monitoring_count" -eq 0 ] && [ "$respawn_count" -eq 0 ]; then
    log "No running or monitored agents."
    return 0
  fi

  [ "$running_count" -gt 0 ] && log "Checking $running_count running agent(s)..."
  [ "$monitoring_count" -gt 0 ] && log "Monitoring $monitoring_count PR(s)..."
  [ "$respawn_count" -gt 0 ] && log "Respawning $respawn_count task(s)..."
  echo ""

  local ids
  ids=$(echo "$tasks" | jq -r '.[] | select(.status == "running" or .status == "pr-open" or .status == "ready" or .status == "deploy-failed") | .id')

  for id in $ids; do
    local task
    task=$(echo "$tasks" | jq --arg id "$id" '.[] | select(.id == $id)')

    # Single jq call to extract all fields (10x fewer forks)
    local branch repo done_file log_file started worktree agent model retries project attempts max_attempts
    eval "$(echo "$task" | jq -r '@sh "branch=\(.branch) repo=\(.repoPath) started=\(.startedAt) worktree=\(.worktree) agent=\(.agent) model=\(.model) retries=\((.attempts // 1) - 1) project=\(.repo) attempts=\(.attempts // 1) max_attempts=\(.maxAttempts // 3)"')"
    # Derive log/done paths from task ID
    log_file="${FOUNDRY_DIR}/logs/${id}.log"
    done_file="${FOUNDRY_DIR}/logs/${id}.done"

    printf "  %-35s " "$id"

    # 0. pr-open / ready / deploy-failed: skip agent lifecycle, go to PR monitoring
    local task_status
    task_status=$(echo "$task" | jq -r '.status')
    if [ "$task_status" = "pr-open" ] || [ "$task_status" = "ready" ] || [ "$task_status" = "deploy-failed" ]; then
      local pr_num
      pr_num=$(echo "$task" | jq -r '.pr // ""')
      if [ -z "$pr_num" ] || [ "$pr_num" = "null" ]; then
        echo -e "${YELLOW}pr-open but no PR number — reverting to done-no-pr${NC}"
        _kill_task_pid "$task_pid"
        registry_batch_update "$id" "status=done-no-pr" "completedAt=$(date +%s)"
        continue
      fi

      local check_dir="$repo"
      [ -d "$worktree" ] && check_dir="$worktree"

      # Check if PR exists and its state
      local pr_state
      pr_state=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr view "$pr_num" --json state --jq '.state' || echo "")
      if [ -z "$pr_state" ]; then
        echo -e "${YELLOW}PR #$pr_num not found (deleted or never created)${NC}"
        registry_batch_update "$id" "status=done-no-pr" "completedAt=$(date +%s)"
        continue
      fi
      local last_notified
      last_notified=$(echo "$task" | jq -r '.lastNotifiedState // ""')
      if [ "$pr_state" = "MERGED" ]; then
        echo -e "${GREEN}MERGED${NC}"
        registry_batch_update "$id" "status=merged" "completedAt=$(date +%s)"
        [ "$last_notified" != "merged" ] && registry_update_field "$id" "lastNotifiedState" "merged"
        continue
      elif [ "$pr_state" = "CLOSED" ]; then
        echo -e "${RED}CLOSED (not merged)${NC}"
        registry_batch_update "$id" "status=closed" "completedAt=$(date +%s)"
        continue
      fi

      # Evaluate PR using shared helper
      local pr_result=0
      _check_pr_status "$id" "$check_dir" "$pr_num" "$task" \
        "$attempts" "$max_attempts" "$agent" "$model" "$retries" "$started" "$project" \
        || pr_result=$?

      # Handle CI failure, deploy failure, review issues for monitored PRs
      if [ "$pr_result" -eq 5 ]; then
        # Deploy-only failure (Railway/Vercel/Supabase): keep monitoring, don't respawn
        registry_update_field "$id" "status" "deploy-failed"
      elif [ "$pr_result" -eq 1 ]; then
        # CI failing — use review-fix budget (agent has a PR, just needs to fix CI)
        registry_update_field "$id" "status" "ci-failed"
        _try_review_fix "$id" \
          "CI failed ($_PR_CI_FAIL_NAMES)" "$agent" "$model" "$retries" "$started" "$project" "$_PR_URL"
      elif [ "$pr_result" -eq 3 ]; then
        registry_update_field "$id" "status" "review-failed"
        _try_review_fix "$id" \
          "Review changes requested" "$agent" "$model" "$retries" "$started" "$project" "$_PR_URL"
      elif [ "$pr_result" -eq 6 ]; then
        # Gemini findings — one fix attempt, then mark addressed
        registry_update_field "$id" "status" "review-failed"
        registry_update_field "$id" "checks.geminiAddressed" "true"
        _try_review_fix "$id" \
          "Gemini review findings need fixing" "$agent" "$model" "$retries" "$started" "$project" "$_PR_URL"
      elif [ "$pr_result" -eq 0 ]; then
        # Ready — try auto-merge if enabled
        _try_auto_merge "$id" "$check_dir"
      fi
      continue
    fi

    # 1. Agent finished? (done marker exists)
    if [ -f "$done_file" ]; then
      local exit_code
      exit_code=$(cat "$done_file")

      if [ "$exit_code" = "0" ]; then
        # Check for PR — first check registry (survives worktree pruning), then gh
        local pr_url=""
        pr_url=$(echo "$task" | jq -r '.pr // empty')
        # Resolve PR number to full URL if needed
        if [ -n "$pr_url" ] && echo "$pr_url" | grep -qE '^[0-9]+$'; then
          local remote_url slug
          remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null || echo "")
          if [ -n "$remote_url" ]; then
            slug=$(echo "$remote_url" | sed -E 's#^https://github\.com/##; s#^git@[^:]+:##; s#\.git$##')
            pr_url="https://github.com/${slug}/pull/${pr_url}"
          fi
        fi
        # Fall back to gh pr list if registry has no PR
        if [ -z "$pr_url" ] || [ "$pr_url" = "null" ]; then
          local check_dir="$worktree"
          [ ! -d "$worktree" ] && check_dir="$repo"
          pr_url=$(cd "$check_dir" 2>/dev/null && gh_retry gh pr list --head "$branch" --json url --jq '.[0].url' || echo "")
        fi

        if [ -n "$pr_url" ] && [ "$pr_url" != "null" ]; then
          registry_batch_update "$id" "pr=$pr_url" "checks.prCreated=true"

          # Evaluate PR using shared helper
          local pr_result=0
          _check_pr_status "$id" "$worktree" "" "$task" \
            "$attempts" "$max_attempts" "$agent" "$model" "$retries" "$started" "$project" \
            || pr_result=$?

          if [ "$pr_result" -eq 5 ]; then
            # Deploy-only failure — keep monitoring, don't respawn
            registry_update_field "$id" "status" "deploy-failed"
            registry_update_field "$id" "pr" "$pr_url"
          elif [ "$pr_result" -eq 1 ]; then
            # CI failing — use review-fix budget (agent has a PR, just needs to fix CI)
            registry_update_field "$id" "status" "ci-failed"
            _try_review_fix "$id" \
              "CI failed ($_PR_CI_FAIL_NAMES)" "$agent" "$model" "$retries" "$started" "$project" "$_PR_URL"
          elif [ "$pr_result" -eq 2 ]; then
            # CI pending — just update PR reference
            registry_update_field "$id" "pr" "$pr_url"
          elif [ "$pr_result" -eq 3 ]; then
            # Changes requested — use review-fix budget (separate from crash retries)
            registry_update_field "$id" "status" "review-failed"
            _try_review_fix "$id" \
              "Review changes requested" "$agent" "$model" "$retries" "$started" "$project" "$_PR_URL"
          elif [ "$pr_result" -eq 6 ]; then
            # Gemini findings — one fix attempt, then mark addressed
            registry_update_field "$id" "status" "review-failed"
            registry_update_field "$id" "checks.geminiAddressed" "true"
            _try_review_fix "$id" \
              "Gemini review findings need fixing" "$agent" "$model" "$retries" "$started" "$project" "$_PR_URL"
          elif [ "$pr_result" -eq 0 ]; then
            # Ready to merge — check if truly all checks pass
            if _all_checks_pass "$id"; then
              local current_status
              current_status=$(registry_get_task "$id" | jq -r '.status // "running"')
              if [ "$current_status" != "ready" ]; then
                local is_draft
                is_draft=$(cd "$worktree" 2>/dev/null && gh_retry gh pr view --json isDraft --jq '.isDraft' || echo "false")
                [ "$is_draft" = "true" ] && { cd "$worktree" 2>/dev/null && gh pr ready 2>/dev/null || true; }
                local now_ts; now_ts=$(date +%s)
                registry_update_field "$id" "completedAt" "$now_ts"
                local duration=$(( now_ts - started ))
                pattern_log "$id" "$agent" "$model" "$retries" "true" "$duration" "$project" "feature"
              fi
              # Try auto-merge if enabled
              _try_auto_merge "$id" "$worktree"
            fi
          fi
          # pr_result == 4 (awaiting reviews) — nothing extra to do
        else
          # Check if agent actually produced any work (exit 0 but zero commits = failed)
          local commit_count
          commit_count=$(cd "$worktree" 2>/dev/null && git rev-list --count "$(git merge-base HEAD main 2>/dev/null || echo main)..HEAD" 2>/dev/null || echo "0")
          if [ "$commit_count" = "0" ]; then
            echo -e "${RED}Failed (exit 0 but no commits, no PR)${NC}"
            _kill_task_pid "$task_pid"
            registry_update_field "$id" "status" "failed"
            _try_respawn_or_exhaust "$id" "$attempts" "$max_attempts" \
              "Agent produced no changes (exit 0)" "$agent" "$model" "$retries" "$started" "$project"
          else
            # Check if a PR was actually created (may have been missed)
            local late_pr
            late_pr=$(cd "$worktree" 2>/dev/null && gh_retry gh pr list --head "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" --json number,url --jq '.[0]' 2>/dev/null || echo "")
            if [ -n "$late_pr" ] && [ "$late_pr" != "null" ]; then
              local late_pr_num late_pr_url
              late_pr_num=$(echo "$late_pr" | jq -r '.number')
              late_pr_url=$(echo "$late_pr" | jq -r '.url')
              echo -e "${GREEN}Late PR discovery: #${late_pr_num}${NC}"
              _kill_task_pid "$task_pid"
              registry_batch_update "$id" "status=pr-open" "pr=$late_pr_num" "completedAt=$(date +%s)"
            else
              echo -e "${YELLOW}Done but no PR created ($commit_count commit(s) on branch)${NC}"
              _kill_task_pid "$task_pid"
              registry_batch_update "$id" "status=done-no-pr" "completedAt=$(date +%s)"
            fi
          fi
        fi
        continue
      else
        # Agent failed with non-zero exit
        echo -e "${RED}Failed (exit $exit_code)${NC}"
        _kill_task_pid "$task_pid"
        registry_update_field "$id" "status" "failed"
        local task_pr_url
        task_pr_url=$(echo "$task" | jq -r '.pr // empty')
        _try_respawn_or_exhaust "$id" "$attempts" "$max_attempts" \
          "Agent failed (exit $exit_code)" "$agent" "$model" "$retries" "$started" "$project" "$task_pr_url"
        continue
      fi
    fi

    # 2. Agent process alive? (PID-based liveness)
    local agent_alive=0
    local task_pid
    task_pid=$(echo "$task" | jq -r '.pid // empty')
    if [ -n "$task_pid" ] && [ "$task_pid" != "null" ]; then
      kill -0 "$task_pid" 2>/dev/null && agent_alive=1
    fi

    if [ "$agent_alive" -eq 0 ]; then
      echo -e "${RED}Crashed (process gone)${NC}"
      registry_update_field "$id" "status" "crashed"
      local task_pr_url
      task_pr_url=$(echo "$task" | jq -r '.pr // empty')
      _try_respawn_or_exhaust "$id" "$attempts" "$max_attempts" \
        "Agent crashed (process dead)" "$agent" "$model" "$retries" "$started" "$project" "$task_pr_url"
      continue
    fi

    # 3. Timeout?
    local now elapsed
    now=$(date +%s)
    elapsed=$((now - started))
    if [ "$elapsed" -gt "$AGENT_TIMEOUT" ]; then
      echo -e "${YELLOW}Timed out (${elapsed}s)${NC}"
      _kill_task_pid "$task_pid"
      echo "1" > "$done_file"
      registry_update_field "$id" "status" "timeout"
      local task_pr_url; task_pr_url=$(echo "$task" | jq -r '.pr // empty')
      _try_respawn_or_exhaust "$id" "$attempts" "$max_attempts" \
        "Agent timed out (${elapsed}s)" "$agent" "$model" "$retries" "$started" "$project" "$task_pr_url"
      continue
    fi

    # 4. Still running
    local mins=$((elapsed / 60))
    echo -e "${BLUE}Running (${mins}m)${NC}"
  done

  # Reconciliation pass: catch tasks stuck in limbo states
  # Tasks can get stuck when status is changed externally (e.g., by orchestrator)
  # without going through the respawn mechanism
  local reconcile_ids
  reconcile_ids=$(registry_read | jq -r '.[] | select(
    (.status == "failed" or .status == "crashed" or .status == "needs-respawn") and
    ((.completedAt // 0) == 0) and
    ((.attempts // 1) < (.maxAttempts // 3))
  ) | .id')
  if [ -n "$reconcile_ids" ]; then
    log "Reconciliation: found stuck tasks to retry"
    for rid in $reconcile_ids; do
      local rtask
      rtask=$(registry_read | jq --arg id "$rid" '.[] | select(.id == $id)')
      local rattempts rmax ragent rmodel rretries rstarted rproject rpr
      eval "$(echo "$rtask" | jq -r '@sh "rattempts=\(.attempts // 1) rmax=\(.maxAttempts // 3) ragent=\(.agent) rmodel=\(.model) rretries=\((.attempts // 1) - 1) rstarted=\(.startedAt) rproject=\(.repo)"')"
      rpr=$(echo "$rtask" | jq -r '.pr // empty')
      local rstatus
      rstatus=$(echo "$rtask" | jq -r '.status')
      log "  Reconciling $rid ($rstatus, attempt $rattempts/$rmax)"
      _kill_task_pid "$(echo "$rtask" | jq -r '.pid // empty')"
      _try_respawn_or_exhaust "$rid" "$rattempts" "$rmax" \
        "Reconciliation: $rstatus at attempt $rattempts/$rmax" \
        "$ragent" "$rmodel" "$rretries" "$rstarted" "$rproject" "$rpr"
    done
  fi

  # Auto-prune: remove done/merged/closed tasks older than 24h
  local now prune_ids
  now=$(date +%s)
  prune_ids=$(registry_read | jq -r --argjson now "$now" '
    .[] | select(
      (.status == "done" or .status == "merged" or .status == "closed" or .status == "done-no-pr" or .status == "exhausted") and
      ((.completedAt // 0) > 0) and
      (($now - (.completedAt // 0)) > 86400)
    ) | .id')
  if [ -n "$prune_ids" ]; then
    local count=0
    for pid in $prune_ids; do
      registry_remove "$pid" 2>/dev/null && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && log "Auto-pruned $count completed task(s) older than 24h"
  fi
}
