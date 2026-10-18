#!/usr/bin/env bash

# qa_runner.sh - QA mode: execute a test-plan issue against a running stack,
# publish the evidence, and file one bug per failure.
#
# A QA plan carries both the trigger label and RALPH_QA_LABEL. It is not
# implementation work: there is no TDD, no verify gate, no verifier and no PR.
# The model executes scenarios and reports one structured result per scenario.
# The shell owns everything outward-facing, so a plan's proof never depends on
# the model remembering to post it:
#   - evidence is pushed to an orphan branch (gh cannot attach images)
#   - bugs are filed with fixed labels, deduplicated against open qa bugs
#   - scenario checkboxes are ticked from the latest run's results
#   - the plan closes only when every scenario passed (otherwise it stays open
#     with a "Blocked by" list and loses the trigger label until a human re-adds it)
#
# The gate is "every scenario executed with evidence", never "every scenario
# passed": a failing scenario is a finding, and re-running the model cannot
# fix product code.
#
# Plan body contract (one line per scenario, parsed from anywhere in the body):
#   - [ ] **QA-05.01** <behaviour>
# Parent link (first line): Parent QA #<n>

RALPH_QA_LABEL="${RALPH_QA_LABEL:-qa}"
RALPH_QA_SKIP_LABELS="${RALPH_QA_SKIP_LABELS:-hitl}"            # Comma-separated; a plan carrying any is never run
RALPH_QA_BUG_LABELS="${RALPH_QA_BUG_LABELS:-bug,qa-found}"       # Plus sev:<severity> per bug
RALPH_QA_STACK_CMD="${RALPH_QA_STACK_CMD:-scripts/qa-stack.sh}"  # Relative to the stack checkout
RALPH_QA_SEED="${RALPH_QA_SEED:-qa}"
RALPH_QA_ENV_FILE="${RALPH_QA_ENV_FILE:-}"                       # Secrets for the stack (Stripe test key), outside any repo
RALPH_QA_EVIDENCE_BRANCH="${RALPH_QA_EVIDENCE_BRANCH:-qa-evidence}"
RALPH_QA_EVIDENCE_MAX_MB="${RALPH_QA_EVIDENCE_MAX_MB:-25}"
RALPH_QA_MAX_LOOPS="${RALPH_QA_MAX_LOOPS:-4}"
RALPH_QA_TIMEOUT_MINUTES="${RALPH_QA_TIMEOUT_MINUTES:-}"         # Empty → CLAUDE_TIMEOUT_MINUTES
RALPH_QA_SYSTEM_PROMPT_FILE="${RALPH_QA_SYSTEM_PROMPT_FILE:-.ralph/QA_PROMPT.md}"
RALPH_QA_SMOKE_PLAN_ID="${RALPH_QA_SMOKE_PLAN_ID:-QA-00}"        # A non-green smoke plan stops the run
RALPH_QA_EXTRA_DENY_RULES="${RALPH_QA_EXTRA_DENY_RULES:-Bash(gh issue create*),Bash(gh issue comment*),Bash(gh pr *),Bash(git commit*),Bash(git push*),Bash(stripe * --live*)}"

QA_SCENARIO_RE='^[[:space:]]*- \[[ xX]\] \*\*(QA-[A-Z]?[0-9]+[a-z]?\.[0-9]+)\*\*[[:space:]]*(.*)$'

QA_SCHEMA='{"type":"object","properties":{"status":{"type":"string","enum":["COMPLETE","IN_PROGRESS","BLOCKED"]},"environment_issue":{"type":"string"},"recommendation":{"type":"string"},"scenarios":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"result":{"type":"string","enum":["PASS","FAIL","BLOCKED"]},"summary":{"type":"string"},"evidence":{"type":"array","items":{"type":"string"}},"blocked_by":{"type":"string"},"bug":{"type":"object","properties":{"title":{"type":"string"},"severity":{"type":"string","enum":["blocker","major","minor"]},"expected":{"type":"string"},"actual":{"type":"string"},"repro":{"type":"string"},"duplicate_of":{"type":"integer"}},"required":["title","severity","expected","actual","repro"]}},"required":["id","result","summary","evidence"]}}},"required":["status","scenarios","recommendation"]}'

# =============================================================================
# PURE HELPERS (unit-tested in tests/test_qa_runner.sh)
# =============================================================================

# Scenarios in a plan body, one "id<TAB>title" per line, in body order.
qa_parse_scenarios() {
    local body=$1 line
    while IFS= read -r line; do
        line=${line%$'\r'}
        if [[ "$line" =~ $QA_SCENARIO_RE ]]; then
            printf '%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
    done <<< "$body"
}

