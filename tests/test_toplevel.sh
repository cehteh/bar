#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
# shellcheck shell=bash
#
# Tests for find_toplevel: which rule directory is found and what BAR_TOPLEVEL becomes.
#
# Regression for the defect where find_toplevel's upward walk clobbered BAR_TOPLEVEL.  With no
# 'Bar.d' anywhere it was left at the last ancestor the walk had reached (or '/') while BAR_DIR
# correctly fell back to the installed modules.  Everything below BAR_TOPLEVEL then pointed outside
# of the project -- the rulefile lookup and the agent run directory: 'cd /tmp && bar verdict <t>'
# tried to create '//.bar.agent' and, where '/' is not writable, reported every target as failed
# without writing a log.  The fixture below therefore must have no rule directory in itself or in
# any ancestor, and the tests must not depend on '/' being unwritable.
#
#   AC1  no rule directory anywhere: BAR_TOPLEVEL is the invocation directory, BAR_DIR the
#        installed fallback
#   AC2  the same, from a subdirectory of it: BAR_TOPLEVEL is the invocation directory, not the
#        directory the walk reached
#   AC3  a rule directory in the invocation directory: BAR_TOPLEVEL is that directory
#   AC4  a rule directory in an ancestor: found from a subdirectory, BAR_TOPLEVEL is the ancestor
#        that holds it (this is where the rulefile lookup happens too)
#   AC5  the alternative names 'bar.d', '.Bar.d', '.bar.d' are honoured and 'Bar.d' wins
#   AC6  'makeitso' keeps its single, absolute module directory and searches no ancestor
#   AC7  the reproducing command: rc and stdout block are the same in and outside a tree, and
#        every log path is below the invocation directory, never below '/'  (needs agent_rules)
#   AC8  the fallback run actually runs: a target that passes is reported 'OK' and its log is
#        below the invocation directory  (needs agent_rules)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }

# write_barf <file> - the throw-away rulefile of the fixtures, prints what find_toplevel decided
write_barf() {
    cat >"$1" <<'BARF'
rule toplevel: -- 'printf "TOP=%s\nDIR=%s\n" "$BAR_TOPLEVEL" "$BAR_DIR"'
BARF
}

