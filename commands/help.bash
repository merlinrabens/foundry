# commands/help.bash — Display help text

cmd_help() {
  cat << 'HELP'
Foundry — Multi-Agent Code Factory

COMMANDS
  setup                             Interactive config wizard (repos, agents, CI)
  spawn <repo> <spec|task> [model]  Launch agent in isolated worktree
  check [task-id]                   Monitor all agents (or one specific task)
  status                            Show task overview with check status
  attach <task-id>                  Stream agent's live log output
  logs <task-id>                    Tail agent log file
  kill <task-id>                    Stop a running agent
  steer <task-id> <msg>             Mid-course correction via ACP signal
  respawn <task-id> [--prompt-file]  Retry failed agent with failure context
  design <repo> <spec> [agent]      Gemini design -> agent pipeline
  diagnose [--fix]                  Self-repair infrastructure diagnostics
  patterns                          Show success/failure stats + cost tracking
  auto                              Proactive scan + spawn by priority score
  register <repo> <pr-number>       Track an existing PR for monitoring
  nudge <message>                   Handle CI review nudge (parse + targeted check)
  cleanup                           Remove completed worktrees + registry
  scan                              Find specs across known projects
  recommend <spec|task>             Suggest best model for a task
  queue                             Show priority-scored spec backlog
  update                            Self-update from upstream repo

EXAMPLES
  foundry spawn ~/projects/aura-shopify specs/backlog/05-dashboard.md
  foundry spawn ~/projects/growthpulse 'Add dark mode' claude-opus-4-6
  foundry spawn ~/projects/aura-shopify specs/04-admin.md codex:high
  foundry spawn ~/projects/aura-shopify specs/04-admin.md gemini
  foundry spawn ~/projects/aura-shopify specs/04-admin.md openclaw  # Jerry picks best
  foundry orchestrate ~/projects/aura-shopify specs/05-dashboard.md
  foundry peek aura-05-dashboard
  foundry design ~/projects/aura-shopify specs/05-dashboard.md codex:high
  foundry check
  foundry respawn aura-05-dashboard
  foundry register ~/projects/primal-meat-club/aura-shopify 884
  foundry steer aura-05-dashboard 'Focus on API first, not the UI'
  foundry recommend specs/backlog/05-dashboard.md
  foundry queue
  foundry patterns
  foundry auto
  foundry status
  foundry cleanup

MODEL ROUTING (three backends + Jerry routing)
  codex               Default workhorse — backend, refactors, bugs
  codex:high          Codex with high reasoning effort (recommended)
  codex:medium        Codex with medium reasoning effort
  claude-sonnet-4-6   Frontend, git ops, fast tasks, nuanced code
  claude-opus-4-6     Complex reasoning, architecture decisions
  gemini              Google Gemini (design sensibility, UI specs)
  gemini:model-name   Gemini with specific model
  openclaw            Jerry smart routing (auto-picks best backend)
  openclaw:codex      Jerry routing with backend hint
  openclaw:claude     Jerry routing with backend hint
  openclaw:gemini     Jerry routing with backend hint

ORCHESTRATION (Jerry as orchestrator)
  orchestrate <repo> <spec|task>   Jerry picks agent + spawns + JSON output
  peek <task-id>                   Structured JSON status (registry + live)
  steer-wait <task-id> <msg>       Steer + wait for response (up to 30s)

HOW IT WORKS
  1. spawn creates an isolated git worktree + ACP agent process
  2. Agent gets a focused one-shot prompt (just the spec, nothing else)
  3. Agent codes, tests, commits, pushes, creates PR, then exits
  4. Pre-flight validation runs lint/test locally before marking done
  5. Foundry Gate (self-hosted runner) reacts to GitHub events INSTANTLY:
     - CI completion → foundry check <task-id> (seconds, not minutes)
     - Review submitted → auto-respawn with review context
     - PR closed/merged → registry update
  6. check loop (3 min) = fallback for edge cases Gate misses
  7. Failed agents auto-respawn with failure context (up to 5 retries)
  8. Zero AI tokens burned on monitoring — it's all deterministic
  9. steer sends mid-flight direction changes via USR1 signal + JSON-RPC

CHECK STATUS (shown in status command)
  C = CI passed        R = Claude review
  K = Codex review     G = Gemini review    S = Synced
  Task is "ready" when CI passes and no reviewer has CHANGES_REQUESTED
HELP
}