# "QA-05" from a title like "QA-05: Public runtime" (empty when absent).
qa_plan_id() {
    local title=$1
    [[ "$title" =~ (QA-[A-Z]?[0-9]+[a-z]?) ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}

# Parent issue number from the "Parent QA #<n>" line (empty when absent).
qa_parent_number() {
    local body=$1
    [[ "$body" =~ Parent\ QA\ \#([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}

# Sort key so plans run in programme order: QA-00 < QA-05 < QA-18a < QA-18b,
# lettered tracks (QA-H1) last. Unnumbered titles sort after everything.
qa_sort_key() {
    local title=$1
    if [[ "$title" =~ QA-([0-9]+)([a-z]?) ]]; then
        printf '%04d%s' "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]:-0}"
    elif [[ "$title" =~ QA-([A-Z])([0-9]+) ]]; then
        printf '8%s%03d' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))"
    else
        printf '9999z'
    fi
}

# Merge one turn's structured scenarios into the accumulated results object
# ({"QA-05.01": {...}}). A later turn's report for an id replaces the earlier
# one, so a resumed session can re-run a scenario it got wrong.
#   $1 = accumulated results JSON object, $2 = structured_output JSON
qa_merge_results() {
    local acc=${1:-'{}'} so=${2:-'{}'}
    jq -nc --argjson acc "$acc" --argjson so "$so" \
        '$acc + ([$so.scenarios // [] | .[] | select(.id != null) | {key: .id, value: .}] | from_entries)'
}

# The QA gate. Echoes one line per problem and returns 1 when any exist.
#   $1 = scenarios TSV (qa_parse_scenarios), $2 = results JSON, $3 = evidence dir
qa_gate() {
    local scenarios=$1 results=$2 evidence_dir=$3
    local problems="" id title r ev result
    while IFS=$'\t' read -r id title; do
        [[ -z "$id" ]] && continue
        r=$(jq -c --arg id "$id" '.[$id] // empty' <<< "$results")
        if [[ -z "$r" ]]; then
            problems+="- $id: not executed"$'\n'
            continue
        fi
        result=$(jq -r '.result' <<< "$r")
        case "$result" in
            PASS|FAIL)
                local found=0
                while IFS= read -r ev; do
                    [[ -z "$ev" ]] && continue
                    [[ -f "$evidence_dir/$ev" ]] && found=1
                done < <(jq -r '.evidence[]?' <<< "$r")
                if [[ $found -eq 0 ]]; then
                    problems+="- $id: $result reported without evidence — none of its evidence paths exists under \$QA_EVIDENCE_DIR"$'\n'
                fi
                if [[ "$result" == "FAIL" ]] && ! jq -e '.bug.title and .bug.severity and .bug.expected and .bug.actual and .bug.repro' <<< "$r" >/dev/null; then
                    problems+="- $id: FAIL needs a complete bug (title, severity, expected, actual, repro)"$'\n'
                fi
                ;;
            BLOCKED)
                if ! jq -e '(.blocked_by // "") | length > 0' <<< "$r" >/dev/null; then
                    problems+="- $id: BLOCKED needs blocked_by (the failing scenario id or #issue)"$'\n'
                fi
                ;;
            *)
                problems+="- $id: unknown result '$result'"$'\n'
                ;;
        esac
    done <<< "$scenarios"

    if [[ -n "$problems" ]]; then
        printf '%s' "$problems"
        return 1
    fi
    return 0
}

# Count of scenarios per result: "PASS FAIL BLOCKED NOT_RUN".
qa_tally() {
    local scenarios=$1 results=$2
    local pass=0 fail=0 blocked=0 not_run=0 id title result
    while IFS=$'\t' read -r id title; do
        [[ -z "$id" ]] && continue
        result=$(jq -r --arg id "$id" '.[$id].result // "NOT_RUN"' <<< "$results")
        case "$result" in
            PASS) pass=$((pass + 1)) ;;
            FAIL) fail=$((fail + 1)) ;;
            BLOCKED) blocked=$((blocked + 1)) ;;
            *) not_run=$((not_run + 1)) ;;
        esac
    done <<< "$scenarios"
    printf '%s %s %s %s' "$pass" "$fail" "$blocked" "$not_run"
}

# Tick each scenario box from this run (PASS → [x], everything else → [ ]),
# and replace the "## Blocked by" section with the open bug list (removed when
# the list is empty). Every other line is left byte-for-byte.
#   $1 = body, $2 = results JSON, $3 = blocked-by markdown bullets (may be empty)
qa_rewrite_body() {
    local body=$1 results=$2 blocked_md=$3
    local out="" line id result in_blocked=0
    while IFS= read -r line; do
        if [[ "$line" == "## Blocked by"* ]]; then
            in_blocked=1
            continue
        fi
        if [[ $in_blocked -eq 1 ]]; then
            [[ "$line" == "## "* ]] || continue
            in_blocked=0
        fi
        if [[ "$line" =~ $QA_SCENARIO_RE ]]; then
            id=${BASH_REMATCH[1]}
            result=$(jq -r --arg id "$id" '.[$id].result // ""' <<< "$results")
            if [[ "$result" == "PASS" ]]; then
                line=$(printf '%s' "$line" | sed -E 's/- \[[ xX]\]/- [x]/')
            else
                line=$(printf '%s' "$line" | sed -E 's/- \[[ xX]\]/- [ ]/')
            fi
        fi
        out+="$line"$'\n'
    done <<< "$body"
    out=${out%$'\n'}
    if [[ -n "$blocked_md" ]]; then
        out=${out%$'\n'}
        out+=$'\n\n## Blocked by\n\n'"$blocked_md"
    fi
    printf '%s' "$out"
}

