#!/usr/bin/env bash

# state_manager.sh - JSON state persistence for ralph-gh
# Tracks in-progress work and processed parent issues

STATE_DIR="${RALPH_GH_STATE_DIR:-.ralph-gh}"
STATE_FILE="$STATE_DIR/state.json"

# Write a fresh default state file
_write_default_state() {
    mkdir -p "$STATE_DIR"
    cat > "$STATE_FILE" << 'EOF'
{
    "in_progress": null,
    "processed": [],
    "last_poll": null
}
EOF
}

# Initialize state directory and file
init_state() {
    mkdir -p "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        _write_default_state
    fi

    # Validate existing state file
    if ! jq '.' "$STATE_FILE" > /dev/null 2>&1; then
        log_status "WARN" "Corrupted state file, reinitializing"
        _write_default_state
    fi
}

# Read the full state
load_state() {
    cat "$STATE_FILE"
}

# Atomic write to state file
save_state() {
    local new_state=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    local tmp_file="${STATE_FILE}.tmp"
    echo "$new_state" > "$tmp_file"
    mv "$tmp_file" "$STATE_FILE"
}

# Check if in_progress is set (non-null)
has_in_progress() {
    local ip
    ip=$(jq -r '.in_progress' "$STATE_FILE" 2>/dev/null)
    [[ "$ip" != "null" && -n "$ip" ]]
}

# Set in_progress for a new parent issue group
set_in_progress() {
    local parent_number=$1
    local branch_name=$2
    shift 2
    local remaining_subs=("$@")

    # Build JSON array of remaining sub-issues
    local subs_json
    subs_json=$(printf '%s\n' "${remaining_subs[@]}" | jq -R 'tonumber' | jq -s '.')

    local state
    state=$(load_state)
    state=$(echo "$state" | jq \
        --argjson parent "$parent_number" \
        --arg branch "$branch_name" \
        --argjson remaining "$subs_json" \
        --arg ts "$(get_iso_timestamp)" \
        '.in_progress = {
            "parent": $parent,
            "branch": $branch,
            "completed_subs": [],
            "remaining_subs": $remaining,
            "held_subs": []
        } | .last_poll = $ts')

    save_state "$state"
}

# Mark a sub-issue as completed
mark_sub_complete() {
    local sub_number=$1

    local state
    state=$(load_state) || { log_status "ERROR" "Failed to load state for mark_sub_complete"; return 1; }
    local new_state
    new_state=$(echo "$state" | jq \
        --argjson sub "$sub_number" \
        '.in_progress.completed_subs += [$sub] |
         .in_progress.remaining_subs -= [$sub]') || { log_status "ERROR" "jq failed in mark_sub_complete"; return 1; }

    save_state "$new_state"
}

# Get remaining sub-issues
get_remaining_subs() {
    jq -r '.in_progress.remaining_subs[]' "$STATE_FILE" 2>/dev/null
}

# Get completed sub-issues
get_completed_subs() {
    jq -r '.in_progress.completed_subs[]' "$STATE_FILE" 2>/dev/null
}

# Mark a sub-issue as held (deferred for human review via skip-label).
# Removes from remaining_subs (so the serial loop won't re-pick), adds to
# held_subs, and — if a DAG is active — moves the sub into the `merged` bucket
# so dependents promote. The held sub is NOT added to completed_subs, so
# complete_group won't close it or tick its checkbox.
mark_sub_held() {
    local sub_number=$1

    local state
    state=$(load_state) || { log_status "ERROR" "Failed to load state for mark_sub_held"; return 1; }

    local new_state
    new_state=$(echo "$state" | jq \
        --argjson sub "$sub_number" \
        '.in_progress.held_subs       = ((.in_progress.held_subs // []) + [$sub] | unique)
       | .in_progress.remaining_subs -= [$sub]
       | if (.in_progress.dag // null) != null then
             .in_progress.dag.ready   -= [$sub]
           | .in_progress.dag.running -= [$sub]
           | .in_progress.dag.blocked -= [$sub]
           | .in_progress.dag.merged   = ((.in_progress.dag.merged // []) + [$sub] | unique)
         else .
         end') || { log_status "ERROR" "jq failed in mark_sub_held"; return 1; }

    save_state "$new_state"
}

# Get held sub-issues (skip-labeled, deferred this run).
get_held_subs() {
    jq -r '.in_progress.held_subs[]?' "$STATE_FILE" 2>/dev/null
}

# True if any sub-issue has been held this run.
has_held_subs() {
    local count
    count=$(jq -r '(.in_progress.held_subs // []) | length' "$STATE_FILE" 2>/dev/null)
    [[ -n "$count" && "$count" != "0" ]]
}

# Get the parent issue number from in_progress
get_in_progress_parent() {
    jq -r '.in_progress.parent' "$STATE_FILE" 2>/dev/null
}

# Get the branch name from in_progress
get_in_progress_branch() {
    jq -r '.in_progress.branch' "$STATE_FILE" 2>/dev/null
}

# Mark parent as processed and clear in_progress
mark_parent_processed() {
    local parent_number=$1

    local state
    state=$(load_state)
    state=$(echo "$state" | jq \
        --argjson parent "$parent_number" \
        '.processed += [$parent] | .in_progress = null')

    save_state "$state"
}

# Clear in_progress without marking as processed (for failures)
clear_in_progress() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq '.in_progress = null')
    save_state "$state"
}

# Check if a parent issue has already been processed
is_processed() {
    local parent_number=$1
    jq -e --argjson n "$parent_number" '.processed | index($n) != null' "$STATE_FILE" > /dev/null 2>&1
}

# Clear the processed list (for fresh runs)
clear_processed() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq '.processed = []')
    save_state "$state"
}

# Update last poll timestamp
update_last_poll() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --arg ts "$(get_iso_timestamp)" '.last_poll = $ts')
    save_state "$state"
}

