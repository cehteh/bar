#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the Hermes log corpus helper (Bar.d/hermes, rule 'hermes_logs').
#
# Everything runs against a throw-away corpus and a throw-away installation, so nothing here depends
# on this host's real Hermes home.  The corpus carries one of every source kind, a compressed log, a
# store with a real 'messages' table, records with and without timestamps, an old record, a 400
# character line and a record with an ANSI escape and a carriage return.  Covered:
#
#   AC1  a grep over the corpus: bounded digest, the exact total, exit 0
#   AC2  the exact count is a hard assertion: it equals an independently counted number, per source
#   AC3  '--count' prints the number alone; elided output always prints the full-match file path
#   AC4  every printed locator retrieves its line, and the full-match file holds every match
#   AC5  '--json' is one valid object, jq clean, with the same numbers as the text form
#   AC6  '--since' as a duration and as an absolute time; a source without timestamps is dated by mtime
#   AC7  '--source' restricts to a kind; '--task' prunes to one worker transcript; '--session' filters
#   AC8  the store is scanned read only, row per content line, with the message's own timestamp
#   AC9  a compressed source is read transparently
#   AC10 exit codes: 0 answered / 3 no match / 2 usage error / 1 a source could not be read
#   AC11 the corpus root: '--root' wins, BAR_HERMES_LOGS_ROOT and $HERMES_HOME are the fallback
#   AC12 '--limit' bounds the digest; two runs are identical and reuse one retrieval file
#   AC13 the answer stays bounded (well under 2 KB) for a query matching every line
#   AC14 a snippet carries no control character and says what it left out
#   AC15 registration: the index lists the helper, the guard passes, 'bar help' has the module prose
#   AC16 reachability: the helper runs through 'please' from an arbitrary directory
#
# The suite needs 'gzip' and 'sqlite3'; the tests of the source they serve are skipped without them.

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
digest_lines() { # the match lines of the last digest, without its footer
    printf '%s\n' "$1" | sed -n '1,/^corpus: /p' | grep -vc '^corpus: '
}
has() { command -v "$1" >/dev/null; }

echo "=== Testing the Hermes log corpus helper (Bar.d/hermes) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT=""
RC=0
run() { # <args..> - run the helper from the repository, without bar's own stderr chatter
    OUT=""
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BAR" hermes_logs "$@" 2>/dev/null)" || RC=$?
}
run_err() { # <args..> - capture stderr instead
    OUT=""
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BAR" hermes_logs "$@" 2>&1 >/dev/null)" || RC=$?
}
count_of() { # <args..> - the helper's count, on stdout alone
    local out
    out="$(cd "$REPO_ROOT" && "$BAR" hermes_logs "$@" --count 2>/dev/null)" || true
    printf '%s' "$out"
}

# --------------------------------------------------------------------------------------------
# the corpus
# --------------------------------------------------------------------------------------------

NOW="$(date -d '-1 hour' '+%Y-%m-%d %H:%M:%S')"
JSONSTAMP="$(date -d '-59 minutes' '+%Y-%m-%d %H:%M:%S')"
OLD="$(date -d '-3 days' '+%Y-%m-%d %H:%M:%S')"
EPOCH_NOW="$(date -d "$NOW" +%s)"
EPOCH_OLD="$(date -d "$OLD" +%s)"