# Blob URL for a published evidence file; images get ?raw=true so they render
# inline in issue markdown.
qa_evidence_url() {
    local repo=$1 commit=$2 path=$3
    local url="https://github.com/$repo/blob/$commit/$path"
    case "${path,,}" in
        *.png|*.jpg|*.jpeg|*.gif|*.webp) url+="?raw=true" ;;
    esac
    printf '%s' "$url"
}

# Markdown for one scenario's evidence: images inline, everything else linked.
#   $1 = repo, $2 = evidence commit (empty → paths only), $3 = base path, $4 = result JSON
qa_render_evidence() {
    local repo=$1 commit=$2 base=$3 r=$4 ev url out=""
    while IFS= read -r ev; do
        [[ -z "$ev" ]] && continue
        if [[ -z "$commit" ]]; then
            out+="- \`$ev\` (not published)"$'\n'
            continue
        fi
        url=$(qa_evidence_url "$repo" "$commit" "$base/$ev")
        case "${ev,,}" in
            *.png|*.jpg|*.jpeg|*.gif|*.webp) out+="![${ev}](${url})"$'\n' ;;
            *) out+="- [${ev}](${url})"$'\n' ;;
        esac
    done < <(jq -r '.evidence[]?' <<< "$r")
    printf '%s' "$out"
}

