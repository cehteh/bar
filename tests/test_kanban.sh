#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the Kanban board state helper (Bar.d/kanban, rule 'kanban_state').
#
# Everything runs against throw-away board databases and a throw-away installation: the live board
# (~/.hermes/kanban.db) is never read, so the assertions do not move under the test.  Covered:
#
#   AC1  the summary is six lines, no card, exit 0 -- also through an installed 'please' from an
#        arbitrary directory
#   AC2  the summary is bounded (the count line, the waiting line, the oldest ready age)
#   AC3  '--json' is one valid object carrying the same numbers as the text form
#   AC4  a selector lists one line per matching card, then the count of its own line
#   AC5  the listing is limited, names the elision counts and the file holding every match
#   AC6  a blocked card carries its reason; without one the failure excerpt, then a plain note
#   AC7  '--runs' prints the runs of one card with the failure count and the workspace
#   AC8  the exit codes: 0 answered (also for an empty result), 2 usage (a missing or empty value),
#        3 unreadable, 4 no card
#   AC9  the board is resolved like the kernel does (--board, HERMES_KANBAN_BOARD, kanban/current)
#   AC10 the JSON survives quotes, pipes, backslashes and control characters
#   AC11 the module header and the rule reach 'bar help'
#   AC12 the repertoire index lists the helper and the registration guard accepts it
#   AC13 two runs agree on every number
#
# Usage: ./bar test_kanban        (or directly: tests/test_kanban.sh)

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
bytes_of() { printf '%s' "$1" | wc -c; }
num() { printf '%s' "${1//[!0-9]/}"; }   # the leading integer of a line, tags stripped

echo "=== Testing the Kanban board state helper (Bar.d/kanban) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# the elision files the helper writes go here, not into the shared scratch directory
export TMPDIR="$WORK/out"
mkdir -p "$TMPDIR"

OUT=""
RC=0
run_bar() { # <dir> <args..>
    local dir="$1"
    shift
    OUT=""
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>/dev/null)" || RC=$?
}
run_bar_err() { # <dir> <args..>
    local dir="$1"
    shift
    OUT=""
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}
run_in() { # <dir> <cmd..>
    local dir="$1"
    shift
    OUT=""
    RC=0
    OUT="$(cd "$dir" && "$@" 2>/dev/null)" || RC=$?
}

# --------------------------------------------------------------------------------------------
# the fixture board
# --------------------------------------------------------------------------------------------
#
# A board with one card per status, dependencies in both directions, three blocked cards (a reason
# in an event, only a failure excerpt, nothing at all), four runs on one card of which one is live.
# The archived card is counted by the kernel but not by the status line, the same as 'hermes kanban
# stats' does it.

NOW="$(date +%s)"
TITLE_TRIAGE='triage: a "quote", a | pipe and a \ backslash'
# long enough to force the card line to shorten it, which is what makes the helper name the file
# holding the complete, untruncated answer
REASON_FULL='the newest reason, with a | pipe and a "quote", and enough words after it to be longer than the one hundred and twenty characters a card line may carry'
OLDEST_READY_AGE=1800

