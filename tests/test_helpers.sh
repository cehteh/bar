#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the helper repertoire infrastructure (Bar.d/helpers_rules).
#
# Everything runs against throw-away projects and a throw-away installation, so nothing here
# depends on this repository's own rules or on the helpers any other card will add.  Covered:
#
#   AC1  the index: one line per helper, sorted, plus the total count, exit 0, clean stdout
#   AC2  the same repertoire on two runs (deterministic) and with a different cwd
#   AC3  --json is one valid object with the same count and names, 'bar --json helpers' too
#   AC4  an unknown argument is a usage error (exit 2), no output on stdout
#   AC5  listing loads no helper module; invoking one loads only its own module
#   AC6  a declaration without a rule is not listed (the index never shows what does not resolve)
#   AC7  the guard passes a registered repertoire and is one line under 'bar check'
#   AC8  every listed helper really runs
#   AC9  the guard fails for each violation class, naming file and line
#   AC10 the module header prose reaches 'bar help' (and the repertoire section does too)
#   AC11 'bar init_install' links a module which was added later, without a manual symlink
#   AC12 a re-run of 'init_install' from another checkout does not repoint existing links
#   AC13 'please helpers' works from an arbitrary directory, in a fresh installation
#   AC14 the index stays below 150 ms (best of 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar and the repertoire (agent_rules supplies the
# '--json' rule of 'bar --json <rule>')
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib agent_rules helpers_rules"
# the modules a throw-away installation needs: the fixture set plus 'init', which provides the
# 'init_install' rule the installation is created with
INSTALL_MODULES="$FIXTURE_MODULES init"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }
bytes_of() { printf '%s' "$1" | wc -c; }

echo "=== Testing the helper repertoire (Bar.d/helpers_rules) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT=""
RC=0
run_bar() { # <dir> <args..>
    local dir="$1"
    shift
    OUT=""
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>/dev/null)" || RC=$?
}
run_bar_err() { # <dir> <args..> - capture stderr instead
    local dir="$1"
    shift
    OUT=""
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}
run_in() { # <dir> <cmd..> - run a command with the cwd changed
    local dir="$1"
    shift
    OUT=""
    RC=0
    OUT="$(cd "$dir" && "$@" 2>/dev/null)" || RC=$?
}

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

# <dir> - a throw-away project: bar, the modules it needs and two helper modules
#
# The fixture directories carry no space in their name: bar itself cannot run from a toplevel
# whose path contains one (measured on the unmodified checkout -- 'require' splits the Barf path
# at the space and the rule is then not found).  That is a bar limitation, not this module's.
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
    cat >"$1/Barf" <<'BARF'
rule MAIN: -- true
BARF
    cat >"$1/Bar.d/frob" <<'MODULE'
# -*- mode: sh; sh-shell: bash -*-

### Fixture helper module: counts frobs.

# helper-module: frob

# helper: frob | count the frobs | frob [--json] | one line per frob, then '(n frobs)'
## List the frobs (fixture).
rule frob: -

# helper: frob_extra | the extra frobs | frob_extra | one word
## The extra frobs (fixture).
rule frob_extra: -- printf '"extra\n"'

function frob
{
    local arg
    for arg in ${1+"$@"}; do
        if [[ "$arg" == --json ]]; then
            printf '{"frobs":2}\n'
            return 0
        fi
    done
    printf 'frob-a\nfrob-b\n(2 frobs)\n'
}

if [[ -n "${HELPERS_TEST_LOAD_LOG:-}" ]]; then
    printf 'frob\n' >>"$HELPERS_TEST_LOAD_LOG"
fi
MODULE
    cat >"$1/Bar.d/quux" <<'MODULE'
# -*- mode: sh; sh-shell: bash -*-

### Fixture helper module: quuxes.

# helper-module: quux

# helper: quux | count the quuxes | quux | one line
## List the quuxes (fixture).
rule quux: -- printf '"quux\n"'

if [[ -n "${HELPERS_TEST_LOAD_LOG:-}" ]]; then
    printf 'quux\n' >>"$HELPERS_TEST_LOAD_LOG"
fi
MODULE
}

