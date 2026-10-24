#!/usr/bin/env bash

# test_baseline.sh - Tests for the verify gate's base-commit baseline.
#
# A red verify run that lists its failures in $RALPH_VERIFY_FAILURES_FILE is
# re-run on the sub-issue's start commit; failures already red there must not
# keep the gate red, new ones must, and anything inconclusive must leave the
# gate red. Runs against a real throwaway git repo with a stub verify script.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/verify_gate.sh"
source "$SCRIPT_DIR/lib/review_panel.sh"
source "$SCRIPT_DIR/lib/branch_manager.sh"
source "$SCRIPT_DIR/lib/worktree_manager.sh"

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
        echo "    Actual: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'git -C "$TMP/ws" worktree prune 2>/dev/null; rm -rf "$TMP"' EXIT
log_status() { :; }
export HOME="$TMP/home"
export RALPH_GH_STATE_DIR="$TMP/state"
export RALPH_GH_TELEMETRY_FILE="$TMP/telemetry.jsonl"
export RALPH_GH_VERIFY_BASELINE=1
mkdir -p "$HOME" "$RALPH_GH_STATE_DIR"

# The stub verify script: every line of failing.txt is a failing test. It
# records what it saw so the tests can check the environment it ran in.
# STUB_BASE_MODE changes only the baseline run: "nolist" goes red without a
# list, "timeout" reports a timeout, "green" passes, "killed" dies on SIGKILL
# after writing its list. STUB_BRANCH_KILLED does the same to the branch run.
STUB="$TMP/verify.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
if [[ "${RALPH_VERIFY_BASELINE:-}" == "1" ]]; then
    echo "run" >> "$STUB_LOG_DIR/baseline_runs"
    git diff --name-only "$RALPH_SUB_START_REF" | sort > "$STUB_LOG_DIR/baseline_scope"
    [[ -f .env ]] && echo yes > "$STUB_LOG_DIR/baseline_env" || echo no > "$STUB_LOG_DIR/baseline_env"
    case "${STUB_BASE_MODE:-}" in
        nolist) exit 1 ;;
        timeout) exit 124 ;;
        green) exit 0 ;;
        killed) cat failing.txt > "$RALPH_VERIFY_FAILURES_FILE"; kill -9 $$ ;;
    esac
else
    echo "${RALPH_VERIFY_BASELINE:-unset}" > "$STUB_LOG_DIR/branch_baseline_flag"
fi
echo "${RALPH_VERIFY_FAILURES_FILE:-unset}" > "$STUB_LOG_DIR/failures_file_${RALPH_VERIFY_BASELINE:-branch}"
[[ -s failing.txt ]] || exit 0
[[ -f nolist ]] || cat failing.txt > "$RALPH_VERIFY_FAILURES_FILE"
[[ -n "${STUB_BRANCH_KILLED:-}" && -z "${RALPH_VERIFY_BASELINE:-}" ]] && kill -9 $$
exit 1
EOF
export RALPH_GH_VERIFY_CMD="bash $STUB"
export STUB_LOG_DIR="$TMP/stub"
export RALPH_GH_REPO="o/r"

WS="$TMP/ws"
git init -q -b main "$WS"
git -C "$WS" config user.email t@t
git -C "$WS" config user.name t
printf 'old flaky\n' > "$WS/failing.txt"
printf 'x\n' > "$WS/src.txt"
echo ".env" > "$WS/.gitignore"
git -C "$WS" add -A
git -C "$WS" commit -qm base
BASE=$(git -C "$WS" rev-parse HEAD)
export RALPH_GH_WORKSPACE="$WS"
echo "SECRET=1" > "$WS/.env"

# Reset the workspace to the base commit plus the given failing list, and
# clear everything the stub and the gate remember between cases.
reset_case() {
    local failing=$1
    git -C "$WS" checkout -q "$BASE" -- .
    git -C "$WS" reset -q "$BASE"
    rm -f "$WS/nolist" "$WS/extra.txt"
    printf '%s' "$failing" > "$WS/failing.txt"
    rm -rf "$STUB_LOG_DIR" "$RALPH_GH_STATE_DIR/verify_baseline" "$HOME/.ralph-gh/pre_existing"
    mkdir -p "$STUB_LOG_DIR"
    unset STUB_BASE_MODE STUB_BRANCH_KILLED
}

