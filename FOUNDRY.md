# Foundry v4 — Multi-Agent Code Factory

Three-backend coding agent system with Jerry as orchestrator. Spawns isolated agents in git worktrees, monitors them with zero AI tokens, auto-respawns on failure, and tracks patterns for model routing. Uses ACP (Agent Client Protocol) for structured agent management with PID-based process lifecycle. Jerry picks the best agent per task via smart routing.

**Key numbers:** ~55-line dispatcher, 6 core modules, 12 lib modules, 16 command files, 5 CI templates. No file over 330 lines.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Foundry System                              │
│                                                                     │
│  ┌──────────┐     ┌──────────────────────────────────────────────┐  │
│  │ Jerry    │────▶│ foundry CLI (bash dispatcher, ~53 lines)     │  │
│  │ (Telegram│     │   spawn | check | status | respawn | ...     │  │
│  │  / cron) │     └──────┬───────────┬───────────┬───────────────┘  │
│  └──────────┘            │           │           │                  │
│                          ▼           ▼           ▼                  │
│  ┌──────────────┐  ┌──────────┐  ┌────────┐  ┌───────────────────┐ │
│  │ core/        │  │ lib/     │  │ cmds/  │  │ foundry.db        │ │
│  │ registry_sql │  │ routing  │  │ 14     │  │ (SQLite, WAL)     │ │
│  │ logging      │  │ state    │  │ files  │  │ tasks + events +  │ │
│  │ gh, patterns │  │ reviews  │  │        │  │ patterns          │ │
│  └──────────────┘  └──────────┘  └────────┘  └───────────────────┘ │
│                                                                     │
│  ┌─── Agent Backends (via ACP JSON-RPC 2.0 over stdio) ──────────┐ │
│  │                                                                │ │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                       │ │
│  │  │ Codex   │  │ Claude  │  │ Gemini  │  ← Jerry picks one    │ │
│  │  │codex-acp│  │claude-  │  │gemini   │    via smart routing   │ │
│  │  │         │  │agent-acp│  │ --acp   │                        │ │
│  │  └────┬────┘  └────┬────┘  └────┬────┘                       │ │
│  │       │            │            │                             │ │
│  │       ▼            ▼            ▼                             │ │
│  │  ┌──────────────────────────────────────────────────────────┐ │ │
│  │  │        acp_orchestrator.py (Python, ~250 lines)          │ │ │
│  │  │  drain startup → session/new → session/prompt → stream   │ │ │
│  │  │  Handles: permissions, steer (USR1), timeout, preflight  │ │ │
│  │  └──────────────────────────────────────────────────────────┘ │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌─── Event-Driven + Fallback Monitoring ─────────────────────────┐ │
│  │  foundry-gate.yml → self-hosted runner → foundry check (instant│ │
│  │  check-loop (*/30 min) → fallback PID + PR + CI + reviews      │ │
│  │  orchestrator (*/3 hrs) → diagnose failures, respawn           │ │
│  │  night-build (1am) → spawn from specs/backlog/                 │ │
│  │  daily-cleanup (3am) → archive, prune worktrees                │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                     │
│  ┌─── Per Task ───────────────────────────────────────────────────┐ │
│  │  git worktree (isolated)  →  PR  →  3 reviewers  →  merge     │ │
│  │  .pid file (liveness)     .done file (completion signal)       │ │
│  │  .log file (streaming)    .steer file (mid-flight redirect)    │ │
│  └────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

Git-style subcommand architecture. The dispatcher is ~50 lines. Each command lives in its own file.

```
foundry                    Thin dispatcher (~53 lines, bash)
swarm -> foundry           Backward compat symlink
config.env                All tunables (models, limits, thresholds)
core/                     Shared infrastructure (6 files, ~400 lines)
  logging.bash              Colors, log functions, tg_notify
  registry.bash             Lock-protected JSON registry ops (legacy)
  registry_sqlite.bash      SQLite-backed registry (primary)
  gh.bash                   GitHub CLI retry wrapper
  patterns.bash             JSONL pattern logging + cost estimation
  templates.bash            Template rendering, helpers (sanitize, detect_pkg_manager)
lib/                      Pure-function modules (12 files, ~900 lines)
  acp_orchestrator.py       ACP agent launcher (Python, ~250 lines, writes status.json)
  jerry_routing.bash        Jerry's smart agent selection (patterns + heuristics)
commands/                 One file per command (16 files, ~2000 lines)
  spawn.bash                cmd_spawn
  check.bash                cmd_check + _check_pr_status
  respawn.bash              cmd_respawn
  design.bash               cmd_design
  status.bash               cmd_status
  patterns.bash             cmd_patterns
  recommend.bash            cmd_recommend
  queue.bash                cmd_queue + cmd_auto
  lifecycle.bash            cmd_attach, cmd_logs, cmd_kill, cmd_steer
  cleanup.bash              cmd_cleanup
  scan.bash                 cmd_scan
  register.bash             cmd_register
  diagnose.bash             cmd_diagnose (self-repair diagnostics)
  help.bash                 cmd_help
check-agents.sh           Zero-token health monitor (standalone, cron fallback)
foundry.db                SQLite registry — single source of truth
scripts/setup-runner.sh   One-time self-hosted runner setup (LaunchAgent)
active-tasks.json         Legacy JSON registry (deprecated, kept for backward compat)
patterns.jsonl            Archive — success/failure/cost per task
templates/                Agent prompt templates (one-shot, fix, design)
ci-templates/             GitHub Actions workflows (6 templates + deploy script, incl. foundry-gate.yml)
tests/                    Bats test suite (347 tests, 19 files)
logs/                     Per-agent log files
```

### How It Works

1. `foundry spawn <repo> <spec> [model]` creates an isolated git worktree, launches a coding agent (Codex, Claude, or Gemini) via ACP as a background process with PID tracking. `foundry orchestrate` adds Jerry's smart routing layer on top.
2. `check-agents.sh` runs every 30 min via cron (fallback; primary is event-driven Gate). Pure bash. Checks: PID alive, PR exists, CI status, 3 reviewer states, branch sync, screenshots. Updates SQLite registry directly. Takes < 2 seconds, uses zero AI tokens. Smart-skips in <100ms when no active tasks. Monitors statuses: `running`, `pr-open`, `ready`, `deploy-failed`, `ci-failed`, `review-failed`, `needs-respawn`. On startup, normalizes unknown statuses (tasks with PR → `pr-open`, without → `failed`).
3. The foundry check loop cron (Sonnet 4.6) reads the registry, auto-respawns failed agents with failure context, and notifies on ready/exhausted states. Non-existent PRs are auto-marked `done-no-pr`. Completed tasks older than 24h are auto-pruned.
4. On completion, `foundry cleanup` archives to `patterns.jsonl`, moves completed specs from `backlog/` to `done/`, and removes worktrees.

### Three Backends + Jerry Routing

| Backend | Default Model | Use For | Cost Estimate |
|---------|--------------|---------|---------------|
| **Codex** | gpt-5.3-codex | Backend logic, complex bugs, multi-file refactors, API work, DB changes | ~$0.002/sec |
| **Claude** | claude-sonnet-4-6 | Frontend components, styling, git ops, fast tasks | ~$0.005/sec |
| **Gemini** | gemini-3.5-pro | Design sensibility, beautiful UIs, HTML/CSS prototypes | ~$0.001/sec |

**Variant models:**
- `codex:medium` or `codex:low` — adjust Codex reasoning level
- `claude-complex` — routes to claude-opus-4-6 for ambiguous specs
- `gemini:custom-model-id` — override Gemini model
- `openclaw` — Jerry smart routing (picks best agent automatically)
- `openclaw:codex` / `openclaw:claude` / `openclaw:gemini` — Jerry routing with hint

**Decision tree:** Design task? → Gemini. Simple frontend? → Claude. Everything else? → Codex. Or use `openclaw` to let Jerry decide.

### Jerry Smart Routing (`openclaw` / `orchestrate`)

Jerry is the orchestrator — he picks the best agent per task using:
1. **Explicit hints**: `openclaw:codex` → use codex directly
2. **Pattern history**: Query `patterns.jsonl` for repo's best agent success rate
3. **Content heuristics**: Design keywords → gemini, frontend files → claude, default → codex

`foundry orchestrate` combines smart routing + spawn + JSON output.
`foundry peek <task-id>` shows structured live status from `status.json`.
`foundry steer-wait <task-id> <msg>` steers + polls for response.

---

## Module System

### core/ — Shared Infrastructure

Six infrastructure modules used by all commands. Each has a double-source guard (`_CORE_*_LOADED`).

```
core/
  logging.bash            ~50 lines  Colors, log/log_ok/warn/err, tg_notify
  registry.bash          ~100 lines  Lock, read, write, update, batch, get_task (legacy JSON)
  registry_sqlite.bash   ~150 lines  SQLite-backed registry (primary, atomic, queryable)
  gh.bash                 ~25 lines  gh_retry wrapper (bail-fast on fatal errors)
  patterns.bash           ~35 lines  pattern_log + cost estimation
  templates.bash          ~45 lines  render_template, detect_pkg_manager, sanitize, generate_task_id
```

### lib/ — Pure Functions

Eleven pure-function bash modules. Each has an include guard and zero side effects. Sourced by both `foundry` and `check-agents.sh`.

```
lib/
  model_routing.bash      35 lines   detect_model_backend()
  state_machine.bash     129 lines   determine_next_status(), is_stale(), is_idle()
  review_pipeline.bash    79 lines   parse_latest_reviews(), detect_gemini_approval(), filter_workflow_checks()
  risk_tier.bash          65 lines   classify_risk_tier(), can_auto_merge()
  notifications.bash      34 lines   should_notify(), build_checks_summary()
  spawn_guards.bash       52 lines   check_concurrent_limit(), detect_parallel_conflict(), parse_spawn_flags()
  video_evidence.bash     49 lines   has_frontend_changes(), check_screenshots_in_pr(), get_screenshot_status()
  check_helpers.bash     160 lines   _try_respawn_or_exhaust, _try_review_fix, _all_checks_pass, _evaluate_pr, _update_pr_checks
  preflight_fn.bash       88 lines   _run_preflight (pre-flight validation)
  respawn_helpers.bash    78 lines   _gather_failure_context, _gather_review_feedback
  runner_script.bash      50 lines   _write_runner_script (shared between spawn + respawn)
```

### model_routing.bash

Resolves user-facing model strings into backend + model + settings.

```bash
source lib/model_routing.bash
detect_model_backend "codex:medium"
# Sets: MODEL_OUT="gpt-5.3-codex", AGENT_BACKEND_OUT="codex", CODEX_REASONING_OUT="medium"

detect_model_backend "openclaw"
# Sets: MODEL_OUT="auto", AGENT_BACKEND_OUT="jerry"

detect_model_backend "openclaw:codex"
# Sets: MODEL_OUT="codex", AGENT_BACKEND_OUT="jerry"
```

### jerry_routing.bash

Jerry's smart agent selection. Resolves the `jerry` meta-backend into a concrete agent.

```bash
source lib/jerry_routing.bash
_jerry_select_agent "/path/to/repo" "Build a dashboard with charts" "auto"
# Sets: JERRY_BACKEND="codex", JERRY_MODEL="codex"

_jerry_select_agent "/path/to/repo" "Redesign the landing page" "auto"
# Sets: JERRY_BACKEND="gemini", JERRY_MODEL="gemini"

_jerry_select_agent "/path/to/repo" "anything" "codex"
# Sets: JERRY_BACKEND="codex", JERRY_MODEL="codex" (hint respected)
```

### state_machine.bash

13 state transitions, fully deterministic. Takes current state + conditions, returns next state.

```bash
source lib/state_machine.bash
next=$(determine_next_status "running" "true" "0" "true" "1" "3" "600" "1800" "true")
# next="pr-open"

is_stale 8000 7200 "false" && echo "STALE"  # running >2h, no PR
is_idle 2000 1800 0 && echo "IDLE"            # running >30min, zero changes
```

### review_pipeline.bash

Handles the 3-reviewer pipeline. Deduplicates reviews (only latest per reviewer matters).

```bash
source lib/review_pipeline.bash
# DISMISSED reviews are filtered out before grouping — prevents false respawns
# on already-fixed code when a human dismisses stale review feedback.
latest=$(parse_latest_reviews "$raw_reviews_json")
claude_state=$(get_reviewer_state "$latest" '.login == "claude[bot]"')

detect_gemini_approval "" "" "" && echo "Gemini: auto-passed (no review = approved)"
detect_gemini_approval "COMMENTED" "0" "" && echo "Gemini: clean (0 findings)"

failures=$(filter_workflow_checks "$checks_json" "1")  # Excludes review checks when PR modifies workflows
```

### risk_tier.bash

Classifies PRs by changed files. Used for auto-merge gating.

```bash
source lib/risk_tier.bash
tier=$(classify_risk_tier "docs/README.md
tests/unit/foo.test.ts")
# tier="LOW"

tier=$(classify_risk_tier "src/auth/login.ts")
# tier="HIGH"

can_auto_merge "APPROVED" "APPROVED" "AUTO_PASSED" "LOW" "true" && echo "safe to merge"
```

### notifications.bash

Dedup logic + CRKG status string builder.

```bash
source lib/notifications.bash
should_notify "ready" "pr-open" && echo "State changed, send notification"
should_notify "ready" "ready"   || echo "Already notified, skip"

summary=$(build_checks_summary "true" "true" "true" "false")
# summary="CRK" (Gemini not approved yet)
```

### spawn_guards.bash

Pre-spawn validation: concurrency limits, conflict detection, flag parsing.

```bash
source lib/spawn_guards.bash
check_concurrent_limit 3 4 && echo "OK, slot available"

conflicts=$(detect_parallel_conflict "/path/to/repo" "$(cat active-tasks.json)")
# echoes IDs of running agents on same repo

parse_spawn_flags --prompt-file /tmp/fix.md myrepo myspec codex
# Sets: PROMPT_FILE_OVERRIDE="/tmp/fix.md", POSITIONAL_ARGS=("myrepo" "myspec" "codex")
```

### video_evidence.bash

Frontend change detection + screenshot verification in PR bodies.

```bash
source lib/video_evidence.bash
has_frontend_changes "src/components/Button.tsx" && echo "frontend PR"

status=$(get_screenshot_status "src/App.tsx" "$pr_body")
# "true" if screenshots found, "false" if missing, "null" if no frontend changes
```

---

## State Machine

### States

| State | Meaning |
|-------|---------|
| `running` | Agent process is active (PID alive) |
| `pr-open` | Agent finished, PR created, awaiting reviews |
| `ready` | All checks passing, awaiting human merge |
| `merged` | PR merged (terminal) |
| `closed` | PR closed without merge (terminal) |
| `done-no-pr` | Agent finished cleanly but didn't create a PR (has commits on branch) |
| `failed` | Agent exited 0 but produced zero commits — rate limit, auth error, stall. Auto-respawns. |
| `needs-respawn` | Failed, eligible for retry |
| `exhausted` | Failed, no retries left (terminal) |
| `crashed` | Agent process died unexpectedly |
| `timeout` | Agent exceeded AGENT_TIMEOUT |
| `ci-failed` | PR exists but CI tests/lint are failing (respawns agent) |
| `deploy-failed` | External deployment failed (Railway/Vercel/Supabase) — waits for self-heal, no respawn |
| `review-failed` | PR exists but reviewer requested changes |
| `killed` | Manually stopped |

### Transition Diagram

```
                    +-----------+
                    |  running  |
                    +-----+-----+
                          |
            +-------------+-------------+
            |             |             |
        exit=0        exit!=0      process died
            |             |             |
     +------+------+     |        +----+----+
     | has PR?     |     |        | crashed |---> needs-respawn
     +--+-------+--+     |        +---------+        |
        |       |        |                      (if attempts < max)
     yes|    no |   +----+-----+                     |
        |       |   | attempts |               +-----------+
  +-----+--+ +-+---+--+ < max?|               | exhausted |
  | pr-open | |done-no | +--+--+               +-----------+
  +----+----+ |   -pr  |    |
       |      +--------+ yes|       elapsed > timeout?
       |             +------+------+      |
       |             |needs-respawn+------+
       |             +------+------+  (if attempts < max)
       |                    |
       |              (respawn cycle)
       |
  +----+----+
  |         +-- PR merged? -----> merged
  |         +-- PR closed? -----> closed
  |         +-- CI failed? -----> ci-failed ---> needs-respawn
  |         +-- Deploy fail? ---> deploy-failed (self-healing, re-checks each cycle)
  |         +-- Review failed? -> review-failed -> needs-respawn
  |         +-- All pass? ------> ready
  +---------+
```

### Self-Healing Flow

1. `check-agents.sh` detects failure (CI, review, crash, timeout)
2. Sets status to `needs-respawn` with `failureReason`
3. Foundry check loop cron reads failure context
4. Fetches: last 100 lines of agent log, CI error details, ALL review feedback (reviews + comments + inline)
5. Builds `fix.md` prompt with full failure context
6. Respawns agent in same worktree -- agent reads its own previous code + specific errors
7. Each retry is smarter: the agent sees what failed and why
8. If `attempts >= maxAttempts` (default 5) BUT task has a PR + unused review-fix budget: delegates to `_try_review_fix` instead of exhausting
9. If truly exhausted (no budget left): escalates to Telegram

**Worktree self-healing:** If cleanup pruned a worktree (exhausted/completed task), `cmd_respawn` auto-recreates it via `git worktree add` and regenerates `.foundry-run.sh` via the shared `_write_runner_script`. No manual intervention needed.

**Two budget system:**
- **Crash budget** (`attempts/maxAttempts`, default 5): For agent crashes, timeouts, exit failures (no PR produced)
- **Review-fix budget** (`reviewFixAttempts/maxReviewFixes`, default 20, configurable via `MAX_REVIEW_FIXES` in config.env): For review-fix cycles (CHANGES_REQUESTED from Claude/Codex/Gemini) AND CI failures on existing PRs. Separate counter, not burned by crashes. `--force` flag bypasses crash budget check.
- **CI failures use review-fix budget**: When a task has a PR but CI is failing (lint, tests), it counts against the review-fix budget — not the crash budget. The agent already produced working code; it just needs to fix CI issues.
- **Wait for all reviewers**: Fix cycles only start after all reviews are in. First cycle waits for Claude + Codex + Gemini. Subsequent cycles (reviewFixAttempts > 0) only wait for Claude + Codex (Gemini only reviews on PR open, not synchronize). This prevents wasted cycles fixing one reviewer's issues while another hasn't reported yet.

### Resilience Features

- **gh_retry bail-fast:** Fatal errors ("Could not resolve", "no checks reported", "not found", "404") cause immediate return instead of 3x retry with backoff. Prevents 14+ second timeouts on non-existent PRs.
- **Non-existent PR detection:** If `gh pr view` returns empty state, task auto-transitions to `done-no-pr` instead of hanging.
- **Loop isolation:** `_check_pr_status` return codes are captured with `|| pr_result=$?` so non-zero codes (awaiting-reviews=4, etc.) don't break the iteration loop.
- **Ready-condition guard:** A PR is only marked `ready` when (Claude OR Codex approved) AND (`CHANGES_REQUESTED == 0`). Previously, approval from one reviewer could override rejection from another.
- **Auto-prune:** Completed tasks (done/merged/closed/done-no-pr/exhausted) older than 24h are automatically removed from the registry at the end of each check cycle.

---

## CRKG Status System

Four-letter status code shown in `foundry status` output. Each letter represents a check gate. The PR link is shown directly in its own column.

| Letter | Check | Meaning |
|--------|-------|---------|
| **C** | CI Passed | All CI checks green |
| **R** | Claude Review | Claude Code Action approved |
| **K** | Codex Review | Codex Action approved (K = codeK) |
| **G** | Gemini Review | Gemini Code Assist approved or auto-passed |

A task showing `CRKG` has all 4 checks passing and is `ready` for merge. The status display also shows an `S` (Synced) flag for branch sync state, making the full column `CRKGS`.

Partial examples:
- `C....` = CI green, waiting on all 3 reviews
- `CR...` = Claude approved, waiting on Codex + Gemini
- `.....` = CI still running, no reviews yet

---

## Risk Tiers

Inspired by the Ryan Carson agent factory pattern. Every PR is classified by its changed files.

| Tier | File Patterns | Policy |
|------|--------------|--------|
| **LOW** | `.md`, tests, `.css/.scss/.less`, images, README, CHANGELOG, LICENSE, `docs/` | Can auto-merge (when `AUTO_MERGE_LOW_RISK=true`) |
| **MEDIUM** | Application code (everything not LOW or HIGH) | Requires human merge decision |
| **HIGH** | `migration`, `auth`, `security`, `payment`, `.env`, `secret`, `credential`, `.pem`, `.key` | NEVER auto-merge. Extra review required. |

Auto-merge requirements (all must be true):
1. `AUTO_MERGE_LOW_RISK=true` in `config.env` (disabled by default)
2. Risk tier is LOW
3. ALL 3 reviewers approved
4. CI is green

---

## Visual Evidence

Frontend PRs get video screencasts embedded directly in the PR comment. Inspired by Ryan Carson's "Harness Engineering" pattern.

### CI Workflow (`visual-evidence.yml`)

1. Detects frontend changes (`.tsx`, `.jsx`, `.vue`, `.svelte`, `.css`, `.scss`, `.html`)
2. Waits for Vercel preview deployment (or falls back to `localhost:3000`)
3. Records video screencasts via Playwright `recordVideo`:
   - Desktop: Chromium 1440x900
   - Mobile: WebKit iPhone 14
4. FFmpeg transcodes WebM to MP4 (H.264, web-optimized) + GIF previews
5. If R2 CDN secrets configured: uploads to CDN, embeds `<video>` tags inline in PR comment (playable directly in GitHub)
6. Otherwise: uploads as GitHub Actions artifacts (14-day retention) with download link

### R2 CDN Setup (for inline playable videos)

Add these secrets to your GitHub repo for inline `<video>` playback:
- `R2_ACCOUNT_ID` — Cloudflare account ID
- `R2_ACCESS_KEY_ID` — R2 API token key ID
- `R2_SECRET_ACCESS_KEY` — R2 API token secret
- `R2_BUCKET` (optional, defaults to `avatarfunnels-assets`)
- `CDN_BASE_URL` (optional, defaults to `https://assets.avatarfunnels.ai`)

Without R2 secrets, the workflow still works — it uploads artifacts and links to the download page.

### Monitoring Integration

`check-agents.sh` tracks the `screenshotsIncluded` field per task:
- `true` -- video/screenshot evidence found in PR body (`<video>`, image URLs, etc.)
- `false` -- frontend PR but no evidence (flagged, doesn't block)
- `null` -- no frontend changes (N/A)

---

## PR Review Pipeline

Every PR gets three AI reviews.

| Reviewer | Action | Blocking? | Triggers On | Auto-Respawn on Rejection? |
|----------|--------|-----------|-------------|---------------------------|
| **Codex** | `openai/codex-action@v1` | YES | opened, synchronize | YES |
| **Claude** | `anthropics/claude-code-action@v1` | YES | opened, synchronize | YES |
| **Gemini** | Gemini Code Assist (GitHub App) | YES (findings block ready) | opened only | YES (one fix cycle) |

**Gemini approval logic** (handles the opened-only limitation):
- No review posted = auto-approved (expected on synchronize events)
- COMMENTED + 0 inline findings = approved (clean review summary)
- ANY inline findings (even low-priority) = NOT approved → triggers one respawn
- After respawn attempt, `geminiAddressed=true` prevents infinite loop (Gemini won't re-review)
- Anything else = not approved

**Workflow chicken-and-egg:** When a PR modifies `.github/workflows/`, the Claude/Codex review workflows may fail because they don't exist on the default branch yet. `filter_workflow_checks()` handles this by excluding review check failures for workflow-modifying PRs.

---

## CLI Reference

```bash
# ─── Orchestration (Jerry) ────────────────────────────────────────────
foundry orchestrate <repo> <spec|task> [hint] --topic  # Jerry picks best agent + spawns (JSON output)
foundry peek <id>                                 # Structured JSON status (registry + live status)
foundry steer-wait <id> <msg>                     # Steer + poll for response (30s timeout)

# ─── Core ──────────────────────────────────────────────────────────────
foundry spawn <repo> <spec|task> [model] --topic  # Launch agent in isolated worktree + TG topic
foundry spawn <repo> <spec> codex --topic-id 42   # Use existing Telegram topic
foundry spawn <repo> <spec> codex --prompt-file /tmp/prompt.md --topic  # Custom prompt
foundry check                                     # Run zero-token monitoring cycle
foundry status                                    # Overview of all active tasks

# ─── Agent Management ─────────────────────────────────────────────────
foundry attach <id>                               # Stream agent's live log output
foundry logs <id>                                 # Tail agent log file
foundry kill <id>                                 # Stop a running agent
foundry steer <id> <msg>                          # Send mid-course correction via ACP signal
foundry diagnose [--fix]                          # Self-repair diagnostics
foundry respawn <id>                              # Retry failed agent with failure context
foundry respawn <id> --force                      # Bypass exhausted budget
foundry respawn <id> --max-fixes 40               # Raise review fix budget and respawn
foundry respawn <id> --prompt-file /tmp/fix.md    # Custom fix prompt

# ─── Pipelines ─────────────────────────────────────────────────────────
foundry design <repo> <spec> [agent]              # Gemini design -> agent implementation
foundry register <repo> <pr-number>               # Track existing PR for monitoring

# ─── Intelligence ──────────────────────────────────────────────────────
foundry patterns                                  # Success/failure stats + cost tracking
foundry recommend <spec|task>                     # Suggest best model from patterns
foundry scan                                      # Find specs across all known projects
foundry queue                                     # Priority-scored spec backlog

# ─── Operations ────────────────────────────────────────────────────────
foundry auto                                      # Auto-spawn from priority queue
foundry cleanup                                   # Archive completed, move specs to done/, remove worktrees

# ─── Zero-Token Monitor (standalone) ──────────────────────────────────
foundry check                                   # Full check with Telegram notifications
foundry check --quiet                           # Silent, just update registry
foundry check --no-notify                       # No Telegram alerts
foundry check --json                            # Machine-readable output
```

---

## Backlog Management

Git-native spec lifecycle: `specs/backlog/` → `specs/done/`.

```
specs/
  backlog/          Pending specs (night-build picks these up)
    01-feature.md
    05-dashboard.md
  done/             Completed specs (archived after merge)
    13-slim-agents.md
```

**How specs move to done:**
1. **Agent Step 7** (primary): One-shot template includes `git mv specs/backlog/X specs/done/` as the last step. Gets squash-merged with the PR.
2. **Cleanup safety net**: `foundry cleanup` checks merged tasks — if spec is still in `backlog/`, moves it. Tries direct push; falls back to chore branch + PR for branch-protected repos.

**Commands:**
- `foundry queue` — shows priority-scored backlog across all known projects
- `foundry scan` — discovers specs across known projects
- `foundry auto` — auto-spawns from priority queue

---

## CI Templates

Six workflow templates deployable to any repo via `deploy-ci.sh`.

```bash
./ci-templates/deploy-ci.sh /path/to/repo [--with-claude-md]
```

| Template | Purpose | Triggers |
|----------|---------|----------|
| `claude-code-review.yml` | Claude Code Action review | PR opened, synchronize |
| `codex-review.yml` | Codex Code Action review | PR opened, synchronize |
| `gemini-check.yml` | Gemini Code Assist review | PR opened, reopened |
| `test-runner.yml` | Lint, types, unit tests | PR opened, synchronize |
| `visual-evidence.yml` | Playwright video screencasts + FFmpeg | PR opened, synchronize |
| **`foundry-gate.yml`** | **Event-driven bridge → local `foundry check`** | **workflow_run completed, review submitted, PR closed/labeled** |

**Required secrets:** `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`), `OPENAI_API_KEY`
**Required app:** Gemini Code Assist (free, GitHub Marketplace)

### Foundry Gate (Event-Driven Check)

The `foundry-gate.yml` workflow runs on a **self-hosted runner** (label: `foundry`) on the Mac mini. When any CI workflow completes, a review is submitted, or a PR is closed — the Gate triggers `foundry check <task-id>` **locally within seconds**. No polling delay.

```
GitHub Event (CI done / review submitted / PR closed)
  → foundry-gate.yml triggers on self-hosted runner
  → Resolves PR → looks up task-id in SQLite registry
  → Runs `foundry check <task-id>` (targeted, fast)
  → Auto-respawn with review context if CHANGES_REQUESTED
```

**Security:** Fork PRs rejected. Only `foundry/` branches or `foundry`-labeled PRs trigger the runner. Event data via env vars (no shell injection). Concurrency group per branch prevents duplicate checks.

**Setup:** `bash scripts/setup-runner.sh <github-org>` — installs runner as LaunchAgent (auto-start on boot).

The check-loop cron (*/30 min) remains as a **fallback** for edge cases the Gate doesn't catch (e.g., agent timeout, PID death, orphaned tasks).

---

## Authentication

Foundry agents authenticate differently per backend:

| Backend | Auth Method | Token Location |
|---------|------------|----------------|
| **Codex** | API key (`OPENAI_API_KEY`) | Environment variable — never expires. Sandbox: `disk-full-read-write-access` (set in `acp_orchestrator.py`) |
| **Claude** | OAuth setup-token | `~/.claude/.foundry-setup-token` — ~1 year validity |
| **Gemini** | API key (`GEMINI_API_KEY`) | Environment variable — never expires |

### Claude Agent Auth (Setup Token)

Claude backend agents run headlessly and cannot refresh OAuth tokens interactively. The solution is a **long-lived setup-token** generated once via `claude setup-token` (~1 year validity).

**One-time setup:**

```bash
claude setup-token
# Copy the output token, then:
echo -n "<TOKEN>" > ~/.claude/.foundry-setup-token
chmod 600 ~/.claude/.foundry-setup-token
```

**Token resolution priority** (in `runner_script.bash`):

1. `~/.claude/.foundry-setup-token` — long-lived setup-token (preferred)
2. `~/.claude/.credentials.json` — short-lived OAuth token (8-12h, skipped if expired)
3. `~/.claude/.foundry-token` — cache written by active CLI sessions
4. macOS Keychain — last resort

If all sources are exhausted, the agent fails loudly with a clear error message.

**CI reviews** use the same setup-token stored as `CLAUDE_CODE_OAUTH_TOKEN` GitHub secret. The `claude-code-action` handles refresh internally.

**Renewal:** Run `claude setup-token` again when the token approaches its ~1 year expiry.

### Codex Sandbox Permissions

Codex CLI runs a macOS Seatbelt sandbox by default which blocks writes to `/tmp`, `__pycache__`, and temp directories. Foundry passes `sandbox_permissions=["disk-full-read-write-access"]` via `acp_orchestrator.py` so agents can run tests and write files in worktrees. This is safe because each agent runs in an isolated git worktree.

---

## Cron Jobs

### Event-Driven + Cron Fallback

Primary monitoring is **event-driven** via Foundry Gate (self-hosted runner). Cron jobs serve as fallback + orchestration.

| Job | Schedule | Model | Timeout | Purpose |
|-----|----------|-------|---------|---------|
| **Foundry Gate** | Event-driven | — | 5 min | CI done / review submitted → immediate `foundry check` |
| `foundry-check-loop` | Every 30 min | Haiku | 120s | Fallback monitor + auto-respawn |
| `foundry-daily-cleanup` | 3:45 AM daily | Haiku | 120s | Archive + prune worktrees |
| `foundry-orchestrator` | Every 3 hours | Sonnet 4.6 | 300s | Proactive spawn from backlogs |
| `foundry-night-build` | 1:30 AM daily | Sonnet 4.6 | 300s | Auto-spawn from spec backlogs |

The Gate handles real-time reactions (review → respawn in seconds). The check-loop catches edge cases (timeout, PID death, orphans). Check-loop and cleanup use Haiku (simple tasks). Orchestrator uses Sonnet (needs judgment).

---

## Configuration

All tunables in `config.env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_DEFAULT` | `claude-sonnet-4-6` | Default Claude model |
| `CLAUDE_COMPLEX` | `claude-opus-4-6` | Claude model for complex tasks |
| `CODEX_MODEL` | `gpt-5.3-codex` | Codex model |
| `CODEX_REASONING` | `high` | Default Codex reasoning level |
| `GEMINI_MODEL` | `gemini-3.5-pro` | Gemini model |
| `DEFAULT_MODEL` | `codex` | Backend for `foundry spawn` without model arg |
| `MAX_RETRIES` | `5` | Auto-respawn attempts before exhausted |
| `AGENT_TIMEOUT` | `1800` | 30 min timeout per agent |
| `MAX_CONCURRENT` | `4` | Max parallel agents |
| `PREFLIGHT_ENABLED` | `true` | Local lint/test before marking done |
| `AUTO_MERGE_LOW_RISK` | `false` | Auto-merge LOW risk PRs |
| `STALE_THRESHOLD_SECS` | `7200` | Flag agents running >2h without PR |
| `IDLE_THRESHOLD_SECS` | `1800` | Flag agents idle >30min with zero changes |
| `LINEAR_INTEGRATION` | `false` | Enable Linear identifier injection in PRs |
| `LINEAR_PREFIX_MAP` | `{}` | JSON map of `"owner/repo"` to Linear team prefix |

---

## Linear Integration (Optional)

When enabled, Foundry automatically injects Linear issue identifiers into PR descriptions so stakeholders can track progress on a Linear board without any manual work.

**How it works:**
- Foundry maps GitHub repos to Linear team prefixes (e.g. `myorg/my-repo` -> `ENG`)
- For issue-based tasks, the PR title gets the Linear ID and the body gets both closing keywords:
  ```
  Title: ENG-5: issue-5
  Body:
  fixes ENG-5    <- Linear: links PR
  fixes #5       <- GitHub: auto-closes the issue on merge
  ```
- Linear recognizes the ID in the PR title and automatically tracks status:
  - PR opened -> In Progress
  - PR merged -> Done
- Foundry never calls the Linear API. It's a static prefix lookup, nothing more.

**Setup:**
```bash
# config.env
LINEAR_INTEGRATION=true
LINEAR_PREFIX_MAP='{
  "myorg/my-repo": "ENG",
  "myorg/design-system": "DES"
}'
```

Repos not in the map are unaffected. When disabled (default), Foundry behaves exactly as before.

---

## Testing

374 tests across 19 files using [Bats](https://github.com/bats-core/bats-core) (Bash Automated Testing System).

### ACP StreamReader Fix

- `asyncio.create_subprocess_exec` uses `limit=16MB` (16_777_216 bytes) to handle large ACP responses that exceed the default 64KB StreamReader buffer
- CI failures now use the review-fix budget (20 attempts, configurable via `MAX_REVIEW_FIXES`) instead of the crash budget, since the agent already produced working code and just needs to fix CI issues

```bash
# Run all tests
cd ~/.openclaw/workspace/scripts/foundry && bats tests/

# Run a specific test file
bats tests/test_state_machine.bats

# Run with verbose output
bats --verbose-run tests/
```

### Test Files

| File | Tests | What It Covers |
|------|-------|---------------|
| `test_model_routing.bats` | 12 | Backend resolution, variant models, defaults |
| `test_state_machine.bats` | 23 | All 13 state transitions, stale/idle detection |
| `test_review_pipeline.bats` | 18 | Review dedup, Gemini approval logic, workflow filtering |
| `test_risk_tier.bats` | 17 | File classification, auto-merge gating |
| `test_notifications.bats` | 8 | Dedup logic, CRKG string building |
| `test_spawn_guards.bats` | 12 | Concurrency limits, conflict detection, flag parsing |
| `test_video_evidence.bats` | 12 | Frontend detection, screenshot parsing |
| `test_pure_functions.bats` | 22 | Original inline pure functions |
| `test_registry.bats` | 24 | active-tasks.json read/write operations |
| `test_scoring.bats` | 30 | Queue priority scoring, spec parsing |
| `test_pattern_log.bats` | 13 | Pattern archive, cost tracking |
| `test_lifecycle.bats` | 13 | End-to-end spawn -> check -> cleanup |
| `test_edge_cases.bats` | 16 | Boundary conditions, error handling |
| `test_ci_templates.bats` | 15 | Template deployment, file existence |
| `test_template.bats` | 8 | Prompt template rendering |
| `test_gh_retry.bats` | 5 | GitHub API retry logic |
| `test_acp.bats` | 17 | ACP runner scripts, attach, steer, kill |
| `test_diagnose.bats` | 7 | Self-repair diagnostics, stuck detection |

---

## Registry Schema

SQLite database (`foundry.db`) with three tables: `tasks`, `events`, `patterns`. Each task:

```json
{
  "id": "aura-shopify-12-agent-friendly-linting",
  "repo": "aura-shopify",
  "repoPath": "/Users/me/projects/org/aura-shopify",
  "worktree": "...-foundry/12-agent-friendly-linting",
  "branch": "foundry/12-agent-friendly-linting",
  "pid": 12345,
  "agent": "codex",
  "model": "gpt-5.3-codex",
  "spec": "specs/backlog/12-agent-friendly-linting.md",
  "description": "Agent-friendly lint rules",
  "startedAt": 1740268800,
  "status": "running",
  "attempts": 1,
  "maxAttempts": 5,
  "reviewFixAttempts": 0,
  "maxReviewFixes": 20,
  "pr": null,
  "checks": {
    "agentAlive": true,
    "prCreated": false,
    "branchSynced": false,
    "ciPassed": false,
    "codexReview": null,
    "claudeReview": null,
    "geminiReview": null,
    "screenshotsIncluded": null
  },
  "lastCheckedAt": null,
  "completedAt": null,
  "failureReason": null,
  "respawnContext": null,
  "notifyOnComplete": true
}
```

---

## Known Projects

Configured in `config.env` under `KNOWN_PROJECTS`:

```
~/projects/primal-meat-club/aura-shopify     # Shopify store (pnpm, Next.js, Supabase)
~/projects/primal-meat-club/ad-engine        # Ad management (pnpm, Next.js)
~/projects/merlinrabens/growthpulse          # Growth analytics (pnpm, Next.js)
~/projects/huklberry/lead-gen                # Lead generation (pnpm, Next.js)
~/projects/merlinrabens/avatarfunnels        # Avatar funnels website
```

---

## Related Docs

- **Orchestrator knowledge:** `workspace/knowledge/foundry-orchestrator.md` -- prompt templates, workflows, cron prompts
- **Spec format:** `workspace/specs/unified-agent-factory-v2.md` -- canonical spec
- **Reference article:** `workspace/knowledge/reference/elvis-agent-factory-article.md`