# =============================================================================
# DAG state for parallel execution.
#
# When a parent's body declares `depends_on:` lines, the orchestrator stores
# the DAG plus per-sub execution state under .in_progress.dag:
#   "dag": {
#     "raw":     <dag JSON from dag_parse_body>,
#     "ready":   [<sub_id>, ...],   -- waiting for capacity
#     "running": [<sub_id>, ...],   -- background workers in flight
#     "merged":  [<sub_id>, ...],   -- squash-merged into parent branch
#     "failed":  [<sub_id>, ...],   -- terminal failure or dep-failure cascade
#     "blocked": [<sub_id>, ...]    -- deps not yet satisfied
#   }
# Invariant: every sub appears in EXACTLY ONE bucket. Mutations go through
# the dag_state_* helpers below. Legacy state without this field continues to
# work via the old serial loop.
# =============================================================================

# Initialize .in_progress.dag from a raw dag JSON. All subs start `blocked`;
# the scheduler then promotes zero-dep subs to `ready` via dag_state_promote_ready.
dag_state_init() {
    local dag_json=$1
    local subs_json
    subs_json=$(echo "$dag_json" | jq '.subs')

    local state
    state=$(load_state)
    state=$(echo "$state" | jq \
        --argjson dag "$dag_json" \
        --argjson subs "$subs_json" \
        '.in_progress.dag = {
            "raw": $dag,
            "ready":   [],
            "running": [],
            "merged":  [],
            "failed":  [],
            "blocked": $subs
        }')
    save_state "$state"
}

dag_state_get() { jq -c '.in_progress.dag // null' "$STATE_FILE" 2>/dev/null; }

dag_state_active() {
    local d
    d=$(dag_state_get)
    [[ -n "$d" && "$d" != "null" ]]
}

