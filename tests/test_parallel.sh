#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for parallel dependency evaluation: the '+' prefix, the '--parallel' clause
# flag, BAR_PARALLEL, the barriers around them and the filter a job of its own starts.
#
#   AC1  '+' starts a run of dependencies at the same time, and BAR_PARALLEL bounds it
#   AC2  the verdict is taken in declared order at any BAR_PARALLEL
#   AC3  a checking dependency and a plain one are barriers: what was started before them is
#        collected before they run
#   AC4  the clause body is a barrier too: it sees every dependency it declared
#   AC5  a dependency evaluated in a job is remembered by the shell that started it
#   AC6  a clause marked '--parallel' is the '+' prefix on its non-checking dependencies
#   AC7  a job which requires a module gets a filter of its own, and the parent's still works
#   AC8  BAR_PARALLEL unset, empty or not a number evaluates exactly as serially
#   AC9  the run ends: a 'wait' in CLEANUP does not sit on the filter, and no filter is left
#   AC10 '~' is not a barrier: '+dep~' is a job and a run continues through it
#   AC11 'rule --parallel' is inherited by its clauses, '--conclusive' and '--default' opt out
#
# usage: tests/test_parallel.sh

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

# mkproj <dir> - a project of its own: this repository's modules as its 'Bar.d' and nothing else.
# The modules are copied (not linked) so that nothing a test does reaches the checkout.
mkproj() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
}

P="$WORK/proj"
mkproj "$P"
P_LOG="$WORK/log"
export P_LOG

cat >"$P/Barf" <<'EOF'
p_a:
	sleep 0.6 ; echo a >>"$P_LOG"

p_b:
	sleep 0.6 ; echo b >>"$P_LOG"

p_main: +p_a +p_b
	:

p_serial: p_a p_b
	:

slow_fail:
	sleep 0.6 ; echo slow >>"$P_LOG" ; return 3

fast_fail:
	sleep 0.6 ; echo fast >>"$P_LOG" ; return 5

p_verdict: +slow_fail +fast_fail
	:

side:
	echo side >>"$P_LOG"

needs_side:
	[ -s "$P_LOG" ]

p_check_barrier: +side needs_side?
	:

p_plain_barrier: +side needs_side
	:

p_body: +p_a +p_b
	[ "$(wc -l <"$P_LOG")" = 2 ]

counted:
	echo counted >>"$P_LOG"

p_memo: +counted
	:

p_memo: counted
	:

rule p_clause_flag: --parallel p_a p_b -- :

p_tilde_fail:
	sleep 0.6 ; echo tf >>"$P_LOG" ; return 4

p_tilde: +p_a +p_tilde_fail~ +p_b
	:

rule --parallel p_rule_flag: p_a p_b -- :

rule --parallel p_rule_flag_c: --conclusive p_a p_b -- :

rule --parallel p_rule_flag_d: --default p_a p_b -- :

j_a:
	require memodb
	echo "a:$(type -t memodb_init >/dev/null && echo ok || echo none)" >>"$P_LOG"

j_b:
	require sourcetree
	echo "b:$(type -t sourcetree_state >/dev/null && echo ok || echo none)" >>"$P_LOG"

j_main: +j_a +j_b
	require git_lib
	echo "p:$(type -t git_ls_files >/dev/null && echo ok || echo none)" >>"$P_LOG"

w_main:
	echo body >>"$P_LOG"

CLEANUP:
	wait
	echo cleanup >>"$P_LOG.cleanup"
EOF

# timed <parallel> <rule> - runs a rule in the project, recording RC and ELAPSED (milliseconds)
timed() {
    local par="$1"
    shift
    local start
    RC=0
    start=$(date +%s%N)
    ( cd "$P" && BAR_PARALLEL="$par" "$BAR" "$@" ) >"$WORK/out" 2>"$WORK/err" || RC=$?
    ELAPSED=$(( ($(date +%s%N) - start) / 1000000 ))
}

echo "=== Testing parallel dependency evaluation ==="
echo

