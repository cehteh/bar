#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the agent output contract (Bar.d/agent_rules).
#
# Every criterion of the contract is exercised here against a throw-away project with synthetic
# targets, so nothing in this file depends on this repository's own rules.  Covered:
#
#   AC1  success is exactly one line, small and 0
#   AC2  a failure block is bounded (lines and bytes) and carries verdict/chain/totals/log path
#   AC3  the printed totals equal 'wc -l -c' of the log, byte exact
#   AC4  'bar log' returns what 'sed -n'/'tail -n'/'cat' return, byte exact
#   AC5  stdout and stderr of a target are merged in true order
#   AC6  a failing target with no output at all still gets verdict, totals, log path and rc
#   AC7  exit codes: propagated rc, usage error, missing log
#   AC8  no keyword filtering: a signal line without any error keyword is surfaced or its exact
#        line range is named
#   AC9  two runs on an unchanged tree print the same block
#   AC10 the wrapper overhead stays below 150 ms
#   AC11 the block AND the exit code are identical at every verbosity (regression for F1)
#   AC12 a log stays retrievable after later runs of other targets (the 'latest' symlink is not
#        the lookup path)
#   AC13 the module is shellcheck clean
#   AC14 hostile logs (one 200 kB line, 40 x 10 kB lines) stay below BAR_AGENT_MAX_BYTES, while
#        'bar log' still returns every byte of them
#   AC15 old runs are pruned (BAR_AGENT_KEEP) and never delete the run that just happened
#   AC16 --json emits one valid object per run with the same numbers as the text block
#   AC17 evidence line numbers really address the log (sed -n '<n>p' returns that line)
#   AC18 the evidence budget is tunable (BAR_AGENT_HEAD/TAIL) and the elision stays consistent
#   AC19 the linter bar runs does not force colour into a captured log (F13)
#   AC20 several targets in one run: one block each, rc of the first failure
#   AC21 bar's own records are never evidence, and a short log gets no elision marker
#   AC22 the capture does not leak the outer output format into the target
#   AC23 a bar option written after the target is dropped, not run as a phantom target (and a
#        target whose name begins with a dash stays reachable behind '--')

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

MAX_LINES=20                # contract: default head(8)+tail(4) plus verdict/chain/raw/log/marker
MAX_BYTES=4096              # contract: BAR_AGENT_MAX_BYTES default

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }

echo "=== Testing the agent output contract (Bar.d/agent_rules) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Bar.d"
for module in std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules; do
    ln -s "$REPO_ROOT/Bar.d/$module" "$WORK/Bar.d/$module"
done

cat >"$WORK/Barf" <<'BARF'
# throw-away rulefile for the agent contract tests
rule pass: -- 'echo "all good"'

# fails without printing anything: the block must still be complete
rule silent_fail: -- 'false'

# a target whose clause body calls 'exit' must not take the report down
rule exit3: -- 'echo "boom" >&2; exit 3'

# alternating streams must keep their order in the merged log
rule interleave: -- 'echo out-1; echo err-2 >&2; echo out-3; echo err-4 >&2; exit 1'

# lots of noise, the signal at the very end and without any error-ish keyword
rule needle: -- '
    i=0
    while (( i < 300 )); do
        echo "noise line $i: compiling widget $i"
        i=$((i + 1))
    done
    echo "the needle says: krehcs liah"
    exit 1
'

# a failing dependency (bar prints a FAIL: record for it)
rule leaf_fail: -- 'echo "leaf says no" >&2; false'
rule dep_fail: leaf_fail

# hostile single line (200 kB)
rule hugeline: -- 'printf "%s\n" "$(head -c 200000 /dev/zero | tr "\0" x)"; exit 1'

# 40 lines of 10 kB, none of them keyword-ish
rule longlines: -- '
    i=0
    while (( i < 40 )); do
        head -c 10000 /dev/zero | tr "\0" y
        echo
        i=$((i + 1))
    done
    exit 1
'

# the std 'agent' target (std_rules), hooked by the project
rule agent: pass

