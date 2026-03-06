#!/usr/bin/env bats
# Tests for lib/risk_tier.bash — Risk classification for PR changed files

setup() {
  unset _LIB_RISK_TIER_LOADED
  source "$(dirname "$BATS_TEST_FILENAME")/../lib/risk_tier.bash"
  export AUTO_MERGE_LOW_RISK="false"
}

# ── classify_risk_tier: LOW ──

@test "classify_risk_tier: only .md files → LOW" {
  run classify_risk_tier "docs/guide.md
README.md"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "classify_risk_tier: only test files → LOW" {
  run classify_risk_tier "src/utils.test.ts
src/api.spec.js"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "classify_risk_tier: only .css/.scss files → LOW" {
  run classify_risk_tier "styles/main.css
theme/dark.scss"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "classify_risk_tier: only images (.svg, .png) → LOW" {
  run classify_risk_tier "assets/logo.svg
images/hero.png"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "classify_risk_tier: README, CHANGELOG, LICENSE → LOW" {
  run classify_risk_tier "README
CHANGELOG
LICENSE"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

@test "classify_risk_tier: docs/ directory → LOW" {
  run classify_risk_tier "docs/api-reference.md
docs/setup-guide.md"
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

# ── classify_risk_tier: HIGH ──

@test "classify_risk_tier: auth file → HIGH" {
  run classify_risk_tier "src/auth/login.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "classify_risk_tier: migration file → HIGH" {
  run classify_risk_tier "db/migrations/001_create_users.sql"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "classify_risk_tier: .env file → HIGH" {
  run classify_risk_tier ".env.production"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "classify_risk_tier: payment module → HIGH" {
  run classify_risk_tier "src/payment/stripe.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

# ── classify_risk_tier: MEDIUM ──

@test "classify_risk_tier: regular .ts/.js files → MEDIUM" {
  run classify_risk_tier "src/utils.ts
src/index.js"
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

@test "classify_risk_tier: mixed docs + source → MEDIUM" {
  run classify_risk_tier "README.md
src/app.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "MEDIUM" ]
}

# ── classify_risk_tier: empty ──

@test "classify_risk_tier: empty input → LOW" {
  run classify_risk_tier ""
  [ "$status" -eq 0 ]
  [ "$output" = "LOW" ]
}

# ── can_auto_merge ──

@test "can_auto_merge: all approved + LOW + enabled → 0 (can merge)" {
  run can_auto_merge "APPROVED" "APPROVED" "AUTO_PASSED" "LOW" "true"
  [ "$status" -eq 0 ]
}

@test "can_auto_merge: disabled → 1 (cannot)" {
  run can_auto_merge "APPROVED" "APPROVED" "AUTO_PASSED" "LOW" "false"
  [ "$status" -eq 1 ]
}

@test "can_auto_merge: MEDIUM risk → 1 (cannot)" {
  run can_auto_merge "APPROVED" "APPROVED" "AUTO_PASSED" "MEDIUM" "true"
  [ "$status" -eq 1 ]
}

@test "can_auto_merge: one reviewer not approved → 1 (cannot)" {
  run can_auto_merge "APPROVED" "CHANGES_REQUESTED" "AUTO_PASSED" "LOW" "true"
  [ "$status" -eq 1 ]
}

@test "can_auto_merge: HIGH risk even with all approved → 1 (cannot)" {
  run can_auto_merge "APPROVED" "APPROVED" "AUTO_PASSED" "HIGH" "true"
  [ "$status" -eq 1 ]
}

@test "can_auto_merge: all AUTO_PASSED + LOW + enabled → 0 (can merge)" {
  run can_auto_merge "APPROVED" "APPROVED" "APPROVED" "LOW" "true"
  [ "$status" -eq 0 ]
}

@test "can_auto_merge: only 2 of 3 approved → 1 (cannot)" {
  run can_auto_merge "APPROVED" "APPROVED" "" "LOW" "true"
  [ "$status" -eq 1 ]
}
