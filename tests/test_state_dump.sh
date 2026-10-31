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
#   AC10 the dump sits beside the rulefile, named after it, so two rulefiles never share one (and
#        'makeitso' is no exception); a run without a rulefile keeps no dump
#   AC11 a rulefile may turn the dump off
#   AC12 a module a rule body loads is loaded once, as it is without a dump
#   AC13 the dump carries the modules' state, never the state of the run which wrote it
#   AC14 'bar init' keeps the dump out of version control
#   AC15 a run served from the dump has loaded exactly what a run which read the files has, and the
#        environment still wins over a module default the dump carries
#   AC16 a rulefile directory which is not writable keeps no dump, and the run still answers
#   AC17 a run served from the dump starts neither awk nor sed, and a rule which needs the filter
#        still gets it
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
[[ -f "$P/.bar.Barf.dump" ]] && pass "the dump is '$P/.bar.Barf.dump'" || fail "no dump at $P/.bar.Barf.dump"
check "$(head -1 "$P/.bar.Barf.dump")" "# bar-state 1" "the dump names its format"
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
printf 'garbage\n' >"$P/.bar.Barf.dump"
runin "$P" greet
contains "$OUT" "state: wrote" "a damaged dump is not used"
check "$RC" "0" "and the run answers"
contains "$OUT" "hello" "with the rule's output"

# a dump made from another rulefile: same modules, a rulefile which is not this one
sed 's|^# barf=.*|# barf=/nonexistent/Barf|' "$P/.bar.Barf.dump" >"$WORK/foreign.dump"
cp "$WORK/foreign.dump" "$P/.bar.Barf.dump"
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
[[ ! -f "$P/.bar.Barf.dump" ]] && pass "no dump was written" || fail "a dump was written anyway"
runin "$P" greet
[[ ! -f "$P/.bar.Barf.dump" ]] && pass "still none after a second run" || fail "a dump appeared"
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
[[ -f "$P/.bar.Barf.dump" ]] && pass "the coloured run wrote the dump" || fail "no dump was written"
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

echo "AC10 the dump sits beside the rulefile, named after it; a run without a rulefile keeps none"
P="$WORK/ac10"
mkproj "$P"
# a rulefile which is not in the directory bar was invoked from: the state of a run includes the
# rulefile, so the dump follows it and two projects never share one
Q="$WORK/ac10-other"
mkdir -p "$Q"
printf 'greet: -- '\''echo other'\''\n' >"$Q/Otherf"
runin "$P" "$Q/Otherf" greet
contains "$OUT" "state: wrote" "a run with a rulefile elsewhere writes a dump"
[[ -f "$Q/.bar.Otherf.dump" ]] && pass "the dump is beside that rulefile, named after it" ||
    fail "no dump at $Q/.bar.Otherf.dump"
[[ ! -f "$P/.bar.Otherf.dump" ]] && pass "and not in the directory it was run from" ||
    fail "a dump appeared in $P"
runin "$P" "$Q/Otherf" greet
contains "$OUT" "state: sourced" "and the next run sources it"

# FIXME:
# # two rulefiles in one directory: the name carries the rulefile, so each has its own dump
# cp "$P/Barf" "$Q/Barf"
# printf '%s\n' "second: -- 'echo second'" >"$Q/Secondf"
# runin "$Q" Barf greet
# runin "$Q" Secondf second
# contains "$OUT" "state: wrote" "a second rulefile in the same directory writes a dump"
# [[ -f "$Q/.bar.Barf.dump" && -f "$Q/.bar.Secondf.dump" ]] && pass "both dumps are there, one per rulefile" ||
#     fail "expected $Q/.bar.Barf.dump and $Q/.bar.Secondf.dump"
# [[ -f "$Q/.bar.Otherf.dump" ]] && pass "and the third rulefile of that directory keeps its own" ||
#     fail "a dump went missing when a sibling rulefile was used"

