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
#   AC8  BAR_PARALLEL is the machine's count unless the caller says otherwise, and a value which
#        is not a number is the serial run
#   AC9  the run ends: a 'wait' in CLEANUP does not sit on the filter, and no filter is left
#   AC10 '~' is not a barrier: '+dep~' is a job and a run continues through it
#   AC11 'rule --parallel' is inherited by its clauses, '--conclusive' and '--default' opt out
#   AC12 a job's own jobs spend from one budget for the whole tree
#   AC13 a rule two jobs both need is evaluated once, and its verdict is theirs
#   AC14 the clauses of a '--parallel' rule run their dependencies at the same time
#   AC15 the rules of 'ParallelTest': every one of them costs one dependency, not the sum
#   AC16 early fail: a failure starts nothing more, and a body which runs finishes
#   AC17 '--parallel' with the other rule and clause flags: no error, and the incompatible ones
#        fall back to the serial evaluation
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
P_NESTED="$WORK/nested"
export P_NESTED

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

n_leaf:
	_ns=$(date +%s%N) ; sleep 0.3 ; printf '%s %s\n' "$_ns" "$(date +%s%N)" >>"$P_NESTED"

n_arm1: "+n_leaf 1" "+n_leaf 2"
	:

n_arm2: "+n_leaf 3" "+n_leaf 4"
	:

n_main: +n_arm1 +n_arm2
	:

d_shared:
	sleep 0.3 ; echo shared >>"$P_LOG"

d_shared_bad:
	sleep 0.3 ; echo shared >>"$P_LOG" ; false

d_arm1: d_shared
	:

d_arm2: d_shared
	:

d_main: +d_arm1 +d_arm2
	:

d_arm1_bad: d_shared_bad
	:

d_arm2_bad: d_shared_bad
	:

d_main_bad: +d_arm1_bad +d_arm2_bad
	:

w_main:
	echo body >>"$P_LOG"

q_one:
	sleep 0.4 ; echo one >>"$P_LOG"

q_two:
	sleep 0.4 ; echo two >>"$P_LOG"

q_three:
	sleep 0.4 ; echo three >>"$P_LOG"

q_four:
	sleep 0.4 ; echo four >>"$P_LOG"

rule --parallel q_main: q_one -- 'echo b1 >>"$P_LOG"'
rule --parallel q_main: q_two -- 'echo b2 >>"$P_LOG"'
rule --parallel q_main: q_three -- 'echo b3 >>"$P_LOG"'
rule --parallel q_main: q_four -- 'echo b4 >>"$P_LOG"'

rule --parallel --disjunct q_disjunct: q_one -- :
rule --parallel --disjunct q_disjunct: q_two -- :
rule --parallel --disjunct q_disjunct: q_three -- :
rule --parallel --disjunct q_disjunct: q_four -- :

# The rules of 'ParallelTest', the rulefile the pool was asked for: every one of them costs about
# one dependency's time, and a disjunct rule keeps its clauses in order.
pb1: (sleep 0.5)
pb2: (sleep 0.5)
pb3: (sleep 0.5)
pb4: (sleep 0.5)

rule --parallel pb_main: pb1 pb2 pb3 pb4

pl_slow1: ; sleep 0.5
pl_slow2: ; sleep 0.5
pl_slow3: ; sleep 0.5
pl_slow4: ; sleep 0.5
pl_false: ; false

rule --parallel pl_slow1x4: pl_slow1 pl_slow2 pl_slow3 pl_slow4

rule --parallel pl_slow2x2: pl_slow1 pl_slow2
rule --parallel pl_slow2x2: pl_slow3 pl_slow4

rule --parallel pl_slow4x1: pl_slow1
rule --parallel pl_slow4x1: pl_slow2
rule --parallel pl_slow4x1: pl_slow3
rule --parallel pl_slow4x1: pl_slow4

rule --parallel pl_early1x5: pl_slow1 pl_slow2 pl_slow3 pl_slow4 pl_false

