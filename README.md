# ralph-gh

Autonomous GitHub issue worker powered by Claude Code CLI.

ralph-gh polls your GitHub repo for labeled parent issues, parses their task lists for sub-issues, works through them sequentially using Claude Code, and opens a PR when done.

## How it works

```
1. You create a parent issue with a task list:
   - [ ] #12 Add user validation
   - [ ] #13 Update API endpoint
   - [ ] #14 Write tests

2. You label it "ralph"

3. ralph-gh picks it up, creates a branch, and works each sub-issue

4. When done: PR opened, sub-issues closed, label removed
   On failure: Draft PR with partial work, comment explaining what went wrong
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (authenticated via Max subscription)
- [GitHub CLI](https://cli.github.com/) (`gh`, authenticated)
- `git`, `jq`

## Quick start

```bash
# Clone
git clone https://github.com/Nour-ElMasry/ralph-gh.git
cd ralph-gh

# Install
./install.sh

# Configure
$EDITOR ~/.ralph-gh/ralph-gh.conf
# Set RALPH_GH_REPO and RALPH_GH_WORKSPACE

# Create the label on your repo
./setup.sh owner/repo

# Run
~/.ralph-gh/ralph-gh.sh

# Or run in tmux (recommended)
tmux new -s ralph-gh '~/.ralph-gh/ralph-gh.sh'
```

## Configuration

### Global config (`~/.ralph-gh/ralph-gh.conf`)

| Variable | Default | Description |
|---|---|---|
| `RALPH_GH_REPO` | (required) | GitHub repo, e.g. `owner/repo` |
| `RALPH_GH_WORKSPACE` | (required) | Local path to repo clone |
| `RALPH_GH_LABEL` | `ralph` | Issue label that triggers automation |
| `RALPH_GH_POLL_INTERVAL` | `1800` | Seconds between polls (30 min) |
| `RALPH_GH_MAIN_BRANCH` | `main` | Base branch for PRs |
| `CLAUDE_TIMEOUT_MINUTES` | `15` | Max time per sub-issue |
| `CB_NO_PROGRESS_THRESHOLD` | `3` | Circuit breaker: open after N no-progress attempts |

### Per-project config

ralph-gh checks the workspace root for:

- **`.ralphrc`** - Project settings that override global config (same format)
- **`.ralph/PROMPT.md`** - Project-specific system prompt for Claude (tech stack, conventions, architecture)
- **`.ralph/AGENT.md`** - Build/test/run instructions (appended to prompt)

Config resolution: built-in defaults -> `~/.ralph-gh/ralph-gh.conf` -> `.ralphrc`

## Issue format

Parent issues must use GitHub task list syntax:

```markdown
## Description
Implement user authentication flow

## Tasks
- [ ] #12 Add user validation
- [ ] #13 Update API endpoint
- [ ] #14 Write tests
```

Each `- [ ] #N` references a sub-issue that ralph-gh will work on sequentially.

## Commands

```bash
ralph-gh.sh              # Start the poll loop
ralph-gh.sh --status     # Show current state
ralph-gh.sh --reset      # Reset state and circuit breaker
ralph-gh.sh --help       # Show help
```

## Architecture

```
ralph-gh.sh (orchestrator)
  |
  +-- lib/github_poller.sh    # Poll issues, parse task lists
  +-- lib/issue_worker.sh     # Claude Code invocation per sub-issue
  +-- lib/branch_manager.sh   # Git operations, PR creation
  +-- lib/state_manager.sh    # JSON state persistence
  +-- lib/circuit_breaker.sh  # Stagnation detection
  +-- lib/utils.sh            # Logging utilities
  +-- lib/date_utils.sh       # Cross-platform date helpers
```

### State management

State is stored in `<workspace>/.ralph-gh/state.json`:

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

### Double-processing prevention

1. `state.in_progress` acts as a lock during work
2. `state.processed` filters out completed parents
3. Label removal after PR - survives state loss

## Safety

- **Circuit breaker**: Stops after repeated failures (configurable threshold)
- **On failure**: Opens a draft PR with partial work, comments on parent issue
- **No auto-merge**: PRs are opened for human review
- **Label-based**: Only issues you explicitly label get worked on

## Credits

Inspired by [ralph-claude-code](https://github.com/frankbria/ralph-claude-code) by Frank Bria.

## License

MIT
