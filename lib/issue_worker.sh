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

    # Record whether the issue body contains any checklist markers (- [ ] or
    # - [x]). If it doesn't, the sub-issue has no explicit acceptance criteria
    # and run_acceptance_gate will auto-skip to avoid bouncing Claude for a
    # missing block it couldn't meaningfully populate.
    if echo "$sub_body" | grep -qE '^\s*-\s*\[[xX ]\]'; then
        echo "true" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
    else
        echo "false" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
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

    # Execute with timeout. Capture stderr to a sibling file so we can diagnose
    # exit-code-1 failures (rate limits, quota, session errors, etc.) instead
    # of silently throwing them away.
    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_output_${stamp}.log"
    local stderr_file="$RALPH_GH_STATE_DIR/logs/claude_output_${stamp}.stderr.log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>"$stderr_file"
    exit_code=$?

    # Save path for downstream gate functions (run_acceptance_gate reads this)
    echo "$output_file" > "$RALPH_GH_STATE_DIR/.last_claude_output_path"

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Claude Code timed out after ${timeout_minutes} minutes"
        if [[ -s "$stderr_file" ]]; then
            log_status "WARN" "Claude stderr (tail):"
            tail -15 "$stderr_file" >&2 || true
        fi
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Claude Code exited with code $exit_code"
        if [[ -s "$stderr_file" ]]; then
            log_status "ERROR" "Claude stderr (tail — full log at $stderr_file):"
            tail -15 "$stderr_file" >&2 || true
        else
            log_status "ERROR" "Claude stderr was empty"
        fi
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
# Returns: 0 if all criteria checked (or sub-issue has no criteria), 1 if any unchecked OR no block found.
run_acceptance_gate() {
    # Auto-skip when the sub-issue body has no checklist markers. Gate is
    # enforced whenever there ARE criteria; skipped when there aren't any.
    local criteria_flag_file="$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
    if [[ -f "$criteria_flag_file" ]] && [[ "$(cat "$criteria_flag_file")" == "false" ]]; then
        log_status "INFO" "Acceptance gate skipped: sub-issue has no checklist criteria in its body"
        return 0
    fi

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

    prompt+="## Task: Pre-PR Review (Best Practices Audit)"
    prompt+=$'\n\n'
    prompt+="You are reviewing the complete diff of branch work for parent issue #${parent_issue_number} before a PR is opened."
    prompt+=$'\n\n'
    prompt+="Run \`/review-best-practices\` to analyze all changes on this branch compared to \`${main_branch}\`. This is a superset of \`/review\` — it runs the standard pre-landing review first (SQL safety, trust boundaries, race conditions, test coverage) then layers on a best-practices audit (SOLID, DRY, KISS, YAGNI, clean code)."
    prompt+=$'\n\n'
    prompt+="If the audit surfaces issues, fix the critical and best-practices findings and commit with conventional commit messages."
    prompt+=$'\n'
    prompt+="If no issues are found, report COMPLETE without making any changes."
    prompt+=$'\n\n'

    # Add rules
    prompt+=$(cat <<'RULES'
## Rules
1. Run /review-best-practices first — do not skip it
2. Fix critical (from /review) and best-practices findings
3. Commit fixes with descriptive conventional commit messages (e.g. fix: ..., refactor: ...)
4. Do NOT close issues or open PRs - that is handled externally
5. Do NOT modify .ralph-gh/ or .ralph/ state files
6. If the audit is clean (no findings), do NOT make any file changes — report COMPLETE

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

# Build the simplify prompt for post-sub-issue /simplify pass
build_simplify_prompt() {
    local workspace=$1
    local sub_issue_number=$2
    local sub_start_ref=$3

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

    prompt+="## Task: Post-Implementation /simplify Pass"
    prompt+=$'\n\n'
    prompt+="You just finished sub-issue #${sub_issue_number}. The changes you introduced are committed between \`${sub_start_ref}\` and \`HEAD\`."
    prompt+=$'\n\n'
    prompt+="Run \`/simplify\` over that diff (\`git diff ${sub_start_ref}...HEAD\`). The skill reviews changed code for reuse opportunities, quality, and efficiency, then fixes any issues found."
    prompt+=$'\n\n'
    prompt+="If the skill surfaces issues, fix them and commit with a conventional commit message (\`refactor:\` or \`fix:\`)."
    prompt+=$'\n'
    prompt+="If nothing needs changing, report COMPLETE without making any changes."
    prompt+=$'\n\n'

    # Add rules
    prompt+=$(cat <<'RULES'
## Rules
1. Run /simplify first — do not skip it
2. Only touch files inside the sub-issue diff unless /simplify identifies a reuse opportunity in a closely adjacent file
3. Commit fixes with descriptive conventional commit messages (e.g. refactor: ..., fix: ...)
4. Do NOT close issues or open PRs — that is handled externally
5. Do NOT modify .ralph-gh/ or .ralph/ state files
6. Do NOT run `pnpm changeset` — changesets are handled after all sub-issues complete
7. If /simplify finds nothing actionable, do NOT make any file changes — report COMPLETE

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

# Execute a /simplify pass against the just-finished sub-issue's diff.
# One-shot (no retry loop), non-fatal (caller ignores failure).
# Returns: 0 on success, 1 on failure.
execute_simplify() {
    local workspace=$1
    local sub_issue_number=$2
    local sub_start_ref=$3
    local allowed_tools=$4
    local timeout_minutes=$5

    local timeout_seconds=$((timeout_minutes * 60))

    log_status "INFO" "Running /simplify for sub-issue #$sub_issue_number..."

    # Build the simplify prompt
    local prompt
    prompt=$(build_simplify_prompt "$workspace" "$sub_issue_number" "$sub_start_ref")

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
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_simplify_$(date '+%Y%m%d_%H%M%S').log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking Claude Code for simplify (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
        < /dev/null > "$output_file" 2>/dev/null
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Simplify timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Simplify Claude invocation exited with code $exit_code"
        return 1
    fi

    # Commit any simplify fixes
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || \
       [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        git add -A -- ':!.ralph-gh' 2>/dev/null || true
        git commit -m "refactor(ralph): simplify sub-issue #$sub_issue_number" 2>/dev/null || true
        log_status "SUCCESS" "Simplify fixes committed for #$sub_issue_number"
    else
        log_status "INFO" "Simplify complete — no fixes needed for #$sub_issue_number"
    fi

    return 0
}

export -f build_full_prompt execute_for_sub_issue
export -f build_review_prompt execute_review
export -f build_simplify_prompt execute_simplify
export -f build_changeset_prompt execute_changeset
export -f get_saved_session_id clear_saved_session
export -f run_acceptance_gate
export -f run_e2e_pre_check
