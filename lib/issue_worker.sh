#!/usr/bin/env bash

# issue_worker.sh - Per-sub-issue Claude Code invocation for ralph-gh
#
# The model's report comes back as structured output (--json-schema), never as
# a regex over prose. .ralph/PROMPT.md is delivered as a system prompt by the
# runner (see claude_runner.sh), so it is NOT prepended here.

WORKER_SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["IN_PROGRESS","COMPLETE","BLOCKED"]},"exit_signal":{"type":"boolean"},"tests_status":{"type":"string","enum":["PASSING","FAILING","NOT_RUN"]},"files_modified":{"type":"integer"},"recommendation":{"type":"string"},"acceptance":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"met":{"type":"boolean"},"evidence":{"type":"string"}},"required":["criterion","met","evidence"]}}},"required":["status","exit_signal","tests_status","recommendation","acceptance"]}'

REVIEW_SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["COMPLETE","BLOCKED"]},"findings_fixed":{"type":"integer"},"findings_open":{"type":"array","items":{"type":"string"}},"recommendation":{"type":"string"}},"required":["status","findings_fixed","findings_open","recommendation"]}'

# Build the user-turn prompt: issue context + rules + report contract.
# When is_last_sub=true, also instructs the model to create the parent-group
# changeset in the same Claude call (saves a separate end-of-group invocation).
build_full_prompt() {
    local workspace=$1
    local sub_issue_number=$2
    local sub_issue_title=$3
    local sub_issue_body=$4
    local parent_issue_number=$5
    local parent_issue_title=$6
    local completed_subs=$7
    local retry_context=${8:-}
    local is_last_sub=${9:-false}

    local prompt=""

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

    # The shell's verify command, so the model can run the same oracle itself.
    local verify_cmd=""
    if declare -F resolve_verify_cmd >/dev/null 2>&1; then
        verify_cmd=$(resolve_verify_cmd "$workspace")
    fi
    local verify_rule
    if [[ -n "$verify_cmd" ]]; then
        verify_rule="3. **The shell runs \`${verify_cmd}\` after your turn ends.** If it is red you are re-invoked with the failure output, so run it yourself before you finish. Do not report tests as passing unless you ran them in this turn. If you get stuck on failures, use the \`/test-fixing\` skill."
    else
        verify_rule="3. **Run the project's unit tests and build before you finish** (see Build & Run Instructions). An independent verifier then grades your diff against the acceptance criteria."
    fi

    # Final step: changeset for the parent group (only on the last sub-issue).
    local changeset_rule="8. Do NOT run \`pnpm changeset\` — changesets are handled after all sub-issues complete."
    if [[ "$is_last_sub" == "true" ]]; then
        changeset_rule="8. **This is the LAST sub-issue in the parent group.** After the sub-issue work is committed, also create the parent-group changeset: run \`pnpm changeset\` to create ONE changeset summarizing the overall feature/fix for parent #${parent_issue_number} (not one per sub-issue), then \`git add .changeset && git commit -m \"chore: add changeset for #${parent_issue_number}\"\`. Use \`git log --oneline\` on the branch to see what to summarize."
    fi

    # Add rules
    prompt+=$'## Rules\n\n'
    prompt+=$'1. **Search the codebase before assuming anything.** Look for existing patterns, utilities, and components before writing new ones.\n'
    prompt+=$'2. **TDD is mandatory.** Use the `/tdd` skill. For every acceptance criterion with testable behavior, write one failing test first, run it red, implement, run it green. For UI-only criteria, describe the manual verification step.\n'
    prompt+="$verify_rule"$'\n'
    prompt+=$'4. **Acceptance criteria are the contract.** Every checklist item in the issue body (`- [ ]`) must be satisfied and reported in the structured output. The shell refuses to mark the sub-issue complete while any is unmet, and a separate read-only verifier session grades your diff against each criterion — evidence you cannot point to will be caught.\n'
    prompt+=$'5. **Commit with descriptive conventional commit messages** (`feat:`, `fix:`, `test:`, `refactor:`).\n'
    prompt+=$'6. Do NOT close issues or open PRs — handled externally. Do NOT force-push, reset, or switch branches.\n'
    prompt+=$'7. Do NOT modify `.ralph-gh/` or `.ralph/` state files.\n'
    prompt+="$changeset_rule"$'\n\n'

    prompt+=$(cat <<'REPORT_BLOCK'
## Final report (REQUIRED)

Your final action must be the structured output the CLI enforces (JSON schema). Fill it honestly:

- `status`: `COMPLETE` only when every acceptance criterion is met and the tests/build are green in this turn. `BLOCKED` when you cannot proceed. `IN_PROGRESS` otherwise.
- `exit_signal`: `true` only together with `BLOCKED`, when a human decision is required and retrying cannot help (out of scope, environmental blocker, contradictory requirements). Retryable problems keep it `false`.
- `tests_status`: `PASSING` | `FAILING` | `NOT_RUN` — the result of the last run you actually executed in this turn.
- `files_modified`: number of files you changed.
- `acceptance`: one entry per checklist item (`- [ ]` / `- [x]`) in the issue body, criterion text verbatim. `met: true` only with concrete `evidence` (path:line, test name, or command output). If the issue has no checklist, list 2-4 criteria you inferred from the description.
- `recommendation`: one line for the orchestrator or the human reviewer.
REPORT_BLOCK
)

    echo "$prompt"
}