mkboard() { # <path> [empty]
    local db="$1"
    local empty="${2:-}"
    sqlite3 "$db" <<SQL
create table tasks (
    id text primary key,
    title text not null,
    body text,
    assignee text,
    status text not null,
    priority integer default 0,
    created_by text,
    created_at integer not null,
    started_at integer,
    completed_at integer,
    workspace_kind text not null default 'scratch',
    workspace_path text,
    branch_name text,
    project_id text,
    current_run_id integer,
    block_kind text,
    last_failure_error text,
    tenant text
);
create table task_links (parent_id text not null, child_id text not null, primary key (parent_id, child_id));
create table task_comments (id integer primary key autoincrement, task_id text not null, author text not null, body text not null, created_at integer not null);
create table task_events (id integer primary key autoincrement, task_id text not null, run_id integer, kind text not null, payload text, created_at integer not null);
create table task_runs (id integer primary key autoincrement, task_id text not null, profile text, step_key text, status text not null, started_at integer not null, ended_at integer, outcome text, summary text, metadata text, error text);
SQL
    if [[ -n "$empty" ]]; then
        return 0
    fi
    sqlite3 "$db" <<SQL
insert into tasks (id, title, assignee, status, priority, created_at, current_run_id, block_kind, last_failure_error, project_id, workspace_kind, workspace_path, branch_name) values
 ('t_ready_a',    'ready: the oldest, waiting half an hour', 'default', 'ready',     5, $((NOW - OLDEST_READY_AGE)), null, null, null, null, 'worktree', '/w/t_ready_a',    'wt/t_ready_a'),
 ('t_ready_b',    'ready: newer',                            'worker',  'ready',     1, $((NOW - 600)),  null, null, null, null, 'scratch',  '/w/t_ready_b',    ''),
 ('t_run_a',      'running: has four runs',                  'default', 'running',   9, $((NOW - 300)),  41,   null, null, null, 'worktree', '/w/t_run_a',      'wt/t_run_a'),
 ('t_run_b',      'running: a second live run',              'default', 'running',   6, $((NOW - 150)),  36,   null, null, null, 'scratch',  '/w/t_run_b',      ''),
 ('t_blk_reason', 'blocked: a reason in its event',          'default', 'blocked',   7, $((NOW - 900)),  null, 'needs_input', null, null, 'scratch', '/w/t_blk_reason', ''),
 ('t_blk_err',    'blocked: only a failure excerpt',         'default', 'blocked',   2, $((NOW - 1200)), null, null, 'spawn failed: no such profile', null, 'scratch', '/w/t_blk_err', ''),
 ('t_blk_bare',   'blocked: nothing recorded at all',        'worker',  'blocked',   0, $((NOW - 1500)), null, null, null, null, 'scratch', '/w/t_blk_bare', ''),
 ('t_todo_dep',   'todo: behind a ready parent',             'default', 'todo',      3, $((NOW - 2400)), null, null, null, null, 'scratch', '/w/t_todo_dep', ''),
 ('t_todo_free',  'todo: its parent is done',                'default', 'todo',      4, $((NOW - 2100)), null, null, null, null, 'scratch', '/w/t_todo_free', ''),
 ('t_done_a',     'done: nothing to do',                     'default', 'done',      0, $((NOW - 3600)), null, null, null, null, 'scratch', '/w/t_done_a', ''),
 ('t_done_b',     'done: a parent of two',                   'default', 'done',      0, $((NOW - 7200)), null, null, null, null, 'scratch', '/w/t_done_b', ''),
 ('t_triage_a',   '$TITLE_TRIAGE',                           'default', 'triage',    1, $((NOW - 120)),  null, null, null, null, 'scratch', '/w/t_triage_a', ''),
 ('t_sched_a',    'scheduled: waiting on a clock',           'default', 'scheduled', 6, $((NOW - 60)),   null, null, null, null, 'scratch', '/w/t_sched_a', ''),
 ('t_review_a',   'review: awaiting a reviewer',             'default', 'review',    8, $((NOW - 90)),   null, null, null, null, 'scratch', '/w/t_review_a', ''),
 ('t_proj_a',     'todo: linked to the demo project',        'default', 'todo',      5, $((NOW - 180)),  null, null, null, 'p_demo', 'scratch', '/w/t_proj_a', ''),
 ('t_multiline',  'title with' || char(10) || 'a newline',   'default', 'todo',      0, $((NOW - 30)),   null, null, null, null, 'scratch', '/w/t_multiline', ''),
 ('t_arch',       'archived: counted by nobody',             'default', 'archived',  0, $((NOW - 10000)), null, null, null, null, 'scratch', '/w/t_arch', '');

insert into task_links (parent_id, child_id) values
 ('t_done_b', 't_todo_free'),
 ('t_done_b', 't_ready_a'),
 ('t_ready_a', 't_todo_dep'),
 ('t_run_a', 't_ready_b');

insert into task_events (id, task_id, kind, payload, created_at) values
 (1, 't_blk_reason', 'blocked', '{"kind":"needs_input","reason":"an older reason which must not win"}', $((NOW - 1000))),
 (2, 't_blk_reason', 'blocked', json_object('kind', 'needs_input', 'reason', '$REASON_FULL'), $((NOW - 900))),
 (3, 't_triage_a', 'status', 'not json at all', $((NOW - 120)));

insert into task_runs (id, task_id, profile, status, started_at, ended_at, outcome, summary, error) values
 (41, 't_run_a', 'default', 'running', $((NOW - 300)),  null,         null,        null, null),
 (40, 't_run_a', 'default', 'done',    $((NOW - 3600)), $((NOW - 3000)), 'completed', 'the first attempt', null),
 (39, 't_run_a', 'default', 'crashed', $((NOW - 4000)), $((NOW - 3900)), 'crashed',   null, 'the worker died'),
 (38, 't_run_a', 'default', 'done',    $((NOW - 5000)), $((NOW - 4000)), 'timed_out', null, null),
 (36, 't_run_b', 'default', 'running', $((NOW - 150)),  null,         null,        null, null),
 (37, 't_blk_reason', 'default', 'done', $((NOW - 1200)), $((NOW - 1000)), 'blocked', null, null);
SQL
}

