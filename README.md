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

### Per-repo settings

| File | Purpose |
|---|---|
| `.ralphrc` | Override any global setting for this repo |
| `.ralph/PROMPT.md` | System prompt — tech stack, conventions, architecture |
| `.ralph/AGENT.md` | Build, test, and run instructions |

**Priority:** defaults < global config < `.ralphrc` < environment variables

## Safety

Ralph is designed to be **conservative, not clever**.

| Principle | How |
|---|---|
| **Label-gated** | Only touches issues you explicitly label. No surprises. |
| **Never auto-merges** | Always opens a PR for human review. You decide what ships. |
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
  +-- lib/utils.sh                   Logging + cross-platform timeout
  +-- lib/date_utils.sh              Date helpers (Linux + macOS)
```

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