# <dir> - a throw-away bar checkout to install from: bar plus the modules the installation needs
#
# It links the same module set 'mkproject' does, not every module of this repository: a helper
# module added to the repository later must not move the counts this test asserts (it did, for the
# first helper added after this file was written -- the installation is a fixture, not a mirror).
mkinstall() {
    mkdir -p "$1/Bar.d" "$1/contrib"
    cp "$BAR" "$1/bar"
    cp "$REPO_ROOT/Barf.default" "$1/"
    cp "$REPO_ROOT/Pleasef.default" "$1/"
    cp "$REPO_ROOT/contrib/bar_complete" "$1/contrib/"
    local module
    for module in $INSTALL_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
}

PROJ="$WORK/proj"
mkproject "$PROJ"

# --------------------------------------------------------------------------------------------
# AC1  the index: one line per helper, sorted, plus the count
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" helpers
check "$RC" "0" "AC1: 'bar helpers' exits 0"
INDEX="$OUT"
check "$(printf '%s\n' "$OUT" | wc -l)" "4" "AC1: three helpers and the count are four lines"
check "$(sed -n 1p <<<"$OUT")" \
    "frob        count the frobs  | frob [--json]  | one line per frob, then '(n frobs)'" \
    "AC1: the first line is '<name>  <purpose>  | <invocation>  | <output shape>'"
check "$(sed -n 2p <<<"$OUT")" "frob_extra  the extra frobs  | frob_extra  | one word" \
    "AC1: the second line is the other helper of that module"
check "$(sed -n 3p <<<"$OUT")" "quux        count the quuxes  | quux  | one line" \
    "AC1: the helpers are sorted by name"
check "$(sed -n 4p <<<"$OUT")" "(3 helpers)" "AC1: the total count is the last line"
if (( $(bytes_of "$OUT") <= 512 )); then pass "AC1: the index is $(bytes_of "$OUT") B"; else fail "AC1: the index is $(bytes_of "$OUT") B"; fi
run_bar_err "$PROJ" helpers
absent "$OUT" "WARN" "AC1: a complete repertoire produces no warning"
contains "$OUT" "OK: helpers" "AC1: only bar's own stderr record accompanies it"

# an empty repertoire is an answer, not an error
mkproject "$WORK/empty"
rm "$WORK/empty/Bar.d/frob" "$WORK/empty/Bar.d/quux"
run_bar "$WORK/empty" helpers
check "$RC" "0" "AC1: an empty repertoire exits 0"
check "$OUT" "(0 helpers)" "AC1: an empty repertoire says so"

# --------------------------------------------------------------------------------------------
# AC2  deterministic, and independent of the working directory
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" helpers
check "$OUT" "$INDEX" "AC2: two runs print the same index (order and alignment are stable)"
run_bar "$WORK/empty" helpers
check "$RC" "0" "AC2: a repertoire without any helper still answers"
mkdir -p "$PROJ/sub/dir"
run_bar "$PROJ/sub/dir" helpers
check "$RC" "0" "AC2: the index works from a subdirectory (the module directory is found upwards)"
check "$OUT" "$INDEX" "AC2: and does not depend on the cwd"

# --------------------------------------------------------------------------------------------
# AC3  --json, from the argument and from 'bar --json'
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" helpers --json
check "$RC" "0" "AC3: 'helpers --json' exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "1" "AC3: 'helpers --json' is one line"
if command -v jq >/dev/null; then
    check "$(printf '%s' "$OUT" | jq -r '.count')" "3" "AC3: the JSON count matches the text form"
    check "$(printf '%s' "$OUT" | jq -r '[.helpers[].name] | join(",")')" "frob,frob_extra,quux" \
        "AC3: the JSON names are the listed helpers"
    check "$(printf '%s' "$OUT" | jq -r '.helpers[1].invocation')" "frob_extra" \
        "AC3: every helper carries its invocation"
    check "$(printf '%s' "$OUT" | jq -r '.bar_helpers')" "1" "AC3: the object identifies itself"
else
    pass "AC3: jq is not installed, the JSON is only checked for its shape"
fi
run_bar "$PROJ" --json helpers
check "$(printf '%s' "$OUT" | sed -n 's/.*"count":\([0-9]*\).*/\1/p')" "3" \
    "AC3: 'bar --json helpers' prints the same count"
run_bar "$WORK/empty" helpers --json
check "$OUT" '{"bar_helpers":1,"count":0,"helpers":[]}' \
    "AC3: an empty repertoire is a valid empty object"