# <dir> - a throw-away bar project: bar itself plus every module of this repository
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in "$REPO_ROOT/Bar.d/"*; do
        ln -s "$module" "$1/Bar.d/${module##*/}"
    done
    cat >"$1/Barf" <<'BARF'
rule MAIN: -- true
BARF
}

# the root the helper resolves boards under, with a default board and a named one
ROOT="$WORK/root"
FIXTURE="$ROOT/kanban.db"
DEMO_BOARD="$ROOT/kanban/boards/demo/kanban.db"
mkdir -p "$ROOT/kanban/boards/demo"
mkboard "$FIXTURE"
mkboard "$DEMO_BOARD" empty

PROJ="$WORK/proj"
mkproject "$PROJ"

# The helper is invoked from a project of its own, the way a rule of an installed helper is: the
# board it reads is chosen by the environment and by its options, never by the cwd.  It is also
# what makes 'please kanban_state' work from a directory without any Bar.d at all (AC14).
kanban() { # <args..> - the helper against the fixture root
    OUT=""
    RC=0
    OUT="$(cd "$PROJ" && env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD \
        HERMES_KANBAN_HOME="$ROOT" \
        "$BAR" kanban_state "$@" 2>/dev/null)" || RC=$?
}

kanban_err() { # <args..>
    OUT=""
    RC=0
    OUT="$(cd "$PROJ" && env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD \
        HERMES_KANBAN_HOME="$ROOT" \
        "$BAR" kanban_state "$@" 2>&1 >/dev/null)" || RC=$?
}

status_counts="triage: 1, todo: 4, scheduled: 1, ready: 2, running: 2, blocked: 3, review: 1, done: 2"
empty_counts="tasks: 0 (triage: 0, todo: 0, scheduled: 0, ready: 0, running: 0, blocked: 0, review: 0, done: 0)"

# --------------------------------------------------------------------------------------------
# AC1  the summary: six lines, no card, exit 0
# --------------------------------------------------------------------------------------------
echo "--- AC1 the summary ---"
kanban
check "$RC" "0" "AC1: 'kanban_state' exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "6" "AC1: the summary is six lines"
check "$(sed -n 1p <<<"$OUT")" "board: default ($FIXTURE)" "AC1: the first line names the board and its database"
contains "$(sed -n 6p <<<"$OUT")" "active runs: 2" "AC1: the last line counts the live runs"
check "$(printf '%s\n' "$OUT" | grep -c '^t_[a-z0-9_]*  ' || true)" "0" \
    "AC1: not one line of the summary is a card line"
if (( $(bytes_of "$OUT") <= 512 )); then
    pass "AC1: the whole summary of a 16 card board is $(bytes_of "$OUT") B"
else
    fail "AC1: the summary is $(bytes_of "$OUT") B, over the 512 B budget"
fi

# --------------------------------------------------------------------------------------------
# AC2  the numbers: every status, the waiting totals, the age of the oldest ready card
# --------------------------------------------------------------------------------------------
echo "--- AC2 the counts ---"
check "$(grep -m1 '^tasks: ' <<<"$OUT")" "tasks: 16 ($status_counts)" \
    "AC2: the count line carries every status of the workflow (the archived card is not one)"
check "$(grep -m1 '^waiting: ' <<<"$OUT")" "waiting: ready 2, blocked 3, scheduled 1" \
    "AC2: the waiting line carries the actionable totals"
oldest="$(grep -m1 '^oldest ready: ' <<<"$OUT")"
contains "$oldest" "oldest ready: t_ready_a (" "AC2: the oldest ready card is named"
# the age is measured, so assert it within a tolerance instead of on a frozen number
age="$(printf '%s' "$oldest" | sed -n 's/.*, \([0-9]*\)s).*/\1/p')"
if [[ -n "$age" ]] && (( age >= OLDEST_READY_AGE - 5 && age <= OLDEST_READY_AGE + 5 )); then
    pass "AC2: its age is ${age}s (fixture: ${OLDEST_READY_AGE}s)"
else
    fail "AC2: its age is [$age]s, want about ${OLDEST_READY_AGE}s [$oldest]"
fi
contains "$(grep -m1 '^tasks: ' <<<"$OUT")" "todo: 4" "AC2: a status with a card of every shape is counted"
absent "$(grep -m1 '^tasks: ' <<<"$OUT")" "archived" "AC2: the archived card is not part of the counts"

# an empty board is an answer, not an error
kanban --board demo
check "$RC" "0" "AC2: an empty board exits 0"
check "$(grep -m1 '^tasks: ' <<<"$OUT")" "tasks: 0 (triage: 0, todo: 0, scheduled: 0, ready: 0, running: 0, blocked: 0, review: 0, done: 0)" \
    "AC2: an empty board counts zeros"
