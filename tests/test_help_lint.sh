#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'help_lint' and for the source annotations 'help --debug' prints.
#
#   AC1  a document which follows the rules reports nothing and exits 0
#   AC2  every rule fires: the broken fixture names each of the 15 ids, and exit is 1
#   AC3  '-C <n>' prints the numbered block around a violation, the line marked
#   AC4  '--rule' keeps only the named ids, and a rule which fires on nothing reports nothing
#   AC5  '--width' is off by default and reports the rendered width when given
#   AC6  no file means the render: the counts of 'bar help_lint' and of the same text read
#        from a file agree, so the README is never linted in place
#   AC7  'help --debug' annotates the source and changes nothing else: dropping the '#file:line'
#        lines yields exactly the plain render
#   AC8  'help_lint --debug' names the source ('<file>:<line>') of the line it reports
#   AC9  a file which is not there and an unknown option are usage errors (exit 2)
#
# usage: tests/test_help_lint.sh

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

# the rule runner prints one status line of its own; nothing of it is the lint's report
lint() {
    "$BAR" --bare help_lint "$@" 2>/dev/null | grep -v -e '^ *OK: ' -e '^ *FAIL: ' || true
}

CLEAN="$SCRIPT_DIR/help_lint_clean.txt"
BAD="$SCRIPT_DIR/help_lint_bad.txt"
[[ -f "$CLEAN" && -f "$BAD" ]] || { echo "  ✗ the fixtures are missing"; exit 1; }

# AC1 -----------------------------------------------------------------------------------------
out="$(lint "$CLEAN")"
rc=0
"$BAR" --bare help_lint "$CLEAN" >/dev/null 2>&1 || rc=$?
check "$out" "" "AC1 a clean document reports nothing"
check "$rc" "0" "AC1 a clean document exits 0"

# AC2 -----------------------------------------------------------------------------------------
out="$(lint "$BAD")"
rc=0
"$BAR" --bare help_lint "$BAD" >/dev/null 2>&1 || rc=$?
check "$rc" "1" "AC2 a document with violations exits 1"
missing=""
for id in B1 C2 H1 H2 H4 H5 I1 K1 K2 L1 L3 L4 T1 W2 W3; do
    if ! grep -q ":$id\$" <<<"$out"; then
        missing="$missing $id"
    fi
done
check "$missing" "" "AC2 every rule fires (missing:${missing:- none})"
if grep -qv '^[0-9]\+:[A-Z][0-9]$' <<<"$out"; then
    fail "AC2 the report is one '<line>:<id>' per line"
else
    pass "AC2 the report is one '<line>:<id>' per line"
fi

# AC3 -----------------------------------------------------------------------------------------
out="$(lint -C 1 --rule W3 "$BAD")"
contains "$out" "15:W3" "AC3 the violation names its line"
contains "$out" $'\n    14|' "AC3 -C prints the line above, numbered"
contains "$out" $'\n    15> ' "AC3 -C marks the offending line"
contains "$out" $'\n    16|' "AC3 -C prints the line below, numbered"

# AC4 -----------------------------------------------------------------------------------------
out="$(lint --rule W3,T1 "$BAD")"
contains "$out" ":W3" "AC4 a named rule is reported"
contains "$out" ":T1" "AC4 a second named rule is reported"
absent "$out" ":B1" "AC4 a rule which was not named is not reported"
out="$(lint --rule H1 "$CLEAN")"
check "$out" "" "AC4 a named rule which fires on nothing reports nothing"

# AC5 -----------------------------------------------------------------------------------------
absent "$(lint "$BAD")" ":W1" "AC5 the width is not measured by default"
out="$(lint --width 40 "$BAD")"
contains "$out" ":W1" "AC5 --width reports a longer line"

# AC6 -----------------------------------------------------------------------------------------
live="$(lint)"
from_file="$(lint <("$BAR" --bare help 2>/dev/null))"
check "$from_file" "$live" "AC6 the render is what is linted, not the README"

# AC7 -----------------------------------------------------------------------------------------
plain="$("$BAR" --bare help 2>/dev/null || true)"
debug="$("$BAR" --bare help --debug 2>/dev/null || true)"
stripped="$(grep -v '^#[^[:space:]]*:[0-9]\+$' <<<"$debug" || true)"
check "$stripped" "$plain" "AC7 --debug only adds annotation lines"
contains "$debug" $'\n#Bar.d/help:' "AC7 the narrative is annotated"
contains "$debug" $'\n#Bar.d/std_lib:' "AC7 a module block is annotated"
contains "$debug" $'\n#bar:' "AC7 the main script is annotated"

# AC8 -----------------------------------------------------------------------------------------
out="$(lint --debug)"
contains "$out" $'\n#Bar.d/' "AC8 --debug names the source of a violation"
if grep -qv '^#[^ ]*:[0-9]\+ [0-9]\+:[A-Z][0-9]$' <<<"$out"; then
    fail "AC8 --debug reports '#<file>:<line> <line>:<id>'"
else
    pass "AC8 --debug reports '#<file>:<line> <line>:<id>'"
fi

# AC9 -----------------------------------------------------------------------------------------
rc=0
err="$("$BAR" --bare help_lint /does/not/exist 2>&1 >/dev/null)" || rc=$?
check "$rc" "2" "AC9 a file which is not there is a usage error"
contains "$err" "not a file" "AC9 the usage error says what is wrong"
contains "$err" "usage help_lint" "AC9 the usage error names the help which answers it"
rc=0
"$BAR" --bare help_lint --nonsense >/dev/null 2>&1 || rc=$?
check "$rc" "2" "AC9 an unknown option is a usage error"

# the documentation the rule carries is what 'bar usage' prints
contains "$("$BAR" --bare usage help_lint 2>/dev/null || true)" "K2  the columns of one term list align" \
    "AC10 'bar usage help_lint' explains the rule ids"

if (( failures > 0 )); then
    echo "$failures assertion(s) failed"
    exit 1
fi
echo "all help_lint assertions passed"