rule --parallel pl_early5x1: pl_slow1
rule --parallel pl_early5x1: pl_slow2
rule --parallel pl_early5x1: pl_slow3
rule --parallel pl_early5x1: pl_slow4
rule --parallel pl_early5x1: pl_false

rule --parallel --disjunct pl_disjunct: pl_slow1 pl_slow2 -- 'echo d1 >>"$P_LOG"'
rule --parallel --disjunct pl_disjunct: pl_slow3 pl_slow4 -- 'echo d2 >>"$P_LOG"'

pl_caching: pl_caching_inner
pl_caching_inner: pl_slow1x4 pl_slow4x1
pl_caching_inner: pl_slow1x4 pl_slow4x1

# early fail: the first dependency fails, so what has not started is not started -- and the leaf
# which is already running is collected, not killed.  Six leaves to a budget of two: a walk which
# did not stop would take three waves of 0.3s, so one wave plus the failure is what the timing
# below proves.
ef_bad:
	sleep 0.1
	echo bad >>"$P_LOG"
	false

ef_l1:
	echo start1 >>"$P_LOG"
	sleep 0.3
	echo done1 >>"$P_LOG"

ef_l2:
	echo start2 >>"$P_LOG"
	sleep 0.3
	echo done2 >>"$P_LOG"

ef_l3:
	echo start3 >>"$P_LOG"
	sleep 0.3
	echo done3 >>"$P_LOG"

ef_l4:
	echo start4 >>"$P_LOG"
	sleep 0.3
	echo done4 >>"$P_LOG"

ef_l5:
	echo start5 >>"$P_LOG"
	sleep 0.3
	echo done5 >>"$P_LOG"

ef_l6:
	echo start6 >>"$P_LOG"
	sleep 0.3
	echo done6 >>"$P_LOG"

rule --parallel ef_main: ef_bad ef_l1 ef_l2 ef_l3 ef_l4 ef_l5 ef_l6

# keep-going: the run continues after a failure, so nothing is abandoned
kg_bad:
	echo bad >>"$P_LOG"
	false

kg_after:
	echo after >>"$P_LOG"

rule --parallel kg_main: p_a kg_bad kg_after

# '--parallel' beside the flags it can not use: every one of these is a fallback, never an error
rule --parallel --meta ip_meta: p_a p_b -- :

rule --parallel --reverse ip_reverse: p_a p_b -- :

rule --parallel ip_clause_flags: --conclusive p_a -- :
rule --parallel ip_clause_flags: --default p_b -- :

rule --parallel ip_conditional: p_a "p_b?" -- :

rule --parallel ip_negated: p_a "!p_tilde_fail" -- :

rule --bare bb_a: -- :

rule --bare bb_b: -- :

rule --parallel --bare ip_bare: bb_a bb_b -- :

rule --always p_always: -- :

rule --parallel ip_always: p_a p_always p_b -- :

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

# timed_env <parallel> <NAME=value> <rule> - 'timed' with one more variable in the run's environment
timed_env() {
    local par="$1" assign="$2"
    shift 2
    local start
    RC=0
    start=$(date +%s%N)
    ( cd "$P" && env BAR_PARALLEL="$par" "$assign" "$BAR" "$@" ) >"$WORK/out" 2>"$WORK/err" || RC=$?
    ELAPSED=$(( ($(date +%s%N) - start) / 1000000 ))
}

echo "=== Testing parallel dependency evaluation ==="
echo

echo "AC1 '+' starts a run of dependencies at the same time"
: >"$P_LOG"
timed 1 p_serial
serial_ms=$ELAPSED
# The first run in a project builds its state dump and a busy machine only ever adds time, so the
# baseline below is the better of two: one slow sample must not fail every comparison it serves.
: >"$P_LOG"
timed 1 p_serial
(( ELAPSED < serial_ms )) && serial_ms=$ELAPSED
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