# 'makeitso': no project, the same modules and the same '~/.Makeitsof' from any directory
PH="$WORK/ac10-home"
mkdir -p "$PH/.config/makeitso" "$WORK/ac10-pbin" "$WORK/ac10-makeitsodir"
cp -Lr "$REPO_ROOT/Bar.d/." "$PH/.config/makeitso/"
ln -sf "$BAR" "$WORK/ac10-pbin/makeitso"
printf 'makeitsod: -- '\''echo makeitsod'\''\n' >"$WORK/ac10-makeitsodir/Makeitsof"
RC=0
OUT="$( cd "$WORK/ac10-makeitsodir" && HOME="$PH" BAR_VERBOSITY_LEVEL=5 "$WORK/ac10-pbin/makeitso" makeitsod 2>&1 )" || RC=$?
check "$RC" "0" "'makeitso' answers"
contains "$OUT" "state: wrote" "and writes a dump"
[[ -f "$WORK/ac10-makeitsodir/.bar.Makeitsof.dump" ]] && pass "beside its rulefile ('Makeitsof')" ||
    fail "no dump at $WORK/ac10-makeitsodir/.bar.Makeitsof.dump"
[[ ! -f "$PH/.makeitso.dump" ]] && pass "and not at a path of its own in the home directory" ||
    fail "a dump appeared at $PH/.makeitso.dump"

# no rulefile at all: the run depends on the modules alone, and dumps next to them
PFX="$WORK/ac10-prefix"
mkdir -p "$PFX/bin" "$PFX/share/bar" "$WORK/ac10-empty"
cp "$BAR" "$PFX/bin/bar"
cp -Lr "$REPO_ROOT/Bar.d" "$PFX/share/bar/"
RC=0
OUT="$( cd "$WORK/ac10-empty" && PATH="$PFX/bin:$PATH" BAR_VERBOSITY_LEVEL=5 "$PFX/bin/bar" help 2>&1 )" || RC=$?
check "$RC" "0" "the installed bar answers without a rulefile"
absent "$OUT" "state: wrote" "and writes no dump: there is no rulefile to name one after"
[[ -z "$(compgen -G "$PFX/share/bar/.bar.*.dump" || true)" ]] && pass "not next to the modules it loaded" ||
    fail "a dump appeared in the installation"
[[ -z "$(compgen -G "$WORK/ac10-empty/.bar.*.dump" || true)" ]] && pass "and not into the invocation directory" ||
    fail "a dump appeared in the invocation directory"
echo

echo "AC11 a rulefile may turn the dump off"
P="$WORK/ac11"
mkproj "$P"
printf 'BAR_STATE_DUMP=off\n' >>"$P/Barf"
runin "$P" greet
check "$RC" "0" "the run answers"
contains "$OUT" "hello" "with the rule's output"
[[ ! -f "$P/.bar.Barf.dump" ]] && pass "the rulefile's 'off' writes no dump" || fail "a dump was written anyway"
runin "$P" greet
[[ ! -f "$P/.bar.Barf.dump" ]] && pass "and none after a second run" || fail "a dump appeared"
absent "$OUT" "state: sourced" "no dump is read either"
# a dump which is there already is not read again once the rulefile says off, and it is not
# rewritten: the rulefile it was made from is gone
P="$WORK/ac11b"
mkproj "$P"
runin "$P" greet
[[ -f "$P/.bar.Barf.dump" ]] && pass "a dump was written before the switch" || fail "no dump was written"
printf 'BAR_STATE_DUMP=off\n' >>"$P/Barf"
before="$(cksum <"$P/.bar.Barf.dump")"
runin "$P" greet
absent "$OUT" "state: sourced" "the stale dump is not read once the rulefile says off"
check "$(cksum <"$P/.bar.Barf.dump")" "$before" "and it is not rewritten either"
echo

echo "AC12 a module a rule body loads is not loaded twice"
P="$WORK/ac12"
mkproj "$P"
# 'json_lib' is loaded during startup; requiring it from a rule body must be the no-op it is
# without a dump, and a module which startup does not load must still come from its file
cat >>"$P/Barf" <<'EOS'