# --------------------------------------------------------------------------------------------
# AC4  a usage error is exit 2 and leaves stdout alone
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" helpers --nonsense
check "$RC" "2" "AC4: an unknown argument exits 2"
check "$OUT" "" "AC4: an unknown argument prints nothing on stdout"
run_bar_err "$PROJ" helpers --nonsense
contains "$OUT" "usage: bar helpers [--json|--check]" "AC4: the usage goes to stderr"

# --------------------------------------------------------------------------------------------
# AC5  listing loads nothing, invoking loads one module
# --------------------------------------------------------------------------------------------
LOAD_LOG="$WORK/load.log"
: >"$LOAD_LOG"
run_in "$PROJ" env HELPERS_TEST_LOAD_LOG="$LOAD_LOG" "$BAR" helpers
check "$(cat "$LOAD_LOG")" "" "AC5: listing the repertoire loads no helper module"
: >"$LOAD_LOG"
run_in "$PROJ" env HELPERS_TEST_LOAD_LOG="$LOAD_LOG" "$BAR" frob_extra
check "$RC" "0" "AC5: the helper runs"
check "$(cat "$LOAD_LOG")" "frob" "AC5: invoking a helper loads its own module only"
: >"$LOAD_LOG"
run_in "$PROJ" env HELPERS_TEST_LOAD_LOG="$LOAD_LOG" "$BAR" quux
check "$(cat "$LOAD_LOG")" "quux" "AC5: another helper loads another module only"

# --------------------------------------------------------------------------------------------
# AC6  a declaration without a rule is not listed (the index shows nothing that does not resolve)
# --------------------------------------------------------------------------------------------
GHOST="$WORK/ghost"
mkproject "$GHOST"
cat >>"$GHOST/Bar.d/frob" <<'MODULE'

# helper: frob_ghost | a declaration without a rule | frob_ghost | nothing
MODULE
run_bar "$GHOST" helpers
check "$RC" "0" "AC6: the index still answers"
absent "$OUT" "frob_ghost" "AC6: the unresolvable declaration is not listed"
check "$OUT" "$INDEX" "AC6: the resolvable helpers are listed exactly as before"
run_bar_err "$GHOST" helpers
contains "$OUT" "unusable" "AC6: the rejection is counted on stderr"
run_bar "$GHOST" helpers_check
check "$RC" "1" "AC6: the guard fails for it"
contains "$OUT" "the declaration of 'frob_ghost' has no rule below it" "AC6: the guard names the declaration"

# --------------------------------------------------------------------------------------------
# AC7  the guard passes a registered repertoire, and is one line under 'bar check'
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" helpers --check
check "$RC" "0" "AC7: 'helpers --check' exits 0 for a registered repertoire"
check "$OUT" "" "AC7: 'helpers --check' says nothing when there is nothing to say"
run_bar "$PROJ" check helpers_check
check "$RC" "0" "AC7: 'check helpers_check' exits 0"
check "$OUT" "OK helpers_check" "AC7: the check is one line (the guard is an agent contract target)"

# --------------------------------------------------------------------------------------------
# AC8  everything the index lists really runs
# --------------------------------------------------------------------------------------------
listed="$(printf '%s\n' "$(cd "$PROJ" && "$BAR" helpers 2>/dev/null)" | sed -n 's/^\([^ ]*\) .*/\1/p' | grep -v '^(')"
check "$listed" "$(printf 'frob\nfrob_extra\nquux')" "AC8: the index lists three helpers"
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    run_bar "$PROJ" "$name"
    check "$RC" "0" "AC8: the listed helper '$name' resolves and runs"
done <<<"$listed"

# --------------------------------------------------------------------------------------------
# AC9  the guard fails for every violation class
# --------------------------------------------------------------------------------------------
broken_case() { # <name> <expected finding> <module content>
    local name="$1"
    local expected="$2"
    local content="$3"
    local dir="$WORK/broken/$name"
    mkproject "$dir"
    printf '%s\n' "$content" >"$dir/Bar.d/frob"
    run_bar "$dir" helpers_check
    check "$RC" "1" "AC9 ($name): the guard fails"
    contains "$OUT" "$expected" "AC9 ($name): the finding names the problem"
    contains "$OUT" "Bar.d/frob:" "AC9 ($name): the finding names the file"
}

