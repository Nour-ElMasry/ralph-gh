#!/usr/bin/env bash

# dag.sh - DAG parser, validator, and scheduling primitives for parallel ralph-gh.
#
# Reads `depends_on:` declarations from a parent issue body. Each sub-issue
# checkbox `- [ ] #N ...` may be followed by a line of the form:
#     depends_on: []
#     depends_on: [#522]
#     depends_on: [#522, #523]
# When a sub-issue has no depends_on line, fall back to "depends on the
# immediately-prior sub-issue" (= legacy serial behavior). This keeps existing
# PRDs working unchanged while letting new ones declare fan-out explicitly.

# Parse a parent issue body into a JSON DAG.
#
# Output schema:
#   {
#     "subs": [<sub_id>, ...],                          # in declared order
#     "deps": { "<sub_id>": [<dep_sub_id>, ...], ... }  # parent → list of deps
#   }
#
# Args:
#   $1 = issue body (markdown string)
# Echoes JSON on stdout. Returns 0 on success, 1 on parse error / cycle.
dag_parse_body() {
    local body=$1
    local subs_csv=""           # comma-separated sub ids in declared order
    local current_sub=""        # sub whose deps line we're awaiting
    local last_completed_sub="" # most recent sub whose deps are recorded (for serial fallback)
    local saw_deps_for_sub=0    # 1 once a depends_on: line has been parsed for $current_sub
    local line

    while IFS= read -r line; do
        # Checkbox:  - [ ] #N ...   (tolerates -[x] / -[X] / leading whitespace)
        if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[[:space:]xX]?\][[:space:]]*\#([0-9]+) ]]; then
            local new_sub="${BASH_REMATCH[1]}"

            # Close out the previous sub if its deps were never declared.
            # Default = depend on last_completed_sub (serial fallback).
            if [[ -n "$current_sub" && $saw_deps_for_sub -eq 0 ]]; then
                _dag_record_default_deps "$current_sub" "$last_completed_sub"
                last_completed_sub="$current_sub"
            fi

            current_sub="$new_sub"
            saw_deps_for_sub=0
            subs_csv+="${current_sub},"
            continue
        fi

        # Look for depends_on: [...] under the current sub
        if [[ -n "$current_sub" && $saw_deps_for_sub -eq 0 ]]; then
            if [[ "$line" =~ ^[[:space:]]*depends_on:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
                local deps_raw="${BASH_REMATCH[1]}"
                _dag_record_explicit_deps "$current_sub" "$deps_raw"
                saw_deps_for_sub=1
                last_completed_sub="$current_sub"
                continue
            fi
        fi
    done <<< "$body"

    # Close out the trailing sub
    if [[ -n "$current_sub" && $saw_deps_for_sub -eq 0 ]]; then
        _dag_record_default_deps "$current_sub" "$last_completed_sub"
    fi

    # No sub-issues at all → empty DAG
    if [[ -z "$subs_csv" ]]; then
        echo '{"subs":[],"deps":{}}'
        return 0
    fi

    # Build final JSON
    local subs_json
    subs_json=$(echo "${subs_csv%,}" | jq -R 'split(",") | map(tonumber)')
    local deps_json="{}"
    if [[ -n "$_DAG_DEPS_BUFFER" ]]; then
        # _DAG_DEPS_BUFFER is a sequence of jq object additions, e.g. ' + {"522":[]} + {"524":[522]}'
        # Apply them onto the empty object via jq
        deps_json=$(jq -n "${_DAG_DEPS_BUFFER:2}")  # strip leading " +"
    fi

    jq -n \
        --argjson subs "$subs_json" \
        --argjson deps "$deps_json" \
        '{subs: $subs, deps: $deps}'

    # Reset module-level scratch buffer so subsequent calls start clean
    _DAG_DEPS_BUFFER=""
    _DAG_PREV_SUB_FOR_LAST=""
}

# Internal scratch state used by dag_parse_body to accumulate deps without
# string-mangling JSON. Cleared at the end of dag_parse_body.
_DAG_DEPS_BUFFER=""
_DAG_PREV_SUB_FOR_LAST=""

# Record explicit `depends_on: [#A, #B]` for a sub.
# Args: $1 = sub id, $2 = comma/space-separated deps with optional '#'
_dag_record_explicit_deps() {
    local sub=$1
    local deps_raw=$2
    # Strip '#' and whitespace; split on either commas or whitespace
    local cleaned
    cleaned=$(echo "$deps_raw" | tr ',' ' ' | tr -s ' ' | sed 's/#//g; s/^ *//; s/ *$//')
    local deps_json
    if [[ -z "$cleaned" ]]; then
        deps_json='[]'
    else
        deps_json=$(echo "$cleaned" | tr ' ' '\n' | jq -R 'select(length > 0) | tonumber' | jq -s '.')
    fi
    _DAG_DEPS_BUFFER+=" + {\"$sub\": $deps_json}"
    _DAG_PREV_SUB_FOR_LAST=$sub
}

# Record default deps (= depends on prev_sub if any, else empty) for a sub
# whose body had no `depends_on:` line. Preserves legacy serial behavior.
_dag_record_default_deps() {
    local sub=$1
    local prev=$2
    local deps_json
    if [[ -z "$prev" || "$prev" == "$sub" ]]; then
        deps_json='[]'
    else
        deps_json="[$prev]"
    fi
    _DAG_DEPS_BUFFER+=" + {\"$sub\": $deps_json}"
    _DAG_PREV_SUB_FOR_LAST=$sub
}

# Validate a DAG: every dep must be a known sub, and there must be no cycles.
# Args: $1 = DAG JSON string
# Returns 0 if valid, 1 with a reason on stderr otherwise.
dag_validate() {
    local dag=$1

    # All deps reference known subs
    local unknown
    unknown=$(echo "$dag" | jq -r '
        . as $d
        | .deps | to_entries[]
        | .value[]
        | select(. as $v | ($d.subs | index($v)) == null)
    ' 2>/dev/null)
    if [[ -n "$unknown" ]]; then
        echo "DAG references unknown sub-issue(s): $unknown" >&2
        return 1
    fi

    # Cycle detection via Kahn's algorithm. We iterate at most |subs| times;
    # each iteration removes any node whose deps are all already removed. If
    # the working set is non-empty after that many rounds, a cycle exists.
    local cycle_check
    cycle_check=$(echo "$dag" | jq '
        (.subs | length) as $n
        | reduce range(0; $n) as $_ (
            {deps: .deps, remaining: .subs};
            .deps as $d
            | (.remaining | map(select(($d[(. | tostring)] // []) | length == 0))) as $ready
            | if ($ready | length) == 0 then .
              else {
                deps: ($d | with_entries(
                    .value |= map(select(. as $v | $ready | index($v) | not))
                )),
                remaining: (.remaining - $ready)
              }
              end
          )
        | .remaining | length
    ' 2>/dev/null)
    if [[ -z "$cycle_check" || "$cycle_check" != "0" ]]; then
        echo "DAG has a cycle (or unresolved dependencies)" >&2
        return 1
    fi

    return 0
}

# Sub-issues that are ready to run: blocked subs whose deps are all in `merged`.
# Args: $1 = DAG JSON, $2 = JSON array of merged sub ids, $3 = JSON array of failed
# Echoes JSON array of ready sub ids (a subset of `blocked`).
dag_compute_ready() {
    local dag=$1
    local merged=$2
    local failed=$3
    local blocked=$4

    echo "$dag" | jq \
        --argjson merged "$merged" \
        --argjson failed "$failed" \
        --argjson blocked "$blocked" \
        '
        .deps as $deps
        | $blocked
        | map(select(
            . as $sub
            | (
                ($deps[$sub | tostring] // [])
                | all(. as $d | $merged | index($d) != null)
              )
            and (
                ($deps[$sub | tostring] // [])
                | all(. as $d | $failed | index($d) == null)
              )
        ))
        '
}

# Sub-issues that should be terminally blocked because a dep failed.
# Args: $1 = DAG, $2 = failed array, $3 = blocked array
# Echoes JSON array of newly-cascaded-failed sub ids.
dag_compute_cascade_failures() {
    local dag=$1
    local failed=$2
    local blocked=$3

    echo "$dag" | jq \
        --argjson failed "$failed" \
        --argjson blocked "$blocked" \
        '
        .deps as $deps
        | $blocked
        | map(select(
            . as $sub
            | ($deps[$sub | tostring] // [])
            | any(. as $d | $failed | index($d) != null)
        ))
        '
}

export -f dag_parse_body dag_validate dag_compute_ready dag_compute_cascade_failures
export -f _dag_record_explicit_deps _dag_record_default_deps
