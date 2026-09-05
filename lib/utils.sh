#!/usr/bin/env bash

# utils.sh - Logging and utility functions for ralph-gh

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Log with timestamp and level
log_status() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""

    case $level in
        "INFO")    color=$BLUE ;;
        "WARN")    color=$YELLOW ;;
        "ERROR")   color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP")    color=$PURPLE ;;
    esac

    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2 2>/dev/null

    # Write to log file if LOG_DIR is set
    if [[ -n "${LOG_DIR:-}" ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph-gh.log" 2>/dev/null
    fi
}

# Cross-platform timeout wrapper
# Sends TERM first, then KILL after 10s to ensure full cleanup
portable_timeout() {
    if command -v timeout &>/dev/null; then
        timeout --kill-after=10s "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout --kill-after=10s "$@"
    else
        # Fallback: run without timeout
        shift  # Remove the timeout duration arg
        "$@"
    fi
}

# Describe a process for the reap log: argv with NULs flattened, falling back
# to the comm name for kernel threads and truncated so one orphan is one line.
proc_cmdline() {
    local cmd
    cmd=$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    [[ -z "$cmd" ]] && cmd=$(cat "/proc/$1/comm" 2>/dev/null)
    printf '%.200s' "${cmd:-<gone>}"
}

proc_state() {
    local state
    state=$(awk '/^State:/{print $2}' "/proc/$1/status" 2>/dev/null)
    printf '%s' "${state:-?}"
}

# Kill orphaned processes still rooted in a workspace directory.
# `portable_timeout` signals only the Claude CLI process; shells and test
# runners it spawned (backgrounded jest, dev servers) get reparented to init
# and keep running — contending for the worktree's test database and poisoning
# every subsequent loop (#894 postmortem: orphaned jest runs made three
# 45-minute loops in a row look hung). Anything whose CWD is inside the
# workspace after the CLI died is such an orphan, except this script's own
# process chain, which cd'd into the worktree itself.
# The chain is walked from $BASHPID, not $$: the gates run inside $(...), and
# in that subshell $$ still names the main script, so the subshell doing the
# reaping is not $$ and would otherwise kill itself (#1132: five verifier
# PASS verdicts lost, circuit breaker tripped on the empty "failure").
# Linux /proc only; silently a no-op elsewhere (macOS).
reap_workspace_orphans() {
    local workspace=$1
    [[ -n "$workspace" && -d "$workspace" && -d /proc ]] || return 0

    local protected=" $$ $PPID ${BASHPID:-$$} "
    local p=${BASHPID:-$$}
    while [[ -n "$p" && "$p" != "0" && "$p" != "1" ]]; do
        p=$(grep -s '^PPid:' "/proc/$p/status" | awk '{print $2}')
        [[ -n "$p" ]] && protected+=" $p "
    done

    local pid_dir pid cwd victims=""
    for pid_dir in /proc/[0-9]*; do
        pid="${pid_dir##*/}"
        [[ "$protected" == *" $pid "* ]] && continue
        cwd=$(readlink "$pid_dir/cwd" 2>/dev/null) || continue
        if [[ "$cwd" == "$workspace" || "$cwd" == "$workspace"/* ]]; then
            victims+=" $pid"
        fi
    done
    [[ -z "$victims" ]] && return 0

    log_status "WARN" "Reaping orphaned process(es) still running in $workspace:$victims"
    for pid in $victims; do
        log_status "WARN" "  orphan $pid [$(proc_state "$pid")]: $(proc_cmdline "$pid")"
    done

    # shellcheck disable=SC2086  # word splitting of the pid list is intended
    kill -TERM $victims 2>/dev/null || true
    sleep 2
    # shellcheck disable=SC2086
    kill -KILL $victims 2>/dev/null || true
    sleep 1

    # SIGKILL is not always the end of it: a process wedged in uninterruptible
    # I/O only dies once the kernel releases it, and signalling can fail
    # outright. Such a survivor still holds the worktree's test database, so
    # name it instead of logging a reap that silently did nothing. Zombies are
    # already dead — their parent just hasn't reaped them.
    local survivors=""
    for pid in $victims; do
        [[ -d "/proc/$pid" && "$(proc_state "$pid")" != "Z" ]] && survivors+=" $pid"
    done
    [[ -z "$survivors" ]] && return 0

    log_status "ERROR" "Orphan(s) survived SIGKILL in $workspace:$survivors"
    for pid in $survivors; do
        log_status "ERROR" "  survivor $pid [$(proc_state "$pid")]: $(proc_cmdline "$pid")"
    done
    return 0
}

export -f log_status
export -f portable_timeout
export -f proc_cmdline
export -f proc_state
export -f reap_workspace_orphans