# Execute Claude Code for a single sub-issue
# Returns: 0=success, 1=failure, 2=terminal block (BLOCKED + exit_signal)
# Optional 8th arg: retry_context from a prior gate failure
# Optional 9th arg: is_last_sub ("true"/"false") — append changeset block to prompt
execute_for_sub_issue() {
    local workspace=$1
    local repo=$2
    local sub_issue_number=$3
    local parent_issue_number=$4
    local session_id=$5
    local allowed_tools=$6
    local timeout_minutes=$7
    local retry_context=${8:-}
    local is_last_sub=${9:-false}

    local timeout_seconds=$((timeout_minutes * 60))

    # Fetch sub-issue details
    local sub_title sub_body
    sub_title=$(get_issue_title "$repo" "$sub_issue_number") || sub_title=""
    sub_body=$(get_issue_body "$repo" "$sub_issue_number") || sub_body=""

    if [[ -z "$sub_title" ]]; then
        log_status "ERROR" "Could not fetch details for sub-issue #$sub_issue_number"
        return 1
    fi

    mkdir -p "$RALPH_GH_STATE_DIR/logs"

    # Record whether the issue body contains any checklist markers (- [ ] or
    # - [x]). If it doesn't, the sub-issue has no explicit acceptance criteria
    # and run_acceptance_gate will auto-skip to avoid bouncing Claude for a
    # missing block it couldn't meaningfully populate.
    if echo "$sub_body" | grep -qE '^\s*-\s*\[[xX ]\]'; then
        echo "true" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
    else
        echo "false" > "$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
    fi
    # Keep title/body around for the verifier gate (avoids a second gh fetch)
    printf '%s' "$sub_title" > "$RALPH_GH_STATE_DIR/.last_sub_title"
    printf '%s' "$sub_body" > "$RALPH_GH_STATE_DIR/.last_sub_body"

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
        "$retry_context" \
        "$is_last_sub")

    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_output_${stamp}.log"
    local stderr_file="$RALPH_GH_STATE_DIR/logs/claude_output_${stamp}.stderr.log"

    log_status "INFO" "Invoking Claude Code (${RALPH_GH_MODEL:-default model}, timeout: ${timeout_minutes}m)..."

    # Rule 5 tells the model to commit, so a fully committed turn leaves a
    # clean tree. Remember where HEAD was so new commits count as progress.
    local turn_start_head
    turn_start_head=$(git rev-parse HEAD 2>/dev/null || true)

    local exit_code=0
    run_claude "$workspace" "$prompt" "$output_file" "$stderr_file" "$timeout_seconds" \
        "${RALPH_GH_MODEL:-}" "$WORKER_SCHEMA" "$session_id" "$allowed_tools" "" "implement" || exit_code=$?

    # Save path for downstream gate functions (run_acceptance_gate reads this)
    echo "$output_file" > "$RALPH_GH_STATE_DIR/.last_claude_output_path"
    rm -f "$RALPH_GH_STATE_DIR/.last_status.json"

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
            local err_result
            err_result=$(claude_result_field "$output_file" '.result' | head -5)
            [[ -n "$err_result" ]] && log_status "ERROR" "Claude result: $err_result"
        fi
        return 1
    fi

    # Extract and save session ID for retries of the same sub-issue
    local new_session_id
    new_session_id=$(claude_result_field "$output_file" '.session_id // .sessionId' | head -1)
    if [[ -n "$new_session_id" && "$new_session_id" != "null" ]]; then
        echo "$new_session_id" > "$RALPH_GH_STATE_DIR/.claude_session_id"
        log_status "INFO" "Saved session: ${new_session_id:0:20}..."
    fi

    # Structured report → .last_status.json (gates read this, never prose)
    local status_json
    status_json=$(claude_structured_output "$output_file")
    if [[ -n "$status_json" ]]; then
        printf '%s' "$status_json" > "$RALPH_GH_STATE_DIR/.last_status.json"
    else
        log_status "WARN" "No structured_output in Claude result — treating report as missing"
    fi

    # Check working tree for progress indicators
    local has_changes=false
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        has_changes=true
    fi
    if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        has_changes=true
    fi
    local turn_end_head
    turn_end_head=$(git rev-parse HEAD 2>/dev/null || true)
    if [[ "$turn_end_head" != "$turn_start_head" ]]; then
        has_changes=true
    fi

    local response_status=""
    if [[ -n "$status_json" ]]; then
        response_status=$(printf '%s' "$status_json" | jq -r '.status // ""')
        local tests_status
        tests_status=$(printf '%s' "$status_json" | jq -r '.tests_status // "NOT_RUN"')
        log_status "INFO" "Model report: status=$response_status tests=$tests_status"

        if [[ "$response_status" == "BLOCKED" ]]; then
            log_status "WARN" "Claude reported BLOCKED for sub-issue #$sub_issue_number"
            # exit_signal=true is a deliberate, terminal escalation — the model
            # has decided it cannot proceed without a human/orchestrator
            # decision. Retrying cannot clear it, so return 2 ("terminal block")
            # instead of burning the circuit breaker. A BLOCKED without
            # exit_signal is retryable via return 1.
            if [[ "$(printf '%s' "$status_json" | jq -r '.exit_signal // false')" == "true" ]]; then
                log_status "WARN" "Sub-issue #$sub_issue_number: exit_signal set — terminal block, will not retry"
                return 2
            fi
            return 1
        fi
    fi

    if [[ "$has_changes" == "true" || "$response_status" == "COMPLETE" ]]; then
        log_status "SUCCESS" "Sub-issue #$sub_issue_number: Claude turn finished, running gates"
        return 0
    else
        log_status "WARN" "No changes detected for sub-issue #$sub_issue_number"
        return 1
    fi
}

