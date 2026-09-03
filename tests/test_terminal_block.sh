#!/usr/bin/env bash

# test_terminal_block.sh - Tests for terminal-block handling.
#
# A sub-issue that reports status BLOCKED + exit_signal true (structured
# output) is making a deliberate, non-retryable escalation.
# execute_for_sub_issue must return 2 for that case (so the caller defers to a
# human) and keep returning 1 for a retryable BLOCKED and 0 for COMPLETE. Also
# covers get_last_recommendation and the missing-structured-output path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

# --- Stubs for execute_for_sub_issue's boundaries ---------------------------
RALPH_GH_STATE_DIR="$(mktemp -d)"
WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$RALPH_GH_STATE_DIR" "$WORKSPACE"' EXIT
RALPH_GH_ALLOWED_TOOLS=""
RALPH_GH_TELEMETRY_FILE="$RALPH_GH_STATE_DIR/telemetry.jsonl"

log_status() { :; }
reap_workspace_orphans() { :; }
get_issue_title() { echo "Test sub-issue"; }
get_issue_body() { echo "- [ ] some criterion"; }
get_completed_subs() { echo ""; }
build_full_prompt() { echo "stub prompt"; }
# Claude's JSON result is delivered via portable_timeout's stdout, which
# run_claude redirects into the output file. Emit a canned payload.
portable_timeout() { printf '%s' "$RALPH_TEST_CLAUDE_JSON"; return 0; }
# Deterministic clean working tree so has_changes=false unless status says so.
git() {
    case "$1 $2" in
        "diff --quiet"|"diff --cached") return 0 ;;
        "ls-files") return 0 ;;
        *) return 0 ;;
    esac
}

run_execute() {
    RALPH_TEST_CLAUDE_JSON="$1"
    local rc=0
    execute_for_sub_issue "$WORKSPACE" "owner/repo" "594" "593" "" "" "1" "" "false" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

echo "=== execute_for_sub_issue return codes (structured output) ==="

BLOCKED_TERMINAL='{"type":"result","is_error":false,"result":"needs a human","session_id":"11111111-1111-1111-1111-111111111111","structured_output":{"status":"BLOCKED","exit_signal":true,"tests_status":"NOT_RUN","recommendation":"needs a human decision","acceptance":[]}}'
BLOCKED_RETRY='{"type":"result","is_error":false,"result":"hit a snag","session_id":"22222222-2222-2222-2222-222222222222","structured_output":{"status":"BLOCKED","exit_signal":false,"tests_status":"FAILING","recommendation":"retry","acceptance":[]}}'
COMPLETE='{"type":"result","is_error":false,"result":"all green","session_id":"33333333-3333-3333-3333-333333333333","structured_output":{"status":"COMPLETE","exit_signal":false,"tests_status":"PASSING","recommendation":"ship it","acceptance":[{"criterion":"some criterion","met":true,"evidence":"src/x.ts:12"}]}}'
NO_STRUCTURED='{"type":"result","is_error":false,"result":"STATUS: COMPLETE (prose only)","session_id":"44444444-4444-4444-4444-444444444444"}'
ARRAY_FORM='[{"type":"system"},{"type":"result","is_error":false,"result":"ok","session_id":"55555555-5555-5555-5555-555555555555","structured_output":{"status":"BLOCKED","exit_signal":true,"tests_status":"NOT_RUN","recommendation":"array form","acceptance":[]}}]'

assert_eq "BLOCKED + exit_signal:true returns 2 (terminal)" "2" "$(run_execute "$BLOCKED_TERMINAL")"
assert_eq "BLOCKED + exit_signal:false returns 1 (retryable)" "1" "$(run_execute "$BLOCKED_RETRY")"
assert_eq "COMPLETE returns 0" "0" "$(run_execute "$COMPLETE")"
assert_eq "prose-only STATUS: COMPLETE with no changes is NOT trusted (returns 1)" "1" "$(run_execute "$NO_STRUCTURED")"
assert_eq "stream/array result form is parsed (terminal block → 2)" "2" "$(run_execute "$ARRAY_FORM")"

echo ""
echo "=== session + status persistence ==="
run_execute "$COMPLETE" >/dev/null
assert_eq "session id saved from result" "33333333-3333-3333-3333-333333333333" "$(get_saved_session_id)"
assert_eq ".last_status.json holds the structured report" "COMPLETE" "$(jq -r .status "$RALPH_GH_STATE_DIR/.last_status.json")"
assert_eq "sub body captured for the verifier" "- [ ] some criterion" "$(get_last_sub_body)"

echo ""
echo "=== get_last_recommendation ==="
run_execute "$BLOCKED_TERMINAL" >/dev/null
assert_eq "extracts the recommendation" "needs a human decision" "$(get_last_recommendation)"
run_execute "$NO_STRUCTURED" >/dev/null
assert_eq "empty when no structured report" "" "$(get_last_recommendation)"

echo ""
echo "=== telemetry side-effect ==="
n=$(grep -c '"event":"claude"' "$RALPH_GH_TELEMETRY_FILE" 2>/dev/null || echo 0)
assert_eq "one telemetry record per invocation (8 runs)" "8" "$n"
assert_eq "telemetry carries phase=implement" "implement" "$(tail -1 "$RALPH_GH_TELEMETRY_FILE" | jq -r .phase)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