echo "AC1 '+' starts a run of dependencies at the same time"
: >"$P_LOG"
timed 1 p_serial
serial_ms=$ELAPSED
: >"$P_LOG"
timed 2 p_serial
serial2_ms=$ELAPSED
: >"$P_LOG"
timed 1 p_main
par1_ms=$ELAPSED
check "$RC" "0" "BAR_PARALLEL=1: the rule succeeds"
check "$(sort "$P_LOG" | tr '\n' ' ')" "a b " "BAR_PARALLEL=1: both dependencies ran, once each"
: >"$P_LOG"
timed 2 p_main
par2_ms=$ELAPSED
check "$RC" "0" "BAR_PARALLEL=2: the rule succeeds"
check "$(sort "$P_LOG" | tr '\n' ' ')" "a b " "BAR_PARALLEL=2: both dependencies ran, once each"
if (( par2_ms + 400 < par1_ms )); then
    pass "the run overlaps: ${par2_ms}ms at 2 against ${par1_ms}ms at 1"
else
    fail "the run does not overlap: ${par2_ms}ms at 2 against ${par1_ms}ms at 1"
fi
if (( par1_ms + 400 > serial_ms && par1_ms < serial_ms + 900 )); then
    pass "BAR_PARALLEL=1 costs what the serial rule costs (${par1_ms}ms against ${serial_ms}ms)"
else
    fail "BAR_PARALLEL=1 is not the serial run (${par1_ms}ms against ${serial_ms}ms)"
fi
echo

echo "AC2 the verdict is taken in declared order"
: >"$P_LOG"
timed 2 p_verdict
check "$RC" "3" "BAR_PARALLEL=2: the first failing dependency decides, though the later one failed too"
check "$(sort "$P_LOG" | tr '\n' ' ')" "fast slow " "both ran, so the later one was already decided when the verdict was taken"
: >"$P_LOG"
timed 1 p_verdict
check "$RC" "3" "BAR_PARALLEL=1: the same verdict"
check "$(sort "$P_LOG" | tr '\n' ' ')" "slow " "serially the later one never ran"
echo

echo "AC3 a checking dependency and a plain one are barriers"
: >"$P_LOG"
timed 2 p_check_barrier
check "$RC" "0" "a '?dependency' ran after the job it checks the side effect of"
if (( ELAPSED + 400 < 1500 )); then
    pass "the barrier collected the started job instead of restarting it (${ELAPSED}ms)"
else
    fail "the barrier did not collect the started job (${ELAPSED}ms)"
fi
: >"$P_LOG"
timed 2 p_plain_barrier
check "$RC" "0" "a dependency without the prefix ran after the job it needs"
echo

echo "AC4 the clause body is a barrier too"
: >"$P_LOG"
timed 2 p_body
check "$RC" "0" "the body saw both dependencies finished"
echo

echo "AC5 a dependency evaluated in a job is remembered"
: >"$P_LOG"
timed 2 p_memo
check "$RC" "0" "the rule succeeds"
check "$(grep -c counted "$P_LOG" || true)" "1" "the second clause reused the result instead of running it again"
echo

echo "AC6 a clause marked '--parallel'"
: >"$P_LOG"
timed 1 p_clause_flag
flag1_ms=$ELAPSED
: >"$P_LOG"
timed 2 p_clause_flag
flag2_ms=$ELAPSED
check "$RC" "0" "the rule succeeds"
if (( flag2_ms + 400 < flag1_ms )); then
    pass "its dependencies ran together (${flag2_ms}ms against ${flag1_ms}ms)"
else
    fail "its dependencies ran serially (${flag2_ms}ms against ${flag1_ms}ms)"
fi
echo

echo "AC7 a job requiring a module gets a filter of its own"
: >"$P_LOG"
timed 2 j_main
check "$RC" "0" "the rule succeeds"
check "$(sort "$P_LOG" | tr '\n' ' ')" "a:ok b:ok p:ok " "the modules loaded in the jobs and in the parent"
echo

