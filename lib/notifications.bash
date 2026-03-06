#!/bin/bash
# lib/notifications.bash — Notification dedup logic
[[ -n "${_LIB_NOTIFICATIONS_LOADED:-}" ]] && return 0
_LIB_NOTIFICATIONS_LOADED=1

# should_notify <current_state> <last_notified_state>
# Returns 0 (should notify) if state changed since last notification.
# Returns 1 (skip) if already notified about this state.
#
# The foundry uses "claim then send" pattern: write lastNotifiedState BEFORE
# sending to prevent race conditions in concurrent cron cycles.
should_notify() {
  local current="$1" last="$2"
  [ "$current" != "$last" ]
}

# build_checks_summary <ci_passed> <claude_approved> <codex_approved> <gemini_approved>
# Builds the CRKG status string shown in notifications.
# C = CI passed, R = Claude approved, K = Codex (codeK) approved, G = Gemini approved
# Echoes: string like "CRKG" or "C" etc.
build_checks_summary() {
  local ci_passed="$1"
  local claude_approved="$2"
  local codex_approved="$3"
  local gemini_approved="$4"

  local summary=""
  [ "$ci_passed" = "true" ] || [ "$ci_passed" = "1" ] && summary="${summary}C"
  [ "$claude_approved" = "true" ] || [ "$claude_approved" = "1" ] && summary="${summary}R"
  [ "$codex_approved" = "true" ] || [ "$codex_approved" = "1" ] && summary="${summary}K"
  [ "$gemini_approved" = "true" ] || [ "$gemini_approved" = "1" ] && summary="${summary}G"
  echo "$summary"
}
