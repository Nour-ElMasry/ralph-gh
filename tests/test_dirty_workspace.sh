#!/usr/bin/env bash

# test_dirty_workspace.sh — ralph must refuse to start on a workspace holding
# someone else's uncommitted changes, and must not refuse a resumed run's own.
#
# Regression (#1488, 2026-10-18): the user's uncommitted marketing files rode
# `ensure_latest_main` onto ralph/issue-1488, were committed with the slice,
# then reverted by the review pass, which removed them from the user's tree.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/date_utils.sh
source "$SCRIPT_DIR/lib/date_utils.sh"
# shellcheck source=../lib/utils.sh
source "$SCRIPT_DIR/lib/utils.sh"
# shellcheck source=../lib/branch_manager.sh
source "$SCRIPT_DIR/lib/branch_manager.sh"

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

# A repo on main with one committed file. Echoes its path.
setup_repo() {
    local repo=$1/repo
    git init --quiet -b main "$repo"
    git -C "$repo" config user.email t@t
    git -C "$repo" config user.name t
    echo one > "$repo/tracked.txt"
    git -C "$repo" add tracked.txt
    git -C "$repo" commit --quiet -m "initial"
    echo "$repo"
}

echo "workspace_foreign_changes"

tmp=$(mktemp -d)
repo=$(setup_repo "$tmp")
workspace_foreign_changes "$repo" >/dev/null
assert_eq "a clean main is not refused" "1" "$?"
rm -rf "$tmp"

tmp=$(mktemp -d)
repo=$(setup_repo "$tmp")
echo two > "$repo/tracked.txt"
assert_eq "a modified tracked file on main is reported" " M tracked.txt" "$(workspace_foreign_changes "$repo")"
rm -rf "$tmp"

tmp=$(mktemp -d)
repo=$(setup_repo "$tmp")
echo new > "$repo/untracked.txt"
assert_eq "an untracked file on main is reported" "?? untracked.txt" "$(workspace_foreign_changes "$repo")"
rm -rf "$tmp"

tmp=$(mktemp -d)
repo=$(setup_repo "$tmp")
git -C "$repo" checkout --quiet -b ralph/issue-7
echo two > "$repo/tracked.txt"
workspace_foreign_changes "$repo" >/dev/null
assert_eq "a resumed ralph branch's own changes are not refused" "1" "$?"
rm -rf "$tmp"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
