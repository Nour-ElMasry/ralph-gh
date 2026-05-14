#!/usr/bin/env bash

# worktree_manager.sh - Git worktree isolation for parallel ralph-gh workers
# Each targeted issue gets its own worktree so multiple ralphs can run concurrently.

# Base directory for all worktrees (inside the main repo, gitignored)
WORKTREE_BASE=""

# Saved main workspace path for restoration after cleanup
_RALPH_MAIN_WORKSPACE=""

# Set up an isolated worktree for a targeted issue.
# Creates the worktree, acquires a per-issue lock, and redirects all state globals.
# After this call, CWD is inside the worktree and all state paths point to it.
worktree_setup() {
    local issue_number=$1
    local main_branch=$2

    _RALPH_MAIN_WORKSPACE="$RALPH_GH_WORKSPACE"
    WORKTREE_BASE="$_RALPH_MAIN_WORKSPACE/.ralph-workers"
    local worktree_dir="$WORKTREE_BASE/issue-${issue_number}"
    local branch_name="ralph/issue-${issue_number}"

    mkdir -p "$WORKTREE_BASE"

    # Acquire per-issue lock (prevents duplicate workers on the same issue)
    local lock_file="$WORKTREE_BASE/.lock-${issue_number}"
    eval "exec 8>\"$lock_file\""
    if ! flock -n 8; then
        log_status "ERROR" "Issue #$issue_number is already being worked on by another worker (lock: $lock_file)"
        return 1
    fi

    # Fetch latest from remote so we have up-to-date refs
    log_status "INFO" "Fetching latest refs for worktree setup..."
    git -C "$_RALPH_MAIN_WORKSPACE" fetch origin 2>/dev/null || true

    if [[ -d "$worktree_dir" ]]; then
        # Worktree already exists — validate and reuse (resume case)
        if git -C "$worktree_dir" rev-parse --is-inside-work-tree &>/dev/null; then
            log_status "INFO" "Reusing existing worktree at $worktree_dir (resuming)"
        else
            # Corrupt worktree — remove and recreate
            log_status "WARN" "Corrupt worktree at $worktree_dir, recreating..."
            git -C "$_RALPH_MAIN_WORKSPACE" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
            _worktree_create "$worktree_dir" "$branch_name" "$main_branch"
        fi
    else
        _worktree_create "$worktree_dir" "$branch_name" "$main_branch"
    fi

    # Redirect state globals to an EXTERNAL directory (outside the worktree).
    # Keeping state inside the worktree meant Claude could wipe it by running
    # `git clean -fdx`, `pnpm clean`, or similar during a sub-issue — causing
    # mark_sub_complete and get_remaining_subs to silently return empty state.
    RALPH_GH_WORKSPACE="$worktree_dir"
    RALPH_GH_STATE_DIR="$HOME/.ralph-gh/runs/issue-${issue_number}"
    STATE_DIR="$RALPH_GH_STATE_DIR"
    STATE_FILE="$RALPH_GH_STATE_DIR/state.json"
    CB_STATE_FILE="$RALPH_GH_STATE_DIR/.circuit_breaker_state"
    LOG_DIR="$RALPH_GH_STATE_DIR/logs"
    mkdir -p "$LOG_DIR"

    cd "$worktree_dir"
    log_status "SUCCESS" "Worktree ready at $worktree_dir (state at $RALPH_GH_STATE_DIR)"
    return 0
}

# Internal: create a new worktree, handling branch-exists scenarios
_worktree_create() {
    local worktree_dir=$1
    local branch_name=$2
    local main_branch=$3

    # Check if branch exists locally or on remote
    if git -C "$_RALPH_MAIN_WORKSPACE" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
        # Branch exists locally — create worktree using it
        log_status "INFO" "Creating worktree with existing local branch $branch_name"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree add "$worktree_dir" "$branch_name" 2>/dev/null
    elif git -C "$_RALPH_MAIN_WORKSPACE" show-ref --verify --quiet "refs/remotes/origin/$branch_name" 2>/dev/null; then
        # Branch exists on remote — create worktree tracking it
        log_status "INFO" "Creating worktree from remote branch $branch_name"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree add "$worktree_dir" -b "$branch_name" "origin/$branch_name" 2>/dev/null
    else
        # Fresh branch from main
        log_status "INFO" "Creating worktree with new branch $branch_name from $main_branch"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree add "$worktree_dir" -b "$branch_name" "origin/$main_branch" 2>/dev/null
    fi
}

