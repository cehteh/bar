#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'clause_local' (Bar.d/rule_lib): the three forms its arguments come in, and
# the value the outer scope had.
#
#   AC1 'var=value' assigns the variable inside the clause
#   AC2 'var=' empties the variable, whether or not the outer scope had a value
#   AC3 a bare 'var' keeps the value of the outer scope
#   AC4 a variable named like one of the locals of 'clause_local' itself is assigned, not shadowed
#   AC5 the value of the outer scope is back behind the clause
#
# usage: tests/test_clause_local.sh

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

# mkproj <dir> - a project of its own: this repository's modules as its 'Bar.d' and nothing else
mkproj() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
}

RC=0
OUT=""
# runin <dir> <rule> - run a rule in a project, capturing its output and exit status
runin() {
    local dir="$1"
    shift
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>"$WORK/err")" || RC=$?
}

echo "=== Testing clause_local ==="
echo

P="$WORK/forms"
mkproj "$P"
cat >"$P/Barf" <<'EOS'
#shellcheck disable=2034
outer=outside
var=outer-var
value=outer-value

rule form_assign: 'clause_local var=inner' -- 'echo "assign [$var]"'
rule form_assign
rule form_empty: 'clause_local outer=' -- 'echo "empty [${outer}]"'
rule form_empty
rule form_unset: 'clause_local fresh=' -- 'echo "unset [${fresh}]"'
rule form_unset
rule form_keep: 'clause_local outer' -- 'echo "keep [$outer]"'
rule form_keep
rule form_names: 'clause_local var=1 value=2' -- 'echo "names [$var][$value]"'
rule form_names
rule form_quiet: 'clause_local var=inner' -- true
rule form_restore: form_quiet -- 'echo "after [$var]"'
rule form_restore
EOS

echo "AC1 'var=value' assigns the variable inside the clause"
runin "$P" form_assign
check "$RC" 0 "the clause succeeds"
check "$OUT" "assign [inner]" "the clause sees the assigned value"
echo

echo "AC2 'var=' empties the variable"
runin "$P" form_empty
check "$RC" 0 "the clause succeeds with a value in the outer scope"
check "$OUT" "empty []" "the outer value is emptied for the clause"
runin "$P" form_unset
check "$RC" 0 "the clause succeeds without a value in the outer scope"
check "$OUT" "unset []" "the variable exists and is empty"
echo

echo "AC3 a bare 'var' keeps the value of the outer scope"
runin "$P" form_keep
check "$RC" 0 "the clause succeeds"
check "$OUT" "keep [outside]" "the clause sees the outer value"
echo

echo "AC4 a variable named like one of its own locals is assigned, not shadowed"
runin "$P" form_names
check "$RC" 0 "the clause succeeds"
check "$OUT" "names [1][2]" "both variables carry the assigned values"
echo

echo "AC5 the value of the outer scope is back behind the clause"
runin "$P" form_restore
check "$RC" 0 "the rule succeeds"
check "$OUT" "after [outer-var]" "the assignment of the dependency was restored"
echo

if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All clause_local tests passed ==="
