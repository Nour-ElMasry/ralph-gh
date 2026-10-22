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
#    A red run is checked against a baseline when the command lists its
#    failures, one stable id per line, in $RALPH_VERIFY_FAILURES_FILE: the
#    same command re-runs on the sub-issue's start commit in a throwaway
#    worktree, and only failures that are not already red there keep the gate
#    red. Without that list a red run stays red, as before, and so does a run
#    killed by a signal. The list must name every failing thing — build,
#    typecheck and lint as well as tests: a failure it leaves out can hide
#    behind one that is pre-existing.
#
# 2. run_verifier_gate — a separate, read-only Claude session (Sonnet by
#    default) that gets the sub-issue's criteria and the diff and grades each
#    criterion against the code. The implementer never grades itself.

RALPH_GH_VERIFY_CMD="${RALPH_GH_VERIFY_CMD:-}"
RALPH_GH_VERIFY_TIMEOUT_MINUTES="${RALPH_GH_VERIFY_TIMEOUT_MINUTES:-15}"
RALPH_GH_VERIFY_BASELINE="${RALPH_GH_VERIFY_BASELINE:-1}"  # 0 = a red run never re-runs on the base commit
RALPH_GH_VERIFIER_ENABLED="${RALPH_GH_VERIFIER_ENABLED:-1}"
RALPH_GH_VERIFIER_MODEL="${RALPH_GH_VERIFIER_MODEL:-claude-sonnet-5}"
RALPH_GH_VERIFIER_TIMEOUT_MINUTES="${RALPH_GH_VERIFIER_TIMEOUT_MINUTES:-10}"
RALPH_GH_VERIFIER_ALLOWED_TOOLS="${RALPH_GH_VERIFIER_ALLOWED_TOOLS:-Read,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status),Bash(git status *),Bash(git ls-files *),Bash(cat *),Bash(ls *),Bash(wc *),Bash(head *),Bash(tail *)}"

