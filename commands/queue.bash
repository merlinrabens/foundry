# commands/queue.bash — Priority-scored spec backlog + auto-spawn

# auto calls cmd_spawn to launch agents
type cmd_spawn &>/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spawn.bash"

cmd_queue() {
  log "Scanning and scoring specs across all known projects..."
  echo ""

  local running_count
  running_count=$(registry_read | jq '[.[] | select(.status == "running")] | length')
  local slots=$((MAX_CONCURRENT - running_count))

  log "Running agents: $running_count / $MAX_CONCURRENT (${slots} slots available)"
  echo ""

  # Collect all specs with scores
  local scored_specs=()
  local spec_details=""

  for proj in "${KNOWN_PROJECTS[@]}"; do
    if [ ! -d "$proj" ] || [ ! -d "$proj/specs/backlog" ]; then continue; fi

    local name
    name=$(basename "$proj")

    while IFS= read -r -d '' spec_file; do
      local spec_name
      spec_name=$(basename "$spec_file" .md)
      local potential_id
      potential_id=$(generate_task_id "$spec_name" "$name")

      # Skip if already in registry (any status)
      local existing
      existing=$(registry_get_task "$potential_id" 2>/dev/null || echo "")
      if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        continue
      fi

      # ── Score the spec ──
      local score=50  # base score
      local score_reasons=""

      # Read frontmatter (first 20 lines)
      local frontmatter
      frontmatter=$(head -20 "$spec_file")

      # Priority from frontmatter (|| true to prevent pipefail on no match)
      local priority
      priority=$(echo "$frontmatter" | grep -i "^priority:" | awk '{print $2}' | tr -d ' ' || true)
      case "$priority" in
        critical) score=$((score + 30)); score_reasons="priority:critical(+30)" ;;
        high)     score=$((score + 20)); score_reasons="priority:high(+20)" ;;
        medium)   score=$((score + 10)); score_reasons="priority:medium(+10)" ;;
        low)      score=$((score + 0));  score_reasons="priority:low(+0)" ;;
      esac

      # Lower spec number = higher priority
      local num
      num=$(echo "$spec_name" | grep -o '^[0-9]*' || true)
      # Strip leading zeros to avoid octal interpretation
      num=$(echo "$num" | sed 's/^0*//' || true)
      if [ -n "$num" ] && [ "$num" -gt 0 ]; then
        local num_bonus=$((100 - num))
        [ "$num_bonus" -lt 0 ] && num_bonus=0
        score=$((score + num_bonus))
        score_reasons="${score_reasons:+$score_reasons, }order:#${num}(+${num_bonus})"
      fi

      # Complexity from frontmatter (|| true to prevent pipefail on no match)
      local complexity
      complexity=$(echo "$frontmatter" | grep -i "^estimated_complexity:" | awk '{print $2}' | tr -d ' ' || true)
      case "$complexity" in
        small)  score=$((score + 10)); score_reasons="${score_reasons:+$score_reasons, }small(+10)" ;;
        medium) score=$((score + 5));  score_reasons="${score_reasons:+$score_reasons, }medium(+5)" ;;
        large)  score=$((score + 0));  score_reasons="${score_reasons:+$score_reasons, }large(+0)" ;;
      esac

      # Dependency check from frontmatter (|| true to prevent pipefail on no match)
      local deps
      deps=$(echo "$frontmatter" | grep -i "^depends_on:" | sed 's/depends_on: *\[//;s/\]//' | tr ',' '\n' | tr -d ' ' || true)
      local deps_satisfied=true
      if [ -n "$deps" ]; then
        for dep in $deps; do
          [ -z "$dep" ] && continue
          # Check if dependency spec is in "merged" status or not in registry
          local dep_status
          dep_status=$(registry_read | jq -r --arg d "$dep" \
            '[.[] | select(.id | contains($d))] | .[0].status // "not-found"')
          if [ "$dep_status" != "merged" ] && [ "$dep_status" != "not-found" ]; then
            deps_satisfied=false
            break
          fi
        done
      fi

      if [ "$deps_satisfied" = "true" ]; then
        score=$((score + 15))
        score_reasons="${score_reasons:+$score_reasons, }deps-ok(+15)"
      else
        score=$((score - 20))
        score_reasons="${score_reasons:+$score_reasons, }deps-blocked(-20)"
      fi

      # Store: score|project|spec_file|spec_name|reasons|deps_satisfied
      scored_specs+=("${score}|${name}|${spec_file}|${spec_name}|${score_reasons}|${deps_satisfied}")

    done < <(find "$proj/specs/backlog" -name "*.md" -print0 2>/dev/null | sort -z)
  done

  if [ ${#scored_specs[@]} -eq 0 ]; then
    log "No unstarted specs found in any project backlog."
    return 0
  fi

  # Sort by score (descending)
  local sorted_specs
  sorted_specs=$(printf '%s\n' "${scored_specs[@]}" | sort -t'|' -k1 -rn)

  # Display
  printf "${BOLD}%-6s %-30s %-15s %-8s %s${NC}\n" "SCORE" "SPEC" "PROJECT" "DEPS" "REASONS"
  printf "%-6s %-30s %-15s %-8s %s\n" "-----" "----" "-------" "----" "-------"

  local rank=0
  while IFS='|' read -r score proj_name spec_file spec_name reasons deps_ok; do
    rank=$((rank + 1))
    local deps_disp="ok"
    [ "$deps_ok" = "false" ] && deps_disp="${YELLOW}blocked${NC}"

    local score_color="$NC"
    [ "$score" -ge 150 ] && score_color="$GREEN"
    [ "$score" -lt 50 ] && score_color="$RED"

    # Mark top N that fit in available slots
    local slot_marker=""
    if [ "$rank" -le "$slots" ] && [ "$deps_ok" = "true" ]; then
      slot_marker="${GREEN}*${NC}"
    fi

    printf "${score_color}%-6s${NC} %-30s %-15s %-8b %s %b\n" \
      "$score" "$spec_name" "$proj_name" "$deps_disp" "$reasons" "$slot_marker"
  done <<< "$sorted_specs"

  echo ""
  log "Specs marked with ${GREEN}*${NC} fit in available slots ($slots)."
  log "Run ${BOLD}foundry auto${NC} to spawn them, or spawn individually:"
  log "  foundry spawn <repo> <spec> [model]"
}

cmd_auto() {
  log "Proactive scan: checking known projects for top-priority specs..."
  echo ""

  local running_count
  running_count=$(registry_read | jq '[.[] | select(.status == "running")] | length')
  local slots=$((MAX_CONCURRENT - running_count))

  if [ "$slots" -le 0 ]; then
    log_warn "All $MAX_CONCURRENT slots full. Wait for agents to finish."
    return 0
  fi

  log "Available slots: $slots"
  echo ""

  # Collect and score all specs, then spawn by priority
  local scored_specs=()

  for proj in "${KNOWN_PROJECTS[@]}"; do
    if [ ! -d "$proj" ] || [ ! -d "$proj/specs/backlog" ]; then continue; fi

    local name
    name=$(basename "$proj")

    while IFS= read -r -d '' spec_file; do
      local spec_name
      spec_name=$(basename "$spec_file" .md)
      local potential_id
      potential_id=$(generate_task_id "$spec_name" "$name")

      # Skip if already in registry (any status)
      local existing
      existing=$(registry_get_task "$potential_id" 2>/dev/null || echo "")
      if [ -n "$existing" ] && [ "$existing" != "null" ]; then
        continue
      fi

      # Score the spec (same logic as cmd_queue, || true for pipefail safety)
      local score=50
      local frontmatter
      frontmatter=$(head -20 "$spec_file")

      # Priority
      local priority
      priority=$(echo "$frontmatter" | grep -i "^priority:" | awk '{print $2}' | tr -d ' ' || true)
      case "$priority" in
        critical) score=$((score + 30)) ;;
        high)     score=$((score + 20)) ;;
        medium)   score=$((score + 10)) ;;
      esac

      # Spec number (strip leading zeros to avoid octal interpretation)
      local num
      num=$(echo "$spec_name" | grep -o '^[0-9]*' || true)
      num=$(echo "$num" | sed 's/^0*//' || true)
      if [ -n "$num" ] && [ "$num" -gt 0 ]; then
        local num_bonus=$((100 - num))
        [ "$num_bonus" -lt 0 ] && num_bonus=0
        score=$((score + num_bonus))
      fi

      # Complexity
      local complexity
      complexity=$(echo "$frontmatter" | grep -i "^estimated_complexity:" | awk '{print $2}' | tr -d ' ' || true)
      case "$complexity" in
        small) score=$((score + 10)) ;;
        medium) score=$((score + 5)) ;;
      esac

      # Dependency check
      local deps
      deps=$(echo "$frontmatter" | grep -i "^depends_on:" | sed 's/depends_on: *\[//;s/\]//' | tr ',' '\n' | tr -d ' ' || true)
      local deps_satisfied=true
      if [ -n "$deps" ]; then
        for dep in $deps; do
          [ -z "$dep" ] && continue
          local dep_status
          dep_status=$(registry_read | jq -r --arg d "$dep" \
            '[.[] | select(.id | contains($d))] | .[0].status // "not-found"')
          if [ "$dep_status" != "merged" ] && [ "$dep_status" != "not-found" ]; then
            deps_satisfied=false
            break
          fi
        done
      fi

      # Skip blocked specs
      [ "$deps_satisfied" = "false" ] && continue

      score=$((score + 15))  # deps-ok bonus

      scored_specs+=("${score}|${proj}|${spec_file}|${potential_id}")

    done < <(find "$proj/specs/backlog" -name "*.md" -print0 2>/dev/null | sort -z)
  done

  if [ ${#scored_specs[@]} -eq 0 ]; then
    log "No new specs to spawn."
    return 0
  fi

  # Sort by score (descending) and spawn top N
  local sorted_specs
  sorted_specs=$(printf '%s\n' "${scored_specs[@]}" | sort -t'|' -k1 -rn)

  local spawned=0
  while IFS='|' read -r score proj_path spec_file potential_id; do
    if [ "$spawned" -ge "$slots" ]; then break; fi

    log "Auto-spawning (score=$score): ${BOLD}${potential_id}${NC}"
    cmd_spawn "$proj_path" "$spec_file" || true
    spawned=$((spawned + 1))
  done <<< "$sorted_specs"

  if [ "$spawned" -eq 0 ]; then
    log "No new specs to spawn."
  else
    log_ok "Auto-spawned $spawned agent(s) (by priority score)."
  fi
}
