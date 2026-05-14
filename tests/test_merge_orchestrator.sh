#!/usr/bin/env bash

# test_merge_orchestrator.sh — exercises sub_worktree_merge and
# sub_commit_is_on_parent against a throwaway git repo.
#
# Runs the four merge outcomes the orchestrator distinguishes by return code:
#   0 — clean merge + commit landed
#   1 — real merge conflict (unmerged paths)
#   2 — empty squash (sub branch's tree == parent tree)
#   3 — refused (e.g. hung commit hook)
# And confirms sub_commit_is_on_parent recognises a ralph-formatted commit
# subject only when the sub's commit actually lives between origin/main and HEAD.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

assert_rc() {
    local name=$1 expected=$2 actual=$3
    assert_eq "$name (rc=$expected)" "$expected" "$actual"
}

# Stub the issue-title lookup so we don't hit GitHub during tests
get_issue_title() {
    case "$2" in
        100) echo "Add greeting module" ;;
        101) echo "Update farewell module" ;;
        102) echo "Empty slice" ;;
        103) echo "Conflicting greeting" ;;
        104) echo "Refused commit" ;;
        *)   echo "Sub-issue $2" ;;
    esac
    return 0
}
export -f get_issue_title

# Build a tiny fixture repo with a parent worktree and four sub-branches that
# trigger each of the four return codes.
setup_fixture() {
    local root=$1
    rm -rf "$root"
    mkdir -p "$root"

    # Bare "origin" so HEAD has a sensible upstream for sub_commit_is_on_parent
    local origin="$root/origin.git"
    git init --quiet --bare "$origin"

    # Working clone — this is our parent worktree
    local parent="$root/parent"
    git clone --quiet "$origin" "$parent"
    git -C "$parent" -c user.email=t@t -c user.name=t commit \
        --allow-empty -m "initial" --quiet
    git -C "$parent" branch -M main
    git -C "$parent" push --quiet origin main

    # Parent branch
    git -C "$parent" checkout -q -b ralph/issue-540

    # Seed: a file the sub-branches will operate on
    echo "hello" > "$parent/file.txt"
    git -C "$parent" -c user.email=t@t -c user.name=t add file.txt
    git -C "$parent" -c user.email=t@t -c user.name=t commit -m "seed file" --quiet

    # --- Sub #100: clean merge (adds a new file, no conflict) ---
    git -C "$parent" checkout -q -b ralph/issue-540-100
    echo "hello from 100" > "$parent/sub100.txt"
    git -C "$parent" -c user.email=t@t -c user.name=t add sub100.txt
    git -C "$parent" -c user.email=t@t -c user.name=t commit -m "add 100" --quiet
    git -C "$parent" checkout -q ralph/issue-540

    # --- Sub #101: clean merge, different file ---
    git -C "$parent" checkout -q -b ralph/issue-540-101
    echo "hello from 101" > "$parent/sub101.txt"
    git -C "$parent" -c user.email=t@t -c user.name=t add sub101.txt
    git -C "$parent" -c user.email=t@t -c user.name=t commit -m "add 101" --quiet
    git -C "$parent" checkout -q ralph/issue-540

    # --- Sub #102: empty (no changes vs parent) ---
    git -C "$parent" checkout -q -b ralph/issue-540-102
    git -C "$parent" -c user.email=t@t -c user.name=t commit \
        --allow-empty -m "empty 102" --quiet
    git -C "$parent" checkout -q ralph/issue-540

    # --- Sub #103: conflicts with #100 (both modify the same file differently) ---
    git -C "$parent" checkout -q -b ralph/issue-540-103
    echo "different greeting" > "$parent/file.txt"
    git -C "$parent" -c user.email=t@t -c user.name=t add file.txt
    git -C "$parent" -c user.email=t@t -c user.name=t commit -m "change greeting (103)" --quiet
    git -C "$parent" checkout -q ralph/issue-540

    # We'll create the conflict case by first merging #100's file.txt change
    # into parent before running the #103 squash. Done in the test itself.

    # Set up the env worktree_manager expects
    WORKTREE_BASE="$root"
    # Rename `parent` → `issue-540` to match WORKTREE_BASE/issue-<n> convention
    mv "$parent" "$root/issue-540"

    # Re-set origin remote and main branch on the renamed clone
    RALPH_GH_REPO="local/test"
    RALPH_GH_MAIN_BRANCH="main"
    export WORKTREE_BASE RALPH_GH_REPO RALPH_GH_MAIN_BRANCH
}