# Get the saved session ID (for retries within the same sub-issue)
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

# Clear saved session (for starting fresh with a new sub-issue / parent group)
clear_saved_session() {
    rm -f "$RALPH_GH_STATE_DIR/.claude_session_id"
}

# Echo the recommendation from the most recent structured report (empty if
# absent). Used to surface a terminal block's rationale to the human on
# handoff. Always exits 0 so callers under `set -e` stay safe.
get_last_recommendation() {
    local status_file="$RALPH_GH_STATE_DIR/.last_status.json"
    [[ -f "$status_file" ]] || return 0
    jq -r '.recommendation // empty' "$status_file" 2>/dev/null || true
}

# Echo the title/body captured by execute_for_sub_issue (for the verifier gate).
get_last_sub_title() { cat "$RALPH_GH_STATE_DIR/.last_sub_title" 2>/dev/null || true; }
get_last_sub_body()  { cat "$RALPH_GH_STATE_DIR/.last_sub_body"  2>/dev/null || true; }

# =============================================================================
# PER-SUB-ISSUE GATES
# =============================================================================

# Parse the acceptance list from the last structured report.
# Echoes unmet criteria (one per line) on stdout.
# Returns: 0 if all criteria met (or sub-issue has no criteria), 1 if any unmet
# OR no report found.
run_acceptance_gate() {
    # Auto-skip when the sub-issue body has no checklist markers. Gate is
    # enforced whenever there ARE criteria; skipped when there aren't any.
    local criteria_flag_file="$RALPH_GH_STATE_DIR/.last_sub_has_criteria"
    if [[ -f "$criteria_flag_file" ]] && [[ "$(cat "$criteria_flag_file")" == "false" ]]; then
        log_status "INFO" "Acceptance gate skipped: sub-issue has no checklist criteria in its body"
        telemetry_record_gate "acceptance" "skip" "no criteria" 2>/dev/null || true
        return 0
    fi

    local status_file="$RALPH_GH_STATE_DIR/.last_status.json"
    if [[ ! -s "$status_file" ]]; then
        telemetry_record_gate "acceptance" "fail" "no structured report" 2>/dev/null || true
        echo "Your final report was missing or not delivered through the structured output schema. Finish with the structured report, one acceptance entry per checklist item."
        return 1
    fi

    local count
    count=$(jq -r '.acceptance | length' "$status_file" 2>/dev/null || echo 0)
    if [[ "${count:-0}" -eq 0 ]]; then
        telemetry_record_gate "acceptance" "fail" "empty acceptance list" 2>/dev/null || true
        echo "The structured report's acceptance list was empty. Report one entry per checklist item from the issue body, each with evidence."
        return 1
    fi

    local unmet
    unmet=$(jq -r '.acceptance[] | select(.met != true) | "- [ ] \(.criterion) — NOT DONE: \(.evidence // "no reason given")"' "$status_file" 2>/dev/null)
    if [[ -n "$unmet" ]]; then
        telemetry_record_gate "acceptance" "fail" "$(printf '%s' "$unmet" | head -1)" 2>/dev/null || true
        echo "$unmet"
        return 1
    fi

    telemetry_record_gate "acceptance" "pass" "$count criteria" 2>/dev/null || true
    return 0
}

