#!/bin/bash
# setup-runner.sh — One-time setup of GitHub Actions self-hosted runner for Foundry Gate
#
# This installs a self-hosted runner on the Mac mini that receives GitHub events
# and runs `foundry check` locally. Truly event-driven, zero polling.
#
# Usage:
#   bash setup-runner.sh <github-org-or-owner/repo>
#
# Examples:
#   bash setup-runner.sh primal-meat-club                          # org-level runner (covers all repos)
#   bash setup-runner.sh primal-meat-club/aura-shopify             # repo-level runner (single repo)
#
# Prerequisites:
#   - gh CLI authenticated with admin access
#   - macOS (arm64 or x64)

set -eo pipefail

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  echo "Usage: $0 <github-org-or-owner/repo>"
  echo ""
  echo "Examples:"
  echo "  $0 primal-meat-club                    # org-level (recommended)"
  echo "  $0 primal-meat-club/aura-shopify       # repo-level"
  exit 1
fi

RUNNER_DIR="$HOME/.openclaw/github-runner"
RUNNER_NAME="foundry-$(hostname -s)"
RUNNER_LABELS="self-hosted,foundry,macOS"

# ── Detect scope (org vs repo) ──────────────────────────────────────
if [[ "$TARGET" == */* ]]; then
  SCOPE="repo"
  API_PATH="repos/$TARGET"
  RUNNER_URL="https://github.com/$TARGET"
else
  SCOPE="org"
  API_PATH="orgs/$TARGET"
  RUNNER_URL="https://github.com/$TARGET"
fi

echo "Setting up Foundry self-hosted runner"
echo "  Target:  $TARGET ($SCOPE-level)"
echo "  Name:    $RUNNER_NAME"
echo "  Labels:  $RUNNER_LABELS"
echo "  Dir:     $RUNNER_DIR"
echo ""

# ── Check prerequisites ─────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI required. brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "ERROR: gh not authenticated. gh auth login"; exit 1; }

# ── Get registration token ──────────────────────────────────────────
echo "Requesting registration token..."
REG_TOKEN=$(gh api -X POST "$API_PATH/actions/runners/registration-token" --jq '.token' 2>/dev/null)
if [ -z "$REG_TOKEN" ]; then
  echo "ERROR: Failed to get registration token. Do you have admin access to $TARGET?"
  exit 1
fi
echo "  Got token"

# ── Download runner (if not already installed) ───────────────────────
if [ -f "$RUNNER_DIR/config.sh" ]; then
  echo "Runner binary already installed at $RUNNER_DIR"
else
  echo "Downloading GitHub Actions runner..."
  mkdir -p "$RUNNER_DIR"

  # Detect architecture
  ARCH=$(uname -m)
  case "$ARCH" in
    arm64) RUNNER_ARCH="osx-arm64" ;;
    x86_64) RUNNER_ARCH="osx-x64" ;;
    *) echo "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
  esac

  # Get latest release URL
  LATEST_VERSION=$(gh api repos/actions/runner/releases/latest --jq '.tag_name' | sed 's/^v//')
  DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${LATEST_VERSION}/actions-runner-${RUNNER_ARCH}-${LATEST_VERSION}.tar.gz"

  echo "  Version: $LATEST_VERSION ($RUNNER_ARCH)"
  curl -sL "$DOWNLOAD_URL" | tar xz -C "$RUNNER_DIR"
  echo "  Installed"
fi

# ── Configure ────────────────────────────────────────────────────────
echo "Configuring runner..."
(cd "$RUNNER_DIR" && ./config.sh \
  --url "$RUNNER_URL" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$RUNNER_LABELS" \
  --work "$RUNNER_DIR/_work" \
  --replace \
  --unattended)

echo "  Configured"

# ── Install as LaunchAgent (auto-start on boot) ─────────────────────
echo "Installing as LaunchAgent..."
(cd "$RUNNER_DIR" && ./svc.sh install)

# Patch plist: add KeepAlive + ThrottleInterval (svc.sh doesn't include these)
# Without KeepAlive, network blips kill the runner and it never restarts.
PLIST_FILE=$(ls ~/Library/LaunchAgents/actions.runner.*.plist 2>/dev/null | head -1)
if [ -n "$PLIST_FILE" ] && ! grep -q "KeepAlive" "$PLIST_FILE"; then
  echo "  Patching plist with KeepAlive..."
  sed -i '' 's|</dict>|    <key>KeepAlive</key>\
    <true/>\
    <key>ThrottleInterval</key>\
    <integer>30</integer>\
  </dict>|' "$PLIST_FILE"
  echo "  Added KeepAlive (auto-restart on crash, 30s throttle)"
fi

(cd "$RUNNER_DIR" && ./svc.sh start)

echo ""
echo "✅ Foundry self-hosted runner is running!"
echo ""
echo "Verify: gh api $API_PATH/actions/runners --jq '.runners[] | select(.name == \"$RUNNER_NAME\") | {name, status, labels: [.labels[].name]}'"
echo ""
echo "The Foundry Gate workflow will now run locally on this machine."
echo "Events from GitHub (CI completion, review submission) trigger"
echo "immediate foundry check — zero polling, zero delay."
echo ""
echo "Management:"
echo "  Status:  cd $RUNNER_DIR && ./svc.sh status"
echo "  Stop:    cd $RUNNER_DIR && ./svc.sh stop"
echo "  Start:   cd $RUNNER_DIR && ./svc.sh start"
echo "  Remove:  cd $RUNNER_DIR && ./svc.sh uninstall && ./config.sh remove --token \$(gh api -X POST $API_PATH/actions/runners/remove-token --jq '.token')"
