#!/usr/bin/env bash

# verify_gate.sh - shell-owned oracles that run AFTER each Claude turn.
#
# Two gates live here, both independent of the implementing model:
#
# 1. run_verify_gate — a deterministic test/build command run by the shell.
#    Resolution order: $RALPH_GH_VERIFY_CMD, then <workspace>/.ralph/verify.sh.
#    The command runs with RALPH_SUB_START_REF exported so a repo can scope
#    tests to the sub-issue's diff. This is the authoritative red/green: a repo
#    Stop hook (if any) gives the model early feedback, but it lets a second
#    stop through unverified (stop_hook_active), so the shell re-runs the check
#    itself and never trusts the model's tests_status field.
#
# 2. run_verifier_gate — a separate, read-only Claude session (Sonnet by
#    default) that gets the sub-issue's criteria and the diff and grades each
#    criterion against the code. The implementer never grades itself.

RALPH_GH_VERIFY_CMD="${RALPH_GH_VERIFY_CMD:-}"
RALPH_GH_VERIFY_TIMEOUT_MINUTES="${RALPH_GH_VERIFY_TIMEOUT_MINUTES:-15}"
RALPH_GH_VERIFIER_ENABLED="${RALPH_GH_VERIFIER_ENABLED:-1}"
RALPH_GH_VERIFIER_MODEL="${RALPH_GH_VERIFIER_MODEL:-claude-sonnet-5}"
RALPH_GH_VERIFIER_TIMEOUT_MINUTES="${RALPH_GH_VERIFIER_TIMEOUT_MINUTES:-10}"
RALPH_GH_VERIFIER_ALLOWED_TOOLS="${RALPH_GH_VERIFIER_ALLOWED_TOOLS:-Read,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status),Bash(git status *),Bash(git ls-files *),Bash(cat *),Bash(ls *),Bash(wc *),Bash(head *),Bash(tail *)}"

VERIFIER_SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]},"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"met":{"type":"boolean"},"reason":{"type":"string"}},"required":["criterion","met","reason"]}},"summary":{"type":"string"}},"required":["verdict","criteria","summary"]}'

# Echo the verify command for a workspace, or nothing when none is configured.
resolve_verify_cmd() {
    local workspace=$1
    if [[ -n "$RALPH_GH_VERIFY_CMD" ]]; then
        printf '%s' "$RALPH_GH_VERIFY_CMD"
    elif [[ -f "$workspace/.ralph/verify.sh" ]]; then
        printf 'bash %s' "$workspace/.ralph/verify.sh"
    fi
    return 0
}

# Run the verify command in the workspace.
#   $1 = workspace
#   $2 = sub_start_ref (exported as RALPH_SUB_START_REF for diff scoping)
# Returns 0 when green or when nothing is configured (logged as a WARN),
# 1 when red — with the output tail on stdout for the retry context.
run_verify_gate() {
    local workspace=$1
    local sub_start_ref=${2:-}

    local cmd
    cmd=$(resolve_verify_cmd "$workspace")
    if [[ -z "$cmd" ]]; then
        log_status "WARN" "Verify gate skipped: no RALPH_GH_VERIFY_CMD and no .ralph/verify.sh in $workspace"
        telemetry_record_gate "verify" "skip" "no command configured" 2>/dev/null || true
        return 0
    fi

    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    local log_file="${RALPH_GH_STATE_DIR:-$workspace/.ralph-gh}/logs/verify_${stamp}.log"
    mkdir -p "$(dirname "$log_file")"

    local timeout_seconds=$((RALPH_GH_VERIFY_TIMEOUT_MINUTES * 60))
    log_status "INFO" "Verify gate: running \`$cmd\` (timeout ${RALPH_GH_VERIFY_TIMEOUT_MINUTES}m)"

    local rc=0
    (
        cd "$workspace" || exit 1
        export RALPH_SUB_START_REF="$sub_start_ref"
        export RALPH_GH_ACTIVE=1
        portable_timeout "${timeout_seconds}s" bash -c "$cmd" < /dev/null > "$log_file" 2>&1
    )
    rc=$?

    if [[ $rc -eq 0 ]]; then
        log_status "SUCCESS" "Verify gate green"
        telemetry_record_gate "verify" "pass" "$cmd" 2>/dev/null || true
        return 0
    fi

    if [[ $rc -eq 124 ]]; then
        log_status "WARN" "Verify gate timed out after ${RALPH_GH_VERIFY_TIMEOUT_MINUTES}m (log: $log_file)"
        telemetry_record_gate "verify" "fail" "timeout" 2>/dev/null || true
        echo "The verify command \`$cmd\` timed out after ${RALPH_GH_VERIFY_TIMEOUT_MINUTES} minutes. Look for hung processes, watch-mode test runners, or a dev server left running."
        return 1
    fi

    log_status "WARN" "Verify gate RED (exit $rc, log: $log_file)"
    telemetry_record_gate "verify" "fail" "exit $rc" 2>/dev/null || true
    echo "The verify command \`$cmd\` exited $rc. Last 120 lines of output:"
    echo '```'
    tail -120 "$log_file"
    echo '```'
    return 1
}