# a target that runs bar itself -- the capture must not change how it behaves
rule nested: -- '"$BAR_SELF" check pass'

# a target whose name begins with a dash -- only reachable behind a bare '--'
rule --weird: -- 'echo "weird target ran"'
BARF

OUT=""
RC=0
run_bar() {
    OUT=""
    RC=0
    OUT="$(cd "$WORK" && "$BAR" "$@" 2>/dev/null)" || RC=$?
}
run_bar_err() {
    OUT=""
    RC=0
    OUT="$(cd "$WORK" && "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}
bytes_of() { printf '%s' "$1" | wc -c; }
lines_of() { printf '%s\n' "$1" | wc -l; }
field_of() { sed -n "s#^$1: ##p" <<<"$2"; }
run_bar_to_file() {
    local file="$1"
    shift
    (cd "$WORK" && "$BAR" "$@" >"$file" 2>/dev/null) || true
}

# --------------------------------------------------------------------------------------------
# AC1  success: exactly one line, small, rc 0
# --------------------------------------------------------------------------------------------
run_bar check pass
check "$OUT" "OK pass" "AC1: 'bar check pass' prints exactly 'OK pass'"
check "$RC" "0" "AC1: 'bar check pass' exits 0"
if (( $(bytes_of "$OUT") <= 32 )); then pass "AC1: success is $(bytes_of "$OUT") B (<= 32)"; else fail "AC1: success block is $(bytes_of "$OUT") B"; fi
run_bar verdict pass
check "$OUT" "OK pass" "AC1: 'bar verdict pass' prints exactly 'OK pass'"
run_bar check agent
check "$OUT" "OK agent" "AC1: the std 'agent' target runs under the contract"

# --------------------------------------------------------------------------------------------
# AC2  a failure block is bounded and complete
# --------------------------------------------------------------------------------------------
run_bar check needle
check "$RC" "1" "AC2: 'bar check needle' propagates rc 1"
block_lines="$(lines_of "$OUT")"
block_bytes="$(bytes_of "$OUT")"
if (( block_lines <= MAX_LINES )); then pass "AC2: block is $block_lines lines (<= $MAX_LINES)"; else fail "AC2: block is $block_lines lines (> $MAX_LINES)"; fi
if (( block_bytes <= MAX_BYTES )); then pass "AC2: block is $block_bytes B (<= $MAX_BYTES)"; else fail "AC2: block is $block_bytes B (> $MAX_BYTES)"; fi
check "$(head -1 <<<"$OUT")" "FAIL needle (rc=1)" "AC2: verdict is the first line"
if [[ "$OUT" == *"  chain: "* ]]; then pass "AC2: block carries the chain"; else fail "AC2: block has no chain line"; fi
if [[ "$OUT" == *"  raw: "* ]]; then pass "AC2: block carries the totals"; else fail "AC2: block has no raw line"; fi
if [[ "$OUT" == *$'\n'"log: "* ]]; then pass "AC2: block carries the log path"; else fail "AC2: block has no log line"; fi
if [[ "$OUT" == *"log lines not shown"* ]]; then pass "AC2: the elision is announced with a line range"; else fail "AC2: elision is not announced"; fi
log_path="$(field_of log "$OUT")"
if [[ -f "$log_path" ]]; then pass "AC2: the log exists at $log_path"; else fail "AC2: no log at [$log_path]"; fi

# --------------------------------------------------------------------------------------------
# AC3  the printed totals are exactly what wc reports for the log
# --------------------------------------------------------------------------------------------
read -r wc_lines wc_bytes < <(wc -l -c <"$log_path")
raw_lines="$(sed -n 's#^  raw: \([0-9]*\) lines / \([0-9]*\) B$#\1#p' <<<"$OUT")"
raw_bytes="$(sed -n 's#^  raw: \([0-9]*\) lines / \([0-9]*\) B$#\2#p' <<<"$OUT")"
check "$raw_lines" "$wc_lines" "AC3: printed lines == 'wc -l' ($wc_lines)"
check "$raw_bytes" "$wc_bytes" "AC3: printed bytes == 'wc -c' ($wc_bytes)"
first_evidence="$(sed -n 's#^  *\([0-9]*\)| .*#\1#p' <<<"$OUT" | head -1)"
tail_evidence="$(sed -n 's#^  *\([0-9]*\)| .*#\1#p' <<<"$OUT" | tail -1)"

