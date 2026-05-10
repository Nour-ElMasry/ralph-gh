#!/usr/bin/env bash

# parallel_orchestrator.sh - DAG-driven scheduler for parallel sub-issue execution.
#
# Replaces the inner serial loop in process_parent_group when the parent's
# DAG has genuine parallelism (see dag_has_parallelism). Sequential DAGs go
# through the legacy loop unchanged so existing PRDs behave identically.
#
# The scheduler is a single thread of control inside the foreground ralph-gh
# process. On each tick it:
#   1. Reaps any background workers whose pid has exited.
#   2. Squash-merges their sub-branch into the parent branch.
#      - on conflict or post-merge build/lint failure, invokes the reconciler.
#   3. Promotes blocked sub-issues whose deps are all in `merged` to `ready`.
#   4. Cascades failures into `blocked → failed` for downstream of failed subs.
#   5. Spawns up to `RALPH_MAX_PARALLEL` workers from the `ready` queue.
#   6. Sleeps a short interval and repeats.
#
# Worker tracking lives in /home/$USER/.ralph-gh/runs/issue-<parent>/workers/<sub>.pid
# (PID file written at spawn, removed at reap). This survives ralph-gh restart:
# on restart, any pid still alive is treated as still-running; dead pids with
# their branch in non-merged state are reaped.

WORKER_TICK_SECONDS="${WORKER_TICK_SECONDS:-3}"

# Spawn a background worker for one sub-issue. The worker:
#   - cd's into its sub-worktree
#   - sets up RALPH_GH_WORKSPACE / STATE_DIR for the sub
#   - calls execute_for_sub_issue (existing code path; runs Stop hook)
#   - writes its exit code to <state_dir>/exit_code on completion
#
# Returns the worker pid via stdout.
_spawn_sub_worker() {
    local parent_issue=$1
    local sub_issue=$2
    local parent_branch=$3

    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    local sub_worktree="$parent_worktree/sub-${sub_issue}"
    local sub_state_dir="$HOME/.ralph-gh/runs/issue-${parent_issue}/sub-${sub_issue}"

    if [[ ! -d "$sub_worktree" ]]; then
        log_status "ERROR" "Cannot spawn worker for #$sub_issue: sub-worktree missing"
        return 1
    fi

    mkdir -p "$sub_state_dir/logs"
    local exit_file="$sub_state_dir/exit_code"
    rm -f "$exit_file"

    # Capture context for the worker. Each background subshell needs its own
    # RALPH_GH_WORKSPACE (the sub-worktree) and RALPH_GH_STATE_DIR (per-sub).
    (
        export RALPH_GH_WORKSPACE="$sub_worktree"
        export RALPH_GH_STATE_DIR="$sub_state_dir"
        export STATE_DIR="$sub_state_dir"
        export STATE_FILE="$sub_state_dir/state.json"
        export CB_STATE_FILE="$sub_state_dir/.circuit_breaker_state"
        export LOG_DIR="$sub_state_dir/logs"
        export RALPH_GH_ACTIVE=1

        # Initialize per-sub state (the sub-worker tracks its own
        # circuit-breaker; the parent's CB is unrelated).
        init_state
        init_circuit_breaker

        # Mark this sub as the only "remaining" so existing helpers still work
        # when execute_for_sub_issue indirectly queries them (it doesn't, but
        # belt-and-suspenders for resume cases).
        set_in_progress "$parent_issue" "ralph/issue-${parent_issue}-${sub_issue}" "$sub_issue"

        cd "$sub_worktree" || exit 1

        # Loop per sub-issue with the same gate the legacy loop uses. Cap loops.
        local loop_count=0
        local sub_done=false
        local retry_context=""
        local result=0

        while [[ "$sub_done" == "false" ]]; do
            loop_count=$((loop_count + 1))
            if [[ $loop_count -gt $RALPH_GH_MAX_LOOPS_PER_ISSUE ]]; then
                log_status "ERROR" "Sub #$sub_issue hit max loops"
                result=1
                break
            fi
            if ! can_execute; then
                log_status "ERROR" "Sub #$sub_issue: circuit breaker open"
                result=1
                break
            fi

            local r=0
            execute_for_sub_issue \
                "$sub_worktree" \
                "$RALPH_GH_REPO" \
                "$sub_issue" \
                "$parent_issue" \
                "$(get_saved_session_id)" \
                "$RALPH_GH_ALLOWED_TOOLS" \
                "$CLAUDE_TIMEOUT_MINUTES" \
                "$retry_context" \
                "false" || r=$?

            if [[ $r -ne 0 ]]; then
                record_result "false" "true"
                retry_context="Previous Claude invocation failed or produced no changes. Re-read the acceptance criteria and try again."
                continue
            fi

            local acceptance_failures
            if ! acceptance_failures=$(run_acceptance_gate 2>&1); then
                retry_context="ACCEPTANCE GATE FAILED. Address each criterion and re-report the ACCEPTANCE block.\n\n$acceptance_failures"
                record_result "true" "true"
                continue
            fi

            # All gates green — commit any leftovers
            local sub_title
            sub_title=$(get_issue_title "$RALPH_GH_REPO" "$sub_issue") || sub_title="Sub-issue $sub_issue"
            commit_changes "$sub_issue" "$sub_title" || true
            record_result "true" "false" || true
            sub_done=true
            result=0
        done

        echo "$result" > "$exit_file"
        exit "$result"
    ) >> "$sub_state_dir/logs/worker.log" 2>&1 &

    local pid=$!
    echo "$pid" > "$sub_state_dir/worker.pid"
    log_status "INFO" "Spawned worker pid=$pid for sub #$sub_issue"
    echo "$pid"
}

