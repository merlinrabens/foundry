#!/usr/bin/env bats
# Tests for status.json writing + peek command

load test_helper

# ============================================================================
# ACP orchestrator: status file + phase detection
# ============================================================================

@test "ACPOrchestrator has _write_status method" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$real_dir', 'lib'))
from acp_orchestrator import ACPOrchestrator
assert hasattr(ACPOrchestrator, '_write_status'), 'Missing _write_status method'
"
}

@test "ACPOrchestrator has _detect_phase method" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$real_dir', 'lib'))
from acp_orchestrator import ACPOrchestrator
assert hasattr(ACPOrchestrator, '_detect_phase'), 'Missing _detect_phase method'
"
}

@test "detect_phase returns coding for Edit tool" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local result
  result=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$real_dir', 'lib'))
from acp_orchestrator import ACPOrchestrator
print(ACPOrchestrator._detect_phase('Edit'))
")
  [ "$result" = "coding" ]
}

@test "detect_phase returns coding for Write tool" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local result
  result=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$real_dir', 'lib'))
from acp_orchestrator import ACPOrchestrator
print(ACPOrchestrator._detect_phase('Write'))
")
  [ "$result" = "coding" ]
}

@test "detect_phase returns None for Bash (ambiguous)" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local result
  result=$(python3 -c "
import sys, os
sys.path.insert(0, os.path.join('$real_dir', 'lib'))
from acp_orchestrator import ACPOrchestrator
print(ACPOrchestrator._detect_phase('Bash'))
")
  [ "$result" = "None" ]
}

@test "_write_status creates status.json" {
  local real_dir
  real_dir="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  local tmpdir
  tmpdir=$(mktemp -d)
  python3 -c "
import sys, os, json
sys.path.insert(0, os.path.join('$real_dir', 'lib'))
from acp_orchestrator import ACPOrchestrator
o = ACPOrchestrator('codex', 'gpt-5.3-codex', '$tmpdir', '.p.md', '/tmp/l', '$tmpdir/t.done', 60)
o._phase = 'coding'
o._tools_used = ['Edit', 'Read']
o._files_modified = 3
o._last_tool = 'Edit'
o._write_status()
assert os.path.exists('$tmpdir/t.status.json'), 'status.json not created'
data = json.load(open('$tmpdir/t.status.json'))
assert data['phase'] == 'coding'
assert data['files_modified'] == 3
assert 'Edit' in data['tools_used']
assert data['last_tool'] == 'Edit'
assert data['error'] is None
"
  rm -rf "$tmpdir"
}

# ============================================================================
# Peek command
# ============================================================================

@test "cmd_peek returns error for unknown task" {
  create_sample_registry
  run cmd_peek "nonexistent-task"
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '.error' >/dev/null
}

@test "cmd_peek returns structured JSON for known task" {
  create_sample_registry
  run cmd_peek "myproject-feature-auth"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.id' >/dev/null
  echo "$output" | jq -e '.status' >/dev/null
  echo "$output" | jq -e '.agent' >/dev/null
  echo "$output" | jq -e '.phase' >/dev/null
}

@test "cmd_peek includes elapsed_min" {
  create_sample_registry
  local result
  result=$(cmd_peek "myproject-feature-auth")
  local elapsed
  elapsed=$(echo "$result" | jq -r '.elapsed_min')
  [ "$elapsed" -ge 0 ]
}

@test "cmd_peek reads status.json when available" {
  create_sample_registry
  mkdir -p "${FOUNDRY_DIR}/logs"
  cat > "${FOUNDRY_DIR}/logs/myproject-feature-auth.status.json" << 'EOF'
{"phase":"testing","tools_used":["Bash","Edit"],"files_modified":5,"last_tool":"Bash","last_activity_ts":1709654321,"error":null}
EOF
  local result
  result=$(cmd_peek "myproject-feature-auth")
  local phase
  phase=$(echo "$result" | jq -r '.phase')
  [ "$phase" = "testing" ]
  local files
  files=$(echo "$result" | jq -r '.files_modified')
  [ "$files" = "5" ]
}

@test "cmd_peek defaults to unknown phase without status.json" {
  create_sample_registry
  local result
  result=$(cmd_peek "myproject-feature-auth")
  local phase
  phase=$(echo "$result" | jq -r '.phase')
  [ "$phase" = "unknown" ]
}