# Promote all currently-blocked subs whose deps are all merged.
# Echoes JSON array of newly-promoted sub ids.
dag_state_promote_ready() {
    local state dag merged failed blocked newly_ready
    state=$(load_state)
    dag=$(echo "$state" | jq -c '.in_progress.dag.raw')
    merged=$(echo "$state" | jq -c '.in_progress.dag.merged')
    failed=$(echo "$state" | jq -c '.in_progress.dag.failed')
    blocked=$(echo "$state" | jq -c '.in_progress.dag.blocked')

    newly_ready=$(dag_compute_ready "$dag" "$merged" "$failed" "$blocked")
    if [[ "$(echo "$newly_ready" | jq 'length')" == "0" ]]; then
        echo '[]'
        return 0
    fi

    state=$(echo "$state" | jq \
        --argjson promoted "$newly_ready" \
        '.in_progress.dag.ready   += $promoted
       | .in_progress.dag.blocked -= $promoted')
    save_state "$state"
    echo "$newly_ready"
}

# Cascade-fail blocked subs whose deps include a failed sub.
dag_state_cascade_failures() {
    local state dag failed blocked cascaded
    state=$(load_state)
    dag=$(echo "$state" | jq -c '.in_progress.dag.raw')
    failed=$(echo "$state" | jq -c '.in_progress.dag.failed')
    blocked=$(echo "$state" | jq -c '.in_progress.dag.blocked')

    cascaded=$(dag_compute_cascade_failures "$dag" "$failed" "$blocked")
    if [[ "$(echo "$cascaded" | jq 'length')" == "0" ]]; then
        echo '[]'
        return 0
    fi

    state=$(echo "$state" | jq \
        --argjson cascaded "$cascaded" \
        '.in_progress.dag.failed  += $cascaded
       | .in_progress.dag.blocked -= $cascaded')
    save_state "$state"
    echo "$cascaded"
}

dag_state_mark_running() {
    local sub=$1
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --argjson s "$sub" \
        '.in_progress.dag.ready   -= [$s]
       | .in_progress.dag.running += [$s]')
    save_state "$state"
}

dag_state_mark_merged() {
    local sub=$1
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --argjson s "$sub" \
        '.in_progress.dag.running -= [$s]
       | .in_progress.dag.merged += [$s]
       | .in_progress.completed_subs += [$s]
       | .in_progress.remaining_subs -= [$s]')
    save_state "$state"
}

dag_state_mark_failed() {
    local sub=$1
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --argjson s "$sub" \
        '.in_progress.dag.running -= [$s]
       | .in_progress.dag.failed += [$s]
       | .in_progress.remaining_subs -= [$s]')
    save_state "$state"
}

dag_state_running_count() { jq '.in_progress.dag.running | length' "$STATE_FILE" 2>/dev/null; }
dag_state_ready_count()   { jq '.in_progress.dag.ready   | length' "$STATE_FILE" 2>/dev/null; }
dag_state_blocked_count() { jq '.in_progress.dag.blocked | length' "$STATE_FILE" 2>/dev/null; }
dag_state_failed_count()  { jq '.in_progress.dag.failed  | length' "$STATE_FILE" 2>/dev/null; }

dag_state_running_subs() { jq -r '.in_progress.dag.running[]' "$STATE_FILE" 2>/dev/null; }
dag_state_ready_subs()   { jq -r '.in_progress.dag.ready[]'   "$STATE_FILE" 2>/dev/null; }
dag_state_merged_subs()  { jq -r '.in_progress.dag.merged[]'  "$STATE_FILE" 2>/dev/null; }
dag_state_failed_subs()  { jq -r '.in_progress.dag.failed[]'  "$STATE_FILE" 2>/dev/null; }

# Pop the next ready sub. Removes from `ready` so concurrent reapers don't
# double-spawn; caller must call dag_state_mark_running afterwards.
dag_state_pop_ready() {
    local state next
    state=$(load_state)
    next=$(echo "$state" | jq -r '.in_progress.dag.ready[0] // empty')
    if [[ -z "$next" || "$next" == "null" ]]; then
        return 1
    fi
    state=$(echo "$state" | jq --argjson s "$next" \
        '.in_progress.dag.ready -= [$s]')
    save_state "$state"
    echo "$next"
}

# Lock helper for state mutations across background reapers/spawners.
with_dag_state_lock() {
    local lock_file="${DAG_STATE_LOCK:-$STATE_DIR/.dag.lock}"
    mkdir -p "$(dirname "$lock_file")"
    (
        flock -x 200
        "$@"
    ) 200>"$lock_file"
}

export -f init_state load_state save_state
export -f has_in_progress set_in_progress
export -f mark_sub_complete get_remaining_subs get_completed_subs
export -f mark_sub_held get_held_subs has_held_subs
export -f get_in_progress_parent get_in_progress_branch
export -f mark_parent_processed clear_in_progress is_processed clear_processed
export -f update_last_poll
export -f dag_state_init dag_state_get dag_state_active
export -f dag_state_promote_ready dag_state_cascade_failures
export -f dag_state_mark_running dag_state_mark_merged dag_state_mark_failed
export -f dag_state_running_count dag_state_ready_count dag_state_blocked_count dag_state_failed_count
export -f dag_state_running_subs dag_state_ready_subs dag_state_merged_subs dag_state_failed_subs
export -f dag_state_pop_ready with_dag_state_lock
