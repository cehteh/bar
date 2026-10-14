#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the handoff brief rule (Bar.d/hermes, rule 'hermes_handoff').
#
# Everything runs against a throw-away session store built here: the live store
# (~/.hermes/state.db) is never read, so nothing depends on this host.  Covered:
#
#   AC1  the brief mode prints the seven sections in order, the goal, context and gates verbatim
#   AC2  an anchor resolves to 'msg <id> <role> <snippet>', an unresolved phrase is listed and
#        the brief exits 4 (and still prints every section)
#   AC3  the JSON form carries the same numbers as the text form
#   AC4  the --anchors mode prints one line per distinct matching message then 'matches: <n>',
#        and exits 1 when nothing matched
#   AC5  the --verify mode answers whether the session is retrievable (exit 0 / 3)
#   AC6  the exit codes: 2 usage (a missing value, an unknown option), 3 an unknown session
#   AC7  the store and the session can come from '--db' / '$HANDOFF_DB' and '$HERMES_SESSION_ID'
#   AC8  the module header and the rule reach 'bar help' and the repertoire guard accepts them
#   AC9  two runs agree on every number
#
# Usage: ./bar test_hermes_handoff        (or directly: tests/test_hermes_handoff.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

echo "=== Testing the handoff brief rule (Bar.d/hermes) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# the elision files the rule writes go here, not into the shared scratch directory
export TMPDIR="$WORK/out"
mkdir -p "$TMPDIR"

# A throw-away session store: one session with three messages, and no other row.
DB="$WORK/state.db"
sqlite3 "$DB" <<'SQL'
create table sessions(id text primary key, parent_session_id text, started_at real, message_count integer);
create table messages(id integer primary key, session_id text, role text, content text, tool_name text, timestamp real);
insert into sessions values ('s-head', null, 1000.0, 3);
insert into messages values (101, 's-head', 'user', 'compose the handoff brief for the child', null, 1000.0);
insert into messages values (102, 's-head', 'assistant', 'the anchor resolves here' || char(10) || 'second line', null, 1001.0);
insert into messages values (103, 's-head', 'tool', 'unrelated tool output', null, 1002.0);
SQL

OUT=""
RC=0
run_bar() { # <args..>
    OUT=""
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BAR" "$@" 2>/dev/null)" || RC=$?
}
run_bar_err() { # <args..>
    OUT=""
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}

export HERMES_SESSION_PROFILE=default
export HERMES_SESSION_ID=s-head

# --- AC1 the seven sections and the verbatim fields --------------------------------------------
echo "--- AC1 the seven sections ---"
run_bar hermes_handoff --goal 'build the handoff rule' --context 'hermes is the helper module' \
    --anchor 'anchor resolves' --gate './bar lints' --report-chars 1200 \
    --session s-head --db "$DB"
check "$RC" "0" "AC1: a brief with every anchor resolved exits 0"
BRIEF="$OUT"
contains "$BRIEF" "GOAL" "AC1: the GOAL heading is printed"
contains "$BRIEF" "build the handoff rule" "AC1: the goal is verbatim"
contains "$BRIEF" "CONTEXT" "AC1: the CONTEXT heading is printed"
contains "$BRIEF" "hermes is the helper module" "AC1: the context is verbatim"
contains "$BRIEF" "RETRIEVAL" "AC1: the RETRIEVAL heading is printed"
contains "$BRIEF" "ANCHORS" "AC1: the ANCHORS heading is printed"
contains "$BRIEF" "MECHANICS" "AC1: the MECHANICS heading is printed"
contains "$BRIEF" "ACCEPTANCE GATES" "AC1: the ACCEPTANCE GATES heading is printed"
contains "$BRIEF" "./bar lints" "AC1: the gate is verbatim"
contains "$BRIEF" "REPORT FORMAT" "AC1: the REPORT FORMAT heading is printed"
contains "$BRIEF" "@session:default/s-head" "AC1: the session link is printed"
contains "$BRIEF" "report at most 1200 chars" "AC1: the report bound is printed"
absent "$BRIEF" "$(printf '\033')" "AC1: no ANSI in the brief"

# --- AC2 an anchor resolves, an unresolved phrase is listed and exits 4 -------------------------
echo
echo "--- AC2 anchors resolve / unresolved ---"
contains "$BRIEF" "msg 102 assistant the anchor resolves here second line" \
    "AC2: the anchor resolved to its message with the newline flattened"
