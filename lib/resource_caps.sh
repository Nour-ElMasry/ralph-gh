#!/usr/bin/env bash

# resource_caps.sh - keep a ralph run from taking the machine down.
#
# Every `ralph-gh run` re-executes itself inside a transient systemd scope
# under one shared slice (default ralph.slice). The slice carries the memory
# and CPU limits, so N concurrent runs share ONE ceiling instead of each
# adding an uncapped Claude session, test workers, typechecks and builds on
# top of whatever else the box is doing. When the ceiling is hit, the kernel
# OOM-kills the largest process inside the slice (a test worker, a build) and
# that one command fails; the rest of the machine stays responsive.
#
# The scope itself carries OOMPolicy=continue. systemd's default for a scope
# is `stop`: one OOM-killed process anywhere in the scope makes systemd
# SIGTERM everything else in it, i.e. the whole run aborts to a draft PR —
# and because the kernel picks its victim from the entire slice, run A's
# build spike could abort run B. Three overlapping runs died that way on
# 2026-09-06. With `continue` only the killed process is lost; the command
# that spawned it fails and the run carries on.
#
# MemoryMax defaults to `auto`: 75% of MemTotal, so the ceiling follows the
# machine (and a resized WSL VM) instead of a number frozen in a config file.
# A slice pinned at its ceiling does not just OOM-kill: it evicts and
# re-reads file cache continuously, which shows up as the disk at 100%. Size
# for headroom, not for the bare minimum.
#
# Why a slice and not per-scope properties: on WSL2 (systemd 255) a scope
# created under the default app.slice never gets memory.max applied even
# when MemoryMax is passed, whereas a named slice does. Verified 2026-09-06.
#
# Where systemd-run is unavailable (macOS, no user manager) the run proceeds
# uncapped with a WARN — behaviour identical to before this file existed.

RALPH_GH_CGROUP="${RALPH_GH_CGROUP:-1}"                    # 0 disables the re-exec
RALPH_GH_CGROUP_SLICE="${RALPH_GH_CGROUP_SLICE:-ralph.slice}"
RALPH_GH_MEMORY_MAX="${RALPH_GH_MEMORY_MAX:-auto}"        # shared by every concurrent run; auto = 75% of MemTotal
RALPH_GH_MEMORY_SWAP_MAX="${RALPH_GH_MEMORY_SWAP_MAX:-0}"  # 0 = fail fast, never thrash into swap
RALPH_GH_CPU_WEIGHT="${RALPH_GH_CPU_WEIGHT:-50}"          # default weight is 100; interactive work wins ties

# True when the calling process already lives under the slice.
#   $1 = slice name
#   $2 = cgroup file to inspect (default /proc/self/cgroup; injectable for tests)
cgroup_in_slice() {
    local slice=$1
    local cgroup_file=${2:-/proc/self/cgroup}
    [[ -f "$cgroup_file" ]] || return 1
    grep -q "/${slice}/" "$cgroup_file"
}

# True when a transient scope can actually be created under the slice.
#   $1 = slice name
cgroup_available() {
    local slice=$1
    command -v systemd-run >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemd-run --user --scope --quiet --slice="$slice" -- true >/dev/null 2>&1
}

# Resolve the configured MemoryMax to a concrete size. `auto` becomes 75% of
# MemTotal rounded down to whole GiB (never below 2G); anything else passes
# through untouched. Without /proc/meminfo (macOS) `auto` falls back to 6G.
#   $1 = configured value
#   $2 = meminfo file to read (default /proc/meminfo; injectable for tests)
cgroup_resolve_memory_max() {
    local configured=$1
    local meminfo=${2:-/proc/meminfo}
    [[ "$configured" == "auto" ]] || { printf '%s' "$configured"; return 0; }

    local total_kb
    total_kb=$(awk '/^MemTotal:/{print $2}' "$meminfo" 2>/dev/null)
    [[ "$total_kb" =~ ^[0-9]+$ ]] || { printf '6G'; return 0; }

    local gib=$(( total_kb * 3 / 4 / 1048576 ))
    (( gib < 2 )) && gib=2
    printf '%dG' "$gib"
}

