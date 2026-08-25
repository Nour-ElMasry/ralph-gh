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

# Kill orphaned processes still rooted in a workspace directory.
# `portable_timeout` signals only the Claude CLI process; shells and test
# runners it spawned (backgrounded jest, dev servers) get reparented to init
# and keep running — contending for the worktree's test database and poisoning
# every subsequent loop (#894 postmortem: orphaned jest runs made three
# 45-minute loops in a row look hung). Anything whose CWD is inside the
# workspace after the CLI died is such an orphan, except this script's own
# process chain, which cd'd into the worktree itself.
# Linux /proc only; silently a no-op elsewhere (macOS).
reap_workspace_orphans() {
    local workspace=$1
    [[ -n "$workspace" && -d "$workspace" && -d /proc ]] || return 0

    local protected=" $$ $PPID "
    local p=$PPID
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
    # shellcheck disable=SC2086  # word splitting of the pid list is intended
    kill -TERM $victims 2>/dev/null || true
    sleep 2
    kill -KILL $victims 2>/dev/null || true
    return 0
}

export -f log_status
export -f portable_timeout
export -f reap_workspace_orphans
