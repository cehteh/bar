#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the state dump: what a run writes after the modules and the rulefile were
# loaded, and what a later run reads instead of them.
#
#   AC1  a run writes the dump, the next run sources it instead of the files
#   AC2  what a run answers is the same with and without the dump
#   AC3  editing the rulefile invalidates it, and the edit is in effect
#   AC4  editing a module invalidates it, and the edit is in effect
#   AC5  a module which appeared in 'Bar.d' invalidates it (the startup set changed)
#   AC6  a dump which is damaged, foreign or from another rulefile is not used, and the run still
#        answers
#   AC7  'BAR_STATE_DUMP=off' neither reads nor writes a dump
#   AC8  state which belongs to the invocation is decided again, not restored: the tty binding
#        follows 'COLOR', and a rule defined after the dump was written still loads
#   AC9  a run with a current dump is measurably faster than one which loads the files
#
# usage: tests/test_state_dump.sh

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mkproj <dir> - a project of its own: this repository's modules as its 'Bar.d', a rulefile with
# two rules.  The modules are copied (not linked) so that nothing a test does reaches the checkout.
mkproj() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
    cat >"$dir/Barf" <<'EOS'
greet: -- 'echo hello'

fails: -- 'error "boom"'
EOS
}

RC=0
OUT=""
ERR=""
# runin <dir> <rule> [args..] - run a rule in a project, capturing its output and exit status.
# 'BAR_VERBOSITY_LEVEL=5' is on so that 'state: wrote'/'state: sourced' can be read back: those
# two lines are how a test sees which path a run took.
runin() {
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$( cd "$dir" && BAR_STATE_DUMP="${STATE_DUMP-}" BAR_VERBOSITY_LEVEL="${VERB:-5}" "$BAR" "$@" 2>"$WORK/err" )" || RC=$?
    ERR="$(cat "$WORK/err")"
    OUT+="$ERR"
}

echo "AC1 a run writes the dump, the next run sources it"
P="$WORK/ac1"
mkproj "$P"
runin "$P" greet
check "$RC" "0" "the first run answers"
contains "$OUT" "state: wrote" "the first run writes the dump"
[[ -f "$P/.bar.dump" ]] && pass "the dump is '$P/.bar.dump'" || fail "no dump at $P/.bar.dump"
check "$(head -1 "$P/.bar.dump")" "# bar-state 1" "the dump names its format"
runin "$P" greet
contains "$OUT" "state: sourced" "the second run sources the dump instead of the files"
absent "$OUT" "state: wrote" "and does not write it again"
contains "$OUT" "hello" "and answers the rule"
echo

echo "AC2 what a run answers is the same with and without the dump"
P="$WORK/ac2"
mkproj "$P"
VERB=0 # the comparison is of what a run answers, not of what it says about itself
runin "$P" greet                                  # writes the dump
runin "$P" rule_list
HIT_LIST="$OUT"
runin "$P" help usage greet
HIT_HELP="$OUT"
STATE_DUMP=off
runin "$P" greet
absent "$OUT" "state:" "the disabled run names no dump"
runin "$P" rule_list
OFF_LIST="$OUT"
runin "$P" help usage greet
OFF_HELP="$OUT"
STATE_DUMP=""
check "$HIT_LIST" "$OFF_LIST" "the rule list is the same with and without the dump"
check "$HIT_HELP" "$OFF_HELP" "the rule documentation is the same with and without the dump"
VERB=""
echo

echo "AC3 editing the rulefile invalidates the dump"
P="$WORK/ac3"
mkproj "$P"
runin "$P" greet
printf '\ngreet2: -- '\''echo second'\''\n' >>"$P/Barf"
runin "$P" greet2
contains "$OUT" "state: wrote" "the changed rulefile invalidates the dump"
check "$RC" "0" "the new rule is defined"
contains "$OUT" "second" "and runs"
runin "$P" greet2
contains "$OUT" "state: sourced" "the run after it sources a fresh dump"
echo

echo "AC4 editing a module invalidates the dump"
P="$WORK/ac4"
mkproj "$P"
runin "$P" greet
cat >>"$P/Bar.d/std_rules" <<'EOS'

declare -grx GREET_CONST="const" ## a readonly constant a test added

function greet_extra ## - a function a test added
{
    echo "extra $GREET_CONST"
}

