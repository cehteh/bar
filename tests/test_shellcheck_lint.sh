#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for linting the bar files themselves ('bar_lint' and the routing of
# 'shellcheck_is_barfile' in Bar.d/shellcheck).
#
# A module and a rule file may be written in the make/just spellings 'preprocess' expands, so the
# text shellcheck reads has to be the text 'require' sources -- otherwise every sugared line is
# reported as a syntax error.  The fixture is a throw-away project which owns this tree's bar and
# modules, so nothing here depends on the repository's own rules.
#
#   AC1  a rule file written in the spellings passes 'shellcheck_lint' clean
#   AC2  the same file checked as written fails: the filter is what makes the difference
#   AC3  a module written in the spellings passes too, and the rule it defines answers
#   AC4  a genuine shell defect is still reported, naming the file and the line, never a
#        '/dev/fd/' descriptor
#   AC5  'bar_lint' answers for one file: 0 when clean, 1 with the defect, 2 when it is not there
#   AC6  'shellcheck_is_barfile' knows a rulefile, a module and a file whose shebang names bar
#   AC7  a shell script which is not a bar file is checked as written: a spelling is an error there
#   AC8  'bar usage bar_lint' prints the arguments, exit 0
#
# usage: tests/test_shellcheck_lint.sh

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
# <file> <pattern> - the line the pattern is written at, so the fixture can grow without the
# expected numbers below going stale
line_of() { grep -n -m1 -- "$2" "$1" | cut -d: -f1; }

echo "=== Testing the lint of bar modules and rule files (Bar.d/shellcheck) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

RC=0
OUT=""
ERR=""
# runin <dir> <args..> - run bar in a project, capturing stdout and stderr apart
#
# 'SHELLCHECK_LS_FILES' is exported by the module and set by this repository's own 'Barf' (':!tests'),
# so a run of this test from inside 'bar tests' would inherit it and the plain script below would be
# excluded -- the test is about the default routing, so it is dropped for the invocations.
runin() {
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && env -u SHELLCHECK_LS_FILES "$BAR" "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}

# mkproject <dir> - this tree's bar, every module, the shellcheckrc, and a git index, because
# 'shellcheck_lint' walks 'git ls-files'
mkproject() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -L "$BAR" "$dir/bar"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
    cp "$REPO_ROOT/shellcheckrc" "$dir/"
    git -C "$dir" init -q .
}

PROJECT="$WORK/project"
mkproject "$PROJECT"

# a rule file in the spellings: a header with a flag, an indented body, a semi colon body and a
# parenthesised dependency.  Written as bash it does not parse, which AC2 shows.
cat >"$PROJECT/Barf" <<'BARF'
#!/usr/bin/env bar
# shellcheck shell=bash
# shellcheck disable=SC2016

## Build everything.
build: [always] clean compile