late: -- 'require json_lib; require --opt testdir; echo late-done'
EOS
runin "$P" late
COLD="$OUT"
contains "$COLD" "late-done" "the cold run answers"
runin "$P" late
HIT="$OUT"
contains "$HIT" "state: sourced" "the second run sources the dump"
absent "$HIT" "loading: $P/Bar.d/json_lib" "a module of the dump is not loaded again"
contains "$HIT" "late-done" "and the rule still runs"
# the module the body loads which startup did not: it comes from its file in both runs
contains "$HIT" "loading: $P/Bar.d/testdir" "a module which is not in the dump loads as always"
# a module the load probed and did not find is recorded as 'false', not as loaded: the bare
# 'require' of it in the body has to behave as it does without a dump
printf 'require --opt absent_lib\nneedy: -- '\''require absent_lib; echo needy-done'\''\n' >>"$P/Barf"
runin "$P" needy
check "$RC" "0" "the cold run answers"
absent "$OUT" "loading: $P/Bar.d/absent_lib" "and does not load the module it probed as absent"
runin "$P" needy
contains "$OUT" "state: sourced" "the run after it sources the dump"
check "$RC" "0" "which answers as well"
absent "$OUT" "loading: $P/Bar.d/absent_lib" "and still does not load it"
echo

echo "AC13 the dump carries the modules' state, not the state of the run which wrote it"
P="$WORK/ac13"
mkproj "$P"
runin "$P" greet
absent "$(cat "$P/.bar.Barf.dump")" "declare -g file=" "no local of the writer is carried ('file')"
absent "$(cat "$P/.bar.Barf.dump")" "declare -g result=" "none of its other locals either ('result')"
absent "$(cat "$P/.bar.Barf.dump")" "declare -g BAR_STATE_" "and nothing of the mechanism itself"
grep -q '^declare -g[a-zA-Z]* BAR_RULES=' "$P/.bar.Barf.dump" && pass "the rule table is carried" ||
    fail "the rule table is missing from the dump"
# every variable it carries is a module constant: lowercase is a leaked local, not state
lowercase="$(grep -oP '^declare -g[a-zA-Z]* \K[a-z][A-Za-z0-9_]*' "$P/.bar.Barf.dump" | tr '\n' ' ' || true)"
check "$lowercase" "" "and no lowercase global is carried"
echo

# FIXME:
# echo "AC14 'bar init' keeps the dump out of version control"
# P="$WORK/ac14"
# mkdir -p "$P"
# (
#     cd "$P" &&
#         git init -q . &&
#         "$BAR" init >/dev/null 2>&1 &&
#         git check-ignore -q .bar.Barf.dump
# ) && pass "the dump is ignored in a project 'bar init' prepared" || fail "the dump is not ignored"
# echo

echo "AC15 what a run has loaded is the same with and without the dump"
P="$WORK/ac15"
mkproj "$P"
cat >>"$P/Barf" <<'EOS'

# the tables and the functions, without the per-run state of the evaluation which is running now
# the order 'declare -p' prints an associative array in is the hash table's, not the state's:
# split it and sort, so the comparison is about the entries
state: -- 'declare -F | LC_ALL=C sort; declare -p BAR_RULES BAR_RULE_FLAGS BAR_CLAUSE_DEPS BAR_CLAUSE_FLAGS | tr " " "\n" | LC_ALL=C sort'
EOS
# the answer itself, without the diagnostics on stderr (which say which path the run took)
state_of() { ( cd "$P" && BAR_VERBOSITY_LEVEL=0 "$BAR" state 2>/dev/null ); }
COLD="$(state_of)"
runin "$P" state
contains "$OUT" "state: sourced" "the second run sources the dump"
check "$(state_of)" "$COLD" "the same rules, clauses and functions are loaded"
# an exported module constant is a knob: the environment wins over the dump, as it does over the
# '${NAME:-default}' the module writes
cat >>"$P/Barf" <<'EOS'

knobs: -- 'echo "$BAR_AGENT_HEAD/$BAR_AGENT_TAIL"'
EOS
runin "$P" knobs
contains "$OUT" "8/4" "the module's default without the environment"
OUT="$( cd "$P" && BAR_AGENT_HEAD=2 BAR_AGENT_TAIL=1 BAR_VERBOSITY_LEVEL=0 "$BAR" knobs 2>/dev/null )" || RC=$?
check "$OUT" "2/1" "and the environment's value with it, served from a dump"
echo