greet_extra_rule: -- greet_extra
EOS
runin "$P" greet_extra_rule
contains "$OUT" "state: wrote" "the changed module invalidates the dump"
check "$RC" "0" "the rule of the changed module is defined"
contains "$OUT" "extra const" "and the function and its readonly constant are there"
echo

echo "AC5 a module which appeared in 'Bar.d' invalidates the dump"
P="$WORK/ac5"
mkproj "$P"
runin "$P" greet
cat >"$P/Bar.d/added_rules" <<'EOS'
added_rule: -- 'echo added'
EOS
runin "$P" added_rule
contains "$OUT" "state: wrote" "a new '*_rules' module invalidates the dump"
check "$RC" "0" "and its rule is loaded"
contains "$OUT" "added" "and runs"
echo

echo "AC6 a damaged, foreign or mismatched dump is not used"
P="$WORK/ac6"
mkproj "$P"
runin "$P" greet
printf 'garbage\n' >"$P/.bar.dump"
runin "$P" greet
contains "$OUT" "state: wrote" "a damaged dump is not used"
check "$RC" "0" "and the run answers"
contains "$OUT" "hello" "with the rule's output"

# a dump made from another rulefile: same modules, a rulefile which is not this one
sed 's|^# barf=.*|# barf=/nonexistent/Barf|' "$P/.bar.dump" >"$WORK/foreign.dump"
cp "$WORK/foreign.dump" "$P/.bar.dump"
runin "$P" greet
contains "$OUT" "state: wrote" "a dump made from another rulefile is not used"
check "$RC" "0" "and the run answers"
echo

echo "AC7 'BAR_STATE_DUMP=off' neither reads nor writes a dump"
P="$WORK/ac7"
mkproj "$P"
STATE_DUMP=off
runin "$P" greet
check "$RC" "0" "the run answers"
[[ ! -f "$P/.bar.dump" ]] && pass "no dump was written" || fail "a dump was written anyway"
runin "$P" greet
[[ ! -f "$P/.bar.dump" ]] && pass "still none after a second run" || fail "a dump appeared"
STATE_DUMP=""
runin "$P" greet
contains "$OUT" "state: wrote" "with the switch back on it writes one"
echo

echo "AC8 what belongs to the invocation is decided again, not restored"
P="$WORK/ac8"
mkproj "$P"
# a dump written where colour was forced on, read where it is refused: the binding is a property
# of the reading run, so no escape sequence may appear
( cd "$P" && COLOR=always BAR_VERBOSITY_LEVEL=0 "$BAR" greet >/dev/null 2>&1 )
[[ -f "$P/.bar.dump" ]] && pass "the coloured run wrote the dump" || fail "no dump was written"
( cd "$P" && COLOR=never BAR_VERBOSITY_LEVEL=5 "$BAR" fails >"$WORK/out" 2>"$WORK/err" ) || true
OUT="$(cat "$WORK/out" "$WORK/err")"
contains "$OUT" "state: sourced" "the coloured dump was sourced"
absent "$OUT" "$(printf '\033')" "and the refused colour is respected, not restored from the dump"

# a rule defined after the dump was written still loads: the dump is a starting point, not a seal
printf '\nlate_rule: -- '\''echo late'\''\n' >>"$P/Barf"
runin "$P" late_rule
contains "$OUT" "state: wrote" "the changed rulefile invalidates it"
check "$RC" "0" "and the rule defined after the dump is callable"
contains "$OUT" "late" "and runs"
echo

echo "AC9 a run with a current dump is measurably faster"
# best <dir> <BAR_STATE_DUMP value> - best of three runs of a trivial rule, in milliseconds
best() {
    local dir="$1" dump="$2" b="" start ms
    for _ in 1 2 3; do
        start="$(date +%s%N)"
        ( cd "$dir" && BAR_STATE_DUMP="$dump" "$BAR" greet >/dev/null 2>&1 ) || true
        ms=$(( ($(date +%s%N) - start) / 1000000 ))
        if [[ -z "$b" ]] || (( ms < b )); then
            b="$ms"
        fi
    done
    printf '%s' "$b"
}

P="$WORK/ac9"
mkproj "$P"
runin "$P" greet
hit="$(best "$P" "")"
off="$(best "$P" "off")"
if (( hit < off * 8 / 10 )); then
    pass "a dump run takes ${hit} ms against ${off} ms without it (best of 3)"
else
    fail "a dump run takes ${hit} ms, which is not faster than ${off} ms without it"
fi
echo

if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All state dump tests passed ==="
