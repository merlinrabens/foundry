#!/usr/bin/env bats
# Tests for render_template() — placeholder replacement

load test_helper

# ============================================================================
# render_template()
# ============================================================================

@test "render_template: single placeholder" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  echo "Hello {{NAME}}, welcome!" > "$tmpl"
  result=$(render_template "$tmpl" "NAME=World")
  [ "$result" = "Hello World, welcome!" ]
}

@test "render_template: multiple placeholders" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  echo "{{GREETING}} {{NAME}}, you are {{ROLE}}." > "$tmpl"
  result=$(render_template "$tmpl" "GREETING=Hello" "NAME=Alice" "ROLE=admin")
  [ "$result" = "Hello Alice, you are admin." ]
}

@test "render_template: repeated placeholder replaced everywhere" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  echo "{{X}} and {{X}} and {{X}}" > "$tmpl"
  result=$(render_template "$tmpl" "X=yes")
  [ "$result" = "yes and yes and yes" ]
}

@test "render_template: unreplaced placeholder stays" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  echo "{{REPLACED}} and {{KEPT}}" > "$tmpl"
  result=$(render_template "$tmpl" "REPLACED=done")
  [ "$result" = "done and {{KEPT}}" ]
}

@test "render_template: handles special characters in value" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  echo "Path: {{PATH}}" > "$tmpl"
  result=$(render_template "$tmpl" "PATH=/usr/local/bin")
  [ "$result" = "Path: /usr/local/bin" ]
}

@test "render_template: handles multiline value" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  printf "Start\n{{CONTENT}}\nEnd" > "$tmpl"
  local multiline_val=$'line1\nline2\nline3'
  result=$(render_template "$tmpl" "CONTENT=${multiline_val}")
  echo "$result" | grep -q "line1"
  echo "$result" | grep -q "line2"
  echo "$result" | grep -q "line3"
}

@test "render_template: empty value replaces with nothing" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  echo "before{{EMPTY}}after" > "$tmpl"
  result=$(render_template "$tmpl" "EMPTY=")
  [ "$result" = "beforeafter" ]
}

@test "render_template: preserves non-placeholder content" {
  local tmpl="$FOUNDRY_TEST_DIR/tmpl.txt"
  cat > "$tmpl" << 'EOF'
# Configuration
name = {{NAME}}
port = 8080
debug = true
EOF
  result=$(render_template "$tmpl" "NAME=myapp")
  echo "$result" | grep -q "port = 8080"
  echo "$result" | grep -q "debug = true"
  echo "$result" | grep -q "name = myapp"
}
