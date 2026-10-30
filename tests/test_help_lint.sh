#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'help_lint' and for the source annotations 'help --debug' prints.
#
#   AC1  a document which follows the rules reports nothing and exits 0
#   AC2  every rule fires: the broken fixture names each of the 14 ids, and exit is 1
#   AC3  '-C <n>' prints the numbered block around a violation, the line marked
#   AC4  '--rule' keeps only the named ids, and a rule which fires on nothing reports nothing
#   AC5  '--width' is off by default and reports the rendered width when given
#   AC6  no file means the render: the counts of 'bar help_lint' and of the same text read
#        from a file agree, so the README is never linted in place
#   AC7  'help --debug' annotates the source and changes nothing else: dropping the '#file:line'
#        lines yields exactly the plain render
#   AC8  'help_lint --debug' names the source ('<file>:<line>') of the line it reports
#   AC9  a file which is not there and an unknown option are usage errors (exit 2)
#   AC11 '-v|--verbose' appends the rule's own sentence and prints one line of context, without -C
#   AC12 an explicit '-C 0' keeps the context off under '--verbose'
#   AC13 every sentence '--verbose' prints is the one 'bar usage help_lint' carries
#   AC15 '-' and '+' start a list item like '*', and L3/L4 measure them
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
MARKERS="$SCRIPT_DIR/help_lint_markers.txt"
[[ -f "$CLEAN" && -f "$BAD" && -f "$MARKERS" ]] || { echo "  ✗ the fixtures are missing"; exit 1; }

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
for id in B1 C2 H1 H2 H4 H5 I1 K1 K2 L3 L4 T1 W2 W3; do
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

# AC11 ----------------------------------------------------------------------------------------
out="$(lint -v --rule W3 "$BAD")"
contains "$out" "15:W3 a line carries no trailing spaces" "AC11 --verbose appends the rule's sentence"
contains "$out" $'\n    14|' "AC11 --verbose prints the line above without -C"
contains "$out" $'\n    15> ' "AC11 --verbose marks the offending line"
contains "$out" $'\n    16|' "AC11 --verbose prints the line below without -C"

# AC12 ----------------------------------------------------------------------------------------
out="$(lint --verbose -C 0 --rule W3 "$BAD")"
contains "$out" "15:W3 a line carries no trailing spaces" "AC12 --verbose still appends the sentence"
absent "$out" "    14|" "AC12 an explicit -C 0 keeps the context off"

# AC13 ----------------------------------------------------------------------------------------
# the sentence comes from the rule list itself, so the two can never drift
drift="$(
    awk '
        FNR == NR {
            if ($0 ~ /^ +[A-Z][0-9]  +/) {
                s = $0; sub(/^ +/, "", s)
                t = substr(s, 3); sub(/^ +/, "", t)
                doc[substr(s, 1, 2)] = t
            }
            next
        }
        /^[0-9]+:[A-Z][0-9] / {
            id = substr($0, index($0, ":") + 1, 2)
            t = substr($0, index($0, ":") + 4)
            if (!(id in doc)) { print id " is not in the rule list"; next }
            if (doc[id] != t) { print id " differs from the rule list" }
        }
    ' <("$BAR" --bare usage help_lint 2>/dev/null) \
      <(lint -v --width 40 "$BAD")
)"
check "$drift" "" "AC13 the verbose sentences are the documented ones"

# AC14 ----------------------------------------------------------------------------------------
# context is a presentation of the report, never a different one, and it reads in line order
flat="$(lint --width 40 "$BAD" | grep '^[0-9]*:' | sort)"
ctxout="$(lint -C 2 --width 40 "$BAD" | grep '^[0-9]*:' | sort)"
check "$ctxout" "$flat" "AC14 -C reports the same violations as the flat form"
out="$(lint -C 2 --width 40 "$BAD" | grep '^[0-9]*:')"
check "$out" "$(sort -s -n -t: -k1,1 <<<"$out")" "AC14 -C reports in line order"

# AC15 ----------------------------------------------------------------------------------------
# a '-' or a '+' is a list marker like '*', so the alignment rules measure it and no marker form
# is refused
out="$(lint "$MARKERS")"
check "$out" $'12:L3\n13:L4\n14:L3' "AC15 the alignment rules measure '-' and '+' items"
absent "$out" ":L1" "AC15 no marker form is refused"

if (( failures > 0 )); then
    echo "$failures assertion(s) failed"
    exit 1
fi
echo "all help_lint assertions passed"
