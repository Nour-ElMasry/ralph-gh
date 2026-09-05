#!/usr/bin/env bash

# test_gates.sh - Tests for the runner argv, the shell verify gate, the
# structured acceptance gate, and telemetry aggregation.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/claude_runner.sh"
source "$SCRIPT_DIR/lib/verify_gate.sh"
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

echo "=== claude_build_args ==="
WS="$TMP/ws"; mkdir -p "$WS/.ralph"; echo "conventions" > "$WS/.ralph/PROMPT.md"
RALPH_GH_DENY_RULES="Bash(git push --force*), Bash(rm -rf /*)"
RALPH_GH_FALLBACK_MODEL="claude-sonnet-5"
RALPH_GH_EFFORT="high"
RALPH_GH_MAX_BUDGET_USD=""
args=$(claude_build_args "$WS" "claude-opus-5" '{"type":"object"}' "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" "Read, Edit ,Bash(git add *)" "")
assert_contains "permission mode defaults to auto" $'--permission-mode\nauto' "$args"
assert_contains "deny rules become --settings JSON" '{"permissions":{"deny":["Bash(git push --force*)","Bash(rm -rf /*)"]}}' "$args"
assert_contains "setting sources named explicitly" $'--setting-sources\nuser,project,local' "$args"
assert_contains "PROMPT.md goes to --append-system-prompt-file" $'--append-system-prompt-file\n'"$WS/.ralph/PROMPT.md" "$args"
assert_contains "allowed tools are trimmed" $'--allowedTools\nRead\nEdit\nBash(git add *)' "$args"
assert_contains "model flag" $'--model\nclaude-opus-5' "$args"
assert_contains "fallback model flag" $'--fallback-model\nclaude-sonnet-5' "$args"
assert_contains "effort flag" $'--effort\nhigh' "$args"
assert_contains "json schema flag" $'--json-schema\n{"type":"object"}' "$args"
assert_contains "resume flag" $'--resume\naaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' "$args"
assert_eq "no --max-budget-usd when unset" "" "$(printf '%s' "$args" | grep -c max-budget | sed 's/^0$//')"
args2=$(claude_build_args "$WS" "" "" "" "" "dontAsk" "nosys")
assert_contains "explicit permission mode wins" $'--permission-mode\ndontAsk' "$args2"
assert_eq "nosys skips the system prompt file" "0" "$(printf '%s' "$args2" | grep -c append-system-prompt)"
assert_eq "no model flag when model empty" "0" "$(printf '%s' "$args2" | grep -c -- '--model')"
RALPH_GH_DENY_RULES=""
args3=$(claude_build_args "$WS" "" "" "" "" "")
assert_eq "empty deny list → no --settings" "0" "$(printf '%s' "$args3" | grep -c -- '--settings')"

echo ""
echo "=== claude_result_json / structured output ==="
printf '%s' '{"type":"result","structured_output":{"a":1},"session_id":"s1"}' > "$TMP/obj.json"
printf '%s' '[{"type":"system"},{"type":"result","structured_output":{"a":2},"session_id":"s2"}]' > "$TMP/arr.json"
printf '%s' '{"type":"result","result":"no so"}' > "$TMP/none.json"
assert_eq "object form" '{"a":1}' "$(claude_structured_output "$TMP/obj.json")"
assert_eq "array form takes last result" '{"a":2}' "$(claude_structured_output "$TMP/arr.json")"
assert_eq "missing structured_output → empty" "" "$(claude_structured_output "$TMP/none.json")"
assert_eq "field extraction" "s2" "$(claude_result_field "$TMP/arr.json" '.session_id')"