# True if the worker for a sub is still running (has a live PID file pointing
# at a live process).
_worker_alive() {
    local parent_issue=$1
    local sub_issue=$2
    local pid_file="$HOME/.ralph-gh/runs/issue-${parent_issue}/sub-${sub_issue}/worker.pid"
    [[ -f "$pid_file" ]] || return 1
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Read a worker's exit code (0 = success, non-0 = fail). Returns 1 if no
# exit_code file exists yet.
_worker_exit_code() {
    local parent_issue=$1
    local sub_issue=$2
    local exit_file="$HOME/.ralph-gh/runs/issue-${parent_issue}/sub-${sub_issue}/exit_code"
    if [[ -f "$exit_file" ]]; then
        cat "$exit_file"
        return 0
    fi
    return 1
}

# Reap any worker that has finished. For each finished worker:
#   - if exit_code == 0: squash-merge into parent, run reconciler if needed,
#     mark merged on success, failed on reconcile-failure.
#   - if exit_code != 0: mark failed.
# Returns the count of workers reaped this tick.
_reap_finished_workers() {
    local parent_issue=$1
    local parent_branch=$2

    local reaped=0
    local sub
    while IFS= read -r sub; do
        [[ -z "$sub" ]] && continue
        if _worker_alive "$parent_issue" "$sub"; then
            continue
        fi

        local ec
        if ! ec=$(_worker_exit_code "$parent_issue" "$sub"); then
            # No exit_code yet — process may have died abnormally
            log_status "WARN" "Worker for #$sub vanished without exit code; treating as failed"
            ec=1
        fi

        log_status "INFO" "Reaping worker for #$sub (exit_code=$ec)"
        reaped=$((reaped + 1))

        if [[ "$ec" != "0" ]]; then
            with_dag_state_lock dag_state_mark_failed "$sub"
            sub_worktree_cleanup "$parent_issue" "$sub"
            continue
        fi

        # Worker succeeded — merge into parent. The parent worktree's git ops
        # need an exclusive lock because two reaps could fire near-simultaneously
        # and corrupt the index.
        local merge_result=0
        local conflicts=""
        with_dag_state_lock _merge_one_sub "$parent_issue" "$sub" "$parent_branch" || merge_result=$?
        sub_worktree_cleanup "$parent_issue" "$sub"
    done <<< "$(dag_state_running_subs)"

    echo "$reaped"
}

# Internal: merge a single sub-branch into parent, run post-merge verify,
# invoke reconciler on failure, and update DAG state. Must be called inside
# with_dag_state_lock to serialize parent-worktree git ops.
_merge_one_sub() {
    local parent_issue=$1
    local sub=$2
    local parent_branch=$3

    local conflicts
    if conflicts=$(sub_worktree_merge "$parent_issue" "$sub"); then
        # Clean merge — now run post-merge verify
        local verify_log
        if verify_log=$(sub_worktree_verify_parent "$parent_issue"); then
            dag_state_mark_merged "$sub"
            return 0
        fi

        # Post-merge verify failed — try reconciler
        log_status "WARN" "Post-merge verify failed for #$sub; invoking reconciler"
        local merged_so_far
        merged_so_far=$(dag_state_merged_subs | tr '\n' ',' | sed 's/,$//')
        local sub_branches="ralph/issue-${parent_issue}-${sub}"
        if [[ -n "$merged_so_far" ]]; then
            for prev in $(echo "$merged_so_far" | tr ',' ' '); do
                sub_branches+=",ralph/issue-${parent_issue}-${prev}"
            done
        fi
        if reconcile_merge "$parent_issue" "$parent_branch" "$sub_branches" "post_merge_verify" "" "$verify_log"; then
            dag_state_mark_merged "$sub"
            return 0
        fi
        dag_state_mark_failed "$sub"
        return 1
    fi

    # `conflicts` contains the list of conflicted files
    log_status "WARN" "Merge conflict for #$sub; invoking reconciler"
    local sub_branches="ralph/issue-${parent_issue}-${sub}"
    if reconcile_merge "$parent_issue" "$parent_branch" "$sub_branches" "merge_conflict" "$conflicts" ""; then
        dag_state_mark_merged "$sub"
        return 0
    fi

    # Reconciler failed — abort the merge state so we leave the worktree clean
    local parent_worktree="$WORKTREE_BASE/issue-${parent_issue}"
    git -C "$parent_worktree" merge --abort 2>/dev/null || true
    git -C "$parent_worktree" reset --hard HEAD 2>/dev/null || true
    dag_state_mark_failed "$sub"
    return 1
}

# Spawn workers up to capacity from the ready queue.
_spawn_up_to_capacity() {
    local parent_issue=$1
    local parent_branch=$2

    local cap="${RALPH_MAX_PARALLEL:-2}"
    while true; do
        local running
        running=$(dag_state_running_count)
        if (( running >= cap )); then
            break
        fi

        local next
        if ! next=$(with_dag_state_lock dag_state_pop_ready); then
            break
        fi
        [[ -z "$next" ]] && break

        # Set up sub-worktree against the CURRENT parent branch tip (so the
        # newly-merged dependency commits are included).
        if ! sub_worktree_setup "$parent_issue" "$next" "$parent_branch"; then
            log_status "ERROR" "Sub-worktree setup failed for #$next, marking failed"
            with_dag_state_lock dag_state_mark_failed "$next"
            continue
        fi

        with_dag_state_lock dag_state_mark_running "$next"
        _spawn_sub_worker "$parent_issue" "$next" "$parent_branch" >/dev/null
    done
}

# Main scheduler entry point. Called instead of the legacy serial loop when
# the DAG has parallelism. Returns 0 if all sub-issues merged successfully,
# 1 if any failed (parent group continues; the PR reflects what merged).
parallel_process_dag() {
    local parent_issue=$1
    local parent_branch=$2

    log_status "INFO" "Parallel scheduler engaged (max_parallel=${RALPH_MAX_PARALLEL:-2})"

    # Promote initial zero-dep subs to ready
    with_dag_state_lock dag_state_promote_ready >/dev/null

    while true; do
        # Cascade any failures first (so we don't waste a worker on a sub
        # whose deps already failed)
        with_dag_state_lock dag_state_cascade_failures >/dev/null

        # Reap finished workers (squash-merges happen here)
        _reap_finished_workers "$parent_issue" "$parent_branch" >/dev/null

        # After reaping, deps may have been satisfied — promote
        with_dag_state_lock dag_state_promote_ready >/dev/null

        # Spawn workers up to capacity
        _spawn_up_to_capacity "$parent_issue" "$parent_branch"

        # Termination: all running buckets empty
        local running ready blocked
        running=$(dag_state_running_count)
        ready=$(dag_state_ready_count)
        blocked=$(dag_state_blocked_count)
        if (( running == 0 && ready == 0 && blocked == 0 )); then
            break
        fi

        sleep "$WORKER_TICK_SECONDS"
    done

    # Summarize
    local merged_count failed_count
    merged_count=$(dag_state_merged_subs | grep -c . || true)
    failed_count=$(dag_state_failed_count)
    log_status "INFO" "DAG complete: merged=$merged_count failed=$failed_count"

    if (( failed_count > 0 )); then
        return 1
    fi
    return 0
}

export -f parallel_process_dag
export -f _spawn_sub_worker _worker_alive _worker_exit_code
export -f _reap_finished_workers _merge_one_sub _spawn_up_to_capacity
