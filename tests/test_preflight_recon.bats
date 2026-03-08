#!/usr/bin/env bats
# Tests for lib/preflight_recon.bash — pre-spawn reconnaissance

setup() {
  source "$BATS_TEST_DIRNAME/../core/logging.bash"
  source "$BATS_TEST_DIRNAME/../lib/preflight_recon.bash"
  TEST_REPO=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_REPO"
}

@test "recon detects Next.js + React + Tailwind from package.json" {
  cat > "$TEST_REPO/package.json" << 'JSON'
{"dependencies":{"next":"14.0","react":"18.0","tailwindcss":"3.0"}}
JSON
  mkdir -p "$TEST_REPO/src"
  local output
  output=$(_recon_scan "$TEST_REPO" "Add a dashboard")
  [[ "$output" == *"Next.js"* ]]
  [[ "$output" == *"React"* ]]
  [[ "$output" == *"Tailwind"* ]]
}

@test "recon detects pnpm from lockfile" {
  echo '{}' > "$TEST_REPO/package.json"
  touch "$TEST_REPO/pnpm-lock.yaml"
  mkdir -p "$TEST_REPO/src"
  local output
  output=$(_recon_scan "$TEST_REPO" "Fix something")
  [[ "$output" == *"pnpm"* ]]
}

@test "recon finds relevant files by keyword" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/src/components"
  touch "$TEST_REPO/src/components/Header.tsx"
  touch "$TEST_REPO/src/components/Footer.tsx"
  local output
  output=$(_recon_scan "$TEST_REPO" "Fix the header layout")
  [[ "$output" == *"Header.tsx"* ]]
}

@test "recon excludes node_modules" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/src"
  mkdir -p "$TEST_REPO/node_modules/somepkg/src"
  touch "$TEST_REPO/node_modules/somepkg/src/header.ts"
  touch "$TEST_REPO/src/header.ts"
  local output
  output=$(_recon_scan "$TEST_REPO" "Fix header")
  [[ "$output" != *"node_modules"* ]]
}

@test "recon finds existing pages when task mentions dashboard" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/app/dashboard"
  touch "$TEST_REPO/app/dashboard/page.tsx"
  mkdir -p "$TEST_REPO/app/settings"
  touch "$TEST_REPO/app/settings/page.tsx"
  local output
  output=$(_recon_scan "$TEST_REPO" "Add a new dashboard view")
  [[ "$output" == *"Existing pages"* ]]
  [[ "$output" == *"dashboard/page.tsx"* ]]
}

@test "recon finds API routes when task mentions endpoint" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/app/api/webhook"
  touch "$TEST_REPO/app/api/webhook/route.ts"
  local output
  output=$(_recon_scan "$TEST_REPO" "Add a webhook API endpoint")
  [[ "$output" == *"Existing API routes"* ]]
  [[ "$output" == *"webhook/route.ts"* ]]
}

@test "recon detects AGENTS.md and CLAUDE.md" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/src"
  touch "$TEST_REPO/AGENTS.md"
  touch "$TEST_REPO/CLAUDE.md"
  local output
  output=$(_recon_scan "$TEST_REPO" "Do something")
  [[ "$output" == *"AGENTS.md"* ]]
  [[ "$output" == *"CLAUDE.md"* ]]
}

@test "recon finds test directories" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/src"
  mkdir -p "$TEST_REPO/__tests__"
  mkdir -p "$TEST_REPO/e2e"
  local output
  output=$(_recon_scan "$TEST_REPO" "Add a feature")
  [[ "$output" == *"Test directories"* ]]
  [[ "$output" == *"__tests__"* ]]
}

@test "recon finds schema files when task mentions database" {
  echo '{"dependencies":{"@prisma/client":"5.0"}}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/prisma"
  touch "$TEST_REPO/prisma/schema.prisma"
  mkdir -p "$TEST_REPO/src"
  local output
  output=$(_recon_scan "$TEST_REPO" "Store data in the database")
  [[ "$output" == *"Schema/migration"* ]]
  [[ "$output" == *"schema.prisma"* ]]
}

@test "enrich_spec_with_recon is idempotent" {
  echo '{}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/src"
  touch "$TEST_REPO/AGENTS.md"
  local spec
  spec=$(mktemp)
  echo "# Test task" > "$spec"
  enrich_spec_with_recon "$TEST_REPO" "$spec"
  local first_size
  first_size=$(wc -c < "$spec")
  # Run again — should not append
  enrich_spec_with_recon "$TEST_REPO" "$spec"
  local second_size
  second_size=$(wc -c < "$spec")
  [ "$first_size" -eq "$second_size" ]
  rm -f "$spec"
}

@test "enrich_spec appends Implementation Hints section" {
  echo '{"dependencies":{"next":"14.0"}}' > "$TEST_REPO/package.json"
  mkdir -p "$TEST_REPO/src"
  local spec
  spec=$(mktemp)
  echo "# Build a feature" > "$spec"
  enrich_spec_with_recon "$TEST_REPO" "$spec"
  grep -q "## Implementation Hints (auto-generated)" "$spec"
  rm -f "$spec"
}
