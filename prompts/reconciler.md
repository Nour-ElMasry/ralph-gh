# Merge reconciliation task

You are resolving a merge that produced a conflict, a refused commit, or a post-merge build/lint failure. Two or more parallel sub-issues from a single PRD wrote to overlapping code, and the squash-merge into the parent integration branch needs cleanup.

You are running on a **bounded wall-clock budget** (default 15 minutes) inside `ralph-gh`. The orchestrator will kill you when the budget is exhausted. Plan accordingly: get the fix committed before you verify, not after, so that even a timeout preserves your work.

## Inputs

- `RECON_PARENT_ISSUE` — the parent PRD issue number
- `RECON_PARENT_BRANCH` — the integration branch (e.g. `ralph/issue-521`)
- `RECON_SUB_BRANCHES` — comma-separated list of sub-issue branches that were merged (e.g. `ralph/issue-521-522,ralph/issue-521-523`)
- `RECON_FAILURE_KIND` — `merge_conflict` or `post_merge_verify`
- `RECON_CONFLICT_FILES` — newline-separated list of files with conflict markers (only when `RECON_FAILURE_KIND=merge_conflict`; may be empty if the merge refused for non-conflict reasons such as a hung commit hook)
- `RECON_FAILURE_LOG_PATH` — path to a log file with the failure output (only when `RECON_FAILURE_KIND=post_merge_verify`)

You can read all of these with `echo "$RECON_PARENT_BRANCH"`, etc.

## Ordering rules

1. **Commit before you verify.** If you can produce a plausible fix, commit it immediately with `git commit --no-verify -m "..."` so the squash lands even if you time out. Don't try to run `pnpm build` first and *then* commit — a slow build can eat your whole budget.
2. **Skip pre-commit hooks (`--no-verify`).** The orchestrator runs lint as a separate post-merge pass; pre-commit hooks here are just duplicated work that can fail on unrelated files.
3. **Time-budget your verify.** If you decide to run `pnpm build && pnpm lint` to confirm green, only do so if more than half your budget remains. If less than half remains, commit your best fix, write your status block, and exit 0. The orchestrator re-runs verify after you exit anyway.

## What to do

### If `RECON_FAILURE_KIND=merge_conflict`

1. List the conflicted files: `echo "$RECON_CONFLICT_FILES"` and `git status`.
2. **If `git status` shows staged changes but no `MERGE_HEAD` and no unmerged paths**, the squash-merge actually succeeded but the *commit* step refused (often a pre-commit hook). Just `git commit --no-verify -m "feat(ralph): #<sub_id> - <short title>"` and you're done. Do NOT invent conflicts that don't exist.
3. Otherwise, for each conflicted file, read **both sides** of the conflict and the commit messages on each sub-branch involved (`git log --oneline <branch>` for each branch in `RECON_SUB_BRANCHES`). Both sides represent intentional work — your job is to **combine** them, not pick a winner.
4. Resolve each file by integrating both intents. If you genuinely cannot tell what to do, leave that file unresolved and exit non-zero with a one-line explanation.
5. `git add` the resolved files and `git commit --no-verify -m "chore(ralph): reconcile #<sub_a> and #<sub_b>"`.

### If `RECON_FAILURE_KIND=post_merge_verify`

1. Read the failure log: `cat "$RECON_FAILURE_LOG_PATH"`.
2. Identify the failure (broken build, type error, lint error). The merge itself was clean — failures here typically come from two branches that were independently correct but combined in an incompatible way (e.g. both added a field with different types to the same exported interface).
3. Fix the failure. Edit only what's necessary to restore green; do not refactor adjacent code. Do not add features.
4. Commit your fix immediately with `git commit --no-verify -m "fix(ralph): reconcile post-merge failure for #$RECON_PARENT_ISSUE"`. Do this **before** you run any verification — see "Ordering rules" above.
5. Only if more than half your budget remains, run `pnpm build && pnpm lint` to confirm. If still red, decide quickly: another small fix, or exit non-zero so the orchestrator can surface to a human.

## Hard constraints

- **Do not amend** commits on the sub-branches. Only add new commits on the current (parent integration) branch.
- **Do not touch unrelated files.** If a file isn't conflicted and isn't named in the failure log, don't modify it.
- **Do not add features.** Your job is reconciliation, not enhancement.
- **Do not run `pnpm test:e2e`** (slow and requires Docker). Run only `pnpm build && pnpm lint` (and only with budget headroom) plus the specific unit tests named in the failure log.
- **Always use `--no-verify` on `git commit`.** Pre-commit hooks here just burn budget on unrelated lint.

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