check "$(grep -m1 '^oldest ready: ' <<<"$OUT")" "oldest ready: none" "AC2: an empty board has no oldest ready card"

# --------------------------------------------------------------------------------------------
# AC3  --json carries the same numbers as the text form
# --------------------------------------------------------------------------------------------
echo "--- AC3 --json ---"
kanban --json
TEXT_SUMMARY="$(cd "$PROJ" && env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HERMES_KANBAN_HOME="$ROOT" "$BAR" kanban_state 2>/dev/null)"
check "$RC" "0" "AC3: '--json' exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "1" "AC3: the JSON form is one line"
if command -v jq >/dev/null; then
    check "$(printf '%s' "$OUT" | jq -r .bar_kanban_state)" "1" "AC3: the object identifies itself"
    check "$(printf '%s' "$OUT" | jq -r .tasks)" "16" "AC3: .tasks is the text total"
    check "$(printf '%s' "$OUT" | jq -r .by_status.todo)" "4" "AC3: .by_status carries the text counts"
    check "$(printf '%s' "$OUT" | jq -r '[.by_status[]] | add')" "16" "AC3: they add up to the total"
    check "$(printf '%s' "$OUT" | jq -r .active_runs)" "2" "AC3: .active_runs is the text number"
    check "$(printf '%s' "$OUT" | jq -r .ready)" \
        "$(sed -n 's/^waiting: ready \([0-9]*\),.*/\1/p' <<<"$TEXT_SUMMARY")" \
        "AC3: .ready is the first number of the waiting line"
    check "$(printf '%s' "$OUT" | jq -r .oldest_ready.id)" "t_ready_a" "AC3: the oldest ready card is named"
    json_age="$(printf '%s' "$OUT" | jq -r .oldest_ready.age_seconds)"
    if (( json_age >= OLDEST_READY_AGE - 5 && json_age <= OLDEST_READY_AGE + 5 )); then
        pass "AC3: the JSON age ${json_age}s matches the text age ${age}s"
    else
        fail "AC3: the JSON age [$json_age]s disagrees with the text age [${age}]s"
    fi
    kanban --json --board demo
    check "$(printf '%s' "$OUT" | jq -r .oldest_ready)" "null" "AC3: an empty board answers with null, not an error"
    check "$(printf '%s' "$OUT" | jq -r '[.by_status[]] | add')" "0" "AC3: and no counts"
else
    pass "AC3: jq is not installed, the JSON was only checked for its shape"
fi
run_in "$PROJ" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HERMES_KANBAN_HOME="$ROOT" \
    "$BAR" --json kanban_state --status ready
if command -v jq >/dev/null; then
    check "$(printf '%s' "$OUT" | jq -r .matched)" "2" "AC3: 'bar --json kanban_state' reaches the helper"
else
    pass "AC3: jq is not installed"
fi

# --------------------------------------------------------------------------------------------
# AC4  a selector lists the matching cards, one line each, then the count
# --------------------------------------------------------------------------------------------
echo "--- AC4 the listing ---"
kanban --status ready
check "$RC" "0" "AC4: a selector exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "3" "AC4: two matching cards and the count are three lines"
check "$(sed -n 3p <<<"$OUT")" "(2 cards)" "AC4: the count is an explicit line of its own"
line1="$(sed -n 1p <<<"$OUT")"
check "$(awk '{print $1}' <<<"$line1")" "t_ready_a" "AC4: the oldest card of the highest priority comes first"
check "$(awk '{print $2}' <<<"$line1")" "ready" "AC4: the line carries the status"
contains "$line1" "deps:0u/1d" "AC4: and the dependencies (one child, no unfinished parent)"
contains "$line1" "ready: the oldest, waiting half an hour" "AC4: and the title"
check "$(awk '{print $1}' <<<"$(sed -n 2p <<<"$OUT")")" "t_ready_b" "AC4: then the other match"

# the dependency count is unfinished parents, not all parents
kanban --id t_todo_free
contains "$OUT" "deps:0u/0d" "AC4: a parent in 'done' is not an open dependency"
kanban --id t_todo_dep
contains "$OUT" "deps:1u/0d" "AC4: a parent in 'ready' is one"
kanban --id t_ready_b
contains "$OUT" "deps:1u/0d" "AC4: and a parent which is running is one too"
kanban --id t_run_a
contains "$OUT" "run:#41" "AC4: a live run is named on the card line"

kanban --status running
check "$(awk '{print $1}' <<<"$(sed -n 1p <<<"$OUT")")" "t_run_a" "AC4: the highest priority runs first"

