#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Reproducer: a bare 'wait' in a rule body deadlocks against the rule file filter.
#
# The filter (:func:`barf_pp_start`) is a coprocess of the shell which evaluates rule bodies, and a
# bare 'wait' waits for every child of that shell -- the filter included.  The filter ends only when
# the run closes its write end (:func:`barf_pp_stop`, from the EXIT trap), so a body which waits for
# its own background jobs waits for a process which is waiting for the run: the run never returns.
# Issue 9497e448cedcd73bf1062d9773faf86558f4cd52.
#
#   AC1  a body which opens background jobs and then says 'wait' returns, and both jobs ran
#   AC2  the filter still serves frames afterwards: a module a later body loads of the same run
#   AC3  a second run of the same project exits 0 -- the close in the EXIT trap is the run's last
#        command, so a status it cannot have becomes the run's own exit status
#
# usage: tests/test_bare_wait.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mkproj <dir> - a project of its own: this repository's modules as its 'Bar.d' and a rule file
# which opens two background jobs and waits for them the plain way.
mkproj() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
    cat >"$dir/Barf" <<'EOS'
waits: -- 'echo a & echo b & wait'
after: -- 'require --opt testdir'
MAIN: waits after
EOS
}

RC=0
OUT=""
# runin <dir> - run the project's MAIN under a timeout: on the deadlock it never returns, and the
# timeout's own kill is what makes the failure visible instead of hanging the suite
runin() {
    local dir="$1"
    RC=0
    OUT="$(cd "$dir" && timeout 10 "$BAR" 2>"$WORK/err")" || RC=$?
}

echo "=== Testing a bare 'wait' in a rule body ==="
echo

echo "AC1 a body which says 'wait' returns"
P="$WORK/p1"
mkproj "$P"
runin "$P"
check "$RC" "0" "the run exits 0 (124 is the deadlock: 'wait' never returned)"
contains "$OUT" "a" "the first background job ran"
contains "$OUT" "b" "the second background job ran"
echo

echo "AC2 the filter still serves frames after that body"
check "$(grep -c 'the rule file filter stopped mid run' "$WORK/err" || true)" "0" \
    "no frame was lost after the body waited"
check "$RC" "0" "the later body's module load succeeded"
echo

echo "AC3 a second run of the same project exits 0"
FIRST_RC="$RC"
runin "$P"
check "$RC" "0" "the warm run exits 0 (${FIRST_RC} was the fresh one)"
echo

echo "AC4 a body which fails after its wait still fails the run"
Q="$WORK/p2"
mkdir -p "$Q/Bar.d"
cp -Lr "$REPO_ROOT/Bar.d/." "$Q/Bar.d/"
cat >"$Q/Barf" <<'EOS'
fails: -- 'echo x & wait; exit 3'
MAIN: fails
EOS
runin "$Q"
check "$RC" "3" "the body's own status reaches the caller (not 127 from the stop, not 0)"
contains "$OUT" "x" "and its background job ran before it"
echo

if ((failures)); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All bare wait tests passed ==="