echo "AC8 BAR_PARALLEL unset, empty or not a number is the serial run"
: >"$P_LOG"
timed "" p_main
empty_ms=$ELAPSED
check "$RC" "0" "an empty BAR_PARALLEL: the rule succeeds"
check "$(sort "$P_LOG" | tr '\n' ' ')" "a b " "an empty BAR_PARALLEL: both dependencies ran"
if (( empty_ms + 400 > serial_ms )); then
    pass "an empty BAR_PARALLEL is the serial run (${empty_ms}ms)"
else
    fail "an empty BAR_PARALLEL ran in parallel (${empty_ms}ms against ${serial_ms}ms)"
fi
: >"$P_LOG"
timed "yes" p_main
check "$RC" "0" "a BAR_PARALLEL which is not a number: the rule succeeds"
if (( ELAPSED + 400 > serial_ms )); then
    pass "a non numeric BAR_PARALLEL is the serial run (${ELAPSED}ms)"
else
    fail "a non numeric BAR_PARALLEL ran in parallel (${ELAPSED}ms against ${serial_ms}ms)"
fi
echo

echo "AC9 the run ends"
: >"$P_LOG"
: >"$P_LOG.cleanup"
# a count, not an absolute: a filter of another run is none of this test's business
filters_before="$(pgrep -fc "mark='!!!!!!!!!!!!!!!!!EOF" || true)"
timed 2 w_main
check "$RC" "0" "a 'wait' in CLEANUP returns"
check "$(tr '\n' ' ' <"$P_LOG.cleanup")" "cleanup " "the filter was closed before CLEANUP ran"
check "$(tr '\n' ' ' <"$P_LOG")" "body " "the body ran once"
filters_after="$(pgrep -fc "mark='!!!!!!!!!!!!!!!!!EOF" || true)"
if [[ "$filters_after" = "$filters_before" ]]; then
    pass "no filter is left behind ($filters_after running)"
else
    fail "a filter was left behind ($filters_before before, $filters_after after)"
fi
echo
echo "AC10 '~' is not a barrier"
: >"$P_LOG"
timed 1 p_tilde
tilde1_ms=$ELAPSED
check "$RC" "0" "BAR_PARALLEL=1: the rule succeeds though a '~' dependency failed"
check "$(sort "$P_LOG" | tr '\n' ' ')" "a b tf " "all three dependencies ran"
: >"$P_LOG"
timed 3 p_tilde
tilde3_ms=$ELAPSED
check "$RC" "0" "BAR_PARALLEL=3: the rule succeeds"
if (( tilde3_ms + 400 < tilde1_ms )); then
    pass "the run continued through the '~' dependency (${tilde3_ms}ms against ${tilde1_ms}ms)"
else
    fail "the '~' dependency ended the run (${tilde3_ms}ms against ${tilde1_ms}ms)"
fi
echo

echo "AC11 'rule --parallel' is inherited, '--conclusive' and '--default' opt out"
: >"$P_LOG"
timed 2 p_rule_flag
check "$RC" "0" "the rule succeeds"
if (( ELAPSED + 400 < serial_ms )); then
    pass "the dependencies of its clause ran together (${ELAPSED}ms against ${serial_ms}ms serially)"
else
    fail "the rule flag did not reach its clause (${ELAPSED}ms against ${serial_ms}ms serially)"
fi
: >"$P_LOG"
timed 2 p_rule_flag_c
check "$RC" "0" "a '--conclusive' clause succeeds"
if (( ELAPSED + 400 > serial_ms )); then
    pass "'--conclusive' stayed serial (${ELAPSED}ms)"
else
    fail "'--conclusive' inherited the rule flag (${ELAPSED}ms against ${serial_ms}ms serially)"
fi
: >"$P_LOG"
timed 2 p_rule_flag_d
check "$RC" "0" "a '--default' clause succeeds"
if (( ELAPSED + 400 > serial_ms )); then
    pass "'--default' stayed serial (${ELAPSED}ms)"
else
    fail "'--default' inherited the rule flag (${ELAPSED}ms against ${serial_ms}ms serially)"
fi
echo

if (( failures > 0 )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "all checks passed"