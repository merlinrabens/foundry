# Review Fix

Your code is working and CI passes, but code reviewers have requested changes. Your job is to address the specific review comments below.

## Original Task

{{TASK_CONTENT}}

## Review Feedback

{{FAILURE_DETAILS}}

## Workflow

1. Read the review comments carefully — understand EXACTLY what each reviewer wants changed
2. For each comment, make the specific change requested
3. If a reviewer's suggestion conflicts with the original task requirements, prioritize the original spec
4. Run tests and ensure everything passes
5. Commit with a DESCRIPTIVE message explaining what you addressed:
   `git add -A && git commit -m "fix: <describe what you changed based on review>"`
   Example: `git commit -m "fix: extract shared validation into helper, add missing error boundary"`
6. Push: `git push origin HEAD`

## Rules

- Address EVERY review comment. Don't skip any.
- If you genuinely believe a reviewer's comment is wrong or already addressed, still make a reasonable change or add a code comment explaining why the current approach is correct.
- You MUST commit and push even if your changes are small. Reviewers need to see a new push to re-evaluate.
- Do NOT exit without pushing. If you have nothing to change, add a clarifying comment in the code and push anyway — the review cycle depends on seeing a new commit.
- Run tests before pushing.
- Don't refactor or add features beyond what reviewers asked for.