# --------------------------------------------------------------------------------------------
# AC4  'bar log' is byte identical to the tools it wraps
# --------------------------------------------------------------------------------------------
run_bar_to_file "$WORK/log_full.txt" log needle
if cmp -s "$WORK/log_full.txt" "$log_path"; then pass "AC4: 'bar log needle' == the whole log (byte exact)"; else fail "AC4: 'bar log needle' differs from the log"; fi
run_bar_to_file "$WORK/log_range.txt" log needle "$first_evidence,$wc_lines"
sed -n "${first_evidence},${wc_lines}p" "$log_path" >"$WORK/log_range_want.txt"
if cmp -s "$WORK/log_range.txt" "$WORK/log_range_want.txt"; then pass "AC4: 'bar log needle a,b' == 'sed -n a,bp' (byte exact)"; else fail "AC4: range retrieval differs"; fi
run_bar_to_file "$WORK/log_tail.txt" log needle tail:5
tail -n 5 "$log_path" >"$WORK/log_tail_want.txt"
if cmp -s "$WORK/log_tail.txt" "$WORK/log_tail_want.txt"; then pass "AC4: 'bar log needle tail:5' == 'tail -n 5' (byte exact)"; else fail "AC4: tail retrieval differs"; fi

# --------------------------------------------------------------------------------------------
# AC5  streams are merged in true order
# --------------------------------------------------------------------------------------------
run_bar check interleave
log_path="$(field_of log "$OUT")"
check "$(cat "$log_path")" "$(printf 'out-1\nerr-2\nout-3\nerr-4')" "AC5: merged log keeps the write order"

# --------------------------------------------------------------------------------------------
# AC6  a target failing with no output at all is still complete
# --------------------------------------------------------------------------------------------
run_bar check silent_fail
check "$RC" "1" "AC6: 'bar check silent_fail' exits 1"
check "$(head -1 <<<"$OUT")" "FAIL silent_fail (rc=1)" "AC6: verdict is printed"
if [[ "$OUT" == *"  raw: 0 lines / 0 B"* ]]; then pass "AC6: totals are printed for the empty log"; else fail "AC6: totals missing: [$OUT]"; fi
if [[ "$OUT" == *"no evidence lines"* ]]; then pass "AC6: the empty evidence is stated"; else fail "AC6: empty evidence is not stated"; fi
log_path="$(field_of log "$OUT")"
if [[ -f "$log_path" ]]; then pass "AC6: the (empty) log exists"; else fail "AC6: no log for the silent failure"; fi

# --------------------------------------------------------------------------------------------
# AC7  exit codes
# --------------------------------------------------------------------------------------------
run_bar check exit3
check "$RC" "3" "AC7: a target that exits 3 yields rc 3"
check "$(head -1 <<<"$OUT")" "FAIL exit3 (rc=3)" "AC7: the verdict states the propagated rc"
run_bar check dep_fail
check "$RC" "1" "AC7: a failing dependency yields rc 1"
if [[ "$OUT" == *"chain: dep_fail <- dep_fail: leaf_fail"* ]]; then pass "AC7: the chain names the failing dependency"; else fail "AC7: chain is not [dep_fail <- dep_fail: leaf_fail]: $(field_of chain "$OUT")"; fi
run_bar check
check "$RC" "2" "AC7: 'bar check' without a target is a usage error (rc 2)"
run_bar_err check
if [[ "$OUT" == *"usage: bar check"* ]]; then pass "AC7: the usage error explains itself"; else fail "AC7: no usage message: [$OUT]"; fi
run_bar log this_target_never_ran
check "$RC" "3" "AC7: 'bar log' for an unknown target yields rc 3"
run_bar log needle notarange
check "$RC" "2" "AC7: a malformed range is a usage error"