# several values in one selector, and several selectors at once
kanban --status ready,done --assignee worker
check "$(awk '{print $1}' <<<"$(sed -n 1p <<<"$OUT")")" "t_ready_b" \
    "AC4: a card can be selected by several statuses"
check "$(printf '%s\n' "$OUT" | tail -1)" "(1 cards)" "AC4: only the card of that assignee is left"
contains "$OUT" "t_ready_b" "AC4: and it is the right one"
kanban --status ready --assignee worker
contains "$OUT" "t_ready_b" "AC4: a repeated selector intersects"
absent "$OUT" "t_ready_a" "AC4: and drops the others"

# the project filter, and a title with a newline
kanban --project p_demo
check "$(printf '%s\n' "$OUT" | tail -1)" "(1 cards)" "AC4: --project selects by project id"
contains "$OUT" "t_proj_a" "AC4: and finds the card of that project"
kanban --id t_multiline
contains "$OUT" "title with a newline" "AC4: a title with a newline stays on one line"
check "$(printf '%s\n' "$OUT" | wc -l)" "2" "AC4: and does not break the record"

# --parent walks the links
kanban --parent t_done_b
check "$(printf '%s\n' "$OUT" | tail -1)" "(2 cards)" "AC4: --parent lists the children of a card"
contains "$OUT" "t_todo_free" "AC4: the first child"
contains "$OUT" "t_ready_a" "AC4: the second child"

# an empty result is an answer
kanban --assignee nobody
check "$RC" "0" "AC4: a filter matching nothing exits 0"
check "$OUT" "(0 cards)" "AC4: and says so on its count line"

# --------------------------------------------------------------------------------------------
# AC5  the limit, the elision counts and the file holding every match
# --------------------------------------------------------------------------------------------
echo "--- AC5 the limit ---"
kanban --status todo --limit 2
check "$RC" "0" "AC5: a limited listing exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "4" "AC5: two cards, the count and the file are four lines"
check "$(sed -n 3p <<<"$OUT")" "(2 of 4 cards)" "AC5: the elision counts are explicit"
contains "$(sed -n 4p <<<"$OUT")" "all 4 cards: " "AC5: and the complete answer is named"
FULL="$(printf '%s' "$(sed -n 4p <<<"$OUT")" | sed -n 's/^all 4 cards: //p')"
if [[ -f "$FULL" ]]; then
    pass "AC5: the file holding every match exists"
else
    fail "AC5: no file at [$FULL]"
fi
check "$(wc -l <"$FULL")" "4" "AC5: it holds one line per match"
contains "$(cat "$FULL")" "t_multiline" "AC5: including the cards the screen left out"

kanban --status ready
absent "$OUT" "all 2 cards" "AC5: a listing which elides nothing names no file"
kanban --status todo --all
check "$(printf '%s\n' "$OUT" | tail -1)" "(4 cards)" "AC5: '--all' lifts the limit"
absent "$OUT" "all 4 cards" "AC5: and elides nothing"

# --------------------------------------------------------------------------------------------
# AC6  why a blocked card is blocked
# --------------------------------------------------------------------------------------------
echo "--- AC6 blocked reasons ---"
kanban --status blocked
check "$(printf '%s\n' "$OUT" | wc -l)" "5" "AC6: three cards, the count and the complete file are five lines"
check "$(sed -n 4p <<<"$OUT")" "(3 cards)" "AC6: all three blocked cards are listed"
blocked_reason="$(printf '%s\n' "$OUT" | sed -n 's/.*\(t_blk_reason\).*/\1/p')"
check "$blocked_reason" "t_blk_reason" "AC6: the card with an event reason is listed"
check "$(awk '{print $1}' <<<"$(sed -n 1p <<<"$OUT")")" "t_blk_reason" \
    "AC6: the card with the highest priority comes first"
contains "$(sed -n 1p <<<"$OUT")" "${REASON_FULL:0:120}..." \
    "AC6: the newest event reason is the one shown, shortened on the card line"
contains "$(sed -n 1p <<<"$OUT")" "blocked[needs_input]" "AC6: the block kind is named"
contains "$(sed -n 2p <<<"$OUT")" "spawn failed: no such profile" \
    "AC6: a card without an event reason falls back to its failure excerpt"
contains "$(sed -n 3p <<<"$OUT")" "no reason recorded" \
    "AC6: a card with neither says so instead of printing nothing"
FULL="$(printf '%s' "$(sed -n 5p <<<"$OUT")" | sed -n 's/^all 3 cards: //p')"
if [[ -f "$FULL" ]]; then
    pass "AC6: a shortened reason makes the helper name the file holding every match"
else
    fail "AC6: no file at [$FULL]"
