#!/bin/bash
# lib/preflight_recon.bash — Pre-spawn reconnaissance (planning stage)
# Scans repo for relevant context and enriches the spec before agent spawn.
# Zero AI tokens — pure grep/find/jq heuristics.
[[ -n "${_LIB_PREFLIGHT_RECON_LOADED:-}" ]] && return 0
_LIB_PREFLIGHT_RECON_LOADED=1

# _recon_scan <repo_dir> <task_content>
# Writes implementation hints to stdout. Caller appends to spec.
_recon_scan() {
  local repo_dir="$1"
  local task_content="$2"
  local hints=""

  # ── 1. Detect tech stack ──────────────────────────────────────────────
  local stack=""
  [ -f "$repo_dir/package.json" ] && {
    local deps
    deps=$(cat "$repo_dir/package.json" 2>/dev/null)
    echo "$deps" | grep -q '"next"' && stack="${stack}Next.js, "
    echo "$deps" | grep -q '"react"' && stack="${stack}React, "
    echo "$deps" | grep -q '"@supabase' && stack="${stack}Supabase, "
    echo "$deps" | grep -q '"tailwindcss\|"@tailwindcss' && stack="${stack}Tailwind, "
    echo "$deps" | grep -q '"prisma\|"@prisma' && stack="${stack}Prisma, "
    echo "$deps" | grep -q '"shopify\|"@shopify' && stack="${stack}Shopify, "
    echo "$deps" | grep -q '"playwright' && stack="${stack}Playwright, "
    echo "$deps" | grep -q '"vitest\|"jest' && stack="${stack}Vitest/Jest, "
    # Package manager
    [ -f "$repo_dir/pnpm-lock.yaml" ] && stack="${stack}pnpm, "
    [ -f "$repo_dir/bun.lockb" ] && stack="${stack}bun, "
    [ -f "$repo_dir/yarn.lock" ] && stack="${stack}yarn, "
  }
  [ -f "$repo_dir/requirements.txt" ] || [ -f "$repo_dir/pyproject.toml" ] && stack="${stack}Python, "
  stack="${stack%, }"  # trim trailing comma
  [ -n "$stack" ] && hints="${hints}Tech stack: ${stack}\n"

  # ── 2. Extract keywords from task and find relevant files ─────────────
  # Pull meaningful words (>4 chars, no common words)
  local keywords
  keywords=$(echo "$task_content" | tr '[:upper:]' '[:lower:]' | \
    grep -oE '[a-z]{4,}' | \
    grep -vE '^(that|this|with|from|have|will|should|would|could|when|what|about|into|also|been|each|make|like|just|over|such|after|before|between|through|during|without|within|build|create|implement|feature|update|change|please|need|want|must|spec|criterion|acceptance)$' | \
    sort -u | head -15)

  # Build list of source dirs that actually exist
  local src_dirs=()
  for d in src app pages components lib utils hooks api frontend backend; do
    [ -d "$repo_dir/$d" ] && src_dirs+=("$repo_dir/$d")
  done

  local relevant_files=""
  if [ -n "$keywords" ] && [ ${#src_dirs[@]} -gt 0 ]; then
    for kw in $keywords; do
      # Search filenames
      local found
      found=$(find "${src_dirs[@]}" \
        -maxdepth 4 -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" \) \
        -not -path "*/node_modules/*" -not -path "*/.next/*" \
        -iname "*${kw}*" 2>/dev/null | head -5)
      [ -n "$found" ] && relevant_files="${relevant_files}${found}\n"

      # Search file content (just filenames, limit results)
      found=$(grep -rl --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.py" \
        --exclude-dir=node_modules --exclude-dir=.next \
        -i "$kw" "${src_dirs[@]}" 2>/dev/null | head -3)
      [ -n "$found" ] && relevant_files="${relevant_files}${found}\n"
    done
  fi

  # Deduplicate and format as relative paths
  if [ -n "$relevant_files" ]; then
    local unique_files
    unique_files=$(echo -e "$relevant_files" | sort -u | head -20 | \
      sed "s|${repo_dir}/||g" | grep -v '^$')
    if [ -n "$unique_files" ]; then
      hints="${hints}\nRelevant files (likely need changes or serve as patterns):\n"
      while IFS= read -r f; do
        hints="${hints}  - ${f}\n"
      done <<< "$unique_files"
    fi
  fi

  # ── 3. Find similar existing features as reference ────────────────────
  # Look for route/page patterns if task mentions a page/dashboard/view
  if echo "$task_content" | grep -qiE 'page|dashboard|tab|view|panel|section|screen'; then
    local pages
    pages=$(find "$repo_dir/app" "$repo_dir/pages" "$repo_dir/src/app" "$repo_dir/frontend/app" \
      -maxdepth 3 \( -name "page.tsx" -o -name "page.js" -o -name "index.tsx" \) \
      -not -path "*/node_modules/*" 2>/dev/null | \
      sed "s|${repo_dir}/||g" | head -10)
    if [ -n "$pages" ]; then
      hints="${hints}\nExisting pages/routes (use as structural reference):\n"
      while IFS= read -r p; do
        hints="${hints}  - ${p}\n"
      done <<< "$pages"
    fi
  fi

  # Look for API routes if task mentions API/endpoint
  if echo "$task_content" | grep -qiE 'api|endpoint|route|handler|webhook'; then
    local routes
    routes=$(find "$repo_dir/app/api" "$repo_dir/pages/api" "$repo_dir/src/api" "$repo_dir/frontend/app/api" \
      -maxdepth 3 -type f \( -name "*.ts" -o -name "*.js" \) \
      -not -path "*/node_modules/*" 2>/dev/null | \
      sed "s|${repo_dir}/||g" | head -10)
    if [ -n "$routes" ]; then
      hints="${hints}\nExisting API routes (follow same patterns):\n"
      while IFS= read -r r; do
        hints="${hints}  - ${r}\n"
      done <<< "$routes"
    fi
  fi

  # ── 4. Check for project-specific agent instructions ──────────────────
  local agent_instructions=""
  for f in AGENTS.md CLAUDE.md .claude/settings.json; do
    [ -f "$repo_dir/$f" ] && agent_instructions="${agent_instructions}${f}, "
  done
  agent_instructions="${agent_instructions%, }"
  [ -n "$agent_instructions" ] && hints="${hints}\nAgent config files: ${agent_instructions}\n"

  # ── 5. Check for existing tests pattern ───────────────────────────────
  local test_dirs
  test_dirs=$(find "$repo_dir" -maxdepth 3 -type d \( -name "tests" -o -name "__tests__" -o -name "test" -o -name "e2e" \) \
    -not -path "*/node_modules/*" -not -path "*/.next/*" 2>/dev/null | \
    sed "s|${repo_dir}/||g" | head -5)
  if [ -n "$test_dirs" ]; then
    hints="${hints}\nTest directories (add tests here):\n"
    while IFS= read -r t; do
      hints="${hints}  - ${t}\n"
    done <<< "$test_dirs"
  fi

  # ── 6. Detect DB/schema if task touches data ──────────────────────────
  if echo "$task_content" | grep -qiE 'database|schema|table|model|migration|supabase|prisma|store|persist'; then
    local schema_files
    schema_files=$(find "$repo_dir" -maxdepth 4 -type f \
      \( -name "schema.prisma" -o -name "schema.ts" -o -name "schema.sql" -o -name "*.migration.*" \) \
      -not -path "*/node_modules/*" 2>/dev/null | \
      sed "s|${repo_dir}/||g" | head -5)
    if [ -n "$schema_files" ]; then
      hints="${hints}\nSchema/migration files:\n"
      while IFS= read -r s; do
        hints="${hints}  - ${s}\n"
      done <<< "$schema_files"
    fi
  fi

  echo -e "$hints"
}

# enrich_spec_with_recon <repo_dir> <spec_file>
# Appends recon hints to spec file (in-place). Idempotent (skips if already enriched).
enrich_spec_with_recon() {
  local repo_dir="$1"
  local spec_file="$2"

  # Skip if already enriched
  grep -q "## Implementation Hints (auto-generated)" "$spec_file" 2>/dev/null && return 0

  local task_content
  task_content=$(cat "$spec_file")

  local hints
  hints=$(_recon_scan "$repo_dir" "$task_content")

  if [ -n "$hints" ] && [ "$(echo "$hints" | tr -d '[:space:]')" != "" ]; then
    printf '\n\n## Implementation Hints (auto-generated)\n\n%b\n' "$hints" >> "$spec_file"
    log "Recon: enriched spec with implementation hints"
  fi
}
