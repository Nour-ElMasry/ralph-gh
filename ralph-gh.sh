#!/usr/bin/env bash
set -euo pipefail

# ralph-gh - Autonomous GitHub Issue Worker
# Polls GitHub for labeled parent issues, works through sub-issues sequentially,
# and opens PRs when done.

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Source library modules
source "$SCRIPT_DIR/lib/date_utils.sh"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/state_manager.sh"
source "$SCRIPT_DIR/lib/github_poller.sh"
source "$SCRIPT_DIR/lib/branch_manager.sh"
source "$SCRIPT_DIR/lib/circuit_breaker.sh"
source "$SCRIPT_DIR/lib/issue_worker.sh"

# =============================================================================
# DEFAULTS
# =============================================================================

RALPH_GH_REPO="${RALPH_GH_REPO:-}"
RALPH_GH_WORKSPACE="${RALPH_GH_WORKSPACE:-}"
RALPH_GH_LABEL="${RALPH_GH_LABEL:-ralph}"
RALPH_GH_POLL_INTERVAL="${RALPH_GH_POLL_INTERVAL:-1800}"
RALPH_GH_MAIN_BRANCH="${RALPH_GH_MAIN_BRANCH:-main}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"
RALPH_GH_ALLOWED_TOOLS="${RALPH_GH_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pnpm *),Bash(node *),Bash(find *)}"
CB_NO_PROGRESS_THRESHOLD="${CB_NO_PROGRESS_THRESHOLD:-3}"
CB_SAME_ERROR_THRESHOLD="${CB_SAME_ERROR_THRESHOLD:-5}"
RALPH_GH_MAX_LOOPS_PER_ISSUE="${RALPH_GH_MAX_LOOPS_PER_ISSUE:-5}"  # Max Claude invocations per sub-issue
RALPH_GH_MAX_LOOPS_TOTAL="${RALPH_GH_MAX_LOOPS_TOTAL:-0}"          # Max total invocations per parent group (0=unlimited)

# =============================================================================
# CONFIG LOADING (3-layer: defaults -> global -> project)
# =============================================================================

