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

ralph-gh is a background daemon that watches your GitHub issues. When you label one `ralph`, it wakes up, reads the issue, spins up [Claude Code](https://docs.anthropic.com/en/docs/claude-code), writes the code, and opens a PR. Then it goes back to sleep and waits for the next one.

It handles **standalone issues** (single tasks) and **parent issues with sub-task checklists** (sequential multi-step work on a single branch).

## How it works

```
                    You                                     ralph-gh
                     |                                          |
                     |  Create issue, label it "ralph"          |
                     |----------------------------------------->|
                     |                                          |
                     |                          Polls every 30m |
                     |                          Finds the issue |
                     |                          Creates branch  |
                     |                          Runs Claude Code|
                     |                          Commits changes |
                     |                          Pushes + opens PR|
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

ralph-gh works each `- [ ] #N` sequentially on a single branch. One PR for the whole group.

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

Create the label and start it up:

```bash
./setup.sh you/your-repo

# Run in tmux so it survives terminal closes
tmux new -s ralph-gh '~/.ralph-gh/ralph-gh.sh'
```

That's it. Label an issue `ralph` and watch it go.

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
| `RALPH_GH_POLL_INTERVAL` | `1800` | How often to check (seconds) |
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
ralph-gh              # Start the loop
ralph-gh --status     # What's it doing right now?
ralph-gh --pause      # Pause after current sub-issue completes
ralph-gh --resume     # Resume a paused instance
ralph-gh --kill       # Kill running instance and all child processes
ralph-gh --reset      # Clear state + circuit breaker
ralph-gh --help       # Show help
```

## Safety

ralph-gh is designed to be **conservative, not clever**.

- **Label-gated** — only touches issues you explicitly label. No surprises.
- **No auto-merge** — always opens a PR for human review. You decide what ships.
- **Circuit breaker** — if Claude gets stuck (no progress after N attempts), it stops, opens a draft PR with whatever it has, and comments on the issue explaining what went wrong.
- **Resumable** — kill the process mid-work, restart it, and it picks up where it left off from `state.json`.
- **Failure is loud** — on abort: draft PR + GitHub comment with the failure reason. The label stays so you can re-trigger after fixing the issue.

## Architecture

```
ralph-gh.sh                          The main loop: poll, dispatch, sleep, repeat
  |
  +-- lib/github_poller.sh           Talks to GitHub: find issues, parse task lists
  +-- lib/issue_worker.sh            Builds prompts, invokes Claude Code CLI
  +-- lib/branch_manager.sh          Git branch/commit/push/PR operations
  +-- lib/state_manager.sh           JSON state: what's in progress, what's done
  +-- lib/circuit_breaker.sh         Detects when Claude is spinning its wheels
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

1. **State lock** — `in_progress` prevents re-picking an active issue
2. **Processed list** — completed parents are filtered out of polls
3. **Label removal** — after a successful PR, the `ralph` label is removed. Even if state is lost, no double-processing.

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