run_bar hermes_handoff --goal 'g' --anchor 'anchor resolves' --anchor 'no-such-phrase' \
    --session s-head --db "$DB"
check "$RC" "4" "AC2: an unresolved anchor makes the brief exit 4"
contains "$OUT" "UNRESOLVED: no-such-phrase" "AC2: the unresolved phrase is listed"
contains "$OUT" "ACCEPTANCE GATES" "AC2: the whole brief is still printed"

# --- AC3 the JSON form carries the same numbers as the text form --------------------------------
echo
echo "--- AC3 the JSON form ---"
run_bar hermes_handoff --goal 'g' --context 'c' --anchor 'anchor resolves' --anchor 'no-such-phrase' \
    --gate 'gt' --report-chars 777 --session s-head --db "$DB" --json
check "$RC" "4" "AC3: the JSON form keeps the exit code"
BRIEF_JSON="$OUT"
if printf '%s' "$BRIEF_JSON" | jq -e . >/dev/null 2>&1; then
    pass "AC3: the brief JSON form is one valid object"
else
    fail "AC3: the brief JSON form is not valid JSON"
fi
check "$(printf '%s' "$BRIEF_JSON" | jq -r .mode)" "brief" "AC3: the object names its mode"
run_bar hermes_handoff --goal 'g' --context 'c' --anchor 'anchor resolves' --anchor 'no-such-phrase' \
    --gate 'gt' --report-chars 777 --session s-head --db "$DB"
BRIEF_TEXT="$OUT"
text_chars="$(printf '%s\n' "$BRIEF_TEXT" | sed -n 's/^report at most \([0-9]*\) chars.*/\1/p')"
json_chars="$(printf '%s' "$BRIEF_JSON" | jq -r .report_chars)"
check "$json_chars" "$text_chars" "AC3: report_chars agrees between the forms"
text_anchors="$(printf '%s\n' "$BRIEF_TEXT" | grep -c '^msg ' || true)"
json_anchors="$(printf '%s' "$BRIEF_JSON" | jq -r .anchor_count)"
check "$json_anchors" "$text_anchors" "AC3: anchor_count agrees with the 'msg' lines"
text_unresolved="$(printf '%s\n' "$BRIEF_TEXT" | grep -c '^UNRESOLVED: ' || true)"
json_unresolved="$(printf '%s' "$BRIEF_JSON" | jq -r .unresolved_count)"
check "$json_unresolved" "$text_unresolved" "AC3: unresolved_count agrees with the 'UNRESOLVED' lines"
json_gates="$(printf '%s' "$BRIEF_JSON" | jq -r .gates_count)"
check "$json_gates" "1" "AC3: gates_count counts the one gate"

# --- AC4 the --anchors mode ---------------------------------------------------------------------
echo
echo "--- AC4 the --anchors mode ---"
run_bar hermes_handoff --anchors 'anchor resolves' --session s-head --db "$DB"
check "$RC" "0" "AC4: a phrase that matches exits 0"
contains "$OUT" "msg 102 assistant" "AC4: the match is printed as 'msg <id> <role> <snippet>'"
contains "$OUT" "matches: 1" "AC4: the count line is printed"
run_bar hermes_handoff --anchors 'no-such-phrase' --session s-head --db "$DB"
check "$RC" "1" "AC4: nothing matched exits 1"
contains "$OUT" "matches: 0" "AC4: and says 'matches: 0'"
run_bar hermes_handoff --anchors 'compose' 'anchor resolves' --session s-head --db "$DB" --json
check "$RC" "0" "AC4: the JSON form of a match exits 0"
check "$(printf '%s' "$OUT" | jq -r .mode)" "anchors" "AC4: the object names its mode"
a_total="$(printf '%s' "$OUT" | jq -r .matches)"
a_shown="$(printf '%s' "$OUT" | jq -r .showing)"
check "$a_total" "2" "AC4: the union of two phrases counts two messages"
check "$a_shown" "2" "AC4: and shows them both"

