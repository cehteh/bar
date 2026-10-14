#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the opportunistic vendoring: a 'Bar.d' which was vendored into a project
# only carries the modules the project needs, a module it starts to use is pulled in from the
# installation bar was run from ('require' in bar, BAR_INSTALL_DEPS in Bar.d/rule_lib), and
# 'bar init' installs the mandatory modules and then completes the tree from the Barf
# (Bar.d/init).
#
# Everything runs against throw-away projects and a throw-away installation: the 'origin' is a
# fake installation in the workspace whose 'bin/bar' is the bar under test and whose
# 'share/bar/Bar.d' is a copy of this repository's modules, so nothing here depends on the host
# installation of bar.
#
# 'memodb' and 'testdir' are the witnesses used here: nothing bar loads at startup names them
# (not the mandatory 'std_lib', 'rule_lib' and '*_rules', and not what those require in turn),
# only a Barf or a rule body does.
#
#   AC1  a vendored Bar.d pulls a missing module from the origin, and the module is there after
#   AC2  a module which is nowhere is a warning and a failure, '--opt' stays silent and succeeds
#   AC3  an existing module is never overwritten, no temporary file is left behind
#   AC4  BAR_INSTALL_DEPS walks the deps and the 'require' lines of the rules and vendors what
#        they need (transitively), and does nothing when it is not set
#   AC6  without an origin a missing module stays a failure and nothing is written

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules 'bar init' has to install unconditionally ('std_lib' and 'rule_lib' are required by
# bar itself, the '*_rules' are required at startup), everything else is pulled in on demand
MANDATORY_MODULES="std_lib rule_lib"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

echo "=== Testing opportunistic vendoring ('require', BAR_INSTALL_DEPS, 'bar init') ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ORIGIN="$WORK/prefix"

# <prefix> - a fake installation of bar: the script under test in 'bin/bar', this repository's
# modules as the origin 'share/bar/Bar.d' and the shipped default Barf
mkorigin() {
    local prefix="$1"
    mkdir -p "$prefix/bin" "$prefix/share/bar"
    cp -L "$BAR" "$prefix/bin/bar"
    cp -Lr "$REPO_ROOT/Bar.d" "$prefix/share/bar/Bar.d"
    cp -L "$REPO_ROOT/Barf.default" "$prefix/share/bar/Barf"
}

# <dir> [modules..] - a vendored project: its own copy of bar, a Barf and a Bar.d which only
# carries the modules given
mkvended() {
    local dir="$1"
    shift
    mkdir -p "$dir/Bar.d"
    cp -L "$ORIGIN/bin/bar" "$dir/bar"
    cp -L "$ORIGIN/share/bar/Barf" "$dir/Barf"
    local module
    for module in "$@"; do
        cp -L "$ORIGIN/share/bar/Bar.d/$module" "$dir/Bar.d/$module"
    done
}

# <dir> [args..] - runs the project's own bar with the fake installation on PATH (that is what
# makes it the origin), capturing stdout, stderr and the exit status
OUT=""
ERR=""
RC=0
run_vendored() {
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && PATH="$ORIGIN/bin:$PATH" ./bar "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}

# <dir> [args..] - the same, but with BAR_INSTALL_DEPS=true
run_vendored_deps() {
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && PATH="$ORIGIN/bin:$PATH" BAR_INSTALL_DEPS=true ./bar "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}

mkorigin "$ORIGIN"

# --------------------------------------------------------------------------------------------
# AC1 a vendored Bar.d pulls a missing module from the origin
# --------------------------------------------------------------------------------------------
# 'tty_lib' is not part of the mandatory set, but std_lib requires it: the first run has to
# vendor it into the project's Bar.d and reports it at the 'note' verbosity level
mkvended "$WORK/p1" std_lib rule_lib
OUT="$(cd "$WORK/p1" && PATH="$ORIGIN/bin:$PATH" BAR_VERBOSITY_LEVEL=3 ./bar true 2>"$WORK/stderr")" || RC=$?
ERR="$(cat "$WORK/stderr")"
check "$RC" "0" "AC1: a vendored project runs"
[[ -f "$WORK/p1/Bar.d/tty_lib" ]] && pass "AC1: the missing 'tty_lib' was vendored into Bar.d" \
    || fail "AC1: 'tty_lib' was not vendored into Bar.d"
contains "$ERR" "tty_lib" "AC1: the installation is reported"
[[ -f "$WORK/p1/Bar.d/std_rules" ]] && pass "AC1: a missing '*_rules' module was vendored" \
    || fail "AC1: a missing '*_rules' module was not vendored"
[[ -f "$WORK/p1/Bar.d/memodb" ]] && fail "AC1: a module nothing names was vendored" \
    || pass "AC1: a module nothing names stays out of Bar.d"

# a module which is not there yet is pulled in on demand, not at startup
cat >"$WORK/p1/Barf" <<'BARF'
rule MAIN: -- true

rule uses_memodb: -- '
     require memodb
     printf "memodb ok\n"
'
BARF
run_vendored "$WORK/p1" uses_memodb
check "$RC" "0" "AC1: a rule which requires a missing module runs"
contains "$OUT" "memodb ok" "AC1: the rule body ran"
[[ -f "$WORK/p1/Bar.d/memodb" ]] && pass "AC1: 'memodb' was vendored on demand" \
    || fail "AC1: 'memodb' was not vendored on demand"

# --------------------------------------------------------------------------------------------
# AC2 a module which is nowhere: warning + failure, '--opt' silent and successful
# --------------------------------------------------------------------------------------------
mkvended "$WORK/p2" std_lib rule_lib
cat >"$WORK/p2/Barf" <<'BARF'
rule want_missing: -- '
     require nosuchmodule_at_all
'

rule want_missing_opt: -- '
     require --opt nosuchmodule_at_all
'
BARF
run_vendored "$WORK/p2" want_missing
check "$RC" "1" "AC2: a missing mandatory module fails"
contains "$ERR" "failed loading" "AC2: a missing mandatory module is warned about"
run_vendored "$WORK/p2" want_missing_opt
check "$RC" "0" "AC2: '--opt' still succeeds for a missing module"
absent "$ERR" "failed loading" "AC2: '--opt' stays silent"

# --------------------------------------------------------------------------------------------
# AC3 an existing module is never overwritten and no temporary file is left behind
# --------------------------------------------------------------------------------------------
printf '\n# local edit\n' >>"$WORK/p1/Bar.d/memodb"
run_vendored "$WORK/p1" uses_memodb
check "$RC" "0" "AC3: the project still runs"
if grep -q '^# local edit$' "$WORK/p1/Bar.d/memodb"; then
    pass "AC3: an existing module was not overwritten"
else
    fail "AC3: an existing module was overwritten"
fi
[[ -z "$(find "$WORK/p1/Bar.d" -name '*.tmp' -print -quit)" ]] && pass "AC3: no temporary file left behind" \
    || fail "AC3: a temporary file was left behind"

# --------------------------------------------------------------------------------------------
# AC4 BAR_INSTALL_DEPS walks the deps and the 'require' lines of the rules
# --------------------------------------------------------------------------------------------
mkvended "$WORK/p4" std_lib rule_lib
cat >"$WORK/p4/Barf" <<'BARF'
rule need_memodb: -- '
     require memodb
'

rule check_deps: testdir_enter? -- true
BARF
# control: without BAR_INSTALL_DEPS nothing a rule names is loaded
run_vendored "$WORK/p4" true
absent "$(ls "$WORK/p4/Bar.d")" "testdir" "AC4: without BAR_INSTALL_DEPS no dep module is vendored"
absent "$(ls "$WORK/p4/Bar.d")" "memodb" "AC4: without BAR_INSTALL_DEPS no body module is vendored"
# with it: the deps and the 'require' lines of every rule are loaded, transitively
run_vendored_deps "$WORK/p4" true
check "$RC" "0" "AC4: BAR_INSTALL_DEPS=true still runs"
[[ -f "$WORK/p4/Bar.d/testdir" ]] && pass "AC4: the module of a rule dep was vendored" \
    || fail "AC4: the module of a rule dep ('testdir') was not vendored"
[[ -f "$WORK/p4/Bar.d/lock" ]] && pass "AC4: a module a dep module requires was vendored (transitive)" \
    || fail "AC4: 'lock' (required by testdir) was not vendored"
[[ -f "$WORK/p4/Bar.d/memodb" ]] && pass "AC4: a module a rule body requires was vendored" \
    || fail "AC4: 'memodb' (required in a rule body) was not vendored"

# --------------------------------------------------------------------------------------------
# AC6 without an origin a missing module stays a failure and nothing is written
# --------------------------------------------------------------------------------------------
mkvended "$WORK/p6" std_lib rule_lib
cat >"$WORK/p6/Barf" <<'BARF'
rule want_memodb: -- '
     require memodb
'
BARF
run_vendored_no_origin() {
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && env PATH="/usr/bin:/bin" ./bar "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}
run_vendored_no_origin "$WORK/p6" want_memodb
check "$RC" "1" "AC6: without an origin a missing module fails"
contains "$ERR" "failed loading" "AC6: without an origin a missing module is warned about"
[[ -f "$WORK/p6/Bar.d/memodb" ]] && fail "AC6: something was vendored without an origin" \
    || pass "AC6: nothing was vendored without an origin"

echo
if (( failures == 0 )); then
    echo "=== All vendoring tests passed ==="
else
    echo "=== $failures vendoring assertion(s) FAILED ==="
    exit 1
fi