# Clean up a worktree after PR creation (success path)
worktree_cleanup() {
    local issue_number=$1

    local worktree_dir="$WORKTREE_BASE/issue-${issue_number}"
    local state_dir="$HOME/.ralph-gh/runs/issue-${issue_number}"

    # Return to main workspace
    cd "$_RALPH_MAIN_WORKSPACE" 2>/dev/null || cd "$HOME"

    # Remove the worktree
    if [[ -d "$worktree_dir" ]]; then
        log_status "INFO" "Cleaning up worktree at $worktree_dir"
        git -C "$_RALPH_MAIN_WORKSPACE" worktree remove "$worktree_dir" --force 2>/dev/null || rm -rf "$worktree_dir"
    fi

    # Remove the external state dir for this issue (logs + state.json)
    if [[ -d "$state_dir" ]]; then
        log_status "INFO" "Cleaning up state dir at $state_dir"
        rm -rf "$state_dir"
    fi

    # Release per-issue lock
    local lock_file="$WORKTREE_BASE/.lock-${issue_number}"
    rm -f "$lock_file"

    # Restore globals
    RALPH_GH_WORKSPACE="$_RALPH_MAIN_WORKSPACE"
    RALPH_GH_STATE_DIR="$_RALPH_MAIN_WORKSPACE/.ralph-gh"
    STATE_DIR="$RALPH_GH_STATE_DIR"
    STATE_FILE="$RALPH_GH_STATE_DIR/state.json"
    CB_STATE_FILE="$RALPH_GH_STATE_DIR/.circuit_breaker_state"
    LOG_DIR="$RALPH_GH_STATE_DIR/logs"

    log_status "INFO" "Worktree for issue #$issue_number cleaned up"
}

# Signal handler for SIGINT/SIGTERM during worktree work.
# Pushes partial work, opens draft PR, then cleans up.
worktree_cleanup_on_signal() {
    local issue_number=$1

    local worktree_dir="$WORKTREE_BASE/issue-${issue_number}"
    local branch_name="ralph/issue-${issue_number}"

    log_status "WARN" "Caught signal while working on issue #$issue_number in worktree"

    # Best-effort: commit any uncommitted work
    if [[ -d "$worktree_dir" ]]; then
        git -C "$worktree_dir" add -A -- ':!.ralph-gh' 2>/dev/null || true
        git -C "$worktree_dir" commit -m "wip(ralph): partial work on #$issue_number - interrupted" 2>/dev/null || true
        git -C "$worktree_dir" push origin "$branch_name" 2>/dev/null || true
    fi

    # Open draft PR with partial work (abort_group needs CWD to be in the worktree)
    if [[ -d "$worktree_dir" ]]; then
        cd "$worktree_dir" 2>/dev/null || true
        abort_group "$issue_number" "$branch_name" "Worker interrupted by signal" 2>/dev/null || true
    fi

    worktree_cleanup "$issue_number"
    exit 130
}

# =============================================================================
# Sub-worktrees for parallel execution within a parent PRD.
#
# Topology when a parent issue has parallel sub-issues:
#   <repo>/.ralph-workers/issue-<parent>/             ← parent worktree (existing)
#     ├── node_modules/                                ← installed once at parent
#     ├── sub-<sub_id_a>/                              ← branched off ralph/issue-<parent>
#     ├── sub-<sub_id_b>/                              ← branched off ralph/issue-<parent>
#     └── sub-<sub_id_c>/                              ← created AFTER deps merge
#
# `cp -al` copies node_modules from the parent worktree into each sub-worktree
# via hardlinks: zero disk overhead, ~3 s vs. ~2 min `pnpm install`.
# =============================================================================