# --- AC5 the --verify mode ----------------------------------------------------------------------
echo
echo "--- AC5 the --verify mode ---"
run_bar hermes_handoff --verify --session s-head --db "$DB"
check "$RC" "0" "AC5: a retrievable session exits 0"
contains "$OUT" "session s-head msgs=3 chars=" "AC5: the line carries the message count"
contains "$OUT" "retrieval=ok" "AC5: and the verdict 'ok'"
contains "$OUT" "session_search(session_id='s-head'" "AC5: the scroll recipe is printed"
contains "$OUT" "sqlite3 -readonly" "AC5: the verbatim recipe is printed"
contains "$OUT" "caps: max_spawn_depth=" "AC5: the live caps line is printed"
run_bar hermes_handoff --verify --session nope --db "$DB"
check "$RC" "3" "AC5: an unknown session exits 3"
contains "$OUT" "retrieval=missing" "AC5: and reports 'missing'"
run_bar hermes_handoff --verify --session s-head --db "$DB" --json
check "$RC" "0" "AC5: the JSON form exits 0"
check "$(printf '%s' "$OUT" | jq -r .mode)" "verify" "AC5: the object names its mode"
check "$(printf '%s' "$OUT" | jq -r .msgs)" "3" "AC5: the JSON carries the same message count"
check "$(printf '%s' "$OUT" | jq -r .retrieval)" "ok" "AC5: and the same verdict"

# --- AC6 usage errors and unknown sessions ------------------------------------------------------
echo
echo "--- AC6 exit codes ---"
run_bar_err hermes_handoff --session s-head --db "$DB"
check "$RC" "2" "AC6: a brief without --goal exits 2"
contains "$OUT" "--goal" "AC6: and names the missing option"
run_bar_err hermes_handoff --goal g --bogus --session s-head --db "$DB"
check "$RC" "2" "AC6: an unknown option exits 2"
run_bar_err hermes_handoff --anchors --session s-head --db "$DB"
check "$RC" "2" "AC6: --anchors without a phrase exits 2"
run_bar_err hermes_handoff --goal g --session nope --db "$DB"
check "$RC" "3" "AC6: an unknown session exits 3"
run_bar_err hermes_handoff --verify --session nope-nope --db "$DB/none"
check "$RC" "3" "AC6: unreadable store exits 3"

# --- AC7 the store and session defaults ---------------------------------------------------------
echo
echo "--- AC7 store resolution ---"
OUT=""
RC=0
OUT="$(cd "$REPO_ROOT" && HANDOFF_DB="$DB" HERMES_SESSION_ID=s-head "$BAR" hermes_handoff --verify 2>/dev/null)" || RC=$?
check "$RC" "0" "AC7: the store and session come from \$HANDOFF_DB and \$HERMES_SESSION_ID"
contains "$OUT" "retrieval=ok" "AC7: and the session resolves"

# --- AC8 help and the repertoire registration ---------------------------------------------------
echo
echo "--- AC8 help and the repertoire ---"
run_bar help
contains "$OUT" "HANDOFF BRIEFS" "AC8: the module header prose reaches 'bar help'"
contains "$OUT" "hermes_handoff --goal" "AC8: as the rule's own usage"
contains "$OUT" "hermes - " "AC8: under the module's own block"
run_bar helpers
contains "$OUT" "hermes_handoff" "AC8: the repertoire lists the rule"
contains "$OUT" "hermes" "AC8: under the hermes module"
run_bar helpers --check
check "$RC" "0" "AC8: the registration guard accepts the rule"
check "$OUT" "" "AC8: and says nothing when there is nothing to say"

# --- AC9 determinism ----------------------------------------------------------------------------
echo
echo "--- AC9 determinism ---"
run_bar hermes_handoff --goal 'g' --anchor 'anchor resolves' --anchor 'no-such-phrase' \
    --session s-head --db "$DB"
first="$OUT"
run_bar hermes_handoff --goal 'g' --anchor 'anchor resolves' --anchor 'no-such-phrase' \
    --session s-head --db "$DB"
check "$OUT" "$first" "AC9: two briefs of the same question agree"
run_bar hermes_handoff --anchors 'anchor resolves' --session s-head --db "$DB"
first="$OUT"
run_bar hermes_handoff --anchors 'anchor resolves' --session s-head --db "$DB"
check "$OUT" "$first" "AC9: two anchor listings agree on every number"

echo
if (( failures == 0 )); then
    echo "=== All hermes_handoff tests passed ==="
else
    echo "=== $failures hermes_handoff test(s) FAILED ==="
fi
exit "$(( failures > 0 ? 1 : 0 ))"
