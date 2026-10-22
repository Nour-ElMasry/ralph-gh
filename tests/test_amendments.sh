#!/usr/bin/env bash

# test_amendments.sh - Tests for proposed acceptance-criterion amendments.
#
# A criterion that cannot be met as written is proposed for amendment in the
# structured report, alongside a terminal block. The proposal reaches a human
# as an issue comment (original, proposed, reason, evidence); ralph never
# edits the issue; the acceptance gate refuses a report that proposes an
# amendment without stopping, or that also claims the criterion met.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/claude_runner.sh"
source "$SCRIPT_DIR/lib/verify_gate.sh"
source "$SCRIPT_DIR/lib/issue_worker.sh"
source "$SCRIPT_DIR/lib/github_poller.sh"
# ralph-gh.sh dispatches its CLI when sourced; load just the handoff.
source <(sed -n '/^defer_sub_for_human() {/,/^}/p' "$SCRIPT_DIR/ralph-gh.sh")

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
log_status() { :; }
export RALPH_GH_STATE_DIR="$TMP/state"
export RALPH_GH_TELEMETRY_FILE="$TMP/telemetry.jsonl"
mkdir -p "$RALPH_GH_STATE_DIR"

write_report() { printf '%s' "$1" > "$RALPH_GH_STATE_DIR/.last_status.json"; }

AMENDED='{"status":"BLOCKED","exit_signal":true,"tests_status":"PASSING","recommendation":"rule on the PR-description criterion","acceptance":[{"criterion":"Export works","met":true,"evidence":"src/export.ts:12"},{"criterion":"PR description states the migration","met":false,"evidence":"ralph cannot write the PR description"}],"amendments":[{"criterion":"PR description states the migration","proposed":"docs/migrations.md states the migration","reason":"the implementer cannot edit the PR description","evidence":"gh pr create is on the deny list"},{"criterion":"Use the a|b\nflag","proposed":"","reason":"two lines\nof reason","evidence":"see <!-- this & \\| that"}]}'

echo "=== schema and prompt ==="
assert_eq "amendments is an optional array in the worker schema" "array" "$(jq -r '.properties.amendments.type' <<< "$WORKER_SCHEMA")"
assert_eq "each amendment requires all four fields" "criterion,proposed,reason,evidence" "$(jq -r '.properties.amendments.items.required | join(",")' <<< "$WORKER_SCHEMA")"
assert_eq "amendments stays out of the required list" "false" "$(jq '.required | index("amendments") != null' <<< "$WORKER_SCHEMA")"
prompt=$(build_full_prompt "$TMP" 5 "t" "- [ ] a" 4 "p" "" "" "false")
assert_contains "the prompt says not to reinterpret an unmeetable criterion" "do not reinterpret it into something you can meet" "$prompt"
assert_contains "the prompt routes it to a terminal block" 'propose the wording you would accept in `amendments`, and return `BLOCKED` with `exit_signal: true`' "$prompt"
assert_contains "the report section documents amendments" '`amendments` (optional)' "$prompt"
assert_contains "the escaped apostrophe renders" "an issue's state" "$prompt"

echo ""
echo "=== comment format ==="
write_report "$AMENDED"
comment=$(build_amendment_comment 4 "rule on it" "")
assert_contains "the original criterion is quoted verbatim" "| **Original** | PR description states the migration |" "$comment"
assert_contains "the proposed wording is shown" "| **Proposed** | docs/migrations.md states the migration |" "$comment"
assert_contains "the reason is shown" "| **Reason** | the implementer cannot edit the PR description |" "$comment"
assert_contains "the evidence is shown" "| **Evidence** | gh pr create is on the deny list |" "$comment"
assert_contains "pipes are entity-escaped so the table holds" 'Use the a&#124;b<br>flag' "$comment"
assert_contains "HTML, ampersands and backslashes are escaped" 'see &lt;!-- this &amp; &#92;&#124; that' "$comment"
assert_contains "newlines become line breaks" "two lines<br>of reason" "$comment"
assert_contains "an empty proposal reads as a drop" "_(drop this criterion)_" "$comment"
assert_contains "each amendment is numbered" "| Amendment 2 | |" "$comment"
assert_contains "the comment says how to accept" "Edit the issue body to accept an amendment, or reply with a ruling, then re-trigger parent #4." "$comment"
write_report '{"status":"BLOCKED","exit_signal":true,"tests_status":"NOT_RUN","recommendation":"x","acceptance":[]}'
assert_eq "no amendments, no amendment comment" "" "$(build_amendment_comment 4 "x" "")"

echo ""
echo "=== handoff ==="
GH_CALLS="$TMP/gh_calls"
gh() { printf '%s\n' "$*" >> "$GH_CALLS"; }
complete_group_with_held() { :; }
abort_group() { :; }
git() { return 0; }
RALPH_GH_REPO="o/r"
RALPH_GH_SKIP_LABEL="ralph-hold"
write_report "$AMENDED"
: > "$RALPH_GH_TELEMETRY_FILE"
defer_sub_for_human 4 "ralph/issue-4" 5 "rule on the PR-description criterion"
calls=$(cat "$GH_CALLS")
assert_contains "the comment goes on the sub-issue" "issue comment 5 --repo o/r --body ralph-gh stopped here: an acceptance criterion" "$calls"
assert_contains "the posted comment carries the table" "| **Original** | PR description states the migration |" "$calls"
assert_contains "the model's recommendation is kept" $'**Model recommendation:**\nrule on the PR-description criterion' "$calls"
assert_contains "the sub-issue is held for a human" "issue edit 5 --repo o/r --add-label ralph-hold" "$calls"
assert_eq "ralph never edits an issue's body or title" "0" "$(grep -cE 'issue edit .*--(body|title)|api .*(PATCH|-X)' "$GH_CALLS")"
assert_eq "telemetry records one event per amendment" "2" "$(jq -s 'map(select(.gate == "amendment" and .outcome == "proposed")) | length' "$RALPH_GH_TELEMETRY_FILE")"
assert_eq "telemetry names the criterion" "PR description states the migration" "$(jq -rs 'map(select(.gate == "amendment"))[0].detail' "$RALPH_GH_TELEMETRY_FILE")"
assert_eq "a multi-line criterion is one telemetry line" "Use the a|b flag" "$(jq -rs 'map(select(.gate == "amendment"))[1].detail' "$RALPH_GH_TELEMETRY_FILE")"
stats=$(telemetry_stats)
assert_contains "--stats has an amend column" "amend" "$stats"

