#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Regression tests for condensing repeated report locations.
#
# F4: a multi line report (a single logical error printed by consecutive 'error'/'die' calls from
#     one function) repeated the complete 'ERROR: <file>:<line>:<func>:' prefix on every line --
#     'memodb_analyze' printed 12 such lines for one problem.  The source location must be printed
#     once and the repeats condensed, without losing the verbose, filterable format when the output
#     is redirected (only the console is simplified), and without changing any exit code.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }

echo "=== Testing condensed report locations (F4) ==="
echo

# ---------------------------------------------------------------------------------------------------
# A throw-away project with one function that emits a multi line report, one that reports from two
# sites, one whose report is interrupted (which must reset the condensing) and one that dies.
# ---------------------------------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Bar.d"
ln -s "$REPO_ROOT/Bar.d/std_lib" "$WORK/Bar.d/std_lib"
ln -s "$REPO_ROOT/Bar.d/rule_lib" "$WORK/Bar.d/rule_lib"
ln -s "$REPO_ROOT/Bar.d/tty_lib" "$WORK/Bar.d/tty_lib"

cat > "$WORK/Bar.d/report_rules" <<'RULES'
function report_multi
{
    error "first line"
    error "second line"
    error "third line"
}

function report_two_sites
{
    report_multi
    error "other site"
}

function report_split
{
    error "before"
    warn "interruption"
    error "after"
}

function report_fatal
{
    error "before the fatal"
    die "fatal last line"
}
RULES

cat > "$WORK/Barf" <<'BARF'
rule report: -- report_multi
rule two: -- report_two_sites
rule split: -- report_split
rule fatal: -- report_fatal
BARF

# Number of lines that still carry the report location ('Bar.d/report_rules:<line>:<func>:'), or
# '.bar.dump:<line>:' for a run served from the state dump -- naming the dump instead of the module
# is what the dump costs, and a run without it names the module.
count_locs() { grep -oE '(report_rules|\.bar\.dump):[0-9]+:' <<<"$1" | wc -l; }

# ---------------------------------------------------------------------------------------------------
# 1. The verbose format is the default for redirected output: every line keeps its location, so the
#    output stays greppable by file/line/function.
# ---------------------------------------------------------------------------------------------------
auto="$(cd "$WORK" && "$BAR" --bare report 2>&1 || true)"
if (( $(count_locs "$auto") == 3 )); then
    pass "redirected output keeps the full location on every line (bar_report_condense=auto)"
else
    fail "redirected output lost locations, expected 3 got $(count_locs "$auto"): [$auto]"
fi

never="$(cd "$WORK" && BAR_REPORT_CONDENSE=never "$BAR" --bare report 2>&1 || true)"
if (( $(count_locs "$never") == 3 )); then
    pass "BAR_REPORT_CONDENSE=never keeps the full location on every line"
else
    fail "BAR_REPORT_CONDENSE=never lost locations, expected 3 got $(count_locs "$never"): [$never]"
fi

# ---------------------------------------------------------------------------------------------------
# 2. Condensing prints the location once, keeps every message and aligns the continuation messages
#    with the first one (the prefix is replaced by blanks of the same width).
# ---------------------------------------------------------------------------------------------------
cond="$(cd "$WORK" && BAR_REPORT_CONDENSE=always "$BAR" --bare report 2>&1 || true)"
if (( $(count_locs "$cond") == 1 )); then
    pass "BAR_REPORT_CONDENSE=always prints the repeated location only once"
else
    fail "expected 1 location, got $(count_locs "$cond"): [$cond]"
fi
for text in "first line" "second line" "third line"; do
    if [[ "$cond" != *"$text"* ]]; then
        fail "condensing dropped the message '$text': [$cond]"
    fi
done
first_col="$(awk '/first line/{print index($0, "first line")}' <<<"$cond")"
second_col="$(awk '/second line/{print index($0, "second line")}' <<<"$cond")"
third_col="$(awk '/third line/{print index($0, "third line")}' <<<"$cond")"
if [[ -n "$first_col" && "$first_col" = "$second_col" && "$first_col" = "$third_col" ]]; then
    pass "condensed messages stay in the same column as the first one (column $first_col)"
else
    fail "condensed messages are not aligned: [$cond]"
fi
if ! awk '/first line/{next} /second line|third line/{if ($0 !~ /ERROR:/) exit 1}' <<<"$cond"; then
    fail "condensed lines lost the 'ERROR:' tag: [$cond]"
else
    pass "condensed lines (style tag) keep the 'ERROR:' tag"
fi

# ---------------------------------------------------------------------------------------------------
# 3. BAR_REPORT_STYLE=colon blanks the tag as well, only the ':' of the location remains.
# ---------------------------------------------------------------------------------------------------
colon="$(cd "$WORK" && BAR_REPORT_CONDENSE=always BAR_REPORT_STYLE=colon "$BAR" --bare report 2>&1 || true)"
if (( $(count_locs "$colon") == 1 )); then
    pass "style colon prints the repeated location only once"
else
    fail "style colon expected 1 location, got $(count_locs "$colon"): [$colon]"
fi
colon_col="$(awk '/second line/{print index($0, "second line")}' <<<"$colon")"
if [[ -n "$colon_col" ]] \
    && [[ "$(awk -v c="$colon_col" '/second line/{print substr($0, c-2, 1)}' <<<"$colon")" = ":" ]] \
    && [[ "$(awk -v c="$colon_col" '/second line/{print substr($0, c-1, 1)}' <<<"$colon")" = " " ]]; then
    pass "style colon leaves a single ':' in front of the continued message"
else
    fail "style colon did not leave the ':' marker: [$colon]"
fi

# ---------------------------------------------------------------------------------------------------
# 4. A different report site always prints its own location, and an interruption (warn) ends the
#    block so a later report from the same function prints its location again.
# ---------------------------------------------------------------------------------------------------
two="$(cd "$WORK" && BAR_REPORT_CONDENSE=always "$BAR" --bare two 2>&1 || true)"
if (( $(count_locs "$two") == 2 )); then
    pass "a second report site prints its own location"
else
    fail "expected 2 locations for two sites, got $(count_locs "$two"): [$two]"
fi
split="$(cd "$WORK" && BAR_REPORT_CONDENSE=always "$BAR" --bare split 2>&1 || true)"
if (( $(count_locs "$split") == 2 )); then
    pass "an interruption ends the condensed block"
else
    fail "expected 2 locations after the interruption, got $(count_locs "$split"): [$split]"
fi

# ---------------------------------------------------------------------------------------------------
# 5. Condensing is cosmetic only: it must not change the exit code of a failing rule.
# ---------------------------------------------------------------------------------------------------
for setting in never always; do
    for style in tag colon; do
        if (cd "$WORK" && BAR_REPORT_CONDENSE=$setting BAR_REPORT_STYLE=$style "$BAR" --bare fatal >/dev/null 2>&1); then
            fail "'die' exited 0 with condense=$setting style=$style"
        else
            pass "'die' keeps its exit code with condense=$setting style=$style"
        fi
    done
done
fatal="$(cd "$WORK" && BAR_REPORT_CONDENSE=always "$BAR" --bare fatal 2>&1 || true)"
if [[ "$fatal" = *"fatal last line"* ]]; then
    pass "the fatally reported message is still printed"
else
    fail "the fatally reported message is missing: [$fatal]"
fi

echo
if (( failures == 0 )); then
    echo "=== All report condense tests passed ==="
else
    echo "=== $failures report condense test(s) FAILED ==="
    exit 1
fi