# link_modules <dir> - link every module of this tree into a rule directory of the fixtures
link_modules() {
    local target="$1" module
    mkdir -p "$target"
    for module in "$REPO_ROOT"/Bar.d/*; do
        ln -s "$module" "$target/$(basename "$module")"
    done
}

echo "=== Testing find_toplevel / BAR_TOPLEVEL ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# a fake installation: 'command -v bar' resolves here, so BAR_PREFIX is $WORK/inst and the
# installed fallback loads this tree's modules instead of whatever is deployed on the host
mkdir -p "$WORK/inst/bin" "$WORK/inst/share/bar"
ln -s "$BAR" "$WORK/inst/bin/bar"
link_modules "$WORK/inst/share/bar/Bar.d"

# a tree with a rule directory, and the same tree as seen from a subdirectory
mkdir -p "$WORK/tree/sub/deep"
link_modules "$WORK/tree/Bar.d"
write_barf "$WORK/tree/Barf"

# a directory with no rule directory in itself or in any ancestor, and one below it
mkdir -p "$WORK/nodir/sub"
write_barf "$WORK/nodir/Barf"
write_barf "$WORK/nodir/sub/Barf"

# runs the target with the fake installation on PATH: <dir> <target..>
run() {
    local dir="$1"
    shift
    (cd "$dir" && PATH="$WORK/inst/bin:$PATH" "$BAR" "$@" 2>/dev/null)
}

# the same for the 'makeitso' personality (the invocation name decides it): <dir> <home> <target..>
run_makeitso() {
    local dir="$1" home="$2"
    shift 2
    (cd "$dir" && PATH="$WORK/inst/bin:$PATH" HOME="$home" "$dir/makeitso" "$@" 2>/dev/null)
}

# ---- AC1, AC2: no rule directory anywhere -------------------------------------------------
#
# the fixture premise: no rule directory in the fixture, its subdirectory or any of its ancestors.
# where the filesystem or the host obstructs that, say so instead of failing obscurely below.
premise=
cursor="$(cd "$WORK/nodir" && pwd)"
while :; do
    for name in Bar.d bar.d .Bar.d .bar.d; do
        [[ -d "$cursor/$name" ]] && premise="$cursor/$name"
    done
    [[ "$cursor" == "/" ]] && break
    cursor="$(readlink -f "$cursor/..")"
done
if [[ -n "$premise" ]]; then
    fail "AC1/AC2: fixture premise broken, a rule directory exists at $premise"
else
    pass "AC1: no rule directory in the fixture or in any ancestor of it"
fi

check "$(run "$WORK/nodir" toplevel)" \
    "TOP=$WORK/nodir
DIR=$WORK/inst/share/bar/Bar.d" \
    "AC1: no rule directory: BAR_TOPLEVEL is the invocation directory, BAR_DIR the installed fallback"

check "$(run "$WORK/nodir/sub" toplevel)" \
    "TOP=$WORK/nodir/sub
DIR=$WORK/inst/share/bar/Bar.d" \
    "AC2: no rule directory: BAR_TOPLEVEL is the invocation directory, not the directory the walk reached"

# ---- AC3, AC4: an in-tree rule directory is still found ------------------------------------
check "$(run "$WORK/tree" toplevel)" \
    "TOP=$WORK/tree
DIR=$WORK/tree/Bar.d" \
    "AC3: rule directory in the invocation directory: BAR_TOPLEVEL is that directory"

check "$(run "$WORK/tree/sub/deep" toplevel)" \
    "TOP=$WORK/tree
DIR=$WORK/tree/Bar.d" \
    "AC4: rule directory in an ancestor: found from a subdirectory, BAR_TOPLEVEL is the ancestor"

# ---- AC5: the alternative names, in their documented precedence ----------------------------
alt="$WORK/alt"
mkdir -p "$alt"
link_modules "$alt/bar.d"
write_barf "$alt/Barf"

check "$(run "$alt" toplevel)" \
    "TOP=$alt
DIR=$alt/bar.d" \
    "AC5: 'bar.d' is honoured like 'Bar.d', BAR_TOPLEVEL is the directory that holds it"

both="$WORK/both"
mkdir -p "$both"
link_modules "$both/Bar.d"
link_modules "$both/bar.d"
write_barf "$both/Barf"

check "$(run "$both" toplevel)" \
    "TOP=$both
DIR=$both/Bar.d" \
    "AC5: 'Bar.d' wins over 'bar.d'"

# ---- AC6: the 'makeitso' personality ---------------------------------------------------------
pledir="$WORK/pledir"
mkdir -p "$pledir" "$WORK/home_empty"
ln -s "$BAR" "$pledir/makeitso"
write_barf "$pledir/Makeitsof"
link_modules "$WORK/home/.config/makeitso"

check "$(run_makeitso "$pledir" "$WORK/home" toplevel)" \
    "TOP=$pledir
DIR=$WORK/home/.config/makeitso" \
    "AC6: 'makeitso' loads its modules from ~/.config/makeitso, no ancestor is searched"

check "$(run_makeitso "$pledir" "$WORK/home_empty" toplevel)" \
    "TOP=$pledir
DIR=$WORK/inst/share/bar/Bar.d" \
    "AC6: without ~/.config/makeitso the installed modules are used, BAR_TOPLEVEL is the invocation directory"

# ---- AC7, AC8: where a measured run writes its logs ---------------------------------------
#
# These two observe the run directory of the agent output contract, which is the surface that
# reported the defect: with BAR_TOPLEVEL below an ancestor the run directory is created outside of
# the tree, and where that path is not writable every target comes back rc=1 with no log at all.
# A tree without that module has nothing to observe here, so say so and skip.
if [[ ! -f "$REPO_ROOT/Bar.d/agent_rules" ]]; then
    echo "  - AC7/AC8: no Bar.d/agent_rules in this tree, skipped"
else
    # 'is_command_installed <command>' needs its parameter and a target cannot be given one, so
    # that target fails in a tree as well ('OK true' is the part that ran).  What the defect broke
    # is everything around it, so compare the whole block and the rc of the same run in and
    # outside a tree:
    verdict_in="$(run "$WORK/tree" verdict is_command_installed true)" && rc_in=0 || rc_in=$?
    verdict_out="$(run "$WORK/nodir" verdict is_command_installed true)" && rc_out=0 || rc_out=$?
    norm() { sed -E 's#/[^ ]*/\.bar\.agent/[^/]+/#<RUN>/#g' <<<"$1"; }

    check "$rc_out" "$rc_in" "AC7: the reproducing command returns the same rc in and outside a tree (rc=$rc_out)"
    check "$(norm "$verdict_out")" "$(norm "$verdict_in")" "AC7: the reproducing command prints the same block in and outside a tree"
    if [[ "$verdict_out" == *"OK true"* ]]; then
        pass "AC7: a target that ran is reported 'OK'"
    else
        fail "AC7: a target that ran is not reported 'OK' (got [$verdict_out])"
    fi

    log_paths=
    while IFS= read -r line; do
        [[ "$line" == "log: "* ]] || continue
        log_paths+="${line#log: } "
    done <<<"$verdict_out"
    if [[ -z "$log_paths" ]]; then
        fail "AC7: the failing target printed no log path, the test is not conclusive"
    else
        bad=
        for path in $log_paths; do
            [[ "$path" == "$WORK/nodir/"* ]] || bad="$path"
        done
        if [[ -z "$bad" ]]; then
            pass "AC7: every log is below the invocation directory ($log_paths)"
        else
            fail "AC7: a log is written outside the invocation directory: $bad"
        fi
    fi

    check "$(run "$WORK/nodir" verdict true)" "OK true" "AC8: a passing target is reported 'OK'"

    if [[ -f "$WORK/nodir/.bar.agent/latest/true.log" ]]; then
        pass "AC8: the log of the fallback run is below the invocation directory"
    else
        fail "AC8: no log below the invocation directory ($WORK/nodir/.bar.agent)"
    fi
fi

echo
if (( failures == 0 )); then
    echo "======================================"
    echo "All find_toplevel tests passed"
else
    echo "======================================"
    echo "FAILED: $failures assertion(s)"
    exit 1
fi
