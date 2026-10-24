#!/usr/bin/env bash

# review_panel.sh - the pre-PR review: specialist reviewers that only report,
# and a separate fixer that acts on what they found.
#
# Once every sub-issue is green, each reviewer named in RALPH_GH_REVIEWERS
# (security, code, ui by default) reads the whole branch diff in its own
# read-only session, all in parallel. Blocker and major findings go to a fresh
# fixer session on the implementation model, which fixes or disputes each one.
# The shell then runs the verify gate on the fix: a red verify gets the fixer
# one more turn, then the round's commits are reverted. Reviewers whose
# findings were fixed re-run, up to RALPH_GH_MAX_REVIEW_RUNS review rounds.
# No reviewer fixes, and no fixer grades its own fixes.
#
# What is left over (unresolved, disputed, minor, reviewers that never
# reported) lands in the PR body via review_findings_section. An unresolved
# blocker makes run_review_panel return 1; the caller opens a draft PR.
#
# Reviewer prompts: <repo>/.ralph/reviewers/<name>.md, else
# $RALPH_GH_REVIEW_PROMPT_DIR/review-<name>.md. Per-reviewer overrides:
#   RALPH_GH_REVIEW_MODEL_<NAME>   model (default RALPH_GH_REVIEW_MODEL)
#   RALPH_GH_REVIEW_PATHS_<NAME>   comma-separated globs; the reviewer runs only
#                                  when a changed file matches (empty = always)

RALPH_GH_REVIEWERS="${RALPH_GH_REVIEWERS-security,code,ui}"      # empty disables the pre-PR review
RALPH_GH_MAX_REVIEW_RUNS="${RALPH_GH_MAX_REVIEW_RUNS:-2}"         # review rounds (a fix round sits between two)
RALPH_GH_REVIEW_MODEL="${RALPH_GH_REVIEW_MODEL:-claude-sonnet-5}"
RALPH_GH_REVIEW_MODEL_SECURITY="${RALPH_GH_REVIEW_MODEL_SECURITY:-claude-opus-5-5}"
RALPH_GH_REVIEW_PATHS_UI="${RALPH_GH_REVIEW_PATHS_UI-*.tsx,*.jsx,*.vue,*.svelte,*.css,*.scss,*.html}"
RALPH_GH_REVIEW_TIMEOUT_MINUTES="${RALPH_GH_REVIEW_TIMEOUT_MINUTES:-15}"
RALPH_GH_REVIEW_ALLOWED_TOOLS="${RALPH_GH_REVIEW_ALLOWED_TOOLS:-${RALPH_GH_VERIFIER_ALLOWED_TOOLS:-Read,Grep,Glob,Bash(git diff *),Bash(git log *),Bash(git show *),Bash(git status),Bash(git ls-files *),Bash(cat *),Bash(ls *)}}"
RALPH_GH_REVIEW_PROMPT_DIR="${RALPH_GH_REVIEW_PROMPT_DIR:-${SCRIPT_DIR:-.}/prompts}"

REVIEWER_SCHEMA='{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["blocker","major","minor"]},"location":{"type":"string"},"title":{"type":"string"},"detail":{"type":"string"},"suggestion":{"type":"string"}},"required":["severity","location","title","detail"]}},"summary":{"type":"string"}},"required":["findings","summary"]}'

FIXER_SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["COMPLETE","BLOCKED"]},"findings":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"outcome":{"type":"string","enum":["fixed","disputed"]},"note":{"type":"string"}},"required":["id","outcome","note"]}},"recommendation":{"type":"string"}},"required":["status","findings","recommendation"]}'

