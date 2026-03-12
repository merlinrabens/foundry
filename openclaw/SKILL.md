---
name: foundry
version: 1.1.0
description: Multi-agent code factory. Orchestrates AI coding agents (Codex, Claude, Gemini) — picking the best agent per task, monitoring progress via structured status, and steering mid-flight. Isolated git worktrees + ACP (Agent Client Protocol) with PID-based process management.
---

# Foundry Skill for OpenClaw

## HARD RULES

1. **NEVER spawn agents directly** via `claude`, `codex`, `gemini` CLI, ACP sub-agents, or `sessions_spawn`. ALL coding work MUST go through `foundry spawn` or `foundry orchestrate`. No exceptions. No shortcuts. No "quick path."
2. **NEVER create branches manually** for Foundry work. `foundry spawn` creates isolated worktrees with `foundry/` branch prefixes. If a branch doesn't start with `foundry/`, it's not tracked.
3. **If Foundry errors**, diagnose and fix the error. Do NOT bypass Foundry. Report the error to Merlin if you can't fix it.
4. **One issue = one agent.** Check `foundry status` before spawning. If a task already exists for an issue, use `foundry check` or `foundry respawn`, not a new spawn.

## Commands

```bash
foundry status                        # Dashboard of all tasks
foundry scan <repo-path>              # Find `foundry`-labeled issues
foundry spawn <repo> <spec> [agent] --issue-number <N>  # Spawn agent on an issue
foundry check [task-id]               # Monitor agents, trigger reviews
foundry respawn <task-id>             # Retry a failed task
foundry orchestrate <repo> <spec>     # Route to best agent + spawn
foundry cleanup                       # Archive completed tasks
foundry kill <task-id>                # Stop a running agent
foundry diagnose <task-id>            # Debug a stuck task
foundry peek <task-id>                # View agent's last output
foundry nudge <task-id>               # Unstick a stalled agent
```

## Spawning from GitHub Issues

```bash
# ALWAYS use --issue-number so Foundry fetches the full issue body + comments
foundry spawn ~/projects/org/repo issue-39 claude --issue-number 39
```

Without `--issue-number`, the agent gets zero context about the task.

## Cron Jobs

These are already configured in OpenClaw:
- **Foundry Orchestrator** (every 2h): `foundry check` + respawn failures
- **Foundry Night Build** (1:30 AM): cleanup + scan + spawn up to 3 agents
- **Foundry Daily Cleanup** (3 AM): archive + log rotation

## Notifications

Set `OPENCLAW_TG_BOT_TOKEN` and `TELEGRAM_CHAT_ID` env vars for Telegram notifications on:
- Task completion (PR ready to merge)
- Task failure (budget exhausted)
- Review cycles (all reviewers reported)
