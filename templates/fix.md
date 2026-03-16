# Fix Agent

A previous agent attempted this task but failed. Your job is to fix the specific issue.

## Original Task

{{TASK_CONTENT}}

## What Failed

{{FAILURE_REASON}}

## Failure Details

{{FAILURE_DETAILS}}

## Workflow

1. First, sync with main to resolve any merge conflicts:
   `git fetch origin main && git merge origin/main --no-edit`
   If there are conflicts, resolve them sensibly (prefer main for deleted files, keep your changes for new code).
2. Read the existing code the previous agent wrote
3. Read the failure details carefully — understand EXACTLY what went wrong
4. Fix the specific issue described above
5. Run tests and ensure everything passes
6. Commit with a DESCRIPTIVE message explaining what you actually fixed:
   `git add -A && git commit -m "fix: <describe the actual fix, not the error>"`
   Example: `git commit -m "fix: add missing return type to getUser query"`
   NOT: `git commit -m "fix: CI checks failed"`
7. Push: `git push origin HEAD`

## Rules

- Focus ONLY on fixing the failure. Don't refactor or add features.
- Run tests before pushing.
- Write a commit message that describes WHAT you fixed, not that something failed.
- If you can't fix it, commit what you can with a clear explanation in a TODO comment.
