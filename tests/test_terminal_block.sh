#!/usr/bin/env bash

# test_terminal_block.sh - Tests for terminal-block handling.
#
# A sub-issue that reports STATUS: BLOCKED + EXIT_SIGNAL: true is making a
# deliberate, non-retryable escalation. execute_for_sub_issue must return 2
# for that case (so the caller defers to a human) and keep returning 1 for a
# retryable BLOCKED and 0 for COMPLETE. Also covers get_last_recommendation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
trap 'rm -rf "$RALPH_GH_STATE_DIR"' EXIT
RALPH_GH_ALLOWED_TOOLS=""

log_status() { :; }
get_issue_title() { echo "Test sub-issue"; }
get_issue_body() { echo "- [ ] some criterion"; }
get_completed_subs() { echo ""; }
build_full_prompt() { echo "stub prompt"; }
# Claude's JSON result is delivered via portable_timeout's stdout, which
# execute_for_sub_issue redirects into the output file. Emit a canned payload.
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
    execute_for_sub_issue "/tmp" "owner/repo" "594" "593" "" "" "1" "" "false" >/dev/null 2>&1 || rc=$?
    echo "$rc"
}

echo "=== execute_for_sub_issue return codes ==="

# jq -r '.result' turns \n into real newlines before the grep checks run.
BLOCKED_TERMINAL='{"result":"work done\nSTATUS: BLOCKED\nEXIT_SIGNAL: true\nRECOMMENDATION: needs a human decision","session_id":"11111111-1111-1111-1111-111111111111"}'
BLOCKED_RETRY='{"result":"hit a snag\nSTATUS: BLOCKED\nEXIT_SIGNAL: false","session_id":"22222222-2222-2222-2222-222222222222"}'
COMPLETE='{"result":"all gates green\nSTATUS: COMPLETE\nEXIT_SIGNAL: true","session_id":"33333333-3333-3333-3333-333333333333"}'

assert_eq "BLOCKED + EXIT_SIGNAL:true returns 2 (terminal)" "2" "$(run_execute "$BLOCKED_TERMINAL")"
assert_eq "BLOCKED + EXIT_SIGNAL:false returns 1 (retryable)" "1" "$(run_execute "$BLOCKED_RETRY")"
assert_eq "COMPLETE returns 0" "0" "$(run_execute "$COMPLETE")"

echo ""
echo "=== get_last_recommendation ==="

out_file="$RALPH_GH_STATE_DIR/logs/canned.log"
mkdir -p "$(dirname "$out_file")"
printf '%s' '{"result":"blah\nSTATUS: BLOCKED\nRECOMMENDATION: relax criteria to the CI baseline"}' > "$out_file"
echo "$out_file" > "$RALPH_GH_STATE_DIR/.last_claude_output_path"
assert_eq "extracts the RECOMMENDATION line" \
    "relax criteria to the CI baseline" "$(get_last_recommendation)"

printf '%s' '{"result":"no status block here"}' > "$out_file"
assert_eq "empty when no RECOMMENDATION present" "" "$(get_last_recommendation)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