# Set up a sub-worktree for one sub-issue. Branches `ralph/issue-<parent>-<sub>`
# off the current parent branch tip.
sub_worktree_setup() {
    local parent_issue=$1
    local sub_issue=$2
    local parent_branch=$3

    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    local sub_worktree="$parent_worktree/sub-${sub_issue}"
    local sub_branch="ralph/issue-${parent_issue}-${sub_issue}"

    if [[ -d "$sub_worktree" ]]; then
        log_status "WARN" "Sub-worktree already exists at $sub_worktree, removing"
        git -C "$parent_worktree" worktree remove "$sub_worktree" --force 2>/dev/null || rm -rf "$sub_worktree"
    fi

    log_status "INFO" "Creating sub-worktree for #$sub_issue from $parent_branch"
    if ! git -C "$parent_worktree" worktree add "$sub_worktree" -b "$sub_branch" "$parent_branch" 2>/dev/null; then
        # Resume case: branch already exists
        if git -C "$parent_worktree" show-ref --verify --quiet "refs/heads/$sub_branch"; then
            git -C "$parent_worktree" worktree add "$sub_worktree" "$sub_branch" 2>/dev/null
        else
            log_status "ERROR" "Failed to create sub-worktree for #$sub_issue"
            return 1
        fi
    fi

    # Hardlink-share node_modules. pnpm uses content-addressed store, so even
    # cross-worktree symlinks resolve into ~/.local/share/pnpm/store, not into
    # the parent worktree itself.
    if [[ -d "$parent_worktree/node_modules" ]]; then
        log_status "INFO" "Hardlink-sharing node_modules into sub-worktree #$sub_issue"
        cp -al "$parent_worktree/node_modules" "$sub_worktree/" 2>/dev/null || \
            log_status "WARN" "cp -al node_modules failed; sub-worker will need to install"
    fi

    # Hardlink any nested workspace node_modules (e.g. packages/database/node_modules
    # for generated Prisma client).
    while IFS= read -r nm; do
        local rel="${nm#$parent_worktree/}"
        local target_dir="$sub_worktree/$(dirname "$rel")"
        if [[ ! -e "$sub_worktree/$rel" && -d "$target_dir" ]]; then
            cp -al "$nm" "$sub_worktree/$rel" 2>/dev/null || true
        fi
    done < <(find "$parent_worktree" -maxdepth 4 -type d -name node_modules ! -path "$parent_worktree/node_modules" 2>/dev/null)

    # Manifest lives outside the worktree so `git clean` can't wipe it.
    local sub_state_dir="$HOME/.ralph-gh/runs/issue-${parent_issue}/sub-${sub_issue}"
    mkdir -p "$sub_state_dir/logs"
    cat > "$sub_state_dir/manifest.json" <<EOF
{
    "parent_issue": $parent_issue,
    "sub_issue": $sub_issue,
    "parent_branch": "$parent_branch",
    "sub_branch": "$sub_branch",
    "sub_worktree": "$sub_worktree",
    "created_at": "$(get_iso_timestamp)"
}
EOF

    log_status "SUCCESS" "Sub-worktree ready for #$sub_issue at $sub_worktree"
    return 0
}

sub_worktree_cleanup() {
    local parent_issue=$1
    local sub_issue=$2

    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    local sub_worktree="$parent_worktree/sub-${sub_issue}"
    local sub_state_dir="$HOME/.ralph-gh/runs/issue-${parent_issue}/sub-${sub_issue}"
    local sub_branch="ralph/issue-${parent_issue}-${sub_issue}"

    if [[ -d "$sub_worktree" ]]; then
        git -C "$parent_worktree" worktree remove "$sub_worktree" --force 2>/dev/null || rm -rf "$sub_worktree"
    fi
    # Delete the sub-branch: on success its work is captured by the squash
    # commit on the parent branch; on failure the worktree was already torn
    # down so the dangling ref is just clutter. Use -D (force) because the
    # branch is unmerged from git's POV (squash != merge).
    if git -C "$_RALPH_MAIN_WORKSPACE" show-ref --verify --quiet "refs/heads/$sub_branch" 2>/dev/null; then
        git -C "$_RALPH_MAIN_WORKSPACE" branch -D "$sub_branch" 2>/dev/null || true
    fi
    rm -rf "$sub_state_dir" 2>/dev/null || true
}

