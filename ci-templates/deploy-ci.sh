#!/bin/bash
# deploy-ci.sh — Deploy CI workflow templates to any repository
#
# Usage: ./deploy-ci.sh /path/to/repo [--with-claude-md]
#
# Copies all CI workflow templates into the repo's .github/workflows/ directory.
# Idempotent — safe to run multiple times, overwrites existing templates.
#
# Options:
#   --with-claude-md    Also copy CLAUDE.md.template -> CLAUDE.md in repo root

set -eo pipefail

# ─── Args ────────────────────────────────────────────────────────────
REPO_PATH="${1:-}"
WITH_CLAUDE_MD=0

for arg in "$@"; do
  case "$arg" in
    --with-claude-md) WITH_CLAUDE_MD=1 ;;
  esac
done

if [ -z "$REPO_PATH" ]; then
  echo "Usage: $0 /path/to/repo [--with-claude-md]"
  echo ""
  echo "Deploys CI workflow templates (Claude, Codex, Gemini reviews + test runner + visual evidence + convergence gate)"
  echo "into the target repo's .github/workflows/ directory."
  echo ""
  echo "Required secrets in the target repo:"
  echo "  CLAUDE_CODE_OAUTH_TOKEN  — for Claude Code Review"
  echo "  OPENAI_API_KEY           — for Codex Code Review"
  echo ""
  echo "Required GitHub Apps on the target repo:"
  echo "  Gemini Code Assist       — free, install from GitHub Marketplace"
  exit 1
fi

# ─── Validate ────────────────────────────────────────────────────────
if [ ! -d "$REPO_PATH" ]; then
  echo "ERROR: $REPO_PATH is not a directory"
  exit 1
fi

if [ ! -d "$REPO_PATH/.git" ] && ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: $REPO_PATH is not a git repository"
  exit 1
fi

# ─── Resolve template directory ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"

# ─── Create target directory ─────────────────────────────────────────
WORKFLOWS_DIR="$REPO_PATH/.github/workflows"
mkdir -p "$WORKFLOWS_DIR"

# ─── Copy templates ──────────────────────────────────────────────────
TEMPLATES=(
  "claude-code-review.yml"
  "codex-review.yml"
  "gemini-check.yml"
  "test-runner.yml"
  "visual-evidence.yml"
  "foundry-gate.yml"
)

COPIED=0
for template in "${TEMPLATES[@]}"; do
  src="$TEMPLATE_DIR/$template"
  dst="$WORKFLOWS_DIR/$template"

  if [ ! -f "$src" ]; then
    echo "WARN: Template not found: $src"
    continue
  fi

  cp "$src" "$dst"
  echo "  Deployed: $template"
  COPIED=$((COPIED + 1))
done

# ─── Optional: Copy CLAUDE.md template ───────────────────────────────
if [ "$WITH_CLAUDE_MD" -eq 1 ]; then
  CLAUDE_MD_SRC="$TEMPLATE_DIR/CLAUDE.md.template"
  CLAUDE_MD_DST="$REPO_PATH/CLAUDE.md"

  if [ -f "$CLAUDE_MD_SRC" ]; then
    if [ -f "$CLAUDE_MD_DST" ]; then
      echo "  CLAUDE.md already exists in repo, skipping (use --force to overwrite)"
    else
      cp "$CLAUDE_MD_SRC" "$CLAUDE_MD_DST"
      echo "  Deployed: CLAUDE.md"
    fi
  else
    echo "  WARN: CLAUDE.md.template not found"
  fi
fi

# ─── Create labels ────────────────────────────────────────────────────
echo "  Creating labels..."
(cd "$REPO_PATH" && gh label create "ready-for-evidence" \
  --color 0E8A16 --description "Foundry: triggers visual evidence" \
  --force 2>/dev/null) || true
(cd "$REPO_PATH" && gh label create "foundry" \
  --color 1D76DB --description "Foundry: opt-in to event-driven local checks" \
  --force 2>/dev/null) || true
(cd "$REPO_PATH" && gh label create "foundry-ready" \
  --color 0E8A16 --description "Foundry: all checks passed, ready to merge" \
  --force 2>/dev/null) || true

# ─── Summary ──────────────────────────────────────────────────────────
echo ""
echo "Deployed $COPIED workflow(s) to $WORKFLOWS_DIR"
echo ""
echo "Next steps:"
echo "  1. Add secrets to the repo (Settings > Secrets > Actions):"
echo "     - CLAUDE_CODE_OAUTH_TOKEN"
echo "     - OPENAI_API_KEY"
echo "     - TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID  (for Foundry Gate notifications)"
echo "  2. Install Gemini Code Assist GitHub App on the repo (free)"
echo "     https://github.com/marketplace/gemini-code-assist"
echo "  3. For Visual Evidence, add R2 CDN secrets:"
echo "     - R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY"
echo "  4. Commit and push the workflow files"
echo "  5. Open a PR to test the review pipeline"
