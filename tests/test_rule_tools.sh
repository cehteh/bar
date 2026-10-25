#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'rule_show' and 'rule_edit' (Bar.d/rule_lib).
#
# Both read the rule files, not the loaded rule, so the fixture is a throw-away project whose
# rules are spread over its 'Barf' and one module: a rule with a clause in each, a statement
# continued over several lines, and a rule which only calls the function of its name.
#
#   AC1  'rule_show' prints every clause of a rule, each with the file and line it is written at
#   AC2  a statement continued over several lines is shown whole, not as its first line
#   AC3  a rule which only calls the function of its name also prints that functions source
#   AC4  a name no rule files define is an error: exit 1, the name on stderr, nothing on stdout
#   AC5  'rule_edit' opens the one defining file in the editor, at the statement
#   AC6  'rule_edit' over several defining files lists them and opens the one chosen
#   AC7  a filepattern narrows the list; a pattern which selects none is an error
#   AC8  '-f|--function' searches function definitions instead of rule definitions
#   AC9  '-h' answers what 'bar usage <rule>' answers (in this repository, which carries 'help')
#   AC10 the rules are documented, so 'bar help' carries them
#   AC11 'rule_edit' refuses a definition written outside the base directory, and says where it is
#   AC12 ... which one edits by changing into that directory: the same call then opens it
#   AC13 a name written inside and outside the base directory opens the inside one, without a menu
#
# usage: tests/test_rule_tools.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
# <file> <pattern> - the line the pattern is written at, so the fixture can grow without the
# expected numbers below going stale
line_of() { grep -n -m1 -- "$2" "$1" | cut -d: -f1; }

echo "=== Testing rule_show / rule_edit ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJECT="$WORK/project"
INSTALL="$WORK/install"

# <dir> - a project which runs this trees bar with its own rules: the modules bar loads at
# startup, a rulefile with two rules and a module which completes them
mkproject() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -L "$BAR" "$dir/bar"
    local module
    for module in std_lib rule_lib tty_lib; do
        cp -L "$REPO_ROOT/Bar.d/$module" "$dir/Bar.d/$module"
    done

    cat >"$dir/Barf" <<'BARF'
# the rulefile of the fixture

## A rule with a body of its own.
rule alpha: -- 'echo alpha'

## A statement continued over several lines.
rule delta: \
     'alpha?'\
     'beta?'
BARF

    cat >"$dir/Bar.d/fixture_rules" <<'RULES'
# a module which completes the rules the rulefile defines

## The second clause of alpha, defined here.
rule alpha: -- 'echo module-alpha'

## A rule which only calls the function of its name.
rule gamma:

## gamma is where the work is.
function gamma
{
    echo gamma
}
RULES

    # the editor which stands in for the users one: it prints the arguments it was called with
    mkeditor "$dir"
}

# <dir> - the editor which stands in for the users one: it prints the arguments it was called with
mkeditor() {
    cat >"$1/ed" <<'ED'
#!/bin/sh
printf '%s\n' "$*"
ED
    chmod +x "$1/ed"
}

# <dir> - an installed bar ('bin/bar' beside 'share/bar/Bar.d') and a project which carries no
# rule directory, so bar falls back to the modules of that installation: the definition of 'alpha'
# the project writes into its rulefile sits inside the base directory, the one the installation
# carries outside of it
mkinstall() {
    local dir="$1"
    local prefix="$dir/prefix"
    local module
    mkdir -p "$prefix/bin" "$prefix/share/bar/Bar.d" "$dir/project"
    cp -L "$BAR" "$prefix/bin/bar"
    for module in std_lib rule_lib tty_lib; do
        cp -L "$REPO_ROOT/Bar.d/$module" "$prefix/share/bar/Bar.d/$module"
    done

    cat >"$prefix/share/bar/Bar.d/fixture_rules" <<'RULES'
# the module of the installation

## A rule with a body of its own, as the installation writes it.
rule alpha: -- 'echo installed-alpha'
RULES

    cat >"$dir/project/Barf" <<'BARF'
# the rulefile of the fixture

## A rule with a body of its own, as the project writes it.
rule alpha: -- 'echo alpha'
BARF

    mkeditor "$dir"
}