broken_case "rule-without-declaration" "rule 'frob_extra' is not declared" '# helper-module: frob

# helper: frob | yes | frob | one line
rule frob: -- printf "ok\n"

rule frob_extra: -- printf "extra\n"'
broken_case "name-autoloading-another-module" "its name would autoload module 'git', not 'frob'" '# helper-module: frob

# helper: git_state | no | git_state | one line
rule git_state: -- printf "no\n"'
broken_case "declaration-outside-a-helper-module" "it is not below a '# helper-module:' header" '# helper: frob | no module header | frob | one line
rule frob: -- printf "ok\n"'
broken_case "malformed-declaration" "it needs 4 fields separated by '|', found 3" '# helper-module: frob

# helper: frob | only three fields | frob
rule frob: -- printf "ok\n"'
broken_case "empty-field" 'none of its name, purpose, invocation and output fields may be empty' '# helper-module: frob

# helper: frob | yes | ok | 
rule frob: -- printf "ok\n"'
broken_case "header-naming-another-file" "helper module 'frobs' is not the file 'frob' it is declared in" '# helper-module: frobs

# helper: frob | yes | frob | one line
rule frob: -- printf "ok\n"'
broken_case "duplicate-declaration" "is already declared in" '# helper-module: frob

# helper: frob | first | frob | one line
rule frob: -- printf "ok\n"

# helper: frob | second | frob | one line
rule frob: -- printf "ok\n"'
broken_case "declaration-separated-from-its-rule" "is separated from its rule by other code" '# helper-module: frob

# helper: frob | yes | frob | one line
function unrelated { :; }

rule frob: -- printf "ok\n"'
broken_case "module-without-helpers" "declares no helper" '# helper-module: frob

rule frob: -- printf "ok\n"'
broken_case "rule-not-matching-the-declaration" "does not match the declaration" '# helper-module: frob

# helper: frob | yes | frob | one line
rule frob_other: -- printf "ok\n"'

# a clean module under a different word stays clean (the word is what decides)
GOOD="$WORK/good"
mkproject "$GOOD"
rm "$GOOD/Bar.d/frob" "$GOOD/Bar.d/quux"
cat >"$GOOD/Bar.d/frob" <<'MODULE'
# helper-module: frob

# helper: frob | yes | frob | one line
rule frob: -- printf "ok\n"
MODULE
run_bar "$GOOD" helpers_check
check "$RC" "0" "AC9: one module with one registered helper passes the guard"

# --------------------------------------------------------------------------------------------
# AC10 the module header reaches 'bar help'
# --------------------------------------------------------------------------------------------
run_bar "$REPO_ROOT" help
contains "$OUT" "HELPER MODULES AND RULE NAMES" "AC10: the module header prose is in 'bar help'"
contains "$OUT" "HELPER REPERTOIRE" "AC10: the help section documents the repertoire"
contains "$OUT" "bar helpers --check" "AC10: 'bar help' names the guard"
contains "$OUT" "bar helpers" "AC10: 'bar help helpers' finds the repertoire"
run_bar "$REPO_ROOT" help helpers
check "$RC" "0" "AC10: 'bar help helpers' exits 0"
contains "$OUT" "HELPER REPERTOIRE" "AC10: the topic is reachable by name"

# --------------------------------------------------------------------------------------------
# AC11/AC12/AC13/AC14 a fresh installation
# --------------------------------------------------------------------------------------------
# The fixture installation carries the three helpers of the fixture project ('frob', 'frob_extra'
# and 'quux') plus every helper this repository itself ships.  That second part is counted here
# from the module sources: a card which adds a helper module must not have to edit these numbers,
# and hardcoding them made this test fail for every helper the repertoire gains.
REPO_HELPERS="$(LC_ALL=C grep -h -E '^# helper: .*\|' "$REPO_ROOT"/Bar.d/* | wc -l)"
FAKE_HOME="$WORK/home"
SITE="$WORK/site"
SITE2="$WORK/site2"
mkdir -p "$FAKE_HOME/.local"
mkinstall "$SITE"
mkproject "$WORK/installer"
cp "$WORK/installer/Bar.d/frob" "$SITE/Bar.d/frob"
cp "$WORK/installer/Bar.d/quux" "$SITE/Bar.d/quux"

