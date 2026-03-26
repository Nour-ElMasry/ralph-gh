#!/usr/bin/env bash

# github_poller.sh - GitHub issue polling and task list parsing for ralph-gh

# Poll for parent issues with the target label
# Returns JSON array of candidate parent issues (oldest first)
poll_for_parent_issues() {
    local repo=$1
    local label=$2

    gh issue list \
        --repo "$repo" \
        --label "$label" \
        --state open \
        --limit 50 \
        --json number,title,body,createdAt \
        --jq 'sort_by(.createdAt)' < /dev/null 2>/dev/null
}

# Parse task list from issue body
# Extracts unchecked sub-issue numbers: - [ ] #N
# Returns one issue number per line
parse_task_list() {
    local body=$1

    echo "$body" | grep -oE '\- \[ \] #[0-9]+' | grep -oE '#[0-9]+' | sed 's/#//'
}

# Parse already-checked items from task list
# Returns one issue number per line
parse_completed_tasks() {
    local body=$1

    echo "$body" | grep -oE '\- \[[xX]\] #[0-9]+' | grep -oE '#[0-9]+' | sed 's/#//'
}

# Fetch detailed information about a sub-issue
fetch_sub_issue_details() {
    local repo=$1
    local issue_number=$2

    gh issue view "$issue_number" \
        --repo "$repo" \
        --json number,title,body,labels,comments < /dev/null 2>/dev/null
}

# Get just the title of an issue
get_issue_title() {
    local repo=$1
    local issue_number=$2

    gh issue view "$issue_number" \
        --repo "$repo" \
        --json title \
        --jq '.title' < /dev/null 2>/dev/null
}

# Get just the body of an issue
get_issue_body() {
    local repo=$1
    local issue_number=$2

    gh issue view "$issue_number" \
        --repo "$repo" \
        --json body \
        --jq '.body' < /dev/null 2>/dev/null
}

# Close a sub-issue with a comment
close_sub_issue() {
    local repo=$1
    local issue_number=$2
    local comment=$3

    gh issue close "$issue_number" \
        --repo "$repo" \
        --comment "$comment" < /dev/null 2>/dev/null
}

# Check off a sub-issue in the parent issue's task list (- [ ] #N → - [x] #N)
check_off_sub_issue() {
    local repo=$1
    local parent_number=$2
    local sub_number=$3

    local body
    body=$(get_issue_body "$repo" "$parent_number")
    if [[ -z "$body" ]]; then
        log_status "WARN" "Could not fetch body for parent #$parent_number, skipping checkbox update"
        return 0
    fi

    # Replace unchecked checkbox for this specific sub-issue number
    local new_body
    new_body=$(printf '%s\n' "$body" | sed "s/- \[ \] #${sub_number}\b/- [x] #${sub_number}/g")

    if [[ "$new_body" == "$body" ]]; then
        log_status "INFO" "Checkbox for #$sub_number already checked or not found in parent #$parent_number"
        return 0
    fi

    if ! gh issue edit "$parent_number" --repo "$repo" --body "$new_body" < /dev/null 2>/dev/null; then
        log_status "WARN" "Failed to update checkbox for #$sub_number in parent #$parent_number"
    else
        log_status "INFO" "Checked off #$sub_number in parent #$parent_number"
    fi

    return 0
}

# Remove a label from an issue
remove_label() {
    local repo=$1
    local issue_number=$2
    local label=$3

    gh issue edit "$issue_number" \
        --repo "$repo" \
        --remove-label "$label" < /dev/null 2>/dev/null
}

# Add a comment to an issue
comment_on_issue() {
    local repo=$1
    local issue_number=$2
    local body=$3

    gh issue comment "$issue_number" \
        --repo "$repo" \
        --body "$body" < /dev/null 2>/dev/null
}

# Check if gh CLI is available and authenticated
check_github_available() {
    if ! command -v gh &>/dev/null; then
        log_status "ERROR" "gh CLI not found. Install: https://cli.github.com/"
        return 1
    fi

    if ! gh auth status < /dev/null &>/dev/null; then
        log_status "ERROR" "gh CLI not authenticated. Run: gh auth login"
        return 1
    fi

    return 0
}

# Check that all sub-issues exist and are open
# Returns 0 if all exist and are open, 1 if any are missing or closed
# Outputs only the valid open sub-issue numbers (one per line)
validate_sub_issues() {
    local repo=$1
    shift
    local sub_issues=("$@")

    local all_valid=true
    local valid_subs=()

    for sub in "${sub_issues[@]}"; do
        local state
        state=$(gh issue view "$sub" --repo "$repo" --json state --jq '.state' < /dev/null 2>/dev/null)
        if [[ -z "$state" ]]; then
            log_status "WARN" "Sub-issue #$sub does not exist yet, deferring parent"
            all_valid=false
        elif [[ "$state" == "OPEN" ]]; then
            valid_subs+=("$sub")
        else
            log_status "WARN" "Sub-issue #$sub is not open (state: $state), skipping"
        fi
    done

    if [[ "$all_valid" == "false" ]]; then
        return 1
    fi

    printf '%s\n' "${valid_subs[@]}"
    return 0
}

export -f poll_for_parent_issues parse_task_list parse_completed_tasks
export -f fetch_sub_issue_details get_issue_title get_issue_body
export -f close_sub_issue check_off_sub_issue remove_label comment_on_issue
export -f check_github_available validate_sub_issues