# --------------------------------------------------------------------------------------------
# AC8  a signal without a keyword is surfaced, or its exact range is named
# --------------------------------------------------------------------------------------------
run_bar check needle
log_path="$(field_of log "$OUT")"
needle_line="$(grep -n 'krehcs' "$log_path" | cut -d: -f1)"
if [[ "$OUT" == *krehcs* ]]; then
    pass "AC8: the keyword-less signal line is printed (L$needle_line)"
else
    elide="$(sed -n 's#^  \.\.\.\.| .* (L\([0-9]*\)-L\([0-9]*\) of .*#\1 \2#p' <<<"$OUT")"
    from="${elide%% *}"
    to="${elide##* }"
    if [[ -n "$elide" ]] && (( needle_line >= from && needle_line <= to )); then
        pass "AC8: the signal is inside the announced range L$from-L$to (L$needle_line)"
    else
        fail "AC8: the signal at L$needle_line is neither printed nor announced"
    fi
fi

# --------------------------------------------------------------------------------------------
# AC9  two runs print the same block (only the log path may differ)
# --------------------------------------------------------------------------------------------
normalize() { sed -e 's#^log: .*#log: <path>#' <<<"$1"; }
run_bar check needle
first_block="$(normalize "$OUT")"
run_bar check needle
second_block="$(normalize "$OUT")"
check "$second_block" "$first_block" "AC9: two runs produce an identical block"

# --------------------------------------------------------------------------------------------
# AC10  the wrapper overhead stays below 150 ms
# --------------------------------------------------------------------------------------------
time_run() {
    local start end
    start="$(date +%s%N)"
    (cd "$WORK" && "$BAR" "$@" >/dev/null 2>&1) || true
    end="$(date +%s%N)"
    echo $(( (end - start) / 1000000 ))
}
raw_best=1000000
check_best=1000000
for _ in 1 2 3; do
    t="$(time_run is_git_repository)"
    (( t < raw_best )) && raw_best="$t"
    t="$(time_run check is_git_repository)"
    (( t < check_best )) && check_best="$t"
done
overhead=$(( check_best - raw_best ))
if (( overhead <= 150 )); then
    pass "AC10: overhead is ${overhead} ms (raw ${raw_best} ms, check ${check_best} ms)"
else
    fail "AC10: overhead is ${overhead} ms (raw ${raw_best} ms, check ${check_best} ms)"
fi

# --------------------------------------------------------------------------------------------
# AC11  block and exit code are identical at every verbosity (F1 regression)
# --------------------------------------------------------------------------------------------
run_bar check needle
reference_block="$(normalize "$OUT")"
reference_rc="$RC"
for level in 0 1 2 3 5; do
    OUT=""
    RC=0
    OUT="$(cd "$WORK" && BAR_VERBOSITY_LEVEL="$level" "$BAR" check needle 2>/dev/null)" || RC=$?
    if [[ "$(normalize "$OUT")" == "$reference_block" && "$RC" == "$reference_rc" ]]; then
        pass "AC11: BAR_VERBOSITY_LEVEL=$level gives the same block and rc ($RC)"
    else
        fail "AC11: BAR_VERBOSITY_LEVEL=$level differs (rc $RC vs $reference_rc)"
    fi
done
OUT=""
RC=0
OUT="$(cd "$WORK" && "$BAR" --quiet check needle 2>/dev/null)" || RC=$?
if [[ "$(normalize "$OUT")" == "$reference_block" && "$RC" == "$reference_rc" ]]; then
    pass "AC11: '--quiet' gives the same block and rc ($RC)"
else
    fail "AC11: '--quiet' differs (rc $RC vs $reference_rc)"
fi

