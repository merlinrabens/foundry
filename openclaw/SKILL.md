---
name: foundry
version: 2.0.0
description: Multi-agent code factory. Orchestrates AI coding agents (Codex, Claude, Gemini) with smart routing, isolated worktrees, ACP protocol, SQLite registry, and bidirectional agent communication. Completion and status signals go through the registry, not files.
---

# Foundry Skill for OpenClaw

## HARD RULES

1. **NEVER spawn agents directly** via `claude`, `codex`, `gemini` CLI, ACP sub-agents, or `sessions_spawn`. ALL coding work MUST go through `foundry spawn` or `foundry orchestrate`. No exceptions. No shortcuts.
2. **NEVER create branches manually** for Foundry work. `foundry spawn` creates isolated worktrees with `foundry/` branch prefixes. If a branch doesn't start with `foundry/`, it's not tracked.
3. **If Foundry errors**, diagnose and fix the error. Do NOT bypass Foundry. Report the error to Merlin if you can't fix it.
4. **One issue = one agent.** Check `foundry status` before spawning. If a task already exists for an issue, use `foundry check` or `foundry respawn`, not a new spawn.
5. **NEVER hardcode a backend.** Omit the model argument to use Foundry's configured default. `ENABLED_BACKENDS` in config controls which backends are available.

## Commands

```bash
foundry status                        # Dashboard (shows BACKEND column)
foundry scan <repo-path>              # Find `foundry`-labeled issues
foundry spawn <repo> <spec> [agent] --issue-number <N>  # Spawn agent on an issue
foundry check [task-id]               # Monitor agents, trigger reviews
foundry respawn <task-id>             # Retry a failed task
foundry orchestrate <repo> <spec>     # Route to best agent + spawn
foundry ask <task-id> <question>      # Bidirectional: ask agent a question, get reply
foundry steer <task-id> <msg>         # Redirect agent mid-flight
foundry peek <task-id>                # Structured JSON status (registry + live)
foundry kill <task-id>                # Stop a running agent
foundry cleanup                       # Archive completed tasks
foundry diagnose <task-id>            # Debug a stuck task
```

## Spawning from GitHub Issues

```bash
# ALWAYS use --issue-number so Foundry fetches the full issue body + comments
# Omit model to use the configured default (DEFAULT_MODEL in config)
foundry spawn ~/projects/org/repo "issue title" --issue-number 39 --topic
```

Without `--issue-number`, the agent gets zero context about the task.
Use `--topic` to create a dedicated Telegram thread for the task.

## Signal Architecture

The ACP orchestrator writes directly to the SQLite registry:
- **Completion**: `tasks.status` updated to `completed` or `failed` (no .done file needed)
- **Live status**: `tasks.checks.liveStatus` JSON with phase, tools, files modified
- **Usage limits**: detected automatically, task marked `exhausted`, Telegram alert sent
- **Steer**: via `foundry steer` or `foundry ask` (bidirectional)

## Cron Jobs

These are configured in OpenClaw (`cron/jobs.json`):
- **Foundry Agent Monitor** (hourly): `foundry check` only, zero AI tokens
- **Foundry Orchestrator** (every 2h): scan issues + spawn agents (uses DEFAULT_MODEL)
- **Foundry Night Build** (1:30 AM): scan + spawn up to 3 agents overnight
- **Foundry Daily Cleanup** (3 AM): archive + log rotation

## Configuration

- `DEFAULT_MODEL`: which backend to use when none specified (default: claude)
- `ENABLED_BACKENDS`: comma-separated list of available backends (e.g., `claude,gemini`)
- `MAX_RETRIES`: spawn attempts per task (default: 5)
- `MAX_REVIEW_FIXES`: review-fix cycles per attempt (default: 20)
- `AGENT_TIMEOUT`: seconds per agent run (default: 1800)

## Notifications

Telegram notifications on:
- Task completion (PR ready to merge)
- Task failure (budget exhausted)
- Usage limit hit (rate limit, quota exceeded, with backend name)
- Review cycles (all reviewers reported)
