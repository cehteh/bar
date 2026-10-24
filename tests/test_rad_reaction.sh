#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the reaction helper (Bar.d/rad).
#
# The argument contract and the repertoire entry, without a node and without a store: every marker
# this helper *writes* goes to a radicle repository, so the cases here stop before that -- what they
# pin down is the interface a caller (an agent, a script, the reaction loop) depends on.  A store
# transition needs a radicle fixture and is exercised where such a fixture exists: the loop's own
# writes against the live node, and the copy-on-write cases in `tests/test_rad_comment_metadata.sh`
# (same fake-'rad' fixture shape, should one be wanted here too).
#
#   AC1  '-h' answers the builtin help on stdout, exit 0
#   AC2  usage errors exit 2 and keep stdout empty (no positionals, '--from' without a value,
#        an unknown flag, a missing target)
#   AC3  a reaction the store would not accept is refused before any call, exit 2
#   AC4  the forms parse: '<from> <to> <target>..' and '<to> <target>..' with '--from', including
#        the empty '<to>' that withdraws '<from>'
#   AC5  the helper is registered ('bar helpers --check', and the index names it with its usage)
#
# usage: tests/test_rad_reaction.sh

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
# A path that is no radicle repository: every case that gets past the argument parsing has to fail
# here, which is what keeps this test from writing a marker into a real repository.
NOREPO="$WORKDIR/not-a-repo"
mkdir -p "$NOREPO"

# run <args..> - 'bar rad_reaction' with stdout/stderr split, exit code in RC
OUT=""
ERR=""
RC=0
run() {
    RC=0
    OUT="$("$BAR" rad_reaction "$@" 2>"$WORKDIR/err")" || RC=$?
    ERR="$(cat "$WORKDIR/err")"
}

echo "AC1 '-h' answers the usage on stdout, exit 0"
run -h
check "$RC" 0 "'-h' exits 0"
contains "$OUT" "rad_reaction [--from <emoji>] [--repo <rid|path>] <to> <target>.." "the builtin help goes to stdout"
absent "$ERR" "usage:" "and nothing goes to stderr"
run --help
check "$RC" 0 "'--help' exits 0 too"
echo

echo "AC2 usage errors exit 2 and keep stdout empty"
run
check "$RC" 2 "no positional is a usage error"
absent "$OUT" "usage" "stdout stays empty"
contains "$ERR" "try 'bar usage rad_reaction'" "the help is pointed at, on stderr"
run --from
check "$RC" 2 "'--from' without a value is a usage error"
run --from ":eyes:" ""
check "$RC" 2 "a withdrawal without a target is a usage error"
run --nope ":eyes:" "$NOREPO"
check "$RC" 2 "an unknown flag is a usage error"
run ":eyes:"
check "$RC" 2 "a reaction without a target is a usage error"
echo

echo "AC3 the reaction is one codepoint of the store's allow list"
run "xx" "$NOREPO"
check "$RC" 2 "a non-emoji reaction is refused"
contains "$ERR" "not a reaction the store accepts" "and the error says so"
run "❤️" "$NOREPO"
check "$RC" 2 "a multi-codepoint sequence (heart + variation selector) is refused"
run ":eyes:"
check "$RC" 2 "a reaction without a target is a usage error"
run ":eyes:" "$NOREPO"
check "$RC" 2 "the ':eyes:' shortcode is NOT a reaction: the store wants the codepoint itself"
contains "$ERR" "is not a reaction the store accepts" "and says which rule it broke"
# AC3's last case and AC4 stop *at* the store: the helper refuses a path that is not a repository
# only after it has found the command it would talk to, so where that command is absent the case
# cannot be reached at all.  Said out loud rather than asserted, the way the suite's other
# tool-dependent cases are (a check container carries no radicle binary).
if command -v "${n:-rad}" >/dev/null 2>&1; then
    run "👀" "$NOREPO"
    check "$RC" 3 "an accepted emoji gets past the argument check to the repository"
    contains "$ERR" "" "with nothing on stdout"
    echo

    echo "AC4 the forms parse (a store that holds nothing answers 3, never a usage error)"
    run --from "👀" "" "$NOREPO"
    check "$RC" 3 "the empty <to> parses as a withdrawal"
    absent "$ERR" "usage:" "the parser is past its argument check"
    run "👀" "" "$NOREPO"
    check "$RC" 3 "the positional '<from> <to>' form parses the same way"
    run --from "👀" "🔧" "$NOREPO"
    check "$RC" 3 "the '<from> <to>' form with a marker to set parses"
    run --repo "$NOREPO" "👀" "a"
    check "$RC" 3 "'--repo' is read as the repository, not as a target"
    contains "$ERR" "neither a RID nor a checkout" "and the store says what the path is not"