# --------------------------------------------------------------------------------------------
# AC12  a log survives later runs of other targets
# --------------------------------------------------------------------------------------------
run_bar check needle
needle_log="$(field_of log "$OUT")"
run_bar check pass
run_bar check pass
if [[ -L "$WORK/.bar.agent/latest" ]]; then pass "AC12: 'latest' is a symlink"; else fail "AC12: 'latest' is not a symlink"; fi
if [[ ! -e "$WORK/.bar.agent/latest/needle.log" ]]; then pass "AC12: the newest run does not contain the needle log"; else fail "AC12: 'latest' still holds needle.log, the test is not conclusive"; fi
run_bar log needle tail:1
check "$RC" "0" "AC12: 'bar log needle' still resolves after newer runs"
check "$OUT" "the needle says: krehcs liah" "AC12: and returns the right log"
run_bar log pass
check "$RC" "0" "AC12: 'bar log' works for a successful target too"
check "$OUT" "all good" "AC12: the success log holds what the target wrote"

# --------------------------------------------------------------------------------------------
# AC13  the module is shellcheck clean
# --------------------------------------------------------------------------------------------
if command -v shellcheck >/dev/null; then
    if (cd "$REPO_ROOT" && shellcheck -x Bar.d/agent_rules); then
        pass "AC13: 'shellcheck -x Bar.d/agent_rules' is clean"
    else
        fail "AC13: shellcheck reports findings in Bar.d/agent_rules"
    fi
else
    echo "  - AC13: shellcheck not installed, skipped"
fi

# --------------------------------------------------------------------------------------------
# AC14  hostile logs stay bounded, but are retrievable in full
# --------------------------------------------------------------------------------------------
run_bar check hugeline
if (( $(bytes_of "$OUT") <= MAX_BYTES )); then pass "AC14: a 200 kB single line yields a $(bytes_of "$OUT") B block"; else fail "AC14: a 200 kB line yields a $(bytes_of "$OUT") B block"; fi
if [[ "$OUT" == *"<+"*"B>"* ]]; then pass "AC14: the clipped line states how much was left out"; else fail "AC14: the clipped line does not state the clip"; fi
log_path="$(field_of log "$OUT")"
if (( $(wc -c <"$log_path") == 200001 )); then pass "AC14: the log holds all 200001 B"; else fail "AC14: the log is $(wc -c <"$log_path") B"; fi
run_bar_to_file "$WORK/log_huge.txt" log hugeline
if cmp -s "$WORK/log_huge.txt" "$log_path"; then pass "AC14: 'bar log hugeline' returns every byte of the 200 kB line"; else fail "AC14: 'bar log hugeline' lost bytes ($(wc -c <"$WORK/log_huge.txt") B)"; fi
run_bar check longlines
if (( $(bytes_of "$OUT") <= MAX_BYTES )); then pass "AC14: 40 x 10 kB lines yield a $(bytes_of "$OUT") B block"; else fail "AC14: 40 x 10 kB lines yield a $(bytes_of "$OUT") B block"; fi

# --------------------------------------------------------------------------------------------
# AC15  old runs are pruned, the current one never is
# --------------------------------------------------------------------------------------------
gc_dir="$(mktemp -d)"
gc_bar() { (cd "$gc_dir" && BAR_AGENT_KEEP=3 "$BAR" "$@" >/dev/null 2>&1) || true; }
mkdir -p "$gc_dir/Bar.d"
for module in std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules; do
    ln -s "$REPO_ROOT/Bar.d/$module" "$gc_dir/Bar.d/$module"
done
printf "rule pass: -- 'true'\n" >"$gc_dir/Barf"
for _ in 1 2 3 4 5 6; do gc_bar check pass; done
kept="$(find "$gc_dir/.bar.agent" -mindepth 1 -maxdepth 1 -type d | wc -l)"
check "$kept" "3" "AC15: BAR_AGENT_KEEP=3 keeps 3 runs"
if [[ -d "$gc_dir/.bar.agent/latest" ]]; then pass "AC15: 'latest' resolves to a live run"; else fail "AC15: 'latest' is dangling"; fi
if [[ -f "$gc_dir/.bar.agent/latest/pass.log" ]]; then pass "AC15: the newest run kept its log"; else fail "AC15: the newest run lost its log"; fi
rm -rf "$gc_dir"

