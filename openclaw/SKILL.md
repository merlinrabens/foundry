---
name: foundry
version: 1.0.0
description: Multi-agent code factory. Orchestrates AI coding agents (Codex, Claude, Gemini) — picking the best agent per task, monitoring progress via structured status, and steering mid-flight. Isolated git worktrees + ACP (Agent Client Protocol) with PID-based process management.
---

# Foundry Skill for OpenClaw

## Commands

```bash
foundry status                        # Dashboard of all tasks
foundry scan <repo-path>              # Find `foundry`-labeled issues
foundry spawn <repo> <spec> [agent]   # Spawn agent on a spec
foundry check [task-id]               # Monitor agents, trigger reviews
foundry respawn <task-id>             # Retry a failed task
foundry orchestrate [repo]            # Full auto: scan + spawn + check
foundry cleanup                       # Archive completed tasks
foundry diagnose <task-id>            # Debug a stuck task
foundry peek <task-id>                # View agent's last output
foundry nudge <task-id>               # Unstick a stalled agent
```

## OpenClaw Integration

### Cron Jobs (add to OpenClaw cron config)

```json
{
  "name": "Foundry Check Loop",
  "schedule": { "kind": "cron", "expr": "2,32 * * * *", "tz": "YOUR_TIMEZONE" },
  "payload": { "kind": "agentTurn", "message": "Run: foundry check-all. Report any tasks that need attention." },
  "sessionTarget": "isolated"
}
```

```json
{
  "name": "Foundry Orchestrator",
  "schedule": { "kind": "cron", "expr": "5 */3 * * *", "tz": "YOUR_TIMEZONE" },
  "payload": { "kind": "agentTurn", "message": "Run: foundry orchestrate. Scan all repos for new specs/issues, spawn agents if slots available, check running agents." },
  "sessionTarget": "isolated"
}
```

### ACP Integration

Foundry agents can be spawned via ACP:

```bash
sessions_spawn --runtime acp --task "Build feature X per issue #6" --mode run
```

### Notifications

Set `OPENCLAW_TG_BOT_TOKEN` and `TELEGRAM_CHAT_ID` env vars for Telegram notifications on:
- Task completion (PR ready to merge)
- Task failure (budget exhausted)
- Review cycles (all reviewers reported)

## Setup

1. Install: `curl -fsSL https://raw.githubusercontent.com/merlinrabens/foundry/main/install.sh | bash`
2. Configure: `foundry setup` (interactive wizard — detects CLIs, checks OAuth sign-in)
3. Test: `bats tests/`
4. Add cron jobs to OpenClaw config
5. Update: `foundry update`