mkproject "$PROJECT"
mkinstall "$INSTALL"

BARF_RULEFILE="$PROJECT/Barf"
MODULE="$PROJECT/Bar.d/fixture_rules"
ALPHA_BARF="$(line_of "$BARF_RULEFILE" '^rule alpha:')"
ALPHA_MODULE="$(line_of "$MODULE" '^rule alpha:')"
GAMMA_RULE="$(line_of "$MODULE" '^rule gamma:')"
GAMMA_FUNCTION="$(line_of "$MODULE" '^function gamma')"

OUT=""
RC=0
# <project> [args..] - runs the projects bar with the recording editor
run() {
    local dir="$1"
    shift
    RC=0
    OUT="$(cd "$dir" && EDITOR="$dir/ed" ./bar "$@" 2>"$WORK/stderr")" || RC=$?
}

# <cwd> <dir> [args..] - runs the installed 'bar' of <dir> from <cwd>
runinst_in() {
    local cwd="$1"
    local dir="$2"
    shift 2
    RC=0
    OUT="$(cd "$cwd" && PATH="$dir/prefix/bin:$PATH" EDITOR="$dir/ed" bar "$@" 2>"$WORK/stderr")" || RC=$?
}

# <dir> [args..] - the installed bar, run from the project which falls back to it
runinst() {
    local dir="$1"
    shift
    runinst_in "$dir/project" "$dir" "$@"
}

echo "AC1 every clause of a rule, with the file and line it is written at"
run "$PROJECT" rule_show alpha
check "$RC" 0 "'rule_show alpha' exits 0"
contains "$OUT" "$BARF_RULEFILE:$ALPHA_BARF" "the clause of the rulefile, with its line"
contains "$OUT" "rule alpha: -- 'echo alpha'" "and its source"
contains "$OUT" "$MODULE:$ALPHA_MODULE" "the clause the module adds, with its line"
contains "$OUT" "rule alpha: -- 'echo module-alpha'" "and its source"
echo

echo "AC2 a continued statement is shown whole"
run "$PROJECT" rule_show delta
check "$RC" 0 "'rule_show delta' exits 0"
contains "$OUT" "rule delta: \\" "the first line of the statement"
contains "$OUT" "'alpha?'\\" "its continuation, which a single-line read would drop"
contains "$OUT" "'beta?'" "and the last line of it"
echo

echo "AC3 a rule which only calls its function prints that function too"
run "$PROJECT" rule_show gamma
check "$RC" 0 "'rule_show gamma' exits 0"
contains "$OUT" "rule gamma:" "the rule itself"
contains "$OUT" "function gamma" "the function it calls"
contains "$OUT" "echo gamma" "with its body, not only its signature"
echo

echo "AC4 a name no rule file defines is an error"
run "$PROJECT" rule_show no_such_rule
check "$RC" 1 "'rule_show' of an unknown name exits 1"
check "$OUT" "" "and prints no source"
contains "$(cat "$WORK/stderr")" "no_such_rule" "the name is named on stderr"
echo

echo "AC5 one defining file: opened at the statement"
run "$PROJECT" rule_edit gamma
check "$RC" 0 "'rule_edit gamma' exits 0"
check "$OUT" "+$GAMMA_RULE $MODULE" "the editor is called at the line of the rule"
echo

echo "AC6 several defining files: the chosen one is opened"
RC=0
OUT="$(cd "$PROJECT" && printf '2\n' | EDITOR="$PROJECT/ed" ./bar rule_edit alpha 2>"$WORK/stderr")" || RC=$?
check "$RC" 0 "'rule_edit alpha' exits 0"
contains "$(cat "$WORK/stderr")" "$BARF_RULEFILE:$ALPHA_BARF" "the menu lists the clause of the rulefile"
contains "$(cat "$WORK/stderr")" "$MODULE:$ALPHA_MODULE" "and the one of the module"
check "$OUT" "+$ALPHA_MODULE $MODULE" "the second entry is what the editor is called with"
echo