else
    echo "  - AC3/AC4 store cases skipped: no '${n:-rad}' installed, so the helper stops before the store"
fi
echo

echo "AC5 the helper is registered"
RC=0
OUT="$("$BAR" helpers --check 2>&1)" || RC=$?
check "$RC" 0 "'bar helpers --check' passes"
contains "$OUT" "OK" "and reports OK"
RC=0
OUT="$("$BAR" helpers 2>&1)" || RC=$?
check "$RC" 0 "'bar helpers' answers"
contains "$OUT" "rad_reaction" "the index names rad_reaction"
contains "$OUT" "withdraw one of our reaction markers" "with its declaration's description"
contains "$OUT" "rad_reaction [--from <emoji>] [--repo <rid,path>] <to> <target>.." "and its usage"
echo

# --- the '--state' form: a faked node, a faked store, and a recorded call log -------------------
#
# What is faked: 'rad' (a script answering from $FIXTURES and recording every invocation) and the
# node storage (a directory, so 'rad_metadata_store' resolves).  What is *not* faked is the
# reduction under test: the document, the op chain and the store's own semantics (one op, several
# actions, the last one winning) are the shapes measured on a live node, written into the fixtures.

SRID="rad:z3StateProbeRepo"
OURS="z6MkOursoursoursoursoursoursoursoursoursou"
OTHER="z6MkTheothertheothertheothertheothertheoth"

S_ISSUE="aaaa111122223333444455556666777788889999"
S_ICOM="aaaa222233334444555566667777888899990000"
S_PATCH="bbbb111122223333444455556666777788889999"
S_REV2="bbbb444455556666777788889999000011112222"
S_PCOMM="bbbb222233334444555566667777888899990000"
S_REVIEW="bbbb333344445555666677778888999900001111"
S_NOCOB="cccc111122223333444455556666777788889999"

OP1="1000000000000000000000000000000000000001"
OP2="1000000000000000000000000000000000000002"
OP3="1000000000000000000000000000000000000003"
OP4="1000000000000000000000000000000000000004"
OP5="1000000000000000000000000000000000000005"
OP6="1000000000000000000000000000000000000006"
POP1="2000000000000000000000000000000000000001"
POP2="2000000000000000000000000000000000000002"
POP3="2000000000000000000000000000000000000003"
POP4="2000000000000000000000000000000000000004"

SRADHOME="$WORKDIR/sradhome"
SFIX="$WORKDIR/sfix"
SCALLS="$WORKDIR/scalls"
mkdir -p "$SRADHOME/storage/${SRID#rad:}" "$SFIX/bin" "$SFIX"
: >"$SCALLS"

cat >"$SFIX/bin/rad" <<'FAKE'
#!/usr/bin/env bash
# A fake 'rad': answers from $SFIX, records every invocation in $SCALLS.
set -uo pipefail
printf '%s\n' "$*" >>"$SCALLS"
cmd="${1:-}"
shift || true
case "$cmd" in
path) printf '%s\n' "$SRADHOME" ;;
self) printf 'did:key:%s\n' "$OURS" ;;
cob)
    sub="${1:-}"
    shift || true
    type="" object=""
    while (( $# )); do
        case "$1" in
        -t | --type) type="${2:-}"; shift 2 ;;
        -o | --object) object="${2:-}"; shift 2 ;;
        *) shift ;;
        esac
    done
    case "$sub" in
    list)
        if [[ -f "$SFIX/list.$type" ]]; then cat "$SFIX/list.$type"; fi
        ;;
    show | log)
        if [[ -f "$SFIX/$sub.$type.$object" ]]; then
            cat "$SFIX/$sub.$type.$object"
        else
            printf '✗ Error: object `%s` of type `%s` was not found\n' "$object" "$type"
            exit 1
        fi
        ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 1 ;;
