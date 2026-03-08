# Foundry + Telegram Topics: Agent Notifications That Make Sense

> A guide for developers using Foundry (or considering it) who want to finally organize
> their AI agent updates in Telegram in a structured way.

---

## 1. What is Foundry?

Foundry is a **Multi-Agent Code Factory** — a CLI tool that coordinates AI agents
so they autonomously write, review, and fix code.

**How it works:**

1. You feed in a **GitHub Issue** or a **spec file**
2. Foundry spawns an **AI agent** (Claude, Codex, or Gemini) in an isolated Git worktree
3. The agent writes the code and creates a **Pull Request**
4. **3 AI reviewers** check the PR automatically (Claude, Codex, Gemini Code Assist)
5. On issues: automatic **fix loop** (agent gets feedback, fixes, pushes, reviewers re-check)
6. Result: a **merge-ready PR** waiting for you

**Numbers:**

- 89% success rate (agent delivers a usable PR)
- $2-8 per task (depending on complexity)
- Runs on a MacBook (no server needed)
- Up to 3 agents in parallel

```bash
# An agent that builds a dashboard:
foundry spawn ~/projects/my-app specs/backlog/add-dashboard.md

# Or simply as a text description:
foundry spawn ~/projects/my-app "Fix the login bug" codex
```

---

## 2. The Problem: Agent Spam in Chat

### Before: Chaos

Imagine you have **3 agents running in parallel**. Each sends updates:
- "CI passed" / "CI failed"
- "Review: changes requested"
- "Respawning (attempt 2/3)"
- "PR ready to merge"

That's easily **15-20 messages** per hour. **All in one chat.** Try scrolling through
to figure out which update belongs to which agent. Good luck.

### After: Structure

Each agent gets its own **Telegram Forum Topic** (thread). Updates land exactly
where they belong:

```
📱 Telegram Supergroup
├── General                          ← Short "spawned X" messages
├── aura-shopify/add-dashboard       ← All updates for Task 1
├── aura-shopify/fix-login-bug       ← All updates for Task 2
└── primal-meat-club/new-landing     ← All updates for Task 3
```

The **main chat** only gets a short notification:
> "Spawned `AURA-add-dashboard-a3f2` (codex) — tracking in topic"

Everything else goes into the respective thread.

---

## 3. How to Use It (Step by Step)

### Prerequisites

1. **Telegram Supergroup** with Topics/Forum enabled
   - Open group → Settings → Topics → enable
2. **Bot as admin** of the group (must be allowed to create topics)
3. `TG_CHAT_ID` must point to the supergroup (negative number, e.g. `-1001234567890`)

### Option A: Auto-create a new topic

```bash
foundry spawn ~/projects/my-app specs/backlog/add-dashboard.md --topic
```

**What happens:**

1. Foundry creates a Git **worktree** (isolated copy of the repo)
2. The agent starts (PID-based, in the background)
3. Foundry calls the Telegram Bot API: `createForumTopic` with the name `my-app/add-dashboard`
4. The topic ID is stored in the **SQLite registry** (`tg_topic_id` column)
5. First message in the topic: "Agent spawned: ... Backend: codex | Model: ..."
6. Short info in main chat: "Spawned X — tracking in topic"
7. All subsequent updates (CI, reviews, respawns) automatically go to the topic

### Option B: Use an existing topic

```bash
foundry spawn ~/projects/my-app "Fix the login bug" codex --topic-id 42
```

No new topic is created here. Instead, the provided `topic-id` is stored directly
in the registry. Useful when you:
- Already created a topic manually
- Want to bundle multiple tasks in one topic

### Option C: Without topics (as before)

```bash
foundry spawn ~/projects/my-app specs/backlog/add-dashboard.md
```

No `--topic` flag = everything goes to the main chat. Full backward compatibility.

---

## 4. Architecture (Simply Explained)

The feature consists of three parts:

### 4.1 Topic Creation (`core/logging.bash`)

```bash
tg_create_topic "my-app/add-dashboard"
# → Calls Telegram Bot API: createForumTopic
# → Returns the message_thread_id (e.g. "42")
```

