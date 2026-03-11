# commands/scan.bash — Find specs across known projects (file-based + GitHub Issues)

cmd_scan() {
  echo ""
  log "Scanning known projects for specs..."
  echo ""

  local found=0
  for proj in "${KNOWN_PROJECTS[@]}"; do
    if [ ! -d "$proj" ]; then continue; fi
    local name
    name=$(basename "$proj")

    # ── File-based specs (specs/backlog/*.md) ──────────────────────────────
    local specs=()
    if [ -d "$proj/specs/backlog" ]; then
      while IFS= read -r -d '' f; do
        specs+=("$f")
      done < <(find "$proj/specs/backlog" -name "*.md" -print0 2>/dev/null)
    fi

    if [ ${#specs[@]} -gt 0 ]; then
      printf "${BOLD}%-20s${NC} %d spec(s) in backlog:\n" "$name" "${#specs[@]}"
      for s in "${specs[@]}"; do
        printf "  -> %s\n" "$(basename "$s" .md)"
      done
      found=$((found + ${#specs[@]}))
    fi

    # ── GitHub Issues (when foundry.issues: true in AGENTS.md) ────────────
    if _foundry_issues_enabled "$proj"; then
      local gh_slug
      gh_slug=$(_get_gh_repo_slug "$proj" 2>/dev/null) || {
        log_warn "$name: foundry.issues enabled but cannot determine GitHub remote — skipping"
        continue
      }

      local issues
      issues=$(gh issue list -R "$gh_slug" \
        --state open --label foundry \
        --json number,title \
        --limit 50 2>/dev/null) || {
        log_warn "$name: gh issue list failed for $gh_slug — skipping"
        continue
      }

      local issue_count
      issue_count=$(echo "$issues" | jq 'length' 2>/dev/null || echo 0)

      if [ "$issue_count" -gt 0 ]; then
        printf "${BOLD}%-20s${NC} %d GitHub Issue(s) with 'foundry' label:\n" "$name" "$issue_count"
        while IFS= read -r line; do
          local num title task_id existing
          num=$(echo "$line"   | jq -r '.number')
          title=$(echo "$line" | jq -r '.title')
          local _slug
          _slug=$(echo "$title" | head -c 40)
          _slug=$(sanitize "$_slug")
          task_id="${name}-${num}-${_slug}"

          # Dedup: skip if a Foundry task already exists for this issue (check both ID formats)
          existing=$(registry_get_task "$task_id" 2>/dev/null || echo "")
          if [ -z "$existing" ] || [ "$existing" = "null" ]; then
            # Fallback: check legacy issue-N format
            existing=$(registry_get_task "${name}-issue-${num}" 2>/dev/null || echo "")
          fi
          if [ -n "$existing" ] && [ "$existing" != "null" ]; then
            local sts
            sts=$(echo "$existing" | jq -r '.status // "unknown"')
            printf "  -> [%-8s] issue-%s: %s\n" "$sts" "$num" "$title"
          else
            printf "  -> [new     ] issue-%s: %s\n" "$num" "$title"
            found=$((found + 1))
          fi
        done < <(echo "$issues" | jq -c '.[]')
      fi
    fi
  done

  echo ""
  if [ "$found" -eq 0 ]; then
    log "No specs found in any project backlog."
  else
    log "$found total spec(s) ready to build."
  fi
}