# Build the review prompt for post-completion /review pass
build_review_prompt() {
    local workspace=$1
    local main_branch=$2
    local parent_issue_number=$3

    local prompt=""

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

    prompt+=$(cat <<'RULES'
## Rules
1. Run /review-best-practices first — do not skip it
2. Fix critical (from /review) and best-practices findings
3. Commit fixes with descriptive conventional commit messages (e.g. fix: ..., refactor: ...)
4. Do NOT close issues or open PRs - that is handled externally
5. Do NOT modify .ralph-gh/ or .ralph/ state files
6. If the audit is clean (no findings), do NOT make any file changes — report COMPLETE

## Final report (REQUIRED)

Deliver the structured output the CLI enforces: `status` (COMPLETE, or BLOCKED if you could not run the review), `findings_fixed` (count), `findings_open` (findings you chose not to fix, one line each, with why), `recommendation` (one line for the human reviewer).
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
    mkdir -p "$(dirname "$e2e_log")"
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

    log_status "INFO" "Running pre-PR /review for parent #$parent_issue_number on ${RALPH_GH_REVIEW_MODEL:-default model}..."

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

    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="$RALPH_GH_STATE_DIR/logs/claude_review_${stamp}.log"
    local stderr_file="$RALPH_GH_STATE_DIR/logs/claude_review_${stamp}.stderr.log"

    log_status "INFO" "Invoking Claude Code for review (timeout: ${timeout_minutes}m)..."

    local exit_code=0
    run_claude "$workspace" "$prompt" "$output_file" "$stderr_file" "$timeout_seconds" \
        "${RALPH_GH_REVIEW_MODEL:-}" "$REVIEW_SCHEMA" "" "$allowed_tools" "" "review" || exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Review timed out after ${timeout_minutes} minutes"
        return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Review Claude invocation exited with code $exit_code"
        [[ -s "$stderr_file" ]] && tail -10 "$stderr_file" >&2
        return 1
    fi

    local so
    so=$(claude_structured_output "$output_file")
    if [[ -n "$so" ]]; then
        local fixed open
        fixed=$(printf '%s' "$so" | jq -r '.findings_fixed // 0')
        open=$(printf '%s' "$so" | jq -r '(.findings_open // []) | length')
        log_status "INFO" "Review report: $fixed finding(s) fixed, $open left open — $(printf '%s' "$so" | jq -r '.recommendation // ""')"
        if [[ "$open" -gt 0 ]]; then
            printf '%s' "$so" | jq -r '.findings_open[] | "  - " + .' >&2
        fi
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

export -f build_full_prompt execute_for_sub_issue
export -f build_review_prompt execute_review
export -f get_saved_session_id clear_saved_session get_last_recommendation
export -f get_last_sub_title get_last_sub_body
export -f run_acceptance_gate
export -f run_e2e_pre_check