# --------------------------------------------------------------------------------------------
# AC16  --json emits one valid object per run, with the numbers of the text block
# --------------------------------------------------------------------------------------------
run_bar --json check needle
check "$RC" "1" "AC16: '--json check needle' still exits 1"
run_bar --json check needle
log_path="$(jq -r '.targets[0].log' <<<"$OUT" 2>/dev/null || true)"
if command -v jq >/dev/null; then
    if jq -e '.bar_agent == 1 and .ok == false and .rc == 1' <<<"$OUT" >/dev/null 2>&1; then
        pass "AC16: the object reports bar_agent/ok/rc"
    else
        fail "AC16: unexpected object: [$OUT]"
    fi
    read -r wc_lines wc_bytes < <(wc -l -c <"$log_path")
    check "$(jq -r '.targets[0].lines' <<<"$OUT")" "$wc_lines" "AC16: .targets[0].lines == 'wc -l'"
    check "$(jq -r '.targets[0].bytes' <<<"$OUT")" "$wc_bytes" "AC16: .targets[0].bytes == 'wc -c'"
    check "$(jq -r '.targets[0].target' <<<"$OUT")" "needle" "AC16: .targets[0].target is the target"
    if (( $(jq -r '.targets[0].evidence | length' <<<"$OUT") > 0 )); then pass "AC16: evidence is included"; else fail "AC16: no evidence in the object"; fi
    if [[ "$(jq -r '.targets[0].elided.from' <<<"$OUT")" != "null" ]]; then pass "AC16: the elided range is included"; else fail "AC16: no elided range"; fi
    run_bar --json check pass
    if jq -e '.ok == true and .rc == 0 and .targets[0].ok == true' <<<"$OUT" >/dev/null 2>&1; then
        pass "AC16: a passing run reports ok"
    else
        fail "AC16: a passing run does not report ok: [$OUT]"
    fi
else
    if [[ "$OUT" == '{"bar_agent":1,"ok":false,"rc":1,"targets":[{"target":"needle"'* ]]; then
        pass "AC16: the object has the expected shape (jq not installed, shape only)"
    else
        fail "AC16: unexpected object: [$OUT]"
    fi
fi

# --------------------------------------------------------------------------------------------
# AC17  evidence line numbers address the log
# --------------------------------------------------------------------------------------------
run_bar check needle
log_path="$(field_of log "$OUT")"
evidence_line="$(sed -n 's#^  *\([0-9]*\)| .*#\1#p' <<<"$OUT" | head -1)"
evidence_text="$(sed -n "s#^  *${evidence_line}| ##p" <<<"$OUT")"
check "$(sed -n "${evidence_line}p" "$log_path")" "$evidence_text" "AC17: L$evidence_line in the block is L$evidence_line in the log"
tail_line="$(sed -n 's#^  *\([0-9]*\)| .*#\1#p' <<<"$OUT" | tail -1)"
tail_text="$(sed -n "s#^  *${tail_line}| ##p" <<<"$OUT")"
check "$(sed -n "${tail_line}p" "$log_path")" "$tail_text" "AC17: L$tail_line in the block is L$tail_line in the log"

# --------------------------------------------------------------------------------------------
# AC18  the evidence budget is tunable and the elision stays consistent
# --------------------------------------------------------------------------------------------
OUT=""
RC=0
OUT="$(cd "$WORK" && BAR_AGENT_HEAD=2 BAR_AGENT_TAIL=1 "$BAR" check needle 2>/dev/null)" || RC=$?
evidence_count="$(grep -c '^  *[0-9]*| ' <<<"$OUT")"
check "$evidence_count" "3" "AC18: BAR_AGENT_HEAD=2 BAR_AGENT_TAIL=1 prints 3 evidence lines"
if (( $(bytes_of "$OUT") < $(bytes_of "$first_block") )); then
    pass "AC18: the smaller budget yields a smaller block ($(bytes_of "$OUT") B < $(bytes_of "$first_block") B)"