# Upper-case a reviewer name into an env-var suffix (ui -> UI, a-b -> A_B).
_review_var_suffix() {
    printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

review_model_for() {
    local var
    var="RALPH_GH_REVIEW_MODEL_$(_review_var_suffix "$1")"
    printf '%s' "${!var:-$RALPH_GH_REVIEW_MODEL}"
}

# Echo the focus prompt file for a reviewer, or nothing when it has none.
#   $1 = workspace, $2 = reviewer name
review_prompt_file() {
    local workspace=$1
    local name=$2
    if [[ -f "$workspace/.ralph/reviewers/$name.md" ]]; then
        printf '%s' "$workspace/.ralph/reviewers/$name.md"
    elif [[ -f "$RALPH_GH_REVIEW_PROMPT_DIR/review-$name.md" ]]; then
        printf '%s' "$RALPH_GH_REVIEW_PROMPT_DIR/review-$name.md"
    fi
    return 0
}

# Return 0 when the reviewer's path globs match any changed file (or it has
# none). Globs match across directories: `*.tsx` covers apps/web/a/b.tsx.
#   $1 = reviewer name, $2 = changed files, one per line
reviewer_applies() {
    local var
    var="RALPH_GH_REVIEW_PATHS_$(_review_var_suffix "$1")"
    local globs=${!var:-}
    [[ -z "$globs" ]] && return 0

    local file pattern
    local -a patterns
    IFS=',' read -r -a patterns <<< "$globs"
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        for pattern in "${patterns[@]}"; do
            pattern=$(printf '%s' "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # shellcheck disable=SC2053  # the pattern is a glob on purpose
            [[ -n "$pattern" && "$file" == $pattern ]] && return 0
        done
    done <<< "$2"
    return 1
}

# Echo the reviewers that run against this change set, one per line.
#   $1 = workspace, $2 = changed files, one per line
select_reviewers() {
    local workspace=$1
    local changed=$2
    local name
    local -a names
    IFS=',' read -r -a names <<< "$RALPH_GH_REVIEWERS"
    for name in "${names[@]}"; do
        name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$name" ]] && continue
        if [[ -z "$(review_prompt_file "$workspace" "$name")" ]]; then
            log_status "WARN" "Reviewer '$name' has no prompt (.ralph/reviewers/$name.md or prompts/review-$name.md) — skipped"
            continue
        fi
        if ! reviewer_applies "$name" "$changed"; then
            log_status "INFO" "Reviewer '$name': no changed file matches its paths — skipped"
            continue
        fi
        printf '%s\n' "$name"
    done
}

# Build one reviewer's prompt.
#   $1 = reviewer name, $2 = focus prompt file, $3 = parent number,
#   $4 = parent title, $5 = diff file, $6 = base ref, $7 = untracked files,
#   $8 = JSON array of this reviewer's findings the fixer disputed (may be empty)
build_reviewer_prompt() {
    local name=$1
    local focus_file=$2
    local parent_number=$3
    local parent_title=$4
    local diff_file=$5
    local base_ref=$6
    local untracked=$7
    local disputed=${8:-}

    local disputed_block=""
    if [[ -n "$disputed" && "$disputed" != "[]" ]]; then
        disputed_block="
## Disputed in an earlier round

The fixer disputed these findings of yours and gave its reasons. Do not raise
them again unless you can show the reason is wrong; if you do, cite the
evidence that refutes it.

$(printf '%s' "$disputed" | jq -r '.[] | "- [\(.severity)] `\(.location)` — \(.title)\n  Fixer: \(.note // "")"')
"
    fi

    cat <<PROMPT
## Role: ${name} reviewer

You are one of several independent reviewers checking the branch for parent
issue #${parent_number} (${parent_title}) before a PR is opened. You did not
write this code and you will not fix it: a separate session acts on your
findings. You are read-only: do not edit files, do not run builds or tests,
do not commit.

## Your focus

$(cat "$focus_file")

## What changed

The branch's full diff against its base (\`git diff ${base_ref}\`) is saved at:

    ${diff_file}

Read it first. Open any file you need for context. You may also run
\`git diff ${base_ref} -- <path>\`, \`git log\`, and \`git show\`.
$( [[ -n "$untracked" ]] && printf '\nNew untracked files (not in the diff, read them directly):\n\n%s\n' "$(printf '%s\n' "$untracked" | sed 's/^/    /')" )
${disputed_block}
## How to report

- Only problems this branch introduces or makes reachable. Not pre-existing
  code the diff does not touch, and not problems outside your focus — other
  reviewers cover those.
- Every finding needs \`location\` (path:line) and a concrete failure in
  \`detail\`: which input or state leads to which wrong outcome.
- \`severity\`: \`blocker\` = must not merge (exploitable vulnerability, data
  loss, a broken core flow); \`major\` = a real defect to fix before merge;
  \`minor\` = worth a note, not worth a fix loop.
- No style or naming nits. If you are not confident a finding is real, leave
  it out. An empty \`findings\` list is a good result for a clean diff.
- \`suggestion\`: the smallest fix you would make, when it is not obvious.
- \`summary\`: one or two lines for a human reviewer.

Deliver the result through the structured output schema. Do not end with
prose only.
PROMPT
}

# Build the fixer's prompt from the actionable findings.
#   $1 = workspace, $2 = parent number, $3 = base ref, $4 = findings JSON array
build_fixer_prompt() {
    local workspace=$1
    local parent_number=$2
    local base_ref=$3
    local findings=$4

    if [[ -f "$workspace/.ralph/AGENT.md" ]]; then
        printf '## Build & Run Instructions\n\n%s\n\n' "$(cat "$workspace/.ralph/AGENT.md")"
    fi

    cat <<PROMPT
## Task: address pre-PR review findings for parent #${parent_number}

Independent reviewers read this branch's diff (\`git diff ${base_ref}\`) and
reported the findings below. Handle every one, by id:

- **fixed** — make the smallest change that removes the problem. When the
  finding is about behaviour, add or adjust a test that would have caught it.
- **disputed** — the finding is wrong: the code already handles it, its
  premise is false, or the fix would contradict the issue's acceptance
  criteria. Put the evidence (path:line) in \`note\`. Do not dispute a finding
  only because the fix is hard.

Stay inside the findings: no unrelated refactors.

## Findings

$(printf '%s' "$findings" | jq -r '.[] | "- **\(.id)** [\(.severity)] \(.reviewer) — `\(.location)` — \(.title)\n  \(.detail)\(if (.suggestion // "") != "" then "\n  Suggested: \(.suggestion)" else "" end)"')

## Rules
1. Commit your fixes with conventional commit messages (fix: ..., test: ...)
2. Do NOT close issues or open PRs - that is handled externally
3. Do NOT modify .ralph-gh/ or .ralph/ state files
4. The shell runs the repo's verify command after you finish; leave it green

## Final report (REQUIRED)

Deliver the structured output the CLI enforces: \`status\` (COMPLETE, or BLOCKED
if you could not work at all), \`findings\` (one entry per id above, with
\`outcome\` fixed or disputed and a one-line \`note\`), \`recommendation\` (one
line for the human reviewer).
PROMPT
}

# Run the given reviewers in parallel against the branch diff. Each writes
# <round_dir>/<name>.json (its findings, ids assigned) or nothing when it did
# not report.
#   $1 = workspace, $2 = parent number, $3 = base ref, $4 = round number,
#   $5 = reviewers (one per line), $6 = round dir,
#   $7 = disputed findings JSON array across all reviewers
run_reviewers() {
    local workspace=$1
    local parent_number=$2
    local base_ref=$3
    local round=$4
    local reviewers=$5
    local round_dir=$6
    local disputed_all=${7:-[]}

    mkdir -p "$round_dir"
    local diff_file="$round_dir/diff.patch"
    git -C "$workspace" diff "$base_ref" > "$diff_file" 2>/dev/null || true
    local untracked
    untracked=$(git -C "$workspace" ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.ralph-gh/' || true)

    local parent_title
    parent_title=$(get_issue_title "$RALPH_GH_REPO" "$parent_number" 2>/dev/null) || parent_title=""

    local timeout_seconds=$((RALPH_GH_REVIEW_TIMEOUT_MINUTES * 60))
    local name
    local -a pids=()
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local model disputed prompt
        model=$(review_model_for "$name")
        disputed=$(printf '%s' "$disputed_all" | jq -c --arg r "$name" '[.[] | select(.reviewer == $r)]')
        prompt=$(build_reviewer_prompt "$name" "$(review_prompt_file "$workspace" "$name")" \
            "$parent_number" "$parent_title" "$diff_file" "$base_ref" "$untracked" "$disputed")
        log_status "INFO" "Reviewer '$name' (round $round) on $model"
        (
            # Siblings share the workspace: a reviewer that reaped on exit would
            # kill the others mid-review. The panel reaps once after all exit.
            export RALPH_GH_REAP_ORPHANS=0
            run_claude "$workspace" "$prompt" "$round_dir/$name.log" "$round_dir/$name.stderr.log" \
                "$timeout_seconds" "$model" "$REVIEWER_SCHEMA" "" "$RALPH_GH_REVIEW_ALLOWED_TOOLS" \
                "dontAsk" "review:$name" || true
        ) &
        pids+=($!)
    done <<< "$reviewers"
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done
    reap_workspace_orphans "$workspace"

    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local so
        so=$(claude_structured_output "$round_dir/$name.log")
        if [[ -z "$so" ]] || ! printf '%s' "$so" | jq -e '.findings | type == "array"' >/dev/null 2>&1; then
            log_status "ERROR" "Reviewer '$name' did not report (timeout, API error, or no structured output) — log: $round_dir/$name.log"
            telemetry_record_gate "review:$name" "skip" "no report, round $round" 2>/dev/null || true
            continue
        fi
        printf '%s' "$so" | jq -c --arg r "$name" --arg round "$round" \
            '[.findings | to_entries[] | .value + {reviewer: $r, id: "\($r | ascii_upcase)-\($round).\(.key + 1)"}]' \
            > "$round_dir/$name.json"
        local actionable
        actionable=$(jq '[.[] | select(.severity != "minor")] | length' "$round_dir/$name.json")
        if [[ "$actionable" -gt 0 ]]; then
            log_status "WARN" "Reviewer '$name': $actionable blocker/major finding(s) — $(printf '%s' "$so" | jq -r '.summary // ""')"
            telemetry_record_gate "review:$name" "fail" "round $round: $actionable actionable" 2>/dev/null || true
        else
            log_status "SUCCESS" "Reviewer '$name' clean — $(printf '%s' "$so" | jq -r '.summary // ""')"
            telemetry_record_gate "review:$name" "pass" "round $round" 2>/dev/null || true
        fi
    done <<< "$reviewers"
}

# Commit whatever the fixer left uncommitted.
_review_commit_fixes() {
    local workspace=$1
    local parent_number=$2
    if [[ -n "$(git -C "$workspace" status --porcelain -- . ':!.ralph-gh' 2>/dev/null)" ]]; then
        git -C "$workspace" add -A -- ':!.ralph-gh' 2>/dev/null || true
        git -C "$workspace" commit -q -m "fix(ralph): address review findings for #$parent_number" 2>/dev/null || true
    fi
}

# One fix round: the fixer works the findings, the shell verifies, a red verify
# gets one more turn, and a verify still red reverts the round.
#   $1 = workspace, $2 = parent number, $3 = base ref, $4 = actionable findings
#   JSON, $5 = round dir
# Echoes the fixer's per-finding report (JSON array; [] when it gave none).
# Returns 0 when the tree is green after the round, 1 when it was reverted.
run_fix_round() {
    local workspace=$1
    local parent_number=$2
    local base_ref=$3
    local findings=$4
    local round_dir=$5

    local pre_fix
    pre_fix=$(git -C "$workspace" rev-parse HEAD)
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    local count
    count=$(printf '%s' "$findings" | jq 'length')
    log_status "INFO" "Fixer: $count finding(s) on ${RALPH_GH_MODEL:-default model}"

    local prompt
    prompt=$(build_fixer_prompt "$workspace" "$parent_number" "$base_ref" "$findings")
    run_claude "$workspace" "$prompt" "$round_dir/fixer.log" "$round_dir/fixer.stderr.log" \
        "$timeout_seconds" "${RALPH_GH_MODEL:-}" "$FIXER_SCHEMA" "" "$RALPH_GH_ALLOWED_TOOLS" "" "review-fix" || true
    local session=$RALPH_LAST_SESSION_ID
    _review_commit_fixes "$workspace" "$parent_number"

    local report
    report=$(claude_structured_output "$round_dir/fixer.log" | jq -c '.findings // []' 2>/dev/null)
    [[ -z "$report" ]] && report='[]'

    local verify_failures="" attempt
    for attempt in 1 2; do
        if verify_failures=$(run_verify_gate "$workspace" "$pre_fix" "$parent_number"); then
            printf '%s' "$report"
            return 0
        fi
        [[ $attempt -eq 2 ]] && break
        log_status "WARN" "Verify gate red after review fixes — one more fixer turn"
        run_claude "$workspace" "## PRIOR ATTEMPT FAILED — the verify gate is red after your review fixes

${verify_failures}

Make it green without undoing a review fix unless that fix is the cause. Then re-report every finding id." \
            "$round_dir/fixer_retry.log" "$round_dir/fixer_retry.stderr.log" \
            "$timeout_seconds" "${RALPH_GH_MODEL:-}" "$FIXER_SCHEMA" "$session" "$RALPH_GH_ALLOWED_TOOLS" "" "review-fix" || true
        _review_commit_fixes "$workspace" "$parent_number"
        local retry_report
        retry_report=$(claude_structured_output "$round_dir/fixer_retry.log" | jq -c '.findings // empty' 2>/dev/null)
        [[ -n "$retry_report" ]] && report=$retry_report
    done

    # Revert rather than reset: the fixer may have pushed, and the branch must
    # stay a fast-forward of what is on origin.
    log_status "ERROR" "Verify gate still red after review fixes — reverting the fix round"
    telemetry_record_gate "review-fix" "fail" "verify red, reverted" 2>/dev/null || true
    if [[ "$(git -C "$workspace" rev-parse HEAD)" != "$pre_fix" ]]; then
        if ! git -C "$workspace" revert --no-edit "$pre_fix..HEAD" >/dev/null 2>&1; then
            git -C "$workspace" revert --abort >/dev/null 2>&1 || true
            log_status "ERROR" "Revert of the fix round failed; the branch keeps the red fixes"
        fi
    fi
    printf '%s' "$report"
    return 1
}

# The state file a parent's review outcome is written to.
review_findings_file() {
    printf '%s' "${RALPH_GH_STATE_DIR:-.ralph-gh}/review_findings_${1}.json"
}

# Run the whole pre-PR review for a parent.
#   $1 = workspace, $2 = main branch, $3 = parent number
# Writes review_findings_file: {unresolved, disputed, minor, missing}.
# Returns 1 when a blocker is left unresolved, else 0.
run_review_panel() {
    local workspace=$1
    local main_branch=$2
    local parent_number=$3

    local out_file
    out_file=$(review_findings_file "$parent_number")
    rm -f "$out_file"

    if [[ -z "$RALPH_GH_REVIEWERS" ]]; then
        log_status "INFO" "Pre-PR review disabled (RALPH_GH_REVIEWERS is empty)"
        return 0
    fi

    local base_ref
    base_ref=$(git -C "$workspace" merge-base HEAD "origin/$main_branch" 2>/dev/null) \
        || base_ref=$(git -C "$workspace" merge-base HEAD "$main_branch" 2>/dev/null) \
        || { log_status "WARN" "Pre-PR review: no merge base with $main_branch — skipped"; return 0; }

    local changed
    changed=$(git -C "$workspace" diff --name-only "$base_ref" 2>/dev/null)
    local reviewers
    reviewers=$(select_reviewers "$workspace" "$changed")

    local review_dir
    review_dir="${RALPH_GH_STATE_DIR:-$workspace/.ralph-gh}/review/${parent_number}_$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$review_dir"

    # latest: each source's most recent findings. A source that is not re-run
    # keeps only its minors — its actionable findings were fixed or disputed.
    local latest='{}' disputed='[]' missing='[]'

    local e2e_failures=""
    if ! e2e_failures=$(run_e2e_pre_check "$workspace" 2>&1 >/dev/null); then
        latest=$(jq -nc --arg d "$e2e_failures" '{e2e: [{id: "E2E-1.1", reviewer: "e2e", severity: "major",
            location: "pnpm --filter api test:e2e", title: "E2E suite is red on this branch",
            detail: ("Diagnose and fix. Run `pnpm --filter api test:e2e` after your fixes.\n\n" + $d)}]}')
    fi

    if [[ -z "$reviewers" && "$latest" == "{}" ]]; then
        log_status "INFO" "Pre-PR review: no reviewer applies to this change set"
        return 0
    fi

    log_status "INFO" "Pre-PR review: $(printf '%s' "$reviewers" | paste -sd, -) (max $RALPH_GH_MAX_REVIEW_RUNS round(s))"

    local round=0 to_run=$reviewers reverted=false
    while [[ $round -lt $RALPH_GH_MAX_REVIEW_RUNS ]]; do
        round=$((round + 1))
        local round_dir="$review_dir/round_$round"
        mkdir -p "$round_dir"
        if [[ -n "$to_run" ]]; then
            run_reviewers "$workspace" "$parent_number" "$base_ref" "$round" "$to_run" "$round_dir" "$disputed"
        fi

        local name
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if [[ -f "$round_dir/$name.json" ]]; then
                latest=$(jq -c --arg r "$name" --slurpfile f "$round_dir/$name.json" '.[$r] = $f[0]' <<< "$latest")
                missing=$(jq -c --arg r "$name" 'map(select(. != $r))' <<< "$missing")
            else
                missing=$(jq -c --arg r "$name" 'map(select(. != $r)) + [$r]' <<< "$missing")
            fi
        done <<< "$to_run"

        local actionable
        actionable=$(jq -c '[.[][] | select(.severity != "minor")]' <<< "$latest")
        if [[ "$actionable" == "[]" ]]; then
            log_status "SUCCESS" "Pre-PR review round $round: no blocker/major findings"
            break
        fi
        if [[ $round -ge $RALPH_GH_MAX_REVIEW_RUNS ]]; then
            log_status "WARN" "Pre-PR review: $(jq length <<< "$actionable") finding(s) still open after $round round(s)"
            break
        fi

        local fix_report
        if ! fix_report=$(run_fix_round "$workspace" "$parent_number" "$base_ref" "$actionable" "$round_dir"); then
            reverted=true
        fi
        [[ -z "$fix_report" ]] && fix_report='[]'
        if [[ "$reverted" == "true" ]]; then
            break
        fi

        # A finding the fixer disputed is not re-sent; one it fixed or did not
        # mention is checked by re-running its reviewer.
        disputed=$(jq -c --argjson rep "$fix_report" --argjson prev "$disputed" '
            ($rep | map(select(.outcome == "disputed")) | map({key: .id, value: .note}) | from_entries) as $d
            | $prev + [.[] | select($d[.id] != null) | . + {note: $d[.id]}]' <<< "$actionable")
        to_run=$(jq -r --argjson rep "$fix_report" '
            ($rep | map(select(.outcome == "disputed") | .id)) as $disp
            | [.[] | select((.id | IN($disp[])) | not) | .reviewer] | unique | .[]' <<< "$actionable")
        # Reviewers that did not report get another chance alongside the
        # re-runs; e2e is not a reviewer and never re-runs.
        to_run=$({ printf '%s\n' "$to_run"; jq -r '.[]' <<< "$missing"; } \
            | grep -Fx -f <(printf '%s\n' "$reviewers" | sed '/^$/d') | sort -u || true)
        latest=$(jq -c --argjson rerun "$(printf '%s\n' "$to_run" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
            with_entries(if (.key | IN($rerun[])) then . else .value |= map(select(.severity == "minor")) end)' <<< "$latest")
    done

    local unresolved
    unresolved=$(jq -c '[.[][] | select(.severity != "minor")]' <<< "$latest")
    jq -n --argjson u "$unresolved" --argjson d "$disputed" --argjson m "$missing" \
        --argjson minor "$(jq -c '[.[][] | select(.severity == "minor")]' <<< "$latest")" \
        --argjson reverted "$reverted" \
        '{unresolved: $u, disputed: $d, minor: $minor, missing: $m, reverted: $reverted}' > "$out_file"

    if jq -e 'any(.[]; .severity == "blocker")' <<< "$unresolved" >/dev/null; then
        log_status "ERROR" "Pre-PR review left $(jq '[.[] | select(.severity == "blocker")] | length' <<< "$unresolved") blocker(s) unresolved"
        return 1
    fi
    return 0
}

# One-line reason for the draft PR when blockers are left.
review_blocker_reason() {
    local f
    f=$(review_findings_file "$1")
    [[ -s "$f" ]] || return 0
    jq -r '"The pre-PR review left blocker finding(s) unresolved: "
        + ([.unresolved[] | select(.severity == "blocker") | "\(.reviewer): \(.title) (`\(.location)`)"] | join("; "))
        + (if .reverted then ". The last fix round broke the verify gate and was reverted." else "" end)' "$f"
}

# PR-body section listing what the review left behind; empty when nothing.
review_findings_section() {
    local f
    f=$(review_findings_file "$1")
    [[ -s "$f" ]] || return 0
    jq -r '
        def line: "- [\(.severity)] \(.reviewer) — `\(.location)` — \(.title)";
        [ (if (.unresolved | length) > 0 then "\n### Review findings left open\n\n" + (.unresolved | map(line + "\n  " + (.detail | split("\n")[0])) | join("\n")) else empty end),
          (if .reverted then "\n_The last review fix round turned the verify gate red and was reverted._" else empty end),
          (if (.disputed | length) > 0 then "\n### Review findings the fixer disputed\n\n" + (.disputed | map(line + "\n  Fixer: " + .note) | join("\n")) else empty end),
          (if (.minor | length) > 0 then "\n### Minor review notes (not fixed)\n\n" + (.minor | map(line) | join("\n")) else empty end),
          (if (.missing | length) > 0 then "\n### Reviewers that did not report\n\n" + (.missing | map("- " + .) | join("\n")) else empty end)
        ] | join("\n")' "$f"
}

export -f _review_var_suffix review_model_for review_prompt_file reviewer_applies select_reviewers
export -f build_reviewer_prompt build_fixer_prompt run_reviewers _review_commit_fixes run_fix_round
export -f review_findings_file run_review_panel review_blocker_reason review_findings_section