echo "AC8 BAR_PARALLEL is the machine's count unless the caller says otherwise"
# how a run at the default looks depends on the machine: one processor is the serial run
nproc_now="$(nproc 2>/dev/null || echo 1)"
default_is_parallel() {
    # <milliseconds> <what> - the default budget's verdict, judged against the serial run
    if (( nproc_now > 1 )); then
        if (( $1 + 400 < serial_ms )); then
            pass "$2 ran in parallel, one job per processor (${1}ms against ${serial_ms}ms serially)"
        else
            fail "$2 did not use the default budget (${1}ms against ${serial_ms}ms serially)"
        fi
    else
        if (( $1 + 400 > serial_ms )); then
            pass "$2 is the serial run on this machine (${1}ms)"
        else
            fail "$2 was parallel on a single processor (${1}ms)"
        fi
    fi
}
: >"$P_LOG"
timed "" p_main
empty_ms=$ELAPSED
check "$RC" "0" "an empty BAR_PARALLEL: the rule succeeds"
check "$(sort "$P_LOG" | tr '\n' ' ')" "a b " "an empty BAR_PARALLEL: both dependencies ran"
default_is_parallel "$empty_ms" "an empty BAR_PARALLEL"
: >"$P_LOG"
RC=0
start=$(date +%s%N)
( cd "$P" && env -u BAR_PARALLEL "$BAR" p_main ) >"$WORK/out" 2>"$WORK/err" || RC=$?
unset_ms=$(( ($(date +%s%N) - start) / 1000000 ))
check "$RC" "0" "an unset BAR_PARALLEL: the rule succeeds"
default_is_parallel "$unset_ms" "an unset BAR_PARALLEL"
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

echo "AC12 a job's own jobs spend from the budget of the tree"
# four leaves, two arms, each arm a job: a budget per shell would start all four at once
: >"$P_NESTED"
timed 2 n_main
check "$RC" "0" "BAR_PARALLEL=2: the nested rule succeeds"
check "$(wc -l <"$P_NESTED" | tr -d ' ')" "4" "all four leaves ran, each once"
overlap="$(awk '{print $1"\t1"; print $2"\t-1"}' "$P_NESTED" | sort -n -k1,1 -k2,2 | awk '{c+=$2; if (c>m) m=c} END{print m+0}')"
if (( overlap <= 2 )); then
    pass "at most two leaves ran at once ($overlap): the arms spend from the same budget"
else
    fail "$overlap leaves ran at once at BAR_PARALLEL=2: the arms started a budget of their own"
fi
: >"$P_NESTED"
timed 4 n_main
check "$RC" "0" "BAR_PARALLEL=4: the nested rule succeeds"
check "$(wc -l <"$P_NESTED" | tr -d ' ')" "4" "all four leaves ran, each once, at 4 too"
overlap="$(awk '{print $1"\t1"; print $2"\t-1"}' "$P_NESTED" | sort -n -k1,1 -k2,2 | awk '{c+=$2; if (c>m) m=c} END{print m+0}')"
if (( overlap > 2 && overlap <= 4 )); then
    pass "a larger budget reaches the leaves below the arms ($overlap at 4)"
else
    fail "the budget did not reach the leaves below the arms ($overlap at 4)"
fi
: >"$P_NESTED"
timed 1 n_main
check "$RC" "0" "BAR_PARALLEL=1: the nested rule succeeds"
check "$(wc -l <"$P_NESTED" | tr -d ' ')" "4" "all four leaves ran serially"
overlap="$(awk '{print $1"\t1"; print $2"\t-1"}' "$P_NESTED" | sort -n -k1,1 -k2,2 | awk '{c+=$2; if (c>m) m=c} END{print m+0}')"
check "$overlap" "1" "nothing overlapped at 1, in the tree as in one shell"
# the server and the store are the run's: a run which had them leaves none behind, CLEANUP included
jobtmp="$WORK/jobtmp"
mkdir -p "$jobtmp"
RC=0
( cd "$P" && TMPDIR="$jobtmp" BAR_PARALLEL=2 "$BAR" n_main ) >"$WORK/out" 2>"$WORK/err" || RC=$?
check "$RC" "0" "the rule succeeds with a TMPDIR of its own"
check "$(ls -A "$jobtmp" | wc -l | tr -d ' ')" "0" "the run took its job directory with it"
echo