# Squash-merge a sub-branch into the parent branch. Distinguishes four outcomes
# via return code so callers can decide whether to invoke the reconciler:
#
#   0 = clean merge + commit landed
#   1 = real merge conflict (unmerged paths exist; conflicted paths on stdout)
#   2 = empty squash (sub-branch's work is already on parent — skip, don't reconcile)
#   3 = commit refused for non-conflict reasons (hook failure, dirty tree, etc.);
#       caller should NOT invoke reconciler — the failure isn't semantic.
#
# Uses --no-verify on the squash commit: pre-commit hooks are for human commits;
# ralph's squash is a robot-driven integration that re-runs lint via the
# post-merge verify pass anyway.
sub_worktree_merge() {
    local parent_issue=$1
    local sub_issue=$2

    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    local sub_branch="ralph/issue-${parent_issue}-${sub_issue}"

    local sub_title
    sub_title=$(get_issue_title "$RALPH_GH_REPO" "$sub_issue") || sub_title="Sub-issue $sub_issue"

    log_status "INFO" "Squash-merging $sub_branch into parent worktree"

    local merge_stderr
    merge_stderr=$(git -C "$parent_worktree" merge --squash "$sub_branch" 2>&1 >/dev/null)
    local merge_rc=$?

    if [[ $merge_rc -ne 0 ]]; then
        # Two cases here: real conflict (unmerged paths) or refused-to-start
        # (dirty tree, locked refs, etc.). Distinguish them.
        local conflicts
        conflicts=$(git -C "$parent_worktree" diff --name-only --diff-filter=U 2>/dev/null)
        if [[ -n "$conflicts" ]]; then
            log_status "WARN" "Merge conflict for #$sub_issue in: $conflicts"
            echo "$conflicts"
            return 1
        fi
        log_status "ERROR" "merge --squash for #$sub_issue refused (no conflict): $merge_stderr"
        # Try to leave the worktree in a sane state
        git -C "$parent_worktree" reset --hard HEAD 2>/dev/null || true
        return 3
    fi

    # merge --squash succeeded — check whether it actually staged anything.
    # If nothing's staged, the sub-branch's commits are already represented on
    # parent (or were no-ops); treat as a benign skip, not a reconcile case.
    if git -C "$parent_worktree" diff --cached --quiet 2>/dev/null; then
        log_status "INFO" "No changes from #$sub_issue squash — work already on parent or sub was empty"
        # `merge --abort` after `merge --squash` is a no-op (no MERGE_HEAD),
        # but reset --hard clears any stray un-staged residue.
        git -C "$parent_worktree" reset --hard HEAD 2>/dev/null || true
        return 2
    fi

    local commit_stderr
    commit_stderr=$(git -C "$parent_worktree" commit --no-verify \
        -m "feat(ralph): #${sub_issue} - ${sub_title}" 2>&1 >/dev/null)
    local commit_rc=$?
    if [[ $commit_rc -ne 0 ]]; then
        log_status "ERROR" "Squash commit refused for #$sub_issue: $commit_stderr"
        git -C "$parent_worktree" reset --hard HEAD 2>/dev/null || true
        return 3
    fi

    log_status "SUCCESS" "Squash-merged #$sub_issue into parent"
    return 0
}

# Check whether a squash commit for this sub already exists on the parent
# branch. Looks for `feat(ralph): #<sub>` in commit subjects since the merge
# base with origin/<main>. Used after a failed reconcile to decide whether
# the work was actually saved (Sonnet may commit then time out during verify).
sub_commit_is_on_parent() {
    local parent_issue=$1
    local sub_issue=$2
    local main_branch="${3:-${RALPH_GH_MAIN_BRANCH:-main}}"

    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    [[ -d "$parent_worktree" ]] || return 1

    local base
    base=$(git -C "$parent_worktree" merge-base HEAD "origin/$main_branch" 2>/dev/null) \
        || base=$(git -C "$parent_worktree" rev-parse "origin/$main_branch" 2>/dev/null) \
        || return 1

    git -C "$parent_worktree" log --format=%s "${base}..HEAD" 2>/dev/null \
        | grep -qE "^(feat|chore|fix)\(ralph\): #${sub_issue}( |\$|-)"
}

# Run post-merge verification (build + lint) from the parent worktree. Returns
# 0 if green, 1 if red. Caller invokes reconciler on red.
sub_worktree_verify_parent() {
    local parent_issue=$1
    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    local log_file="$HOME/.ralph-gh/runs/issue-${parent_issue}/post-merge-verify-$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$log_file")"

    log_status "INFO" "Running post-merge verification (build + lint) in $parent_worktree"
    if (cd "$parent_worktree" && portable_timeout 900s bash -c 'pnpm build && pnpm lint' < /dev/null > "$log_file" 2>&1); then
        log_status "SUCCESS" "Post-merge verification green"
        return 0
    fi

    log_status "WARN" "Post-merge verification failed (log: $log_file)"
    echo "$log_file"
    return 1
}

export -f worktree_setup worktree_cleanup worktree_cleanup_on_signal
export -f _worktree_create
export -f sub_worktree_setup sub_worktree_cleanup
export -f sub_worktree_merge sub_worktree_verify_parent sub_commit_is_on_parent
