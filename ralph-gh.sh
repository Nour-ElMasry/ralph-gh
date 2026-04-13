#!/usr/bin/env bash
set -euo pipefail

# ralph-gh - Autonomous GitHub Issue Worker
# Fetches GitHub issues by label, works through sub-issues sequentially,
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
source "$SCRIPT_DIR/lib/worktree_manager.sh"

# =============================================================================
# DEFAULTS
# =============================================================================

RALPH_GH_REPO="${RALPH_GH_REPO:-}"
RALPH_GH_WORKSPACE="${RALPH_GH_WORKSPACE:-}"
RALPH_GH_LABEL="${RALPH_GH_LABEL:-ralph}"
RALPH_GH_MAIN_BRANCH="${RALPH_GH_MAIN_BRANCH:-main}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"
RALPH_GH_ALLOWED_TOOLS="${RALPH_GH_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(npm *),Bash(pnpm *),Bash(node *),Bash(find *)}"
CB_NO_PROGRESS_THRESHOLD="${CB_NO_PROGRESS_THRESHOLD:-3}"
CB_SAME_ERROR_THRESHOLD="${CB_SAME_ERROR_THRESHOLD:-5}"
RALPH_GH_MAX_LOOPS_PER_ISSUE="${RALPH_GH_MAX_LOOPS_PER_ISSUE:-8}"  # Max Claude invocations per sub-issue (includes gate retries)
RALPH_GH_MAX_LOOPS_TOTAL="${RALPH_GH_MAX_LOOPS_TOTAL:-0}"          # Max total invocations per parent group (0=unlimited)

# =============================================================================
# REPO AUTO-DETECTION
# =============================================================================

# Detect RALPH_GH_REPO and RALPH_GH_WORKSPACE from CWD git context.
# If already set (env var or old global config), respect as override with deprecation warning.
detect_repo_context() {
    if [[ -n "$RALPH_GH_WORKSPACE" ]]; then
        log_status "WARN" "RALPH_GH_WORKSPACE is set explicitly — this is deprecated. Run ralph-gh from inside your repo instead."
    else
        RALPH_GH_WORKSPACE=$(git rev-parse --show-toplevel 2>/dev/null) || {
            log_status "ERROR" "Not inside a git repository. Run ralph-gh from inside your repo, or set RALPH_GH_WORKSPACE."
            exit 1
        }
    fi

    if [[ -n "$RALPH_GH_REPO" ]]; then
        log_status "WARN" "RALPH_GH_REPO is set explicitly — this is deprecated. Run ralph-gh from inside your repo instead."
    else
        local remote_url
        remote_url=$(git -C "$RALPH_GH_WORKSPACE" remote get-url origin 2>/dev/null) || {
            log_status "ERROR" "No 'origin' remote found. Set RALPH_GH_REPO or add a git remote."
            exit 1
        }
        # Parse owner/repo from SSH (git@github.com:owner/repo.git) or HTTPS URLs
        RALPH_GH_REPO=$(echo "$remote_url" | sed -E 's#^.+github\.com[:/]##; s#\.git$##')
    fi
}

# =============================================================================
# CONFIG LOADING (3-layer: defaults -> global -> project)
# =============================================================================