# The proof comment for one plan run.
#   $1 repo, $2 plan number, $3 plan id, $4 run id, $5 sha under test,
#   $6 scenarios TSV, $7 results JSON, $8 evidence commit, $9 evidence base,
#   $10 bug map JSON ({"QA-05.03": 1234}), $11 note (may be empty)
qa_render_proof() {
    local repo=$1 plan=$2 plan_id=$3 run_id=$4 sha=$5 scenarios=$6 results=$7
    local commit=$8 base=$9 bugs=${10:-'{}'} note=${11:-}
    local tally pass fail blocked not_run
    tally=$(qa_tally "$scenarios" "$results")
    read -r pass fail blocked not_run <<< "$tally"

    local out="## QA run \`$run_id\` — $plan_id"$'\n\n'
    out+="Tested \`${sha:0:10}\` · **$pass PASS** · **$fail FAIL** · **$blocked BLOCKED**"
    [[ "$not_run" -gt 0 ]] && out+=" · **$not_run NOT RUN**"
    out+=$'\n\n'
    [[ -n "$note" ]] && out+="> $note"$'\n\n'

    out+=$'| Scenario | Result | Bug |\n|---|---|---|\n'
    local id title r result icon bug
    while IFS=$'\t' read -r id title; do
        [[ -z "$id" ]] && continue
        r=$(jq -c --arg id "$id" '.[$id] // {}' <<< "$results")
        result=$(jq -r '.result // "NOT_RUN"' <<< "$r")
        case "$result" in
            PASS) icon="✅ PASS" ;;
            FAIL) icon="❌ FAIL" ;;
            BLOCKED) icon="⛔ BLOCKED by $(jq -r '.blocked_by' <<< "$r")" ;;
            *) icon="⚪ NOT RUN" ;;
        esac
        bug=$(jq -r --arg id "$id" '.[$id] // empty | "#\(.)"' <<< "$bugs")
        out+="| **$id** ${title//|/\\|} | $icon | ${bug:-—} |"$'\n'
    done <<< "$scenarios"
    out+=$'\n'

    while IFS=$'\t' read -r id title; do
        [[ -z "$id" ]] && continue
        r=$(jq -c --arg id "$id" '.[$id] // empty' <<< "$results")
        [[ -z "$r" ]] && continue
        result=$(jq -r '.result' <<< "$r")
        out+="<details><summary><b>$id</b> $result — $(jq -r '.summary' <<< "$r" | tr '\n' ' ')</summary>"$'\n\n'
        out+=$(qa_render_evidence "$repo" "$commit" "$base" "$r")
        out+=$'\n\n</details>\n'
    done <<< "$scenarios"

    # GitHub refuses comments over 65,536 characters; the table above the
    # details is the verdict, so it is what must survive.
    if [[ ${#out} -gt 64000 ]]; then
        out="${out:0:63000}"$'\n\n</details>\n\n'"_Evidence list truncated at GitHub's comment limit. Everything is on the \`$RALPH_QA_EVIDENCE_BRANCH\` branch under \`$base/\`._"
    fi
    printf '%s' "$out"
}

# Body for a filed bug.
#   $1 repo, $2 plan number, $3 scenario id, $4 scenario title, $5 run id,
#   $6 sha, $7 result JSON, $8 evidence commit, $9 evidence base
qa_render_bug() {
    local repo=$1 plan=$2 id=$3 title=$4 run_id=$5 sha=$6 r=$7 commit=$8 base=$9
    local out="Found by #$plan · **$id** $title · QA run \`$run_id\` on \`${sha:0:10}\`"$'\n\n'
    out+="**Severity:** $(jq -r '.bug.severity' <<< "$r")"$'\n\n'
    out+=$'### Expected\n\n'"$(jq -r '.bug.expected' <<< "$r")"$'\n\n'
    out+=$'### Actual\n\n'"$(jq -r '.bug.actual' <<< "$r")"$'\n\n'
    out+=$'### Repro\n\n'"$(jq -r '.bug.repro' <<< "$r")"$'\n\n'
    out+=$'### Evidence\n\n'"$(qa_render_evidence "$repo" "$commit" "$base" "$r")"$'\n\n'
    out+="Re-test: re-add the \`${RALPH_GH_LABEL:-ralph}\` label to #$plan once this is fixed; the whole plan re-runs."
    printf '%s' "$out"
}

# True when an issue's labels JSON array (["a","b"]) holds any of a
# comma-separated label list.
qa_labels_hit() {
    local labels_json=$1 wanted=$2
    # GitHub label names are case-insensitive: `--label qa` matches "QA".
    jq -e --arg w "$wanted" '($w | ascii_downcase | split(",") | map(select(length > 0))) as $ws | any(.[]; ascii_downcase as $l | $ws | index($l))' \
        <<< "$labels_json" >/dev/null 2>&1
}

# =============================================================================
# PROMPT
# =============================================================================

qa_build_prompt() {
    local plan=$1 title=$2 body=$3 evidence_dir=$4 retry_context=${5:-}
    local prompt=""
    if [[ -n "$retry_context" ]]; then
        prompt+=$'## PRIOR TURN INCOMPLETE — RESOLVE THIS FIRST\n\n'"$retry_context"$'\n\n'
    fi
    prompt+="## QA plan: #${plan} - ${title}"$'\n\n'"$body"$'\n\n'
    prompt+=$(cat <<RULES
## Rules (QA mode)

You are executing a QA test plan, not implementing anything.

1. **Execute every scenario under \`## Scenarios\`** against the running stack described in your system prompt. The stack is already up and was reset with seed \`$RALPH_QA_SEED\` before this plan. Restart or reset it only through \`\$QA_STACK_CMD\` (\`$QA_STACK_CMD_ABS\`).
2. **Never change product code, config or tests in this checkout.** Write throwaway scripts (Playwright, curl, k6) under \`.qa/scripts/\` only. Nothing you write is committed.
3. **Save evidence for every PASS and FAIL** under \`\$QA_EVIDENCE_DIR\` (\`$evidence_dir\`), in a folder named after the scenario id (e.g. \`QA-05.01/final.png\`). Report the evidence paths relative to \`\$QA_EVIDENCE_DIR\`. The shell refuses a PASS or FAIL whose evidence file does not exist.
4. **A FAIL is a finding, not a task.** Do not try to fix it. Report it with a complete \`bug\`. Before you write one, search the open bugs with \`gh issue list --label qa-found --state open --search "<keywords>"\`. If one already covers it, set \`bug.duplicate_of\` to its number. Severity: \`blocker\` means a launch journey is broken or there is a security or data-loss issue. \`major\` means a feature is wrong with a workaround, or a wrong charge, email or permission. \`minor\` means cosmetic, copy, or an edge case with low impact.
5. **BLOCKED** means the scenario cannot run because another scenario in this plan failed, or an open bug blocks it. Set \`blocked_by\` to that scenario id or \`#issue\`, and file no bug of your own for it.
6. **Do not file issues, comment, commit or push.** The shell publishes your evidence and files your bugs from the structured report.
7. If the **stack itself** is broken (a service won't come up, or the seed failed) and \`\$QA_STACK_CMD reset\` does not fix it, stop: return \`status: BLOCKED\` with \`environment_issue\` describing it. That is the harness failing, not the product.
8. Long plans may take several turns. Every turn, report **all** scenarios you have results for so far (results are merged by id). Return \`status: COMPLETE\` once every scenario has a result.

## Final report (REQUIRED)

Your final action must be the structured output the CLI enforces: one \`scenarios\` entry per scenario id, with \`result\`, a one-line \`summary\` of what you observed, \`evidence\` paths, \`blocked_by\` for BLOCKED, and \`bug\` for FAIL.
RULES
)
    printf '%s' "$prompt"
}

# =============================================================================
# SIDE EFFECTS
# =============================================================================

# The stack checkout's paths. Must run in the caller's shell, not inside
# $(qa_stack_up), or the reset and the agent prompt never see them.
qa_stack_paths() {
    local main_ws=$1
    QA_STACK_DIR="$main_ws/.ralph-workers/qa-stack"
    QA_STACK_CMD_ABS="$QA_STACK_DIR/$RALPH_QA_STACK_CMD"
    export QA_STACK_DIR QA_STACK_CMD="$QA_STACK_CMD_ABS"
}

# Ensure the long-lived stack checkout exists at the tip of main and the stack
# is up. Outside every plan worktree, so the per-turn orphan reaper never
# touches it. Echoes the sha under test. Needs qa_stack_paths first.
qa_stack_up() {
    local main_ws=$1
    [[ -n "$RALPH_QA_ENV_FILE" ]] && export QA_ENV_FILE="$RALPH_QA_ENV_FILE"

    git -C "$main_ws" fetch origin "$RALPH_GH_MAIN_BRANCH" >/dev/null 2>&1 || true
    if [[ ! -d "$QA_STACK_DIR" ]]; then
        git -C "$main_ws" worktree add --detach "$QA_STACK_DIR" "origin/$RALPH_GH_MAIN_BRANCH" >/dev/null 2>&1 || {
            log_status "ERROR" "QA: could not create the stack checkout at $QA_STACK_DIR" >&2
            return 1
        }
    else
        git -C "$QA_STACK_DIR" checkout --detach "origin/$RALPH_GH_MAIN_BRANCH" >/dev/null 2>&1 || {
            log_status "ERROR" "QA: could not move the stack checkout to origin/$RALPH_GH_MAIN_BRANCH" >&2
            return 1
        }
    fi
    if [[ ! -x "$QA_STACK_CMD_ABS" ]]; then
        log_status "ERROR" "QA: stack command $RALPH_QA_STACK_CMD is missing or not executable on $RALPH_GH_MAIN_BRANCH" >&2
        return 1
    fi

    log_status "INFO" "QA: bringing the stack up from $QA_STACK_DIR" >&2
    if ! (cd "$QA_STACK_DIR" && "$QA_STACK_CMD_ABS" up) >> "$LOG_DIR/qa-stack.log" 2>&1; then
        log_status "ERROR" "QA: '$RALPH_QA_STACK_CMD up' failed — see $LOG_DIR/qa-stack.log" >&2
        return 1
    fi
    git -C "$QA_STACK_DIR" rev-parse HEAD
}

qa_stack_reset() {
    (cd "$QA_STACK_DIR" && "$QA_STACK_CMD_ABS" reset --seed "$RALPH_QA_SEED") >> "$LOG_DIR/qa-stack.log" 2>&1
}

# Push a plan run's evidence to the orphan evidence branch without a worktree:
# a private index seeded from the branch tip gets only this run's folder added,
# so earlier runs are never touched. Echoes the evidence commit sha.
#   $1 main workspace, $2 evidence src dir, $3 dest base path (e.g. 1500/20261018-1030)
qa_publish_evidence() {
    local main_ws=$1 src=$2 base=$3
    local branch=$RALPH_QA_EVIDENCE_BRANCH
    [[ -d "$src" ]] || return 1

    local staging idx
    staging=$(mktemp -d)
    idx="$staging.index"
    mkdir -p "$staging/$base"
    local max_bytes=$((RALPH_QA_EVIDENCE_MAX_MB * 1024 * 1024))
    (cd "$src" && find . -type f -size -"${max_bytes}"c -print0) \
        | (cd "$src" && xargs -0 -r cp --parents -t "$staging/$base")
    (cd "$src" && find . -type f -size +"$((max_bytes - 1))"c) | while IFS= read -r big; do
        log_status "WARN" "QA: evidence ${big#./} exceeds ${RALPH_QA_EVIDENCE_MAX_MB} MB, not published" >&2
    done

    local git_dir tracking="refs/remotes/origin/$branch"
    git_dir=$(git -C "$main_ws" rev-parse --absolute-git-dir) || return 1

    local attempt commit=""
    for attempt in 1 2 3; do
        local parent_args=() tree
        rm -f "$idx"
        if git -C "$main_ws" fetch origin "+refs/heads/$branch:$tracking" >/dev/null 2>&1; then
            GIT_INDEX_FILE="$idx" git -C "$main_ws" read-tree "$tracking"
            parent_args=(-p "$(git -C "$main_ws" rev-parse "$tracking")")
        fi
        (cd "$staging" && GIT_DIR="$git_dir" GIT_WORK_TREE="$staging" GIT_INDEX_FILE="$idx" git add -f -- "$base") || break
        tree=$(GIT_INDEX_FILE="$idx" git -C "$main_ws" write-tree) || break
        commit=$(git -C "$main_ws" commit-tree "$tree" "${parent_args[@]}" -m "qa evidence: $base") || break
        if git -C "$main_ws" push origin "$commit:refs/heads/$branch" >/dev/null 2>&1; then
            break
        fi
        commit=""
        sleep 3
    done
    rm -rf "$staging" "$idx"
    [[ -n "$commit" ]] || return 1
    printf '%s' "$commit"
}

# Create the bug and severity labels on first use.
qa_ensure_labels() {
    local repo=$1 label
    local IFS=','
    for label in $RALPH_QA_BUG_LABELS sev:blocker sev:major sev:minor; do
        gh label create "$label" --repo "$repo" --color "d93f0b" >/dev/null 2>&1 < /dev/null || true
    done
}

# File (or cross-reference) one bug per FAIL. Echoes the bug map JSON
# {"QA-05.03": 1234} for the proof comment and the Blocked-by list.
qa_file_bugs() {
    local repo=$1 plan=$2 run_id=$3 sha=$4 scenarios=$5 results=$6 commit=$7 base=$8
    local bugs='{}' id title r dup url num
    while IFS=$'\t' read -r id title; do
        [[ -z "$id" ]] && continue
        r=$(jq -c --arg id "$id" '.[$id] // empty' <<< "$results")
        [[ -z "$r" ]] && continue
        [[ "$(jq -r '.result' <<< "$r")" == "FAIL" ]] || continue

        dup=$(jq -r '.bug.duplicate_of // empty' <<< "$r")
        if [[ -n "$dup" ]]; then
            comment_on_issue "$repo" "$dup" "Seen again by #$plan · **$id** in QA run \`$run_id\` on \`${sha:0:10}\`."$'\n\n'"$(qa_render_evidence "$repo" "$commit" "$base" "$r")" || true
            num=$dup
        else
            local sev labels
            sev=$(jq -r '.bug.severity' <<< "$r")
            labels="$RALPH_QA_BUG_LABELS,sev:$sev"
            url=$(gh issue create --repo "$repo" \
                --title "[$id] $(jq -r '.bug.title' <<< "$r")" \
                --label "$labels" \
                --body "$(qa_render_bug "$repo" "$plan" "$id" "$title" "$run_id" "$sha" "$r" "$commit" "$base")" \
                < /dev/null 2>>"$LOG_DIR/qa-gh.log") || url=""
            num=${url##*/}
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                log_status "ERROR" "QA: failed to file the bug for $id — see $LOG_DIR/qa-gh.log" >&2
                continue
            fi
            log_status "INFO" "QA: filed #$num for $id ($sev)" >&2
        fi
        bugs=$(jq -c --arg id "$id" --argjson n "$num" '. + {($id): $n}' <<< "$bugs")
    done <<< "$scenarios"
    printf '%s' "$bugs"
}

# Run one plan end to end. Returns 0 when every scenario passed, 1 when the
# plan finished with findings or gaps, 2 on a harness failure (stack broken).
qa_run_plan() {
    local main_ws=$1 repo=$2 plan=$3 sha=$4
    local title body plan_id parent
    title=$(get_issue_title "$repo" "$plan") || return 2
    body=$(get_issue_body "$repo" "$plan") || return 2
    plan_id=$(qa_plan_id "$title")
    parent=$(qa_parent_number "$body")

    local scenarios
    scenarios=$(qa_parse_scenarios "$body")
    if [[ -z "$scenarios" ]]; then
        comment_on_issue "$repo" "$plan" "ralph-gh QA mode found no scenarios (\`- [ ] **QA-NN.MM** …\`) in this plan, so nothing ran." || true
        return 1
    fi

    local run_id worktree state_dir evidence_dir results_file
    run_id=$(date '+%Y%m%d-%H%M%S')
    worktree="$main_ws/.ralph-workers/qa-$plan"
    state_dir="$HOME/.ralph-gh/runs/qa-$plan"
    evidence_dir="$worktree/.qa/evidence"
    results_file="$state_dir/results.json"
    mkdir -p "$state_dir"

    [[ -d "$worktree" ]] && git -C "$main_ws" worktree remove --force "$worktree" >/dev/null 2>&1
    git -C "$main_ws" worktree add --detach "$worktree" "$sha" >/dev/null 2>&1 || return 2
    mkdir -p "$evidence_dir" "$worktree/.qa/scripts"
    export QA_EVIDENCE_DIR="$evidence_dir" QA_PLAN_ISSUE="$plan" QA_RUN_ID="$run_id"

    log_status "LOOP" "=== QA plan #$plan $plan_id ($(wc -l <<< "$scenarios") scenarios) ==="
    if ! qa_stack_reset; then
        log_status "ERROR" "QA: stack reset failed before #$plan — see $LOG_DIR/qa-stack.log"
        git -C "$main_ws" worktree remove --force "$worktree" >/dev/null 2>&1
        return 2
    fi

    # QA turns get their own system prompt, tool list and a stricter deny list.
    local RALPH_GH_SYSTEM_PROMPT_FILE="$worktree/$RALPH_QA_SYSTEM_PROMPT_FILE"
    local RALPH_GH_DENY_RULES="$RALPH_GH_DENY_RULES,$RALPH_QA_EXTRA_DENY_RULES"
    if [[ ! -f "$RALPH_GH_SYSTEM_PROMPT_FILE" ]]; then
        log_status "ERROR" "QA: $RALPH_QA_SYSTEM_PROMPT_FILE is missing on $RALPH_GH_MAIN_BRANCH"
        git -C "$main_ws" worktree remove --force "$worktree" >/dev/null 2>&1
        return 2
    fi
    local allowed="${RALPH_QA_ALLOWED_TOOLS:-Write,Read,Edit,Bash(curl *),Bash(jq *),Bash(node *),Bash(pnpm *),Bash(npx *),Bash(gh issue list *),Bash(gh issue view *),Bash(git log *),Bash(git diff *),Bash(git show *),Bash(find *),Bash(stripe *),Bash(k6 *),Bash($QA_STACK_CMD_ABS *)}"
    local timeout_minutes=${RALPH_QA_TIMEOUT_MINUTES:-$CLAUDE_TIMEOUT_MINUTES}

    local results='{}' retry_context="" session_id="" loop=0 gate_ok=1 env_resets=0 note=""
    export RALPH_TELEMETRY_PARENT="${parent:-$plan}" RALPH_TELEMETRY_SUB="$plan"
    while [[ $loop -lt $RALPH_QA_MAX_LOOPS ]]; do
        loop=$((loop + 1))
        export RALPH_TELEMETRY_LOOP="$loop"
        log_status "INFO" "QA plan #$plan — turn $loop/$RALPH_QA_MAX_LOOPS"
        local out="$state_dir/turn-$loop.json" err="$state_dir/turn-$loop.err" rc=0
        run_claude "$worktree" "$(qa_build_prompt "$plan" "$title" "$body" "$evidence_dir" "$retry_context")" \
            "$out" "$err" "$((timeout_minutes * 60))" "$RALPH_GH_MODEL" "$QA_SCHEMA" \
            "$session_id" "$allowed" "" "qa" || rc=$?
        session_id=$RALPH_LAST_SESSION_ID

        local so
        so=$(claude_structured_output "$out")
        if [[ -n "$so" ]]; then
            results=$(qa_merge_results "$results" "$so")
            printf '%s' "$results" > "$results_file"
        fi

        if [[ -n "$so" ]] && [[ "$(jq -r '.status' <<< "$so")" == "BLOCKED" ]] \
           && [[ -n "$(jq -r '.environment_issue // empty' <<< "$so")" ]]; then
            local env_issue
            env_issue=$(jq -r '.environment_issue' <<< "$so")
            log_status "WARN" "QA plan #$plan: environment issue — $env_issue"
            if [[ $env_resets -eq 0 ]] && qa_stack_reset; then
                env_resets=1
                retry_context="The stack was reset after you reported: $env_issue. Data seeded before your earlier scenarios is gone, so re-run anything that depended on it."
                continue
            fi
            comment_on_issue "$repo" "$plan" "ralph-gh QA stopped this plan: the stack is broken, not the product."$'\n\n'"> $env_issue"$'\n\n'"Stack log: \`$LOG_DIR/qa-stack.log\`. The \`$RALPH_GH_LABEL\` label is kept for a rerun." || true
            git -C "$main_ws" worktree remove --force "$worktree" >/dev/null 2>&1
            return 2
        fi

        local gate_failures
        if gate_failures=$(qa_gate "$scenarios" "$results" "$evidence_dir"); then
            gate_ok=0
            break
        fi
        if [[ $rc -eq 124 ]]; then
            retry_context="YOUR PREVIOUS TURN WAS KILLED BY THE ${timeout_minutes}-MINUTE WALL CLOCK. This turn resumes the same session; your evidence is still on disk. Carry on with the scenarios below, and report every result you have."$'\n\n'"$gate_failures"
        else
            retry_context="The shell's QA gate is not satisfied yet. Resolve each item below, then report again:"$'\n\n'"$gate_failures"
        fi
        log_status "WARN" "QA plan #$plan gate:"$'\n'"$gate_failures"
    done
    if [[ $gate_ok -ne 0 ]]; then
        note="Incomplete after $RALPH_QA_MAX_LOOPS turns: scenarios without a valid result are shown as NOT RUN."
    fi

    # Publish evidence, file bugs, then post the proof.
    local base="$plan/$run_id" commit=""
    commit=$(qa_publish_evidence "$main_ws" "$evidence_dir" "$base") || {
        log_status "WARN" "QA: evidence push to $RALPH_QA_EVIDENCE_BRANCH failed; the proof lists paths only"
        commit=""
    }
    qa_ensure_labels "$repo"
    local bugs
    bugs=$(qa_file_bugs "$repo" "$plan" "$run_id" "$sha" "$scenarios" "$results" "$commit" "$base")

    comment_on_issue "$repo" "$plan" \
        "$(qa_render_proof "$repo" "$plan" "$plan_id" "$run_id" "$sha" "$scenarios" "$results" "$commit" "$base" "$bugs" "$note")" \
        || log_status "WARN" "QA: proof comment on #$plan failed"

    local tally pass fail blocked not_run
    tally=$(qa_tally "$scenarios" "$results")
    read -r pass fail blocked not_run <<< "$tally"
    local blocked_md
    blocked_md=$(jq -r 'to_entries | map("- #\(.value) (\(.key))") | unique | .[]' <<< "$bugs")
    local new_body
    new_body=$(qa_rewrite_body "$body" "$results" "$blocked_md")
    [[ "$new_body" != "$body" ]] && { gh issue edit "$plan" --repo "$repo" --body "$new_body" < /dev/null >/dev/null 2>&1 || true; }

    local summary="$plan_id #$plan run \`$run_id\`: $pass PASS · $fail FAIL · $blocked BLOCKED"
    [[ "$not_run" -gt 0 ]] && summary+=" · $not_run NOT RUN"
    [[ "$blocked_md" != "" ]] && summary+=" — bugs: $(jq -r '[.[] | "#\(.)"] | unique | join(", ")' <<< "$bugs")"

    remove_label "$repo" "$plan" "$RALPH_GH_LABEL" || true
    local status=1
    if [[ $fail -eq 0 && $blocked -eq 0 && $not_run -eq 0 ]]; then
        close_sub_issue "$repo" "$plan" "All $pass scenarios passed in QA run \`$run_id\` on \`${sha:0:10}\`. Closing." || true
        [[ -n "$parent" ]] && check_off_sub_issue "$repo" "$parent" "$plan"
        telemetry_record_outcome "qa_pass" "$summary" || true
        status=0
    else
        telemetry_record_outcome "qa_findings" "$summary" || true
    fi
    [[ -n "$parent" ]] && { comment_on_issue "$repo" "$parent" "$summary" || true; }
    log_status "$([[ $status -eq 0 ]] && echo SUCCESS || echo WARN)" "$summary"

    reap_workspace_orphans "$worktree"
    git -C "$main_ws" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    return $status
}

# Plans to run, in programme order. With targets, a parent (a body with a
# "## Sub-Issues" list) expands to its open, labelled sub-plans; without
# targets, every open issue carrying both the trigger and QA labels.
#   $1 repo, $2.. targets
qa_collect_plans() {
    local repo=$1
    shift
    local list_json
    if [[ $# -eq 0 ]]; then
        list_json=$(gh issue list --repo "$repo" --label "$RALPH_GH_LABEL" --label "$RALPH_QA_LABEL" \
            --state open --limit 200 --json number,title,body,labels < /dev/null 2>/dev/null) || list_json='[]'
    else
        local nums=() t body
        for t in "$@"; do
            body=$(get_issue_body "$repo" "$t") || continue
            if grep -q '^## Sub-Issues' <<< "$body"; then
                mapfile -t -O "${#nums[@]}" nums < <(parse_task_list "$body")
            else
                nums+=("$t")
            fi
        done
        list_json='[]'
        local n j
        for n in "${nums[@]}"; do
            j=$(gh issue view "$n" --repo "$repo" --json number,title,body,labels,state < /dev/null 2>/dev/null) || continue
            list_json=$(jq -c --argjson j "$j" '. + [$j]' <<< "$list_json")
        done
    fi

    local i count num title labels state
    count=$(jq 'length' <<< "$list_json")
    for ((i = 0; i < count; i++)); do
        num=$(jq -r ".[$i].number" <<< "$list_json")
        title=$(jq -r ".[$i].title" <<< "$list_json")
        state=$(jq -r ".[$i].state // \"OPEN\"" <<< "$list_json")
        labels=$(jq -c "[.[$i].labels[].name]" <<< "$list_json")
        [[ "$state" == "OPEN" ]] || continue
        jq -r ".[$i].body" <<< "$list_json" | grep -q '^## Sub-Issues' && continue
        qa_labels_hit "$labels" "$RALPH_QA_LABEL" || { log_status "INFO" "QA: #$num has no '$RALPH_QA_LABEL' label, skipped" >&2; continue; }
        qa_labels_hit "$labels" "$RALPH_GH_LABEL" || { log_status "INFO" "QA: #$num has no '$RALPH_GH_LABEL' label, skipped" >&2; continue; }
        if qa_labels_hit "$labels" "$RALPH_QA_SKIP_LABELS${RALPH_GH_SKIP_LABEL:+,$RALPH_GH_SKIP_LABEL}"; then
            log_status "INFO" "QA: #$num carries a hold label, skipped" >&2
            continue
        fi
        printf '%s\t%s\t%s\n' "$(qa_sort_key "$title")" "$num" "$title"
    done | sort -k1,1 | cut -f2,3
}

# Entry point for `ralph-gh qa [ISSUE ...]`.
qa_main() {
    local main_ws=$RALPH_GH_WORKSPACE repo=$RALPH_GH_REPO
    local plans
    plans=$(qa_collect_plans "$repo" "$@")
    if [[ -z "$plans" ]]; then
        log_status "INFO" "QA: no runnable plans (need labels '$RALPH_GH_LABEL' + '$RALPH_QA_LABEL', open, not held)"
        return 0
    fi
    log_status "INFO" "QA: plans in order: $(cut -f1 <<< "$plans" | sed 's/^/#/' | tr '\n' ' ')"

    local sha
    qa_stack_paths "$main_ws"
    sha=$(qa_stack_up "$main_ws") || return 1
    log_status "INFO" "QA: stack is up on ${sha:0:10}"

    local num title rc failed=0
    while IFS=$'\t' read -r num title; do
        [[ -z "$num" ]] && continue
        rc=0
        qa_run_plan "$main_ws" "$repo" "$num" "$sha" || rc=$?
        if [[ $rc -eq 2 ]]; then
            log_status "ERROR" "QA: harness failure on #$num — stopping the run"
            return 1
        fi
        [[ $rc -ne 0 ]] && failed=$((failed + 1))
        if [[ $rc -ne 0 && "$(qa_plan_id "$title")" == "$RALPH_QA_SMOKE_PLAN_ID" ]]; then
            log_status "ERROR" "QA: smoke plan $RALPH_QA_SMOKE_PLAN_ID (#$num) is not green — stopping before the rest"
            return 1
        fi
    done <<< "$plans"

    log_status "SUCCESS" "QA run complete: $(wc -l <<< "$plans") plan(s), $failed with findings"
    return 0
}
