#!/usr/bin/env bash

# test_github_poller.sh - Smoke tests for task list parsing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/dag.sh"
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

echo "=== Task List Parsing Tests ==="

# Test 1: Basic unchecked items
body1="## Sub-Issues
- [ ] #12 Add validation
- [ ] #13 Update endpoint
- [x] #14 Already done"

result1=$(parse_task_list "$body1")
expected1="12
13"
assert_eq "Basic unchecked items" "$expected1" "$result1"

# Test 2: No sub-issues
body2="This is a regular issue with no task list"
result2=$(parse_task_list "$body2")
assert_eq "No sub-issues returns empty" "" "$result2"

# Test 3: All checked (no unchecked)
body3="## Sub-Issues
- [x] #10 Done
- [X] #11 Also done"
result3=$(parse_task_list "$body3")
assert_eq "All checked returns empty" "" "$result3"

# Test 4: Mixed content
body4="## Sub-Issues
Some text here
- [ ] #5 First task
More text
- [ ] #20 Second task
- [x] #30 Completed task"
result4=$(parse_task_list "$body4")
expected4="5
20"
assert_eq "Mixed content extracts correctly" "$expected4" "$result4"

# Test 5: Completed tasks parsing
result5=$(parse_completed_tasks "$body1")
expected5="14"
assert_eq "Completed tasks parsing" "$expected5" "$result5"

# Test 6: Single sub-issue
body6="## Sub-Issues
- [ ] #99 Only one task"
result6=$(parse_task_list "$body6")
assert_eq "Single sub-issue" "99" "$result6"

# Test 7: Checklists outside ## Sub-Issues are not sub-issues (#1364 shape)
body7="## Acceptance criteria
- [ ] #1311's paid-plan specs still pass unchanged

## Blocked by
- Blocked by #1311"
result7=$(parse_task_list "$body7")
assert_eq "Acceptance criterion naming an issue is not a sub-issue" "" "$result7"

# Test 8: Section ends at the next level-2 heading; CRLF heading tolerated
body8=$'## Sub-Issues\r\n- [ ] #40 Real slice\r\n\r\n## Acceptance criteria\r\n- [ ] #41 not a slice'
result8=$(parse_task_list "$body8")
assert_eq "Only the Sub-Issues section is parsed" "40" "$result8"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