else
    fail "AC18: the smaller budget did not shrink the block"
fi

# --------------------------------------------------------------------------------------------
# AC19  the linter bar runs does not force colour into a captured log (F13)
# --------------------------------------------------------------------------------------------
if command -v shellcheck >/dev/null; then
    if grep -q -- '--color=auto' "$REPO_ROOT/Bar.d/shellcheck"; then
        pass "AC19: Bar.d/shellcheck asks shellcheck for 'auto' colour"
    else
        fail "AC19: Bar.d/shellcheck does not use '--color=auto'"
    fi
    printf '#!/bin/sh\nfor x in $(ls); do echo $x; done\n' >"$WORK/badscript.sh"
    auto_out="$(shellcheck --color=auto -- "$WORK/badscript.sh" 2>/dev/null || true)"
    bare_out="$(shellcheck --color -- "$WORK/badscript.sh" 2>/dev/null || true)"
    if [[ "$auto_out" == *$'\033'* ]]; then
        fail "AC19: '--color=auto' still writes escape sequences into a pipe"
    else
        pass "AC19: '--color=auto' writes plain text when captured"
    fi
    if [[ "$bare_out" == *$'\033'* ]]; then
        pass "AC19: (control) a bare '--color' does force escape sequences into a pipe"
    else
        fail "AC19: (control) a bare '--color' no longer forces colour, the F13 note needs an update"
    fi
else
    echo "  - AC19: shellcheck not installed, skipped"
fi

# --------------------------------------------------------------------------------------------
# AC20  several targets in one run: one block each, rc of the first failure
# --------------------------------------------------------------------------------------------
run_bar check pass needle
check "$RC" "1" "AC20: one failing target in two yields rc 1"
check "$(sed -n 1p <<<"$OUT")" "OK pass" "AC20: the passing target keeps its one line"
check "$(sed -n 2p <<<"$OUT")" "FAIL needle (rc=1)" "AC20: the failing target follows in order"
run_bar check needle pass
check "$RC" "1" "AC20: the target order does not change the rc"
check "$(sed -n 1p <<<"$OUT")" "FAIL needle (rc=1)" "AC20: the failing target comes first here"
check "$(tail -1 <<<"$OUT")" "OK pass" "AC20: the passing target is still reported"
run_bar verdict needle pass
check "$RC" "1" "AC20: verdict propagates the first failure too"
check "$(sed -n 1p <<<"$OUT")" "FAIL needle (rc=1)" "AC20: verdict prints the failing target first"
check "$(sed -n 3p <<<"$OUT")" "OK pass" "AC20: verdict prints one line per target"

# --------------------------------------------------------------------------------------------
# AC21  bar's own records are never evidence, short logs get no elision marker
# --------------------------------------------------------------------------------------------
run_bar check dep_fail
if [[ "$OUT" != *"FAIL: dep_fail: leaf_fail"* ]]; then
    pass "AC21: bar's own FAIL: record is not printed as evidence"
else
    fail "AC21: bar's own record leaked into the evidence"
fi
if [[ "$OUT" == *"leaf says no"* ]]; then
    pass "AC21: the tool's own line is the evidence"
else
    fail "AC21: the tool's line is missing from the block"
fi
if [[ "$OUT" != *"log lines not shown"* ]]; then
    pass "AC21: a short log is shown without an elision marker"
else
    fail "AC21: an elision was announced although nothing was elided"
fi