echo ""
echo "=== run_acceptance_gate (structured) ==="
echo "true" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
printf '%s' '{"status":"COMPLETE","acceptance":[{"criterion":"A","met":true,"evidence":"a.ts:1"},{"criterion":"B","met":false,"evidence":"not started"}]}' > "$RALPH_GH_STATE_DIR/.last_status.json"
out=$(run_acceptance_gate); rc=$?
assert_eq "unmet criterion fails the gate" "1" "$rc"
assert_contains "unmet criterion is listed with reason" "- [ ] B — NOT DONE: not started" "$out"
printf '%s' '{"status":"COMPLETE","acceptance":[{"criterion":"A","met":true,"evidence":"a.ts:1"}]}' > "$RALPH_GH_STATE_DIR/.last_status.json"
rc=0; run_acceptance_gate >/dev/null || rc=$?
assert_eq "all met passes" "0" "$rc"
printf '%s' '{"status":"COMPLETE","acceptance":[]}' > "$RALPH_GH_STATE_DIR/.last_status.json"
out=$(run_acceptance_gate); rc=$?
assert_eq "empty acceptance list fails" "1" "$rc"
rm -f "$RALPH_GH_STATE_DIR/.last_status.json"
out=$(run_acceptance_gate); rc=$?
assert_eq "missing report fails" "1" "$rc"
assert_contains "missing report explains what to do" "structured output" "$out"
echo "false" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
rc=0; run_acceptance_gate >/dev/null || rc=$?
assert_eq "no criteria in body → gate skipped (pass)" "0" "$rc"

echo ""
echo "=== run_verify_gate ==="
RALPH_GH_VERIFY_CMD=""
rc=0; out=$(run_verify_gate "$WS" "") || rc=$?
assert_eq "no command configured → pass (skip)" "0" "$rc"
cat > "$WS/.ralph/verify.sh" <<'V'
#!/usr/bin/env bash
echo "ref=$RALPH_SUB_START_REF"
[[ "$RALPH_SUB_START_REF" == "deadbeef" ]] && exit 0
echo "boom"; exit 3
V
assert_eq "resolves .ralph/verify.sh" "bash $WS/.ralph/verify.sh" "$(resolve_verify_cmd "$WS")"
rc=0; out=$(run_verify_gate "$WS" "deadbeef") || rc=$?
assert_eq "verify.sh green → 0" "0" "$rc"
rc=0; out=$(run_verify_gate "$WS" "cafef00d") || rc=$?
assert_eq "verify.sh red → 1" "1" "$rc"
assert_contains "red output carries exit code" "exited 3" "$out"
assert_contains "red output carries the log tail" "boom" "$out"
RALPH_GH_VERIFY_CMD="exit 0"
assert_eq "RALPH_GH_VERIFY_CMD overrides verify.sh" "exit 0" "$(resolve_verify_cmd "$WS")"
rc=0; run_verify_gate "$WS" "" >/dev/null || rc=$?
assert_eq "env command green → 0" "0" "$rc"
RALPH_GH_VERIFY_CMD="sleep 5"
portable_timeout() { return 124; }   # simulate the wall-clock expiring
rc=0; out=$(run_verify_gate "$WS" "") || rc=$?
assert_eq "verify timeout → 1" "1" "$rc"
assert_contains "timeout message" "timed out" "$out"
source "$SCRIPT_DIR/lib/utils.sh"; log_status() { :; }   # restore the real portable_timeout
RALPH_GH_VERIFY_CMD=""

echo ""
echo "=== run_verifier_gate (stubbed runner) ==="
git -C "$WS" init -q 2>/dev/null; git -C "$WS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
start=$(git -C "$WS" rev-parse HEAD)
RALPH_GH_VERIFIER_ENABLED=0
rc=0; run_verifier_gate "$WS" "o/r" "1" "t" "b" "$start" >/dev/null || rc=$?
assert_eq "disabled verifier → pass" "0" "$rc"
RALPH_GH_VERIFIER_ENABLED=1
rc=0; out=$(run_verifier_gate "$WS" "o/r" "1" "t" "b" "$start") || rc=$?
assert_eq "empty diff → fail" "1" "$rc"
echo "x" > "$WS/new.ts"
run_claude() { printf '%s' "$RALPH_TEST_VERIFIER_JSON" > "$3"; return "${RALPH_TEST_VERIFIER_RC:-0}"; }
RALPH_TEST_VERIFIER_JSON='{"type":"result","structured_output":{"verdict":"FAIL","criteria":[{"criterion":"A","met":true,"reason":"ok"},{"criterion":"B","met":false,"reason":"no test for B"}],"summary":"B missing"}}'
rc=0; out=$(run_verifier_gate "$WS" "o/r" "1" "t" "- [ ] A\n- [ ] B" "$start") || rc=$?
assert_eq "verifier FAIL → 1" "1" "$rc"
assert_contains "verifier lists unmet criteria" "- B — no test for B" "$out"
RALPH_TEST_VERIFIER_JSON='{"type":"result","structured_output":{"verdict":"PASS","criteria":[{"criterion":"A","met":true,"reason":"ok"}],"summary":"fine"}}'
rc=0; out=$(run_verifier_gate "$WS" "o/r" "1" "t" "b" "$start") || rc=$?
assert_eq "verifier PASS → 0" "0" "$rc"
RALPH_TEST_VERIFIER_JSON='{"type":"result","result":"crashed"}'
RALPH_TEST_VERIFIER_RC=1
rc=0; run_verifier_gate "$WS" "o/r" "1" "t" "b" "$start" >/dev/null || rc=$?
assert_eq "verifier infra failure → inconclusive pass" "0" "$rc"
unset -f run_claude; RALPH_TEST_VERIFIER_RC=0
diffs=$(ls "$RALPH_GH_STATE_DIR"/verifier/diff_1_*.patch | wc -l)
assert_eq "diff file was written for the verifier" "true" "$([[ $diffs -ge 1 ]] && echo true || echo false)"

