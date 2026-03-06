#!/usr/bin/env bats
# Tests for pure functions: sanitize, generate_task_id, detect_pkg_manager

load test_helper

# ============================================================================
# sanitize()
# ============================================================================

@test "sanitize: lowercase conversion" {
  result=$(sanitize "MyProject")
  [ "$result" = "myproject" ]
}

@test "sanitize: spaces to hyphens" {
  result=$(sanitize "my cool project")
  [ "$result" = "my-cool-project" ]
}

@test "sanitize: special chars to hyphens" {
  result=$(sanitize "feat/add_auth@v2")
  [ "$result" = "feat-add-auth-v2" ]
}

@test "sanitize: collapses multiple hyphens" {
  result=$(sanitize "hello---world")
  [ "$result" = "hello-world" ]
}

@test "sanitize: strips leading hyphens" {
  result=$(sanitize "-leading")
  [ "$result" = "leading" ]
}

@test "sanitize: strips trailing hyphens" {
  result=$(sanitize "trailing-")
  [ "$result" = "trailing" ]
}

@test "sanitize: already clean input unchanged" {
  result=$(sanitize "clean-input")
  [ "$result" = "clean-input" ]
}

@test "sanitize: numbers preserved" {
  result=$(sanitize "v2-release-01")
  [ "$result" = "v2-release-01" ]
}

@test "sanitize: empty string returns empty" {
  result=$(sanitize "")
  [ "$result" = "" ]
}

@test "sanitize: dots become hyphens" {
  result=$(sanitize "file.name.md")
  [ "$result" = "file-name-md" ]
}

# ============================================================================
# generate_task_id()
# ============================================================================

@test "generate_task_id: basic combination" {
  result=$(generate_task_id "05-dashboard.md" "aura-shopify")
  [ "$result" = "aura-shopify-05-dashboard" ]
}

@test "generate_task_id: strips .md extension" {
  result=$(generate_task_id "feature-auth.md" "myproject")
  [ "$result" = "myproject-feature-auth" ]
}

@test "generate_task_id: sanitizes spec name" {
  result=$(generate_task_id "My Cool Feature.md" "project")
  [ "$result" = "project-my-cool-feature" ]
}

@test "generate_task_id: truncates long names to 40 chars" {
  local long_name="this-is-a-very-long-specification-name-that-exceeds-forty-characters.md"
  result=$(generate_task_id "$long_name" "proj")
  # basename strips .md, head -c 40 truncates, sanitize cleans
  local expected_prefix="proj-"
  [[ "$result" == proj-* ]]
  [ ${#result} -le 46 ]  # proj- (5) + 40 max + sanitize
}

@test "generate_task_id: handles path input" {
  result=$(generate_task_id "specs/backlog/03-api-refactor.md" "myproj")
  [ "$result" = "myproj-03-api-refactor" ]
}

# ============================================================================
# detect_pkg_manager()
# ============================================================================

@test "detect_pkg_manager: detects pnpm" {
  local d="$FOUNDRY_TEST_DIR/pkg-pnpm"
  mkdir -p "$d" && touch "$d/pnpm-lock.yaml"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "pnpm" ]
}

@test "detect_pkg_manager: detects yarn" {
  local d="$FOUNDRY_TEST_DIR/pkg-yarn"
  mkdir -p "$d" && touch "$d/yarn.lock"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "yarn" ]
}

@test "detect_pkg_manager: detects npm" {
  local d="$FOUNDRY_TEST_DIR/pkg-npm"
  mkdir -p "$d" && touch "$d/package-lock.json"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "npm" ]
}

@test "detect_pkg_manager: detects uv (pyproject.toml)" {
  local d="$FOUNDRY_TEST_DIR/pkg-uv"
  mkdir -p "$d" && touch "$d/pyproject.toml"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "uv" ]
}

@test "detect_pkg_manager: detects pip (requirements.txt)" {
  local d="$FOUNDRY_TEST_DIR/pkg-pip"
  mkdir -p "$d" && touch "$d/requirements.txt"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "pip" ]
}

@test "detect_pkg_manager: returns none when no lock file" {
  local d="$FOUNDRY_TEST_DIR/pkg-none"
  mkdir -p "$d"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "none" ]
}

@test "detect_pkg_manager: pnpm takes priority over npm" {
  local d="$FOUNDRY_TEST_DIR/pkg-multi"
  mkdir -p "$d" && touch "$d/pnpm-lock.yaml" "$d/package-lock.json"
  result=$(detect_pkg_manager "$d")
  [ "$result" = "pnpm" ]
}
