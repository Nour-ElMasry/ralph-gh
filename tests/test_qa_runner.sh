#!/usr/bin/env bash

# test_qa_runner.sh - Tests for QA mode: scenario parsing, the QA gate, result
# merging, body rewriting, proof/bug rendering, plan ordering, and the
# evidence publisher against a local bare remote.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/github_poller.sh"
source "$SCRIPT_DIR/lib/qa_runner.sh"

PASS=0
FAIL=0

assert_eq() {
    local test_name=$1 expected=$2 actual=$3
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected: '$expected'"
        echo "    Actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}
assert_contains() {
    local test_name=$1 needle=$2 haystack=$3
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected to contain: '$needle'"
        echo "    Actual: '$haystack'"
        FAIL=$((FAIL + 1))
    fi
}
assert_not_contains() {
    local test_name=$1 needle=$2 haystack=$3
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  [PASS] $test_name"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $test_name"
        echo "    Expected NOT to contain: '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
LOG_DIR="$TMP/logs"
mkdir -p "$LOG_DIR"

PLAN_BODY='Parent QA #1500 · Plan **QA-05** · Public runtime

## Scope
Things.

## Scenarios
- [ ] **QA-05.01** Published form renders
  - Steps: 1. open
  - Expect: 200
  - Evidence: screenshot
- [x] **QA-05.02** Prefill fills fields
  - Steps: 1. open with ?email=
- [ ] **QA-05.03** Upload over 10 MB is refused

## Out of scope
- [ ] not a scenario, no bold id
- plain bullet'

echo "=== qa_parse_scenarios ==="
SCEN=$(qa_parse_scenarios "$PLAN_BODY")
assert_eq "finds three scenarios" "3" "$(wc -l <<< "$SCEN" | tr -d ' ')"
assert_eq "first id and title" $'QA-05.01\tPublished form renders' "$(head -1 <<< "$SCEN")"
assert_eq "ticked box still parsed" "QA-05.02" "$(sed -n 2p <<< "$SCEN" | cut -f1)"
assert_eq "lettered and track ids parse" $'QA-18a.04\nQA-H1.02' \
    "$(qa_parse_scenarios $'- [ ] **QA-18a.04** a\n- [ ] **QA-H1.02** b' | cut -f1)"
assert_eq "CRLF bodies parse" "QA-01.01" "$(qa_parse_scenarios $'- [ ] **QA-01.01** x\r' | cut -f1)"

echo "=== qa_plan_id / qa_parent_number / qa_sort_key ==="
assert_eq "plan id from title" "QA-05" "$(qa_plan_id 'QA-05: Public runtime')"
assert_eq "no plan id → empty" "" "$(qa_plan_id 'Fix the thing')"
assert_eq "parent from first line" "1500" "$(qa_parent_number "$PLAN_BODY")"
SORTED=$(printf '%s\n' "QA-18b: x" "QA-H1: g" "QA-00: smoke" "QA-18a: y" "QA-05: r" "misc" \
    | while IFS= read -r t; do printf '%s\t%s\n' "$(qa_sort_key "$t")" "$t"; done | sort -k1,1 | cut -f2 | tr '\n' '|')
assert_eq "programme order" "QA-00: smoke|QA-05: r|QA-18a: y|QA-18b: x|QA-H1: g|misc|" "$SORTED"

echo "=== qa_merge_results ==="
R1=$(qa_merge_results '{}' '{"scenarios":[{"id":"QA-05.01","result":"FAIL","summary":"a","evidence":[]}]}')
R2=$(qa_merge_results "$R1" '{"scenarios":[{"id":"QA-05.01","result":"PASS","summary":"b","evidence":["x.png"]},{"id":"QA-05.02","result":"PASS","summary":"c","evidence":[]}]}')
assert_eq "later report for an id wins" "PASS" "$(jq -r '."QA-05.01".result' <<< "$R2")"
assert_eq "new ids are added" "2" "$(jq 'length' <<< "$R2")"
assert_eq "empty structured output keeps results" "$R1" "$(qa_merge_results "$R1" '{}')"

echo "=== qa_gate ==="
EV="$TMP/evidence"
mkdir -p "$EV/QA-05.01" "$EV/QA-05.03"
touch "$EV/QA-05.01/final.png" "$EV/QA-05.03/http.txt"
GOOD='{"QA-05.01":{"result":"PASS","summary":"ok","evidence":["QA-05.01/final.png"]},
"QA-05.02":{"result":"BLOCKED","summary":"b","evidence":[],"blocked_by":"QA-05.03"},
"QA-05.03":{"result":"FAIL","summary":"f","evidence":["QA-05.03/http.txt"],"bug":{"title":"t","severity":"major","expected":"e","actual":"a","repro":"r"}}}'
qa_gate "$SCEN" "$GOOD" "$EV" >/dev/null
assert_eq "complete results pass the gate" "0" "$?"

OUT=$(qa_gate "$SCEN" '{"QA-05.01":{"result":"PASS","summary":"ok","evidence":["QA-05.01/final.png"]}}' "$EV")
assert_eq "missing scenarios fail the gate" "1" "$?"
assert_contains "names the unexecuted scenario" "QA-05.02: not executed" "$OUT"

OUT=$(qa_gate "$SCEN" "$(jq -c '."QA-05.01".evidence = ["QA-05.01/missing.png"]' <<< "$GOOD")" "$EV")
assert_contains "PASS with a nonexistent evidence file is refused" "QA-05.01: PASS reported without evidence" "$OUT"

OUT=$(qa_gate "$SCEN" "$(jq -c 'del(."QA-05.03".bug.repro)' <<< "$GOOD")" "$EV")
assert_contains "FAIL without a complete bug is refused" "QA-05.03: FAIL needs a complete bug" "$OUT"

OUT=$(qa_gate "$SCEN" "$(jq -c 'del(."QA-05.02".blocked_by)' <<< "$GOOD")" "$EV")
assert_contains "BLOCKED without blocked_by is refused" "QA-05.02: BLOCKED needs blocked_by" "$OUT"

OUT=$(qa_gate "$SCEN" "$(jq -c '."QA-05.03".evidence = ["../../etc/passwd"]' <<< "$GOOD")" "$TMP/nowhere")
assert_contains "evidence must live under the evidence dir" "QA-05.03: FAIL reported without evidence" "$OUT"

echo "=== qa_tally ==="
assert_eq "tally counts each result" "1 1 1 0" "$(qa_tally "$SCEN" "$GOOD")"
assert_eq "absent ids are NOT_RUN" "0 0 0 3" "$(qa_tally "$SCEN" '{}')"

echo "=== qa_rewrite_body ==="
NEW=$(qa_rewrite_body "$PLAN_BODY" "$GOOD" "- #9001 (QA-05.03)")
assert_contains "PASS ticks its box" "- [x] **QA-05.01**" "$NEW"
assert_contains "non-PASS unticks a previously ticked box" "- [ ] **QA-05.02**" "$NEW"
assert_contains "Blocked by section appended" $'## Blocked by\n\n- #9001 (QA-05.03)' "$NEW"
assert_contains "non-scenario checkbox untouched" "- [ ] not a scenario, no bold id" "$NEW"
AGAIN=$(qa_rewrite_body "$NEW" "$GOOD" "- #9002 (QA-05.03)")
assert_eq "Blocked by section is replaced, not duplicated" "1" "$(grep -c '^## Blocked by' <<< "$AGAIN")"
assert_not_contains "old bug dropped on replace" "#9001" "$AGAIN"
GREEN=$(qa_rewrite_body "$NEW" "$GOOD" "")
assert_not_contains "empty list removes the section" "## Blocked by" "$GREEN"
assert_contains "content after the section survives" "## Out of scope" \
    "$(qa_rewrite_body $'## Blocked by\n\n- #1\n\n## Out of scope\n- x' '{}' '')"

echo "=== rendering ==="
assert_eq "image URL renders raw" "https://github.com/o/r/blob/abc/1/2/QA-05.01/final.png?raw=true" \
    "$(qa_evidence_url o/r abc 1/2/QA-05.01/final.png)"
assert_eq "text URL stays a blob link" "https://github.com/o/r/blob/abc/x/http.txt" "$(qa_evidence_url o/r abc x/http.txt)"
PROOF=$(qa_render_proof o/r 1505 QA-05 20261018-1030 deadbeefcafe "$SCEN" "$GOOD" abc 1505/20261018-1030 '{"QA-05.03":9001}' "")
assert_contains "proof headline tallies" "**1 PASS** · **1 FAIL** · **1 BLOCKED**" "$PROOF"
assert_contains "proof links the bug" "| **QA-05.03** Upload over 10 MB is refused | ❌ FAIL | #9001 |" "$PROOF"
assert_contains "proof embeds the screenshot" "![QA-05.01/final.png](https://github.com/o/r/blob/abc/1505/20261018-1030/QA-05.01/final.png?raw=true)" "$PROOF"
assert_contains "blocked row names its cause" "⛔ BLOCKED by QA-05.03" "$PROOF"
NOTRUN=$(qa_render_proof o/r 1505 QA-05 r1 sha "$SCEN" '{}' "" b '{}' "Incomplete")
assert_contains "unexecuted scenarios show NOT RUN" "**3 NOT RUN**" "$NOTRUN"
assert_contains "note is quoted" "> Incomplete" "$NOTRUN"
BIG=$(jq -c --arg s "$(printf 'x%.0s' {1..70000})" '."QA-05.01".summary = $s' <<< "$GOOD")
assert_eq "proof stays under GitHub's comment limit" "1" \
    "$([[ $(qa_render_proof o/r 1 QA-05 r s "$SCEN" "$BIG" "" b '{}' "" | wc -c) -lt 65536 ]] && echo 1)"
BUG=$(qa_render_bug o/r 1505 QA-05.03 "Upload over 10 MB is refused" r1 deadbeefcafe "$(jq -c '."QA-05.03"' <<< "$GOOD")" abc base)
assert_contains "bug names its plan and scenario" "Found by #1505 · **QA-05.03**" "$BUG"
assert_contains "bug carries severity" "**Severity:** major" "$BUG"

echo "=== qa_labels_hit ==="
qa_labels_hit '["ralph","qa"]' "qa"; assert_eq "label present" "0" "$?"
qa_labels_hit '["ralph"]' "hitl,qa"; assert_eq "label absent" "1" "$?"
qa_labels_hit '["hitl"]' "hitl,"; assert_eq "trailing comma tolerated" "0" "$?"
qa_labels_hit '["ralph","QA"]' "qa"; assert_eq "label match ignores case" "0" "$?"

echo "=== qa_collect_plans (mocked gh) ==="
gh() {
    if [[ "$1 $2" == "issue list" ]]; then
        cat <<'JSON'
[{"number":12,"title":"QA-05: runtime","body":"- [ ] **QA-05.01** a","labels":[{"name":"ralph"},{"name":"qa"}]},
 {"number":10,"title":"QA-00: smoke","body":"- [ ] **QA-00.01** a","labels":[{"name":"ralph"},{"name":"qa"}]},
 {"number":11,"title":"Launch QA","body":"## Sub-Issues\n- [ ] #10","labels":[{"name":"ralph"},{"name":"qa"}]},
 {"number":13,"title":"QA-H1: google","body":"x","labels":[{"name":"ralph"},{"name":"qa"},{"name":"hitl"}]}]
JSON
    fi
}
RALPH_GH_LABEL=ralph
PLANS=$(qa_collect_plans o/r 2>/dev/null | cut -f1 | tr '\n' ' ')
assert_eq "polls plans in programme order, skipping parents and hitl" "10 12 " "$PLANS"
unset -f gh

echo "=== system prompt override ==="
source "$SCRIPT_DIR/lib/claude_runner.sh"
mkdir -p "$TMP/sysws/.ralph"
echo impl > "$TMP/sysws/.ralph/PROMPT.md"
echo qa > "$TMP/sysws/.ralph/QA_PROMPT.md"
assert_contains "implementer gets PROMPT.md by default" "$TMP/sysws/.ralph/PROMPT.md" \
    "$(claude_build_args "$TMP/sysws" "" "" "" "" "")"
assert_contains "QA turns swap in their own system prompt" "$TMP/sysws/.ralph/QA_PROMPT.md" \
    "$(RALPH_GH_SYSTEM_PROMPT_FILE="$TMP/sysws/.ralph/QA_PROMPT.md" claude_build_args "$TMP/sysws" "" "" "" "" "")"
assert_not_contains "QA turns do not also get PROMPT.md" "/.ralph/PROMPT.md" \
    "$(RALPH_GH_SYSTEM_PROMPT_FILE="$TMP/sysws/.ralph/QA_PROMPT.md" claude_build_args "$TMP/sysws" "" "" "" "" "")"

echo "=== qa_publish_evidence (local bare remote) ==="
REMOTE="$TMP/remote.git"
WS="$TMP/ws"
git init -q --bare "$REMOTE"
git init -q "$WS"
git -C "$WS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WS" remote add origin "$REMOTE"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
C1=$(qa_publish_evidence "$WS" "$EV" "1505/run1")
assert_eq "first publish creates the branch" "$C1" "$(git -C "$REMOTE" rev-parse qa-evidence)"
assert_eq "evidence lands under its base path" "1505/run1/QA-05.01/final.png" \
    "$(git -C "$REMOTE" ls-tree -r --name-only qa-evidence | sort | head -1)"
C2=$(qa_publish_evidence "$WS" "$EV" "1505/run2")
assert_eq "second run keeps the first run's files" "4" "$(git -C "$REMOTE" ls-tree -r --name-only qa-evidence | wc -l | tr -d ' ')"
assert_eq "second run is a child of the first" "$C1" "$(git -C "$REMOTE" rev-parse "$C2^")"
assert_eq "main branch untouched" "1" "$(git -C "$WS" rev-list --count HEAD)"
dd if=/dev/zero of="$EV/QA-05.01/huge.webm" bs=1M count=2 status=none
RALPH_QA_EVIDENCE_MAX_MB=1 qa_publish_evidence "$WS" "$EV" "1505/run3" >/dev/null 2>&1
assert_eq "oversized evidence is skipped" "0" \
    "$(git -C "$REMOTE" ls-tree -r --name-only qa-evidence | grep -c 'run3/.*huge.webm')"

echo "=== qa_redact.py ==="
redact() { python3 "$SCRIPT_DIR/lib/qa_redact.py" --stdin; }
FAKE_JWT="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJxYS11c2VyIn0.ZmFrZS1zaWduYXR1cmUtZm9yLXRlc3Rz"
assert_eq "a JWT anywhere is replaced whole" "token is <redacted:jwt> here" "$(redact <<< "token is $FAKE_JWT here")"
assert_eq "a Set-Cookie keeps its name and flags" "Set-Cookie: access_token=<redacted>; Path=/; HttpOnly; Secure" \
    "$(redact <<< "Set-Cookie: access_token=abcdef123456; Path=/; HttpOnly; Secure")"
assert_eq "a Cookie header blanks every pair" "-H 'Cookie: a=<redacted>; XSRF-TOKEN=<redacted>'" \
    "$(redact <<< "-H 'Cookie: a=one; XSRF-TOKEN=abcdef123456'")"
assert_eq "an Authorization header keeps its scheme" "Authorization: Bearer <redacted>" \
    "$(redact <<< "Authorization: Bearer hp_0123456789abcdef0123456789abcdef")"
assert_eq "the CSRF header is redacted" "x-csrf-token: <redacted>" "$(redact <<< "x-csrf-token: 9f8e7d6c5b4a")"
assert_eq "a JSON headers object is redacted" '{"set-cookie": "sid=<redacted>; HttpOnly","content-type": "text/html"}' \
    "$(redact <<< '{"set-cookie": "sid=s3cr3tvalue; HttpOnly","content-type": "text/html"}')"
assert_eq "a trace's name/value header is redacted" '{"name":"Cookie","value":"sid=<redacted>"}' \
    "$(redact <<< '{"name":"Cookie","value":"sid=s3cr3tvalue"}')"
assert_eq "secret-named JSON fields are redacted" '{"rawKey":"<redacted>","tokenExpiresAt":"2026-10-19T00:00:00Z"}' \
    "$(redact <<< '{"rawKey":"abcdef0123456789","tokenExpiresAt":"2026-10-19T00:00:00Z"}')"
assert_eq "a one-time link loses its token, nested ones too" "/verify?token=<redacted>&next=%2Faccept%3Ftoken%3D<redacted>" \
    "$(redact <<< "/verify?token=abcdef0123456789&next=%2Faccept%3Ftoken%3Dfedcba9876543210")"
assert_eq "a curl -u credential is redacted, a shell expansion too" 'curl -s -u "<redacted>" https://api.stripe.com' \
    "$(redact <<< 'curl -s -u "$STRIPE_SECRET_KEY:" https://api.stripe.com')"
assert_eq "a cookie jar line loses its value" $'localhost\tFALSE\t/\tFALSE\t0\tsid\t<redacted>' \
    "$(redact <<< $'localhost\tFALSE\t/\tFALSE\t0\tsid\ts3cr3tvalue')"
assert_eq "URL-encoded JSON loses its token" "?p=%7B%22token%22%3A%22<redacted>%22%7D" \
    "$(redact <<< "?p=%7B%22token%22%3A%22abcdef0123456789%22%7D")"
assert_eq "a Stripe publishable key is replaced" '"key":"<redacted:stripe-publishable-key>"' \
    "$(redact <<< '"key":"pk_test_0000fake0000fake"')"
assert_eq "a report stays valid JSON" "ok" \
    "$(redact <<< "{\"QA-01.01\":{\"summary\":\"Cookie: sid=abcdefgh1234 and $FAKE_JWT\"}}" | jq -r 'if .["QA-01.01"].summary then "ok" else "broken" end')"
mkdir -p "$TMP/zipsrc"
printf '{"name":"cookie","value":"sid=s3cr3tvalue"}\n' > "$TMP/zipsrc/trace.network"
(cd "$TMP/zipsrc" && python3 -c 'import zipfile; z=zipfile.ZipFile("../trace.zip","w"); z.write("trace.network"); z.close()')
mkdir -p "$TMP/zipdir" && mv "$TMP/trace.zip" "$TMP/zipdir/"
python3 "$SCRIPT_DIR/lib/qa_redact.py" "$TMP/zipdir" 2>/dev/null
assert_eq "a trace zip's network log is redacted" '{"name":"cookie","value":"sid=<redacted>"}' \
    "$(python3 -c 'import sys, zipfile; print(zipfile.ZipFile(sys.argv[1]).read("trace.network").decode().strip())' "$TMP/zipdir/trace.zip")"
printf 'not a zip' > "$TMP/zipdir/broken.zip"
python3 "$SCRIPT_DIR/lib/qa_redact.py" "$TMP/zipdir" 2>/dev/null
assert_eq "an unreadable zip is dropped, not published unread" "no" "$([[ -e "$TMP/zipdir/broken.zip" ]] && echo yes || echo no)"

echo "=== qa_publish_evidence redacts ==="
mkdir -p "$EV/QA-05.04"
printf 'Set-Cookie: access_token=%s; HttpOnly\n' "$FAKE_JWT" > "$EV/QA-05.04/http-login.txt"
C4=$(qa_publish_evidence "$WS" "$EV" "1505/run4" 2>/dev/null)
assert_eq "published evidence carries no session token" "Set-Cookie: access_token=<redacted>; HttpOnly" \
    "$(git -C "$REMOTE" show "$C4:1505/run4/QA-05.04/http-login.txt")"
assert_contains "the local evidence is left as captured" "$FAKE_JWT" "$(cat "$EV/QA-05.04/http-login.txt")"
C5=$(QA_REDACT=/nonexistent/qa_redact.py qa_publish_evidence "$WS" "$EV" "1505/run5" 2>/dev/null)
assert_eq "no redactor, no publish" "" "$C5"

echo "=== qa_stack_paths exports QA_ENV_FILE to the caller ==="
unset QA_ENV_FILE
RALPH_QA_ENV_FILE=/tmp/qa.env qa_stack_paths "$TMP/mainws"
assert_eq "the plan shell sees QA_ENV_FILE" "/tmp/qa.env" "${QA_ENV_FILE:-}"
unset QA_ENV_FILE

echo "qa_file_bugs"
LOG_DIR=$(mktemp -d)
GH_CREATES=0
gh() { [[ "$1 $2" == "issue create" ]] && { GH_CREATES=$((GH_CREATES + 1)); echo "https://github.com/o/r/issues/$((900 + GH_CREATES))"; }; }
COMMENTED="$LOG_DIR/commented"
# Like `gh issue comment`, the real one prints the comment URL on stdout.
comment_on_issue() { echo "$2" >> "$COMMENTED"; echo "https://github.com/o/r/issues/$2#issuecomment-1"; }
qa_render_bug() { :; }
qa_render_evidence() { :; }
DUP_SCEN=$'QA-04.13\tRestore\nQA-04.19\tArchive'
DUP_RES='{"QA-04.13":{"result":"FAIL","bug":{"title":"POSTs answer 201","severity":"minor"}},"QA-04.19":{"result":"FAIL","bug":{"title":"POSTs answer 201","severity":"minor"}}}'
DUP_MAP=$(qa_file_bugs o/r 1499 run sha "$DUP_SCEN" "$DUP_RES" c base 2>/dev/null)
assert_eq "a repeated bug title in one run maps both scenarios to one issue" '{"QA-04.13":901,"QA-04.19":901}' "$DUP_MAP"
assert_eq "the repeat cross-references instead of filing" "901" "$(cat "$COMMENTED")"
unset -f gh comment_on_issue

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