echo "AC7 a filepattern narrows the list"
run "$PROJECT" rule_edit alpha fixture_rules
check "$RC" 0 "'rule_edit alpha fixture_rules' exits 0"
check "$OUT" "+$ALPHA_MODULE $MODULE" "the matching file is opened without a menu"
run "$PROJECT" rule_edit alpha Barf
check "$OUT" "+$ALPHA_BARF $BARF_RULEFILE" "a plain word selects a file by its path"
run "$PROJECT" rule_edit alpha 'nomatch*'
check "$RC" 1 "a pattern which selects nothing exits 1"
contains "$(cat "$WORK/stderr")" "nomatch*" "and says which pattern it was"
echo

echo "AC8 '-f|--function' searches function definitions"
run "$PROJECT" rule_edit -f gamma
check "$OUT" "+$GAMMA_FUNCTION $MODULE" "the function is opened at its own line"
run "$PROJECT" rule_edit gamma
check "$OUT" "+$GAMMA_RULE $MODULE" "and the rule at the rules line"
echo

echo "AC9 '-h' answers what 'bar usage' answers"
RC=0
OUT="$(cd "$REPO_ROOT" && "$BAR" usage rule_show 2>/dev/null)" || RC=$?
check "$RC" 0 "'bar usage rule_show' exits 0"
USAGE="$OUT"
RC=0
OUT="$(cd "$REPO_ROOT" && "$BAR" rule_show -h 2>/dev/null)" || RC=$?
check "$RC" 0 "'rule_show -h' exits 0"
check "$OUT" "$USAGE" "the same text"
RC=0
OUT="$(cd "$REPO_ROOT" && "$BAR" usage rule_edit 2>/dev/null)" || RC=$?
check "$RC" 0 "'bar usage rule_edit' exits 0"
USAGE="$OUT"
RC=0
OUT="$(cd "$REPO_ROOT" && "$BAR" rule_edit -h 2>/dev/null)" || RC=$?
check "$OUT" "$USAGE" "'rule_edit -h' answers the same"
echo

echo "AC10 the rules are documented"
OUT="$(cd "$REPO_ROOT" && "$BAR" usage rule_show 2>/dev/null)"
contains "$OUT" "rule_show <rulename>" "the rule carries its prototype"
contains "$OUT" "Prints the source of a rule" "and its description"
OUT="$(cd "$REPO_ROOT" && "$BAR" usage rule_edit 2>/dev/null)"
contains "$OUT" "rule_edit <rulename> [-f|--function] [filepattern]" "and so does 'rule_edit'"
echo

echo "AC11 a definition written outside the base directory is refused"
INSTALLED_BAR="$INSTALL/prefix/bin/bar"
INSTALLED_MODULE="$INSTALL/prefix/share/bar/Bar.d/fixture_rules"
INSTALL_BARF="$INSTALL/project/Barf"
runinst "$INSTALL" rule_edit -f bar_main
check "$RC" 1 "'rule_edit' of a function of the installed bar exits 1"
check "$OUT" "" "and opens nothing"
ERR="$(cat "$WORK/stderr")"
contains "$ERR" "$INSTALLED_BAR:" "stderr names the file the function is written in"
contains "$ERR" "outside" "and says that it is outside the base directory"
contains "$ERR" "change into that directory" "and what to do about it"
runinst "$INSTALL" rule_show alpha
check "$RC" 0 "'rule_show' still reads the installation"
contains "$OUT" "$INSTALLED_MODULE:" "including the clause written there"
echo

echo "AC12 changing into that directory is how one edits there"
runinst_in "$INSTALL/prefix/share/bar" "$INSTALL" rule_edit -f rule_editor_open
check "$RC" 0 "'rule_edit' from inside the installation exits 0"
contains "$OUT" " $INSTALL/prefix/share/bar/Bar.d/rule_lib" "the module of the installation is opened"
echo

echo "AC13 written inside and outside: the inside one opens, without a menu"
ALPHA_INSTALL_BARF="$(line_of "$INSTALL_BARF" '^rule alpha:')"
runinst "$INSTALL" rule_edit alpha
check "$RC" 0 "'rule_edit alpha' exits 0"
check "$OUT" "+$ALPHA_INSTALL_BARF $INSTALL_BARF" "the project's own clause is opened, directly"
check "$(grep -c -- "$INSTALLED_MODULE" "$WORK/stderr" || true)" 0 "the installed copy is not offered"
echo

echo
if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All rule_show / rule_edit tests passed ==="