fi
check "$(wc -l <"$FULL")" "3" "AC6: with one line per blocked card"
contains "$(sed -n 1p <"$FULL")" "$REASON_FULL" \
    "AC6: and the reason in it is complete, not shortened"
if command -v jq >/dev/null; then
    kanban --status blocked --json
    check "$(printf '%s' "$OUT" | jq -r '.cards[] | select(.id=="t_blk_reason") | .blocked.kind')" "needs_input" \
        "AC6: the JSON carries the block kind"
    check "$(printf '%s' "$OUT" | jq -r '.cards[] | select(.id=="t_blk_reason") | .blocked.reason')" \
        "$REASON_FULL" "AC6: and the untruncated reason"
    check "$(printf '%s' "$OUT" | jq -r '.cards[] | select(.id=="t_blk_bare") | .blocked.reason')" \
        "no reason recorded" "AC6: and the placeholder where there is none"
fi

# --------------------------------------------------------------------------------------------
# AC7  the runs of one card
# --------------------------------------------------------------------------------------------
echo "--- AC7 the runs ---"
kanban --runs t_run_a
check "$RC" "0" "AC7: '--runs' exits 0"
check "$(sed -n 1p <<<"$OUT")" "runs for t_run_a (running) running: has four runs" "AC7: the header names the card"
check "$(printf '%s\n' "$OUT" | wc -l)" "8" "AC7: four runs, the workspace, the failure count and the total"
check "$(awk '{print $1}' <<<"$(sed -n 2p <<<"$OUT")")" "#41" "AC7: the newest run comes first"
contains "$(sed -n 2p <<<"$OUT")" "running" "AC7: with its state"
contains "$(sed -n 2p <<<"$OUT")" "-> -" "AC7: a live run has no end"
contains "$(sed -n 3p <<<"$OUT")" "completed" "AC7: a finished run carries its outcome"
contains "$(sed -n 3p <<<"$OUT")" "10m0s" "AC7: and its duration"
check "$(sed -n 6p <<<"$OUT")" "workspace: worktree /w/t_run_a (branch wt/t_run_a)" \
    "AC7: the workspace of the card is stated"
check "$(sed -n 7p <<<"$OUT")" "failed: 2" "AC7: the failure count is its own line"
check "$(sed -n 8p <<<"$OUT")" "(4 runs)" "AC7: the total is the last line"

kanban --runs t_run_a --json
if command -v jq >/dev/null; then
    check "$(printf '%s' "$OUT" | jq -r .matched)" "4" "AC7: the JSON total matches the text"
    check "$(printf '%s' "$OUT" | jq -r .failed)" "2" "AC7: the JSON failure count matches"
    check "$(printf '%s' "$OUT" | jq -r .task.workspace_path)" "/w/t_run_a" "AC7: the JSON carries the workspace"
    check "$(printf '%s' "$OUT" | jq -r '.runs[1].duration_seconds')" "600" "AC7: and a duration in seconds"
else
    pass "AC7: jq is not installed"
fi

kanban --runs t_blk_reason
check "$(printf '%s\n' "$OUT" | tail -1)" "(1 runs)" "AC7: a card with a single run says one"
check "$(sed -n 4p <<<"$OUT")" "failed: 0" "AC7: a card without a failure says zero"
kanban --runs t_triage_a
check "$(printf '%s\n' "$OUT" | tail -1)" "(0 runs)" "AC7: a card which never ran is an answer, not an error"

# --------------------------------------------------------------------------------------------
# AC8  the exit codes
# --------------------------------------------------------------------------------------------
echo "--- AC8 exit codes ---"
kanban --nonsense
check "$RC" "2" "AC8: an unknown argument exits 2"
check "$OUT" "" "AC8: and leaves stdout alone"
kanban --status
check "$RC" "2" "AC8: a selector without a value exits 2"

# an empty value is no value either: every option that takes one refuses it the same way.  '--id'
# used to answer '(0 cards)' and '--parent' exit 4 on the same input, and an empty '--runs' used to
# be dropped and answered with the whole summary -- silence is the one answer none of them may give.
for opt in --status --assignee --project --parent --id --runs --limit --db --board; do
    kanban "$opt" ""
    check "$RC" "2" "AC8: '$opt' with an empty value exits 2"
    check "$OUT" "" "AC8: '$opt' with an empty value leaves stdout alone"
done
kanban --id=
check "$RC" "2" "AC8: an empty '--id=' after the '=' exits 2 as well"
kanban_err --id ""
contains "$OUT" "'--id' needs a non-empty value" "AC8: and the report names the option"
kanban_err --runs ""
contains "$OUT" "'--runs' needs a non-empty value" "AC8: '--runs' included"

