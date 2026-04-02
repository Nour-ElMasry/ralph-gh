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

ralph-gh is a CLI tool that processes your GitHub issues. Label issues `ralph`, run `ralph-gh run`, and it picks them up, spins up [Claude Code](https://docs.anthropic.com/en/docs/claude-code), writes the code, and opens a PR for each one.

It handles **standalone issues** (single tasks) and **parent issues with sub-task checklists** (sequential multi-step work on a single branch). Need to work on multiple issues at once? Target specific issues and run them in parallel — each gets its own isolated git worktree.

## How it works

```
                    You                                     ralph-gh
                     |                                          |
                     |  Create issue, label it "ralph"          |
                     |                                          |
                     |  Run: ralph-gh run                       |
                     |----------------------------------------->|
                     |                                          |
                     |                        Finds all labeled |
                     |                          Creates branch  |
                     |                          Runs Claude Code|
                     |                          Commits changes |
                     |                          Checks off subs |
                     |                        Pushes + opens PR |
                     |                                          |
                     |  PR ready for review                     |
                     |<-----------------------------------------|
                     |                                          |
                     |  (You review, merge, ship)               |
                     |                                          |
```

### Two modes

**Standalone issue** — label any issue, ralph-gh works it directly:

```markdown
## Fix login button not responding on mobile

The submit button on /login doesn't fire the onClick handler on iOS Safari.
Probably a z-index or touch event issue.
```

**Parent issue with sub-tasks** — use GitHub's task list syntax to break it down:

```markdown
## Implement user auth flow

- [ ] #12 Add input validation to signup form
- [ ] #13 Create /api/auth/register endpoint
- [ ] #14 Write integration tests
```

ralph-gh works each `- [ ] #N` sequentially on a single branch. As each sub-issue completes, its checkbox is checked off (`- [x] #N`) in real time so you can track progress from GitHub. One PR for the whole group.

## Quick start

```bash
git clone https://github.com/Nour-ElMasry/ralph-gh.git
cd ralph-gh
./install.sh
```

Then configure it:

```bash
$EDITOR ~/.ralph-gh/ralph-gh.conf
```

```bash
# The two things you must set:
RALPH_GH_REPO="you/your-repo"
RALPH_GH_WORKSPACE="/path/to/local/clone"
```

Create the label and run:

```bash
./setup.sh you/your-repo

# Process all labeled issues
ralph-gh run
```

That's it. Label an issue `ralph`, run `ralph-gh run`, and watch it go.

### Uninstalling

```bash
./uninstall.sh
```

This removes `~/.ralph-gh/` and the `ralph-gh` symlink. Per-project files (`.ralph/`, `.ralph-gh/`, `.ralphrc`) in your repos are left untouched.

## Prerequisites

| Tool | Why |
|---|---|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | The brain. Must be authenticated (Max subscription, OAuth). |
| [GitHub CLI](https://cli.github.com/) (`gh`) | Reads issues, opens PRs, manages labels. Must be authenticated. |
| `git` | You know why. |
| `jq` | JSON parsing for state management and API responses. |

## Configuration

### Global (`~/.ralph-gh/ralph-gh.conf`)

| Variable | Default | What it does |
|---|---|---|
| `RALPH_GH_REPO` | *(required)* | Target repo (`owner/repo`) |
| `RALPH_GH_WORKSPACE` | *(required)* | Path to your local clone |
| `RALPH_GH_LABEL` | `ralph` | The magic label |
| `RALPH_GH_MAIN_BRANCH` | `main` | Base branch for PRs |
| `CLAUDE_TIMEOUT_MINUTES` | `15` | Max time Claude gets per sub-issue |
| `RALPH_GH_MAX_LOOPS_PER_ISSUE` | `5` | Max Claude invocations per sub-issue |
| `RALPH_GH_MAX_LOOPS_TOTAL` | `0` | Max total invocations per parent group (0 = unlimited) |
| `CB_NO_PROGRESS_THRESHOLD` | `3` | Circuit breaker trips after N stuck attempts |

### Per-project (in your repo root)

ralph-gh respects the same config files as [ralph-claude-code](https://github.com/frankbria/ralph-claude-code):

| File | Purpose |
|---|---|
| `.ralphrc` | Project-specific settings (overrides global config) |
| `.ralph/PROMPT.md` | System prompt for Claude — your tech stack, conventions, architecture |
| `.ralph/AGENT.md` | Build/test/run instructions (appended to the prompt) |

**Config priority:** built-in defaults < `~/.ralph-gh/ralph-gh.conf` < `.ralphrc`

## CLI

```bash
ralph-gh run              # Process all labeled issues sequentially
ralph-gh run 42           # Work on issue #42 in an isolated worktree
ralph-gh run 42 99        # Work on #42 then #99 (sequential, each in its own worktree)
ralph-gh run --label foo  # Override label for this run
ralph-gh --status         # What's it doing right now?
ralph-gh --kill           # Kill running instance and all child processes
ralph-gh --reset          # Clear state + circuit breaker
ralph-gh --help           # Show help
```

### Parallel processing

Target specific issues and run multiple instances simultaneously — each gets its own git worktree so there are no branch conflicts:

```bash
# Terminal 1
ralph-gh run 42

# Terminal 2
ralph-gh run 99
```

Each worker creates an isolated worktree at `.ralph-workers/issue-<N>/`, processes the issue, opens a PR, and cleans up after itself. Per-issue locks prevent accidentally running two workers on the same issue.

## Safety

ralph-gh is designed to be **conservative, not clever**.

- **Label-gated** — only touches issues you explicitly label. No surprises.
- **No auto-merge** — always opens a PR for human review. You decide what ships.
- **Circuit breaker** — if Claude gets stuck (no progress after N attempts), it stops, opens a draft PR with whatever it has, and comments on the issue explaining what went wrong.
- **Resumable** — if interrupted mid-work, the next `ralph-gh run` picks up where it left off from `state.json`.
- **Progress tracking** — sub-issue checkboxes are checked off in the parent issue as each one completes. Sub-issues are closed after the PR is opened.
- **Failure is loud** — on abort: draft PR + GitHub comment with the failure reason. The label stays so the next `ralph-gh run` can re-trigger after you fix the issue.

## Architecture

```
ralph-gh.sh                          Entry point: find labeled issues, process all, exit
  |
  +-- lib/github_poller.sh           Talks to GitHub: find issues, parse task lists
  +-- lib/issue_worker.sh            Builds prompts, invokes Claude Code CLI
  +-- lib/branch_manager.sh          Git branch/commit/push/PR operations
  +-- lib/state_manager.sh           JSON state: what's in progress, what's done
  +-- lib/circuit_breaker.sh         Detects when Claude is spinning its wheels
  +-- lib/worktree_manager.sh        Git worktree isolation for parallel workers
  +-- lib/utils.sh                   Logging, cross-platform timeout
  +-- lib/date_utils.sh              Date helpers that work on both Linux and macOS
```

### State

Lives at `<workspace>/.ralph-gh/state.json`:

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

### How it avoids doing the same work twice

1. **Label removal** — after a successful PR, the `ralph` label is removed. This is the primary dedup mechanism.
2. **State lock** — `in_progress` prevents re-picking an active issue
3. **Per-run processed list** — issues attempted in the current run (whether completed or aborted) are skipped for the remainder of that run. Cleared on next `ralph-gh run`.

## Garbage in, garbage out

ralph-gh is a wrapper around Claude Code. It is exactly as good as what you feed it.

**Your results depend on:**

- **Your issues** — vague issues get vague PRs. Write clear descriptions, acceptance criteria, and constraints. The more context you give, the less Claude has to guess.
- **Your `.ralph/PROMPT.md`** — this is Claude's understanding of your project. Tech stack, conventions, architecture, guard rails. A good system prompt is the difference between "it rewrote my app in a different framework" and "it followed our patterns perfectly."
- **Your codebase** — clean, well-structured code with clear patterns is easier for Claude to extend. If your code confuses humans, it will confuse Claude too.
- **Your slice granularity** — smaller, well-scoped sub-issues succeed more often than massive ones. If a sub-issue says "build the entire auth system," expect a draft PR.

ralph-gh won't turn bad issues into good code. It will turn good issues into good PRs — faster than you could type them yourself.

## Credits

Inspired by [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) by Frank Bria. Built with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic.

## License

MIT
