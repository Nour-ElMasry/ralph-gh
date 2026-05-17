#!/usr/bin/env bash

# test_skip_label.sh - Tests for the HITL skip-label feature.
#
# Covers:
#   - state_manager: mark_sub_held / has_held_subs / get_held_subs
#                    and the DAG-bucket side effects
#   - set_in_progress initializes held_subs to []
#   - github_poller: issue_has_skip_label honors empty env (no-op) and
#                    matches/rejects labels via a mocked gh
#   - poll-time JSON filter logic (the jq expression used in ralph-gh.sh
#                                  to drop held parents from the poll list)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/state_manager.sh"
source "$SCRIPT_DIR/lib/github_poller.sh"

PASS=0
FAIL=0

assert_eq() {
    local test_name=$1
    local expected=$2
    local actual=$3

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

assert_true() {
    local test_name=$1
    local rc=$2
    if [[ "$rc" == "0" ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name (rc=$rc)"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local test_name=$1
    local rc=$2
    if [[ "$rc" != "0" ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name (rc=$rc, expected non-zero)"
        FAIL=$((FAIL + 1))
    fi
}

assert_jq_eq() {
    local test_name=$1
    local expected_json=$2
    local actual_json=$3
    local e a
    e=$(echo "$expected_json" | jq -S .)
    a=$(echo "$actual_json" | jq -S .)
    assert_eq "$test_name" "$e" "$a"
}

# Each test gets a clean state dir under /tmp so we don't clobber a real run.
# Mutates parent shell globals (STATE_DIR/STATE_FILE/CURRENT_TMPDIR) directly —
# don't call via $() because that subshells the assignments away.
fresh_state() {
    CURRENT_TMPDIR=$(mktemp -d /tmp/ralph_skip_test.XXXXXX)
    export STATE_DIR="$CURRENT_TMPDIR"
    export STATE_FILE="$CURRENT_TMPDIR/state.json"
    init_state
}

# ============================================================================
# set_in_progress initializes held_subs: []
# ============================================================================
echo "=== set_in_progress initializes held_subs ==="

fresh_state
set_in_progress 100 "ralph/issue-100" 201 202 203
held_init=$(jq -c '.in_progress.held_subs' "$STATE_FILE")
assert_eq "held_subs initialized to []" "[]" "$held_init"
rm -rf "$CURRENT_TMPDIR"

# ============================================================================
# mark_sub_held — no-DAG path: moves from remaining to held only
# ============================================================================
echo ""
echo "=== mark_sub_held (no DAG) ==="

fresh_state
set_in_progress 100 "ralph/issue-100" 201 202 203
mark_sub_held 202

remaining=$(jq -c '.in_progress.remaining_subs' "$STATE_FILE")
held=$(jq -c '.in_progress.held_subs' "$STATE_FILE")
completed=$(jq -c '.in_progress.completed_subs' "$STATE_FILE")

assert_jq_eq "remaining no longer contains the held sub" "[201,203]" "$remaining"
assert_jq_eq "held_subs contains the held sub" "[202]" "$held"
assert_jq_eq "completed_subs untouched" "[]" "$completed"
rm -rf "$CURRENT_TMPDIR"

# ============================================================================
# mark_sub_held — with DAG: routes through dag.merged so dependents promote
# ============================================================================
echo ""
echo "=== mark_sub_held (with DAG, dependents promote anyway) ==="

fresh_state
# Hand-craft an in_progress with a DAG where 202 and 203 both depend on 201.
cat > "$STATE_FILE" <<'EOF'
{
  "in_progress": {
    "parent": 100,
    "branch": "ralph/issue-100",
    "completed_subs": [],
    "remaining_subs": [201, 202, 203],
    "held_subs": [],
    "dag": {
      "raw": {"subs":[201,202,203],"deps":{"201":[],"202":[201],"203":[201]}},
      "ready":   [201],
      "running": [],
      "merged":  [],
      "failed":  [],
      "blocked": [202, 203]
    }
  },
  "processed": [],
  "last_poll": null
}
EOF

mark_sub_held 201

assert_jq_eq "dag.ready no longer contains held sub" "[]"        "$(jq -c '.in_progress.dag.ready' "$STATE_FILE")"
assert_jq_eq "dag.merged now contains held sub"     "[201]"      "$(jq -c '.in_progress.dag.merged' "$STATE_FILE")"
assert_jq_eq "dag.blocked still contains dependents" "[202,203]" "$(jq -c '.in_progress.dag.blocked' "$STATE_FILE")"
assert_jq_eq "held_subs records the sub"             "[201]"     "$(jq -c '.in_progress.held_subs' "$STATE_FILE")"
assert_jq_eq "completed_subs NOT touched"            "[]"        "$(jq -c '.in_progress.completed_subs' "$STATE_FILE")"
assert_jq_eq "remaining_subs drops the held sub"     "[202,203]" "$(jq -c '.in_progress.remaining_subs' "$STATE_FILE")"

# After mark_sub_held, dag_compute_ready (used by dag_state_promote_ready)
# should now consider 202 and 203 ready because their only dep (201) is merged.
source "$SCRIPT_DIR/lib/dag.sh"
dag_raw=$(jq -c '.in_progress.dag.raw'    "$STATE_FILE")
dag_merged=$(jq -c '.in_progress.dag.merged' "$STATE_FILE")
dag_failed=$(jq -c '.in_progress.dag.failed' "$STATE_FILE")
dag_blocked=$(jq -c '.in_progress.dag.blocked' "$STATE_FILE")
newly_ready=$(dag_compute_ready "$dag_raw" "$dag_merged" "$dag_failed" "$dag_blocked")
assert_jq_eq "dag_compute_ready promotes dependents now that held sub is in merged" \
    "[202,203]" "$newly_ready"

rm -rf "$CURRENT_TMPDIR"

# ============================================================================
# has_held_subs / get_held_subs reflect the held state
# ============================================================================
echo ""
echo "=== has_held_subs / get_held_subs ==="

fresh_state
set_in_progress 100 "ralph/issue-100" 201 202 203

has_held_subs
rc=$?
assert_false "has_held_subs false when none held" "$rc"

mark_sub_held 202
has_held_subs
rc=$?
assert_true "has_held_subs true after holding one" "$rc"

got=$(get_held_subs | tr '\n' ' ' | sed 's/ $//')
assert_eq "get_held_subs returns the held id" "202" "$got"

mark_sub_held 203
got=$(get_held_subs | sort -n | tr '\n' ' ' | sed 's/ $//')
assert_eq "get_held_subs returns multiple ids" "202 203" "$got"
rm -rf "$CURRENT_TMPDIR"

# ============================================================================
# issue_has_skip_label — empty env is a no-op (returns false unconditionally)
# ============================================================================
echo ""
echo "=== issue_has_skip_label (empty env) ==="

# No gh mock needed: empty env should short-circuit before calling gh.
RALPH_GH_SKIP_LABEL="" issue_has_skip_label "owner/repo" 999
rc=$?
assert_false "empty RALPH_GH_SKIP_LABEL → not held (no gh call)" "$rc"

# ============================================================================
# issue_has_skip_label — gh mock returning labels, hit/miss
# ============================================================================
echo ""
echo "=== issue_has_skip_label (mocked gh) ==="

# Override gh as a shell function. Bash function lookup beats $PATH, so this
# shadows the real binary just for this test scope. We accept any args and
# branch on issue number: 555 → has hitl, 666 → no hitl.
gh() {
    # Only the `gh issue view <num> --json labels` path is exercised here.
    if [[ "$1" == "issue" && "$2" == "view" ]]; then
        local num=$3
        case "$num" in
            555) echo '{"labels":[{"name":"ralph"},{"name":"hitl"}]}' ;;
            666) echo '{"labels":[{"name":"ralph"}]}' ;;
            *)   return 1 ;;
        esac
        return 0
    fi
    return 1
}
export -f gh

RALPH_GH_SKIP_LABEL="hitl" issue_has_skip_label "owner/repo" 555
rc=$?
assert_true "issue with hitl label is detected as held" "$rc"

RALPH_GH_SKIP_LABEL="hitl" issue_has_skip_label "owner/repo" 666
rc=$?
assert_false "issue without hitl label is not held" "$rc"

# A label substring shouldn't false-positive: skip label "lock" vs label "blocked"
gh() {
    if [[ "$1" == "issue" && "$2" == "view" ]]; then
        echo '{"labels":[{"name":"blocked"}]}'
        return 0
    fi
    return 1
}
export -f gh

RALPH_GH_SKIP_LABEL="lock" issue_has_skip_label "owner/repo" 777
rc=$?
assert_false "label 'blocked' does not match skip label 'lock' (no substring match)" "$rc"

unset -f gh

# ============================================================================
# Poll-time JSON filter — the jq expression used in poll_and_process
# ============================================================================
echo ""
echo "=== poll-time JSON filter ==="

# This mirrors the filter applied to the output of poll_for_parent_issues.
poll_json='[
    {"number": 1, "title": "A", "body": "", "createdAt": "2026-01-01", "labels": [{"name":"ralph"}]},
    {"number": 2, "title": "B", "body": "", "createdAt": "2026-01-02", "labels": [{"name":"ralph"},{"name":"hitl"}]},
    {"number": 3, "title": "C", "body": "", "createdAt": "2026-01-03", "labels": [{"name":"ralph"}]}
]'

# With skip label set: parent #2 should drop out
filtered=$(echo "$poll_json" | jq --arg skip "hitl" \
    'map(select(([.labels[].name] | index($skip)) == null)) | map(.number)')
assert_jq_eq "skip-label filter drops the parent carrying the hold label" \
    "[1,3]" "$filtered"

# With empty skip label, ralph-gh skips the jq pass entirely. Verify that
# applying an identity (no filter) leaves the list intact — sanity check that
# the wrapping `if [[ -n ... ]]` is the right place to gate the filter.
unfiltered=$(echo "$poll_json" | jq 'map(.number)')
assert_jq_eq "without skip-label filter, all parents pass" \
    "[1,2,3]" "$unfiltered"

# ============================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