esac
FAKE
chmod +x "$SFIX/bin/rad"

printf '%s\n' "$S_ISSUE" >"$SFIX/list.xyz.radicle.issue"
printf '%s\n' "$S_PATCH" >"$SFIX/list.xyz.radicle.patch"

# The issue: ours carries two markers on the root (🔧, ❓) beside another identity's 👀, and one on
# a comment.  The reduction is the store's: one op may set and withdraw in the same action list.
cat >"$SFIX/show.xyz.radicle.issue.$S_ISSUE" <<JSON
{"assignees":[],"title":"an issue","state":{"status":"open"},"labels":[],
 "thread":{"comments":{
   "$S_ISSUE":{"author":"$OTHER","reactions":[["$OURS","🔧"],["$OTHER","👀"],["$OURS","❓"]],
               "resolved":false,"body":"the description"},
   "$S_ICOM":{"author":"$OTHER","reactions":[["$OURS","👀"]],"resolved":false,"body":"a comment"}},
  "timeline":["$OP1","$OP2","$OP3","$OP4","$OP5","$OP6"]}}
JSON

# The chain, newest first as 'rad cob log --format json' prints it.  OP4 sets and withdraws 👀 in
# one action list -- the shape a reader reducing the chain by hand reports as live for ever.
cat >"$SFIX/log.xyz.radicle.issue.$S_ISSUE" <<JSON
{"id":"$OP6","actions":[{"type":"comment.react","id":"$S_ICOM","reaction":"👀","active":true}],"author":"$OURS","timestamp":1790000600000,"parents":["$OP5"]}
{"id":"$OP5","actions":[{"type":"comment.react","id":"$S_ISSUE","reaction":"🔧","active":true}],"author":"$OURS","timestamp":1790000500000,"parents":["$OP4"]}
{"id":"$OP4","actions":[{"type":"comment.react","id":"$S_ISSUE","reaction":"👀","active":true},{"type":"comment.react","id":"$S_ISSUE","reaction":"👀","active":false}],"author":"$OURS","timestamp":1790000400000,"parents":["$OP3"]}
{"id":"$OP3","actions":[{"type":"comment.react","id":"$S_ISSUE","reaction":"❓","active":true}],"author":"$OURS","timestamp":1790000300000,"parents":["$OP2"]}
{"id":"$OP2","actions":[{"type":"comment.react","id":"$S_ISSUE","reaction":"🔧","active":true},{"type":"comment.react","id":"$S_ISSUE","reaction":"👀","active":false}],"author":"$OURS","timestamp":1790000200000,"parents":["$OP1"]}
{"id":"$OP1","actions":[{"type":"comment","body":"the description"}],"author":"$OURS","timestamp":1790000100000,"parents":[]}
JSON

# The patch: a root revision, a second revision, a comment of the revision, a review.
cat >"$SFIX/show.xyz.radicle.patch.$S_PATCH" <<JSON
{"title":"a patch","author":{"id":"did:key:$OURS"},"state":{"status":"open"},"target":"main",
 "labels":[],"assignees":[],"merges":{},
 "revisions":{
  "$S_PATCH":{"id":"$S_PATCH","author":{"id":"did:key:$OURS"},"base":"$OP1","oid":"$OP2",
    "description":[],"resolves":[],"reactions":[{"location":null,"emoji":"✅","authors":["$OURS"]}],
    "discussion":{"comments":{"$S_PCOMM":{"author":"$OTHER","reactions":[],"resolved":false,"body":"a revision comment"}},
                  "timeline":["$S_PCOMM"]},
    "reviews":{"$OTHER":{"id":"$S_REVIEW","author":{"id":"did:key:$OTHER"},"verdict":"comment",
      "summary":[],"labels":[],"reactions":[],"comments":{"comments":{},"timeline":[]}}}},
  "$S_REV2":{"id":"$S_REV2","author":{"id":"did:key:$OURS"},"base":"$OP2","oid":"$OP2",
    "description":[],"resolves":[],"reactions":[{"location":null,"emoji":"✅","authors":["$OURS"]}],
    "discussion":{"comments":{},"timeline":[]},"reviews":{}}},
 "timeline":["$S_PATCH","$S_REV2","$S_PCOMM","$S_REVIEW"]}