kanban --limit x
check "$RC" "2" "AC8: a non numeric limit exits 2"
kanban --board 'Not A Slug'
check "$RC" "2" "AC8: an invalid board slug exits 2"
kanban --runs t_run_a --status ready
check "$RC" "2" "AC8: '--runs' with a selector exits 2"
kanban_err --nonsense
contains "$OUT" "usage: kanban_state" "AC8: the usage goes to stderr"

kanban --db "$WORK/does-not-exist.db"
check "$RC" "3" "AC8: a missing database exits 3"
: >"$WORK/empty.db"
kanban --db "$WORK/empty.db"
check "$RC" "3" "AC8: a database without a tasks table exits 3"
kanban_err --db "$WORK/empty.db"
contains "$OUT" "not a Kanban database" "AC8: and says why"

kanban --id t_no_such_card
check "$RC" "4" "AC8: an unknown card for '--id' exits 4"
kanban --runs t_no_such_card
check "$RC" "4" "AC8: an unknown card for '--runs' exits 4"
kanban --parent t_no_such_card
check "$RC" "4" "AC8: an unknown card for '--parent' exits 4"
kanban_err --parent t_no_such_card
contains "$OUT" "no card t_no_such_card on board default" "AC8: and names the card and the board"

kanban --help
check "$RC" "0" "AC8: '--help' exits 0"
contains "$OUT" "usage: kanban_state" "AC8: and prints the usage on stdout"

# --------------------------------------------------------------------------------------------
# AC9  the board is resolved like the kernel resolves it
# --------------------------------------------------------------------------------------------
echo "--- AC9 board resolution ---"
kanban --board default
check "$(grep -m1 '^tasks: ' <<<"$OUT")" "tasks: 16 ($status_counts)" "AC9: '--board default' is the default board"
kanban --board demo
check "$(sed -n 1p <<<"$OUT")" "board: demo ($DEMO_BOARD)" "AC9: a named board is read from its own directory"
kanban --db "$DEMO_BOARD"
check "$(sed -n 1p <<<"$OUT")" "board: demo ($DEMO_BOARD)" \
    "AC9: '--db' is named after the board it points at"
kanban --db "$WORK/somewhere-else.db"
check "$RC" "3" "AC9: a database of its own is only reached by '--db'"

run_in "$PROJ" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HERMES_KANBAN_HOME="$ROOT" \
    HERMES_KANBAN_BOARD=demo "$BAR" kanban_state
check "$RC" "0" "AC9: '\$HERMES_KANBAN_BOARD' is honoured"
check "$(grep -m1 '^tasks: ' <<<"$OUT")" "$empty_counts" \
    "AC9: and it resolved the empty demo board"
check "$(sed -n 1p <<<"$OUT")" "board: demo ($DEMO_BOARD)" "AC9: naming it as such"

run_in "$PROJ" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HERMES_KANBAN_HOME="$ROOT" \
    HERMES_KANBAN_DB="$DEMO_BOARD" "$BAR" kanban_state
check "$(sed -n 1p <<<"$OUT")" "board: demo ($DEMO_BOARD)" "AC9: '\$HERMES_KANBAN_DB' pins the database"
check "$(grep -m1 '^tasks: ' <<<"$OUT")" "$empty_counts" \
    "AC9: of the empty demo board, not of the default one"

printf 'demo\n' >"$ROOT/kanban/current"
run_in "$PROJ" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HERMES_KANBAN_HOME="$ROOT" \
    "$BAR" kanban_state
check "$(sed -n 1p <<<"$OUT")" "board: demo ($DEMO_BOARD)" "AC9: '<root>/kanban/current' is the fallback"
rm -f "$ROOT/kanban/current"
run_in "$PROJ" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HERMES_KANBAN_HOME="$ROOT" \
    "$BAR" kanban_state
check "$(sed -n 1p <<<"$OUT")" "board: default ($FIXTURE)" "AC9: without it the default board is read"

# --------------------------------------------------------------------------------------------
# AC10 the JSON survives quotes, pipes, backslashes and control characters
# --------------------------------------------------------------------------------------------
echo "--- AC10 escaping ---"
if command -v jq >/dev/null; then
    kanban --id t_triage_a --json
    check "$(printf '%s' "$OUT" | jq -r '.cards[0].title')" "$TITLE_TRIAGE" \
        "AC10: a title with a quote, a pipe and a backslash survives unchanged"
    kanban --id t_multiline --json
    check "$(printf '%s' "$OUT" | jq -r '.cards[0].title')" "title with a newline" \
        "AC10: a newline in a title does not split the JSON string"
    kanban --json
    printf '%s' "$OUT" | jq -e . >/dev/null && pass "AC10: every form of the JSON validates" ||
        fail "AC10: the JSON does not validate"