load_config() {
    # Layer 1: Global config (non-repo settings: timeouts, thresholds, tools)
    local global_config="$HOME/.ralph-gh/ralph-gh.conf"
    if [[ -f "$global_config" ]]; then
        log_status "INFO" "Loading global config: $global_config"
        # shellcheck source=/dev/null
        source "$global_config"
    fi

    # Layer 2: Auto-detect repo and workspace from CWD
    detect_repo_context

    # Layer 3: Project config (.ralphrc at workspace root)
    if [[ -f "$RALPH_GH_WORKSPACE/.ralphrc" ]]; then
        log_status "INFO" "Loading project config: $RALPH_GH_WORKSPACE/.ralphrc"
        # shellcheck source=/dev/null
        source "$RALPH_GH_WORKSPACE/.ralphrc"

        # Map .ralphrc variable names to ralph-gh names
        [[ -n "${ALLOWED_TOOLS:-}" ]] && RALPH_GH_ALLOWED_TOOLS="$ALLOWED_TOOLS"
        [[ -n "${PROJECT_NAME:-}" ]] && log_status "INFO" "Project: $PROJECT_NAME"
    fi

    # Set derived paths and ensure directories exist
    export RALPH_GH_STATE_DIR="$RALPH_GH_WORKSPACE/.ralph-gh"
    export LOG_DIR="$RALPH_GH_STATE_DIR/logs"
    mkdir -p "$LOG_DIR"

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

    # RALPH_GH_REPO and RALPH_GH_WORKSPACE are auto-detected by detect_repo_context()
    # and guaranteed to be set before this function is called.

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

    # Activate the repo-level Stop hook (enforced via env var to avoid blocking
    # interactive Claude Code sessions in the same repo).
    export RALPH_GH_ACTIVE=1

    local total_loops=0

    # Reset circuit breaker for this group
    reset_circuit_breaker

    # Clear session from any previous group
    clear_saved_session

    # Create/checkout the branch (skip sync if already on the work branch — resuming)
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ "$current_branch" != "$branch_name" ]]; then
        ensure_latest_main "$RALPH_GH_MAIN_BRANCH"
    fi
    if ! create_branch "$branch_name" "$RALPH_GH_MAIN_BRANCH"; then
        log_status "ERROR" "Failed to create branch $branch_name"
        abort_group "$parent_number" "$branch_name" "Failed to create branch"
        return 1
    fi

    # Process each remaining sub-issue sequentially
    # Re-read from state each iteration (resilient to external state changes)
    while true; do
        local sub_number
        sub_number=$(get_remaining_subs | head -1)

        if [[ -z "$sub_number" ]]; then
            break
        fi

        log_status "LOOP" "=== Sub-issue #$sub_number ==="

        # Clear session from previous sub-issue (prevent context bleed)
        clear_saved_session

        # Record the ref at the start of this sub-issue. All gates diff against
        # this ref so the review/acceptance sees the full sub-issue change set,
        # regardless of whether Claude made intermediate commits.
        local sub_start_ref
        sub_start_ref=$(git rev-parse HEAD 2>/dev/null)
        # Export so the repo-level Stop hook can scope its test-gate to the sub-issue diff
        export RALPH_SUB_START_REF="$sub_start_ref"

        # Loop per sub-issue: re-invoke Claude until all gates pass or limit hit
        local loop_count=0
        local sub_done=false
        local retry_context=""

        while [[ "$sub_done" == "false" ]]; do
            loop_count=$((loop_count + 1))
            total_loops=$((total_loops + 1))

            # Check max loops per sub-issue
            if [[ $loop_count -gt $RALPH_GH_MAX_LOOPS_PER_ISSUE ]]; then
                log_status "ERROR" "Sub-issue #$sub_number hit max loops ($RALPH_GH_MAX_LOOPS_PER_ISSUE), stopping group"
                abort_group "$parent_number" "$branch_name" \
                    "Sub-issue #$sub_number exceeded max loops ($RALPH_GH_MAX_LOOPS_PER_ISSUE). Last failure: ${retry_context:-unknown}"
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

            # Get session ID for continuity within retries of the SAME sub-issue
            local session_id
            session_id=$(get_saved_session_id)

            # Execute Claude for this sub-issue (passes retry_context from prior gate failures)
            local result=0
            execute_for_sub_issue \
                "$RALPH_GH_WORKSPACE" \
                "$RALPH_GH_REPO" \
                "$sub_number" \
                "$parent_number" \
                "$session_id" \
                "$RALPH_GH_ALLOWED_TOOLS" \
                "$CLAUDE_TIMEOUT_MINUTES" \
                "$retry_context" || result=$?

            if [[ $result -ne 0 ]]; then
                record_result "false" "true"
                if ! can_execute; then
                    log_status "ERROR" "Circuit breaker tripped on sub-issue #$sub_number (loop $loop_count)"
                    abort_group "$parent_number" "$branch_name" \
                        "Circuit breaker opened while working on sub-issue #$sub_number (loop $loop_count)"
                    return 1
                fi
                log_status "WARN" "Sub-issue #$sub_number loop $loop_count: Claude invocation failed, retrying..."
                retry_context="Previous Claude invocation failed or produced no changes. Re-read the acceptance criteria and try again."
                continue
            fi

            # Gate 1: acceptance criteria (parse ACCEPTANCE block from Claude output)
            local acceptance_failures
            if ! acceptance_failures=$(run_acceptance_gate 2>&1); then
                log_status "WARN" "Sub-issue #$sub_number: ACCEPTANCE gate failed"
                log_status "WARN" "Unchecked criteria:"$'\n'"$acceptance_failures"
                retry_context="ACCEPTANCE GATE FAILED. The following criteria are not yet met — address each one and re-report the ACCEPTANCE block with them checked. Evidence (file:line or test name) is required for each [X]."$'\n\n'"$acceptance_failures"
                record_result "false" "true"
                continue
            fi

            # Gate 2: per-sub /review against the sub-issue start ref (list-only, no fixes)
            local review_findings
            if ! review_findings=$(run_per_sub_review \
                "$RALPH_GH_WORKSPACE" \
                "$sub_number" \
                "$RALPH_GH_ALLOWED_TOOLS" \
                8 \
                "$sub_start_ref"); then
                log_status "WARN" "Sub-issue #$sub_number: REVIEW gate found issues"
                retry_context="REVIEW GATE FAILED. A /review pass on your sub-issue diff surfaced the following findings — fix them and ensure the ACCEPTANCE block still reports all criteria as [X]:"$'\n\n'"$review_findings"
                record_result "false" "true"
                continue
            fi

            # All gates passed — commit any remaining uncommitted work
            local sub_title
            sub_title=$(get_issue_title "$RALPH_GH_REPO" "$sub_number" < /dev/null) || sub_title=""
            [[ -z "$sub_title" ]] && sub_title="Sub-issue $sub_number"
            commit_changes "$sub_number" "$sub_title" || \
                log_status "WARN" "commit_changes failed for #$sub_number, continuing"

            mark_sub_complete "$sub_number"
            check_off_sub_issue "$RALPH_GH_REPO" "$parent_number" "$sub_number" || true
            record_result "true" "false" || true
            log_status "SUCCESS" "Sub-issue #$sub_number completed in $loop_count loop(s) (all gates green)"
            sub_done=true
            retry_context=""
        done
    done

    # All sub-issues completed — run /review before opening PR
    log_status "INFO" "All sub-issues done. Running pre-PR review..."
    clear_saved_session
    if ! execute_review \
        "$RALPH_GH_WORKSPACE" \
        "$RALPH_GH_REPO" \
        "$RALPH_GH_MAIN_BRANCH" \
        "$parent_number" \
        "$RALPH_GH_ALLOWED_TOOLS" \
        "$CLAUDE_TIMEOUT_MINUTES"; then
        log_status "WARN" "Pre-PR review failed or timed out — proceeding with PR anyway"
    fi

    # Create changeset summarizing all work
    log_status "INFO" "Creating changeset for parent #$parent_number..."
    local completed_subs_for_changeset
    completed_subs_for_changeset=$(get_completed_subs)
    local subs_summary=""
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local title
        title=$(get_issue_title "$RALPH_GH_REPO" "$sub") || title=""
        [[ -z "$title" ]] && title="Sub-issue $sub"
        subs_summary+="#${sub} - ${title}"$'\n'
    done <<< "$completed_subs_for_changeset"

    clear_saved_session
    if ! execute_changeset \
        "$RALPH_GH_WORKSPACE" \
        "$RALPH_GH_REPO" \
        "$RALPH_GH_MAIN_BRANCH" \
        "$parent_number" \
        "$subs_summary" \
        "$RALPH_GH_ALLOWED_TOOLS" \
        "$CLAUDE_TIMEOUT_MINUTES"; then
        log_status "WARN" "Changeset creation failed — proceeding with PR anyway"
    fi

    complete_group "$parent_number" "$branch_name"
    return 0
}

