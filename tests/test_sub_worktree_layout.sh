#!/usr/bin/env bash

# test_sub_worktree_layout.sh — sub-worktrees must live beside the parent
# worktree, not inside it.
#
# Regression: with subs nested at <parent>/sub-<N>, a sub whose parent branch
# tracked `.env.example` got a stray copy of it at `sub-<N>/.env.example`
# (the env-file copy walked from the parent into the sub itself), the worker
# committed it, and the squash-merge was refused because the real `sub-<N>/`
# directory sat untracked in the parent's working tree. Every downstream sub
# was then marked failed.

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

get_issue_title() { echo "Test sub-issue"; }
export -f get_issue_title

git_t() { git -c user.email=t@t -c user.name=t "$@"; }

main() {
    local tmpdir
    tmpdir=$(mktemp -d -t ralph-subwt-test-XXXXXX)
    trap "rm -rf '$tmpdir'" EXIT
    export HOME="$tmpdir/home"
    mkdir -p "$HOME"

    local main_repo="$tmpdir/repo"
    git init --quiet -b main "$main_repo"
    git_t -C "$main_repo" commit --allow-empty -m "initial" --quiet

    WORKTREE_BASE="$main_repo/.ralph-workers"
    _RALPH_MAIN_WORKSPACE="$main_repo"
    local parent="$WORKTREE_BASE/issue-1"
    git -C "$main_repo" worktree add --quiet -b ralph/issue-1 "$parent" main

    # The parent branch tracks an env example, as a foundation slice would.
    echo "SETUP_TOKEN=" > "$parent/.env.example"
    git_t -C "$parent" add .env.example
    git_t -C "$parent" commit -m "feat(ralph): #2 - foundation" --quiet

    echo "=== Sub-worktree layout ==="
    sub_worktree_setup 1 3 ralph/issue-1 > /dev/null
    sub_worktree_setup 1 4 ralph/issue-1 > /dev/null

    local sub3
    sub3=$(sub_worktree_path 1 3)
    assert_eq "sub-worktree is a sibling of the parent" \
        "$WORKTREE_BASE/issue-1-sub-3" "$sub3"
    assert_eq "parent working tree stays clean with subs alive" \
        "" "$(git -C "$parent" status --porcelain)"
    assert_eq "no stray env files copied into the sub" \
        "" "$(git -C "$sub3" status --porcelain)"

    echo "=== Squash-merge with live sibling subs ==="
    echo "export const x = 1;" > "$sub3/feature.ts"
    git_t -C "$sub3" add -A
    git_t -C "$sub3" commit -m "add feature" --quiet

    local rc=0
    sub_worktree_merge 1 3 > /dev/null 2>&1 || rc=$?
    assert_eq "sub #3 squash-merges into the parent" "0" "$rc"
    assert_eq "merged tree has no nested sub paths" \
        "" "$(git -C "$parent" ls-tree -r --name-only HEAD | grep -E '^(sub-|issue-)' || true)"

    sub_worktree_cleanup 1 3 success > /dev/null 2>&1
    sub_worktree_cleanup 1 4 success > /dev/null 2>&1
    assert_eq "cleanup removes sibling sub-worktrees" \
        "no" "$([[ -e "$sub3" || -e "$(sub_worktree_path 1 4)" ]] && echo yes || echo no)"

    echo ""
    echo "=== Summary ==="
    echo "  Passed: $PASS"
    echo "  Failed: $FAIL"
    [[ $FAIL -eq 0 ]]
}

main "$@"
