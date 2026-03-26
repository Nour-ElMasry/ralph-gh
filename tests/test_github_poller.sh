#!/usr/bin/env bash

# test_github_poller.sh - Smoke tests for task list parsing

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
body1="## Tasks
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
body3="- [x] #10 Done
- [X] #11 Also done"
result3=$(parse_task_list "$body3")
assert_eq "All checked returns empty" "" "$result3"

# Test 4: Mixed content
body4="Some text here
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
body6="- [ ] #99 Only one task"
result6=$(parse_task_list "$body6")
assert_eq "Single sub-issue" "99" "$result6"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
