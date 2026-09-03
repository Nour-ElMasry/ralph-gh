#!/usr/bin/env bash

# claude_runner.sh - the one place ralph-gh invokes the Claude Code CLI.
#
# Every phase (implement, review, verifier, reconcile) goes through run_claude
# so the flags that matter for unattended runs are set once:
#   --permission-mode auto     classifier approves tool calls; nothing blocks
#                              waiting for a human (Manual is the -p default)
#   --settings {deny:[...]}    hard deny list that auto mode cannot override
#   --setting-sources ...      name the settings sources explicitly so the
#                              repo's hooks/skills keep loading when --bare
#                              becomes the -p default
#   --append-system-prompt-file .ralph/PROMPT.md
#                              project conventions belong in the system prompt,
#                              not the user turn
#   --json-schema              structured result instead of regex over prose
#   --fallback-model / --effort / --max-budget-usd
#
# Result JSON (from --output-format json) is a single object with .result,
# .structured_output, .session_id, .num_turns, .duration_ms, .total_cost_usd,
# .is_error, .stop_reason, .permission_denials. Older/stream formats emit an
# array; claude_result_json normalises both.

RALPH_GH_PERMISSION_MODE="${RALPH_GH_PERMISSION_MODE:-auto}"
RALPH_GH_SETTING_SOURCES="${RALPH_GH_SETTING_SOURCES:-user,project,local}"
RALPH_GH_DENY_RULES="${RALPH_GH_DENY_RULES:-Bash(git push --force*),Bash(git push -f*),Bash(git push origin --delete*),Bash(git push --delete*),Bash(git reset --hard*),Bash(git clean*),Bash(git branch -D*),Bash(git checkout main*),Bash(git checkout master*),Bash(git switch main*),Bash(git switch master*),Bash(git worktree*),Bash(git stash drop*),Bash(gh pr merge*),Bash(gh pr create*),Bash(gh issue close*),Bash(gh issue edit*),Bash(rm -rf /*),Bash(rm -rf ~*)}"
RALPH_GH_FALLBACK_MODEL="${RALPH_GH_FALLBACK_MODEL:-claude-sonnet-5}"
RALPH_GH_EFFORT="${RALPH_GH_EFFORT:-}"
RALPH_GH_MAX_BUDGET_USD="${RALPH_GH_MAX_BUDGET_USD:-}"

# Turn a comma-separated rule list into a --settings JSON blob.
#   $1 = comma-separated deny rules (may be empty)
# Echoes '{"permissions":{"deny":[...]}}' or nothing when the list is empty.
claude_deny_settings_json() {
    local rules=$1
    [[ -z "$rules" ]] && return 0
    printf '%s' "$rules" | jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | {permissions: {deny: .}}'
}

