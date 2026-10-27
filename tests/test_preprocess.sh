#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the rule file filter ('preprocess' in bar, applied by 'require'), and for
# the two readers which find rules by their header ('rule_source_blocks', 'help_describe_rules').
#
#   AC1  the filter is an identity over the rule files which use no spelling, and a rule file
#        written in the spellings expands once, keeping its line count (the expansion is a fixed
#        point: a second pass changes nothing)
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
#   AC8  a report from a module names the module and the line, never the descriptor the text was
#        sourced from ('source_info' maps '/dev/fd/NN' back)
#   AC9  a plain run stays inside the startup budget
#   AC10 one preprocessor serves the whole run, not one program per file
#   AC11 a file expands as if it were alone: the state one file leaves does not reach the next
#   AC12 a file whose last line carries no newline keeps that line, and no frame glues onto another
#   AC13 a file the filter cannot read is reported, never expanded to nothing
#   AC14 a run of '[=]var[=value]' words in a header becomes one 'clause_local' dependency, and
#        the three forms mean what they say (see tests/test_clause_local.sh)
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

echo "AC1 the filter is an identity over the rule files which use no spelling"
SPELLED=( "$REPO_ROOT/Barf" "$REPO_ROOT/Barf.default" )
CORPUS=( "$REPO_ROOT/example" )
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

# the repository's own rule files do use the spellings: they expand, one line out per line in, and
# what they expand to uses no spelling any more
for file in "${SPELLED[@]}"; do
    name="${file#"$REPO_ROOT/"}"
    "$BAR" preprocess "$file" >"$WORK/pp1" 2>/dev/null
    "$BAR" preprocess "$WORK/pp1" >"$WORK/pp2" 2>/dev/null
    check "$(wc -l <"$WORK/pp1")" "$(wc -l <"$file")" "$name: one line out per line in"
    if cmp -s "$file" "$WORK/pp1"; then
        fail "$name: no spelling was expanded"
    else
        pass "$name: the spellings were expanded"
    fi
    if cmp -s "$WORK/pp1" "$WORK/pp2"; then
        pass "$name: the expansion is a fixed point"
    else
        fail "$name: a second pass changed the expansion"
    fi
done
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

echo "AC8 a report from a module names the module, not the stream it was sourced from"
L="$WORK/locations"
mkproj "$L"
printf 'loc: -- report_from_here\n' >"$L/Barf"
cat >"$L/Bar.d/loc_rules" <<'EOS'
function report_from_here
{
    error "from a module"
}
EOS
runin "$L" loc
ERR="$(cat "$WORK/err")"
contains "$ERR" "Bar.d/loc_rules:3:report_from_here:" "the location is the module and the line"
absent "$ERR" "/dev/fd/" "and never the descriptor the text came from"
echo

echo "AC9 a plain run stays inside the startup budget"
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

T="$WORK/timing"
mkproj "$T"
printf 'run: -- true\n' >"$T/Barf"
best="$(bestrun "$BAR" "$T")"
modules="$(ls "$REPO_ROOT"/Bar.d/std_lib "$REPO_ROOT"/Bar.d/rule_lib "$REPO_ROOT"/Bar.d/*_rules | wc -l)"
if (( best < 2500 )); then
    pass "a plain run takes ${best} ms (best of 3, budget 2500 ms, ${modules} modules)"
else
    fail "a plain run takes ${best} ms (over the 2500 ms budget)"
fi
echo

echo "AC10 one preprocessor serves the whole run"
# a shim in front of the real awk counts the programs a run starts: the filter is started once and
# handed a file at a time, where one program per file would be one start per module
SHIM="$WORK/shim"
mkdir -p "$SHIM"
REAL_AWK="$(command -v awk)"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" start >>"${AWK_LOG:?}"\nexec %s "$@"\n' "$REAL_AWK" >"$SHIM/awk"
chmod +x "$SHIM/awk"
# awkstarts <dir> <log> - how often a run in <dir> started awk
awkstarts() {
    local dir="$1" log="$2" n
    : >"$log"
    ( cd "$dir" && AWK_LOG="$log" PATH="$SHIM:$PATH" "$BAR" run >/dev/null 2>&1 ) || true
    n="$(grep -c '^start$' "$log" 2>/dev/null || true)"
    printf '%s' "${n:-0}"
}
# the same run on the trunk's 'bar' would start one per module, which is what this counts against
check "$(awkstarts "$T" "$WORK/awk-starts")" "1" "one awk for the run (the trunk's bar: one per module)"
echo

echo "AC11 a file expands as if it were alone"
FR="$WORK/frames"
FOUT="$WORK/frames-out"
mkdir -p "$FR" "$FOUT"
# each frame leaves the filter in the middle of something: a quote, a heredoc, an indented body
printf 'NOTE="half a quote\nh2: dep ; echo swallowed-by-the-quote\n' >"$FR/01-open-quote"
printf 'h2: dep ; echo second-file\n' >"$FR/02-header-after-open-quote"
printf ": <<'NEVER'\nstill: heredoc-data\n" >"$FR/03-open-heredoc"
printf 'blk: dep\n\techo one\n\techo two\n' >"$FR/04-body"
printf 'tail: dep ; echo lastline' >"$FR/05-no-final-newline"
printf 'plain: -- echo plain\n' >"$FR/06-plain"
B="$WORK/batch"
mkproj "$B"
cat >"$B/Bar.d/batch" <<'EOS'
### filters a directory of rule files in one run

