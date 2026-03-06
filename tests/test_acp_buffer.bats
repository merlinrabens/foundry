#!/usr/bin/env bats
# Tests for ACP orchestrator buffer handling (large responses)

load test_helper

# Helper: create a mock ACP adapter that sends large responses
_create_large_response_adapter() {
  local size_kb="${1:-128}"
  local adapter="$FOUNDRY_TEST_DIR/mock_acp_adapter.py"
  local payload
  payload=$(python3 -c "print('x' * ($size_kb * 1024))")
  
  cat > "$adapter" << PYEOF
#!/usr/bin/env python3
import json, sys

# Read session/new
line = sys.stdin.readline()
req = json.loads(line)
resp = {"jsonrpc": "2.0", "id": req["id"], "result": {"sessionId": "test-sess", "data": "$payload"}}
sys.stdout.write(json.dumps(resp) + "\n")
sys.stdout.flush()

# Read session/prompt  
line2 = sys.stdin.readline()
req2 = json.loads(line2)
resp2 = {"jsonrpc": "2.0", "id": req2["id"], "result": {"stopReason": "end_turn"}}
sys.stdout.write(json.dumps(resp2) + "\n")
sys.stdout.flush()
PYEOF
  echo "$adapter"
}

@test "ACP orchestrator: StreamReader limit is 16MB (not default 64KB)" {
  # Verify the limit is set in the source code
  grep -q 'limit=16 \* 1024 \* 1024' "$_FOUNDRY_REAL_DIR/lib/acp_orchestrator.py"
}

@test "ACP orchestrator: handles 128KB ACP response lines" {
  # Integration test using mock adapter
  python3 /tmp/test_acp_buffer.py
}

@test "ACP orchestrator: error logging includes exception type and traceback" {
  grep -q 'type(e).__name__' "$_FOUNDRY_REAL_DIR/lib/acp_orchestrator.py"
  grep -q 'traceback.print_exc' "$_FOUNDRY_REAL_DIR/lib/acp_orchestrator.py"
}

@test "ACP orchestrator: stdin write errors include adapter return code" {
  grep -q 'ACP adapter stdin closed' "$_FOUNDRY_REAL_DIR/lib/acp_orchestrator.py"
  grep -q 'BrokenPipeError' "$_FOUNDRY_REAL_DIR/lib/acp_orchestrator.py"
}
