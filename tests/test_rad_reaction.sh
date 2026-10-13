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
#   AC1  '-h' answers the usage on stdout, exit 0
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
contains "$OUT" "usage: rad_reaction" "the usage goes to stdout"
absent "$ERR" "usage:" "and nothing goes to stderr"
run --help
check "$RC" 0 "'--help' exits 0 too"
echo

echo "AC2 usage errors exit 2 and keep stdout empty"
run
check "$RC" 2 "no positional is a usage error"
absent "$OUT" "usage" "stdout stays empty"
contains "$ERR" "usage: rad_reaction" "the usage is on stderr"
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

if (( failures )); then
    echo "FAILED: $failures"
    exit 1
fi
echo "OK: rad_reaction"
