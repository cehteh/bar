#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# tty_lib: the styles are a small static table, by name.
#
# The module used to build the whole 17x17x8 colour matrix -- 3,822 keys, every foreground,
# background and style combination -- on every invocation, and the call sites read it by colour
# encoding ('${TTYERR[K_B]}').  It is a written out table now, keyed by style name, and this test
# holds the three properties that make that safe:
#
#   T1  the names in the documentation are exactly the keys of both tables
#   T2  every name the tree subscripts is one of them (a typo is an error at run time, not a
#       message which lost its colour, so the tree must not carry one)
#   T3  a name which is not in the table is an error under 'set -u', not an empty string
#   T4  'COLOR=never' and 'TERM=dumb' yield the empty string, 'COLOR=always' the sequence
#   T5  'tty_style' adds a name to both tables, and replaces a built in one
#   T6  a project prints styled and unstyled through bar, end to end

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"
TTY_LIB="$REPO_ROOT/Bar.d/tty_lib"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }

echo "=== tty_lib: a static table by style name ==="
echo

# 'source <module>; <probe>' in a shell with the given colour settings.
tty_probe() {
    local env_setting="$1" probe="$2"
    env TERM=xterm $env_setting bash -uc "source \"$TTY_LIB\"; $probe"
}

# ---------------------------------------------------------------------------------------------------
# T1 -- documented names and table keys agree
# ---------------------------------------------------------------------------------------------------
doc_names="$(awk '/^###   reset /{ on = 1 } on && /^###$/{ exit } on && /^###   [a-z]/{ print $2 }' \
    "$TTY_LIB" | sort)"
if [[ -n "$doc_names" ]]; then
    pass "the documentation names $(wc -l <<<"$doc_names") styles"
else
    fail "no style names found in the documentation block"
fi

ctl_names="$(tty_probe COLOR=always 'printf "%s\n" "${!TTYCTL[@]}"' | sort)"
nil_names="$(tty_probe COLOR=never 'printf "%s\n" "${!TTYNIL[@]}"' | sort)"

[[ "$doc_names" = "$ctl_names" ]] \
    && pass "TTYCTL holds exactly the documented names" \
    || fail "TTYCTL and the documentation disagree: $(diff <(echo "$doc_names") <(echo "$ctl_names") | tr '\n' ' ')"

[[ "$doc_names" = "$nil_names" ]] \
    && pass "TTYNIL mirrors exactly those names" \
    || fail "TTYNIL and the documentation disagree: $(diff <(echo "$doc_names") <(echo "$nil_names") | tr '\n' ' ')"

# ---------------------------------------------------------------------------------------------------
# T2 -- every name the tree subscripts is in the table
# ---------------------------------------------------------------------------------------------------
used="$(grep -rho 'TTY\(OUT\|ERR\)\[[a-zA-Z_][a-zA-Z_0-9]*\]' \
        "$REPO_ROOT/bar" "$REPO_ROOT/Bar.d/std_lib" "$REPO_ROOT/example" \
        "$REPO_ROOT/contrib" 2>/dev/null \
    | sed 's/.*\[\(.*\)\]/\1/' | sort -u)"
unknown="$(comm -23 <(echo "$used") <(echo "$doc_names"))"

if [[ -z "$unknown" ]]; then
    pass "all $(( $(wc -l <<<"$used") )) names the tree uses are in the table"
else
    fail "the tree subscripts names the table does not have: $(echo "$unknown" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------------------------------
# T3 -- a name which is not there is an error, under 'set -u'
# ---------------------------------------------------------------------------------------------------
if out="$(tty_probe COLOR=always ': "${TTYERR[nosuchstyle]}"' 2>&1)"; then
    fail "a missing style did not fail: '$out'"
else
    [[ "$out" == *nosuchstyle* ]] \
        && pass "a missing style is an error naming it" \
        || fail "a missing style failed without naming it: '$out'"
fi

# ---------------------------------------------------------------------------------------------------
# T4 -- what the two tables and the two colour settings produce
# ---------------------------------------------------------------------------------------------------
always="$(tty_probe COLOR=always 'printf %s "${TTYOUT[fail]}"')"
never="$(tty_probe COLOR=never 'printf %s "${TTYOUT[fail]}"')"

[[ "$always" = $'\e[31;1m' ]] && pass "COLOR=always gives the sequence" \
                              || fail "COLOR=always gave '$always'"
[[ -z "$never" ]] && pass "COLOR=never gives the empty string" \
                  || fail "COLOR=never gave '$never'"
dumb="$(TERM=dumb COLOR=always bash -uc "source \"$TTY_LIB\"; printf %s \"\${TTYOUT[fail]}\"")"
[[ -z "$dumb" ]] && pass "TERM=dumb gives the empty string, whatever COLOR says" \
                 || fail "TERM=dumb gave '$dumb'"

# ---------------------------------------------------------------------------------------------------
# T5 -- 'tty_style' adds to both tables and replaces a built in style
# ---------------------------------------------------------------------------------------------------
added="$(tty_probe COLOR=always 'tty_style mine $'"'"'\e[38;5;33m'"'"'; printf "%s|%s|%s" \
    "${TTYCTL[mine]}" "${TTYNIL[mine]}" "${TTYOUT[mine]}"')"
[[ "$added" = "$(printf '\e[38;5;33m')||$(printf '\e[38;5;33m')" ]] \
    && pass "tty_style sets TTYCTL, mirrors the empty string into TTYNIL, and TTYOUT sees it" \
    || fail "tty_style produced '$added'"

replaced="$(tty_probe COLOR=always 'tty_style fail $'"'"'\e[4m'"'"'; printf %s "${TTYERR[fail]}"')"
[[ "$replaced" = $'\e[4m' ]] && pass "tty_style replaces a built in style" \
                             || fail "replacing 'fail' produced '$replaced'"

# ---------------------------------------------------------------------------------------------------
# T6 -- end to end through bar, styled and unstyled
# ---------------------------------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Bar.d"
for module in std_lib rule_lib tty_lib; do
    ln -s "$REPO_ROOT/Bar.d/$module" "$WORK/Bar.d/$module"
done

cat > "$WORK/Barf" <<'BARF'
function probe
{
    progress "step one"
    success "fine"
    failure "broke"
    warn "w1"
    note "n1"
    error "an error"
    ( die "a fatal one" )
}
rule MAIN: probe
BARF

styled="$( cd "$WORK" && TERM=xterm COLOR=always "$BAR" 2>&1 || true )"
plain="$( cd "$WORK" && TERM=xterm COLOR=never "$BAR" 2>&1 || true )"

if [[ "$styled" == *$'\e[31;1m'* && "$styled" == *$'\e[91;1m'* ]]; then
    pass "bar prints styled messages under COLOR=always"
else
    fail "bar printed no escape sequences under COLOR=always: $styled"
fi

if [[ "$plain" != *$'\e['* && "$plain" == *"FAIL:"* && "$plain" == *"PANIC:"* ]]; then
    pass "bar prints the same messages without escapes under COLOR=never"
else
    fail "bar under COLOR=never printed: $plain"
fi

# bar's own report path ('error'/'die' inside bar) uses the table as well
if out="$( cd "$REPO_ROOT" && TERM=xterm COLOR=always "$BAR" --bare nosuchrule 2>&1 )"; then
    fail "an unknown rule succeeded"
else
    [[ "$out" == *"PANIC:"* ]] && pass "bar's own fatal report works with the named styles" \
                               || fail "bar's fatal report printed: $out"
fi

echo
if (( failures )); then
    echo "✗ $failures check(s) failed"
    exit 1
fi
echo "✓ all tty_lib checks passed"
