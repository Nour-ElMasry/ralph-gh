#!/usr/bin/env bash

# issue_worker.sh - Per-sub-issue Claude Code invocation for ralph-gh

# Build the full prompt, combining project prompt + issue context
# Optional 8th arg: retry_context — failure reason from a prior gate so Claude can fix it
build_full_prompt() {
    local workspace=$1
    local sub_issue_number=$2
    local sub_issue_title=$3
    local sub_issue_body=$4
    local parent_issue_number=$5
    local parent_issue_title=$6
    local completed_subs=$7
    local retry_context=${8:-}

    local prompt=""

    # Check for project-specific prompt
    if [[ -f "$workspace/.ralph/PROMPT.md" ]]; then
        prompt=$(cat "$workspace/.ralph/PROMPT.md")
        prompt+=$'\n\n---\n\n'
    fi

    # Prior attempt feedback (from bash-level gates)
    if [[ -n "$retry_context" ]]; then
        prompt+=$'## PRIOR ATTEMPT FAILED — FIX THIS BEFORE ANYTHING ELSE\n\n'
        prompt+="$retry_context"
        prompt+=$'\n\n'
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

1. **Search the codebase before assuming anything.** Look for existing patterns, utilities, and components before writing new ones.
2. **TDD is mandatory.** Use the `/tdd` skill. For every acceptance criterion with testable behavior, write one failing test first, run it red, implement, run it green. For UI-only criteria, describe the manual verification step.
3. **A Stop hook enforces `pnpm --filter api test:unit && pnpm --filter api build` (plus frontend equivalents) before you can end your turn.** Run these yourself during implementation — do not rely on the hook catching your mistakes. If the hook blocks you, use the `/test-fixing` skill to resolve the failures.
4. **Acceptance criteria are the contract.** Every checklist item in the issue body (`- [ ]`) must be satisfied. Report each one explicitly in the ACCEPTANCE block below — shell will refuse to mark the sub-issue complete if any are unchecked.
5. **Commit with descriptive conventional commit messages** (`feat:`, `fix:`, `test:`, `refactor:`).
6. Do NOT close issues or open PRs — handled externally.
7. Do NOT modify `.ralph-gh/` or `.ralph/` state files.
8. Do NOT run `pnpm changeset` — changesets are handled after all sub-issues complete.

## Status Report (REQUIRED — end of every response)

```
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line>
ACCEPTANCE:
  - [X] <criterion text> — evidence: <file:line or test name>
  - [ ] <criterion text> — NOT DONE: <reason>
---END_RALPH_STATUS---
```

**Rules for the ACCEPTANCE block:**
- One line per acceptance criterion from the issue body checklist.
- `[X]` only if the criterion is genuinely satisfied and you can point to evidence (file:line, test name, or visible behavior).
- `[ ]` if not yet met — explain why. The shell parses this and re-invokes you until all items are `[X]`.
- If the issue has no explicit checklist, list 2-4 criteria you inferred from the issue description.
RULES
)

    echo "$prompt"
}

# Execute Claude Code for a single sub-issue
# Returns: 0=success, 1=failure, 2=circuit-break
# Optional 8th arg: retry_context from a prior gate failure
execute_for_sub_issue() {
    local workspace=$1
    local repo=$2
    local sub_issue_number=$3
    local parent_issue_number=$4
    local session_id=$5
    local allowed_tools=$6
    local timeout_minutes=$7
    local retry_context=${8:-}

    local timeout_seconds=$((timeout_minutes * 60))

    # Fetch sub-issue details
    local sub_title sub_body
    sub_title=$(get_issue_title "$repo" "$sub_issue_number") || sub_title=""
    sub_body=$(get_issue_body "$repo" "$sub_issue_number") || sub_body=""

    if [[ -z "$sub_title" ]]; then
        log_status "ERROR" "Could not fetch details for sub-issue #$sub_issue_number"
        return 1
    fi

    # Fetch parent title
    local parent_title
    parent_title=$(get_issue_title "$repo" "$parent_issue_number") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_issue_number"

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
        "$completed_subs_list" \
        "$retry_context")

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

    # Save path for downstream gate functions (run_acceptance_gate reads this)
    echo "$output_file" > "$RALPH_GH_STATE_DIR/.last_claude_output_path"

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
            mkdir -p "$RALPH_GH_STATE_DIR"
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

# =============================================================================
# PER-SUB-ISSUE GATES
# =============================================================================

