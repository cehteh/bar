#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for an interrupted run: '^C' ends the run, and so does everything it started.
#
#   AC1 a parallel run which is interrupted kills the jobs it started, and its own exit path runs
#   AC2 a body's own background children go with the run as well
#   AC3 'TERM' is the same ending, with the status of its own
#
# usage: tests/test_interrupt.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mkproj <dir> - a project of its own: this repository's modules as its 'Bar.d' and nothing else.
mkproj() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
}

P="$WORK/proj"
mkproj "$P"
P_LOG="$WORK/log"
export P_LOG
# the run's job directory is its own per run; a private TMPDIR is how a leak is seen
JOBTMP="$WORK/tmp"
mkdir -p "$JOBTMP"

# every child announces itself, so that the test knows what to look for after the run is gone
cat >"$P/Barf" <<'EOF'
longjob:
	sleep 31 & echo $! >>"$P_LOG" ; wait

longjob2:
	sleep 32 & echo $! >>"$P_LOG" ; wait

rule --parallel p_kids: longjob longjob2 -- :

body_bg: -- :
	sleep 34 & echo $! >>"$P_LOG" ; wait

CLEANUP:
	echo cleanup >>"$P_LOG"
EOF

# interrupted <signal> <rule> - runs the rule in a process group of its own and signals that group
# once its children are there; RUN_RC is the run's status and CHILDREN the pids it reported
interrupted() {
    local sig="$1" rule="$2" i pid waiter
    : >"$P_LOG"
    rm -f "$WORK/run.pid" "$WORK/run.rc"
    # 'set -m' is job control, which is the shell a terminal runs bar in: the run gets a process
    # group of its own and '^C' is a signal to that group, not to the run alone
    (
        set -m
        ( cd "$P" && TMPDIR="$JOBTMP" exec "$BAR" "$rule" ) >"$WORK/out" 2>&1 &
        echo $! >"$WORK/run.pid"
        rc=0
        wait $! || rc=$?
        echo "$rc" >"$WORK/run.rc"
    ) 2>/dev/null &
    waiter=$!
    for ((i = 0; i < 500; i++)); do
        [[ -s "$WORK/run.pid" ]] && [[ -s "$P_LOG" ]] && break
        sleep 0.02
    done
    pid="$(<"$WORK/run.pid")"
    kill -"$sig" -- "-$pid" 2>/dev/null || kill -"$sig" "$pid" 2>/dev/null || true
    for ((i = 0; i < 500; i++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.02
    done
    wait "$waiter" 2>/dev/null || true
    RUN_RC=0
    [[ -s "$WORK/run.rc" ]] && RUN_RC="$(<"$WORK/run.rc")"
    CHILDREN=()
    [[ -s "$P_LOG" ]] && mapfile -t CHILDREN < <(grep -E '^[0-9]+$' "$P_LOG")
}

# alive <pids..> - how many of them are still running
alive() {
    local -i count=0
    local pid
    for pid in "$@"; do
        kill -0 "$pid" 2>/dev/null && count=$((count + 1))
    done
    echo "$count"
}

echo "AC1 a parallel run which is interrupted kills the jobs it started"
interrupted INT p_kids
check "${#CHILDREN[@]}" "2" "both jobs announced their child"
check "$(alive ${CHILDREN[@]+"${CHILDREN[@]}"})" "0" "no child of a job outlived the run"
check "$RUN_RC" "130" "the run ends with the status of '^C'"
check "$(grep -c '^cleanup$' "$P_LOG" || true)" "1" "the run's exit path still ran CLEANUP"
check "$(find "$JOBTMP" -maxdepth 1 -name 'bar-jobs.*' | wc -l)" "0" "the run's job directory went with it"
echo

echo "AC2 a body's own background children go with the run as well"
interrupted INT body_bg
check "${#CHILDREN[@]}" "1" "the body announced its child"
check "$(alive ${CHILDREN[@]+"${CHILDREN[@]}"})" "0" "no child a body started outlived the run"
check "$RUN_RC" "130" "the run ends with the status of '^C'"
check "$(grep -c '^cleanup$' "$P_LOG" || true)" "1" "the run's exit path still ran CLEANUP"
echo

echo "AC3 'TERM' is the same ending, with the status of its own"
interrupted TERM p_kids
check "$(alive ${CHILDREN[@]+"${CHILDREN[@]}"})" "0" "no child of a job outlived the run"
check "$RUN_RC" "143" "the run ends with the status of 'TERM'"
check "$(find "$JOBTMP" -maxdepth 1 -name 'bar-jobs.*' | wc -l)" "0" "the run's job directory went with it"
echo

if (( failures > 0 )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi

echo "all checks passed"
