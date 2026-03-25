#!/usr/bin/env bash

# issue_worker.sh - Per-sub-issue Claude Code invocation for ralph-gh

# Build the prompt for a sub-issue by combining template + issue context
build_issue_prompt() {
    local template_file=$1
    local sub_issue_number=$2
    local sub_issue_title=$3
    local sub_issue_body=$4
    local parent_issue_number=$5
    local parent_issue_title=$6
    local completed_subs=$7

    local prompt
    prompt=$(cat "$template_file")

    # Replace placeholders
    prompt=$(echo "$prompt" | sed \
        -e "s|{{SUB_ISSUE_NUMBER}}|${sub_issue_number}|g" \
        -e "s|{{SUB_ISSUE_TITLE}}|${sub_issue_title}|g" \
        -e "s|{{PARENT_ISSUE_NUMBER}}|${parent_issue_number}|g" \
        -e "s|{{PARENT_ISSUE_TITLE}}|${parent_issue_title}|g" \
        -e "s|{{COMPLETED_SUBS}}|${completed_subs}|g")

    # Replace multi-line body separately (sed can't handle multi-line easily)
    # Use awk for the body replacement
    prompt=$(echo "$prompt" | awk -v body="$sub_issue_body" '{gsub(/\{\{SUB_ISSUE_BODY\}\}/, body); print}')

    echo "$prompt"
}