# <dir> - a throw-away Hermes home carrying every source kind this helper knows.
# 18 records match 'needle': 8 in logs/agent.log, 1 in the rotated log, 3 worker transcripts,
# 2 cron run outputs, 1 jsonl session record and 3 content lines of the store.
mkcorpus() {
    local root="$1"
    mkdir -p "$root/logs" "$root/kanban/logs" "$root/cron/output/job1" "$root/sessions"
    {
        printf '%s,000 INFO [sess-old] agent.loop: needle from an old record\n' "$OLD"
        printf '%s,000 INFO [sess-new] agent.loop: needle fresh record\n' "$NOW"
        printf '   %s,000 WARNING [sess-new] agent.loop: needle indented record\n' "$NOW"
        printf 'continuation of the record above: needle without a stamp\n'
        printf '%s,000 INFO [sess-new] agent.loop: needle %s\n' "$NOW" \
            "$(head -c 400 /dev/zero | tr '\0' 'x')"
        printf '%s,000 INFO [sess-new] agent.loop: needle ansi \033[31mred\033[0m\n' "$NOW"
        printf '%s,000 INFO [sess-new] agent.loop: needle carriage return\r\n' "$NOW"
        printf '{"role": "assistant", "content": "needle json record", "timestamp": "%s"}\n' "$JSONSTAMP"
    } >"$root/logs/agent.log"
    printf '%s,000 INFO [sess-new] agent.loop: needle from a rotated log\n' "$NOW" >"$root/logs/rotated.log"
    if has gzip; then
        gzip -c "$root/logs/rotated.log" >"$root/logs/rotated.log.gz"
        rm -f "$root/logs/rotated.log"
    fi
    printf 'Query: work kanban task t_deadbeef\nneedle worker record one\nneedle worker record two\n' \
        >"$root/kanban/logs/t_deadbeef.log"
    printf 'Query: work kanban task t_cafe0123\nneedle worker record three\n' \
        >"$root/kanban/logs/t_cafe0123.log"
    printf '## Response\nneedle cron record\n' >"$root/cron/output/job1/2026-01-01_09-00-00.md"
    printf 'needle flat cron record\n' >"$root/cron/output/legacy_job_2026-01-01.txt"
    printf '{"role": "user", "content": "needle session record", "timestamp": "%s"}\n' "$NOW" \
        >"$root/sessions/sess-new.jsonl"
    if has sqlite3; then
        sqlite3 "$root/state.db" \
            "create table messages (session_id text, id integer, timestamp real, content text);
             insert into messages values ('sess-new', 1, $EPOCH_NOW, 'needle store record');
             insert into messages values ('sess-old', 2, $EPOCH_OLD, 'needle old store record');
             insert into messages values ('sess-new', 3, $EPOCH_NOW, 'needle store second content line');
             insert into messages values ('sess-new', 4, $EPOCH_NOW, '');" >/dev/null
    fi
}

CORPUS="$WORK/hermes"
mkcorpus "$CORPUS"
export BAR_HERMES_LOGS_DIR="$WORK/max"

# the independent expectations: a plain filesystem sweep plus a SQL count, never this module's code
EXPECT_WORKERS="$(cat "$CORPUS/kanban/logs/"*.log 2>/dev/null | grep -c needle)"
EXPECT_SESSIONS="$(cat "$CORPUS/sessions/"*.jsonl 2>/dev/null | grep -c needle)"
EXPECT_CRON="$(find "$CORPUS/cron/output" -type f -exec cat {} + 2>/dev/null | grep -c needle)"
EXPECT_LOGS="$(cat "$CORPUS/logs/"*.log 2>/dev/null | grep -c needle)"
if has gzip && [[ -f "$CORPUS/logs/rotated.log.gz" ]]; then
    EXPECT_LOGS=$(( EXPECT_LOGS + $(gzip -dc "$CORPUS/logs/rotated.log.gz" | grep -c needle) ))
fi
EXPECT_STORE=0
if has sqlite3 && [[ -f "$CORPUS/state.db" ]]; then
    EXPECT_STORE="$(sqlite3 -readonly "$CORPUS/state.db" \
        "select sum(case when instr(content, 'needle') > 0 then 1 else 0 end) from messages;")"
fi
EXPECT_FILES=$(( EXPECT_LOGS + EXPECT_WORKERS + EXPECT_CRON + EXPECT_SESSIONS ))
EXPECT_ALL=$(( EXPECT_FILES + EXPECT_STORE ))
check "$EXPECT_LOGS" "9" "fixture: the independent sweep finds 9 matching log lines (8 plus the rotated log)"
check "$EXPECT_FILES" "15" "fixture: 15 matching lines outside the store"
# sqlite3 is optional (see the header): without it the store is not a source, so every number below
# that the store contributes to is derived, never spelled out.
if has sqlite3; then
    check "$EXPECT_STORE" "3" "fixture: 3 matching content lines in the store"
    check "$EXPECT_ALL" "18" "fixture: 18 matching records in the whole corpus"
else
    check "$EXPECT_ALL" "15" "fixture: 15 matching records (no sqlite3, the store is not a source)"
fi
SOURCES="logs workers cron sessions"
SOURCES_CSV="logs,workers,cron,sessions"
if has sqlite3; then
    SOURCES="$SOURCES store"
    SOURCES_CSV="$SOURCES_CSV,store"