# Build the argv for a claude -p call, one argument per line, WITHOUT the
# prompt (the caller appends "-p <prompt>" since a prompt contains newlines).
#   $1 = workspace (for .ralph/PROMPT.md)
#   $2 = model (may be empty → CLI default / ANTHROPIC_MODEL)
#   $3 = json schema (may be empty)
#   $4 = session id to --resume (may be empty)
#   $5 = comma-separated allowed tools (may be empty)
#   $6 = permission mode (empty → RALPH_GH_PERMISSION_MODE)
#   $7 = "nosys" to skip the .ralph/PROMPT.md system prompt (optional)
claude_build_args() {
    local workspace=$1
    local model=$2
    local schema=$3
    local session_id=$4
    local allowed_tools=$5
    local permission_mode=${6:-$RALPH_GH_PERMISSION_MODE}
    local sys_mode=${7:-}

    printf '%s\n' "--output-format" "json"
    printf '%s\n' "--permission-mode" "$permission_mode"

    if [[ -n "$RALPH_GH_SETTING_SOURCES" ]]; then
        printf '%s\n' "--setting-sources" "$RALPH_GH_SETTING_SOURCES"
    fi

    local deny_json
    deny_json=$(claude_deny_settings_json "$RALPH_GH_DENY_RULES")
    if [[ -n "$deny_json" ]]; then
        printf '%s\n' "--settings" "$deny_json"
    fi

    if [[ -n "$allowed_tools" ]]; then
        printf '%s\n' "--allowedTools"
        local IFS=','
        local tool
        for tool in $allowed_tools; do
            tool=$(printf '%s' "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -n "$tool" ]] && printf '%s\n' "$tool"
        done
        unset IFS
    fi

    if [[ "$sys_mode" != "nosys" && -f "$workspace/.ralph/PROMPT.md" ]]; then
        printf '%s\n' "--append-system-prompt-file" "$workspace/.ralph/PROMPT.md"
    fi

    [[ -n "$model" ]] && printf '%s\n' "--model" "$model"
    [[ -n "$RALPH_GH_FALLBACK_MODEL" ]] && printf '%s\n' "--fallback-model" "$RALPH_GH_FALLBACK_MODEL"
    [[ -n "$RALPH_GH_EFFORT" ]] && printf '%s\n' "--effort" "$RALPH_GH_EFFORT"
    [[ -n "$RALPH_GH_MAX_BUDGET_USD" ]] && printf '%s\n' "--max-budget-usd" "$RALPH_GH_MAX_BUDGET_USD"
    [[ -n "$schema" ]] && printf '%s\n' "--json-schema" "$schema"
    [[ -n "$session_id" ]] && printf '%s\n' "--resume" "$session_id"
    return 0
}

# Run claude -p in a workspace with a wall-clock timeout.
#   $1 = workspace (cwd for the call)
#   $2 = prompt
#   $3 = stdout file (result JSON)
#   $4 = stderr file
#   $5 = timeout seconds
#   $6 = model (may be empty)
#   $7 = json schema (may be empty)
#   $8 = session id to resume (may be empty)
#   $9 = allowed tools (may be empty)
#  $10 = permission mode (may be empty → default)
#  $11 = telemetry phase label (implement|review|verifier|reconcile)
# Returns the CLI exit code (124 on timeout). Records a telemetry event.
run_claude() {
    local workspace=$1
    local prompt=$2
    local output_file=$3
    local stderr_file=$4
    local timeout_seconds=$5
    local model=$6
    local schema=$7
    local session_id=$8
    local allowed_tools=$9
    local permission_mode=${10:-}
    local phase=${11:-unknown}

    mkdir -p "$(dirname "$output_file")" "$(dirname "$stderr_file")"

    local -a cmd_args=("claude")
    local line
    while IFS= read -r line; do
        cmd_args+=("$line")
    done < <(claude_build_args "$workspace" "$model" "$schema" "$session_id" "$allowed_tools" "$permission_mode")
    cmd_args+=("-p" "$prompt")

    local exit_code=0
    (
        cd "$workspace" || exit 1
        portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
            < /dev/null > "$output_file" 2>"$stderr_file"
    )
    exit_code=$?

    # The CLI is dead (exited or killed) — anything still running in the
    # worktree is an orphan of this invocation and would poison the next loop.
    reap_workspace_orphans "$workspace"

    if declare -F telemetry_record_claude >/dev/null 2>&1; then
        telemetry_record_claude "$output_file" "$phase" "$exit_code" "$model" || true
    fi

    # Auto mode ends a headless run after repeated classifier denials. Surface
    # that distinctly — it's a permissions problem, not a model problem.
    local denials
    denials=$(claude_result_field "$output_file" '.permission_denials | length' 2>/dev/null || echo 0)
    if [[ "${denials:-0}" =~ ^[0-9]+$ && "$denials" -gt 0 ]]; then
        log_status "WARN" "Claude ($phase): $denials tool call(s) denied by permissions — see $output_file"
    fi

    return $exit_code
}

# Echo the final result object from a claude --output-format json file.
# Handles both the object form and the array/stream form.
claude_result_json() {
    local output_file=$1
    [[ -f "$output_file" ]] || { echo '{}'; return 0; }
    if jq -e 'type == "array"' "$output_file" >/dev/null 2>&1; then
        jq -c '[.[] | select(.type == "result")] | (.[-1] // {})' "$output_file" 2>/dev/null || echo '{}'
    else
        jq -c '.' "$output_file" 2>/dev/null || echo '{}'
    fi
}

# Echo a jq expression evaluated against the result object (raw output).
#   $1 = output file, $2 = jq expression
claude_result_field() {
    local output_file=$1
    local expr=$2
    claude_result_json "$output_file" | jq -r "$expr // empty" 2>/dev/null
}

# Echo the structured_output object (or empty when absent/invalid).
claude_structured_output() {
    local output_file=$1
    local so
    so=$(claude_result_json "$output_file" | jq -c '.structured_output // empty' 2>/dev/null)
    [[ -n "$so" && "$so" != "null" ]] && printf '%s' "$so"
    return 0
}

export -f claude_deny_settings_json claude_build_args run_claude
export -f claude_result_json claude_result_field claude_structured_output