# Parse the ACCEPTANCE block from the last Claude output log.
# Echoes unchecked criteria (one per line) on stdout.
# Returns: 0 if all criteria checked, 1 if any unchecked OR no block found.
run_acceptance_gate() {
    local path_file="$RALPH_GH_STATE_DIR/.last_claude_output_path"
    [[ -f "$path_file" ]] || { echo "no-output-file"; return 1; }

    local output_file
    output_file=$(cat "$path_file")
    [[ -f "$output_file" ]] || { echo "no-output-file"; return 1; }

    local result_text
    if jq -e 'type == "array"' "$output_file" > /dev/null 2>&1; then
        result_text=$(jq -r '[.[] | select(.type == "result")] | .[-1].result // ""' "$output_file" 2>/dev/null)
    else
        result_text=$(jq -r '.result // ""' "$output_file" 2>/dev/null)
    fi

    # Extract the ACCEPTANCE block (between "ACCEPTANCE:" and "---END_RALPH_STATUS---")
    local acceptance_block
    acceptance_block=$(echo "$result_text" | awk '
        /ACCEPTANCE:/ { capture=1; next }
        /---END_RALPH_STATUS---/ { capture=0 }
        capture { print }
    ')

    if [[ -z "$acceptance_block" ]]; then
        echo "ACCEPTANCE block missing from status report. Re-run with the ACCEPTANCE block populated."
        return 1
    fi

    # Find unchecked items: lines matching - [ ] (unchecked)
    local unchecked
    unchecked=$(echo "$acceptance_block" | grep -E '^\s*-\s*\[\s*\]' || true)

    if [[ -n "$unchecked" ]]; then
        echo "$unchecked"
        return 1
    fi

    # At least one checked item required
    if ! echo "$acceptance_block" | grep -qE '^\s*-\s*\[[Xx]\]'; then
        echo "ACCEPTANCE block has no checked items. Re-run with at least one criterion marked [X]."
        return 1
    fi

    return 0
}

# Build a small, focused prompt for the per-sub /review gate.
# The reviewer is told to list findings only, NOT fix them — bash uses the list
# as retry_context for the next sub-issue iteration, so the fix happens in the
# main implementation call (with full skill access).
build_per_sub_review_prompt() {
    local workspace=$1
    local sub_issue_number=$2
    local sub_start_ref=$3

    local prompt=""
    prompt+="## Task: Per-sub-issue code review"$'\n\n'
    prompt+="Run \`/review\` on the diff for sub-issue #${sub_issue_number}: \`git diff ${sub_start_ref}\`."$'\n\n'
    prompt+="Review scope is ONLY the changes since ${sub_start_ref} — do not review the whole branch or unrelated files."$'\n\n'
    prompt+="**Rules:**"$'\n'
    prompt+="1. Run \`/review\` first, scoped to \`git diff ${sub_start_ref}\`."$'\n'
    prompt+="2. Do NOT fix any issues — only list them."$'\n'
    prompt+="3. If the review finds any issues (SQL safety, trust boundary, structural, duplication, wrong pattern, missing tests), list them clearly under a \`## FINDINGS\` heading in your final message."$'\n'
    prompt+="4. If the review is clean, write a single line: \`FINDINGS: none\` and nothing else under a FINDINGS heading."$'\n'
    prompt+="5. Do NOT run tests, do NOT build, do NOT commit, do NOT modify files."$'\n\n'
    prompt+=$(cat <<'RULES'
## Status Report (REQUIRED)

```
---RALPH_STATUS---
STATUS: COMPLETE
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
EXIT_SIGNAL: false
RECOMMENDATION: <one line>
---END_RALPH_STATUS---
```
RULES
)
    echo "$prompt"
}

# Invoke Claude for a per-sub-issue /review pass.
# Echoes findings text on stdout. Returns: 0 if clean, 1 if findings or error.
run_per_sub_review() {
    local workspace=$1
    local sub_issue_number=$2
    local allowed_tools=$3
    local timeout_minutes=${4:-8}
    local sub_start_ref=$5

    local timeout_seconds=$((timeout_minutes * 60))
    log_status "INFO" "Running per-sub /review for #$sub_issue_number (diff vs ${sub_start_ref:0:8})..."

    local prompt
    prompt=$(build_per_sub_review_prompt "$workspace" "$sub_issue_number" "$sub_start_ref")

    local -a cmd_args=("claude" "--output-format" "json")
    if [[ -n "$allowed_tools" ]]; then
        cmd_args+=("--allowedTools")
        local IFS=','
        read -ra tools_array <<< "$allowed_tools"
        for tool in "${tools_array[@]}"; do
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$tool" ]] && cmd_args+=("$tool")
        done
    fi
    cmd_args+=("-p" "$prompt")

    local output_file="$RALPH_GH_STATE_DIR/logs/claude_per_sub_review_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        echo "Per-sub review invocation failed (exit $exit_code). Skipping gate (treated as clean)."
        return 0
    fi

    local result_text
    if jq -e 'type == "array"' "$output_file" > /dev/null 2>&1; then
        result_text=$(jq -r '[.[] | select(.type == "result")] | .[-1].result // ""' "$output_file" 2>/dev/null)
    else
        result_text=$(jq -r '.result // ""' "$output_file" 2>/dev/null)
    fi

    # Clean result: "FINDINGS: none" → clean
    if echo "$result_text" | grep -qi 'FINDINGS:\s*none'; then
        log_status "SUCCESS" "Per-sub review clean for #$sub_issue_number"
        return 0
    fi

    # Extract FINDINGS section
    local findings
    findings=$(echo "$result_text" | awk '
        /^## *FINDINGS/ { capture=1; next }
        /^## / && capture { capture=0 }
        capture { print }
    ')

    if [[ -z "$findings" ]]; then
        log_status "INFO" "Per-sub review: no FINDINGS section found, treating as clean"
        return 0
    fi

    echo "$findings"
    return 1
}

# Build the review prompt for post-completion /review pass
build_review_prompt() {
    local workspace=$1
    local main_branch=$2
    local parent_issue_number=$3

    local prompt=""

    # Check for project-specific prompt
    if [[ -f "$workspace/.ralph/PROMPT.md" ]]; then
        prompt=$(cat "$workspace/.ralph/PROMPT.md")
        prompt+=$'\n\n---\n\n'
    fi

    # Add AGENT.md build instructions if available
    if [[ -f "$workspace/.ralph/AGENT.md" ]]; then
        prompt+="## Build & Run Instructions"
        prompt+=$'\n\n'
        prompt+=$(cat "$workspace/.ralph/AGENT.md")
        prompt+=$'\n\n'
    fi

    prompt+="## Task: Pre-PR Review"
    prompt+=$'\n\n'
    prompt+="You are reviewing the complete diff of branch work for parent issue #${parent_issue_number} before a PR is opened."
    prompt+=$'\n\n'
    prompt+="Run \`/review\` to analyze all changes on this branch compared to \`${main_branch}\`."
    prompt+=$'\n\n'
    prompt+="If the review surfaces issues, fix them and commit with conventional commit messages."
    prompt+=$'\n'
    prompt+="If no issues are found, report COMPLETE."
    prompt+=$'\n\n'

    # Add rules
    prompt+=$(cat <<'RULES'
## Rules
1. Run /review first — do not skip it
2. Fix any issues the review identifies
3. Commit fixes with descriptive conventional commit messages (e.g. fix: ...)
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

# Run e2e tests and return failure tail on stderr if red. Returns 0 if green, 1 if red.
# Uses the lead-formz test docker-compose layout; no-op if the compose file isn't present.
run_e2e_pre_check() {
    local workspace=$1
    local compose_file="$workspace/apps/api/docker-compose.test.yml"

    if [[ ! -f "$compose_file" ]]; then
        log_status "INFO" "No e2e docker-compose file at $compose_file, skipping e2e pre-check"
        return 0
    fi

    log_status "INFO" "Starting test database for e2e pre-check..."
    if ! (cd "$workspace" && docker compose -f "$compose_file" up -d >/dev/null 2>&1); then
        log_status "WARN" "Could not start test database; skipping e2e pre-check"
        return 0
    fi

    local e2e_log="$RALPH_GH_STATE_DIR/logs/e2e_pre_check_$(date '+%Y%m%d_%H%M%S').log"
    log_status "INFO" "Running pnpm --filter api test:e2e (timeout 10min)..."

    if (cd "$workspace" && portable_timeout 600s pnpm --filter api test:e2e < /dev/null > "$e2e_log" 2>&1); then
        log_status "SUCCESS" "E2E pre-check green"
        return 0
    fi

    log_status "WARN" "E2E pre-check failed — findings will be passed to the review prompt"
    # Emit last 200 lines on stderr so the caller can inject them into the prompt
    tail -200 "$e2e_log" >&2
    return 1
}

# Execute a /review pass against the current branch before PR creation
# Returns: 0=success (review done, fixes applied if any), 1=failure
execute_review() {
    local workspace=$1
    local repo=$2
    local main_branch=$3
    local parent_issue_number=$4
    local allowed_tools=$5
    local timeout_minutes=$6

    local timeout_seconds=$((timeout_minutes * 60))

    log_status "INFO" "Running pre-PR /review for parent #$parent_issue_number..."

    # Run e2e pre-check; capture failure output for injection into prompt
    local e2e_failures=""
    if ! e2e_failures=$(run_e2e_pre_check "$workspace" 2>&1 >/dev/null); then
        : # e2e_failures contains the tail of the failure log
    else
        e2e_failures=""
    fi

    # Build the review prompt
    local prompt
    prompt=$(build_review_prompt "$workspace" "$main_branch" "$parent_issue_number")

    if [[ -n "$e2e_failures" ]]; then
        prompt+=$'\n\n## E2E TEST FAILURES (fix as part of this review)\n\n'
        prompt+="The following e2e test failures were detected. Diagnose and fix them alongside any review findings. Run \`pnpm --filter api test:e2e\` after your fixes to verify."$'\n\n'
        prompt+='```'$'\n'"$e2e_failures"$'\n''```'$'\n'
    fi

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

    # Add the prompt
    cmd_args+=("-p" "$prompt")

    # Execute with timeout
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_review_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code for review (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Review timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Review Claude invocation exited with code $exit_code"
        return 1
    fi

    # Commit any review fixes
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || \
       [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        git add -A -- ':!.ralph-gh' 2>/dev/null || true
        git commit -m "fix(ralph): address review findings for #$parent_issue_number" 2>/dev/null || true
        log_status "SUCCESS" "Review fixes committed"
    else
        log_status "INFO" "Review complete — no fixes needed"
    fi

    return 0
}

# Build a prompt for changeset creation
build_changeset_prompt() {
    local workspace=$1
    local main_branch=$2
    local parent_issue_number=$3
    local subs_summary=$4

    local parent_title
    parent_title=$(get_issue_title "$RALPH_GH_REPO" "$parent_issue_number") || parent_title=""
    [[ -z "$parent_title" ]] && parent_title="Issue $parent_issue_number"

    cat <<CHANGESET_EOF
You are creating a changeset for a completed group of work.

## Parent Issue: #${parent_issue_number} - ${parent_title}

## Completed sub-issues:
${subs_summary}

## Instructions
1. Review the git diff against main to understand all changes: \`git diff ${main_branch}...HEAD\`
2. Run \`pnpm changeset\` to create a changeset file that summarizes the overall feature/fix
3. Create ONE changeset that covers the entire body of work (not one per sub-issue)
4. After creating the changeset, stage and commit it with: \`git add .changeset && git commit -m "chore: add changeset for #${parent_issue_number}"\`
5. Do NOT close issues or open PRs

## Status Report (REQUIRED)

\`\`\`
---RALPH_STATUS---
STATUS: COMPLETE
FILES_MODIFIED: 1
TESTS_STATUS: NOT_RUN
EXIT_SIGNAL: false
RECOMMENDATION: Changeset created
---END_RALPH_STATUS---
\`\`\`
CHANGESET_EOF
}

# Execute Claude Code to create a changeset after all sub-issues complete
execute_changeset() {
    local workspace=$1
    local repo=$2
    local main_branch=$3
    local parent_issue_number=$4
    local subs_summary=$5
    local allowed_tools=$6
    local timeout_minutes=$7

    local timeout_seconds=$((timeout_minutes * 60))

    log_status "INFO" "Creating changeset for parent #$parent_issue_number..."

    # Build the changeset prompt
    local prompt
    prompt=$(build_changeset_prompt "$workspace" "$main_branch" "$parent_issue_number" "$subs_summary")

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

    # Add the prompt
    cmd_args+=("-p" "$prompt")

    # Execute with timeout
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_changeset_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code for changeset (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Changeset creation timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Changeset Claude invocation exited with code $exit_code"
        return 1
    fi

    log_status "SUCCESS" "Changeset created for parent #$parent_issue_number"
    return 0
}

export -f build_full_prompt execute_for_sub_issue
export -f build_review_prompt execute_review
export -f build_changeset_prompt execute_changeset
export -f get_saved_session_id clear_saved_session
export -f run_acceptance_gate run_per_sub_review build_per_sub_review_prompt
export -f run_e2e_pre_check
