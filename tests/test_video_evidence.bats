#!/usr/bin/env bats

setup() {
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/video_evidence.bash"
}

# ─── has_frontend_changes ─────────────────────────────────────────────

@test "has_frontend_changes: .tsx file returns 0" {
  run has_frontend_changes "src/App.tsx"
  [ "$status" -eq 0 ]
}

@test "has_frontend_changes: .css file returns 0" {
  run has_frontend_changes "styles/main.css"
  [ "$status" -eq 0 ]
}

@test "has_frontend_changes: .py file only returns 1" {
  run has_frontend_changes "server/app.py"
  [ "$status" -eq 1 ]
}

@test "has_frontend_changes: empty returns 1" {
  run has_frontend_changes ""
  [ "$status" -eq 1 ]
}

@test "has_frontend_changes: components/ path returns 0" {
  run has_frontend_changes "src/components/Button.ts"
  [ "$status" -eq 0 ]
}

# ─── check_screenshots_in_pr ─────────────────────────────────────────

@test "check_screenshots_in_pr: markdown image returns 0" {
  run check_screenshots_in_pr "Here is a screenshot: ![demo](https://example.com/img.png)"
  [ "$status" -eq 0 ]
}

@test "check_screenshots_in_pr: HTML img tag returns 0" {
  run check_screenshots_in_pr "Evidence: <img src=\"https://example.com/shot.jpg\">"
  [ "$status" -eq 0 ]
}

@test "check_screenshots_in_pr: no screenshots returns 1" {
  run check_screenshots_in_pr "This PR fixes the login bug. No visual changes."
  [ "$status" -eq 1 ]
}

@test "check_screenshots_in_pr: empty returns 1" {
  run check_screenshots_in_pr ""
  [ "$status" -eq 1 ]
}

# ─── get_screenshot_status ────────────────────────────────────────────

@test "get_screenshot_status: frontend + screenshots gives true" {
  run get_screenshot_status "src/App.tsx" "![demo](https://example.com/img.png)"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "get_screenshot_status: frontend + no screenshots gives false" {
  run get_screenshot_status "src/App.tsx" "Fixed the component layout."
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "get_screenshot_status: no frontend gives null" {
  run get_screenshot_status "server/app.py" "![demo](https://example.com/img.png)"
  [ "$status" -eq 0 ]
  [ "$output" = "null" ]
}
