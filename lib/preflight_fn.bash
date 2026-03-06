# Preflight validation function — sourced by .foundry-run.sh at runtime
# Runs lint/test checks AFTER agent finishes, BEFORE marking as done.
# Catches 80% of CI failures locally, saving a full CI roundtrip.
_run_preflight() {
  local wt="$1"
  local pf_timeout="${PREFLIGHT_TIMEOUT:-120}"
  local PREFLIGHT_FAILED=0
  local PREFLIGHT_LOG=""

  echo ""
  echo "=== Running pre-flight validation... ==="

  cd "$wt" || return 1

  # Detect project type and run appropriate checks
  if [ -f "frontend/package.json" ] || [ -f "package.json" ]; then
    local pkg_dir="$wt"
    [ -f "frontend/package.json" ] && pkg_dir="$wt/frontend"
    cd "$pkg_dir"

    # TypeScript check
    if [ -f "tsconfig.json" ]; then
      echo "[preflight] Running TypeScript check..."
      local tsc_out
      tsc_out=$(timeout "$pf_timeout" npx tsc --noEmit 2>&1 | tail -30) || {
        PREFLIGHT_FAILED=1
        PREFLIGHT_LOG="${PREFLIGHT_LOG}\n[TSC FAILED]\n${tsc_out}"
        echo "[preflight] TypeScript check FAILED"
      }
    fi

    # ESLint check (only if eslint config exists)
    if [ -f ".eslintrc" ] || [ -f ".eslintrc.js" ] || [ -f ".eslintrc.json" ] || [ -f ".eslintrc.yml" ] || [ -f "eslint.config.js" ] || [ -f "eslint.config.mjs" ]; then
      echo "[preflight] Running ESLint..."
      local eslint_out
      eslint_out=$(timeout "$pf_timeout" npx eslint . --max-warnings=0 2>&1 | tail -30) || {
        PREFLIGHT_FAILED=1
        PREFLIGHT_LOG="${PREFLIGHT_LOG}\n[ESLINT FAILED]\n${eslint_out}"
        echo "[preflight] ESLint FAILED"
      }
    fi

    cd "$wt"
  fi

  if [ -f "backend/pyproject.toml" ] || [ -f "pyproject.toml" ]; then
    local py_dir="$wt"
    [ -f "backend/pyproject.toml" ] && py_dir="$wt/backend"
    cd "$py_dir"

    # Ruff check
    if command -v ruff >/dev/null 2>&1; then
      echo "[preflight] Running ruff check..."
      local ruff_out
      ruff_out=$(timeout "$pf_timeout" ruff check . 2>&1 | tail -30) || {
        PREFLIGHT_FAILED=1
        PREFLIGHT_LOG="${PREFLIGHT_LOG}\n[RUFF FAILED]\n${ruff_out}"
        echo "[preflight] Ruff check FAILED"
      }
    fi

    # Pytest (quick run)
    if [ -d "tests" ] || [ -d "test" ]; then
      echo "[preflight] Running pytest..."
      local pytest_out
      pytest_out=$(timeout "$pf_timeout" python -m pytest -x --timeout=60 -q 2>&1 | tail -30) || {
        PREFLIGHT_FAILED=1
        PREFLIGHT_LOG="${PREFLIGHT_LOG}\n[PYTEST FAILED]\n${pytest_out}"
        echo "[preflight] Pytest FAILED"
      }
    fi

    cd "$wt"
  fi

  if [ "$PREFLIGHT_FAILED" -eq 1 ]; then
    echo ""
    echo "=== PRE-FLIGHT VALIDATION FAILED ==="
    echo -e "$PREFLIGHT_LOG"
    echo ""
    echo "PREFLIGHT_FAILED" > "${wt}/.preflight-status"
    return 1
  else
    echo "=== Pre-flight validation PASSED ==="
    echo "PREFLIGHT_PASSED" > "${wt}/.preflight-status"
    return 0
  fi
}