VERIFIER_SCHEMA='{"type":"object","properties":{"verdict":{"type":"string","enum":["PASS","FAIL"]},"criteria":{"type":"array","items":{"type":"object","properties":{"criterion":{"type":"string"},"met":{"type":"boolean"},"unmeetable":{"type":"boolean"},"reason":{"type":"string"}},"required":["criterion","met","reason"]}},"summary":{"type":"string"}},"required":["verdict","criteria","summary"]}'

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
#   $3 = parent issue number (keys the PR's list of pre-existing failures)
# Returns 0 when green, when every listed failure is already red on the base
# commit, or when nothing is configured (the last two logged as a WARN),
# 1 when red — with the failures and output tail on stdout for the retry
# context. A pass on pre-existing failures alone echoes their ids: they are
# still red, and the verifier must hear so.
run_verify_gate() {
    local workspace=$1
    local sub_start_ref=${2:-}
    local parent_number=${3:-}

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
    local failures_file="${log_file%.log}.failures"
    mkdir -p "$(dirname "$log_file")"
    rm -f "$failures_file"

    local timeout_seconds=$((RALPH_GH_VERIFY_TIMEOUT_MINUTES * 60))
    log_status "INFO" "Verify gate: running \`$cmd\` (timeout ${RALPH_GH_VERIFY_TIMEOUT_MINUTES}m)"

    local rc=0
    (
        cd "$workspace" || exit 1
        export RALPH_SUB_START_REF="$sub_start_ref"
        export RALPH_VERIFY_FAILURES_FILE="$failures_file"
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

    local failures
    failures=$(_verify_failure_ids "$failures_file")
    # Above 128 the run died on a signal (an OOM kill, timeout's KILL) and its
    # list stops wherever it was cut off.
    if [[ -n "$failures" && $rc -le 128 && -n "$sub_start_ref" && "$RALPH_GH_VERIFY_BASELINE" == "1" ]]; then
        local base_failures
        if base_failures=$(verify_baseline_failures "$workspace" "$sub_start_ref" "$cmd" "$failures"); then
            local new_failures pre_existing
            new_failures=$(LC_ALL=C comm -23 <(printf '%s\n' "$failures") <(printf '%s\n' "$base_failures") | sed '/^$/d')
            pre_existing=$(LC_ALL=C comm -12 <(printf '%s\n' "$failures") <(printf '%s\n' "$base_failures") | sed '/^$/d')
            if [[ -z "$new_failures" ]]; then
                local count
                count=$(printf '%s\n' "$pre_existing" | wc -l)
                log_status "WARN" "Verify gate red only on $count failure(s) already red at ${sub_start_ref:0:8} — passing (log: $log_file)"
                record_pre_existing_failures "$parent_number" "$pre_existing" \
                    "$(git -C "$workspace" rev-parse "${sub_start_ref}^{commit}")"
                telemetry_record_gate "verify" "pass" "baseline-only: $count" 2>/dev/null || true
                printf '%s\n' "$pre_existing"
                return 0
            fi

            local new_count
            new_count=$(printf '%s\n' "$new_failures" | wc -l)
            log_status "WARN" "Verify gate RED (exit $rc, $new_count new failure(s), log: $log_file)"
            telemetry_record_gate "verify" "fail" "exit $rc, $new_count new" 2>/dev/null || true
            echo "The verify command \`$cmd\` exited $rc. These failures are new on this branch — fix them:"
            echo ""
            printf '%s\n' "$new_failures" | sed 's/^/- /'
            if [[ -n "$pre_existing" ]]; then
                echo ""
                echo "These were already red on the base commit (${sub_start_ref:0:8}); leave them unless a criterion asks you to fix them:"
                echo ""
                printf '%s\n' "$pre_existing" | sed 's/^/- /'
            fi
            echo ""
            echo "Last 120 lines of output:"
            echo '```'
            tail -120 "$log_file"
            echo '```'
            return 1
        fi
        log_status "WARN" "Verify baseline inconclusive — the gate stays red"
    fi

    log_status "WARN" "Verify gate RED (exit $rc, log: $log_file)"
    telemetry_record_gate "verify" "fail" "exit $rc" 2>/dev/null || true
    echo "The verify command \`$cmd\` exited $rc. Last 120 lines of output:"
    echo '```'
    tail -120 "$log_file"
    echo '```'
    return 1
}

# Echo the failure ids the verify command reports on the base commit, scoped
# to the same packages as the branch run. Every run is cached per (base
# commit, set of changed files); a failure red on base in any scope is red on
# base, so when the cached runs for this commit already name every branch
# failure, none runs again.
# Runs in a subshell: its EXIT trap removes the throwaway worktree on every
# path without touching the caller's signal handlers.
#   $1 = workspace, $2 = base ref, $3 = verify command,
#   $4 = the branch run's failure ids (sorted)
# Returns 1 when the baseline is inconclusive (no worktree, a timeout or a
# signal, a red run with no failure list) — the caller then keeps the gate red.
verify_baseline_failures() (
    local workspace=$1
    local base_ref=$2
    local cmd=$3
    local branch_failures=$4

    local base_sha snapshot scope_key
    base_sha=$(git -C "$workspace" rev-parse --verify --quiet "${base_ref}^{commit}") || exit 1
    snapshot=$(_verify_tree_snapshot "$workspace") || exit 1
    scope_key=$(git -C "$workspace" diff --name-only "$base_sha" "$snapshot" | sha1sum | cut -c1-12)

    local state_dir="${RALPH_GH_STATE_DIR:-$workspace/.ralph-gh}"
    local cache_dir="$state_dir/verify_baseline"
    local cache_file="$cache_dir/${base_sha}-${scope_key}.failures"
    local known
    known=$(_verify_failure_ids "$cache_dir/${base_sha}"-*.failures)
    if [[ -f "$cache_file" ]] || [[ -n "$known" && -z "$(LC_ALL=C comm -23 \
            <(printf '%s\n' "$branch_failures") <(printf '%s\n' "$known") | sed '/^$/d')" ]]; then
        log_status "INFO" "Verify baseline: reusing the cached runs at ${base_sha:0:8}"
        printf '%s' "$known"
        exit 0
    fi

    # Outside the workspace: without worktree mode the state dir lives inside
    # it, and a nested checkout there is one more package tree for every tool
    # that walks the repo.
    local tree_root="$HOME/.ralph-gh/baselines"
    mkdir -p "$cache_dir" "$state_dir/logs" "$tree_root"
    _verify_reap_stale_trees "$workspace" "$tree_root"
    local base_tree="$tree_root/wt-${base_sha:0:12}-$BASHPID"
    local failures_file="$cache_dir/run-$BASHPID.failures"
    local log_file
    log_file="$state_dir/logs/verify_baseline_$(date '+%Y%m%d_%H%M%S').log"
    # shellcheck disable=SC2064  # expand now: the trap fires as the subshell exits
    trap "$(printf '_verify_remove_tree %q %q; rm -f %q' "$workspace" "$base_tree" "$failures_file")" EXIT
    trap 'exit 143' TERM INT

    if ! git -C "$workspace" worktree add --detach --quiet "$base_tree" "$base_sha" >/dev/null 2>&1; then
        log_status "WARN" "Verify baseline: could not create a worktree at ${base_sha:0:8}"
        exit 1
    fi
    # Gitignored env files never come with a checkout; the suites need them.
    if declare -F _copy_untracked_env_files >/dev/null; then
        _copy_untracked_env_files "$workspace" "$base_tree"
    fi

    log_status "INFO" "Verify baseline: re-running \`$cmd\` on ${base_sha:0:8} to separate pre-existing failures (log: $log_file)"
    local rc=0
    (
        cd "$base_tree" || exit 1
        # The branch's tree, not the base: a script that scopes by
        # "changed since \$RALPH_SUB_START_REF" (turbo's [ref] filter) then
        # selects the same packages here as it did on the branch. Pointing it
        # at the base would select nothing and pass everything.
        export RALPH_SUB_START_REF="$snapshot"
        export RALPH_VERIFY_BASELINE=1
        export RALPH_VERIFY_FAILURES_FILE="$failures_file"
        export RALPH_GH_ACTIVE=1
        portable_timeout "$((RALPH_GH_VERIFY_TIMEOUT_MINUTES * 60))s" bash -c "$cmd" < /dev/null > "$log_file" 2>&1
    )
    rc=$?

    local ids=""
    if [[ $rc -ne 0 ]]; then
        ids=$(_verify_failure_ids "$failures_file")
        if [[ $rc -eq 124 || $rc -gt 128 || -z "$ids" ]]; then
            log_status "WARN" "Verify baseline inconclusive (exit $rc$([[ -z "$ids" ]] && printf ', no failure list'), log: $log_file)"
            exit 1
        fi
    fi
    printf '%s' "$ids" > "$cache_file"
    printf '%s' "$ids"
)

# Echo a commit holding the workspace's tree as it is now — HEAD plus staged,
# unstaged and untracked (not ignored) changes — without touching its index.
# Starts from a copy of the real index so unchanged files are not re-hashed.
# The copy keeps the index's mtime: git trusts an entry's stat data only when
# the file is older than the index, and a fresh mtime would hide a same-size
# edit made in the same second as the last index write.
_verify_tree_snapshot() (
    local workspace=$1
    local index
    index=$(mktemp) || exit 1
    trap 'rm -f "$index"' EXIT
    cp -p "$(git -C "$workspace" rev-parse --path-format=absolute --git-path index)" "$index" 2>/dev/null \
        || rm -f "$index"
    export GIT_INDEX_FILE="$index"
    git -C "$workspace" add -A >/dev/null 2>&1 || exit 1
    local tree
    tree=$(git -C "$workspace" write-tree) || exit 1
    git -C "$workspace" -c user.name=ralph-gh -c user.email=ralph-gh@localhost \
        commit-tree "$tree" -p HEAD -m "ralph-gh verify baseline scope"
)

_verify_remove_tree() {
    local workspace=$1
    local tree=$2
    [[ -d "$tree" ]] || return 0
    if declare -F reap_workspace_orphans >/dev/null; then
        reap_workspace_orphans "$tree"
    fi
    git -C "$workspace" worktree remove --force "$tree" >/dev/null 2>&1 || rm -rf "$tree"
    git -C "$workspace" worktree prune >/dev/null 2>&1 || true
}

# Remove base worktrees whose run is gone — the EXIT trap never fires on a
# SIGKILL or a crashed machine. A tree is named for the subshell that made it.
#   $1 = workspace, $2 = the baselines directory
_verify_reap_stale_trees() {
    local workspace=$1
    local tree_root=$2
    local tree pid
    for tree in "$tree_root"/wt-*-*; do
        [[ -d "$tree" ]] || continue
        pid=${tree##*-}
        kill -0 "$pid" 2>/dev/null && continue
        log_status "INFO" "Verify baseline: removing a stale worktree at $tree"
        rm -rf "$tree"
    done
    # Drops this repo's records of the removed trees; another repo's go on its
    # next prune.
    git -C "$workspace" worktree prune >/dev/null 2>&1 || true
}

# Echo the ids in the failures files that exist: trimmed, de-duplicated,
# C-sorted for comm.
_verify_failure_ids() {
    local files=() file
    for file in "$@"; do
        [[ -f "$file" ]] && files+=("$file")
    done
    (( ${#files[@]} )) || return 0
    sed 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*$//' "${files[@]}" | sed '/^$/d' | LC_ALL=C sort -u
}

# Path of a parent's pre-existing-failures list. Outside every run's state
# dir: parallel sub-workers each have their own, and worktree mode deletes
# the parent's when a held run ends — the resumed run rewrites the PR body.
#   $1 = parent issue number
pre_existing_failures_file() {
    local repo=${RALPH_GH_REPO:-local}
    printf '%s/.ralph-gh/pre_existing/%s-%s.txt' "$HOME" "${repo//\//_}" "${1:-unknown}"
}

# Lines are "<id><TAB><base sha>".
#   $1 = parent issue number, $2 = failure ids (newline-separated),
#   $3 = the commit they were red on
record_pre_existing_failures() {
    local file
    file=$(pre_existing_failures_file "$1")
    mkdir -p "$(dirname "$file")"
    printf '%s\n' "$2" | sed '/^$/d' | sed "s/\$/	$3/" >> "$file"
}

# Echo the PR-body section listing a parent's pre-existing failures, or nothing.
# A base commit is a sub-issue's start, which can be an earlier sub-issue's
# work rather than main — so each entry says which.
#   $1 = parent issue number
pre_existing_failures_section() {
    local file
    file=$(pre_existing_failures_file "$1")
    [[ -s "$file" ]] || return 0
    local main_ref="origin/${RALPH_GH_MAIN_BRANCH:-main}"
    git -C "${RALPH_GH_WORKSPACE:-.}" rev-parse --verify --quiet "$main_ref" >/dev/null \
        || main_ref=${RALPH_GH_MAIN_BRANCH:-main}
    printf '\n### Pre-existing failures\n\n'
    printf 'The verify gate passed these because each was already red on the commit its sub-issue started from. One red only on this branch may have been caused by an earlier sub-issue — check it before merging.\n\n'
    local id sha where
    # First sighting of each id: the earliest commit it was red on.
    LC_ALL=C sort -t $'\t' -k1,1 -s "$file" | awk -F'\t' '!seen[$1]++' | while IFS=$'\t' read -r id sha; do
        if git -C "${RALPH_GH_WORKSPACE:-.}" merge-base --is-ancestor "$sha" "$main_ref" 2>/dev/null; then
            where="on \`${main_ref##*/}\`"
        else
            where="this branch only"
        fi
        printf -- '- `%s` — red at `%s` (%s)\n' "$id" "${sha:0:8}" "$where"
    done
}

# Build the verifier prompt.
#   $1 = sub number, $2 = sub title, $3 = sub body, $4 = diff file path,
#   $5 = sub_start_ref, $6 = untracked list (newline-separated, may be empty),
#   $7 = verify command, $8 = failures the verify gate passed as pre-existing
build_verifier_prompt() {
    local sub_number=$1
    local sub_title=$2
    local sub_body=$3
    local diff_file=$4
    local sub_start_ref=$5
    local untracked=$6
    local verify_cmd=$7
    local pre_existing=${8:-}
    local verify_result="exited 0"
    if [[ -n "$pre_existing" ]]; then
        verify_result="failed only on what was already failing at \`${sub_start_ref}\`, so the shell let it through. These are still RED:

$(printf '%s\n' "$pre_existing" | sed 's/^/    /')

A criterion that asks for any of these to pass or be fixed is NOT met. Every other
check the script runs passed"
    fi

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
$( [[ -n "$verify_cmd" ]] && printf '\n## What the shell already ran\n\nJust before you started, the shell ran `%s` on this exact tree and it\n%s. Read that script to see which commands it runs. A criterion that\nonly asks for one of those commands to pass (typecheck, build, lint, test) is\nmet: cite the script line that runs it. If the script does not run the\ncommand a criterion names, the criterion is not met; say the verify script\ndoes not run it.\n' "$verify_cmd" "$verify_result" )

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
- \`unmeetable: true\` (with \`met: false\`) only when no change to this
  repository could satisfy the criterion as worded: it asks for something
  outside the repo (a PR description, an issue's state, a deploy), contradicts
  another criterion or the codebase, or names something that does not exist.
  Say why in the reason. Leave it out otherwise.
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
#   $6 = sub_start_ref, $7 = what run_verify_gate echoed on its pass (the
#   failures it let through as pre-existing; empty when it was green)
# Returns 0 on PASS (or when disabled / inconclusive — logged loudly),
# 1 on FAIL with the unmet criteria on stdout for the retry context.
run_verifier_gate() {
    local workspace=$1
    local repo=$2
    local sub_number=$3
    local sub_title=$4
    local sub_body=$5
    local sub_start_ref=$6
    local pre_existing=${7:-}

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
    # Callers run this only after run_verify_gate passed on the same tree.
    prompt=$(build_verifier_prompt "$sub_number" "$sub_title" "$sub_body" "$diff_file" "$sub_start_ref" "$untracked" \
        "$(resolve_verify_cmd "$workspace")" "$pre_existing")

    local output_file="$state_dir/logs/verifier_${sub_number}_${stamp}.log"
    local stderr_file="$state_dir/logs/verifier_${sub_number}_${stamp}.stderr.log"
    local timeout_seconds=$((RALPH_GH_VERIFIER_TIMEOUT_MINUTES * 60))

    log_status "INFO" "Verifier gate: independent review of #$sub_number on $RALPH_GH_VERIFIER_MODEL (timeout ${RALPH_GH_VERIFIER_TIMEOUT_MINUTES}m)"

    local rc=0
    run_claude "$workspace" "$prompt" "$output_file" "$stderr_file" "$timeout_seconds" \
        "$RALPH_GH_VERIFIER_MODEL" "$VERIFIER_SCHEMA" "" "$RALPH_GH_VERIFIER_ALLOWED_TOOLS" "dontAsk" "verifier" || rc=$?

    local so
    so=$(claude_structured_output "$output_file")

    if [[ -z "$so" ]]; then
        # The verifier itself broke (timeout, API error, no structured output).
        # Don't block work on tooling failure, but say so loudly and record it.
        log_status "ERROR" "Verifier gate inconclusive (exit $rc, no structured_output) — passing with a warning. Log: $output_file"
        [[ -s "$stderr_file" ]] && tail -10 "$stderr_file" >&2
        telemetry_record_gate "verifier" "skip" "inconclusive exit $rc" 2>/dev/null || true
        return 0
    fi
    if [[ $rc -ne 0 ]]; then
        # The verdict was written, then the CLI overran (a repo Stop hook that
        # runs the test suite, or the timeout landing during teardown). The
        # verdict is what we asked for — grade on it rather than waving the
        # sub through as inconclusive (#1132: #1134's verdict was discarded).
        log_status "WARN" "Verifier CLI exited $rc after writing its verdict — grading on the verdict"
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
    unmet=$(printf '%s' "$so" | jq -r '.criteria[] | select(.met == false) | "- \(if .unmeetable == true then "UNMEETABLE AS WRITTEN: " else "" end)\(.criterion) — \(.reason)"')
    log_status "WARN" "Verifier gate FAIL: $summary"
    telemetry_record_gate "verifier" "fail" "$summary" 2>/dev/null || true
    echo "An independent verifier read your diff and found these criteria NOT met:"
    echo ""
    echo "${unmet:-- (verifier returned FAIL without itemised criteria): $summary}"
    if printf '%s' "$so" | jq -e 'any(.criteria[]; .met == false and .unmeetable == true)' >/dev/null 2>&1; then
        echo ""
        echo "The verifier judged the criteria marked UNMEETABLE AS WRITTEN impossible to satisfy as worded. Do not reinterpret them. If you agree, propose an amendment for each in \`amendments\`, report it \`met: false\`, and return \`BLOCKED\` with \`exit_signal: true\`. If you disagree, meet it as written and cite the evidence."
    fi
    return 1
}

export -f resolve_verify_cmd run_verify_gate build_verifier_prompt run_verifier_gate
export -f verify_baseline_failures _verify_tree_snapshot _verify_remove_tree _verify_reap_stale_trees _verify_failure_ids
export -f pre_existing_failures_file record_pre_existing_failures pre_existing_failures_section
