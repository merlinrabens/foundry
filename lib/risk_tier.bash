#!/bin/bash
# lib/risk_tier.bash — Risk classification for PR changed files
[[ -n "${_LIB_RISK_TIER_LOADED:-}" ]] && return 0
_LIB_RISK_TIER_LOADED=1

# classify_risk_tier <changed_files_newline_separated>
# Examines file paths to determine risk level.
# Echoes: "LOW", "MEDIUM", or "HIGH"
#
# HIGH: auth, security, payments, migrations, env files, credentials, secrets
# LOW:  docs (md), tests, CSS/SCSS, images (svg/png/jpg/gif), README, CHANGELOG, LICENSE
# MEDIUM: everything else (application code)
classify_risk_tier() {
  local files="$1"
  local risk="LOW"

  [ -z "$files" ] && { echo "LOW"; return 0; }

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    # HIGH risk: auth, security, payments, migrations, env, secrets, credentials
    if echo "$f" | grep -qiE '(migration|auth|security|payment|\.env|secret|credential|\.pem|\.key)'; then
      echo "HIGH"
      return 0
    fi
    # Check if NOT low-risk → upgrade to MEDIUM
    if ! echo "$f" | grep -qiE '\.(md|test\.[jt]sx?|spec\.[jt]sx?|css|scss|less|svg|png|jpg|gif)$|^(README|CHANGELOG|LICENSE|docs/|test/|tests/|__tests__/)'; then
      risk="MEDIUM"
    fi
  done <<< "$files"

  echo "$risk"
}

# can_auto_merge <claude_review> <codex_review> <gemini_review> <risk_tier> <auto_merge_enabled>
# Determines if a PR can be auto-merged based on reviews and risk.
# Returns 0 (can merge) or 1 (cannot).
#
# Requirements for auto-merge:
# 1. AUTO_MERGE_LOW_RISK must be "true"
# 2. Risk tier must be "LOW"
# 3. ALL three reviews must be approved (APPROVED or AUTO_PASSED)
can_auto_merge() {
  local claude_review="$1"
  local codex_review="$2"
  local gemini_review="$3"
  local risk_tier="$4"
  local auto_merge_enabled="${5:-$AUTO_MERGE_LOW_RISK}"

  # Gate: auto-merge must be enabled
  [ "$auto_merge_enabled" != "true" ] && return 1

  # Gate: only LOW risk
  [ "$risk_tier" != "LOW" ] && return 1

  # Gate: all 3 reviews must pass
  local passed=0
  for review in "$claude_review" "$codex_review" "$gemini_review"; do
    case "$review" in
      APPROVED|AUTO_PASSED) passed=$((passed + 1)) ;;
    esac
  done

  [ "$passed" -ge 3 ]
}