Colors for topics can be specified:
- 🟢 Green (default): `7322096`
- 🟡 Yellow: `16766590`
- 🔴 Red: `13338331`
- 🔵 Blue: `9367192`

### 4.2 Persistence (`core/registry_sqlite.bash`)

The `tg_topic_id` is stored as a column in the SQLite database (`foundry.db`).
This means:

- Survives restarts
- Survives respawns (agent dies → gets restarted → uses the same topic)
- Queryable: `sqlite3 foundry.db "SELECT id, tg_topic_id FROM tasks WHERE tg_topic_id IS NOT NULL;"`

The migration is idempotent — on first run, the column is automatically added:

```sql
ALTER TABLE tasks ADD COLUMN tg_topic_id TEXT;
```

### 4.3 Smart Routing (`tg_notify_task`)

The core piece. A single function that decides **where** a message goes:

```
tg_notify_task(task_id, message)
│
├── Does the task have a tg_topic_id in the DB?
│   ├── YES → tg_notify_topic(topic_id, message)    ← Into the thread
│   └── NO  → tg_notify(message)                     ← Main chat (as before)
```

**All existing notification call sites** (`check.bash`, `check_helpers.bash`) use
`tg_notify_task()`. This means: CI updates, review status, respawns, ready-to-merge —
everything is automatically routed. No single caller needs to know whether topics are active or not.

---

## 5. Use Case Scenarios

### Solo Developer: 3 Features in Parallel

You're working on an app and want to simultaneously build a dashboard, an API endpoint,
and a bugfix:

```bash
foundry spawn ~/projects/app specs/backlog/dashboard.md --topic
foundry spawn ~/projects/app specs/backlog/api-endpoint.md --topic
foundry spawn ~/projects/app "Fix memory leak in worker" codex --topic
```

Result: 3 topics in Telegram. You can see at a glance where each agent stands.

### Team Lead: Morning Check

You sent off 3 agents in the evening. In the morning you check Telegram:

- Topic "app/dashboard" → Last message: **"PR ready to merge"** ✅
- Topic "app/api-endpoint" → Last message: **"CI failing [tests]"** → Agent fixed 3x, now stuck
- Topic "app/fix-memory-leak" → Last message: **"Respawning (attempt 2/3)"** → Still working

In 10 seconds you know exactly what's going on. Without topics you'd have to scroll through 40+ messages.

### Night Build: 1 AM Auto-Spawn

Foundry has a Night Build cron that spawns agents at 1 AM:

```
1:00 AM → Foundry spawns 3 agents from specs/backlog/ → 3 topics created
1:05 AM → All 3 working, topics filling with updates
7:00 AM → You wake up, 3 clean topics with the full history
```

Each topic shows the complete history:
1. Agent spawned
2. PR created
3. CI passed
4. Claude Review: changes requested
5. Auto-fix (review cycle 1/20)
6. All reviews passed
7. PR ready to merge

### Debugging: Why Did the Agent Fail?

Agent is in `failed` status. You open the topic and see:

```
Agent spawned: AURA-add-auth-x7k2
Backend: codex | Model: codex-mini-latest

CI failing [lint] — auto-fixing (attempt 2/3)

CI failing [tests] — auto-fixing (attempt 3/3)

Agent exhausted after 3 attempts: AURA-add-auth-x7k2. Needs human.
```

Immediately clear: Lint was the first problem, tests the second. The agent tried 3 times
and gave up. You know exactly where to start.

### Client Projects: Clean Separation

One topic per client repo. Updates from `client-a/feature` never mix with
`client-b/bugfix`. Ideal when you're managing multiple projects simultaneously.

---

## 6. Value for Others / Community

### Foundry is Open Source

```
github.com/merlinrabens/foundry
License: MIT
```

Anyone can use, fork, and customize it.

### What Problem Does the Topics Feature Solve?

**Agent spam becomes unusable at 3+ parallel agents.**