load_config() {
    # Layer 2: Global config
    local global_config="$HOME/.ralph-gh/ralph-gh.conf"
    if [[ -f "$global_config" ]]; then
        log_status "INFO" "Loading global config: $global_config"
        # shellcheck source=/dev/null
        source "$global_config"
    fi

    # Layer 3: Project config (.ralphrc at workspace root)
    if [[ -n "$RALPH_GH_WORKSPACE" && -f "$RALPH_GH_WORKSPACE/.ralphrc" ]]; then
        log_status "INFO" "Loading project config: $RALPH_GH_WORKSPACE/.ralphrc"
        # shellcheck source=/dev/null
        source "$RALPH_GH_WORKSPACE/.ralphrc"

        # Map .ralphrc variable names to ralph-gh names
        [[ -n "${ALLOWED_TOOLS:-}" ]] && RALPH_GH_ALLOWED_TOOLS="$ALLOWED_TOOLS"
        [[ -n "${PROJECT_NAME:-}" ]] && log_status "INFO" "Project: $PROJECT_NAME"
    fi

    # Set derived paths
    export RALPH_GH_STATE_DIR="$RALPH_GH_WORKSPACE/.ralph-gh"
    export LOG_DIR="$RALPH_GH_STATE_DIR/logs"

    # Update circuit breaker and state manager paths
    CB_STATE_FILE="$RALPH_GH_STATE_DIR/.circuit_breaker_state"
    STATE_DIR="$RALPH_GH_STATE_DIR"
    STATE_FILE="$RALPH_GH_STATE_DIR/state.json"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_environment() {
    local errors=0

    # Check required config
    if [[ -z "$RALPH_GH_REPO" ]]; then
        log_status "ERROR" "RALPH_GH_REPO is not set (e.g., 'owner/repo')"
        errors=$((errors + 1))
    fi

    if [[ -z "$RALPH_GH_WORKSPACE" ]]; then
        log_status "ERROR" "RALPH_GH_WORKSPACE is not set (path to local repo clone)"
        errors=$((errors + 1))
    elif [[ ! -d "$RALPH_GH_WORKSPACE" ]]; then
        log_status "ERROR" "RALPH_GH_WORKSPACE does not exist: $RALPH_GH_WORKSPACE"
        errors=$((errors + 1))
    elif [[ ! -d "$RALPH_GH_WORKSPACE/.git" ]]; then
        log_status "ERROR" "RALPH_GH_WORKSPACE is not a git repo: $RALPH_GH_WORKSPACE"
        errors=$((errors + 1))
    fi

    # Check claude CLI
    if ! command -v claude &>/dev/null; then
        log_status "ERROR" "claude CLI not found. Install: npm install -g @anthropic-ai/claude-code"
        errors=$((errors + 1))
    fi

    # Check gh CLI
    if ! check_github_available; then
        errors=$((errors + 1))
    fi

    # Check jq
    if ! command -v jq &>/dev/null; then
        log_status "ERROR" "jq not found. Install: apt install jq / brew install jq"
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        log_status "ERROR" "Validation failed with $errors error(s). Exiting."
        exit 1
    fi

    log_status "SUCCESS" "Environment validated"
}

# =============================================================================
# WORK LOOP - Process a parent issue group
# =============================================================================

process_parent_group() {
    local parent_number
    parent_number=$(get_in_progress_parent)
    local branch_name
    branch_name=$(get_in_progress_branch)

    log_status "INFO" "Processing parent issue #$parent_number on branch $branch_name"
    log_status "INFO" "Loops per sub-issue: $RALPH_GH_MAX_LOOPS_PER_ISSUE | Total limit: ${RALPH_GH_MAX_LOOPS_TOTAL:-unlimited}"

    local total_loops=0

    # Reset circuit breaker for this group
    reset_circuit_breaker

    # Clear session from any previous group
    clear_saved_session

    # Create/checkout the branch
    ensure_latest_main "$RALPH_GH_MAIN_BRANCH"
    if ! create_branch "$branch_name" "$RALPH_GH_MAIN_BRANCH"; then
        log_status "ERROR" "Failed to create branch $branch_name"
        abort_group "$parent_number" "$branch_name" "Failed to create branch"
        return 1
    fi

    # Process each remaining sub-issue sequentially
    local remaining_subs
    remaining_subs=$(get_remaining_subs)

    if [[ -z "$remaining_subs" ]]; then
        log_status "WARN" "No remaining sub-issues for parent #$parent_number"
        complete_group "$parent_number" "$branch_name"
        return 0
    fi

    while IFS= read -r sub_number; do
        [[ -z "$sub_number" ]] && continue

        log_status "LOOP" "=== Sub-issue #$sub_number ==="

        # Loop per sub-issue: re-invoke Claude until it reports COMPLETE or hits the limit
        local loop_count=0
        local sub_done=false

        while [[ "$sub_done" == "false" ]]; do
            loop_count=$((loop_count + 1))
            total_loops=$((total_loops + 1))

            # Check max loops per sub-issue
            if [[ $loop_count -gt $RALPH_GH_MAX_LOOPS_PER_ISSUE ]]; then
                log_status "ERROR" "Sub-issue #$sub_number hit max loops ($RALPH_GH_MAX_LOOPS_PER_ISSUE), stopping group"
                abort_group "$parent_number" "$branch_name" \
                    "Sub-issue #$sub_number exceeded max loops ($RALPH_GH_MAX_LOOPS_PER_ISSUE). Claude could not complete in time."
                return 1
            fi

            # Check max total loops for the group
            if [[ $RALPH_GH_MAX_LOOPS_TOTAL -gt 0 && $total_loops -gt $RALPH_GH_MAX_LOOPS_TOTAL ]]; then
                log_status "ERROR" "Parent #$parent_number hit max total loops ($RALPH_GH_MAX_LOOPS_TOTAL), stopping group"
                abort_group "$parent_number" "$branch_name" \
                    "Parent group exceeded max total loops ($RALPH_GH_MAX_LOOPS_TOTAL)."
                return 1
            fi

            # Check circuit breaker
            if ! can_execute; then
                log_status "ERROR" "Circuit breaker is open, aborting group"
                abort_group "$parent_number" "$branch_name" "Circuit breaker opened: $(show_circuit_status)"
                return 1
            fi

            log_status "INFO" "Sub-issue #$sub_number — loop $loop_count/$RALPH_GH_MAX_LOOPS_PER_ISSUE (total: $total_loops)"

            # Get session ID for continuity across loops and sub-issues
            local session_id
            session_id=$(get_saved_session_id)

            # Execute Claude for this sub-issue
            local result=0
            execute_for_sub_issue \
                "$RALPH_GH_WORKSPACE" \
                "$RALPH_GH_REPO" \
                "$sub_number" \
                "$parent_number" \
                "$session_id" \
                "$RALPH_GH_ALLOWED_TOOLS" \
                "$CLAUDE_TIMEOUT_MINUTES" || result=$?

            if [[ $result -eq 0 ]]; then
                # Success — commit changes and mark done
                local sub_title
                sub_title=$(get_issue_title "$RALPH_GH_REPO" "$sub_number")
                commit_changes "$sub_number" "$sub_title"
                mark_sub_complete "$sub_number"
                record_result "true" "false"
                log_status "SUCCESS" "Sub-issue #$sub_number completed in $loop_count loop(s)"
                sub_done=true
            else
                # Failure — record and check circuit breaker
                record_result "false" "true"

                if ! can_execute; then
                    log_status "ERROR" "Circuit breaker tripped on sub-issue #$sub_number (loop $loop_count)"
                    abort_group "$parent_number" "$branch_name" \
                        "Circuit breaker opened while working on sub-issue #$sub_number (loop $loop_count)"
                    return 1
                fi

                # Still within limits — will retry on next iteration of while loop
                log_status "WARN" "Sub-issue #$sub_number loop $loop_count failed, retrying..."
            fi
        done
    done <<< "$remaining_subs"

    # All sub-issues completed successfully
    complete_group "$parent_number" "$branch_name"
    return 0
}

# Complete a parent group: push, PR, close sub-issues, remove label
complete_group() {
    local parent_number=$1
    local branch_name=$2

    log_status "SUCCESS" "All sub-issues for parent #$parent_number completed!"

    # Push branch
    if ! push_branch "$branch_name"; then
        log_status "ERROR" "Failed to push branch $branch_name"
        return 1
    fi

    # Determine if this is a standalone issue (parent == only sub-issue)
    local completed_subs
    completed_subs=$(get_completed_subs)
    local is_standalone=false
    if [[ "$(echo "$completed_subs" | tr -d '[:space:]')" == "$parent_number" ]]; then
        is_standalone=true
    fi

    # Get parent title
    local parent_title
    parent_title=$(get_issue_title "$RALPH_GH_REPO" "$parent_number")

    if [[ "$is_standalone" == "true" ]]; then
        # Standalone issue — PR closes the issue directly
        log_status "INFO" "Opening PR for standalone issue #$parent_number..."
        open_pr "$RALPH_GH_REPO" "$branch_name" "$RALPH_GH_MAIN_BRANCH" \
            "$parent_number" "$parent_title" "Standalone issue — no sub-issues"

        # Close the issue
        log_status "INFO" "Closing issue #$parent_number"
        close_sub_issue "$RALPH_GH_REPO" "$parent_number" \
            "Completed by ralph-gh. PR opened."
    else
        # Parent with sub-issues
        local completed_list=""
        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            local title
            title=$(get_issue_title "$RALPH_GH_REPO" "$sub")
            completed_list+="- #${sub} - ${title}"$'\n'
        done <<< "$completed_subs"

        log_status "INFO" "Opening PR..."
        open_pr "$RALPH_GH_REPO" "$branch_name" "$RALPH_GH_MAIN_BRANCH" \
            "$parent_number" "$parent_title" "$completed_list"

        # Close sub-issues
        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            log_status "INFO" "Closing sub-issue #$sub"
            close_sub_issue "$RALPH_GH_REPO" "$sub" \
                "Completed by ralph-gh as part of parent issue #$parent_number"
        done <<< "$completed_subs"
    fi

    # Remove label from issue
    log_status "INFO" "Removing '$RALPH_GH_LABEL' label from #$parent_number"
    remove_label "$RALPH_GH_REPO" "$parent_number" "$RALPH_GH_LABEL"

    # Update state
    mark_parent_processed "$parent_number"

    log_status "SUCCESS" "Parent #$parent_number complete. PR opened, sub-issues closed."
}

# Abort a parent group: push partial work, draft PR, comment
abort_group() {
    local parent_number=$1
    local branch_name=$2
    local failure_reason=$3

    log_status "ERROR" "Aborting parent #$parent_number: $failure_reason"

    # Commit any uncommitted work
    git add -A 2>/dev/null
    git commit -m "wip(ralph): partial work on #$parent_number - aborted" 2>/dev/null || true

    # Push partial work
    push_branch "$branch_name" || true

    # Build completed subs list
    local completed_list=""
    local completed_subs
    completed_subs=$(get_completed_subs)
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local title
        title=$(get_issue_title "$RALPH_GH_REPO" "$sub")
        completed_list+="- #${sub} - ${title}"$'\n'
    done <<< "$completed_subs"

    if [[ -z "$completed_list" ]]; then
        completed_list="None"
    fi

    # Get parent title
    local parent_title
    parent_title=$(get_issue_title "$RALPH_GH_REPO" "$parent_number")

    # Open draft PR
    log_status "INFO" "Opening draft PR with partial work..."
    open_draft_pr "$RALPH_GH_REPO" "$branch_name" "$RALPH_GH_MAIN_BRANCH" \
        "$parent_number" "$parent_title" "$completed_list" "$failure_reason"

    # Comment on parent issue
    comment_on_issue "$RALPH_GH_REPO" "$parent_number" \
        "ralph-gh encountered an error and has stopped working on this issue.

**Reason:** $failure_reason

A draft PR has been opened with the partial work completed so far. The \`$RALPH_GH_LABEL\` label has been kept so you can re-trigger after fixing the issue.

**Completed sub-issues:**
$completed_list"

    # Clear in_progress but do NOT add to processed (human re-labels to retry)
    # Also do NOT remove the label
    clear_in_progress

    log_status "WARN" "Parent #$parent_number aborted. Draft PR opened. Label kept for retry."
}

# =============================================================================
# POLL LOOP
# =============================================================================

poll_and_process() {
    log_status "INFO" "Polling for issues with label '$RALPH_GH_LABEL' in $RALPH_GH_REPO..."

    local issues_json
    issues_json=$(poll_for_parent_issues "$RALPH_GH_REPO" "$RALPH_GH_LABEL")

    if [[ -z "$issues_json" || "$issues_json" == "[]" || "$issues_json" == "null" ]]; then
        log_status "INFO" "No labeled issues found"
        update_last_poll
        return 1
    fi

    # Filter out already-processed issues
    local candidate_count
    candidate_count=$(echo "$issues_json" | jq 'length')

    local parent_number=""
    local parent_body=""

    for i in $(seq 0 $((candidate_count - 1))); do
        local num
        num=$(echo "$issues_json" | jq -r ".[$i].number")

        if is_processed "$num"; then
            log_status "INFO" "Skipping already-processed parent #$num"
            continue
        fi

        parent_number="$num"
        parent_body=$(echo "$issues_json" | jq -r ".[$i].body")
        break
    done

    if [[ -z "$parent_number" ]]; then
        log_status "INFO" "All labeled issues have been processed"
        update_last_poll
        return 1
    fi

    log_status "INFO" "Found issue #$parent_number"

    # Parse task list from issue body
    local sub_issues
    sub_issues=$(parse_task_list "$parent_body")

    local branch_name="ralph/issue-${parent_number}"

    if [[ -z "$sub_issues" ]]; then
        # Standalone issue (no sub-issues) — treat the issue itself as the work
        log_status "INFO" "Issue #$parent_number is a standalone issue (no task list)"
        set_in_progress "$parent_number" "$branch_name" "$parent_number"
        log_status "SUCCESS" "Set up work for standalone issue #$parent_number"
    else
        log_status "INFO" "Found sub-issues: $(echo "$sub_issues" | tr '\n' ' ')"

        # Validate sub-issues are open
        local valid_subs
        mapfile -t sub_array <<< "$sub_issues"
        valid_subs=$(validate_sub_issues "$RALPH_GH_REPO" "${sub_array[@]}")

        if [[ -z "$valid_subs" ]]; then
            log_status "WARN" "No valid open sub-issues found for parent #$parent_number"
            update_last_poll
            return 1
        fi

        mapfile -t valid_sub_array <<< "$valid_subs"
        set_in_progress "$parent_number" "$branch_name" "${valid_sub_array[@]}"
        log_status "SUCCESS" "Set up work for parent #$parent_number with ${#valid_sub_array[@]} sub-issues"
    fi

    update_last_poll
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo ""
    echo "================================================"
    echo "  ralph-gh - Autonomous GitHub Issue Worker"
    echo "================================================"
    echo ""

    # Load config (3-layer)
    load_config

    # Validate environment
    validate_environment

    # Initialize state
    cd "$RALPH_GH_WORKSPACE"
    mkdir -p "$RALPH_GH_STATE_DIR/logs"
    init_state
    init_circuit_breaker

    log_status "INFO" "Workspace: $RALPH_GH_WORKSPACE"
    log_status "INFO" "Repo: $RALPH_GH_REPO"
    log_status "INFO" "Label: $RALPH_GH_LABEL"
    log_status "INFO" "Poll interval: ${RALPH_GH_POLL_INTERVAL}s"
    log_status "INFO" "Main branch: $RALPH_GH_MAIN_BRANCH"

    # Check for in-progress work to resume
    if has_in_progress; then
        local resume_parent
        resume_parent=$(get_in_progress_parent)
        log_status "INFO" "Resuming in-progress work on parent #$resume_parent"
        process_parent_group
    fi

    # Main poll loop
    while true; do
        # Try to find and set up new work
        if ! has_in_progress; then
            if poll_and_process; then
                # Found work, process it
                process_parent_group
            else
                # No work found, sleep
                log_status "INFO" "Sleeping for ${RALPH_GH_POLL_INTERVAL}s..."
                sleep "$RALPH_GH_POLL_INTERVAL"
            fi
        else
            # Still have in-progress work (shouldn't normally reach here)
            process_parent_group
        fi

        # Return to main branch after processing
        cd "$RALPH_GH_WORKSPACE"
        git checkout "$RALPH_GH_MAIN_BRANCH" 2>/dev/null || true
    done
}

# Handle CLI arguments
case "${1:-}" in
    --status)
        load_config
        cd "$RALPH_GH_WORKSPACE"
        init_state
        echo "=== ralph-gh Status ==="
        if has_in_progress; then
            echo "In progress: parent #$(get_in_progress_parent) on $(get_in_progress_branch)"
            echo "Completed subs: $(get_completed_subs | tr '\n' ' ')"
            echo "Remaining subs: $(get_remaining_subs | tr '\n' ' ')"
        else
            echo "No work in progress"
        fi
        echo "Processed parents: $(jq -r '.processed | join(", ")' "$RALPH_GH_STATE_DIR/state.json" 2>/dev/null)"
        show_circuit_status
        ;;
    --reset)
        load_config
        cd "$RALPH_GH_WORKSPACE"
        init_state
        clear_in_progress
        reset_circuit_breaker
        echo "State and circuit breaker reset"
        ;;
    --help|-h)
        echo "ralph-gh - Autonomous GitHub Issue Worker"
        echo ""
        echo "Usage: ralph-gh.sh [options]"
        echo ""
        echo "Options:"
        echo "  --status    Show current status"
        echo "  --reset     Reset state and circuit breaker"
        echo "  --help      Show this help"
        echo ""
        echo "Configuration:"
        echo "  Global:  ~/.ralph-gh/ralph-gh.conf"
        echo "  Project: <workspace>/.ralphrc"
        echo "  Prompt:  <workspace>/.ralph/PROMPT.md"
        echo ""
        echo "Environment variables:"
        echo "  RALPH_GH_REPO         Repository (owner/repo)"
        echo "  RALPH_GH_WORKSPACE    Path to local repo clone"
        echo "  RALPH_GH_LABEL        Issue label to watch (default: ralph)"
        echo "  RALPH_GH_POLL_INTERVAL  Seconds between polls (default: 1800)"
        echo "  RALPH_GH_MAIN_BRANCH  Base branch (default: main)"
        echo "  CLAUDE_TIMEOUT_MINUTES  Max time per sub-issue (default: 15)"
        ;;
    *)
        main
        ;;
esac
