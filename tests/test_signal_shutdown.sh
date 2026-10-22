#!/usr/bin/env bash

# test_signal_shutdown.sh - Tests for shutdown_on_signal.
#
# A TERM must log one shutdown line and take the run's process group down.
# The handler's own `kill 0` reaches the handling shell too; with the trap
# still set, it re-caught that TERM and logged thousands of lines a second.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A run stand-in in its own process group, with a child to take down.
setsid bash -c '
    echo $$ > "$1/pid"
    source "$2/lib/utils.sh"
    trap shutdown_on_signal INT TERM
    sleep 30 &
    echo $! > "$1/child"
    wait
' _ "$TMP" "$SCRIPT_DIR" > /dev/null 2> "$TMP/log" < /dev/null &
for _ in $(seq 1 50); do [[ -s "$TMP/child" ]] && break; sleep 0.1; done
run_pid=$(cat "$TMP/pid")
child_pid=$(cat "$TMP/child")
kill -TERM "$run_pid"
for _ in $(seq 1 50); do kill -0 "$run_pid" 2>/dev/null || break; sleep 0.1; done

echo "shutdown_on_signal:"
assert_eq "logs the shutdown once" "1" "$(grep -c 'Caught signal, shutting down' "$TMP/log")"
assert_eq "the run exits" "gone" "$(kill -0 "$run_pid" 2>/dev/null && echo alive || echo gone)"
assert_eq "the run's children exit" "gone" "$(kill -0 "$child_pid" 2>/dev/null && echo alive || echo gone)"
kill -KILL -- "-$run_pid" 2>/dev/null

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