This is not a theoretical problem — it's the point where most people stop monitoring
their agents via Telegram and instead run `foundry status` manually. The topics feature
makes Telegram the **primary monitoring channel** again.

### Who Benefits Immediately?

Anyone who:
- Uses Foundry
- Has Telegram as a notification channel
- Runs more than 1-2 agents simultaneously

The feature is **opt-in** (`--topic` flag), so zero risk for existing users.

### Transferable Pattern

The architecture (`tg_notify_task` as a smart router) is a pattern that easily
transfers to other platforms:

| Platform        | Equivalent                         |
| --------------- | ---------------------------------- |
| Telegram        | Forum Topics (message_thread_id)   |
| Slack           | Threads (thread_ts)                |
| Discord         | Threads / Forum Channels           |
| Microsoft Teams | Channel Threads                    |

The code changes minimally: `tg_notify_topic` becomes `slack_reply_thread` etc.
The routing logic (`tg_notify_task`) stays identical.

---

## 7. Quick Reference

### Commands Cheat Sheet

```bash
# Spawn with a new topic
foundry spawn <repo-path> <spec-or-description> [model] --topic

# Spawn with an existing topic
foundry spawn <repo-path> <spec-or-description> [model] --topic-id <id>

# Spawn without topic (default behavior)
foundry spawn <repo-path> <spec-or-description> [model]

# Status of all tasks (incl. topic info)
foundry status

# Look up a task's topic ID
sqlite3 ~/.openclaw/workspace/scripts/foundry/foundry.db \
  "SELECT id, tg_topic_id FROM tasks WHERE tg_topic_id IS NOT NULL;"
```

### Config Variables

| Variable                | Description                                     | Where to set              |
| ----------------------- | ----------------------------------------------- | ------------------------- |
| `TG_CHAT_ID`           | Telegram Supergroup ID (e.g. `-1001234567890`)  | `config.env`              |
| `OPENCLAW_TG_BOT_TOKEN`| Bot token for the Telegram API                  | Environment variable      |

### Telegram Supergroup Setup

1. Create a Telegram group
2. Convert it to a **Supergroup** (Settings → Group Type)
3. Enable **Topics** (Settings → Topics)
4. Add your bot and make it an **Admin**
   - Bot needs: "Manage Topics" and "Post Messages" permissions
5. Find the Chat ID:
   ```bash
   # Send a message in the group, then:
   curl "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].message.chat.id'
   ```

### Troubleshooting

| Problem | Cause | Solution |
| ------- | ----- | -------- |
| "Failed to create topic" | Bot is not an admin | Make bot admin with "Manage Topics" permission |
| Topic created but messages don't arrive | `TG_CHAT_ID` is wrong | Check chat ID (must be negative number, `-100...`) |
| Updates go to main chat instead of topic | `--topic` flag forgotten | Use `foundry spawn ... --topic` |
| Topic lost on respawn | Should not happen | `tg_topic_id` is persistent in SQLite, survives respawns |
| `jq` error on topic creation | `jq` not installed | `brew install jq` |
| Bot can't create topics | Topics not enabled | Group → Settings → Enable Topics |

### Topic Colors (for Custom Use)

```bash
# Default (Green):
tg_create_topic "my-task" 7322096

# Yellow (e.g. for warnings):
tg_create_topic "my-task" 16766590

# Red (e.g. for critical tasks):
tg_create_topic "my-task" 13338331

# Blue:
tg_create_topic "my-task" 9367192
```

---

## Summary

| Feature | Status |
| ------- | ------ |
| `--topic` flag on `foundry spawn` | Live |
| `--topic-id` for existing topics | Live |
| `tg_notify_task` smart router | Live (all notifications) |
| `tg_topic_id` in SQLite registry | Live (persistent) |
| Topic creation via Bot API | Live |
| Jerry/Orchestrator `--topic` support | Not yet (topics manually or via `--topic-id`) |
| Slack/Discord threading | Not yet (pattern is transferable) |

**Bottom line:** A single `--topic` flag that turns chat chaos into structured agent threads.
Opt-in, zero breaking changes, immediately usable.