run_gate() {
    GATE_OUT=$(run_verify_gate "$WS" "$BASE" 42)
    GATE_RC=$?
}

leftover_trees() {
    local n
    n=$(git -C "$WS" worktree list | wc -l)
    printf '%s/%s' "$((n - 1))" "$(find "$HOME/.ralph-gh/baselines" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
}

echo "=== only pre-existing failures ==="
reset_case $'old flaky\n'
printf 'y\n' > "$WS/src.txt"
run_gate
assert_eq "gate passes when every failure is red on base" "0" "$GATE_RC"
assert_eq "the baseline ran once" "1" "$(wc -l < "$STUB_LOG_DIR/baseline_runs")"
assert_eq "telemetry records baseline-only" "baseline-only: 1" "$(tail -1 "$RALPH_GH_TELEMETRY_FILE" | jq -r .detail)"
assert_eq "the gate hands the verifier what it let through" "old flaky" "$GATE_OUT"
assert_eq "the pre-existing failure is recorded with its base commit" "old flaky	$BASE" "$(cat "$(pre_existing_failures_file 42)")"
assert_contains "the PR section lists it as red on main" "- \`old flaky\` — red at \`${BASE:0:8}\` (on \`main\`)" "$(pre_existing_failures_section 42)"
assert_eq "no worktree is left behind" "0/0" "$(leftover_trees)"

echo ""
echo "=== environment of each run ==="
assert_eq "RALPH_VERIFY_BASELINE is not set on the branch run" "unset" "$(cat "$STUB_LOG_DIR/branch_baseline_flag")"
assert_contains "the branch run gets a failures file" "$RALPH_GH_STATE_DIR/logs/verify_" "$(cat "$STUB_LOG_DIR/failures_file_branch")"
assert_contains "the baseline run gets a failures file" "$RALPH_GH_STATE_DIR/verify_baseline/run-" "$(cat "$STUB_LOG_DIR/failures_file_1")"
assert_eq "the baseline is scoped to the branch's changed files" "src.txt" "$(cat "$STUB_LOG_DIR/baseline_scope")"
assert_eq "untracked env files are copied into the base worktree" "yes" "$(cat "$STUB_LOG_DIR/baseline_env")"

echo ""
echo "=== a new failure ==="
reset_case $'old flaky\nnew break\n'
run_gate
assert_eq "gate stays red" "1" "$GATE_RC"
assert_contains "retry context lists the new failure" $'fix them:\n\n- new break' "$GATE_OUT"
assert_contains "retry context names the pre-existing one" $'leave them unless a criterion asks you to fix them:\n\n- old flaky' "$GATE_OUT"
assert_eq "nothing is recorded for the PR" "" "$(pre_existing_failures_section 42)"
assert_eq "telemetry counts the new failures" "exit 1, 1 new" "$(tail -1 "$RALPH_GH_TELEMETRY_FILE" | jq -r .detail)"

echo ""
echo "=== no overlap with base ==="
reset_case $'brand new\n'
git -C "$WS" commit -qam "branch work"
run_gate
assert_eq "a failure base does not share keeps the gate red" "1" "$GATE_RC"
assert_eq "committed branch work is in the baseline's scope" "failing.txt" "$(cat "$STUB_LOG_DIR/baseline_scope")"
assert_not_contains "no pre-existing section without an overlap" "leave them" "$GATE_OUT"

echo ""
echo "=== base is green ==="
reset_case $'old flaky\n'
export STUB_BASE_MODE=green
run_gate
assert_eq "a red branch over a green base stays red" "1" "$GATE_RC"
assert_contains "every failure is reported as new" $'fix them:\n\n- old flaky' "$GATE_OUT"

echo ""
echo "=== no failure list ==="
reset_case $'old flaky\n'
touch "$WS/nolist"
run_gate
assert_eq "a red run without a list stays red" "1" "$GATE_RC"
assert_eq "and never runs the baseline" "no" "$([[ -f "$STUB_LOG_DIR/baseline_runs" ]] && echo yes || echo no)"