run_merge_tests() {
    local root=$1
    local parent_worktree="$root/issue-540"
    cd "$parent_worktree"

    echo "=== sub_worktree_merge return codes ==="

    # rc=0: clean merge
    sub_worktree_merge 540 100 > /dev/null 2>&1
    assert_rc "clean merge of #100" "0" "$?"
    # Confirm commit landed with the expected subject
    local subject
    subject=$(git -C "$parent_worktree" log -1 --format=%s)
    assert_eq "commit subject matches feat(ralph) format" \
        "feat(ralph): #100 - Add greeting module" "$subject"

    # rc=2: empty squash (#102 has no diff vs parent)
    sub_worktree_merge 540 102 > /dev/null 2>&1
    assert_rc "empty squash of #102 → rc=2" "2" "$?"
    # Worktree should be clean after rc=2
    local dirty
    dirty=$(git -C "$parent_worktree" status --porcelain)
    assert_eq "worktree clean after empty squash" "" "$dirty"

    # rc=0: another clean merge (#101, independent file)
    sub_worktree_merge 540 101 > /dev/null 2>&1
    assert_rc "clean merge of #101" "0" "$?"

    # rc=1: real conflict (#103 touches file.txt which #100 didn't but seed
    # set to "hello" and #103 set to "different greeting" — both modified.
    # To force a real conflict, we modify file.txt on parent first.
    echo "parent-side change" > "$parent_worktree/file.txt"
    git -C "$parent_worktree" -c user.email=t@t -c user.name=t add file.txt
    git -C "$parent_worktree" -c user.email=t@t -c user.name=t commit -m "parent-side mod" --quiet

    local conflict_out
    conflict_out=$(sub_worktree_merge 540 103 2>/dev/null)
    assert_rc "conflicting squash of #103 → rc=1" "1" "$?"
    assert_eq "conflict output names file.txt" "file.txt" "$conflict_out"

    # Reset to a clean state before next test
    git -C "$parent_worktree" reset --hard HEAD --quiet
}

run_commit_detector_tests() {
    local root=$1
    local parent_worktree="$root/issue-540"

    echo "=== sub_commit_is_on_parent ==="

    # After run_merge_tests, #100 and #101 should be on the branch
    sub_commit_is_on_parent 540 100 main
    assert_rc "#100 is on parent branch" "0" "$?"
    sub_commit_is_on_parent 540 101 main
    assert_rc "#101 is on parent branch" "0" "$?"

    # #102 was an empty squash (rc=2) so no commit landed for it
    sub_commit_is_on_parent 540 102 main
    assert_rc "#102 NOT on parent branch (empty squash)" "1" "$?"

    # #103 conflicted and was reset; should not be on parent
    sub_commit_is_on_parent 540 103 main
    assert_rc "#103 NOT on parent branch (conflicted)" "1" "$?"

    # A sub number nothing knows about
    sub_commit_is_on_parent 540 999 main
    assert_rc "unknown sub #999 NOT on parent branch" "1" "$?"

    # Subject like "feat(ralph): #100xx" (suffix digits) must NOT match #100.
    # Add such a commit and re-check the detector boundary.
    git -C "$parent_worktree" -c user.email=t@t -c user.name=t commit \
        --allow-empty -m "feat(ralph): #1000 - decoy" --quiet
    sub_commit_is_on_parent 540 100 main
    assert_rc "decoy 'feat(ralph): #1000' does not falsely flag #100" "0" "$?"
    # And the decoy itself should match for #1000:
    sub_commit_is_on_parent 540 1000 main
    assert_rc "decoy 'feat(ralph): #1000' matches #1000" "0" "$?"
    # But a truly non-existent number with matching prefix must not match:
    sub_commit_is_on_parent 540 10 main
    assert_rc "'#10' does not falsely match '#100'/'#1000'" "1" "$?"
}

run_refused_commit_test() {
    local root=$1
    local parent_worktree="$root/issue-540"

    echo "=== refused-commit path (rc=3) ==="

    # Build a fresh sub-branch with a clean change
    git -C "$parent_worktree" checkout -q ralph/issue-540
    git -C "$parent_worktree" checkout -q -b ralph/issue-540-104
    echo "104 content" > "$parent_worktree/sub104.txt"
    git -C "$parent_worktree" -c user.email=t@t -c user.name=t add sub104.txt
    git -C "$parent_worktree" -c user.email=t@t -c user.name=t commit -m "add 104" --quiet
    git -C "$parent_worktree" checkout -q ralph/issue-540

    # Install a pre-commit hook that ALWAYS rejects. With --no-verify (our new
    # default), the commit should still succeed → rc=0, not rc=3. This verifies
    # the --no-verify wiring in worktree_manager.
    mkdir -p "$parent_worktree/.git/hooks"
    cat > "$parent_worktree/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "pre-commit hook rejects everything" >&2
exit 1
EOF
    chmod +x "$parent_worktree/.git/hooks/pre-commit"

    sub_worktree_merge 540 104 > /dev/null 2>&1
    assert_rc "rejecting pre-commit hook bypassed by --no-verify → rc=0" "0" "$?"

    rm -f "$parent_worktree/.git/hooks/pre-commit"
}

main() {
    local tmpdir
    tmpdir=$(mktemp -d -t ralph-merge-test-XXXXXX)
    trap "rm -rf '$tmpdir'" EXIT

    setup_fixture "$tmpdir"
    run_merge_tests "$tmpdir"
    run_commit_detector_tests "$tmpdir"
    run_refused_commit_test "$tmpdir"

    echo ""
    echo "=== Summary ==="
    echo "  Passed: $PASS"
    echo "  Failed: $FAIL"
    [[ $FAIL -eq 0 ]]
}

main "$@"
