#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Regression tests for the locale bar forces on itself ('bar_main', bar:51).
#
# F1: the selection was 'locale -a | grep -i 'C.utf.*8'' -- an unanchored pattern, so every UTF-8
#     locale whose name merely *contains* 'C.utf8' matched as well: on a host which has en_SC.utf8
#     and es_EC.utf8 the command substitution returned three lines, and 'LC_ALL' became the
#     multi-line string "C.utf8\nen_SC.utf8\nes_EC.utf8".  Bash then warned
#     'setlocale: LC_ALL: cannot change locale (...)' for that value and every child of bar ran
#     without a locale at all.
# F2: a host which has no UTF-8 C locale must keep getting a usable 'LC_ALL' ('C'), never an empty
#     one -- '... | head -n 1' looks like the same fix and leaves '' behind.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# mkproj <dir> - a project of its own: this repository's modules as its 'Bar.d', and one rule which
# prints the 'LC_ALL' the run decided on.  The modules are copied, so nothing here reaches the
# checkout, and the rule is '--bare' so no hook can change what it sees.
mkproj() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    cp -Lr "$REPO_ROOT/Bar.d/." "$dir/Bar.d/"
    cat >"$dir/Barf" <<'EOS'
show_locale: -- 'printf "%s" "$LC_ALL"'
EOS
}

# fakelocale <name> <line..> - a 'locale' on PATH which answers 'locale -a' with exactly these names,
# so a host whose locale list is the one in the report is reproduced on any host.
fakelocale() {
    local name="$1"
    shift
    mkdir -p "$WORK/$name/bin"
    {
        echo '#!/bin/sh'
        printf 'printf "%%s\\n"'
        printf ' %q' "$@"
        echo
    } >"$WORK/$name/bin/locale"
    chmod +x "$WORK/$name/bin/locale"
}

OUT="" ERR="" RC=0
# runin <dir> <fake-locale-dir> - run 'show_locale' with that 'locale' first on PATH.
runin() {
    local dir="$1" fake="$2"
    RC=0
    OUT="$( cd "$dir" && PATH="$fake/bin:$PATH" "$BAR" --bare show_locale 2>"$WORK/err" )" || RC=$?
    ERR="$(cat "$WORK/err")"
}

echo "=== Testing the utf8 locale selection (F1, F2) ==="
echo

echo "AC1 only the C locale itself is selected, however many names contain 'C.utf8'"
P="$WORK/ac1"
mkproj "$P"
fakelocale ac1 C C.utf8 de_DE.utf8 en_SC.utf8 es_EC.utf8 POSIX
runin "$P" "$WORK/ac1"
check "$RC" "0" "the run answers"
check "$OUT" "C.utf8" "LC_ALL is the one C UTF-8 locale"
absent "$ERR" "setlocale" "and bash does not warn about the locale it was given"
echo

echo "AC2 the C locale is still found when it is not the first entry"
P="$WORK/ac2"
mkproj "$P"
fakelocale ac2 C de_DE.utf8 C.utf8 POSIX
runin "$P" "$WORK/ac2"
check "$RC" "0" "the run answers"
check "$OUT" "C.utf8" "LC_ALL is the C UTF-8 locale"
absent "$ERR" "setlocale" "with no warning"
echo

echo "AC3 a UTF-8 name which does not belong to C is not selected"
P="$WORK/ac3"
mkproj "$P"
fakelocale ac3 C de_DE.utf8 en_SC.utf8 es_EC.utf8 POSIX
runin "$P" "$WORK/ac3"
check "$RC" "0" "the run answers"
check "$OUT" "C" "LC_ALL falls back to C"
absent "$ERR" "setlocale" "with no warning"
echo

echo "AC4 a host without any C UTF-8 locale still gets a usable LC_ALL (F2)"
P="$WORK/ac4"
mkproj "$P"
fakelocale ac4 C POSIX de_DE.utf8
runin "$P" "$WORK/ac4"
check "$RC" "0" "the run answers"
check "$OUT" "C" "LC_ALL is C, not an empty value"
absent "$ERR" "setlocale" "with no warning"
echo

echo "AC5 a modifier form of the name does not win over the plain C UTF-8 locale"
P="$WORK/ac5"
mkproj "$P"
fakelocale ac5 C C.utf8@euro C.utf8 de_DE.utf8
runin "$P" "$WORK/ac5"
check "$RC" "0" "the run answers"
check "$OUT" "C.utf8" "LC_ALL is the plain C UTF-8 locale, not the modifier form"
absent "$ERR" "setlocale" "with no warning"
echo

if (( failures )); then
    echo "FAILED: $failures check(s)"
    exit 1
fi
echo "=== All locale selection tests passed ==="