# The systemd property assignments for the slice, one per line.
#   $1 = MemoryMax, $2 = MemorySwapMax, $3 = CPUWeight
cgroup_slice_properties() {
    printf 'MemoryMax=%s\nMemorySwapMax=%s\nCPUWeight=%s\n' "$1" "$2" "$3"
}

# The systemd property assignments for the per-run scope, one per line.
cgroup_scope_properties() {
    printf 'OOMPolicy=continue\n'
}

# Apply the limits to the slice (runtime only — nothing persists past reboot;
# every run re-applies, so the numbers in config are always the live ones).
#   $1 = slice name
cgroup_apply_slice_limits() {
    local slice=$1
    local -a props=()
    local line
    while IFS= read -r line; do
        props+=("$line")
    done < <(cgroup_slice_properties "$RALPH_GH_MEMORY_MAX" "$RALPH_GH_MEMORY_SWAP_MAX" "$RALPH_GH_CPU_WEIGHT")

    local err
    if ! err=$(systemctl --user set-property --runtime "$slice" "${props[@]}" 2>&1 >/dev/null); then
        log_status "WARN" "Could not set limits on $slice: $err"
        return 1
    fi
    return 0
}

# Re-exec the current script inside the slice unless already there.
# Never returns when it re-execs; returns 0 when the run should simply
# continue in place (disabled, already inside, or unsupported).
#   $1 = absolute path of the script to re-exec
#   $@ = the script's original arguments
cgroup_reexec_in_slice() {
    local script=$1
    shift

    # Resolved here, after config load, so both the parent and the re-exec'd
    # child (which re-sources the same `auto`) log the concrete figure.
    RALPH_GH_MEMORY_MAX=$(cgroup_resolve_memory_max "$RALPH_GH_MEMORY_MAX")

    [[ "$RALPH_GH_CGROUP" == "1" ]] || return 0
    cgroup_in_slice "$RALPH_GH_CGROUP_SLICE" && return 0

    if ! cgroup_available "$RALPH_GH_CGROUP_SLICE"; then
        log_status "WARN" "systemd-run --user unavailable — running UNCAPPED (set RALPH_GH_CGROUP=0 to silence)"
        return 0
    fi

    cgroup_apply_slice_limits "$RALPH_GH_CGROUP_SLICE" || return 0

    local -a scope_props=()
    local line
    while IFS= read -r line; do
        scope_props+=(--property="$line")
    done < <(cgroup_scope_properties)

    log_status "INFO" "Re-launching inside $RALPH_GH_CGROUP_SLICE (MemoryMax=$RALPH_GH_MEMORY_MAX MemorySwapMax=$RALPH_GH_MEMORY_SWAP_MAX CPUWeight=$RALPH_GH_CPU_WEIGHT, shared by every concurrent run; OOMPolicy=continue)"
    exec systemd-run --user --scope --quiet --slice="$RALPH_GH_CGROUP_SLICE" "${scope_props[@]}" -- "$script" "$@"
}

# Count targeted runs other than ours that currently hold a worktree lock.
# Runs share the slice ceiling, so the caller warns when this is non-zero.
#   $1 = worktree base directory
#   $2 = our own issue number (may be empty)
count_other_ralph_runs() {
    local base=$1
    local own=${2:-}
    local count=0
    local lock
    for lock in "$base"/.lock-*; do
        [[ -e "$lock" ]] || continue
        [[ -n "$own" && "$lock" == "$base/.lock-$own" ]] && continue
        if ! flock -n "$lock" true 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

export -f cgroup_in_slice cgroup_available cgroup_slice_properties
export -f cgroup_resolve_memory_max cgroup_scope_properties
export -f cgroup_apply_slice_limits cgroup_reexec_in_slice count_other_ralph_runs
