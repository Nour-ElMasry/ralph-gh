#!/usr/bin/env bash

# reconciler.sh - Sonnet-powered merge reconciliation for parallel ralph-gh.
#
# Triggered by the orchestrator when:
#   - `git merge --squash` produced conflict markers, OR
#   - the post-merge `pnpm build && pnpm lint` fails (semantic merge issue).
# One reconciler invocation per merged batch. If it can't fix things in one
# pass, the batch aborts and the human is pinged via a PRD comment.

# Path to the prompt template, relative to ralph-gh install dir.
RECON_PROMPT_PATH="${RECON_PROMPT_PATH:-$SCRIPT_DIR/prompts/reconciler.md}"

# Run the reconciler against the parent worktree's CURRENT (dirty for
# merge_conflict, clean-but-broken for post_merge_verify) state.
#
# Args:
#   $1 = parent_issue
#   $2 = parent_branch
#   $3 = sub_branches (comma-separated)
#   $4 = failure_kind ("merge_conflict" | "post_merge_verify")
#   $5 = conflict_files (newline-separated, may be empty)
#   $6 = failure_log_path (may be empty)
# Returns: 0 if reconciliation succeeded AND post-reconcile verification is
# green, 1 otherwise.
reconcile_merge() {
    local parent_issue=$1
    local parent_branch=$2
    local sub_branches=$3
    local failure_kind=$4
    local conflict_files=$5
    local failure_log_path=$6

    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    if [[ ! -d "$parent_worktree" ]]; then
        log_status "ERROR" "Parent worktree missing: $parent_worktree"
        return 1
    fi

    if [[ ! -f "$RECON_PROMPT_PATH" ]]; then
        log_status "ERROR" "Reconciler prompt missing at $RECON_PROMPT_PATH"
        return 1
    fi

    local prompt
    prompt=$(cat "$RECON_PROMPT_PATH")

    # Inject AGENT.md so the reconciler knows how to run build/lint
    if [[ -f "$parent_worktree/.ralph/AGENT.md" ]]; then
        prompt+=$'\n\n---\n\n## Repo Build Instructions\n\n'
        prompt+=$(cat "$parent_worktree/.ralph/AGENT.md")
    fi

    # Build Claude CLI command. Use Sonnet (cheaper than Opus, this work is
    # mechanical) and a tight allowed-tools list.
    local model="${RALPH_RECONCILER_MODEL:-claude-sonnet-4-6}"
    local timeout_minutes="${RALPH_RECONCILER_TIMEOUT_MINUTES:-15}"
    local timeout_seconds=$((timeout_minutes * 60))
    local allowed_tools="${RALPH_RECONCILER_ALLOWED_TOOLS:-Read,Edit,Write,Bash(git *),Bash(pnpm *),Bash(cat *),Bash(echo *)}"

    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    local output_file="$HOME/.ralph-gh/runs/issue-${parent_issue}/reconcile_${stamp}.log"
    local stderr_file="$HOME/.ralph-gh/runs/issue-${parent_issue}/reconcile_${stamp}.stderr.log"
    mkdir -p "$(dirname "$output_file")"

    log_status "INFO" "Invoking reconciler ($model, kind=$failure_kind, timeout ${timeout_minutes}m)"

    local -a cmd_args=("claude")
    cmd_args+=("--model" "$model")
    cmd_args+=("--output-format" "json")
    cmd_args+=("--allowedTools")
    local IFS=','
    read -ra tools_array <<< "$allowed_tools"
    for tool in "${tools_array[@]}"; do
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -n "$tool" ]] && cmd_args+=("$tool")
    done
    cmd_args+=("-p" "$prompt")

    # Run with reconciliation context exported as env vars (the prompt reads them)
    local exit_code=0
    (
        cd "$parent_worktree"
        export RECON_PARENT_ISSUE="$parent_issue"
        export RECON_PARENT_BRANCH="$parent_branch"
        export RECON_SUB_BRANCHES="$sub_branches"
        export RECON_FAILURE_KIND="$failure_kind"
        export RECON_CONFLICT_FILES="$conflict_files"
        export RECON_FAILURE_LOG_PATH="$failure_log_path"
        portable_timeout "${timeout_seconds}s" "${cmd_args[@]}" \
            < /dev/null > "$output_file" 2>"$stderr_file"
    )
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        log_status "WARN" "Reconciler timed out after ${timeout_minutes}m"
        return 1
    fi
    if [[ $exit_code -ne 0 ]]; then
        log_status "ERROR" "Reconciler exited code $exit_code"
        [[ -s "$stderr_file" ]] && tail -20 "$stderr_file" >&2
        return 1
    fi

    # Verify the reconciler's claim by re-running build/lint. If still red,
    # treat reconciliation as failed regardless of what the model reported.
    log_status "INFO" "Re-running post-reconcile verification"
    local verify_log
    if verify_log=$(sub_worktree_verify_parent "$parent_issue"); then
        : # green
    else
        log_status "ERROR" "Post-reconcile verification still red — aborting batch"
        return 1
    fi

    # Sanity: there must be a commit on the parent branch (reconciler shouldn't
    # leave the merge half-applied). If a merge_conflict reconciliation didn't
    # produce a commit, something is wrong.
    if [[ "$failure_kind" == "merge_conflict" ]]; then
        if git -C "$parent_worktree" diff --name-only --diff-filter=U 2>/dev/null | grep -q .; then
            log_status "ERROR" "Reconciler left unresolved conflicts"
            return 1
        fi
        # If there's an in-progress merge state, finalize it
        if [[ -f "$parent_worktree/.git/MERGE_HEAD" ]]; then
            log_status "WARN" "Merge state still in progress; aborting"
            git -C "$parent_worktree" merge --abort 2>/dev/null || true
            return 1
        fi
    fi

    log_status "SUCCESS" "Reconciliation complete"
    return 0
}

export -f reconcile_merge