# Build the verifier prompt.
#   $1 = sub number, $2 = sub title, $3 = sub body, $4 = diff file path,
#   $5 = sub_start_ref, $6 = untracked list (newline-separated, may be empty)
build_verifier_prompt() {
    local sub_number=$1
    local sub_title=$2
    local sub_body=$3
    local diff_file=$4
    local sub_start_ref=$5
    local untracked=$6

    cat <<PROMPT
## Role: independent verifier

You did NOT write this change. A separate implementer session worked on the
sub-issue below and claims it is complete. Your only job is to check, against
the actual code, whether each acceptance criterion is genuinely satisfied.
You are read-only: do not edit files, do not run builds or tests, do not
commit. Verdicts must be grounded in what you can point to in the diff or the
files (path:line).

## Sub-issue #${sub_number} - ${sub_title}

${sub_body}

## What changed

The full diff of the sub-issue's work (\`git diff ${sub_start_ref}\`, committed
plus working tree) is saved at:

    ${diff_file}

Read it first. Then open any file you need to confirm behaviour. You may also
run \`git diff ${sub_start_ref} -- <path>\`, \`git log\`, and \`git show\`.
$( [[ -n "$untracked" ]] && printf '\nNew untracked files (not in the diff, read them directly):\n\n%s\n' "$(printf '%s\n' "$untracked" | sed 's/^/    /')" )

## How to grade

- One entry per acceptance criterion. Use every \`- [ ]\` / \`- [x]\` checklist
  item from the sub-issue body, criterion text verbatim. If the body has no
  checklist, derive 2-4 criteria from its description and say so in the reason.
- \`met: true\` only when the code demonstrably does it. A test that exercises
  the behaviour, or the implementing lines, must exist and be cited in the
  reason as path:line or test name.
- \`met: false\` when the behaviour is missing, partial, only claimed in a
  comment/commit message, or when a required test is absent. Say what is
  missing concretely so the implementer can fix it in one pass.
- Do not grade style, naming, or things the issue did not ask for. Do not fail
  a criterion for something the issue explicitly left out of scope.
- \`verdict\` is PASS only when every criterion is met.
- \`summary\`: one or two lines for a human reviewer.

Deliver the result through the structured output schema. Do not end with
prose only.
PROMPT
}

# Run the independent verifier against the sub-issue's diff.
#   $1 = workspace, $2 = repo, $3 = sub number, $4 = sub title, $5 = sub body,
#   $6 = sub_start_ref
# Returns 0 on PASS (or when disabled / inconclusive — logged loudly),
# 1 on FAIL with the unmet criteria on stdout for the retry context.
run_verifier_gate() {
    local workspace=$1
    local repo=$2
    local sub_number=$3
    local sub_title=$4
    local sub_body=$5
    local sub_start_ref=$6

    if [[ "$RALPH_GH_VERIFIER_ENABLED" != "1" ]]; then
        telemetry_record_gate "verifier" "skip" "disabled" 2>/dev/null || true
        return 0
    fi

    local state_dir="${RALPH_GH_STATE_DIR:-$workspace/.ralph-gh}"
    local stamp
    stamp=$(date '+%Y%m%d_%H%M%S')
    local vdir="$state_dir/verifier"
    mkdir -p "$vdir" "$state_dir/logs"

    local diff_file="$vdir/diff_${sub_number}_${stamp}.patch"
    if [[ -n "$sub_start_ref" ]]; then
        git -C "$workspace" diff "$sub_start_ref" > "$diff_file" 2>/dev/null || true
    else
        git -C "$workspace" diff HEAD > "$diff_file" 2>/dev/null || true
    fi
    local untracked
    untracked=$(git -C "$workspace" ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.ralph-gh/' || true)

    if [[ ! -s "$diff_file" && -z "$untracked" ]]; then
        log_status "WARN" "Verifier gate: no diff since $sub_start_ref — nothing to verify"
        telemetry_record_gate "verifier" "fail" "empty diff" 2>/dev/null || true
        echo "The verifier found no code changes since the sub-issue started. Nothing was implemented."
        return 1
    fi

    local prompt
    prompt=$(build_verifier_prompt "$sub_number" "$sub_title" "$sub_body" "$diff_file" "$sub_start_ref" "$untracked")

    local output_file="$state_dir/logs/verifier_${sub_number}_${stamp}.log"
    local stderr_file="$state_dir/logs/verifier_${sub_number}_${stamp}.stderr.log"
    local timeout_seconds=$((RALPH_GH_VERIFIER_TIMEOUT_MINUTES * 60))

    log_status "INFO" "Verifier gate: independent review of #$sub_number on $RALPH_GH_VERIFIER_MODEL (timeout ${RALPH_GH_VERIFIER_TIMEOUT_MINUTES}m)"

    local rc=0
    run_claude "$workspace" "$prompt" "$output_file" "$stderr_file" "$timeout_seconds" \
        "$RALPH_GH_VERIFIER_MODEL" "$VERIFIER_SCHEMA" "" "$RALPH_GH_VERIFIER_ALLOWED_TOOLS" "dontAsk" "verifier" || rc=$?

    local so
    so=$(claude_structured_output "$output_file")

    if [[ $rc -ne 0 || -z "$so" ]]; then
        # The verifier itself broke (timeout, API error, no structured output).
        # Don't block work on tooling failure, but say so loudly and record it.
        log_status "ERROR" "Verifier gate inconclusive (exit $rc, structured_output=$([[ -n "$so" ]] && echo yes || echo no)) — passing with a warning. Log: $output_file"
        [[ -s "$stderr_file" ]] && tail -10 "$stderr_file" >&2
        telemetry_record_gate "verifier" "skip" "inconclusive exit $rc" 2>/dev/null || true
        return 0
    fi

    printf '%s' "$so" > "$vdir/verdict_${sub_number}_${stamp}.json"

    local verdict
    verdict=$(printf '%s' "$so" | jq -r '.verdict // "FAIL"')
    local summary
    summary=$(printf '%s' "$so" | jq -r '.summary // ""')

    if [[ "$verdict" == "PASS" ]]; then
        log_status "SUCCESS" "Verifier gate PASS: $summary"
        telemetry_record_gate "verifier" "pass" "$summary" 2>/dev/null || true
        return 0
    fi

    local unmet
    unmet=$(printf '%s' "$so" | jq -r '.criteria[] | select(.met == false) | "- \(.criterion) — \(.reason)"')
    log_status "WARN" "Verifier gate FAIL: $summary"
    telemetry_record_gate "verifier" "fail" "$summary" 2>/dev/null || true
    echo "An independent verifier read your diff and found these criteria NOT met:"
    echo ""
    echo "${unmet:-- (verifier returned FAIL without itemised criteria): $summary}"
    return 1
}

export -f resolve_verify_cmd run_verify_gate build_verifier_prompt run_verifier_gate
