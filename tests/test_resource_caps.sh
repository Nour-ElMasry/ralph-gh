#!/usr/bin/env bash

# test_resource_caps.sh - Tests for the slice re-exec guard and its helpers.
#
# Covers:
#   - cgroup_in_slice: reads an injected cgroup file, matches only the named slice
#   - cgroup_slice_properties: the property list handed to systemctl
#   - cgroup_reexec_in_slice: returns (does not exec) when disabled, when
#                             already inside the slice, and when unsupported
#   - count_other_ralph_runs: counts held worktree locks, skips our own

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/resource_caps.sh"

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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== cgroup_in_slice ==="

printf '0::/user.slice/user-1000.slice/user@1000.service/ralph.slice/run-abc.scope\n' > "$TMP/inside"
printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-abc.scope\n' > "$TMP/outside"
printf '0::/init.scope\n' > "$TMP/init"

cgroup_in_slice "ralph.slice" "$TMP/inside" && r=inside || r=outside
assert_eq "matches a scope under the named slice" "inside" "$r"

cgroup_in_slice "ralph.slice" "$TMP/outside" && r=inside || r=outside
assert_eq "does not match a scope under app.slice" "outside" "$r"

cgroup_in_slice "ralph.slice" "$TMP/init" && r=inside || r=outside
assert_eq "does not match init.scope (WSL default)" "outside" "$r"

cgroup_in_slice "ralph.slice" "$TMP/missing" && r=inside || r=outside
assert_eq "missing cgroup file counts as outside" "outside" "$r"

echo "=== cgroup_slice_properties ==="

assert_eq "property list in systemctl form" \
    $'MemoryMax=6G\nMemorySwapMax=0\nCPUWeight=50' \
    "$(cgroup_slice_properties 6G 0 50)"

echo "=== cgroup_reexec_in_slice returns instead of exec-ing ==="

# Any exec here would replace the test shell, so a return is the whole assertion.
RALPH_GH_CGROUP=0 cgroup_reexec_in_slice /bin/true run 1
assert_eq "disabled → returns" "0" "$?"

cgroup_available() { return 0; }
cgroup_in_slice() { return 0; }
RALPH_GH_CGROUP=1 cgroup_reexec_in_slice /bin/true run 1
assert_eq "already inside the slice → returns" "0" "$?"

cgroup_in_slice() { return 1; }
cgroup_available() { return 1; }
warned=$(RALPH_GH_CGROUP=1 cgroup_reexec_in_slice /bin/true run 1 2>&1 >/dev/null)
assert_eq "unsupported host → returns with a WARN" "1" "$(grep -c 'running UNCAPPED' <<< "$warned")"

echo "=== count_other_ralph_runs ==="

mkdir -p "$TMP/workers"
assert_eq "no lock files → 0" "0" "$(count_other_ralph_runs "$TMP/workers" 7)"

touch "$TMP/workers/.lock-7" "$TMP/workers/.lock-8"
assert_eq "unheld lock files → 0" "0" "$(count_other_ralph_runs "$TMP/workers" 7)"

# Hold #8 from a background process the way a live run does.
(
    exec 8>"$TMP/workers/.lock-8"
    flock 8
    sleep 5
) &
holder=$!
sleep 0.3
assert_eq "held lock for another issue → 1" "1" "$(count_other_ralph_runs "$TMP/workers" 7)"

(
    exec 8>"$TMP/workers/.lock-7"
    flock 8
    sleep 5
) &
holder_own=$!
sleep 0.3
assert_eq "our own held lock is skipped" "1" "$(count_other_ralph_runs "$TMP/workers" 7)"
assert_eq "with no own issue every held lock counts" "2" "$(count_other_ralph_runs "$TMP/workers" "")"

kill "$holder" "$holder_own" 2>/dev/null
wait "$holder" "$holder_own" 2>/dev/null

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