## Compile the sources.
compile:
     for f in src/*; do
         echo "$f"
     done

## Remove the build directory.
clean: (rm -rf build)

## Answer a line of text.
greet: -- 'printf "%s\n" "greeting: hello"'
BARF

# a module in the same spellings, named '*_rules' so bar loads it at startup
cat >"$PROJECT/Bar.d/sugared_rules" <<'MODULE'
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
# shellcheck shell=bash

## Answers the module was loaded.
sugared_probe: -- 'echo sugared_module_ok'

## A body written as an indented block.
sugared_block:
     echo sugared_block_ok
MODULE

git -C "$PROJECT" add -A

runin "$PROJECT" shellcheck_lint
check "$RC" 0 "AC1: a sugared rule file and module lint clean"
absent "$ERR" "/dev/fd/" "AC1: no descriptor is named in a clean run"

# The filter is what makes AC1 true: the same file, checked as written, does not parse.
RC=0
OUT="$(cd "$PROJECT" && shellcheck --shell=bash Barf 2>&1)" || RC=$?
if (( RC != 0 )); then
    pass "AC2: the same file checked as written fails (exit $RC)"
else
    fail "AC2: the raw file passed shellcheck, so the fixture proves nothing"
fi
contains "$OUT" "SC10" "AC2: the raw check reports a parse error"

runin "$PROJECT" sugared_probe
check "$OUT" "sugared_module_ok" "AC3: the sugared module loaded and its rule answers"
runin "$PROJECT" sugared_block
check "$OUT" "sugared_block_ok" "AC3: a body written as an indented block answers"

# a genuine defect, in a file which also uses a spelling
cat >"$PROJECT/Bar.d/defect_rules" <<'MODULE'
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
# shellcheck shell=bash

## Reports a parameter without quoting it.
function defect_probe ## <arg> - echo the argument
{
    echo $1
}

## A sugared rule next to the defect, so the filter runs on the same file.
defect_sugared:
     echo defect_sugared_ok
MODULE
git -C "$PROJECT" add -A

DEFECT_LINE="$(line_of "$PROJECT/Bar.d/defect_rules" 'echo \$1')"

runin "$PROJECT" shellcheck_lint
check "$RC" 1 "AC4: a genuine shell defect still fails the lint"
contains "$OUT" "Bar.d/defect_rules line $DEFECT_LINE" "AC4: the report names the file and the line"
contains "$OUT" "SC2086" "AC4: the report names the finding"
absent "$OUT" "/dev/fd/" "AC4: no descriptor is named instead of the file"

runin "$PROJECT" bar_lint Bar.d/defect_rules
check "$RC" 1 "AC5: bar_lint answers 1 for the defect"
contains "$OUT" "Bar.d/defect_rules line $DEFECT_LINE" "AC5: bar_lint names the file"

runin "$PROJECT" bar_lint Barf
check "$RC" 0 "AC5: bar_lint answers 0 for the sugared rule file"
absent "$OUT" "SC" "AC5: no finding is reported for a clean file"

runin "$PROJECT" bar_lint nope_rules
check "$RC" 2 "AC5: a file which is not there is an error, never a silent pass"

# AC6 and AC7 need a shell script which is not a bar file: no 'Bar.d' in its path, no rule file
# name, and a bash shebang
mkdir -p "$PROJECT/tests"
cat >"$PROJECT/tests/tool.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck shell=bash
echo tool
SH
git -C "$PROJECT" add -A

runin "$PROJECT" shellcheck_is_barfile Barf
check "$RC" 0 "AC6: 'Barf' is a rule file"
runin "$PROJECT" shellcheck_is_barfile Bar.d/defect_rules
check "$RC" 0 "AC6: a 'Bar.d' module is a bar file"
runin "$PROJECT" shellcheck_is_barfile "$REPO_ROOT/example"
check "$RC" 0 "AC6: a file whose shebang names bar is a bar file"
runin "$PROJECT" shellcheck_is_barfile tests/tool.sh
check "$RC" 1 "AC6: a shell script is not a bar file"

# AC7: the routing is not cosmetic -- a spelling outside a bar file is still an error
cat >"$PROJECT/tests/tool.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck shell=bash
clean: (rm -rf build)
SH
git -C "$PROJECT" add -A
runin "$PROJECT" shellcheck_lint
check "$RC" 1 "AC7: a spelling in a plain shell script is not filtered away"
contains "$OUT" "tests/tool.sh line 3" "AC7: the plain script is reported at its own line"
rm -f "$PROJECT/tests/tool.sh"
git -C "$PROJECT" add -A

runin "$PROJECT" usage bar_lint
check "$RC" 0 "AC8: 'bar usage bar_lint' answers"
contains "$OUT" "bar_lint <file>" "AC8: the usage carries the argument"
contains "$OUT" "Lint a bar module or rule file" "AC8: the usage carries the description"

echo
if (( failures )); then
    echo "FAIL: $failures check(s) failed"
    exit 1
fi
echo "All checks passed"