else
    pass "AC10: jq is not installed, escaping was not verified"
fi

# --------------------------------------------------------------------------------------------
# AC11 the module reaches 'bar help', AC12 the repertoire registration
# --------------------------------------------------------------------------------------------
echo "--- AC11/AC12 help and the repertoire ---"
run_bar "$PROJ" help
contains "$OUT" "Hermes Kanban board state" "AC11: the module header prose is in 'bar help'"
contains "$OUT" "kanban - " "AC11: as the module's own block"
run_bar "$PROJ" helpers
contains "$OUT" "kanban_state" "AC12: the repertoire lists the helper"
run_bar "$PROJ" helpers --check
check "$RC" "0" "AC12: the registration guard accepts the module"
check "$OUT" "" "AC12: and says nothing when there is nothing to say"
run_bar "$PROJ" check helpers_check
check "$RC" "0" "AC12: the guard is green as a 'bar check' target"
check "$OUT" "OK helpers_check" "AC12: and is one line there"

# the helper runs from a project of its own, not only from this checkout
run_bar "$PROJ" kanban_state --db "$FIXTURE"
check "$RC" "0" "AC12: the helper resolves and runs from another project"

# --------------------------------------------------------------------------------------------
# AC13 determinism
# --------------------------------------------------------------------------------------------
echo "--- AC13 determinism ---"
kanban --status ready
first="$OUT"
kanban --status ready
check "$OUT" "$first" "AC13: two listings of the same question agree"

# the wall clock and the age of the oldest ready card move between two runs; every other number
# must not
settle() {
    sed -E -e 's/^as of: .*/as of: X/' -e 's/\(([0-9]+[dhms])+, [0-9]+s\)/(age)/' \
        -e 's/"now":[0-9]+/"now":0/' -e 's/"age_seconds":[0-9]+/"age_seconds":0/'
}
kanban --json
first="$(printf '%s' "$OUT" | settle)"
kanban --json
check "$(printf '%s' "$OUT" | settle)" "$first" "AC13: two summaries agree on every number"
kanban
first="$(printf '%s' "$OUT" | settle)"
kanban
check "$(printf '%s' "$OUT" | settle)" "$first" "AC13: and so do two runs of the text summary"

# --------------------------------------------------------------------------------------------
# AC14 'please' from an arbitrary directory: the acceptance criterion of the card
# --------------------------------------------------------------------------------------------
echo "--- AC14 an installed 'please' ---"
FAKE_HOME="$WORK/home"
SITE="$WORK/site"
mkdir -p "$FAKE_HOME/.local" "$SITE/Bar.d" "$SITE/contrib"
cp "$BAR" "$SITE/bar"
cp "$REPO_ROOT/Barf.default" "$REPO_ROOT/Pleasef.default" "$SITE/"
cp "$REPO_ROOT/contrib/bar_complete" "$SITE/contrib/"
for module in "$REPO_ROOT/Bar.d/"*; do
    ln -s "$module" "$SITE/Bar.d/${module##*/}"
done
(cd "$SITE" && HOME="$FAKE_HOME" ./bar init_install "$FAKE_HOME/.local" >/dev/null 2>&1) || true
if [[ -x "$FAKE_HOME/.local/bin/please" ]]; then
    pass "AC14: the installation provides 'please'"
else
    fail "AC14: no 'please' at $FAKE_HOME/.local/bin/please"
fi
run_in "$WORK" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HOME="$FAKE_HOME" \
    HERMES_KANBAN_HOME="$ROOT" "$FAKE_HOME/.local/bin/please" kanban_state
check "$RC" "0" "AC14: 'please kanban_state' from an arbitrary directory exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "6" "AC14: and prints the six line summary"
check "$(grep -m1 '^tasks: ' <<<"$OUT")" "tasks: 16 ($status_counts)" "AC14: of the board it resolved"
run_in "$WORK" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HOME="$FAKE_HOME" \
    HERMES_KANBAN_HOME="$ROOT" "$FAKE_HOME/.local/bin/please" kanban_state --status blocked
check "$(printf '%s\n' "$OUT" | tail -2 | head -1)" "(3 cards)" "AC14: and a filter too"
run_in "$WORK" env -u HERMES_KANBAN_DB -u HERMES_KANBAN_BOARD HOME="$FAKE_HOME" \
    "$FAKE_HOME/.local/bin/please" kanban_state
check "$RC" "3" "AC14: with no board at all it fails fast, exit 3"
check "$OUT" "" "AC14: and says nothing on stdout"

echo
if (( failures == 0 )); then
    echo "=== All Kanban board state tests passed ==="
else
    echo "=== $failures Kanban board state assertion(s) FAILED ==="
    exit 1
fi
