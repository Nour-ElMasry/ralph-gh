<p align="center">
  <h1 align="center">ralph-gh</h1>
  <p align="center"><strong>Your tireless AI intern that closes GitHub issues while you sleep.</strong></p>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#how-it-works">How It Works</a> &bull;
  <a href="#configuration">Configuration</a> &bull;
  <a href="#safety">Safety</a>
</p>

---

ralph-gh is a CLI that turns GitHub issues into pull requests. Label an issue, run one command, and [Claude Code](https://docs.anthropic.com/en/docs/claude-code) writes the code, commits it, and opens a PR for your review.

Works on **any repo** — just `cd` in and run. Handles single issues, multi-step task lists, and parallel work across isolated git worktrees.

## The backstory

It started, as most things do, at 3 AM - but not by choice.

My newborn had just woken up for the second time. I'm pacing the hallway, baby in one arm, phone in the other, scrolling through the fifteen GitHub issues I'd written earlier that day. Neatly scoped. The kind of issues that make you feel productive without actually *being* productive.

Somewhere between the third feeding and the fourth diaper change, I thought: "I'm already using Claude Code for everything. What if it could just... pick these up and do them while I'm on dad duty?"

I'd been using [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) by Frank Bria and loved the concept - label an issue, let AI work it. But I kept bumping into walls. One repo only. No parallel processing. I wanted to label three issues across two projects before the baby's next nap and come back to three PRs.

So I forked it. Then I rewrote most of it. Then I rewrote it again because the baby woke up and I lost my train of thought mid-refactor.

The result is ralph-gh - named after the intern archetype. Eager, tireless, occasionally needs supervision, but genuinely gets stuff done. Unlike a real intern, Ralph doesn't need coffee breaks, doesn't ask if the standup could've been a Slack message, and won't ghost you after two weeks for a better offer. Unlike a newborn, he sleeps when you tell him to.

He just branches, codes, commits, and PRs. Every. Single. Time.

Is it perfect? No. Will Ralph occasionally open a PR that makes you question the nature of consciousness? Yes. But he'll do it at 3 AM while you're up anyway, and that's more than most developers can say about their side projects.

## How it works

```
              You                                     ralph-gh
               |                                          |
               |  1. Create issue, add "ralph" label      |
               |                                          |
               |  2. ralph-gh run                         |
               |----------------------------------------->|
               |                                          |
               |                          Picks up issue  |
               |                          Creates branch  |
               |                        Invokes Claude AI |
               |                         Commits changes  |
               |                      Checks off progress |
               |                        Pushes & opens PR |
               |                                          |
               |  3. PR ready for review                  |
               |<-----------------------------------------|
               |                                          |
               |  4. You review, merge, ship              |
               |                                          |
```

### Issue types

<details>
<summary><strong>Standalone issue</strong> — one task, one PR</summary>

```markdown
## Fix login button not responding on mobile

The submit button on /login doesn't fire the onClick handler on iOS Safari.
Probably a z-index or touch event issue.
```

Label it `ralph`, run `ralph-gh run`, get a PR.

</details>

<details>
<summary><strong>Parent issue with sub-tasks</strong> — multiple steps, one branch, one PR</summary>

```markdown
## Implement user auth flow

- [ ] #12 Add input validation to signup form
- [ ] #13 Create /api/auth/register endpoint
- [ ] #14 Write integration tests
```

Ralph works each `- [ ] #N` sequentially. As each completes, its checkbox is checked off in real time on GitHub so you can track progress. One PR for the whole group.

</details>

<details>
<summary><strong>Parallel issues</strong> — multiple issues, multiple worktrees, simultaneous</summary>

```bash
# Terminal 1                    # Terminal 2
ralph-gh run 42                 ralph-gh run 99
```

Each gets its own isolated git worktree. No branch conflicts. Per-issue locks prevent duplicates. Worktrees are cleaned up after PR creation.

</details>

## Quick start

**Install:**

```bash
git clone https://github.com/Nour-ElMasry/ralph-gh.git
cd ralph-gh && ./install.sh
```

**Set up a repo:**

```bash
cd /path/to/your/repo
ralph-gh setup                  # Creates the 'ralph' label (auto-detects from git remote)
```

**Run:**

```bash
ralph-gh run                    # Poll for all labeled issues
ralph-gh run 42                 # Target a specific issue
```

That's it. No config files to edit. Repo and workspace are auto-detected from your current directory.

> **Tip:** Add a `.ralph/PROMPT.md` to your repo with your tech stack, conventions, and architecture. This is the single biggest lever for PR quality.

## Prerequisites

| Tool | Purpose |
|---|---|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | The AI that writes the code. Must be authenticated. |
| [GitHub CLI](https://cli.github.com/) (`gh`) | Reads issues, opens PRs, manages labels. Must be authenticated. |
| `git` | Version control. |
| `jq` | JSON parsing for state management. |

## CLI

All commands auto-detect repo and workspace from your current directory.

| Command | Description |
|---|---|
| `ralph-gh run` | Process all labeled issues sequentially |
| `ralph-gh run 42` | Work on issue #42 in an isolated worktree |
| `ralph-gh run 42 99` | Work on #42 then #99, each in its own worktree |
| `ralph-gh run --label foo` | Override the trigger label for this run |
| `ralph-gh setup` | Create the `ralph` label on the current repo |
| `ralph-gh --status` | Show current status |
| `ralph-gh --stats` | Per-parent telemetry: loops, turns, cost, gate failures (`--stats --all` for every repo) |
| `ralph-gh --kill` | Kill running instance and all child processes |
| `ralph-gh --reset` | Clear state and circuit breaker |

### Parallel processing

Run multiple instances in separate terminals — each gets its own git worktree:

```bash
ralph-gh run 42 &               # Background
ralph-gh run 99                  # Foreground
```

## Configuration

### Auto-detection

Repo and workspace are detected automatically from your current directory:

- **Repo** — parsed from `git remote get-url origin` (supports SSH and HTTPS)
- **Workspace** — resolved via `git rev-parse --show-toplevel`

No global config needed to get started.

### Global settings (`~/.ralph-gh/ralph-gh.conf`)

Optional. Applies across all repos:

| Variable | Default | Description |
|---|---|---|
| `RALPH_GH_LABEL` | `ralph` | Label that triggers automation |
| `RALPH_GH_MAIN_BRANCH` | `main` | Base branch for PRs |
| `CLAUDE_TIMEOUT_MINUTES` | `15` | Max time per sub-issue |
| `RALPH_GH_MAX_LOOPS_PER_ISSUE` | `5` | Max retries per sub-issue |
| `RALPH_GH_MAX_LOOPS_TOTAL` | `0` | Max total retries per parent (0 = unlimited) |
| `CB_NO_PROGRESS_THRESHOLD` | `3` | Circuit breaker opens after N stuck attempts |
| `RALPH_GH_MODEL` | `$ANTHROPIC_MODEL`, then `claude-opus-5-5` | Implementation model |
| `RALPH_GH_VERIFIER_MODEL` | `claude-sonnet-5` | Independent read-only verifier |
| `RALPH_GH_REVIEW_MODEL` | `claude-sonnet-5` | Pre-PR review pass |
| `RALPH_GH_FALLBACK_MODEL` | `claude-sonnet-5` | Used when the primary model is overloaded |
| `RALPH_GH_PERMISSION_MODE` | `auto` | Claude Code permission mode for unattended runs |
| `RALPH_GH_DENY_RULES` | force-push, reset, clean, PR/issue mutation, … | Hard deny list auto mode cannot override |
| `RALPH_GH_VERIFY_CMD` | `.ralph/verify.sh` if present | Test/build command the shell runs after every turn |
| `RALPH_GH_VERIFIER_ENABLED` | `1` | Run the independent verifier gate |
| `RALPH_GH_TELEMETRY_FILE` | `~/.ralph-gh/telemetry.jsonl` | Run records; read with `ralph-gh --stats` |
| `RALPH_GH_CGROUP` | `1` | Re-exec every run inside a bounded systemd slice (`0` = uncapped) |
| `RALPH_GH_CGROUP_SLICE` | `ralph.slice` | The slice all concurrent runs share |
| `RALPH_GH_MEMORY_MAX` | `auto` | Memory ceiling for the whole slice, not per run; `auto` = 75% of RAM |
| `RALPH_GH_MEMORY_SWAP_MAX` | `0` | Swap the slice may use; `0` fails fast instead of thrashing |
| `RALPH_GH_CPU_WEIGHT` | `50` | CPU weight of the slice (default unit weight is 100) |

**Resource caps.** A run is a Claude session plus whatever it launches — test
workers, typechecks, builds — and three runs side by side once took down a
whole WSL machine. So `ralph-gh run` re-executes itself under
`systemd-run --user --scope --slice=ralph.slice`, and the slice carries the
memory and CPU limits. Runs share the ceiling; when it is hit the kernel kills
the largest process *inside the slice* (a test worker, a build) and that one
command fails, while the rest of the machine stays usable. The scope carries
`OOMPolicy=continue`, so that single kill does not take the run down with it
(systemd's default `stop` would SIGTERM the whole run — and since the victim
is picked from the entire slice, one run's build spike could abort another).
Needs a user systemd manager (Linux, WSL2 with systemd on); elsewhere the run
proceeds uncapped with a `WARN`.

### Per-repo settings

| File | Purpose |
|---|---|
| `.ralphrc` | Override any global setting for this repo |
| `.ralph/PROMPT.md` | System prompt (sent via `--append-system-prompt-file`) — tech stack, conventions, architecture |
| `.ralph/AGENT.md` | Build, test, and run instructions (injected into the task prompt) |
| `.ralph/verify.sh` | Test/build oracle the **shell** runs after every Claude turn. Exit 0 = green. Receives `RALPH_SUB_START_REF` to scope to the sub-issue's diff. Without it the verify gate is skipped with a warning. |

**Priority:** defaults < global config < `.ralphrc` < environment variables

## QA mode

`ralph-gh qa [--scenarios QA-NN.MM,...] [ISSUE ...]` executes test plans instead of implementing them. A plan is an open issue labelled `ralph` + `qa` whose scenarios look like `- [ ] **QA-05.01** <behaviour>`. With no arguments it runs every such plan in programme order (`QA-00`, `QA-01`, …, `QA-18a`, lettered tracks like `QA-H1` last). A parent issue argument expands to the unchecked plans in its `## Sub-Issues` list. `ralph-gh run` hands `qa` issues over to this mode, and its label poll never picks them up.

Per run:

1. The shell checks out `origin/main` at `.ralph-workers/qa-stack` and runs `$RALPH_QA_STACK_CMD up`. That checkout sits outside every plan worktree, so the per-turn orphan reaper never kills the stack.
2. For each plan, it runs `$RALPH_QA_STACK_CMD reset --seed $RALPH_QA_SEED`, then gives the model the plan, with `.ralph/QA_PROMPT.md` as its system prompt and a structured schema. The model may not file issues, comment, commit or push.
3. The gate is **every scenario executed with evidence**: PASS/FAIL need an evidence file that exists under `$QA_EVIDENCE_DIR`, FAIL needs a complete bug, BLOCKED needs `blocked_by`. The gate does not require scenarios to pass, so a failing product never loops the model.
4. The shell then:
   - redacts the evidence (`lib/qa_redact.py`: session cookies, CSRF and form-session headers, `Authorization`, JWTs, API and Stripe keys, token-named fields and query parameters, `curl -u` credentials, inside trace zips too; an unreadable zip is dropped) and pushes it to the orphan `qa-evidence` branch. No `python3`, no publish. The model's summaries and bug text pass the same redactor before they reach an issue;
   - files one bug per new FAIL (`bug`, `qa-found`, `sev:<blocker|major|minor>`), or comments on the open bug the model named as a duplicate;
   - posts a proof comment (verdict table plus inline screenshots);
   - ticks the PASS scenario boxes and rewrites the plan's `## Blocked by` list.
5. An all-green plan is closed and checked off on its `Parent QA #N`. Otherwise it stays open without the `ralph` label until a human re-adds it, and the whole plan reruns.

**Targeted re-tests.** `ralph-gh qa --scenarios QA-07.24,QA-05.15 [ISSUE ...]` (or `RALPH_QA_SCENARIOS`) runs only those scenarios. Plans holding none of them are skipped; labels and the open-state rules are unchanged. The model is told to set up any prerequisite state itself from the fresh seed. Gate, tally, proof ("Targeted re-test: N of M scenarios") and bug filing cover the subset only. The body rewrite touches only the subset's boxes and merges its bugs into the existing `## Blocked by` list. The plan closes when this run is clean **and** every scenario box in the body is ticked. Each filed bug ends with the exact re-test command for its scenario.

**Token economy.** The QA rules tell the model to keep bulky output (curl bodies, psql, logs, Mailpit, Playwright) in files and read back only the lines it needs. They also tell it to delegate scenarios, one at a time in the foreground, to subagents: mechanical assertions go to `RALPH_QA_SCENARIO_MODEL`, and judgment calls (design, copy, exploratory security) go to `RALPH_QA_JUDGE_MODEL`. A cheap-model FAIL is reproduced on the judge model before it is reported.

A smoke plan (`RALPH_QA_SMOKE_PLAN_ID`, default `QA-00`) that is not green stops the run. So does a broken stack.

| Variable | Default | |
|---|---|---|
| `RALPH_QA_LABEL` | `qa` | Second label that marks a plan |
| `RALPH_QA_SKIP_LABELS` | `hitl` | Plans carrying any of these never run |
| `RALPH_QA_STACK_CMD` | `scripts/qa-stack.sh` | Must support `up` and `reset --seed <name>` |
| `RALPH_QA_ENV_FILE` | — | Secrets for the stack (e.g. a Stripe test key), exported as `QA_ENV_FILE` to the stack and every QA turn |
| `RALPH_QA_MAX_LOOPS` | `4` | Turns per plan before unfinished scenarios are reported NOT RUN |
| `RALPH_QA_TIMEOUT_MINUTES` | `CLAUDE_TIMEOUT_MINUTES` | Per-turn wall clock |
| `RALPH_QA_EVIDENCE_BRANCH` | `qa-evidence` | Orphan branch for screenshots and traces |
| `RALPH_QA_EVIDENCE_MAX_MB` | `25` | Larger files are not published |
| `RALPH_QA_SCENARIOS` | — | Comma-separated scenario ids for a targeted re-test (`--scenarios` sets it) |
| `RALPH_QA_SCENARIO_MODEL` | `sonnet` | Subagent model for mechanical scenarios |
| `RALPH_QA_JUDGE_MODEL` | `opus` | Subagent model for judgment scenarios and FAIL reproduction |
| `RALPH_QA_ALLOWED_TOOLS` | curl, jq, node, pnpm, npx, gh issue list/view, stripe, k6, the stack command | Pre-approved tools for QA turns |

## Safety

Ralph is designed to be **conservative, not clever**.

| Principle | How |
|---|---|
| **Label-gated** | Only touches issues you explicitly label. No surprises. |
| **Never auto-merges** | Always opens a PR for human review. You decide what ships. |
| **Three gates per sub-issue** | The model's structured report, then the shell running your tests/build, then a separate read-only Claude session grading the diff against each acceptance criterion. Any red re-invokes the implementer with the failure as context. The implementer never grades itself. |
| **Hard deny list** | Runs in auto permission mode (classifier-approved tool calls, nothing blocks on a human) with a deny list for force-push, reset, clean, branch switching, and PR/issue mutation that auto mode cannot override. |
| **Circuit breaker** | Stops after N stuck attempts. Opens a draft PR with partial work. |
| **Resumable** | Interrupted mid-work? Next run picks up where it left off. |
| **Live progress** | Sub-issue checkboxes update in real time on GitHub. |
| **Loud failures** | On abort: draft PR + GitHub comment with the failure reason. Label kept for retry. |

## Architecture

```
ralph-gh.sh                          CLI + orchestration
  |
  +-- lib/github_poller.sh           GitHub API: issues, task lists, labels
  +-- lib/issue_worker.sh            Prompt building + Claude Code invocation
  +-- lib/branch_manager.sh          Git: branch, commit, push, PR
  +-- lib/state_manager.sh           JSON state persistence
  +-- lib/circuit_breaker.sh         Stagnation detection (Nygard pattern)
  +-- lib/worktree_manager.sh        Worktree isolation for parallel workers
  +-- lib/claude_runner.sh           The one place `claude -p` is invoked (flags, deny list, schema, telemetry)
  +-- lib/verify_gate.sh             Shell test/build oracle + independent verifier session
  +-- lib/telemetry.sh               Append-only run records (~/.ralph-gh/telemetry.jsonl) + --stats
  +-- lib/utils.sh                   Logging + cross-platform timeout
  +-- lib/date_utils.sh              Date helpers (Linux + macOS)
```

### The loop, per sub-issue

```
claude -p  (implementer, structured JSON report)
   |
   +-- 1. acceptance gate   parse the report: every checklist item met, with evidence?
   +-- 2. verify gate       shell runs .ralph/verify.sh (tests + build) — authoritative red/green
   +-- 3. verifier gate     fresh read-only claude -p (Sonnet) grades the diff per criterion
   |
   any red --> re-invoke the implementer (same session) with the failure as context
   all green --> commit, tick the checkbox on GitHub, next sub-issue
```

Retries are bounded by `RALPH_GH_MAX_LOOPS_PER_ISSUE` and the circuit breaker. Every Claude call and gate verdict is one line in the telemetry file; `ralph-gh --stats` summarises loops, turns, cost and gate failures per parent.

<details>
<summary><strong>State file</strong></summary>

Lives at `<repo>/.ralph-gh/state.json`:

```json
{
  "in_progress": {
    "parent": 10,
    "branch": "ralph/issue-10",
    "completed_subs": [12],
    "remaining_subs": [13, 14]
  },
  "processed": [7, 8, 9],
  "last_poll": "2026-03-25T10:00:00+00:00"
}
```

</details>

<details>
<summary><strong>Deduplication</strong></summary>

1. **Label removal** — after PR, the `ralph` label is removed (primary mechanism)
2. **State lock** — `in_progress` prevents re-picking an active issue
3. **Per-run processed list** — attempted issues are skipped for the rest of the run

</details>

## Getting the best results

Ralph is a wrapper around Claude Code. The quality of the output depends entirely on the quality of the input.

- **Write clear issues.** Vague issues get vague PRs. Include descriptions, acceptance criteria, and constraints.
- **Invest in `.ralph/PROMPT.md`.** This is Claude's understanding of your project. A good system prompt is the difference between "it rewrote my app in a different framework" and "it followed our patterns perfectly."
- **Keep your codebase clean.** If your code confuses humans, it will confuse Claude.
- **Slice small.** Smaller, well-scoped sub-issues succeed more often than large ones. "Build the entire auth system" will get you a draft PR. "Add email validation to the signup form" will get you a mergeable one.

## Uninstalling

```bash
./uninstall.sh
```

Removes `~/.ralph-gh/` and the `ralph-gh` symlink. Per-project files (`.ralph/`, `.ralph-gh/`, `.ralphrc`) are left untouched.

## Credits

Inspired by [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) by Frank Bria. Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic.

## License

MIT