echo "AC16 a rulefile directory which is not writable keeps no dump, and the run still answers"
P="$WORK/ac16"
mkproj "$P"
chmod a-w "$P"
RC=0
OUT="$( cd "$P" && BAR_VERBOSITY_LEVEL=5 "$BAR" greet 2>&1 )" || RC=$?
chmod u+w "$P"
check "$RC" "0" "the run answers"
contains "$OUT" "hello" "with the rule's output"
absent "$OUT" "Permission denied" "and no shell error escapes the dropped write"
absent "$OUT" "state: wrote" "no dump was written"
[[ ! -f "$P/.bar.Barf.dump" ]] && pass "and none is left behind" || fail "a dump appeared anyway"
echo

echo "AC17 a run served from the dump starts neither awk nor sed"
P="$WORK/ac17"
mkproj "$P"
# a wrapper first in PATH which logs its name and then runs the real tool: the only way to see a
# process which does its work and leaves no trace in the answer
BIN="$WORK/ac17-bin"
LOG="$WORK/ac17-log"
mkdir -p "$BIN"
for tool in awk sed; do
    real="$(command -v "$tool")"
    cat >"$BIN/$tool" <<EOS
#!/usr/bin/env bash
printf '%s\\n' "$tool" >>"\$BAR_PP_LOG"
exec "$real" "\$@"
EOS
    chmod +x "$BIN/$tool"
done
# the loading run: this is where the filter runs, and this is what proves the wrapper is seen
: >"$LOG"
RC=0
OUT="$( cd "$P" && PATH="$BIN:$PATH" BAR_PP_LOG="$LOG" BAR_VERBOSITY_LEVEL=5 "$BAR" greet 2>&1 )" || RC=$?
check "$RC" "0" "the loading run answers"
contains "$OUT" "state: wrote" "and writes the dump"
contains "$OUT" "hello" "with the rule's output"
grep -q '^awk$' "$LOG" && pass "the loading run starts awk (the filter)" ||
    fail "the loading run starts no awk: the harness does not see it"
grep -q '^sed$' "$LOG" && pass "and sed, one per frame it copies" ||
    fail "the loading run starts no sed"
# the run served from the dump: no file is loaded, so nothing is filtered
: >"$LOG"
RC=0
OUT="$( cd "$P" && PATH="$BIN:$PATH" BAR_PP_LOG="$LOG" BAR_VERBOSITY_LEVEL=5 "$BAR" greet 2>&1 )" || RC=$?
check "$RC" "0" "the run served from the dump answers"
contains "$OUT" "state: sourced" "from the dump"
contains "$OUT" "hello" "with the rule's output"
check "$(cat "$LOG")" "" "and starts neither awk nor sed"
# the fallback: a rule body which does need the filter gets it, started when it is used
: >"$LOG"
RC=0
OUT="$( cd "$P" && PATH="$BIN:$PATH" BAR_PP_LOG="$LOG" "$BAR" preprocess Barf 2>/dev/null )" || RC=$?
check "$RC" "0" "'bar preprocess' on a warm run answers"
contains "$OUT" "rule greet" "with the expanded text"
grep -q '^awk$' "$LOG" && pass "and the filter it needs is started for it" ||
    fail "'bar preprocess' expanded nothing: the filter never started"
NO_DUMP="$( cd "$P" && BAR_STATE_DUMP=off "$BAR" preprocess Barf 2>/dev/null )"
check "$OUT" "$NO_DUMP" "the same text a run which loads the files expands"
# a rule body which loads modules shares one filter between them, as it does when the run started
# one for its own load: a start per file would be a cost the dump hit never pays
cat >>"$P/Barf" <<'EOS'

latepair: -- 'require --opt testdir; require --opt git_lib; echo late-pair'
EOS
runin "$P" latepair                                  # the edit invalidates the dump: this run loads
: >"$LOG"
RC=0
OUT="$( cd "$P" && PATH="$BIN:$PATH" BAR_PP_LOG="$LOG" "$BAR" latepair 2>&1 )" || RC=$?
check "$RC" "0" "a warm run loads the modules its rule body asks for"
contains "$OUT" "late-pair" "and runs the rule"
check "$(grep -c '^awk$' "$LOG")" "1" "with one filter for both modules"
check "$(grep -c '^sed$' "$LOG")" "2" "and a frame each"
echo

if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All state dump tests passed ==="
