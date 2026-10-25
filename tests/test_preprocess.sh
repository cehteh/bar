#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the rule file filter ('preprocess' in bar, applied by 'require'), and for
# the two readers which find rules by their header ('rule_source_blocks', 'help_describe_rules').
#
#   AC1  the filter is an identity over this repository's rule files: 'Barf', 'Barf.default',
#        'example', 'Bar.d/*' and 'tests/*.sh' come back unchanged -- content and line count (a
#        file whose last line has no newline gets one, which is all awk's 'print' does)
#   AC2  one input line yields exactly one output line, counted on a file which uses every
#        spelling
#   AC3  every spelling behaves exactly like its hand expanded twin: same output, same exit code
#   AC4  the printed text is the text which is sourced: 'bar preprocess' written out as a rule
#        file answers the same as the sugared original
#   AC5  data is never rewritten: the content of a heredoc, of a multi line quoted string, and a
#        '[ -f x ]' test come through untouched
#   AC6  a body block ends at the first line indented less than its first line, and a header nothing
#        indented follows stays a plain header
#   AC7  'rule_show' prints a rule written in the sugar, and the documentation lists it under its
#        '##' description
#   AC8  a plain run stays inside the startup budget, and what the filter costs against the trunk's
#        'bar' is printed rather than hidden (one awk per module, optimised in a later item)
#
# The filter is infallible by design: it never refuses a line, what it does not know is passed
# through and bar's own parser reports it.  So the tests here assert output and behaviour, never
# an exit status of the filter itself.
#
# usage: tests/test_preprocess.sh

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

RC=0
OUT=""
# runin <dir> <rule> [args..] - run a rule in a project, capturing its output and exit status
runin() {
    local dir="$1"
    shift
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>"$WORK/err")" || RC=$?
}

echo "=== Testing the rule file filter ('preprocess') ==="
echo

echo "AC1 the filter is an identity over this repository's rule files"
CORPUS=( "$REPO_ROOT/Barf" "$REPO_ROOT/Barf.default" "$REPO_ROOT/example" )
while IFS= read -r file; do
    CORPUS+=( "$file" )
done < <(find "$REPO_ROOT/Bar.d" "$REPO_ROOT/tests" -maxdepth 1 -type f | sort)
identical=0
differed=""
for file in "${CORPUS[@]}"; do
    # the whole text, trailing newlines aside: 'print' adds the one a last line may lack
    if [[ "$("$BAR" preprocess "$file" 2>/dev/null)" == "$(cat "$file")" ]]; then
        identical=$((identical + 1))
    else
        differed+=" ${file#"$REPO_ROOT/"}"
    fi
done
check "$identical" "${#CORPUS[@]}" "${#CORPUS[@]} rule files come back unchanged${differed:+ (differed:$differed)}"
echo

echo "AC2 one input line yields exactly one output line"
cat >"$WORK/all.spellings" <<'EOS'
[always]
flagged: dep ; echo flagged-body
clause: [conclusive] dep ; echo clause-body
paren: (echo a "b c") ; echo paren-body
block: dep
	echo block-1

	echo block-2
NAME := value
COND ?= value
EOS
"$BAR" preprocess "$WORK/all.spellings" >"$WORK/all.out" 2>/dev/null
inlines="$(wc -l <"$WORK/all.spellings")"
outlines="$(wc -l <"$WORK/all.out")"
check "$outlines" "$inlines" "a file using every spelling keeps its line count"
echo

echo "AC3 every spelling behaves like its hand expanded twin"
# <name> <sugar> <expanded> - one pair, run as the rule '#1' from both files
pair() {
    local name="$1" sugar="$2" expanded="$3"
    local a="$WORK/pair-$name-sugar" b="$WORK/pair-$name-expanded"
    mkproj "$a"
    mkproj "$b"
    printf '%s\n' "$sugar" >"$a/Barf"
    printf '%s\n' "$expanded" >"$b/Barf"
    runin "$a" "$name"
    local rc_sugar="$RC" out_sugar="$OUT"
    runin "$b" "$name"
    local rc_expanded="$RC" out_expanded="$OUT"
    check "$out_sugar" "$out_expanded" "$name: same output"
    check "$rc_sugar" "$rc_expanded" "$name: same exit status"
}

pair header 'hello: dep
	echo hi
dep: -- echo dep-body' "rule hello: dep -- <<'EOR'
echo hi
EOR
rule dep: -- echo dep-body"

pair inline 'two: dep ; echo inline-body
dep: -- echo dep-body' "rule two: dep -- echo inline-body
rule dep: -- echo dep-body"

pair clause 'clause: [conclusive] dep ; echo clause-body
dep: -- echo dep-body' "rule clause: --conclusive dep -- echo clause-body
rule dep: -- echo dep-body"

pair flags '[always]
[disjunct]
dd: ndep ; echo first-body
dd: dep ; echo second-body
ndep: -- false
dep: -- echo dep-body' "rule --always --disjunct dd: ndep -- echo first-body
rule --always --disjunct dd: dep -- echo second-body
rule ndep: -- false
rule dep: -- echo dep-body"

pair paren 'paren: (echo a "b c") ; echo paren-body' "rule paren: 'echo a \"b c\"' -- echo paren-body"

pair negated 'negated: !(false arg) ; echo negated-body' "rule negated: '!false arg' -- echo negated-body"