echo ""
echo "=== a killed run ==="
reset_case $'old flaky\n'
export STUB_BRANCH_KILLED=1
run_gate
assert_eq "a branch run killed by a signal stays red" "1" "$GATE_RC"
assert_eq "and its cut-off list never reaches the baseline" "no" "$([[ -f "$STUB_LOG_DIR/baseline_runs" ]] && echo yes || echo no)"
reset_case $'old flaky\n'
export STUB_BASE_MODE=killed
run_gate
assert_eq "a baseline killed by a signal leaves the gate red" "1" "$GATE_RC"
assert_eq "and is not cached" "0" "$(find "$RALPH_GH_STATE_DIR/verify_baseline" -name '*-*.failures' | wc -l)"

echo ""
echo "=== baseline disabled ==="
reset_case $'old flaky\n'
RALPH_GH_VERIFY_BASELINE=0 run_gate
assert_eq "RALPH_GH_VERIFY_BASELINE=0 keeps the gate red" "1" "$GATE_RC"
assert_eq "and skips the baseline" "no" "$([[ -f "$STUB_LOG_DIR/baseline_runs" ]] && echo yes || echo no)"

echo ""
echo "=== inconclusive baseline ==="
reset_case $'old flaky\n'
export STUB_BASE_MODE=nolist
run_gate
assert_eq "a red baseline without a list leaves the gate red" "1" "$GATE_RC"
assert_eq "no worktree is left behind" "0/0" "$(leftover_trees)"
assert_eq "an inconclusive baseline is not cached" "0" "$(find "$RALPH_GH_STATE_DIR/verify_baseline" -name '*.failures' | wc -l)"
reset_case $'old flaky\n'
export STUB_BASE_MODE=timeout
run_gate
assert_eq "a timed-out baseline leaves the gate red" "1" "$GATE_RC"
assert_eq "no worktree is left behind after a timeout" "0/0" "$(leftover_trees)"
reset_case $'old flaky\n'
GATE_OUT=$(run_verify_gate "$WS" "0000000000000000000000000000000000000000" 42); GATE_RC=$?
assert_eq "an unknown base ref leaves the gate red" "1" "$GATE_RC"

echo ""
echo "=== cache ==="
reset_case $'old flaky\n'
printf 'y\n' > "$WS/src.txt"
run_gate
printf 'z\n' > "$WS/src.txt"
run_gate
assert_eq "same changed files reuse the baseline" "1" "$(wc -l < "$STUB_LOG_DIR/baseline_runs")"
assert_eq "the reused baseline still passes the gate" "0" "$GATE_RC"
echo "new" > "$WS/extra.txt"
run_gate
assert_eq "a new file whose failures are all known reuses the baseline" "1" "$(wc -l < "$STUB_LOG_DIR/baseline_runs")"
printf 'old flaky\nunseen\n' > "$WS/failing.txt"
run_gate
assert_eq "a failure no cached run names re-runs the baseline" "2" "$(wc -l < "$STUB_LOG_DIR/baseline_runs")"
assert_eq "the re-run sees the untracked file in scope" $'extra.txt\nfailing.txt\nsrc.txt' "$(cat "$STUB_LOG_DIR/baseline_scope")"
assert_eq "and the unseen failure keeps the gate red" "1" "$GATE_RC"
assert_eq "the workspace index is untouched by the snapshot" "" "$(git -C "$WS" diff --cached --name-only)"

echo ""
echo "=== stale base worktrees ==="
reset_case $'old flaky\n'
mkdir -p "$HOME/.ralph-gh/baselines/wt-dead-4194303" "$HOME/.ralph-gh/baselines/wt-live-$$"
printf 'y\n' > "$WS/src.txt"
run_gate
assert_eq "a tree whose run is gone is reaped" "no" "$([[ -d "$HOME/.ralph-gh/baselines/wt-dead-4194303" ]] && echo yes || echo no)"
assert_eq "a tree whose run is alive is kept" "yes" "$([[ -d "$HOME/.ralph-gh/baselines/wt-live-$$" ]] && echo yes || echo no)"
rm -rf "$HOME/.ralph-gh/baselines/wt-live-$$"

echo ""
echo "=== snapshot sees a racily clean edit ==="
# Same size, same mtime second as the checkout that wrote the index entry:
# git trusts its stat data unless the index itself is no older than the file.
reset_case $'old flaky\n'
checkout_mtime=$(stat -c %Y "$WS/src.txt")
printf 'y\n' > "$WS/src.txt"
touch -d "@$checkout_mtime" "$WS/src.txt"
sleep 1.1
snapshot=$(_verify_tree_snapshot "$WS")
assert_eq "the snapshot holds the edit" "y" "$(git -C "$WS" show "$snapshot:src.txt")"

