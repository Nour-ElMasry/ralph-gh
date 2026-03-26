#!/usr/bin/env bash

# state_manager.sh - JSON state persistence for ralph-gh
# Tracks in-progress work and processed parent issues

STATE_DIR="${RALPH_GH_STATE_DIR:-.ralph-gh}"
STATE_FILE="$STATE_DIR/state.json"

# Initialize state directory and file
init_state() {
    mkdir -p "$STATE_DIR"

    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" << 'EOF'
{
    "in_progress": null,
    "processed": [],
    "last_poll": null
}
EOF
    fi

    # Validate existing state file
    if ! jq '.' "$STATE_FILE" > /dev/null 2>&1; then
        log_status "WARN" "Corrupted state file, reinitializing"
        cat > "$STATE_FILE" << 'EOF'
{
    "in_progress": null,
    "processed": [],
    "last_poll": null
}
EOF
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

# Check if there's work in progress
get_in_progress() {
    jq -r '.in_progress // empty' "$STATE_FILE" 2>/dev/null
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
            "remaining_subs": $remaining
        } | .last_poll = $ts')

    save_state "$state"
}

# Mark a sub-issue as completed
mark_sub_complete() {
    local sub_number=$1

    local state
    state=$(load_state)
    state=$(echo "$state" | jq \
        --argjson sub "$sub_number" \
        '.in_progress.completed_subs += [$sub] |
         .in_progress.remaining_subs -= [$sub]')

    save_state "$state"
}

# Get remaining sub-issues
get_remaining_subs() {
    jq -r '.in_progress.remaining_subs[]' "$STATE_FILE" 2>/dev/null
}

# Get completed sub-issues
get_completed_subs() {
    jq -r '.in_progress.completed_subs[]' "$STATE_FILE" 2>/dev/null
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

# Update last poll timestamp
update_last_poll() {
    local state
    state=$(load_state)
    state=$(echo "$state" | jq --arg ts "$(get_iso_timestamp)" '.last_poll = $ts')
    save_state "$state"
}

export -f init_state load_state save_state
export -f get_in_progress has_in_progress set_in_progress
export -f mark_sub_complete get_remaining_subs get_completed_subs
export -f get_in_progress_parent get_in_progress_branch
export -f mark_parent_processed clear_in_progress is_processed
export -f update_last_poll
