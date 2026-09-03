#!/usr/bin/env bash

# telemetry.sh - append-only run records that outlive worktree cleanup.
#
# Every Claude invocation and every gate verdict is one JSON line in
# ~/.ralph-gh/telemetry.jsonl. Worktree cleanup deletes per-issue logs on
# success, so before this file existed nothing survived a good run: no
# loops-per-sub, no cost-per-PR, no failure-mode histogram.
#
# Context (repo/parent/sub/loop) is read from globals the orchestrator sets:
#   RALPH_TELEMETRY_REPO, RALPH_TELEMETRY_PARENT, RALPH_TELEMETRY_SUB,
#   RALPH_TELEMETRY_LOOP

RALPH_GH_TELEMETRY_FILE="${RALPH_GH_TELEMETRY_FILE:-$HOME/.ralph-gh/telemetry.jsonl}"

_telemetry_append() {
    local line=$1
    mkdir -p "$(dirname "$RALPH_GH_TELEMETRY_FILE")" 2>/dev/null || return 0
    printf '%s\n' "$line" >> "$RALPH_GH_TELEMETRY_FILE" 2>/dev/null || true
}

_telemetry_ctx_json() {
    jq -nc \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg repo "${RALPH_TELEMETRY_REPO:-${RALPH_GH_REPO:-}}" \
        --arg parent "${RALPH_TELEMETRY_PARENT:-}" \
        --arg sub "${RALPH_TELEMETRY_SUB:-}" \
        --arg loop "${RALPH_TELEMETRY_LOOP:-}" \
        '{ts: $ts, repo: $repo,
          parent: (if $parent == "" then null else ($parent | tonumber) end),
          sub:    (if $sub == "" then null else ($sub | tonumber) end),
          loop:   (if $loop == "" then null else ($loop | tonumber) end)}'
}

# Record one Claude invocation from its --output-format json file.
#   $1 = output file, $2 = phase, $3 = CLI exit code, $4 = requested model
telemetry_record_claude() {
    local output_file=$1
    local phase=$2
    local exit_code=$3
    local model=${4:-}

    local result='{}'
    if declare -F claude_result_json >/dev/null 2>&1; then
        result=$(claude_result_json "$output_file")
    fi
    [[ -z "$result" ]] && result='{}'

    local line
    line=$(jq -nc \
        --argjson ctx "$(_telemetry_ctx_json)" \
        --argjson r "$result" \
        --arg phase "$phase" \
        --arg exit_code "$exit_code" \
        --arg model "$model" \
        '$ctx + {
            event: "claude",
            phase: $phase,
            exit_code: ($exit_code | tonumber),
            model_requested: $model,
            models_used: (($r.modelUsage // {}) | keys),
            is_error: (if ($r | has("is_error")) then $r.is_error else null end),
            stop_reason: ($r.stop_reason // null),
            num_turns: ($r.num_turns // null),
            duration_ms: ($r.duration_ms // null),
            cost_usd: ($r.total_cost_usd // null),
            input_tokens: ($r.usage.input_tokens // null),
            output_tokens: ($r.usage.output_tokens // null),
            cache_read_tokens: ($r.usage.cache_read_input_tokens // null),
            permission_denials: (($r.permission_denials // []) | length),
            has_structured_output: (($r.structured_output // null) != null),
            session_id: ($r.session_id // null)
        }' 2>/dev/null) || return 0
    _telemetry_append "$line"
}

# Record a gate verdict.
#   $1 = gate name (acceptance|verify|verifier|invocation), $2 = "pass"|"fail"|"skip", $3 = detail (short)
telemetry_record_gate() {
    local gate=$1
    local outcome=$2
    local detail=${3:-}
    local line
    line=$(jq -nc \
        --argjson ctx "$(_telemetry_ctx_json)" \
        --arg gate "$gate" --arg outcome "$outcome" --arg detail "${detail:0:300}" \
        '$ctx + {event: "gate", gate: $gate, outcome: $outcome, detail: $detail}' 2>/dev/null) || return 0
    _telemetry_append "$line"
}

# Record a parent-level outcome (pr_opened|draft_pr|aborted|deferred).
#   $1 = outcome, $2 = detail
telemetry_record_outcome() {
    local outcome=$1
    local detail=${2:-}
    local line
    line=$(jq -nc \
        --argjson ctx "$(_telemetry_ctx_json)" \
        --arg outcome "$outcome" --arg detail "${detail:0:300}" \
        '$ctx + {event: "outcome", outcome: $outcome, detail: $detail}' 2>/dev/null) || return 0
    _telemetry_append "$line"
}

# Print a per-parent summary table for `ralph-gh --stats`.
#   $1 = optional repo filter (owner/repo)
telemetry_stats() {
    local repo_filter=${1:-}
    if [[ ! -s "$RALPH_GH_TELEMETRY_FILE" ]]; then
        echo "No telemetry yet at $RALPH_GH_TELEMETRY_FILE"
        return 0
    fi
    echo "Telemetry: $RALPH_GH_TELEMETRY_FILE"
    echo ""
    jq -rs --arg repo "$repo_filter" '
        map(select($repo == "" or .repo == $repo))
        | group_by(.repo, .parent)
        | map({
            repo: .[0].repo,
            parent: .[0].parent,
            first: (map(.ts) | min),
            last:  (map(.ts) | max),
            calls: (map(select(.event == "claude")) | length),
            implement_calls: (map(select(.event == "claude" and .phase == "implement")) | length),
            subs: (map(select(.sub != null) | .sub) | unique | length),
            cost: (map(select(.event == "claude") | .cost_usd // 0) | add // 0),
            turns: (map(select(.event == "claude") | .num_turns // 0) | add // 0),
            minutes: ((map(select(.event == "claude") | .duration_ms // 0) | add // 0) / 60000),
            gate_fail_accept:   (map(select(.event == "gate" and .gate == "acceptance" and .outcome == "fail")) | length),
            gate_fail_verify:   (map(select(.event == "gate" and .gate == "verify" and .outcome == "fail")) | length),
            gate_fail_verifier: (map(select(.event == "gate" and .gate == "verifier" and .outcome == "fail")) | length),
            denials: (map(select(.event == "claude") | .permission_denials // 0) | add // 0),
            outcome: (map(select(.event == "outcome") | .outcome) | last // "-")
          })
        | sort_by(.first)
        | (["parent","subs","impl","calls","turns","min","cost$","accept✗","verify✗","verifier✗","denied","outcome","last"] | @tsv),
          (.[] | [ (.parent|tostring), .subs, .implement_calls, .calls, .turns, (.minutes|floor), (.cost|.*100|round/100), .gate_fail_accept, .gate_fail_verify, .gate_fail_verifier, .denials, .outcome, .last[0:10] ] | @tsv)
    ' "$RALPH_GH_TELEMETRY_FILE" | { column -t -s $'\t' 2>/dev/null || cat; }
    echo ""
    jq -rs --arg repo "$repo_filter" '
        map(select(($repo == "" or .repo == $repo) and .event == "claude"))
        | "Totals: \(length) claude calls, $\((map(.cost_usd // 0) | add // 0) * 100 | round / 100), \((map(.num_turns // 0) | add // 0)) turns, \(((map(.duration_ms // 0) | add // 0) / 3600000 * 10 | round / 10)) hours of model time"
    ' "$RALPH_GH_TELEMETRY_FILE"
}

export -f telemetry_record_claude telemetry_record_gate telemetry_record_outcome telemetry_stats
