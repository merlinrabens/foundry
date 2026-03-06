#!/bin/bash
# lib/video_evidence.bash — Screenshot/video evidence detection for PRs
[[ -n "${_LIB_VIDEO_EVIDENCE_LOADED:-}" ]] && return 0
_LIB_VIDEO_EVIDENCE_LOADED=1

# has_frontend_changes <changed_files_newline_separated>
# Returns 0 (has frontend changes) if any files are frontend-related.
# Returns 1 (no frontend changes) otherwise.
#
# Frontend file patterns: .tsx, .jsx, .vue, .svelte, .css, .scss, .html,
# or paths under frontend/src/, components/, pages/, app/
has_frontend_changes() {
  local files="$1"
  [ -z "$files" ] && return 1
  echo "$files" | grep -qiE '\.(tsx|jsx|vue|svelte|css|scss|html)$|frontend/src/|/components/|/pages/|/app/'
}

# check_screenshots_in_pr <pr_body>
# Returns 0 (screenshots found) if the PR body contains image/video evidence.
# Returns 1 (missing) otherwise.
#
# Checks for:
# - Markdown images: ![alt](url.png)
# - HTML img tags: <img src=...>
# - HTML video tags: <video ...>
# - Direct image/video URLs: https://...png/jpg/gif/webp/mp4
check_screenshots_in_pr() {
  local body="$1"
  [ -z "$body" ] && return 1
  echo "$body" | grep -qiE '!\[.*\]\(.*\.(png|jpg|gif|webp|mp4)|<img |<video |https://[^ ]*\.(png|jpg|gif|webp|mp4)'
}

# get_screenshot_status <changed_files> <pr_body>
# Convenience function combining frontend detection + screenshot check.
# Echoes: "true" (screenshots found), "false" (missing), "null" (not applicable)
get_screenshot_status() {
  local changed_files="$1" pr_body="$2"

  if ! has_frontend_changes "$changed_files"; then
    echo "null"
    return 0
  fi

  if check_screenshots_in_pr "$pr_body"; then
    echo "true"
  else
    echo "false"
  fi
}