# Build a formatted list of completed sub-issues (used for PRs and comments)
build_completed_subs_list() {
    local completed_subs
    completed_subs=$(get_completed_subs)
    local list=""
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        local title
        title=$(get_issue_title "$RALPH_GH_REPO" "$sub") || title=""
        [[ -z "$title" ]] && title="Sub-issue $sub"
        list+="- #${sub} - ${title}"$'\n'
    done <<< "$completed_subs"
    echo "${list:-None}"
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
    parent_title=$(get_issue_title "$RALPH_GH_REPO" "$parent_number") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_number"

    if [[ "$is_standalone" == "true" ]]; then
        # Standalone issue — PR closes the issue directly
        log_status "INFO" "Opening PR for standalone issue #$parent_number..."
        if ! open_pr "$RALPH_GH_REPO" "$branch_name" "$RALPH_GH_MAIN_BRANCH" \
            "$parent_number" "$parent_title" "Standalone issue — no sub-issues"; then
            log_status "WARN" "Failed to open PR for standalone issue #$parent_number"
        fi

        # Close the issue
        log_status "INFO" "Closing issue #$parent_number"
        close_sub_issue "$RALPH_GH_REPO" "$parent_number" \
            "Completed by ralph-gh. PR opened." || true
    else
        # Parent with sub-issues
        local completed_list
        completed_list=$(build_completed_subs_list) || completed_list="(could not build list)"

        log_status "INFO" "Opening PR..."
        if ! open_pr "$RALPH_GH_REPO" "$branch_name" "$RALPH_GH_MAIN_BRANCH" \
            "$parent_number" "$parent_title" "$completed_list"; then
            log_status "WARN" "Failed to open PR for parent #$parent_number"
        fi

        # Close sub-issues
        while IFS= read -r sub; do
            [[ -z "$sub" ]] && continue
            log_status "INFO" "Closing sub-issue #$sub"
            close_sub_issue "$RALPH_GH_REPO" "$sub" \
                "Completed by ralph-gh as part of parent issue #$parent_number" || true
        done <<< "$completed_subs"
    fi

    # Remove label from issue
    log_status "INFO" "Removing '$RALPH_GH_LABEL' label from #$parent_number"
    remove_label "$RALPH_GH_REPO" "$parent_number" "$RALPH_GH_LABEL" || true

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
    local completed_list
    completed_list=$(build_completed_subs_list) || completed_list="(could not build list)"

    # Get parent title
    local parent_title
    parent_title=$(get_issue_title "$RALPH_GH_REPO" "$parent_number") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_number"

    # Open draft PR
    log_status "INFO" "Opening draft PR with partial work..."
    open_draft_pr "$RALPH_GH_REPO" "$branch_name" "$RALPH_GH_MAIN_BRANCH" \
        "$parent_number" "$parent_title" "$completed_list" "$failure_reason" || true

    # Comment on parent issue
    comment_on_issue "$RALPH_GH_REPO" "$parent_number" \
        "ralph-gh encountered an error and has stopped working on this issue.

**Reason:** $failure_reason

A draft PR has been opened with the partial work completed so far. The \`$RALPH_GH_LABEL\` label has been kept so you can re-trigger after fixing the issue.

**Completed sub-issues:**
$completed_list" || true

    # Clear in_progress and mark as processed for THIS run (skips re-pick in same run).
    # Label is kept so the next `ralph-gh run` can re-trigger it.
    clear_in_progress
    mark_parent_processed "$parent_number"

    log_status "WARN" "Parent #$parent_number aborted. Draft PR opened. Label kept for retry."
}

# =============================================================================
# TARGETED ISSUE PROCESSING
# =============================================================================

# Process a single explicitly-specified issue (no label required)
process_targeted_issue() {
    local issue_number=$1

    log_status "INFO" "Fetching targeted issue #$issue_number..."

    # Fetch and validate the issue is open
    local issue_json
    if ! issue_json=$(fetch_issue_details "$RALPH_GH_REPO" "$issue_number"); then
        return 1
    fi

    local body
    body=$(echo "$issue_json" | jq -r '.body')

    # Parse task list from issue body
    local sub_issues
    sub_issues=$(parse_task_list "$body")

    local branch_name="ralph/issue-${issue_number}"

    if [[ -z "$sub_issues" ]]; then
        # Standalone issue
        log_status "INFO" "Issue #$issue_number is a standalone issue (no task list)"
        set_in_progress "$issue_number" "$branch_name" "$issue_number"
    else
        log_status "INFO" "Found sub-issues: $(echo "$sub_issues" | tr '\n' ' ')"

        # Validate all sub-issues exist and are open
        local valid_subs
        mapfile -t sub_array <<< "$sub_issues"
        if ! valid_subs=$(validate_sub_issues "$RALPH_GH_REPO" "${sub_array[@]}"); then
            log_status "ERROR" "Not all sub-issues are ready for parent #$issue_number"
            return 1
        fi

        if [[ -z "$valid_subs" ]]; then
            log_status "ERROR" "No valid open sub-issues found for #$issue_number"
            return 1
        fi

        mapfile -t valid_sub_array <<< "$valid_subs"
        set_in_progress "$issue_number" "$branch_name" "${valid_sub_array[@]}"
        log_status "SUCCESS" "Set up work for parent #$issue_number with ${#valid_sub_array[@]} sub-issues"
    fi

    process_parent_group
    return $?
}

# =============================================================================
# FETCH AND PROCESS
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

    # Filter out already-processed issues and find a ready candidate
    local candidate_count
    candidate_count=$(echo "$issues_json" | jq 'length')

    for i in $(seq 0 $((candidate_count - 1))); do
        local num
        num=$(echo "$issues_json" | jq -r ".[$i].number")

        if is_processed "$num"; then
            log_status "INFO" "Skipping already-processed parent #$num"
            continue
        fi

        local body
        body=$(echo "$issues_json" | jq -r ".[$i].body")

        log_status "INFO" "Found issue #$num"

        # Parse task list from issue body
        local sub_issues
        sub_issues=$(parse_task_list "$body")

        # If already on a non-main branch, use it; otherwise create a new one
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        local branch_name
        if [[ "$current_branch" != "$RALPH_GH_MAIN_BRANCH" ]]; then
            branch_name="$current_branch"
            log_status "INFO" "Using current branch '$branch_name' instead of creating new branch"
        else
            branch_name="ralph/issue-${num}"
        fi

        if [[ -z "$sub_issues" ]]; then
            # Standalone issue (no sub-issues) — treat the issue itself as the work
            log_status "INFO" "Issue #$num is a standalone issue (no task list)"
            set_in_progress "$num" "$branch_name" "$num"
            log_status "SUCCESS" "Set up work for standalone issue #$num"
            update_last_poll
            return 0
        fi

        log_status "INFO" "Found sub-issues: $(echo "$sub_issues" | tr '\n' ' ')"

        # Validate all sub-issues exist and are open
        local valid_subs
        mapfile -t sub_array <<< "$sub_issues"
        if ! valid_subs=$(validate_sub_issues "$RALPH_GH_REPO" "${sub_array[@]}"); then
            log_status "INFO" "Deferring parent #$num — waiting for all sub-issues to be created"
            continue
        fi

        if [[ -z "$valid_subs" ]]; then
            log_status "WARN" "No valid open sub-issues found for parent #$num"
            continue
        fi

        mapfile -t valid_sub_array <<< "$valid_subs"
        set_in_progress "$num" "$branch_name" "${valid_sub_array[@]}"
        log_status "SUCCESS" "Set up work for parent #$num with ${#valid_sub_array[@]} sub-issues"
        update_last_poll
        return 0
    done

    log_status "INFO" "No ready issues found (all processed or waiting for sub-issues)"
    update_last_poll
    return 1
}

# =============================================================================
# WORKTREE-ISOLATED TARGETED PROCESSING
# =============================================================================

# Process a targeted issue inside an isolated git worktree.
# This allows multiple ralph instances to work on different issues concurrently.
process_targeted_in_worktree() {
    local issue_number=$1

    log_status "INFO" "Setting up worktree for issue #$issue_number..."

    # Set up worktree (creates it, acquires per-issue lock, redirects globals, cd's into it)
    if ! worktree_setup "$issue_number" "$RALPH_GH_MAIN_BRANCH"; then
        log_status "ERROR" "Failed to set up worktree for issue #$issue_number"
        return 1
    fi

    # Set signal trap for clean shutdown inside worktree
    trap "worktree_cleanup_on_signal $issue_number" INT TERM

    # Initialize fresh state and circuit breaker inside the worktree
    init_state
    init_circuit_breaker

    local result=0

    # Check for in-progress work (resume after crash)
    if has_in_progress; then
        local resume_parent
        resume_parent=$(get_in_progress_parent)
        log_status "INFO" "Resuming in-progress work on parent #$resume_parent in worktree"
        process_parent_group || result=$?
    else
        process_targeted_issue "$issue_number" || result=$?
    fi

    # Clean up worktree regardless of success/failure
    worktree_cleanup "$issue_number"

    # Restore default signal trap
    trap 'log_status "WARN" "Caught signal, shutting down..."; kill 0 2>/dev/null; exit 130' INT TERM

    if [[ $result -ne 0 ]]; then
        log_status "WARN" "Failed to process targeted issue #$issue_number"
    fi

    return $result
}

# =============================================================================
# RUN COMMAND
# =============================================================================

run_command() {
    echo ""
    echo "================================================"
    echo "  ralph-gh - Autonomous GitHub Issue Worker"
    echo "================================================"
    echo ""

    # Load config (3-layer)
    load_config

    # Apply CLI --label override after config loading
    [[ -n "${_LABEL_OVERRIDE:-}" ]] && RALPH_GH_LABEL="$_LABEL_OVERRIDE"

    # Validate environment
    validate_environment

    # Initialize state
    cd "$RALPH_GH_WORKSPACE"
    init_state
    init_circuit_breaker

    # Acquire exclusive lock for serial poller mode only.
    # Targeted mode (issue numbers given) uses per-issue locks instead,
    # allowing multiple ralph instances to run concurrently.
    if [[ ${#_TARGET_ISSUES[@]} -eq 0 ]]; then
        local lock_file="$RALPH_GH_STATE_DIR/.lock"
        mkdir -p "$RALPH_GH_STATE_DIR"
        exec 9>"$lock_file"
        if ! flock -n 9; then
            log_status "ERROR" "Another ralph-gh instance is already running (lock: $lock_file)"
            exit 1
        fi
    fi

    # Trap Ctrl+C / SIGTERM — kill entire process group for clean shutdown
    trap 'log_status "WARN" "Caught signal, shutting down..."; kill 0 2>/dev/null; exit 130' INT TERM

    # Fresh run: clear processed list (label removal is the primary dedup)
    clear_processed

    log_status "INFO" "Workspace: $RALPH_GH_WORKSPACE"
    log_status "INFO" "Repo: $RALPH_GH_REPO"
    log_status "INFO" "Label: $RALPH_GH_LABEL"
    log_status "INFO" "Main branch: $RALPH_GH_MAIN_BRANCH"

    # Resume in-progress work if any (crash recovery)
    if has_in_progress; then
        local resume_parent
        resume_parent=$(get_in_progress_parent)
        log_status "INFO" "Resuming in-progress work on parent #$resume_parent"
        process_parent_group
        cd "$RALPH_GH_WORKSPACE"
        git checkout "$RALPH_GH_MAIN_BRANCH" 2>/dev/null || true
    fi

    # Process targeted issues or fall back to label polling
    if [[ ${#_TARGET_ISSUES[@]} -gt 0 ]]; then
        log_status "INFO" "Processing ${#_TARGET_ISSUES[@]} targeted issue(s) via worktrees: ${_TARGET_ISSUES[*]}"
        for target_num in "${_TARGET_ISSUES[@]}"; do
            process_targeted_in_worktree "$target_num" || true
        done
        log_status "SUCCESS" "Run complete. All targeted issues processed."
    else
        # Process all labeled issues until none remain
        while poll_and_process; do
            process_parent_group
            cd "$RALPH_GH_WORKSPACE"
            git checkout "$RALPH_GH_MAIN_BRANCH" 2>/dev/null || true
        done
        log_status "SUCCESS" "Run complete. No more labeled issues to process."
    fi
}

# =============================================================================
# CLI
# =============================================================================

case "${1:-}" in
    run)
        shift
        _TARGET_ISSUES=()
        # Parse flags and positional args (issue numbers)
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --label)
                    if [[ -n "${2:-}" ]]; then
                        _LABEL_OVERRIDE="$2"
                        shift 2
                    else
                        echo "Error: --label requires a value"
                        exit 1
                    fi
                    ;;
                -*)
                    echo "Unknown option: $1"
                    echo "Usage: ralph-gh run [--label LABEL] [ISSUE_NUMBER ...]"
                    exit 1
                    ;;
                *)
                    # Positional arg — must be a number
                    if [[ "$1" =~ ^[0-9]+$ ]]; then
                        _TARGET_ISSUES+=("$1")
                    else
                        echo "Error: '$1' is not a valid issue number"
                        exit 1
                    fi
                    shift
                    ;;
            esac
        done
        run_command
        ;;
    --status)
        load_config
        cd "$RALPH_GH_WORKSPACE"
        init_state
        echo "=== ralph-gh Status ==="
        if flock -n "$RALPH_GH_STATE_DIR/.lock" true 2>/dev/null; then
            echo "State: STOPPED"
        else
            echo "State: RUNNING"
        fi
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
    --kill)
        load_config
        cd "$RALPH_GH_WORKSPACE"
        _lock_file="$RALPH_GH_STATE_DIR/.lock"
        if [[ -f "$_lock_file" ]]; then
            _pid=$(flock -n "$_lock_file" echo "not-locked" 2>/dev/null)
            if [[ "$_pid" != "not-locked" ]]; then
                # Find the ralph-gh process holding the lock
                _holder_pid=$(fuser "$_lock_file" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$_holder_pid" ]]; then
                    echo "Killing ralph-gh process tree (PID: $_holder_pid)..."
                    # Kill the entire process group to catch Claude subprocesses
                    kill -- -"$(ps -o pgid= -p "$_holder_pid" | tr -d '[:space:]')" 2>/dev/null || \
                        kill "$_holder_pid" 2>/dev/null
                    sleep 1
                    # Force kill if still alive
                    if kill -0 "$_holder_pid" 2>/dev/null; then
                        kill -9 "$_holder_pid" 2>/dev/null
                    fi
                    echo "ralph-gh killed."
                else
                    echo "Could not find ralph-gh process. Lock may be stale."
                    rm -f "$_lock_file"
                    echo "Removed stale lock."
                fi
            else
                echo "ralph-gh is not running."
            fi
        else
            echo "ralph-gh is not running (no lock file)."
        fi
        ;;
    setup)
        shift
        # Delegate to setup.sh (supports auto-detection or explicit repo arg)
        exec "$SCRIPT_DIR/setup.sh" "$@"
        ;;
    --help|-h|"")
        echo "ralph-gh - Autonomous GitHub Issue Worker"
        echo ""
        echo "Usage: cd <your-repo> && ralph-gh run [--label LABEL] [ISSUE_NUMBER ...]"
        echo ""
        echo "  Repo and workspace are auto-detected from the current directory."
        echo "  Just cd into any git repo with a GitHub remote and run."
        echo ""
        echo "Commands:"
        echo "  setup [OWNER/REPO]               Create 'ralph' label (auto-detects repo)"
        echo "  run [--label LABEL] [ISSUE ...]  Process issues and exit"
        echo ""
        echo "  When issue numbers are given, ralph works on those specific issues"
        echo "  (no label required) in isolated git worktrees. Without issue numbers,"
        echo "  ralph polls for all open issues with the target label."
        echo ""
        echo "Options:"
        echo "  --status    Show current status"
        echo "  --reset     Reset state and circuit breaker"
        echo "  --kill      Kill running instance and all child processes"
        echo "  --help      Show this help"
        echo ""
        echo "Configuration:"
        echo "  Global:  ~/.ralph-gh/ralph-gh.conf (timeouts, thresholds)"
        echo "  Project: <repo>/.ralphrc (per-repo overrides)"
        echo "  Prompt:  <repo>/.ralph/PROMPT.md"
        echo ""
        echo "Environment variables:"
        echo "  RALPH_GH_LABEL             Issue label to watch (default: ralph)"
        echo "  RALPH_GH_MAIN_BRANCH       Base branch (default: main)"
        echo "  CLAUDE_TIMEOUT_MINUTES     Max time per sub-issue (default: 15)"
        echo "  RALPH_GH_REPO              Override auto-detected repo (deprecated)"
        echo "  RALPH_GH_WORKSPACE         Override auto-detected workspace (deprecated)"
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run 'ralph-gh --help' for usage."
        exit 1
        ;;
esac
