#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Regression tests for reduced verbosity.
#
# F1: '--quiet' (and any BAR_VERBOSITY_LEVEL <= 1) used to make an *otherwise successful* rule exit
#     1.  The reporting helpers (progress/success/failure in Bar.d/std_lib) end their verbosity guards
#     in '(( ... )) && { ... }', which evaluates to status 1 when it suppresses the output; the
#     helpers are called as plain statements while 'set -euo pipefail' is active, so the shell aborted
#     right after 'success ...'.  Reduced verbosity must only suppress output -- never change the exit
#     code of the rule.
#
# F2: the shipped Pleasef.default called 'net_wakonlan' (typo), a function that does not exist, so the
#     documented 'please wake <host>' could never work.  It must call 'net_wakeonlan' (Bar.d/net).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }

echo "=== Testing reduced verbosity (F1) and the Pleasef wake typo (F2) ==="
echo

# ---------------------------------------------------------------------------------------------------
# A throw-away project with one succeeding and one failing rule, so the exit-code contract can be
# checked without depending on this repository's own rules.
# ---------------------------------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Bar.d"
ln -s "$REPO_ROOT/Bar.d/std_lib" "$WORK/Bar.d/std_lib"
ln -s "$REPO_ROOT/Bar.d/rule_lib" "$WORK/Bar.d/rule_lib"
ln -s "$REPO_ROOT/Bar.d/tty_lib" "$WORK/Bar.d/tty_lib"
touch "$WORK/Bar.d/dummy_rules"   # satisfy the Bar.d/*_rules glob

cat > "$WORK/Barf" <<'BARF'
rule good: -- 'true'
rule bad: -- 'false'
BARF

# 1. A successful rule exits 0 at every reduced verbosity level (this is the F1 regression).
for level in 0 1 2; do
    if (cd "$WORK" && BAR_VERBOSITY_LEVEL=$level "$BAR" --bare good >/dev/null 2>&1); then
        pass "successful rule exits 0 with BAR_VERBOSITY_LEVEL=$level"
    else
        fail "successful rule did NOT exit 0 with BAR_VERBOSITY_LEVEL=$level (F1 regression)"
    fi
done

# 2. Suppression actually happens: no 'OK:' line at level 0, an 'OK:' line at the default level 2.
out0="$(cd "$WORK" && BAR_VERBOSITY_LEVEL=0 "$BAR" --bare good 2>&1 || true)"
out2="$(cd "$WORK" && BAR_VERBOSITY_LEVEL=2 "$BAR" --bare good 2>&1 || true)"
if [[ "$out0" != *"OK:"* ]]; then
    pass "output is suppressed at BAR_VERBOSITY_LEVEL=0"
else
    fail "output is NOT suppressed at BAR_VERBOSITY_LEVEL=0: [$out0]"
fi
if [[ "$out2" == *"OK:"* ]]; then
    pass "verdict is still printed at BAR_VERBOSITY_LEVEL=2"
else
    fail "verdict is missing at BAR_VERBOSITY_LEVEL=2: [$out2]"
fi

# 3. Reduced verbosity must NOT swallow failures: a failing rule still exits non-zero (and at higher
#    verbosity too, as a control).
for level in 0 1 2; do
    if (cd "$WORK" && BAR_VERBOSITY_LEVEL=$level "$BAR" --bare bad >/dev/null 2>&1); then
        fail "failing rule exited 0 with BAR_VERBOSITY_LEVEL=$level (failures must not be swallowed)"
    else
        pass "failing rule still exits non-zero with BAR_VERBOSITY_LEVEL=$level"
    fi
done

# 4. '--quiet' (the rule in std_rules) behaves the same way on a real repository rule.
if (cd "$REPO_ROOT" && "$BAR" --quiet is_git_repository >/dev/null 2>&1); then
    pass "'./bar --quiet is_git_repository' exits 0"
else
    fail "'./bar --quiet is_git_repository' did NOT exit 0 (F1 regression)"
fi
if (cd "$REPO_ROOT" && "$BAR" --quiet rule_exists this_rule_does_not_exist >/dev/null 2>&1); then
    fail "'./bar --quiet rule_exists <missing>' must not exit 0"
else
    pass "'--quiet' keeps the failing exit code of a failing rule"
fi

# ---------------------------------------------------------------------------------------------------
# F2: Pleasef.default must call the function that actually exists.
# ---------------------------------------------------------------------------------------------------
if grep -q 'net_wakonlan' "$REPO_ROOT/Pleasef.default"; then
    fail "Pleasef.default still calls the non-existent 'net_wakonlan' (F2 regression)"
else
    pass "Pleasef.default no longer references the non-existent 'net_wakonlan'"
fi

# The callee must be defined and resolvable by bar (no 'no rule, command or function' panic).
if grep -q 'function net_wakeonlan' "$REPO_ROOT/Bar.d/net"; then
    pass "Bar.d/net defines net_wakeonlan"
else
    fail "Bar.d/net does not define net_wakeonlan"
fi
wakeout="$(cd "$REPO_ROOT" && "$BAR" --bare net_wakeonlan 2>&1 || true)"
if [[ "$wakeout" == *"no rule, command or function"* ]]; then
    fail "Pleasef wake target is not resolvable: $wakeout"
else
    pass "Pleasef wake target 'net_wakeonlan' is resolvable"
fi

echo
if (( failures == 0 )); then
    echo "=== All verbosity/wake tests passed ==="
else
    echo "=== $failures verbosity/wake test(s) FAILED ==="
    exit 1
fi