echo "AC13 a rule two jobs both need is evaluated once"
# the diamond: two arms as jobs, one rule they share -- without a store each arm evaluates it
: >"$P_LOG"
timed 2 d_main
check "$RC" "0" "the rule succeeds"
check "$(grep -c shared "$P_LOG" || true)" "1" "the shared rule ran once, though both arms needed it"
if (( ELAPSED + 400 < 900 )); then
    pass "the second arm took the stored verdict instead of evaluating again (${ELAPSED}ms)"
else
    fail "the second arm evaluated the shared rule again (${ELAPSED}ms for one 300ms rule)"
fi
: >"$P_LOG"
timed 2 d_main_bad
check "$RC" "1" "the shared failure is the verdict of the diamond"
check "$(grep -c shared "$P_LOG" || true)" "1" "and it was still evaluated once"
: >"$P_LOG"
timed 2 d_main
check "$(grep -c shared "$P_LOG" || true)" "1" "a later run evaluates again: the store lives with its run"
echo

echo "AC14 the clauses of a '--parallel' rule run their dependencies at the same time"
# four clauses, one 400ms dependency each: pooled they cost one dependency, serially the sum, and
# the bodies stay in declared order -- a body works in the directory
: >"$P_LOG"
timed 1 q_main
q_serial_ms=$ELAPSED
check "$RC" "0" "BAR_PARALLEL=1: the rule succeeds"
: >"$P_LOG"
timed 4 q_main
check "$RC" "0" "BAR_PARALLEL=4: the rule succeeds"
check "$(grep -v '^b' "$P_LOG" | sort | tr '\n' ' ')" "four one three two " "every clause's dependency ran, once each"
check "$(grep '^b' "$P_LOG" | tr '\n' ' ')" "b1 b2 b3 b4 " "the bodies ran in declared order"
if (( ELAPSED + 600 < q_serial_ms )); then
    pass "the four clauses cost one dependency (${ELAPSED}ms against ${q_serial_ms}ms serially)"
else
    fail "the clauses did not overlap (${ELAPSED}ms against ${q_serial_ms}ms serially)"
fi
# a disjunct rule keeps its clauses in order: the clause tried first is its meaning
: >"$P_LOG"
timed 4 q_disjunct
check "$RC" "0" "a '--parallel --disjunct' rule succeeds on its first clause"
check "$(sort "$P_LOG" | tr '\n' ' ')" "one " "the clauses after it were not started: disjunct stays in order"
echo

echo "AC15 the rules of 'ParallelTest' cost one dependency, not the sum"
# that file's own budget is 10 and its leaves sleep 1s; here the leaves sleep 0.5 and the bar is
# 1300ms, which is the same claim on a shorter suite
for pl_rule in pl_slow1x4 pl_slow2x2 pl_slow4x1 pl_early1x5 pl_early5x1 pl_disjunct pl_caching; do
    case "$pl_rule" in
    pl_early*) want_rc=1 ;;
    *)         want_rc=0 ;;
    esac
    : >"$P_LOG"
    timed 10 "$pl_rule"
    check "$RC" "$want_rc" "$pl_rule: the verdict"
    if (( ELAPSED < 1300 )); then
        pass "$pl_rule: one dependency's time (${ELAPSED}ms)"
    else
        fail "$pl_rule: the sum of its dependencies (${ELAPSED}ms)"
    fi
done
# a disjunct rule keeps its clauses in order: the clause tried first is its meaning
: >"$P_LOG"
timed 10 pl_disjunct
check "$RC" "0" "pl_disjunct: succeeds on its first clause"
check "$(sort "$P_LOG" | tr '\n' ' ')" "d1 " "the disjunct rule ran its first clause only"
# the same shape serially is the sum
: >"$P_LOG"
timed 1 pl_slow4x1
pl_serial_ms=$ELAPSED
check "$RC" "0" "pl_slow4x1 serially: the rule succeeds"
: >"$P_LOG"
timed 10 pl_slow4x1
if (( ELAPSED + 800 < pl_serial_ms )); then
    pass "the four clauses cost one dependency (${ELAPSED}ms against ${pl_serial_ms}ms serially)"
