#!/usr/bin/env bash

# test_stale_branch.sh — a parent worktree must not resume a branch whose PR
# already merged, nor one that has diverged from its remote.
#
# Regression (#1306, 2026-10-06): the local ralph/issue-1306 still pointed at
# the pre-review head while a reviewer's fixes sat only on origin and the PR
# had been squash-merged. The rerun reused the local branch, built three
# slices on stale code, and the final push was refused.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/date_utils.sh
source "$SCRIPT_DIR/lib/date_utils.sh"
# shellcheck source=../lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"
# shellcheck source=../lib/worktree_manager.sh
source "$SCRIPT_DIR/lib/worktree_manager.sh"

PASS=0
FAIL=0

assert_eq() {
    local name=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $name"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# The PR states `gh pr list --head <branch> --state all` reports.
PR_STATES=""
gh() { echo "$PR_STATES"; }
RALPH_GH_REPO="owner/repo"

# Builds origin + a clone with ralph/issue-1 on both, local one commit behind
# a reviewer's push. Echoes the clone path.
setup_repos() {
    local tmpdir=$1
    git init --quiet --bare -b main "$tmpdir/origin.git"
    git clone --quiet "$tmpdir/origin.git" "$tmpdir/repo" 2>/dev/null
    local repo="$tmpdir/repo"
    git -C "$repo" config user.email t@t
    git -C "$repo" config user.name t
    git -C "$repo" commit --allow-empty -m "initial" --quiet
    git -C "$repo" push --quiet origin main
    git -C "$repo" branch ralph/issue-1
    git -C "$repo" checkout --quiet ralph/issue-1
    git -C "$repo" commit --allow-empty -m "feat(ralph): #2 - slice" --quiet
    git -C "$repo" push --quiet origin ralph/issue-1
    git -C "$repo" checkout --quiet main
    echo "$repo"
}

reviewer_pushes_fix() {
    local tmpdir=$1
    git clone --quiet -b ralph/issue-1 "$tmpdir/origin.git" "$tmpdir/reviewer" 2>/dev/null
    git -C "$tmpdir/reviewer" -c user.email=r@r -c user.name=r commit --allow-empty -m "fix: review" --quiet
    git -C "$tmpdir/reviewer" push --quiet origin ralph/issue-1
}

run_create() {
    local repo=$1
    _RALPH_MAIN_WORKSPACE="$repo"
    WORKTREE_BASE="$repo/.ralph-workers"
    git -C "$repo" fetch --quiet origin
    local rc=0
    _worktree_create "$WORKTREE_BASE/issue-1" ralph/issue-1 main > /dev/null 2>&1 || rc=$?
    echo "$rc"
}

main() {
    local tmpdir repo
    tmpdir=$(mktemp -d -t ralph-stale-test-XXXXXX)
    trap "rm -rf '$tmpdir'" EXIT
    export HOME="$tmpdir/home"
    mkdir -p "$HOME"

    echo "=== Merged PR: start fresh from main ==="
    mkdir "$tmpdir/a"
    repo=$(setup_repos "$tmpdir/a")
    reviewer_pushes_fix "$tmpdir/a"
    PR_STATES="MERGED"
    assert_eq "worktree is created" "0" "$(run_create "$repo")"
    assert_eq "worktree starts at origin/main" \
        "$(git -C "$repo" rev-parse origin/main)" \
        "$(git -C "$repo/.ralph-workers/issue-1" rev-parse HEAD)"
    assert_eq "old local branch is archived" \
        "1" "$(git -C "$repo" branch --list 'ralph-archive/issue-1-*' | wc -l | tr -d ' ')"
    assert_eq "merged remote head is deleted" \
        "" "$(git -C "$repo" ls-remote origin ralph/issue-1)"

    echo "=== Open PR, local behind remote: fast-forward ==="
    mkdir "$tmpdir/b"
    repo=$(setup_repos "$tmpdir/b")
    reviewer_pushes_fix "$tmpdir/b"
    PR_STATES="OPEN"
    assert_eq "worktree is created" "0" "$(run_create "$repo")"
    assert_eq "worktree carries the reviewer's fix" \
        "fix: review" "$(git -C "$repo/.ralph-workers/issue-1" log -1 --format=%s)"

    echo "=== Open PR, local diverged from remote: refuse ==="
    mkdir "$tmpdir/c"
    repo=$(setup_repos "$tmpdir/c")
    reviewer_pushes_fix "$tmpdir/c"
    git -C "$repo" checkout --quiet ralph/issue-1
    git -C "$repo" commit --allow-empty -m "local only" --quiet
    git -C "$repo" checkout --quiet main
    PR_STATES="OPEN"
    assert_eq "setup is refused" "1" "$(run_create "$repo")"
    assert_eq "no worktree is created" \
        "no" "$([[ -e "$repo/.ralph-workers/issue-1" ]] && echo yes || echo no)"

    echo ""
    echo "=== Summary ==="
    echo "  Passed: $PASS"
    echo "  Failed: $FAIL"
    [[ $FAIL -eq 0 ]]
}

main "$@"
