#!/bin/bash
# lib/model_routing.bash — Model string → backend resolution
[[ -n "${_LIB_MODEL_ROUTING_LOADED:-}" ]] && return 0
_LIB_MODEL_ROUTING_LOADED=1

# detect_model_backend <model_string>
# Resolves a user-facing model string (e.g. "codex", "codex:medium", "claude", "claude-complex", "gemini", "gemini:custom-model")
# into concrete backend + model + reasoning settings.
#
# Sets these variables in caller's scope:
#   MODEL_OUT          — resolved model name (e.g. "gpt-5.3-codex", "claude-sonnet-4-6")
#   AGENT_BACKEND_OUT  — backend type: "claude", "codex", or "gemini"
#   CODEX_REASONING_OUT — codex reasoning level (only meaningful for codex backend)
#   GEMINI_MODEL_OUT   — resolved gemini model (only meaningful for gemini backend)
detect_model_backend() {
  local input="$1"
  AGENT_BACKEND_OUT="claude"
  CODEX_REASONING_OUT="${CODEX_REASONING:-high}"
  GEMINI_MODEL_OUT="${GEMINI_MODEL:-gemini-3.5-pro}"
  MODEL_OUT="$input"

  if [[ "$input" == openclaw* ]]; then
    AGENT_BACKEND_OUT="auto"   # Meta-backend — resolved at spawn time by _jerry_select_agent
    if [[ "$input" == *:* ]]; then
      MODEL_OUT="${input#*:}"   # Hint: openclaw:codex → model=codex (Foundry respects hints)
    else
      MODEL_OUT="auto"          # Let Foundry pick the best backend
    fi
  elif [[ "$input" == codex* ]]; then
    AGENT_BACKEND_OUT="codex"
    [[ "$input" == *:* ]] && CODEX_REASONING_OUT="${input#*:}"
    MODEL_OUT="${CODEX_MODEL:-gpt-5.3-codex}"
  elif [[ "$input" == gemini* ]]; then
    AGENT_BACKEND_OUT="gemini"
    [[ "$input" == *:* ]] && GEMINI_MODEL_OUT="${input#*:}"
    MODEL_OUT="$GEMINI_MODEL_OUT"
  elif [[ "$input" == "claude" ]]; then
    MODEL_OUT="${CLAUDE_DEFAULT:-claude-sonnet-4-6}"
  elif [[ "$input" == "claude-complex" ]]; then
    MODEL_OUT="${CLAUDE_COMPLEX:-claude-opus-4-6}"
  fi
}
