#!/usr/bin/env bash

# test_review_panel.sh - Tests for the pre-PR review panel.
#
# Reviewers only report; a separate fixer acts on blocker/major findings; the
# shell verifies the fix and reverts a round that stays red; disputed findings
# are not re-sent; what is left lands in the PR body, and an unresolved blocker
# fails the panel. run_claude, the verify gate and the e2e pre-check are mocked;
# git is real.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/claude_runner.sh"
source "$SCRIPT_DIR/lib/verify_gate.sh"
source "$SCRIPT_DIR/lib/issue_worker.sh"
source "$SCRIPT_DIR/lib/review_panel.sh"

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
assert_contains() {
    local test_name=$1 needle=$2 haystack=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected to contain: '$needle'"
        echo "    Actual: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}
assert_not_contains() {
    local test_name=$1 needle=$2 haystack=$3
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected NOT to contain: '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log_status() { :; }
get_issue_title() { echo "Parent title"; }
reap_workspace_orphans() { echo "reap" >> "$MOCK/reaps"; }
export RALPH_GH_TELEMETRY_FILE="$TMP/telemetry.jsonl"
export RALPH_GH_REPO="o/r"
export RALPH_TELEMETRY_REPO="o/r" RALPH_TELEMETRY_PARENT=10
CLAUDE_TIMEOUT_MINUTES=1
RALPH_GH_MODEL="claude-opus-5-5"
RALPH_GH_ALLOWED_TOOLS="Read,Edit"
RALPH_GH_REVIEW_PROMPT_DIR="$SCRIPT_DIR/prompts"

# --- mocks ------------------------------------------------------------------
# Reviewer replies come from $MOCK/<name>.<round> (a JSON structured_output, or
# a missing file for "no report"); the fixer's from $MOCK/fixer.<n>. Every call
# is logged as "phase model reap=<flag> session=<id>".
run_claude() {
    local workspace=$1 prompt=$2 out=$3 phase=${11}
    local model=$6 session=$8
    echo "$phase $model reap=${RALPH_GH_REAP_ORPHANS:-1} session=${session:-new}" >> "$MOCK/calls"
    printf '%s' "$prompt" > "$MOCK/prompt.${phase//:/_}"
    RALPH_LAST_SESSION_ID="sess-1"
    local key n
    if [[ "$phase" == review:* ]]; then
        key=${phase#review:}
    else
        key=fixer
        # The fixer edits a file; the shell is expected to commit it.
        echo "fix $RANDOM" >> "$workspace/app.ts"
    fi
    n=$(( $(cat "$MOCK/count.$key" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$MOCK/count.$key"
    if [[ -f "$MOCK/$key.$n" ]]; then
        jq -nc --argjson so "$(cat "$MOCK/$key.$n")" '{type: "result", structured_output: $so}' > "$out"
    else
        : > "$out"
    fi
    return 0
}
run_verify_gate() {
    echo "$2" >> "$MOCK/verify_refs"
    local n
    n=$(( $(cat "$MOCK/count.verify" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$MOCK/count.verify"
    if [[ -f "$MOCK/verify_red.$n" ]]; then
        echo "tests red"
        return 1
    fi
    return 0
}
run_e2e_pre_check() { return 0; }

clean='{"findings":[],"summary":"clean"}'
finding() {  # severity title [location]
    jq -nc --arg s "$1" --arg t "$2" --arg l "${3:-app.ts:1}" \
        '{findings: [{severity: $s, location: $l, title: $t, detail: "it breaks"}], summary: "found"}'
}

# Fresh repo: main with app.ts, a feature branch changing the given files.
#   $@ = files the branch adds or changes
setup() {
    MOCK="$TMP/mock_$RANDOM"; mkdir -p "$MOCK"
    WS="$TMP/ws_$RANDOM"; mkdir -p "$WS"
    export RALPH_GH_STATE_DIR="$WS/.ralph-gh"
    git -C "$WS" init -q -b main
    git -C "$WS" config user.email t@t; git -C "$WS" config user.name t
    echo ".ralph-gh/" > "$WS/.gitignore"
    echo "base" > "$WS/app.ts"
    git -C "$WS" add -A; git -C "$WS" commit -q -m base
    git -C "$WS" checkout -q -b ralph/issue-10
    local f
    for f in "$@"; do mkdir -p "$WS/$(dirname "$f")"; echo "change" >> "$WS/$f"; done
    git -C "$WS" add -A; git -C "$WS" commit -q -m "feat: change"
    rm -f "$RALPH_GH_TELEMETRY_FILE"
}
calls() { cat "$MOCK/calls" 2>/dev/null; }
# Strict mode, as ralph-gh.sh runs.
panel() { (set -euo pipefail; cd "$WS" && run_review_panel "$WS" main 10); }

RALPH_GH_REVIEWERS="security,code,ui"
RALPH_GH_MAX_REVIEW_RUNS=2

echo "=== reviewer selection ==="
setup app.ts
echo "$clean" > "$MOCK/security.1"; echo "$clean" > "$MOCK/code.1"
panel; rc=$?
assert_eq "clean review passes" "0" "$rc"
assert_not_contains "ui skipped when no UI file changed" "review:ui" "$(calls)"
assert_contains "security runs on its own model" "review:security claude-opus-5-5" "$(calls)"
assert_contains "code runs on the review model" "review:code claude-sonnet-5" "$(calls)"
assert_contains "reviewers do not reap on their own" "review:code claude-sonnet-5 reap=0" "$(calls)"
assert_eq "the panel reaps once after the reviewers exit" "1" "$(wc -l < "$MOCK/reaps")"
assert_not_contains "no fixer on a clean review" "review-fix" "$(calls)"
assert_contains "reviewer prompt carries its focus" "You own trust boundaries" "$(cat "$MOCK/prompt.review_security")"
assert_contains "reviewer is told it is read-only" "You are read-only" "$(cat "$MOCK/prompt.review_security")"

setup apps/web/src/page.tsx
for r in security code ui; do echo "$clean" > "$MOCK/$r.1"; done
panel
assert_contains "ui runs when a .tsx file changed" "review:ui" "$(calls)"

setup app.ts
mkdir -p "$WS/.ralph/reviewers"; echo "REPO SECURITY RULES" > "$WS/.ralph/reviewers/security.md"
echo "$clean" > "$MOCK/security.1"; echo "$clean" > "$MOCK/code.1"
panel
assert_contains "repo reviewer prompt overrides the built-in" "REPO SECURITY RULES" "$(cat "$MOCK/prompt.review_security")"

setup app.ts
RALPH_GH_REVIEWERS="security,perf"
echo "$clean" > "$MOCK/security.1"
panel
assert_not_contains "a reviewer with no prompt is skipped" "review:perf" "$(calls)"
RALPH_GH_REVIEWERS=""
setup app.ts
panel; rc=$?
assert_eq "empty RALPH_GH_REVIEWERS disables the review" "0" "$rc"
assert_eq "no Claude call when disabled" "" "$(calls)"
RALPH_GH_REVIEWERS="security,code,ui"

echo ""
echo "=== fix round ==="
setup app.ts
finding major "Missing tenant filter" > "$MOCK/security.1"
echo "$clean" > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[{"id":"SECURITY-1.1","outcome":"fixed","note":"added filter"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
echo "$clean" > "$MOCK/security.2"
pre=$(git -C "$WS" rev-parse HEAD)
panel; rc=$?
assert_eq "fixed finding, clean re-review passes" "0" "$rc"
assert_contains "fixer runs on the implementation model" "review-fix claude-opus-5-5" "$(calls)"
assert_contains "fixer prompt lists the finding by id" "**SECURITY-1.1** [major] security" "$(cat "$MOCK/prompt.review-fix")"
assert_eq "the shell commits the fixer's changes" "fix(ralph): address review findings for #10" "$(git -C "$WS" log -1 --format=%s)"
assert_eq "verify scoped to the fix round" "$pre" "$(cat "$MOCK/verify_refs")"
assert_eq "only the reviewer with a fixed finding re-runs" "2" "$(grep -c 'review:security' "$MOCK/calls")"
assert_eq "a clean reviewer is not re-run" "1" "$(grep -c 'review:code' "$MOCK/calls")"
assert_eq "nothing left for the PR body" "" "$(review_findings_section 10)"

echo ""
echo "=== disputed finding ==="
setup app.ts
echo "$clean" > "$MOCK/security.1"
finding blocker "Race in checkout" > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[{"id":"CODE-1.1","outcome":"disputed","note":"guarded by a row lock at app.ts:3"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
panel; rc=$?
assert_eq "a disputed blocker does not fail the panel" "0" "$rc"
assert_eq "a reviewer whose only finding was disputed is not re-run" "1" "$(grep -c 'review:code' "$MOCK/calls")"
section=$(review_findings_section 10)
assert_contains "disputed finding in the PR body" "Review findings the fixer disputed" "$section"
assert_contains "the fixer's reason is shown" "guarded by a row lock" "$section"

setup app.ts
echo "$clean" > "$MOCK/security.1"
jq -nc '{findings: [{severity: "major", location: "a.ts:1", title: "Fixed one", detail: "d"},
                    {severity: "major", location: "b.ts:2", title: "Disputed one", detail: "d"}], summary: "s"}' > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[{"id":"CODE-1.1","outcome":"fixed","note":"x"},{"id":"CODE-1.2","outcome":"disputed","note":"not reachable"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
echo "$clean" > "$MOCK/code.2"
panel
code_prompt=$(cat "$MOCK/prompt.review_code")
assert_contains "the re-run reviewer hears about the dispute" "Disputed in an earlier round" "$code_prompt"
assert_contains "with the fixer's reason" "Fixer: not reachable" "$code_prompt"
assert_not_contains "the fixed finding is not listed as disputed" "Fixed one" "$code_prompt"

echo ""
echo "=== unresolved findings ==="
setup app.ts
finding blocker "IDOR on /leads/:id" "apps/api/leads.ts:40" > "$MOCK/security.1"
echo "$clean" > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[{"id":"SECURITY-1.1","outcome":"fixed","note":"x"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
finding blocker "IDOR on /leads/:id" "apps/api/leads.ts:40" > "$MOCK/security.2"
panel; rc=$?
assert_eq "a blocker still open after the last round fails the panel" "1" "$rc"
assert_contains "draft reason names the blocker" "security: IDOR on /leads/:id (\`apps/api/leads.ts:40\`)" "$(review_blocker_reason 10)"
assert_contains "open finding in the PR body" "Review findings left open" "$(review_findings_section 10)"
assert_eq "one fixer round between two review rounds" "1" "$(grep -c 'review-fix' "$MOCK/calls")"

setup app.ts
finding major "Weak check" > "$MOCK/security.1"
finding minor "Naming" > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[],"recommendation":"ok"}' > "$MOCK/fixer.1"
finding major "Weak check" > "$MOCK/security.2"
panel; rc=$?
assert_eq "only majors left open → the panel passes" "0" "$rc"
section=$(review_findings_section 10)
assert_contains "the open major is listed" "[major] security" "$section"
assert_contains "minor notes are listed, not fixed" "Minor review notes" "$section"
assert_not_contains "minor findings never reach the fixer" "Naming" "$(cat "$MOCK/prompt.review-fix")"

echo ""
echo "=== verify red after the fix ==="
setup app.ts
finding blocker "Broken auth" > "$MOCK/security.1"
echo "$clean" > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[{"id":"SECURITY-1.1","outcome":"fixed","note":"x"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
touch "$MOCK/verify_red.1" "$MOCK/verify_red.2"
before_tree=$(git -C "$WS" rev-parse 'HEAD^{tree}')
panel; rc=$?
assert_contains "red verify gets one more fixer turn, same session" "review-fix claude-opus-5-5 reap=1 session=sess-1" "$(calls)"
assert_eq "a round still red is reverted" "$before_tree" "$(git -C "$WS" rev-parse 'HEAD^{tree}')"
assert_contains "revert keeps history (no reset)" "Revert" "$(git -C "$WS" log -1 --format=%s)"
assert_eq "the reverted blocker fails the panel" "1" "$rc"
assert_contains "draft reason says the round was reverted" "was reverted" "$(review_blocker_reason 10)"
assert_eq "no second review round after a revert" "1" "$(grep -c 'review:security' "$MOCK/calls")"

setup app.ts
finding major "Slow query" > "$MOCK/code.1"
echo "$clean" > "$MOCK/security.1"
echo '{"status":"COMPLETE","findings":[{"id":"CODE-1.1","outcome":"fixed","note":"x"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
echo "$clean" > "$MOCK/code.2"
touch "$MOCK/verify_red.1"
panel; rc=$?
assert_eq "red then green after the retry passes" "0" "$rc"
assert_eq "two verify runs" "2" "$(cat "$MOCK/count.verify")"

echo ""
echo "=== reviewer that does not report ==="
setup app.ts
echo "$clean" > "$MOCK/code.1"
panel; rc=$?
assert_eq "a silent reviewer does not block (fail-open)" "0" "$rc"
assert_contains "and is named in the PR body" "Reviewers that did not report" "$(review_findings_section 10)"

echo ""
echo "=== telemetry ==="
setup app.ts
finding major "X" > "$MOCK/security.1"
echo "$clean" > "$MOCK/code.1"
echo '{"status":"COMPLETE","findings":[{"id":"SECURITY-1.1","outcome":"disputed","note":"no"}],"recommendation":"ok"}' > "$MOCK/fixer.1"
panel
assert_eq "review gate events recorded" "1" "$(jq -s '[.[] | select(.event == "gate" and .gate == "review:security" and .outcome == "fail")] | length' "$RALPH_GH_TELEMETRY_FILE")"
assert_contains "stats has a review column" "review✗" "$(telemetry_stats "o/r")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
