# Task

{{TASK_CONTENT}}

# Instructions

Complete this in ONE pass. No iteration loops.

1. Read CLAUDE.md and relevant code to understand patterns
2. Implement the complete task, following existing conventions
3. Run tests: fix any failures before committing
4. Commit: `git add -A && git commit -m "{{COMMIT_MSG}}"`
5. Push: `git push -u origin HEAD`
6. Create a PR:
   ```bash
   gh pr create --title "{{PR_TITLE}}" --base {{DEFAULT_BRANCH}} --body "$(cat <<'PRBODY'
   ## Summary
   [What and why — 2-3 sentences]

   ## Changes
   [Every file changed and what changed]

   ## Validation
   [Tests/checks run and results]
   PRBODY
   )"
   ```
   Replace ALL bracketed placeholders with real content.
7. Archive the spec if it came from backlog:
   ```bash
   [ -f "specs/backlog/$(basename '{{SPEC_PATH}}')" ] && mkdir -p specs/done && git mv "specs/backlog/$(basename '{{SPEC_PATH}}')" "specs/done/" && git commit -m "chore: archive completed spec" && git push
   ```

# Rules

- ONE logical commit, not many small ones
- Do NOT create tracking files (IMPLEMENTATION_PLAN.md, BUILD_STATUS.md, etc.)
- Do NOT loop waiting for CI — create the PR and exit
- If blocked, commit what you have with a TODO comment and move on
- If your changes touch any frontend files (*.tsx, *.css, *.vue, components/), include a screenshot in the PR description showing the visual change. Use Playwright to capture it:
  ```bash
  npx playwright screenshot --viewport-size=1440,900 http://localhost:3000/affected-page screenshot.png
  ```
  Upload it to the PR body or reference it in the commit.