pair assign 'VAL := one
COND ?= two
COND ?= three
assign: -- echo "$VAL $COND"' 'VAL=one
: "${COND:=two}"
: "${COND:=three}"
rule assign: -- echo "$VAL $COND"'
echo

echo "AC4 the printed text is the text which is sourced"
A="$WORK/printed-sugar"
B="$WORK/printed-expanded"
mkproj "$A"
mkproj "$B"
cat >"$A/Barf" <<'EOS'
## hello - greets
hello: dep ; echo hi
dep:
	echo dep-block
EOS
"$BAR" preprocess "$A/Barf" >"$B/Barf" 2>/dev/null
contains "$(cat "$B/Barf")" "rule hello: dep -- echo hi" "the printed file carries the expanded header"
runin "$A" hello
out_sugar="$OUT" rc_sugar="$RC"
runin "$B" hello
check "$OUT" "$out_sugar" "the printed file answers like the original"
check "$RC" "$rc_sugar" "with the same exit status"
echo

echo "AC5 data is never rewritten"
G="$WORK/guards"
mkproj "$G"
cat >"$G/Barf" <<'EOS'
: <<'COMMENT'
block: this looks like a header
[always] this looks like a flag
(x) this looks like a dependency
COMMENT

NOTE='
multi: line quoted string
'

quoted:
	echo "$NOTE"

bracket: [ -f /nonexistent-for-the-filter ] ; echo bracket-body
EOS
out="$("$BAR" preprocess "$G/Barf" 2>/dev/null)"
contains "$out" "block: this looks like a header" "a heredoc body is not rewritten"
contains "$out" "[always] this looks like a flag" "a heredoc line looking like a flag survives"
contains "$out" "(x) this looks like a dependency" "a heredoc line looking like a dependency survives"
contains "$out" "multi: line quoted string" "a multi line quoted string is not rewritten"
contains "$out" "rule bracket: [ -f /nonexistent-for-the-filter ] -- echo bracket-body" \
    "a test bracket is a dependency, not a flag"
runin "$G" quoted
check "$RC" 0 "a rule after the heredoc still loads"
contains "$OUT" "multi: line quoted string" "and prints its quoted data untouched"
echo

echo "AC6 a body block ends at the first line indented less"
E="$WORK/ending"
mkproj "$E"
cat >"$E/Barf" <<'EOS'
first: -- true
	echo first-body
second: -- echo second-body
EOS
out="$("$BAR" preprocess "$E/Barf" 2>/dev/null)"
contains "$out" "rule second: -- echo second-body" "the dedented header is a header again"
runin "$E" first
check "$RC" 0 "the body block runs"
check "$OUT" "first-body" "and carries only its own lines"
# a header nothing indented follows stays a plain header
printf 'lonely: dep\n' >"$E/Barf"
check "$("$BAR" preprocess "$E/Barf" 2>/dev/null)" "rule lonely: dep" "a header without a body expands alone"
echo

echo "AC7 the readers find a rule by its sugared header"
R="$WORK/readers"
mkproj "$R"
cat >"$R/Barf" <<'EOS'
## hello - greets from the sugar
hello: -- echo hi
EOS
cat >"$R/Bar.d/zz_sugar" <<'EOS'
### a module written in the sugar

## zz_sugared [arg] - listed from a sugared header
zz_sugared: -- echo "$1"
EOS
runin "$R" rule_show hello
contains "$OUT" "hello:" "rule_show prints the sugared header"
contains "$OUT" "echo hi" "with its body"
runin "$R" usage zz_sugared
contains "$OUT" "listed from a sugared header" "the documentation lists a sugared rule with its '##' text"
echo

echo "AC8 a plain run stays inside the startup budget"
# bestrun <bar> <dir> - best of three runs of a trivial rule, in milliseconds
bestrun() {
    local bar="$1" dir="$2" best="" start ms
    for _ in 1 2 3; do
        start="$(date +%s%N)"
        ( cd "$dir" && "$bar" timing >/dev/null 2>&1 ) || true
        ms=$(( ($(date +%s%N) - start) / 1000000 ))
        if [[ -z "$best" ]] || (( ms < best )); then
            best="$ms"
        fi
    done
    printf '%s' "$best"
}

# the trunk's 'bar' as the baseline: the same modules, without the filter
TRUNK_BAR="$WORK/bar-trunk"
( cd "$REPO_ROOT" && git show HEAD:bar >"$TRUNK_BAR" )
chmod +x "$TRUNK_BAR"

T="$WORK/timing"
mkproj "$T"
printf 'timing: -- true\n' >"$T/Barf"
best="$(bestrun "$BAR" "$T")"
trunk="$(bestrun "$TRUNK_BAR" "$T")"
modules="$(ls "$REPO_ROOT"/Bar.d/std_lib "$REPO_ROOT"/Bar.d/rule_lib "$REPO_ROOT"/Bar.d/*_rules | wc -l)"
if (( best < 2500 )); then
    pass "a plain run takes ${best} ms (best of 3, budget 2500 ms; the trunk's bar ${trunk} ms, the filter costs $((best - trunk)) ms for ${modules} modules)"
else
    fail "a plain run takes ${best} ms (over the 2500 ms budget; the trunk's bar ${trunk} ms)"
fi
echo

if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All rule file filter tests passed ==="
