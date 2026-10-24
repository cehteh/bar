#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'bar usage' (the rule in Bar.d/std_rules, 'help_usage' in Bar.d/help).
#
#   AC1  '<name>' answers the builtin help of that rule or function: its '##' prototype and
#        description, and nothing of the documentation that comes later
#   AC2  the module is derived the way the module loader derives it: 'always_', 'is_', 'has_' and
#        'try_' stripped, the word before the first '_', looked up as '<module>', '<module>_lib'
#        and '<module>_rules' -- a name whose module is a '_lib' or a '_rules' module is answered
#        from it
#   AC3  a name the narrowed module list does not carry still answers, from the full documentation
#   AC4  no name at all is a usage error: exit 2, the reason and where the help is, on stderr
#   AC5  a rule's '-h' and 'bar usage <rule>' print the same text, so the code which refuses an
#        argument never has to carry one
#   AC6  no module carries its own usage text any more
#
# usage: tests/test_usage.sh

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

OUT="" RC=0
run() {
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BAR" "$@" 2>"$WORKDIR/err")" || RC=$?
}
run_err() {
    RC=0
    OUT="$(cd "$REPO_ROOT" && "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}

echo "AC1 the builtin help of the name asked for"
run usage rad_state
check "$RC" 0 "'rad_state' is answered, exit 0"
contains "$OUT" "rad_state [--json] [--max <n>]" "with its prototype"
contains "$OUT" "the radicle state of this checkout" "and its description"
absent "$OUT" "BAshRulez" "and not the whole documentation"
run usage rad_trust
contains "$OUT" "rad_trust --repo <rid|path> --author <did|nid|alias>" "a rule's options are its prototype"
echo

echo "AC2 the module is derived like the module loader derives it"
run usage is_testdir_used
check "$RC" 0 "a helper of a single-word module is answered"
contains "$OUT" "is_testdir_used" "with its own entry"
run usage githook_enable
check "$RC" 0 "a helper of a '_rules' module is answered"
contains "$OUT" "githook_enable" "with its own entry"
run usage json_string
check "$RC" 0 "a helper of a '_lib' module is answered"
contains "$OUT" "json_string" "with its own entry"
echo

echo "AC3 a name outside those modules falls back to the full documentation"
run usage is_command_installed
check "$RC" 0 "'is_command_installed' derives 'command', which is no module: the fallback answers"
contains "$OUT" "is_command_installed <command>" "and the answer is still the right one"
run usage no_such_name_at_all
check "$RC" 0 "an unknown name is not an error"
contains "$OUT" "BAshRulez the bash rule evaluator" "it answers the whole documentation, like 'bar help'"
echo

echo "AC4 no name is a usage error"
run_err usage
check "$RC" 2 "exit 2"
contains "$OUT" "usage: a rule, function or variable name is required" "the reason is named"
contains "$OUT" "try 'bar usage usage'" "and the help of 'usage' is pointed at"
echo

echo "AC5 '-h' and 'bar usage' are the same text"
run usage rad_topic
USAGE="$OUT"
run rad_topic -h
check "$RC" 0 "'rad_topic -h' exits 0"
check "$OUT" "$USAGE" "'-h' answers what 'bar usage rad_topic' answers"
run usage sourcetree_state
USAGE="$OUT"
run sourcetree_state -h
check "$OUT" "$USAGE" "the same holds for a rule which had a usage helper of its own"
echo

echo "AC6 no module carries its own usage text"
HELP="$(cd "$REPO_ROOT" && "$BAR" help 2>/dev/null)"
absent "$HELP" "usage: rad_" "no 'rad_*' usage text is left in the documentation"
absent "$HELP" "usage: bar hermes" "and none in the hermes modules"
absent "$HELP" "usage: bar sourcetree" "and none in the source-tree module"
if [[ -e "$REPO_ROOT/Bar.d/usage" ]]; then
    fail "the 'usage' module still exists: the rule belongs in 'Bar.d/std_rules', the function in 'Bar.d/help'"
else
    pass "no 'usage' module: the rule is in 'Bar.d/std_rules', the function in 'Bar.d/help'"
fi
STRAY_USAGE="$(grep -rho 'function [a-z_]*_usage' "$REPO_ROOT/Bar.d/" | sort -u | grep -v '^function help_usage$' || true)"
if [[ -n "$STRAY_USAGE" ]]; then
    fail "a usage helper other than 'help_usage' is still defined: $STRAY_USAGE"
else
    pass "no usage helper other than 'help_usage' is defined in Bar.d/"
fi
echo

echo
if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All usage helper tests passed ==="