JSON

# The chain a patch really has: a merge op with two parents, and the marker's op hanging off the
# *second* one -- unreachable for a reader that walks 'parents[0]' down from the tip.  The lines are
# deliberately out of order: '--format json' promises none.
cat >"$SFIX/log.xyz.radicle.patch.$S_PATCH" <<JSON
{"id":"$POP1","actions":[{"type":"revision.react","revision":"$S_PATCH","reaction":"✅","active":true}],"author":"$OURS","timestamp":1790000650000,"parents":[]}
{"id":"$POP3","actions":[{"type":"revision.react","revision":"$S_REV2","reaction":"✅","active":true}],"author":"$OURS","timestamp":1790000800000,"parents":["$POP1"]}
{"id":"$POP2","actions":[],"author":"$OURS","timestamp":1790000700000,"parents":["$POP1"]}
{"id":"$POP4","actions":[],"author":"$OURS","timestamp":1790000900000,"parents":["$POP2","$POP3"]}
JSON

# run_state <args..> - 'bar rad_reaction' against the faked node, stdout/stderr split
SOUT=""
SERR=""
SRC=0
run_state() {
    SRC=0
    SOUT="$(RAD_BIN="$SFIX/bin/rad" RADHOME="$SRADHOME" SFIX="$SFIX" SCALLS="$SCALLS" \
        SRADHOME="$SRADHOME" OURS="$OURS" "$BAR" rad_reaction "$@" 2>"$WORKDIR/serr")" || SRC=$?
    SERR="$(cat "$WORKDIR/serr")"
}
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

echo "AC6 '--state' usage errors exit 2 and keep stdout empty"
: >"$SCALLS"
run_state --state
check "$SRC" 2 "'--state' without a target is a usage error"
absent "$SOUT" "state item=" "stdout stays empty"
contains "$SERR" "try 'bar usage rad_reaction'" "the usage error points at the help"
run_state --state --from "👀" "$S_ISSUE"
check "$SRC" 2 "'--from' with '--state' is a usage error"
contains "$SERR" "'--from'" "and the error names the flag"
run_state --state --nope "$S_ISSUE"
check "$SRC" 2 "an unknown flag with '--state' is a usage error"
check "$(grep -c 'cob ' "$SCALLS" || true)" 0 "a usage error opens no store"
echo

echo "AC7 '--state' answers the reduced state, dated by the op that set it"
: >"$SCALLS"
run_state --state --repo "$SRID" "$S_ISSUE"
check "$SRC" 0 "the root comment answers 0"
contains "$SOUT" "item=issue:$S_ISSUE" "the line names the item"
contains "$SOUT" "level=root" "and its level"
contains "$SOUT" "target=$S_ISSUE" "and the full target id"
contains "$SOUT" "markers=❓,🔧" "both live markers of ours, oldest first"
absent "$SOUT" "👀" "the one withdrawn in the same op is not live"
absent "$SOUT" "✅" "and another identity's marker is not ours"
contains "$SOUT" "since=$(iso 1790000500)" "since is the op that set the newest marker"
contains "$SOUT" "op=$OP5" "with that op's id"
check "$(printf '%s\n' "$SOUT" | wc -l | tr -d ' ')" 1 "one line per target"
echo

