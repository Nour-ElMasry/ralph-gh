# Merge reconciliation task

You are resolving a merge that produced a conflict or post-merge build/lint failure. Two or more parallel sub-issues from a single PRD wrote to overlapping code, and the squash-merge into the parent integration branch needs cleanup.

## Inputs

- `RECON_PARENT_ISSUE` — the parent PRD issue number
- `RECON_PARENT_BRANCH` — the integration branch (e.g. `ralph/issue-521`)
- `RECON_SUB_BRANCHES` — comma-separated list of sub-issue branches that were merged (e.g. `ralph/issue-521-522,ralph/issue-521-523`)
- `RECON_FAILURE_KIND` — either `merge_conflict` or `post_merge_verify`
- `RECON_CONFLICT_FILES` — newline-separated list of files with conflict markers (only set when `RECON_FAILURE_KIND=merge_conflict`)
- `RECON_FAILURE_LOG_PATH` — path to a log file with the failure output (only set when `RECON_FAILURE_KIND=post_merge_verify`)

You can read all of these with `echo "$RECON_PARENT_BRANCH"` etc.

## What to do

### If `RECON_FAILURE_KIND=merge_conflict`

1. List the conflicted files: `echo "$RECON_CONFLICT_FILES"` and `git status`.
2. For each conflicted file, read **both sides** of the conflict and the commit messages on each sub-branch involved (`git log --oneline <branch>` for each branch in `RECON_SUB_BRANCHES`). Both sides represent intentional work — your job is to **combine** them, not pick a winner.
3. Resolve each file by integrating both intents. If you genuinely cannot tell what to do, leave that file unresolved and exit non-zero with a one-line explanation.
4. `git add` the resolved files and `git commit -m "chore(ralph): reconcile #<sub_a> and #<sub_b>"`.

### If `RECON_FAILURE_KIND=post_merge_verify`

1. Read the failure log: `cat "$RECON_FAILURE_LOG_PATH"`.
2. Identify the failure (broken build, type error, lint error). The merge itself was clean — failures here typically come from two branches that were independently correct but combined in an incompatible way (e.g. both added a field with different types to the same exported interface).
3. Fix the failure. Edit only what's necessary to restore green; do not refactor adjacent code. Do not add features.
4. Re-run `pnpm build && pnpm lint` to confirm green, then commit with `git commit -m "fix(ralph): reconcile post-merge failure for #$RECON_PARENT_ISSUE"`.

## Hard constraints

- **Do not amend** commits on the sub-branches. Only add new commits on the current (parent integration) branch.
- **Do not touch unrelated files.** If a file isn't conflicted and isn't named in the failure log, don't modify it.
- **Do not add features.** Your job is reconciliation, not enhancement.
- **Do not run `pnpm test:e2e`** (slow and requires Docker). Run `pnpm build && pnpm lint` and the relevant unit tests if the failure log mentions them.
- **Time budget:** if you can't reconcile in one pass, exit non-zero rather than thrashing. The orchestrator will fall back to "abort batch" and surface the conflict to a human.

## Status report (REQUIRED at end of response)

```
---RALPH_STATUS---
STATUS: COMPLETE | BLOCKED
RECONCILE_KIND: merge_conflict | post_merge_verify
FILES_TOUCHED: <number>
VERIFICATION: build_pass | build_fail | not_run
RECOMMENDATION: <one line>
---END_RALPH_STATUS---
```