else
    fail "the clauses did not overlap (${ELAPSED}ms against ${pl_serial_ms}ms serially)"
fi
echo

echo "AC16 early fail: a failure starts nothing more, and a body which runs finishes"
# two of seven leaves fit the budget: the failing dependency and one leaf.  The failure lands while
# that leaf's body is running, so the leaf is collected -- a body is the atomic unit of work, never
# killed -- and the five leaves behind it are never started.  One wave plus the failure is 0.4s
# here; three waves of them would be 0.9s.
: >"$P_LOG"
timed 2 ef_main
check "$RC" "1" "the failure is the rule's verdict"
check "$(grep -c '^start' "$P_LOG" || true)" "1" "only the one leaf the budget started ran"
check "$(grep -c '^done' "$P_LOG" || true)" "1" "and it finished: a body is atomic, it is not killed"
check "$(grep -c '^bad' "$P_LOG" || true)" "1" "the failing dependency ran"
if (( ELAPSED < 700 )); then
    pass "the failure cost one wave, not six leaves (${ELAPSED}ms)"
else
    fail "the work behind the failure was still run (${ELAPSED}ms)"
fi
# a budget which covers every dependency starts all of them: they are running, so they complete
: >"$P_LOG"
timed 8 ef_main
check "$RC" "1" "a budget of 8: the verdict is the same"
check "$(grep -c '^start' "$P_LOG" || true)" "6" "all six leaves were started: the budget had room"
check "$(grep -c '^done' "$P_LOG" || true)" "6" "and every one of them finished: a body is atomic"
# keep-going: the run does not stop, so nothing is abandoned
: >"$P_LOG"
timed_env 4 BAR_KEEP_GOING=2 kg_main
check "$RC" "1" "keep-going: the failure is the rule's verdict"
contains "$(tr '\n' ' ' <"$P_LOG")" "after " "keep-going: the clause after the failure ran"
echo

echo "AC17 '--parallel' beside the other rule and clause flags"
# every combination is a fallback, never an error: the rule completes and bar does not panic
for ip_rule in ip_meta ip_reverse ip_clause_flags ip_conditional ip_negated ip_bare ip_always; do
    : >"$P_LOG"
    timed 4 "$ip_rule"
    check "$RC" "0" "$ip_rule: the rule succeeds"
    absent "$(cat "$WORK/err")" "PANIC:" "$ip_rule: no fatal error"
done
# '--meta' is shared state, so it is the serial evaluation
: >"$P_LOG"
timed 4 ip_meta
meta_ms=$ELAPSED
if (( meta_ms + 400 > serial_ms )); then
    pass "'--parallel --meta' falls back to the serial evaluation (${meta_ms}ms)"
else
    fail "'--parallel --meta' ran its dependencies together (${meta_ms}ms against ${serial_ms}ms)"
fi
# '--reverse' only reorders the clauses: the dependencies are still pooled
: >"$P_LOG"
timed 4 ip_reverse
if (( ELAPSED + 400 < serial_ms )); then
    pass "'--parallel --reverse' still pools the dependencies (${ELAPSED}ms)"
else
    fail "'--parallel --reverse' did not overlap (${ELAPSED}ms against ${serial_ms}ms)"
fi
echo

echo "AC18 the progress notices of a parallel run leave no empty line behind"
# A notice is written without its newline and cleared in place by the next message.  Another shell
# may have ended that line already (every job writes to the same terminal), and the notice must not
# then end it a second time: that was a blank line in front of the next message.
if command -v script >/dev/null 2>&1; then
    play=$( ( cd "$P" && TERM=xterm BAR_PARALLEL=4 timeout 20 script -qec "$BAR pb_main" /dev/null 2>/dev/null ) || true )
    plain=$(printf '%s' "$play" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g')
    check "$(printf '%s' "$plain" | grep -c '^[[:space:]]*$' || true)" "0" "no empty line in the terminal output"
    contains "$plain" "OK: pb_main" "the run's own result was printed"
else
    pass "no 'script' on this host: the terminal output is not exercised"
fi
echo

if (( failures > 0 )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "all checks passed"