echo ""
echo "=== interrupted baseline ==="
reset_case $'old flaky\n'
cat > "$TMP/slow.sh" <<'EOF2'
#!/usr/bin/env bash
if [[ "${RALPH_VERIFY_BASELINE:-}" == "1" ]]; then
    touch "$STUB_LOG_DIR/started"
    sleep 30
fi
cat failing.txt > "$RALPH_VERIFY_FAILURES_FILE"
exit 1
EOF2
cat > "$TMP/driver.sh" <<EOF2
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/telemetry.sh"
source "$SCRIPT_DIR/lib/verify_gate.sh"
log_status() { :; }
RALPH_GH_VERIFY_CMD="bash $TMP/slow.sh" run_verify_gate "$WS" "$BASE" 42
EOF2
# Its own session, then TERM to the whole session: how systemd stops a scope.
setsid bash "$TMP/driver.sh" >/dev/null 2>&1 &
driver_pid=$!
for _ in $(seq 1 100); do [[ -f "$STUB_LOG_DIR/started" ]] && break; sleep 0.1; done
assert_eq "the baseline was running when interrupted" "1/1" "$(leftover_trees)"
driver_sid=$(ps -o sid= -p "$driver_pid" | tr -d ' ')
pkill -TERM -s "$driver_sid"
wait "$driver_pid" 2>/dev/null
# The cleanup runs in the gate's subshell, which outlives the driver.
for _ in $(seq 1 100); do pgrep -s "$driver_sid" >/dev/null || break; sleep 0.1; done
assert_eq "a terminated baseline removes its worktree" "0/0" "$(leftover_trees)"

echo ""
echo "=== PR bodies ==="
reset_case ""
SIDE=$(git -C "$WS" commit-tree "$BASE^{tree}" -p "$BASE" -m "an earlier sub-issue")
record_pre_existing_failures 42 $'b failure\na failure' "$SIDE"
record_pre_existing_failures 42 $'b failure\nc failure' "$BASE"
gh() {
    local arg prev=""
    for arg in "$@"; do
        [[ "$prev" == "--body" ]] && printf '%s' "$arg" > "$TMP/pr_body"
        prev=$arg
    done
    [[ "$1 $2" == "pr list" ]] && return 0
    echo "https://example/pr/1"
}
open_pr "o/r" "ralph/issue-42" "main" 42 "title" "- #43" >/dev/null 2>&1
body=$(cat "$TMP/pr_body")
assert_contains "open_pr lists the pre-existing failures, sorted, one line each" \
    $'- `a failure` — red at `'"${SIDE:0:8}"$'` (this branch only)\n- `b failure` — red at `'"${SIDE:0:8}"$'` (this branch only)\n- `c failure` — red at `'"${BASE:0:8}"$'` (on `main`)\n\n---' "$body"
assert_contains "the section says why a branch-only commit matters" "may have been caused by an earlier sub-issue" "$body"
open_draft_pr "o/r" "ralph/issue-42" "main" 42 "title" "- #43" "held" >/dev/null 2>&1
assert_contains "open_draft_pr lists them too" '- `a failure`' "$(cat "$TMP/pr_body")"
open_pr "o/r" "ralph/issue-7" "main" 7 "title" "- #8" >/dev/null 2>&1
assert_not_contains "a parent with none gets no section" "Pre-existing" "$(cat "$TMP/pr_body")"
assert_eq "the list outlives every run's state dir" "$HOME/.ralph-gh/pre_existing/o_r-9.txt" "$(RALPH_GH_STATE_DIR="$TMP/sub" pre_existing_failures_file 9)"

echo ""
echo "=== verifier prompt ==="
prompt=$(build_verifier_prompt 5 "t" "- [ ] a" "$TMP/d.patch" "$BASE" "" "bash verify.sh" $'old flaky')
assert_contains "the verifier hears which failures are still red" $'These are still RED:\n\n    old flaky' "$prompt"
assert_contains "and that a criterion asking for them is not met" "A criterion that asks for any of these to pass or be fixed is NOT met." "$prompt"
assert_contains "a green run still reads as exit 0" "on this exact tree and it
exited 0." "$(build_verifier_prompt 5 "t" "- [ ] a" "$TMP/d.patch" "$BASE" "" "bash verify.sh")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