# Build the full prompt, combining project prompt + issue context
build_full_prompt() {
    local workspace=$1
    local sub_issue_number=$2
    local sub_issue_title=$3
    local sub_issue_body=$4
    local parent_issue_number=$5
    local parent_issue_title=$6
    local completed_subs=$7

    local prompt=""

    # Check for project-specific prompt
    if [[ -f "$workspace/.ralph/PROMPT.md" ]]; then
        prompt=$(cat "$workspace/.ralph/PROMPT.md")
        prompt+=$'\n\n---\n\n'
    fi

    # Add issue context section
    prompt+="## Current Task: #${sub_issue_number} - ${sub_issue_title}"
    prompt+=$'\n\n'
    prompt+="$sub_issue_body"
    prompt+=$'\n\n'
    prompt+="## Parent Context: #${parent_issue_number} - ${parent_issue_title}"
    prompt+=$'\n\n'
    prompt+="Previously completed sub-issues in this group: ${completed_subs:-none}"
    prompt+=$'\n\n'

    # Add AGENT.md build instructions if available
    if [[ -f "$workspace/.ralph/AGENT.md" ]]; then
        prompt+="## Build & Run Instructions"
        prompt+=$'\n\n'
        prompt+=$(cat "$workspace/.ralph/AGENT.md")
        prompt+=$'\n\n'
    fi

    # Add rules
    prompt+=$(cat <<'RULES'
## Rules
1. Search the codebase before assuming anything
2. Implementation > Documentation > Tests
3. Commit with descriptive conventional commit messages
4. Do NOT close issues or open PRs - that is handled externally
5. Do NOT modify .ralph-gh/ or .ralph/ state files

## Status Report (REQUIRED - end of every response)

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line>
---END_RALPH_STATUS---
```
RULES
)

    echo "$prompt"
}

# Execute Claude Code for a single sub-issue
# Returns: 0=success, 1=failure, 2=circuit-break
execute_for_sub_issue() {
    local workspace=$1
    local repo=$2
    local sub_issue_number=$3
    local parent_issue_number=$4
    local session_id=$5
    local allowed_tools=$6
    local timeout_minutes=$7

    local timeout_seconds=$((timeout_minutes * 60))

    # Fetch sub-issue details
    local sub_title sub_body
    sub_title=$(get_issue_title "$repo" "$sub_issue_number")
    sub_body=$(get_issue_body "$repo" "$sub_issue_number")

    if [[ -z "$sub_title" ]]; then
        log_status "ERROR" "Could not fetch details for sub-issue #$sub_issue_number"
        return 1
    fi

    # Fetch parent title
    local parent_title
    parent_title=$(get_issue_title "$repo" "$parent_issue_number")

    # Get completed subs for context
    local completed_subs_list
    completed_subs_list=$(get_completed_subs | tr '\n' ', ' | sed 's/,$//')
    if [[ -n "$completed_subs_list" ]]; then
        completed_subs_list=$(echo "$completed_subs_list" | sed 's/\([0-9]\+\)/#\1/g')
    fi

    log_status "LOOP" "Working on sub-issue #$sub_issue_number: $sub_title"

    # Build the prompt
    local prompt
    prompt=$(build_full_prompt \
        "$workspace" \
        "$sub_issue_number" \
        "$sub_title" \
        "$sub_body" \
        "$parent_issue_number" \
        "$parent_title" \
        "$completed_subs_list")

    # Build Claude CLI command
    local -a cmd_args=("claude")
    cmd_args+=("--output-format" "json")

    # Add allowed tools
    if [[ -n "$allowed_tools" ]]; then
        cmd_args+=("--allowedTools")
        local IFS=','
        read -ra tools_array <<< "$allowed_tools"
        for tool in "${tools_array[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                cmd_args+=("$tool")
            fi
        done
    fi

    # Add session resumption
    if [[ -n "$session_id" ]]; then
        cmd_args+=("--resume" "$session_id")
    fi

    # Add the prompt
    cmd_args+=("-p" "$prompt")

    # Execute with timeout
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_output_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Claude Code timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Claude Code exited with code $exit_code"
        return 1
    fi

    # Extract and save session ID for next sub-issue
    if [[ -f "$output_file" ]]; then
        local new_session_id
        # Handle both array and object JSON formats
        if jq -e 'type == "array"' "$output_file" > /dev/null 2>&1; then
            new_session_id=$(jq -r '[.[] | select(.type == "result")] | .[-1].session_id // .[-1].sessionId // empty' "$output_file" 2>/dev/null | head -1)
        else
            new_session_id=$(jq -r '.session_id // .sessionId // .metadata.session_id // empty' "$output_file" 2>/dev/null | head -1)
        fi

        if [[ -n "$new_session_id" && "$new_session_id" != "null" ]]; then
            echo "$new_session_id" > "$RALPH_GH_STATE_DIR/.claude_session_id"
            log_status "INFO" "Saved session: ${new_session_id:0:20}..."
        fi
    fi

    # Check response for progress indicators
    local has_changes=false
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi
    if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        has_changes=true
    fi

    # Check for STATUS: COMPLETE or BLOCKED in the response
    local response_status=""
    if [[ -f "$output_file" ]]; then
        local result_text
        if jq -e 'type == "array"' "$output_file" > /dev/null 2>&1; then
            result_text=$(jq -r '[.[] | select(.type == "result")] | .[-1].result // ""' "$output_file" 2>/dev/null)
        else
            result_text=$(jq -r '.result // ""' "$output_file" 2>/dev/null)
        fi

        if echo "$result_text" | grep -q "STATUS: COMPLETE"; then
            response_status="COMPLETE"
        elif echo "$result_text" | grep -q "STATUS: BLOCKED"; then
            response_status="BLOCKED"
            log_status "WARN" "Claude reported BLOCKED for sub-issue #$sub_issue_number"
            return 1
        fi
    fi

    if [[ "$has_changes" == "true" || "$response_status" == "COMPLETE" ]]; then
        log_status "SUCCESS" "Sub-issue #$sub_issue_number completed"
        return 0
    else
        log_status "WARN" "No changes detected for sub-issue #$sub_issue_number"
        return 1
    fi
}

# Get the saved session ID (for cross-sub-issue continuity)
get_saved_session_id() {
    local session_file="$RALPH_GH_STATE_DIR/.claude_session_id"
    if [[ -f "$session_file" ]]; then
        local sid
        sid=$(head -1 "$session_file" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$sid" && "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            echo "$sid"
            return 0
        fi
    fi
    echo ""
}

# Clear saved session (for starting fresh with a new parent group)
clear_saved_session() {
    rm -f "$RALPH_GH_STATE_DIR/.claude_session_id"
}

export -f build_issue_prompt build_full_prompt execute_for_sub_issue
export -f get_saved_session_id clear_saved_session
