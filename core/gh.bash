# core/gh.bash — GitHub CLI retry wrapper + repo helpers
[ "${_CORE_GH_LOADED:-}" = "1" ] && return 0
_CORE_GH_LOADED=1

# Extract "owner/repo" slug from a local git repo's origin remote.
# Handles both HTTPS (https://github.com/owner/repo.git)
# and SSH (git@github.com:owner/repo.git) remotes.
_get_gh_repo_slug() {
  local proj="$1"
  local remote
  remote=$(git -C "$proj" remote get-url origin 2>/dev/null) || return 1
  echo "$remote" | sed 's|\.git$||' | sed 's|.*github\.com[:/]||'
}

# Return 0 (true) when a repo has opted in to GitHub Issues as a spec source.
# Looks for a line "foundry.issues: true" in the repo's AGENTS.md.
_foundry_issues_enabled() {
  local proj="$1"
  [ -f "$proj/AGENTS.md" ] && grep -q "^foundry\.issues: true" "$proj/AGENTS.md" 2>/dev/null
}

gh_retry() {
  # Retry gh commands up to 3 times with backoff. Captures stdout cleanly.
  # Bails immediately on fatal errors (PR not found, no checks) — no point retrying.
  local max=3 delay=2 out tmperr="/tmp/.gh_retry_err.$$"
  for ((i=1; i<=max; i++)); do
    out=$("$@" 2>"$tmperr") && { rm -f "$tmperr"; echo "$out"; return 0; }
    # Fatal errors: don't retry, just fail fast
    if grep -qiE "Could not resolve|no checks reported|not found|does not exist|404" "$tmperr" 2>/dev/null; then
      rm -f "$tmperr"
      return 1
    fi
    [ "$i" -lt "$max" ] && sleep "$delay" && delay=$((delay * 2))
  done
  rm -f "$tmperr"
  return 1
}