echo ""
echo "=== orphan reaper ==="
# ralph-gh.sh runs the gates inside $(...) after cd'ing into the worktree, so
# the reaper's caller is a subshell whose cwd is the workspace. It must not
# reap itself (the #1132 postmortem: every verifier PASS was lost because the
# gate subshell was killed the moment the CLI exited).
mkdir -p "$TMP/reapws"
rc=0; out=$(cd "$TMP/reapws" && reap_workspace_orphans "$TMP/reapws" && echo survived) || rc=$?
assert_eq "reaper spares its own command-substitution subshell" "0:survived" "$rc:$out"
sleep 30 > /dev/null 2>&1 &
orphan=$!
( cd "$TMP/reapws" && reap_workspace_orphans "$TMP/reapws" >/dev/null 2>&1 )
kill -0 "$orphan" 2>/dev/null && orphan_alive=yes || orphan_alive=no
assert_eq "reaper ignores processes outside the workspace" "yes" "$orphan_alive"
kill "$orphan" 2>/dev/null || true
( cd "$TMP/reapws" && exec sleep 30 ) > /dev/null 2>&1 &
orphan=$!
sleep 0.2
reap_workspace_orphans "$TMP/reapws" >/dev/null 2>&1
kill -0 "$orphan" 2>/dev/null && orphan_alive=yes || orphan_alive=no
assert_eq "reaper kills a real orphan rooted in the workspace" "no" "$orphan_alive"

echo ""
echo "=== telemetry ==="
export RALPH_TELEMETRY_REPO="o/r" RALPH_TELEMETRY_PARENT="10" RALPH_TELEMETRY_SUB="11" RALPH_TELEMETRY_LOOP="2"
printf '%s' '{"type":"result","is_error":false,"num_turns":7,"duration_ms":60000,"total_cost_usd":1.25,"stop_reason":"end_turn","session_id":"s","permission_denials":[{"tool":"Bash"}],"structured_output":{"x":1},"modelUsage":{"claude-opus-5":{}},"usage":{"input_tokens":10,"output_tokens":20}}' > "$TMP/r.json"
telemetry_record_claude "$TMP/r.json" "implement" 0 "claude-opus-5"
last=$(tail -1 "$RALPH_GH_TELEMETRY_FILE")
assert_eq "claude event parent" "10" "$(printf '%s' "$last" | jq -r .parent)"
assert_eq "claude event loop" "2" "$(printf '%s' "$last" | jq -r .loop)"
assert_eq "claude event cost" "1.25" "$(printf '%s' "$last" | jq -r .cost_usd)"
assert_eq "claude event denials counted" "1" "$(printf '%s' "$last" | jq -r .permission_denials)"
assert_eq "claude event models_used" "claude-opus-5" "$(printf '%s' "$last" | jq -r '.models_used[0]')"
telemetry_record_outcome "pr_opened" "done"
stats=$(telemetry_stats "o/r")
assert_contains "stats table lists the parent" "10" "$stats"
assert_contains "stats shows outcome" "pr_opened" "$stats"
assert_contains "stats totals line" "claude calls" "$stats"
assert_eq "stats for unknown repo is empty table" "0" "$(telemetry_stats "nope/nope" | grep -c pr_opened)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
