#!/usr/bin/env bash

# test_dag.sh - Tests for the DAG parser, validator, and scheduling primitives.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/dag.sh"

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

assert_jq_eq() {
    local test_name=$1
    local expected_json=$2
    local actual_json=$3
    # Normalize via jq -S so key order doesn't matter
    local e a
    e=$(echo "$expected_json" | jq -S .)
    a=$(echo "$actual_json" | jq -S .)
    assert_eq "$test_name" "$e" "$a"
}

echo "=== DAG Parser Tests ==="

# Test 1: All slices independent (depends_on: [])
body1='## Sub-Issues

- [ ] #522 outbound idempotency keys
  depends_on: []
- [ ] #523 persist webhook payload
  depends_on: []
- [ ] #524 reconciliation cron
  depends_on: [#522, #523]
'
result1=$(dag_parse_body "$body1")
assert_jq_eq "Three slices, last depends on first two" \
    '{"subs":[522,523,524],"deps":{"522":[],"523":[],"524":[522,523]}}' \
    "$result1"

# Test 2: Legacy serial fallback when depends_on missing
body2='## Sub-Issues

- [ ] #100 first
- [ ] #101 second
- [ ] #102 third
'
result2=$(dag_parse_body "$body2")
assert_jq_eq "Missing depends_on falls back to serial" \
    '{"subs":[100,101,102],"deps":{"100":[],"101":[100],"102":[101]}}' \
    "$result2"

# Test 3: Mixed (some declared, some legacy)
body3='## Sub-Issues

- [ ] #1 first
  depends_on: []
- [ ] #2 second (legacy fallback to depend on #1)
- [ ] #3 third
  depends_on: [#1]
'
result3=$(dag_parse_body "$body3")
assert_jq_eq "Mixed declared/legacy" \
    '{"subs":[1,2,3],"deps":{"1":[],"2":[1],"3":[1]}}' \
    "$result3"

# Test 4: No sub-issues
body4='Just a regular issue body, no checklist.'
result4=$(dag_parse_body "$body4")
assert_jq_eq "Empty body → empty DAG" \
    '{"subs":[],"deps":{}}' \
    "$result4"

# Test 5: Single sub-issue
body5='- [ ] #99 only one
  depends_on: []
'
result5=$(dag_parse_body "$body5")
assert_jq_eq "Single sub-issue" \
    '{"subs":[99],"deps":{"99":[]}}' \
    "$result5"

# Test 6: depends_on with single dep, no leading #
body6='- [ ] #10 first
  depends_on: []
- [ ] #20 second
  depends_on: [10]
'
result6=$(dag_parse_body "$body6")
assert_jq_eq "depends_on tolerates missing # prefix" \
    '{"subs":[10,20],"deps":{"10":[],"20":[10]}}' \
    "$result6"

# Test 7: Already-checked items still parsed
body7='- [x] #5 done
- [ ] #6 todo
  depends_on: [#5]
'
result7=$(dag_parse_body "$body7")
assert_jq_eq "Checked items still appear in DAG" \
    '{"subs":[5,6],"deps":{"5":[],"6":[5]}}' \
    "$result7"

echo ""
echo "=== DAG Validator Tests ==="

# Test 8: Valid DAG
dag_valid='{"subs":[1,2,3],"deps":{"1":[],"2":[1],"3":[1,2]}}'
if dag_validate "$dag_valid" 2>/dev/null; then
    echo "  [PASS] Valid DAG accepted"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] Valid DAG rejected"
    FAIL=$((FAIL + 1))
fi

# Test 9: Cycle detection
dag_cycle='{"subs":[1,2,3],"deps":{"1":[3],"2":[1],"3":[2]}}'
if dag_validate "$dag_cycle" 2>/dev/null; then
    echo "  [FAIL] Cycle DAG accepted (should reject)"
    FAIL=$((FAIL + 1))
else
    echo "  [PASS] Cycle DAG rejected"
    PASS=$((PASS + 1))
fi

# Test 10: Self-loop
dag_self='{"subs":[1,2],"deps":{"1":[1],"2":[]}}'
if dag_validate "$dag_self" 2>/dev/null; then
    echo "  [FAIL] Self-loop accepted"
    FAIL=$((FAIL + 1))
else
    echo "  [PASS] Self-loop rejected"
    PASS=$((PASS + 1))
fi

# Test 11: Unknown dep
dag_unknown='{"subs":[1,2],"deps":{"1":[],"2":[999]}}'
if dag_validate "$dag_unknown" 2>/dev/null; then
    echo "  [FAIL] Unknown dep accepted"
    FAIL=$((FAIL + 1))
else
    echo "  [PASS] Unknown dep rejected"
    PASS=$((PASS + 1))
fi

echo ""
echo "=== DAG Scheduler Tests ==="

# Test 12: Compute ready with no merged yet → only zero-dep subs
dag='{"subs":[522,523,524],"deps":{"522":[],"523":[],"524":[522,523]}}'
ready=$(dag_compute_ready "$dag" '[]' '[]' '[522,523,524]')
assert_jq_eq "Initial ready = zero-dep subs" '[522,523]' "$ready"

# Test 13: Compute ready after one merge
ready2=$(dag_compute_ready "$dag" '[522]' '[]' '[523,524]')
assert_jq_eq "Ready after #522 merged" '[523]' "$ready2"

# Test 14: Compute ready after both merge
ready3=$(dag_compute_ready "$dag" '[522,523]' '[]' '[524]')
assert_jq_eq "Ready after both deps merged" '[524]' "$ready3"

# Test 15: Cascade failure — #524 should be marked failed if dep failed
cascaded=$(dag_compute_cascade_failures "$dag" '[522]' '[523,524]')
assert_jq_eq "Cascade failure when dep failed" '[524]' "$cascaded"

# Test 16: No cascade if dep merged
cascaded2=$(dag_compute_cascade_failures "$dag" '[]' '[523,524]')
assert_jq_eq "No cascade with no failures" '[]' "$cascaded2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