rule batch_frames: -- batch_frames_run

function batch_frames_run
{
    local f
    for f in "$FRAMES"/*; do
        if [[ -f $f ]]; then
            preprocess "$f" >"$FRAMES_OUT/${f##*/}"
        fi
    done
}
EOS
if ( cd "$B" && FRAMES="$FR" FRAMES_OUT="$FOUT" "$BAR" batch_frames ) >/dev/null 2>&1; then
    pass "the frames are filtered by one run"
else
    fail "the batch run failed"
fi
for f in "$FR"/*; do
    name="${f##*/}"
    check "$(cat "$FOUT/$name" 2>/dev/null)" "$("$BAR" preprocess "$f" 2>/dev/null)" \
        "$name expands as it does alone"
done
echo

echo "AC12 a file without a final newline keeps its last line, and no frame glues"
printf 'tail: dep ; echo lastline\n' >"$WORK/with-newline"
"$BAR" preprocess "$FR/05-no-final-newline" >"$WORK/alone-noterm" 2>/dev/null
"$BAR" preprocess "$WORK/with-newline" >"$WORK/alone-term" 2>/dev/null
if cmp -s "$WORK/alone-noterm" "$WORK/alone-term"; then
    pass "a file without a final newline expands like one which has it"
else
    fail "a file without a final newline differs from one which has it"
fi
absent "$(cat "$WORK/alone-noterm")" "EOF" "the frame marker never reaches the output"
check "$(head -1 "$FOUT/06-plain")" "rule plain: -- echo plain" \
    "the frame after it starts on a line of its own"
echo

echo "AC13 a file the filter cannot read is reported"
RC=0
OUT="$("$BAR" preprocess "$WORK/there-is-no-such-rule-file" 2>"$WORK/err13")" || RC=$?
if (( RC != 0 )); then
    pass "an unreadable file fails the rule"
else
    fail "an unreadable file succeeded"
fi
check "$OUT" "" "and prints nothing"
contains "$(cat "$WORK/err13")" "there-is-no-such-rule-file" "the report names the file"
RC=0
OUT="$("$BAR" preprocess "$WORK" 2>"$WORK/err13")" || RC=$?
if (( RC != 0 )); then
    pass "a directory is refused the same way"
else
    fail "a directory was expanded as if it were a rule file"
fi
echo

echo "AC14 runs of variable definitions in a header become one 'clause_local'"
# the example of the item which asked for it: a run becomes one dependency, 'var=' is a local which
# is empty, '=var' one which starts at the value of the outer scope, and the order is kept
printf 'test: var=value var2= =var3 something else var4="another value"\n' >"$WORK/vardef-header"
check "$("$BAR" preprocess "$WORK/vardef-header" 2>/dev/null)" \
    "rule test: 'clause_local var=value var2= var3' something else 'clause_local var4=\"another value\"'" \
    "one 'clause_local' per run, in the order they are written"
# a run ends where a dependency of another kind starts: two runs are never coalesced
printf 'split: a=1 b=2 noop c=3\n' >"$WORK/vardef-split"
check "$("$BAR" preprocess "$WORK/vardef-split" 2>/dev/null)" \
    "rule split: 'clause_local a=1 b=2' noop 'clause_local c=3'" \
    "a dependency between two runs keeps them apart"
# what follows '--' is a body, so it is commands and not definitions
printf 'body: -- var=1\n' >"$WORK/vardef-body"
check "$("$BAR" preprocess "$WORK/vardef-body" 2>/dev/null)" "rule body: -- var=1" \
    "a word of the body is not a definition"
"$BAR" preprocess "$WORK/vardef-header" >"$WORK/vardef-1" 2>/dev/null
"$BAR" preprocess "$WORK/vardef-1" >"$WORK/vardef-2" 2>/dev/null
if cmp -s "$WORK/vardef-1" "$WORK/vardef-2"; then
    pass "the expansion is a fixed point"
else
    fail "a second pass changed the expansion"
fi
# and it answers like its hand expanded twin, which is what gives the three forms their meaning.
# The value carries no space: a dependency's arguments are split on IFS ('read -r -a depargs' in
# rule_lib), so 'var=x y' reaches 'clause_local' as two words however it is quoted -- a limit of
# dependency arguments, older than this spelling and not one it can lift.
VA="$WORK/vardefs-sugar"
VB="$WORK/vardefs-expanded"
mkproj "$VA"
mkproj "$VB"
cat >"$VA/Barf" <<'EOS'
outerword=OUT
noop: -- true
cl_vardef: var=value var2= =outerword noop var4=another ; 'echo "[$var][$var2][$outerword][$var4]"'
EOS
cat >"$VB/Barf" <<'EOS'
outerword=OUT
rule noop: -- true
rule cl_vardef: 'clause_local var=value var2= outerword' noop 'clause_local var4=another' \
    -- 'echo "[$var][$var2][$outerword][$var4]"'
EOS
runin "$VA" cl_vardef
rc_sugar="$RC"
out_sugar="$OUT"
runin "$VB" cl_vardef
check "$out_sugar" "$OUT" "the sugar answers like its hand expanded twin"
check "$rc_sugar" "$RC" "with the same exit status"
check "$out_sugar" '[value][][OUT][another]' "and the three forms mean what they say"
echo

if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All rule file filter tests passed ==="