# --------------------------------------------------------------------------------------------
# AC22  the capture does not leak the outer output format into the target
# --------------------------------------------------------------------------------------------
run_bar --json check nested
check "$RC" "0" "AC22: a target that runs bar itself still passes under --json"
nested_log="$(sed -n 's#.*"log":"\([^"]*\)".*#\1#p' <<<"$OUT")"
if [[ -n "$nested_log" && -f "$nested_log" ]]; then
    pass "AC22: the JSON names the nested target's log"
else
    fail "AC22: no nested log in [$OUT]"
fi
if [[ "$(cat "$nested_log")" != *'"bar_agent"'* ]]; then
    pass "AC22: BAR_AGENT_JSON did not leak into the target"
else
    fail "AC22: the target inherited the JSON output format"
fi
if [[ "$(cat "$nested_log")" == *"OK pass"* ]]; then
    pass "AC22: the nested bar printed its terse text into the log"
else
    fail "AC22: unexpected nested log: [$(cat "$nested_log")]"
fi

# --------------------------------------------------------------------------------------------
# AC23  a bar option after the target is not a target
# --------------------------------------------------------------------------------------------
# rule_lib hands everything after the rule name to the rule, so an option written after the target
# used to arrive at the contract as just another target: 'bar check agent --quiet' printed
# 'OK agent' *and* a phantom 'OK --quiet' -- a measured-looking line for something that was never
# run as a target.  Dashed arguments are dropped now, and announced from verbosity 3 on.
for opt in --quiet -q --json --definitely-not-a-bar-option; do
    run_bar check agent "$opt"
    check "$RC" "0" "AC23: 'check agent $opt' exits 0"
    check "$OUT" "OK agent" "AC23: 'check agent $opt' reports the real target only"
done
run_bar verdict agent --quiet
check "$RC" "0" "AC23: 'verdict agent --quiet' exits 0"
check "$OUT" "OK agent" "AC23: 'verdict agent --quiet' is one line for the one real target"
run_bar verdict agent -q
check "$OUT" "OK agent" "AC23: 'verdict agent -q' is one line for the one real target"
if [[ "$(sed -n 's#.*\"ok\":true.*#json#p' <<<"$OUT")" != json ]]; then
    pass "AC23: '--json' after the target does not switch the format (options precede the rule)"
else
    fail "AC23: '--json' after the target was honoured, the test is not conclusive"
fi

# a dropped option must not swallow a failure, duplicate a target or reorder the verdicts
run_bar verdict pass needle --quiet
check "$RC" "1" "AC23: a dropped option keeps the rc of the failing target"
check "$(lines_of "$OUT")" "3" "AC23: two targets stay two verdicts plus the failing log path"
check "$(sed -n 1p <<<"$OUT")" "OK pass" "AC23: the passing target keeps its position"
check "$(sed -n 2p <<<"$OUT")" "FAIL needle (rc=1)" "AC23: the failing target keeps its position"
run_bar check needle --quiet
check "$RC" "1" "AC23: 'check needle --quiet' still exits 1"
check "$(grep -c '^FAIL needle (rc=1)$' <<<"$OUT")" "1" "AC23: exactly one failure block is printed"
if [[ "$OUT" != "OK "* ]]; then
    pass "AC23: the block carries no phantom OK line"
else
    fail "AC23: a phantom OK line survived: [$OUT]"
fi

# dropping is not the same as swallowing: from verbosity 3 the argument is named on stderr
noted="$(cd "$WORK" && BAR_VERBOSITY_LEVEL=3 "$BAR" verdict agent --quiet 2>&1 >/dev/null | grep -- '--quiet' || true)"
if [[ "$noted" == *"not a target"* ]]; then
    pass "AC23: verbosity 3 names the dropped argument"
else
    fail "AC23: the dropped argument is not announced at verbosity 3"
fi

# a target whose *name* begins with a dash stays reachable behind a bare '--'
run_bar check -- --weird
check "$RC" "0" "AC23: 'bar check -- --weird' runs the dashed target"
check "$OUT" "OK --weird" "AC23: the dashed target is reported as the target it is"
run_bar log --weird
check "$OUT" "weird target ran" "AC23: and it really ran (its log holds its output)"
run_bar check -- --weird pass
check "$RC" "0" "AC23: '--' makes every following argument a target again"
check "$OUT" "$(printf 'OK --weird\nOK pass')" "AC23: both targets are reported"

echo
if (( failures == 0 )); then
    echo "=== All agent output contract tests passed ==="
else
    echo "=== $failures agent output contract assertion(s) FAILED ==="
    exit 1
fi