fi
# two records are older than a day: one log line, and one store row when the store is scanned
EXPECT_RECENT=$(( EXPECT_ALL - 1 - (EXPECT_STORE > 0 ? 1 : 0) ))
# the AC13 query is '.', which matches every non empty line of every source: an independent sweep
EXPECT_DOT_STORE=0
if has sqlite3; then
    EXPECT_DOT_STORE="$(sqlite3 -readonly "$CORPUS/state.db" \
        "select count(*) from messages where length(content) > 0;")"
fi
EXPECT_DOT_FILES=0
for f in "$CORPUS"/logs/*.log "$CORPUS"/kanban/logs/*.log "$CORPUS"/sessions/*.jsonl; do
    [[ -f "$f" ]] && EXPECT_DOT_FILES=$(( EXPECT_DOT_FILES + $(grep -c '.' "$f") ))
done
if has gzip; then
    for f in "$CORPUS"/logs/*.log.gz; do
        [[ -f "$f" ]] && EXPECT_DOT_FILES=$(( EXPECT_DOT_FILES + $(gzip -dc "$f" | grep -c '.') ))
    done
fi
EXPECT_DOT_FILES=$(( EXPECT_DOT_FILES + $(find "$CORPUS/cron/output" -type f -exec cat {} + 2>/dev/null | grep -c '.') ))
EXPECT_DOT_ALL=$(( EXPECT_DOT_FILES + EXPECT_DOT_STORE ))

# --------------------------------------------------------------------------------------------
# AC1  a grep over the corpus: bounded digest, exact total, exit 0
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep needle --since 1d
check "$RC" "0" "AC1: '--grep needle --since 1d' exits 0"
contains "$OUT" "matches: $EXPECT_RECENT" "AC1: the exact total ($EXPECT_ALL minus the two records older than a day)"
contains "$OUT" "of $EXPECT_RECENT (limit 20 lines, 1200 chars)" \
    "AC1: the digest is bounded by the line limit and the byte budget, and says so"
contains "$OUT" "max: " "AC1: and an elided answer names the full match list"
absent "$OUT" "unreadable:" "AC1: every source was readable"
contains "$OUT" "corpus: $CORPUS [$SOURCES]" \
    "AC1: the 'corpus:' line names the root and the sources it scanned"
contains "$OUT" "clipped: 1 snippet(s) at 160 chars" "AC1: the totals are lines of their own"
if (( $(digest_lines "$OUT") <= EXPECT_RECENT )); then
    pass "AC1: the digest holds $(digest_lines "$OUT") of the $EXPECT_RECENT records (budget 1200 chars)"
else
    fail "AC1: the digest holds more records than the corpus has"
fi

check "$(count_of --root "$CORPUS" --grep needle --since 1d --source logs)" "8" \
    "AC1: the logs source contributes 8 records in that range (9 less the old one)"

# an answer that shows everything needs no retrieval handle and no truncation line
run --root "$CORPUS" --grep 'needle fresh record'
check "$(digest_lines "$OUT")" "1" "AC1: a narrow query shows all its records"
absent "$OUT" "shown:" "AC1: a complete answer prints no truncation line"
absent "$OUT" "max:" "AC1: and no 'max:' handle"

# --------------------------------------------------------------------------------------------
# AC2  the exact count is a hard assertion
# --------------------------------------------------------------------------------------------
check "$(count_of --root "$CORPUS" --grep needle)" "$EXPECT_ALL" \
    "AC2: the count equals the independent filesystem sweep"
check "$(count_of --root "$CORPUS" --grep needle --source logs)" "$EXPECT_LOGS" \
    "AC2: '--source logs' counts every log line, the compressed source included"
check "$(count_of --root "$CORPUS" --grep needle --source sessions)" "$EXPECT_SESSIONS" \
    "AC2: the jsonl session records are counted per line"
if has sqlite3; then
    check "$(count_of --root "$CORPUS" --grep needle --source store)" "$EXPECT_STORE" \
        "AC2: '--source store' counts the matching content lines of the store"
fi
check "$(count_of --root "$CORPUS" --grep needle --source workers)" "$EXPECT_WORKERS" \
    "AC2: the worker transcripts contribute three records"
check "$(count_of --root "$CORPUS" --grep needle --source cron)" "$EXPECT_CRON" \
    "AC2: the cron run outputs contribute two records"
check "$(count_of --root "$CORPUS" --grep 'needle (fresh|indented)')" "2" \
    "AC2: the pattern is an extended regular expression, not a fixed string"
check "$(count_of --root "$CORPUS" --grep 'NEEDLE' -i)" "$EXPECT_ALL" \
    "AC2: '--ignore-case' finds the same records"
check "$(count_of --root "$CORPUS" --grep 'exit\][[:space:]]rc=1')" "0" \
    "AC2: a backslash in the pattern reaches the matcher unchanged (no '-v' escape mangling)"

# --------------------------------------------------------------------------------------------
# AC3  '--count' prints the number alone; elided output prints the full-match file path
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep needle --count
check "$RC" "0" "AC3: '--count' exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "1" "AC3: '--count' is one line"
check "$OUT" "$EXPECT_ALL" "AC3: '--count' prints the number and nothing else"
check "$(count_of --root "$CORPUS" --grep needle --json)" "$EXPECT_ALL" \
    "AC3: '--count' wins over '--json' (a number is already machine readable)"

run --root "$CORPUS" --grep needle --limit 4
contains "$OUT" "shown: 4 of $EXPECT_ALL (limit 4 lines, 1200 chars)" \
    "AC3: the digest is bounded and says how much it withheld"
contains "$OUT" "max: " "AC3: elided output prints the full-match file path"
MAX="$(printf '%s\n' "$OUT" | sed -n 's/^max: \([^ ]*\).*/\1/p')"
if [[ -f "$MAX" ]]; then pass "AC3: the printed path exists"; else fail "AC3: no file at [$MAX]"; fi
check "$(wc -l <"$MAX")" "$EXPECT_ALL" "AC3: the file holds every match, not the four it printed"

