#!/bin/bash
# lib/spawn_guards.bash — Pre-spawn validation guards
[[ -n "${_LIB_SPAWN_GUARDS_LOADED:-}" ]] && return 0
_LIB_SPAWN_GUARDS_LOADED=1

# check_concurrent_limit <running_count> <max_concurrent>
# Returns 0 (ok to spawn) if under the limit.
# Returns 1 (limit reached) otherwise.
check_concurrent_limit() {
  local running="$1" max="$2"
  [ "$running" -lt "$max" ]
}

# detect_parallel_conflict <repo_path> <registry_json>
# Checks if any running agents are working on the same repo.
# Echoes: list of conflicting task IDs (one per line), empty if no conflicts.
#
# Arguments:
#   repo_path     — absolute path to the repo being spawned into
#   registry_json — contents of active-tasks.json
detect_parallel_conflict() {
  local repo_path="$1" registry_json="$2"
  echo "$registry_json" | jq -r --arg rp "$repo_path" \
    '.[] | select(.status == "running" and .repoPath == $rp) | .id' 2>/dev/null || echo ""
}

# parse_spawn_flags <args...>
# Parses --prompt-file flag from spawn/respawn arguments.
# Sets in caller's scope:
#   PROMPT_FILE_OVERRIDE — path to custom prompt file (empty if not provided)
#   POSITIONAL_ARGS      — array of remaining positional arguments
parse_spawn_flags() {
  PROMPT_FILE_OVERRIDE=""
  POSITIONAL_ARGS=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt-file)
        PROMPT_FILE_OVERRIDE="$2"
        shift 2
        ;;
      --prompt-file=*)
        PROMPT_FILE_OVERRIDE="${1#*=}"
        shift
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}
