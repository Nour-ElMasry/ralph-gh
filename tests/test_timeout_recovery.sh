#!/usr/bin/env bash

# test_timeout_recovery.sh - Tests for surviving a wall-clock timeout.
#
# A turn killed by the timeout never writes its result JSON, so ralph used to
# lose both things it needed from it: the session id (the retry restarted cold,
# re-reading the issue and rediscovering its own half-written files) and any
# notion that work had happened at all (the circuit breaker was told
# has_progress=false regardless of the tree). PRD #1119 died of exactly that —
# three timeouts on sub-issue #1127 opened the breaker, and the wip commit
# ralph made on the way out held 23 files and 5,634 lines from those three
# "no progress" attempts.
#
# Covers: workspace_tree_fingerprint, --session-id vs --resume, and the
# timeout branch of execute_for_sub_issue.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/claude_runner.sh"
source "$SCRIPT_DIR/lib/issue_worker.sh"

PASS=0
FAIL=0

assert_eq() {
    local test_name=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_ne() {
    local test_name=$1 unexpected=$2 actual=$3
    if [[ "$unexpected" != "$actual" ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected anything but: '$unexpected'"
        FAIL=$((FAIL + 1))
    fi
}

# --- workspace_tree_fingerprint ---------------------------------------------
# A real repo, not a stubbed `git`: the bug this helper replaces was a wrong
# reading of real git output, so a fake git would have hidden it.

echo "=== workspace_tree_fingerprint ==="

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO" "$STATE" "$WS"' EXIT
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
mkdir -p "$REPO/src"
echo "one" > "$REPO/src/a.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm initial

FP_CLEAN=$(workspace_tree_fingerprint "$REPO")

# The helper is called from the orchestrator's cwd, which is not always the
# worktree — hashing repo-relative paths from elsewhere silently degrades the
# fingerprint to HEAD-only, which never changes within a sub-issue.
FP_FROM_ELSEWHERE=$(cd / && workspace_tree_fingerprint "$REPO")
assert_eq "fingerprint does not depend on the caller's cwd" "$FP_CLEAN" "$FP_FROM_ELSEWHERE"

echo "two" > "$REPO/src/b.txt"
FP_UNTRACKED=$(workspace_tree_fingerprint "$REPO")
assert_ne "an untracked file the turn wrote changes the fingerprint" "$FP_CLEAN" "$FP_UNTRACKED"

# The case `git status --porcelain` cannot see: a file that was already
# modified stays a bare `M` however many times its contents change, so a loop
# spent editing what an earlier loop had touched would read as stagnant.
echo "one modified" > "$REPO/src/a.txt"
FP_MODIFIED=$(workspace_tree_fingerprint "$REPO")
echo "one modified again" > "$REPO/src/a.txt"
FP_MODIFIED_AGAIN=$(workspace_tree_fingerprint "$REPO")
assert_ne "editing an already-modified file changes the fingerprint" "$FP_MODIFIED" "$FP_MODIFIED_AGAIN"

git -C "$REPO" checkout -q -- src/a.txt
rm -f "$REPO/src/b.txt"
FP_REVERTED=$(workspace_tree_fingerprint "$REPO")
assert_eq "reverting every change restores the original fingerprint" "$FP_CLEAN" "$FP_REVERTED"

git -C "$REPO" commit -q --allow-empty -m second
FP_COMMITTED=$(workspace_tree_fingerprint "$REPO")
assert_ne "a new commit changes the fingerprint" "$FP_CLEAN" "$FP_COMMITTED"

FP_IDLE=$(workspace_tree_fingerprint "$REPO")
assert_eq "a turn that touched nothing leaves the fingerprint alone" "$FP_COMMITTED" "$FP_IDLE"

# --- claude_build_args: --session-id vs --resume ----------------------------

echo "=== session flags ==="

RALPH_GH_FALLBACK_MODEL=""
NEW_ARGS=$(claude_build_args "$REPO" "" "" "abc-123" "" "auto" "nosys" "new" | tr '\n' ' ')
assert_eq "session mode 'new' mints the id with --session-id" \
    "yes" "$(grep -q -- '--session-id abc-123' <<<"$NEW_ARGS" && echo yes || echo no)"

RESUME_ARGS=$(claude_build_args "$REPO" "" "" "abc-123" "" "auto" "nosys" "resume" | tr '\n' ' ')
assert_eq "session mode 'resume' reuses it with --resume" \
    "yes" "$(grep -q -- '--resume abc-123' <<<"$RESUME_ARGS" && echo yes || echo no)"

DEFAULT_ARGS=$(claude_build_args "$REPO" "" "" "abc-123" "" "auto" "nosys" | tr '\n' ' ')
assert_eq "resume stays the default for callers that pass no mode" \
    "yes" "$(grep -q -- '--resume abc-123' <<<"$DEFAULT_ARGS" && echo yes || echo no)"

# --- run_claude publishes the session id it ran under -----------------------

echo "=== run_claude session id ==="

STATE="$(mktemp -d)"
WS="$(mktemp -d)"
RALPH_GH_STATE_DIR="$STATE"
RALPH_GH_TELEMETRY_FILE="$STATE/telemetry.jsonl"
log_status() { :; }
reap_workspace_orphans() { :; }

RALPH_TEST_TIMEOUT_RC=0
portable_timeout() { printf '%s' '{"session_id":"from-result","is_error":false}'; return "$RALPH_TEST_TIMEOUT_RC"; }

RALPH_LAST_SESSION_ID=""
run_claude "$WS" "prompt" "$STATE/out.json" "$STATE/err.log" 60 "" "" "" "" "" "implement" >/dev/null 2>&1
assert_ne "a fresh call knows its session id before the CLI answers" "" "$RALPH_LAST_SESSION_ID"

RALPH_LAST_SESSION_ID=""
run_claude "$WS" "prompt" "$STATE/out.json" "$STATE/err.log" 60 "" "" "given-id" "" "" "implement" >/dev/null 2>&1
assert_eq "a resumed call reports the id it was handed" "given-id" "$RALPH_LAST_SESSION_ID"

# --- execute_for_sub_issue on timeout ---------------------------------------

echo "=== timeout branch ==="

get_issue_title() { echo "Test sub-issue"; }
get_issue_body() { echo "- [ ] some criterion"; }
get_completed_subs() { echo ""; }
build_full_prompt() { echo "stub prompt"; }
RALPH_GH_ALLOWED_TOOLS=""

RALPH_TEST_TIMEOUT_RC=124
rm -f "$STATE/.claude_session_id" "$STATE/.last_failure_kind"
TIMEOUT_RC=0
execute_for_sub_issue "$WS" "owner/repo" "1127" "1119" "" "" "1" "" "false" >/dev/null 2>&1 || TIMEOUT_RC=$?

assert_eq "a timed-out turn is retryable, not terminal" "1" "$TIMEOUT_RC"
assert_eq "the timeout is labelled so the retry prompt can say so" \
    "timeout" "$(cat "$STATE/.last_failure_kind" 2>/dev/null)"
assert_eq "the session survives the kill so the retry resumes it" \
    "$RALPH_LAST_SESSION_ID" "$(cat "$STATE/.claude_session_id" 2>/dev/null)"

RALPH_TEST_TIMEOUT_RC=0
rm -f "$STATE/.last_failure_kind"
execute_for_sub_issue "$WS" "owner/repo" "1127" "1119" "" "" "1" "" "false" >/dev/null 2>&1 || true
assert_eq "a turn that ends on its own is not labelled a timeout" \
    "" "$(cat "$STATE/.last_failure_kind" 2>/dev/null)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