# --------------------------------------------------------------------------------------------
# AC4  every locator retrieves its line
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep 'needle fresh' --limit 1
LOCATOR="$(printf '%s\n' "$OUT" | sed -n 1p | cut -f1)"
check "$LOCATOR" "logs/agent.log:2" "AC4: the locator is '<path relative to the root>:<line>'"
check "$(sed -n "${LOCATOR##*:}p" "$CORPUS/${LOCATOR%:*}" | grep -c 'needle fresh')" "1" \
    "AC4: 'sed -n <line>p <root>/<path>' retrieves the matching line"
run --root "$CORPUS" --grep 'needle fresh' --json --limit 1
STAMP="$(printf '%s' "$OUT" | sed -n 's/.*"timestamp":"\([^"]*\)".*/\1/p')"
check "$STAMP" "$NOW" "AC4: the record carries the timestamp of its line"
if has sqlite3; then
    run --root "$CORPUS" --source store --grep 'needle store record' --limit 1
    SLOCATOR="$(printf '%s\n' "$OUT" | sed -n 1p | cut -f1)"
    check "$SLOCATOR" "state.db:sess-new/1/1" "AC4: a store record locates session, message and line"
    SMATCH="$(sqlite3 -readonly "$CORPUS/state.db" \
        "select content from messages where id=$(printf '%s' "$SLOCATOR" | cut -d/ -f2);" \
        | grep -c 'needle store record')"
    check "$SMATCH" "1" "AC4: the store locator resolves to the record it names"
fi

# --------------------------------------------------------------------------------------------
# AC5  '--json' is one valid object with the same numbers
# --------------------------------------------------------------------------------------------
if has jq; then
    run --root "$CORPUS" --grep needle --since 1d --limit 5 --json
    check "$RC" "0" "AC5: '--json' exits 0"
    check "$(printf '%s\n' "$OUT" | wc -l)" "1" "AC5: '--json' is one line"
    if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
        pass "AC5: jq accepts the object"
    else
        fail "AC5: jq rejects [$OUT]"
    fi
    check "$(printf '%s' "$OUT" | jq -r '.bar_hermes_logs')" "1" "AC5: the object identifies itself"
    check "$(printf '%s' "$OUT" | jq -r '.matches')" "$EXPECT_RECENT" "AC5: the JSON total is the text total"
    check "$(printf '%s' "$OUT" | jq -r '.shown')" "5" "AC5: 'shown' is the bounded digest size"
    check "$(printf '%s' "$OUT" | jq -r '.limit')" "5" "AC5: the object carries the limit it used"
    check "$(printf '%s' "$OUT" | jq -r '.unreadable')" "0" "AC5: nothing was unreadable"
    check "$(printf '%s' "$OUT" | jq -r '.hits | length')" "5" "AC5: the hits array is the digest"
    check "$(printf '%s' "$OUT" | jq -r '.hits[0].locator')" "logs/agent.log:2" \
        "AC5: the first hit is the first digest line"
    check "$(printf '%s' "$OUT" | jq -r '.hits[0].exact')" "true" \
        "AC5: a stamp taken from the line is marked exact"
    check "$(printf '%s' "$OUT" | jq -r '.sources | join(",")')" "$SOURCES_CSV" \
        "AC5: the sources are named in the corpus order"
    check "$(printf '%s' "$OUT" | jq -r '.roots | length')" "1" "AC5: the object names its corpus root"
    ## The helper resolves its own 'date -d "-1 day"' while it runs; comparing that against a
    ## second 'date' call of this test is a clock race which failed whenever the two calls
    ## straddled a second boundary (measured: '2026-10-10 01:34:16' against '...:17').  Assert
    ## the window the cutoff must fall in instead, which is what the answer means.
    SINCE="$(printf '%s' "$OUT" | jq -r '.since')"
    SINCE_AGE=$(( $(date '+%s') - $(date -d "$SINCE" '+%s') ))
    if (( SINCE_AGE >= 86400 && SINCE_AGE <= 86405 )); then
        pass "AC5: the resolved cutoff is part of the answer (${SINCE}, ${SINCE_AGE}s back)"
    else
        fail "AC5: the resolved cutoff is ${SINCE}, ${SINCE_AGE}s back (want one day)"
    fi
    ABSENT="$(printf '%s' "$OUT" | jq -r '.max')"
    if [[ -f "$ABSENT" ]]; then pass "AC5: the object carries the retrieval handle"; else fail "AC5: no file at [$ABSENT]"; fi
    run --root "$CORPUS" --grep needle --json --count
    check "$OUT" "$EXPECT_ALL" "AC5: '--json --count' still answers with the number"
    OUT="$(cd "$REPO_ROOT" && "$BAR" --json hermes_logs --root "$CORPUS" --grep 'needle fresh' 2>/dev/null)" || RC=$?
    check "$(printf '%s' "$OUT" | jq -r '.hits | length' 2>/dev/null)" "1" \
        "AC5: 'bar --json hermes_logs' is the machine form too"
else
    pass "AC5: jq is not installed, the JSON assertions are skipped"
fi

# --------------------------------------------------------------------------------------------
# AC6  '--since', and a source without timestamps is dated by its mtime
# --------------------------------------------------------------------------------------------
check "$(count_of --root "$CORPUS" --grep 'from an old record' --since 1d)" "0" \
    "AC6: a record older than the range is dropped"
check "$(count_of --root "$CORPUS" --grep 'from an old record')" "1" \
    "AC6: and is found without a range"
if has sqlite3; then
    check "$(count_of --root "$CORPUS" --source store --grep 'old store record' --since 1d)" "0" \
        "AC6: the range reaches the store (SQL) too"
    check "$(count_of --root "$CORPUS" --source store --grep 'old store record')" "1" \
        "AC6: and its old record is there without one"
fi
check "$(count_of --root "$CORPUS" --grep needle --since "$(date -d '-2 hours' '+%Y-%m-%d %H:%M:%S')")" "$EXPECT_RECENT" \
    "AC6: an absolute '--since' works like the duration"
run --root "$CORPUS" --grep 'without a stamp' --limit 1
contains "$OUT" "$NOW" "AC6: a record without a stamp inherits the stamp above it"
run --root "$CORPUS" --grep 'needle json record' --limit 1
contains "$OUT" "$JSONSTAMP" "AC6: a JSON record's own stamp is used, not the stamp above it"
run --root "$CORPUS" --grep 'worker record one' --limit 1
contains "$OUT" "	~" "AC6: the stamp of a source without timestamps is marked as derived"
touch -d '3 days ago' "$CORPUS/kanban/logs/t_deadbeef.log"
check "$(count_of --root "$CORPUS" --grep 'worker record' --since 1d)" "1" \
    "AC6: a transcript older than the range is dropped by its mtime"
check "$(count_of --root "$CORPUS" --grep 'worker record' --since 1w)" "3" \
    "AC6: and comes back in a wider range"

# --------------------------------------------------------------------------------------------
# AC7  '--source', '--task' and '--session'
# --------------------------------------------------------------------------------------------
check "$(count_of --root "$CORPUS" --grep needle --source workers --source cron)" "5" \
    "AC7: '--source' is repeatable"
run --root "$CORPUS" --task t_cafe0123 --grep 'worker record'
contains "$OUT" "corpus: $CORPUS [workers]" "AC7: '--task' keeps one worker transcript"
contains "$OUT" "matches: 1" "AC7: and counts only the records of that transcript"
check "$(count_of --root "$CORPUS" --task t_deadbeef --grep 'worker record')" "2" \
    "AC7: another task selects its own transcript"
check "$(count_of --root "$CORPUS" --run legacy --grep needle)" "1" \
    "AC7: '--run' selects the cron output of one run"
check "$(count_of --root "$CORPUS" --session sess-new --grep needle --source logs)" "6" \
    "AC7: '--session' filters the log lines by their text"
check "$(count_of --root "$CORPUS" --session sess-old --grep needle)" "$(( 1 + (EXPECT_STORE > 0 ? 1 : 0) ))" \
    "AC7: another session selects only its own records"
if has sqlite3; then
    check "$(count_of --root "$CORPUS" --session sess-new --source store --grep needle)" "2" \
        "AC7: in the store the session filter matches the session id"
fi

# --------------------------------------------------------------------------------------------
# AC8  the store
# --------------------------------------------------------------------------------------------
if has sqlite3; then
    run --root "$CORPUS" --source store --grep 'store record'
    check "$RC" "0" "AC8: the store answers"
    contains "$OUT" "corpus: $CORPUS [store]" "AC8: only the store was scanned"
    contains "$OUT" "matches: 2" "AC8: one record per matching content line"
    check "$(count_of --root "$CORPUS" --source store --grep 'second content line')" "1" \
        "AC8: a second content line is a record of its own"
    run --root "$CORPUS" --source store --grep 'store record' --limit 1
    contains "$OUT" "$NOW" "AC8: the record carries the timestamp of its message"
    before="$(cd "$CORPUS" && printf '%s\n' state.db*)"
    count_of --root "$CORPUS" --source store --grep needle >/dev/null
    after="$(cd "$CORPUS" && printf '%s\n' state.db*)"
    check "$after" "$before" "AC8: reading the store leaves no journal or wal file behind"
else
    pass "AC8: sqlite3 is not installed, the store assertions are skipped"
fi

# --------------------------------------------------------------------------------------------
# AC9  a compressed source
# --------------------------------------------------------------------------------------------
if has gzip; then
    check "$(count_of --root "$CORPUS" --grep 'rotated log' --source logs)" "1" \
        "AC9: a '*.log.gz' source is decompressed and matched"
    run --root "$CORPUS" --grep 'rotated log' --limit 1
    contains "$OUT" "logs/rotated.log.gz:1" "AC9: its locator keeps the path of the compressed file"
else
    pass "AC9: gzip is not installed, the compressed source assertions are skipped"
fi

# --------------------------------------------------------------------------------------------
# AC10 exit codes
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep 'no such record in this corpus'
check "$RC" "3" "AC10: no match is exit 3, not a failure"
contains "$OUT" "matches: 0" "AC10: and the count still says so"
check "$(count_of --root "$CORPUS" --grep 'no such record in this corpus')" "0" \
    "AC10: '--count' answers 0 for no match"
run --root "$CORPUS" --nonsense
check "$RC" "2" "AC10: an unknown argument exits 2"
check "$OUT" "" "AC10: and prints nothing on stdout"
run_err --root "$CORPUS" --nonsense
contains "$OUT" "hermes_logs: unknown argument '--nonsense'" "AC10: what was wrong goes to stderr"
contains "$OUT" "try 'bar usage hermes_logs'" "AC10: and where the help is"
run --root "$CORPUS" --source nonsense
check "$RC" "2" "AC10: an unknown source exits 2"
run --root "$CORPUS" --since 'not a time'
check "$RC" "2" "AC10: an unreadable '--since' exits 2"
run --root "$CORPUS" --limit lots
check "$RC" "2" "AC10: a non numeric '--limit' exits 2"
run --root "$CORPUS" --grep
check "$RC" "2" "AC10: an option without its value exits 2"
run --root "$WORK/no-such-root" --grep needle
check "$RC" "1" "AC10: a root which is not a directory exits 1"
run_err --root "$WORK/no-such-root" --grep needle
contains "$OUT" "not a corpus root" "AC10: and says which root"
if has sqlite3; then
    cp "$CORPUS/state.db" "$WORK/state.db.good"
    printf 'this is not a database\n' >"$CORPUS/state.db"
    run --root "$CORPUS" --grep needle
    check "$RC" "1" "AC10: an unreadable source exits 1"
    contains "$OUT" "unreadable: 1 source(s) not scanned: store/state.db" \
        "AC10: and the digest names the source the count does not cover"
    run_err --root "$CORPUS" --grep needle
    contains "$OUT" "could not read" "AC10: with the reason on stderr"
    cp "$WORK/state.db.good" "$CORPUS/state.db"
else
    pass "AC10: sqlite3 is not installed, the unreadable store assertion is skipped"
fi

# --------------------------------------------------------------------------------------------
# AC11 the corpus root
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --root "$WORK/empty2" --grep needle
check "$RC" "1" "AC11: one missing root of two is an error"
mkdir -p "$WORK/empty2"
run --root "$CORPUS" --root "$WORK/empty2" --grep needle
check "$RC" "0" "AC11: an empty root is an empty corpus, not an error"
contains "$OUT" "corpus: $WORK/empty2 [nothing]" "AC11: and the digest says it contributed nothing"
contains "$OUT" "#1/logs/agent.log:2" "AC11: with two roots a locator names its root"
OUT2="$(cd "$REPO_ROOT" && BAR_HERMES_LOGS_ROOT="$CORPUS" "$BAR" hermes_logs --grep needle --count 2>/dev/null)" || true
check "$OUT2" "$EXPECT_ALL" "AC11: BAR_HERMES_LOGS_ROOT is the environment fallback"
OUT2="$(cd "$REPO_ROOT" && BAR_HERMES_LOGS_ROOT="$WORK/empty2" "$BAR" hermes_logs --root "$CORPUS" --grep needle --count 2>/dev/null)" || true
check "$OUT2" "$EXPECT_ALL" "AC11: '--root' wins over the environment"
OUT2="$(cd "$REPO_ROOT" && HERMES_HOME="$CORPUS" "$BAR" hermes_logs --grep needle --count 2>/dev/null)" || true
check "$OUT2" "$EXPECT_ALL" "AC11: \$HERMES_HOME is the default root"

# --------------------------------------------------------------------------------------------
# AC12 bounds and determinism
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep needle --limit 2
check "$(digest_lines "$OUT")" "2" "AC12: '--limit 2' prints two match lines"
contains "$OUT" "shown: 2 of $EXPECT_ALL (limit 2 lines, 1200 chars)" "AC12: and states the truncation"
FIRST="$OUT"
run --root "$CORPUS" --grep needle --limit 2
check "$OUT" "$FIRST" "AC12: two identical queries print identical output"
MAX="$(printf '%s\n' "$OUT" | sed -n 's/^max: \([^ ]*\).*/\1/p')"
check "$(wc -l <"$MAX")" "$EXPECT_ALL" "AC12: and reuse one retrieval file holding every match"

# --------------------------------------------------------------------------------------------
# AC13 the answer stays bounded
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep '.' --limit 10
if (( $(bytes_of "$OUT") <= 2048 )); then
    pass "AC13: a query matching every line answers in $(bytes_of "$OUT") B (budget 2048 B)"
else
    fail "AC13: a query matching every line answers in $(bytes_of "$OUT") B (budget 2048 B)"
fi
contains "$OUT" "matches: $EXPECT_DOT_ALL" \
    "AC13: the count covers the corpus ($EXPECT_DOT_FILES non empty file lines, $EXPECT_DOT_STORE store lines)"
run --root "$CORPUS" --grep '.' --limit 100
contains "$OUT" "(limit 100 lines, 1200 chars)" \
    "AC13: the byte budget binds before the line limit"
contains "$OUT" "matches: $EXPECT_DOT_ALL" "AC13: and the count stays exact"
if (( $(digest_lines "$OUT") < EXPECT_DOT_ALL )); then
    pass "AC13: the digest stops at $(digest_lines "$OUT") of the $EXPECT_DOT_ALL records"
else
    fail "AC13: the byte budget did not bound the digest"
fi
if (( $(bytes_of "$OUT") <= 2048 )); then
    pass "AC13: and the answer is still $(bytes_of "$OUT") B"
else
    fail "AC13: and the answer is still $(bytes_of "$OUT") B, over the 2048 B budget"
fi

# --------------------------------------------------------------------------------------------
# AC14 no control character in a snippet, and the elision is stated
# --------------------------------------------------------------------------------------------
run --root "$CORPUS" --grep 'needle' --limit 20
absent "$OUT" "$(printf '\033')" "AC14: an ANSI escape never reaches the digest"
absent "$OUT" "$(printf '\r')" "AC14: nor a carriage return"
contains "$OUT" "needle ansi " "AC14: the text around the escape is kept"
contains "$OUT" "[31mred[0m" "AC14: and the escape's own bytes are gone, not the word"
contains "$OUT" "<+" "AC14: the 400 character line says how much was clipped"
contains "$OUT" "clipped: 1 snippet(s) at 160 chars" "AC14: and the digest counts the clipped snippet"

# --------------------------------------------------------------------------------------------
# AC15 registration and documentation
# --------------------------------------------------------------------------------------------
OUT="$(cd "$REPO_ROOT" && "$BAR" helpers 2>/dev/null)" || RC=$?
contains "$OUT" "hermes_logs  " "AC15: the repertoire index lists the helper"
OUT="$(cd "$REPO_ROOT" && "$BAR" helpers --check 2>/dev/null)" || RC=$?
check "$OUT" "" "AC15: the registration guard passes"
OUT="$(cd "$REPO_ROOT" && "$BAR" help 2>/dev/null)" || RC=$?
contains "$OUT" "Retrieval over the Hermes log corpus" "AC15: 'bar help' carries the module prose"
contains "$OUT" "THE CORPUS (explicit, never guessed)" "AC15: including the corpus roots it scans"
contains "$OUT" "NON GOALS" "AC15: and what it does not do"

# --------------------------------------------------------------------------------------------
# AC16 reachability through 'please', in a fresh installation
# --------------------------------------------------------------------------------------------
FAKE_HOME="$WORK/home"
SITE="$WORK/site"
mkdir -p "$FAKE_HOME/.local" "$SITE/Bar.d" "$SITE/contrib"
cp "$BAR" "$SITE/bar"
cp "$REPO_ROOT/Barf.default" "$REPO_ROOT/Pleasef.default" "$SITE/"
cp "$REPO_ROOT/contrib/bar_complete" "$SITE/contrib/" 2>/dev/null || true
module=""
for module in "$REPO_ROOT/Bar.d/"*; do
    ln -s "$module" "$SITE/Bar.d/${module##*/}"
done
(cd "$SITE" && HOME="$FAKE_HOME" ./bar init_install "$FAKE_HOME/.local" >/dev/null 2>&1) || true
if [[ -L "$FAKE_HOME/.config/please/hermes" ]]; then
    pass "AC16: 'init_install' linked the new module for 'please'"
else
    fail "AC16: no link for 'hermes' in ~/.config/please"
fi
OUT="$(cd "$WORK" && HOME="$FAKE_HOME" BAR_HERMES_LOGS_DIR="$WORK/max" \
    "$FAKE_HOME/.local/bin/please" hermes_logs --root "$CORPUS" --grep 'fresh record' --limit 1 \
    2>/dev/null)" || RC=$?
contains "$OUT" "logs/agent.log:2" "AC16: 'please hermes_logs' answers from an arbitrary directory"
contains "$OUT" "matches: 1" "AC16: with the exact count"

echo
if (( failures == 0 )); then
    echo "=== All Hermes log helper tests passed ==="
else
    echo "=== $failures Hermes log helper assertion(s) FAILED ==="
    exit 1
fi