: > "$GH_CALLS"
write_report '{"status":"BLOCKED","exit_signal":true,"tests_status":"NOT_RUN","recommendation":"env is down","acceptance":[]}'
defer_sub_for_human 4 "ralph/issue-4" 5 "env is down"
assert_contains "a block without amendments keeps the old comment" "reported a **terminal block**" "$(cat "$GH_CALLS")"

echo ""
echo "=== acceptance gate ==="
echo "true" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
write_report '{"status":"COMPLETE","exit_signal":false,"tests_status":"PASSING","recommendation":"x","acceptance":[{"criterion":"PR description states the migration","met":true,"evidence":"wrote docs instead"}],"amendments":[{"criterion":"PR description states the migration ","proposed":"docs","reason":"r","evidence":"e"}]}'
out=$(run_acceptance_gate); rc=$?
assert_eq "an amended criterion reported met fails the gate" "1" "$rc"
assert_contains "the message names the claim" "proposed amending these criteria and also reported them met" "$out"
assert_contains "it lists the criterion" "- PR description states the migration" "$out"
assert_eq "telemetry records the gaming guard" "amended criterion reported met" "$(tail -1 "$RALPH_GH_TELEMETRY_FILE" | jq -r .detail)"

write_report '{"status":"IN_PROGRESS","exit_signal":false,"tests_status":"PASSING","recommendation":"x","acceptance":[{"criterion":"a","met":false,"evidence":"no"}],"amendments":[{"criterion":"a","proposed":"b","reason":"r","evidence":"e"}]}'
out=$(run_acceptance_gate); rc=$?
assert_eq "an amendment without a terminal block fails the gate" "1" "$rc"
assert_contains "the message says it did not stop" "did not stop for a human" "$out"
assert_contains "the message gives both ways out" 'return `BLOCKED` with `exit_signal: true`' "$out"

echo "false" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
out=$(run_acceptance_gate); rc=$?
assert_eq "the guard holds even when the body has no checklist" "1" "$rc"
echo "true" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"

write_report '{"status":"COMPLETE","exit_signal":false,"tests_status":"PASSING","recommendation":"x","acceptance":[{"criterion":"a","met":true,"evidence":"src/a.ts:1"}]}'
out=$(run_acceptance_gate); rc=$?
assert_eq "a report without amendments passes as before" "0" "$rc"
write_report '{"status":"COMPLETE","exit_signal":false,"tests_status":"PASSING","recommendation":"x","acceptance":[{"criterion":"a","met":true,"evidence":"src/a.ts:1"}],"amendments":[]}'
out=$(run_acceptance_gate); rc=$?
assert_eq "an empty amendments list passes" "0" "$rc"

echo ""
echo "=== verifier: unmeetable as written ==="
assert_eq "the verifier schema has an optional unmeetable flag" "boolean" "$(jq -r '.properties.criteria.items.properties.unmeetable.type' <<< "$VERIFIER_SCHEMA")"
vprompt=$(build_verifier_prompt 5 "t" "- [ ] a" "$TMP/d.patch" "abc" "" "")
assert_contains "the verifier prompt explains unmeetable" '`unmeetable: true` (with `met: false`) only when no change to this' "$vprompt"
WS="$TMP/ws"; mkdir -p "$WS"
git() { [[ "$1" == "-C" && "$3" == "diff" ]] && echo "diff --git a/x b/x"; return 0; }
run_claude() { printf '%s' "$RALPH_TEST_VERIFIER_JSON" > "$3"; return 0; }
RALPH_TEST_VERIFIER_JSON='{"type":"result","structured_output":{"verdict":"FAIL","criteria":[{"criterion":"PR description states X","met":false,"unmeetable":true,"reason":"outside the repo"},{"criterion":"b","met":false,"reason":"missing test"}],"summary":"1 unmeetable"}}'
out=$(run_verifier_gate "$WS" "o/r" 5 "t" "- [ ] a" "abc"); rc=$?
assert_eq "an unmeetable verdict still fails the gate" "1" "$rc"
assert_contains "the unmeetable criterion is marked" "- UNMEETABLE AS WRITTEN: PR description states X — outside the repo" "$out"
assert_contains "an ordinary miss is not marked" "- b — missing test" "$out"
assert_contains "the retry context routes it to an amendment" 'propose an amendment for each in `amendments`' "$out"
RALPH_TEST_VERIFIER_JSON='{"type":"result","structured_output":{"verdict":"FAIL","criteria":[{"criterion":"b","met":false,"reason":"missing test"}],"summary":"x"}}'
out=$(run_verifier_gate "$WS" "o/r" 5 "t" "- [ ] a" "abc")
assert_eq "no amendment advice without an unmeetable verdict" "0" "$(grep -c 'propose an amendment' <<< "$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