echo "AC8 a target named a second way reports the level it really is"
run_state --state --repo "$SRID" "$S_ISSUE" "$S_ICOM"
check "$SRC" 0 "a comment of the issue answers 0"
contains "$SOUT" "level=comment" "a comment is level=comment, not root"
contains "$SOUT" "target=$S_ICOM" "and the target is the comment"
contains "$SOUT" "markers=👀" "with its own marker"
contains "$SOUT" "op=$OP6" "dated by the op that set it"
run_state --state --repo "$SRID" "$S_PATCH"
check "$SRC" 0 "a patch id answers 0"
contains "$SOUT" "item=patch:$S_PATCH" "the item is the patch"
contains "$SOUT" "level=revision" "a patch id is its root revision"
contains "$SOUT" "markers=✅" "with the revision's marker"
run_state --state --repo "$SRID" "$S_REV2"
check "$SRC" 0 "a revision id answers 0"
contains "$SOUT" "level=revision" "a second revision is level=revision too"
contains "$SOUT" "target=$S_REV2" "and is reported as itself"
contains "$SOUT" "op=$POP3" "dated by its own op, which hangs off the merge's second parent"
run_state --state --repo "$SRID" "$S_PATCH" "$S_REVIEW"
check "$SRC" 0 "a review of the patch answers 0"
contains "$SOUT" "level=review" "a review is level=review"
contains "$SOUT" "markers=-" "and no marker of ours is a state, not an error"
echo

echo "AC9 '--state' is read-only and names every target it was given"
: >"$SCALLS"
run_state --state --repo "$SRID" "$S_ISSUE" "$S_PATCH"
check "$SRC" 0 "one invocation, two targets"
check "$(printf '%s\n' "$SOUT" | wc -l | tr -d ' ')" 2 "one line for each"
contains "$SOUT" "item=issue:$S_ISSUE" "the first is the issue"
contains "$SOUT" "item=patch:$S_PATCH" "the second the patch"
run_state --state --repo "$SRID" "$S_ISSUE" "$S_ICOM"
check "$SRC" 0 "an item and one id inside it is one target"
check "$(printf '%s\n' "$SOUT" | wc -l | tr -d ' ')" 1 "and one line"
contains "$SOUT" "target=$S_ICOM" "the second word is the target, not a second item"
check "$(grep -c 'cob update' "$SCALLS" || true)" 0 "no 'cob update' was made"
check "$(grep -ci 'react' "$SCALLS" || true)" 0 "and no typed react either"
echo

echo "AC10 '--state --json' is one object per target, marked as bar's"
run_state --state --json --repo "$SRID" "$S_ISSUE"
check "$SRC" 0 "'--json' answers 0"
check "$(printf '%s' "$SOUT" | jq -r '.bar_rad')" 1 "the object is marked bar_rad: 1"
check "$(printf '%s' "$SOUT" | jq -r '.item')" "issue:$S_ISSUE" "item names the COB and its type"
check "$(printf '%s' "$SOUT" | jq -r '.level')" root "level is the one it really is"
check "$(printf '%s' "$SOUT" | jq -r '.markers | length')" 2 "both markers"
check "$(printf '%s' "$SOUT" | jq -r '.markers[-1].emoji')" "🔧" "newest last"
check "$(printf '%s' "$SOUT" | jq -r '.markers[-1].op')" "$OP5" "each marker carries its op"
check "$(printf '%s' "$SOUT" | jq -r '.markers[-1].date')" "$(iso 1790000500)" "and its date"
check "$(printf '%s' "$SOUT" | jq -r '.since')" "$(iso 1790000500)" "since belongs to the newest"
check "$(printf '%s' "$SOUT" | jq -r '.op')" "$OP5" "op too"
echo

echo "AC11 a target the store does not carry is exit 3, never 'markers=-'"
run_state --state --repo "$SRID" "$S_NOCOB"
check "$SRC" 3 "an id nothing carries is exit 3"
absent "$SOUT" "markers=-" "and it is not reported as an empty state"
contains "$SERR" "holds no" "the store says what it holds no such thing of"
echo

if (( failures )); then
    echo "FAILED: $failures"
    exit 1
fi
echo "OK: rad_reaction"