(cd "$SITE" && HOME="$FAKE_HOME" ./bar init_install "$FAKE_HOME/.local" >/dev/null 2>&1) || true
if [[ -L "$FAKE_HOME/.config/please/helpers_rules" ]]; then
    pass "AC13: 'init_install' links the helper repertoire for 'please'"
else
    fail "AC13: no link for 'helpers_rules' in ~/.config/please"
fi
if [[ -L "$FAKE_HOME/.config/please/frob" ]]; then
    pass "AC11: the fixture helper module is linked"
else
    fail "AC11: no link for 'frob'"
fi

run_in "$WORK" env HOME="$FAKE_HOME" "$FAKE_HOME/.local/bin/please" helpers
check "$RC" "0" "AC13: 'please helpers' works from an arbitrary directory"
check "$(printf '%s\n' "$OUT" | tail -1)" "($((REPO_HELPERS + 3)) helpers)" \
    "AC13: and lists the installed repertoire (the fixture helpers and the ones shipped here)"
run_in "$WORK" env HOME="$FAKE_HOME" "$FAKE_HOME/.local/bin/please" frob_extra
check "$OUT" "extra" "AC13: an installed helper runs through 'please' too"

# AC11  a module which is added later is linked by a re-run of init_install
cat >"$SITE/Bar.d/late" <<'MODULE'
# helper-module: late

# helper: late | a helper which was added later | late | one line
rule late: -- printf '"late\n"'
MODULE
(cd "$SITE" && HOME="$FAKE_HOME" ./bar init_install "$FAKE_HOME/.local" >/dev/null 2>&1) || true
if [[ -L "$FAKE_HOME/.config/please/late" ]]; then
    pass "AC11: a re-run of 'init_install' links a module which was added later"
else
    fail "AC11: the module added later was not linked (a manual symlink would be needed)"
fi
run_in "$WORK" env HOME="$FAKE_HOME" "$FAKE_HOME/.local/bin/please" helpers
check "$(printf '%s\n' "$OUT" | tail -1)" "($((REPO_HELPERS + 4)) helpers)" \
    "AC11: and the index shows it without any other edit"
run_in "$WORK" env HOME="$FAKE_HOME" "$FAKE_HOME/.local/bin/please" late
check "$OUT" "late" "AC11: the new helper runs through 'please'"

# AC14  a re-run from another checkout must not repoint an installation at it
before="$(readlink "$FAKE_HOME/.config/please/helpers_rules")"
mkinstall "$SITE2"
(cd "$SITE2" && HOME="$FAKE_HOME" ./bar init_install "$FAKE_HOME/.local" >/dev/null 2>&1) || true
after="$(readlink "$FAKE_HOME/.config/please/helpers_rules")"
check "$after" "$before" "AC14: 'init_install' leaves an existing link alone"
run_in "$WORK" env HOME="$FAKE_HOME" "$FAKE_HOME/.local/bin/please" helpers
check "$(printf '%s\n' "$OUT" | tail -1)" "($((REPO_HELPERS + 4)) helpers)" \
    "AC14: the installation still works"

# AC14  the index stays cheap
time_run() { # <cmd..>
    local start end
    start="$(date +%s%N)"
    (cd "$WORK" && HOME="$FAKE_HOME" "$@" >/dev/null 2>&1) || true
    end="$(date +%s%N)"
    echo $(( (end - start) / 1000000 ))
}
best=1000000
for _ in 1 2 3 4 5; do
    t="$(time_run "$FAKE_HOME/.local/bin/please" helpers)"
    (( t < best )) && best="$t"
done
base=1000000
for _ in 1 2 3 4 5; do
    t="$(time_run "$FAKE_HOME/.local/bin/please" rule_exists foo)"
    (( t < base )) && base="$t"
done
if (( best < 150 )); then
    pass "AC14: 'please helpers' takes ${best} ms (best of 5, budget 150 ms; a bare bar call is ${base} ms)"
else
    fail "AC14: 'please helpers' takes ${best} ms (over the 150 ms budget; a bare bar call is ${base} ms)"
fi

echo
if (( failures == 0 )); then
    echo "=== All helper repertoire tests passed ==="
else
    echo "=== $failures helper repertoire assertion(s) FAILED ==="
    exit 1
fi
