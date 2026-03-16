#!/bin/bash
# lib/state_machine.bash — Agent lifecycle state transitions
[[ -n "${_LIB_STATE_MACHINE_LOADED:-}" ]] && return 0
_LIB_STATE_MACHINE_LOADED=1

# determine_next_status <current> <agent_done> <exit_code> <has_pr> <attempts> <max_attempts> <elapsed> <timeout> <agent_alive> [<ci_passed> <reviews_approved> <changes_requested> <pr_state>]
# Echoes the next status string based on current state + conditions.
# Pure function — no side effects.
#
# States: running, pr-open, done-no-pr, needs-respawn, exhausted, crashed,
#         timeout, merged, closed, ci-failed, review-failed, deploy-failed, ready
determine_next_status() {
  local current="$1"
  local agent_done="$2"      # "true" or "false"
  local exit_code="$3"       # integer
  local has_pr="$4"          # "true" or "false"
  local attempts="$5"        # integer
  local max_attempts="$6"    # integer
  local elapsed="$7"         # seconds
  local timeout="$8"         # seconds
  local agent_alive="$9"     # "true" or "false"
  local ci_passed="${10:-}"   # "true", "false", or "" (unknown)
  local reviews_approved="${11:-}"  # "true" or "false"
  local changes_requested="${12:-}" # "true" or "false"
  local pr_state="${13:-}"    # "MERGED", "CLOSED", "OPEN", or ""

  # Terminal states: merged, closed, exhausted — no transitions out
  case "$current" in
    merged|closed|exhausted)
      echo "$current"
      return 0
      ;;
  esac

  # agent-done: agent exited, exit code in registry, no evaluation yet.
  # Transition to final state based on exit code and PR discovery.
  if [ "$current" = "agent-done" ]; then
    if [ "$exit_code" = "0" ] || [ "$exit_code" = "2" ]; then
      # exit 0 = success, exit 2 = preflight failure (still has code changes)
      if [ "$has_pr" = "true" ]; then
        echo "pr-open"
      else
        echo "done-no-pr"
      fi
    elif [ "$exit_code" = "99" ]; then
      # Usage/rate limit — never respawn
      echo "exhausted"
    else
      # Non-zero exit (crash, error, refusal)
      if [ "$attempts" -lt "$max_attempts" ]; then
        echo "needs-respawn"
      else
        echo "exhausted"
      fi
    fi
    return 0
  fi

  # PR-open path (deploy-failed re-evaluates here too — may self-heal)
  if [ "$current" = "pr-open" ] || [ "$current" = "ready" ] || [ "$current" = "deploy-failed" ]; then
    [ "$pr_state" = "MERGED" ] && { echo "merged"; return 0; }
    [ "$pr_state" = "CLOSED" ] && { echo "closed"; return 0; }
    if [ "$ci_passed" = "false" ]; then
      if [ "$attempts" -lt "$max_attempts" ]; then
        echo "ci-failed"
      else
        echo "exhausted"
      fi
      return 0
    fi
    if [ "$changes_requested" = "true" ]; then
      if [ "$attempts" -lt "$max_attempts" ]; then
        echo "review-failed"
      else
        echo "exhausted"
      fi
      return 0
    fi
    if [ "$ci_passed" = "true" ] && [ "$reviews_approved" = "true" ]; then
      echo "ready"
      return 0
    fi
    echo "$current"
    return 0
  fi

  # Running path
  if [ "$current" = "running" ]; then
    # Agent finished (done file exists)
    if [ "$agent_done" = "true" ]; then
      if [ "$exit_code" = "0" ]; then
        if [ "$has_pr" = "true" ]; then
          echo "pr-open"
        else
          echo "done-no-pr"
        fi
      else
        # Non-zero exit
        if [ "$attempts" -lt "$max_attempts" ]; then
          echo "needs-respawn"
        else
          echo "exhausted"
        fi
      fi
      return 0
    fi

    # Agent died
    if [ "$agent_alive" = "false" ]; then
      if [ "$attempts" -lt "$max_attempts" ]; then
        echo "crashed"
      else
        echo "exhausted"
      fi
      return 0
    fi

    # Timeout
    if [ "$elapsed" -gt "$timeout" ]; then
      if [ "$attempts" -lt "$max_attempts" ]; then
        echo "timeout"
      else
        echo "exhausted"
      fi
      return 0
    fi

    # Still running
    echo "running"
    return 0
  fi

  # For other states (needs-respawn, crashed, timeout, ci-failed, review-failed, etc.)
  # These are transient — they get picked up by auto-respawn logic
  echo "$current"
  return 0
}

# is_stale <elapsed_seconds> <threshold_seconds> <has_pr>
# Returns 0 (stale) if agent has been running longer than threshold without a PR.
# Returns 1 (not stale) otherwise.
is_stale() {
  local elapsed="$1" threshold="$2" has_pr="$3"
  [ "$elapsed" -gt "$threshold" ] && [ "$has_pr" != "true" ]
}

# is_idle <elapsed_seconds> <threshold_seconds> <changes_count>
# Returns 0 (idle) if agent has been running longer than threshold with zero code changes.
# Returns 1 (not idle) otherwise.
is_idle() {
  local elapsed="$1" threshold="$2" changes="$3"
  [ "$elapsed" -gt "$threshold" ] && [ "$changes" -eq 0 ] 2>/dev/null
}
