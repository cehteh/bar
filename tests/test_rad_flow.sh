#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the Radicle/source-work flow helpers (Bar.d/rad).
#
# Everything runs against throw-away repositories, a throw-away source-work root and a stub fact
# tool, so nothing here depends on this host's radicle node, on '~/hermes_src' or on the real
# 'tools/radicle_triage/triage-facts'.  Covered:
#
#   AC1  rad_trust: a delegate is 'trusted', exit 0, one line of key=value facts
#   AC2  rad_trust: below the threshold is 'untrusted', exit 1
#   AC3  rad_trust: --threshold reaches the fact tool, an unresolvable author is exit 2
#   AC4  rad_trust: usage errors are exit 2 with stdout empty, a missing tool too
#   AC5  rad_trust: --json is one object which carries the same numbers as the line
#   AC6  rad_topic: creates '<class>-<description>' on the branch of the same name, exit 0
#   AC7  rad_topic: the main checkout stays clean, '.worktrees/' is excluded, base is the trunk
#   AC8  rad_topic: the description is slugified, a name over 40 characters is refused
#   AC9  rad_topic: an unknown class is refused and the class list is complete
#   AC10 rad_topic: an existing tree or branch is refused, nothing is half-made
#   AC11 rad_topic: --dry-run and --json answer without creating anything
#   AC12 rad_topic: the clone is found from inside a topic tree and with --root
#   AC13 rad_topic: the base is the trunk, a trunk behind upstream is refused
#   AC14 the helpers are registered (index, guard) and the module is documented by 'bar help'
#   AC15 the output is deterministic, ANSI-free, and diagnostics stay off stdout
#
# usage: tests/test_rad_flow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar and the helpers under test ('git' is read for
# the branch classes, 'agent_rules' supplies the '--json' rule of 'bar --json <rule>')
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git git_lib json_lib agent_rules helpers_rules radicle_lib rad"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }
field() { printf '%s' "$1" | LC_ALL=C tr ' ' '\n' | LC_ALL=C sed -n "s/^$2=//p" | head -1; }
first() { printf '%s' "$1" | LC_ALL=C awk '{ print $1 }'; }
second() { printf '%s' "$1" | LC_ALL=C awk '{ print $2 }'; }
assert_absent() { # <dir> <name> <what>
    if [[ ! -e "$1/$2" ]]; then pass "$3"; else fail "$3 ([$2] exists)"; fi
}

echo "=== Testing the Radicle/source-work helpers (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT=""
ERR=""
RC=0
run_bar() { # <dir> <args..> - stdout and rc
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && "$BAR" "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}
run_bar_env() { # <dir> <VAR=value>.. -- <args..> - stdout and rc with environment assignments
    local dir="$1"
    shift
    local -a envs=()
    while [[ "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && env "${envs[@]}" "$BAR" "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}

# -------------------------------------------------------------------------------------------------
# fixtures
# -------------------------------------------------------------------------------------------------

# a stub for 'tools/radicle_triage/triage-facts': it records its arguments and prints $STUB_JSON
mkstub() { # <file>
    cat >"$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"${STUB_ARGS:-/dev/null}"
printf '%s' "${STUB_JSON-}"
exit "${STUB_RC:-0}"
STUB
    chmod +x "$1"
}

# <dir> - a directory with the modules, but no repository: bar resolves the rules, git does not
mkbucket() {
    local dir="$1"
    mkdir -p "$dir/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$dir/Bar.d/$module"
    done
    cat >"$dir/Barf" <<'BARF'
rule MAIN: -- true
BARF
}

trusted_json() { # <delegate> <authored> <threshold>
    printf '{"rid":"rad:zTEST","threshold":%s,"delegates":[],"author":{"alias":"cehteh","did":"did:key:zTEST","is_delegate":%s,"total_authored":%s},"contributor":%s,"reason":"%s"}' \
        "$3" "$1" "$2" "$1" "stub verdict"
}

# <dir> - a throw-away clone of 'proj': bar, the modules, a project Barf, one commit
mkclone() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.name "Bar Test"
    git -C "$dir" config user.email "bar-test@example.com"
    printf 'one\n' >"$dir/file"
    mkdir -p "$dir/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$dir/Bar.d/$module"
    done
    cat >"$dir/Barf" <<'BARF'
rule MAIN: -- true
BARF
    git -C "$dir" add file Barf Bar.d
    git -C "$dir" commit -qm first
}

# <root> - a clone 'proj' whose 'rad' remote is a bare repository, and an upstream commit which is
# only in the bare repository ('refs/remotes/rad/main' of the clone is behind on purpose)
mkclone_with_rad() {
    local root="$1"
    mkdir -p "$root"
    git init -q --bare "$root/upstream.git"
    mkclone "$root/proj"
    git -C "$root/proj" remote add rad "$root/upstream.git"
    git -C "$root/proj" push -q rad main
    git -C "$root/proj" fetch -q rad
    git clone -q "$root/upstream.git" "$root/other"
    git -C "$root/other" config user.name "Bar Test"
    git -C "$root/other" config user.email "bar-test@example.com"
    printf 'upstream\n' >"$root/other/upstream-file"
    git -C "$root/other" add upstream-file
    git -C "$root/other" commit -qm "upstream moves on"
    git -C "$root/other" push -q origin main
}

STUB="$WORK/triage-facts"
mkstub "$STUB"
TRUST="$WORK/trust-proj"
mkclone "$TRUST"

# -------------------------------------------------------------------------------------------------
# AC1..AC5 - rad_trust
# -------------------------------------------------------------------------------------------------

echo "--- AC1 a delegate is trusted ---"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=$WORK/args" \
    "STUB_JSON=$(trusted_json true 396 10)" -- rad_trust --repo rad:zTEST --author cehteh
check "$RC" "0" "exit 0 for a delegate"
contains "$OUT" "trusted author=cehteh" "the verdict and the author are on the line"
contains "$OUT" "delegate=yes" "the delegate fact is on the line"
contains "$OUT" "authored=396" "the authored count is on the line"
contains "$OUT" "threshold=10" "the threshold is on the line"
contains "$OUT" "repo=rad:zTEST" "the repository is on the line"
check "$(printf '%s' "$OUT" | wc -l)" "0" "one line, no trailing blank"

echo "--- AC2 below the threshold is untrusted ---"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=$WORK/args" \
    "STUB_JSON=$(trusted_json false 3 10)" -- rad_trust --repo rad:zTEST --author someone
check "$RC" "1" "exit 1 for an outsider"
contains "$OUT" "untrusted author=cehteh" "the verdict carries the alias the tool resolved"
contains "$OUT" "delegate=no" "the delegate fact is 'no'"

echo "--- AC3 the threshold reaches the tool, an unknown author is not 'untrusted' ---"
: >"$WORK/args"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=$WORK/args" \
    "STUB_JSON=$(trusted_json true 4 4)" -- rad_trust --repo rad:zTEST --author x --threshold 4
check "$RC" "0" "exit 0 at the threshold"
contains "$(cat "$WORK/args")" "--threshold 4" "the threshold is passed to the fact tool"
contains "$OUT" "threshold=4" "the threshold of the answer is the one asked for"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=/dev/null" \
    'STUB_JSON={"rid":"rad:zTEST","threshold":10,"author":null,"contributor":null,"reason":"","error":"cannot resolve author x"}' \
    -- rad_trust --repo rad:zTEST --author x
check "$RC" "2" "exit 2 when the author cannot be resolved"
contains "$OUT" "unknown author=-" "the verdict is 'unknown', never 'untrusted'"
contains "$OUT" "cannot resolve author x" "the reason of the tool is carried"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=/dev/null" "STUB_RC=2" \
    'STUB_JSON={"rid":"rad:zTEST","threshold":10,"author":null,"contributor":null,"error":"cannot resolve author x"}' \
    -- rad_trust --repo rad:zTEST --author x
check "$RC" "2" "a non-zero tool exit is exit 2, not a crash"
contains "$OUT" "cannot resolve author x" "the reason survives a non-zero tool exit"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=/dev/null" "STUB_RC=3" "STUB_JSON=" \
    -- rad_trust --repo rad:zTEST --author x
check "$RC" "2" "an empty answer is exit 2"
check "$OUT" "" "stdout stays empty"
contains "$ERR" "gave no answer" "the empty answer is named"
contains "$RC-$(printf '%s' "$OUT" | wc -l)" "2-0" "still one line"

echo "--- AC4 usage errors and a missing tool ---"
run_bar "$TRUST" rad_trust
check "$RC" "2" "no arguments is a usage error"
check "$OUT" "" "stdout stays empty"
contains "$ERR" "usage: rad_trust" "the usage goes to stderr"
run_bar "$TRUST" rad_trust --help
check "$RC" "0" "'--help' is not an error"
contains "$OUT" "usage: rad_trust" "and the usage is the answer, on stdout"
run_bar "$TRUST" rad_topic --help
check "$RC" "0" "and 'rad_topic --help' answers outside a repository too"
contains "$OUT" "usage: rad_topic" "with its own usage"
run_bar "$TRUST" rad_trust --repo rad:zTEST --author x --threshold nope
check "$RC" "2" "a non-numeric threshold is a usage error"
run_bar "$TRUST" rad_trust --repo rad:zTEST --author x --frobnicate
check "$RC" "2" "an unknown argument is a usage error"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$WORK/nope" -- rad_trust --repo rad:zTEST --author x
check "$RC" "2" "a missing fact tool is exit 2"
check "$OUT" "" "stdout stays empty"
contains "$ERR" "not executable" "the missing tool is named"

echo "--- AC5 --json carries the same numbers ---"
run_bar_env "$TRUST" "RAD_TRIAGE_FACTS=$STUB" "STUB_ARGS=/dev/null" \
    "STUB_JSON=$(trusted_json true 396 10)" -- rad_trust --repo rad:zTEST --author cehteh --json
check "$RC" "0" "exit 0 in the machine form too"
check "$(printf '%s' "$OUT" | jq -r '.bar_rad')" "1" "the object is marked"
check "$(printf '%s' "$OUT" | jq -r '.verdict')" "trusted" "the verdict is in the object"
check "$(printf '%s' "$OUT" | jq -r '.author.total_authored')" "396" "the authored count is in the object"
check "$(printf '%s' "$OUT" | jq -r '.threshold')" "10" "the threshold is in the object"

# -------------------------------------------------------------------------------------------------
# AC6..AC13 - rad_topic
# -------------------------------------------------------------------------------------------------

echo "--- AC6/AC7 the topic tree, its name, the clean checkout and the base ---"
ROOT="$WORK/src"
mkclone "$ROOT/proj"
CLONE="$ROOT/proj"
run_bar "$CLONE" rad_topic fix "crash on empty config"
check "$RC" "0" "exit 0 after creating the tree"
check "$(first "$OUT")" "$CLONE/.worktrees/fix-crash-on-empty-config" "the tree is the minted name"
check "$(second "$OUT")" "fix-crash-on-empty-config" "the branch carries the name"
check "$(field "$OUT" base)" "main" "the base is the trunk"
check "$(git -C "$CLONE" rev-parse --verify --quiet --short refs/heads/fix-crash-on-empty-config)" \
    "$(git -C "$CLONE" rev-parse --short HEAD)" "the branch exists at the trunk tip"
check "$(git -C "$CLONE/.worktrees/fix-crash-on-empty-config" log -1 --format=%h)" "$(git -C "$CLONE" rev-parse --short HEAD)" "the tree starts at the trunk tip"
check "$(git -C "$CLONE" status --porcelain)" "" "the main checkout stays clean"
contains "$(cat "$CLONE/.git/info/exclude")" ".worktrees/" "'.worktrees/' is kept out"

echo "--- AC8 slugified descriptions, the 40 character limit ---"
run_bar "$CLONE" rad_topic feature "Add the FOO_bar thing!"
check "$RC" "0" "exit 0 for a description which needs slugifying"
check "$(first "$OUT")" "$CLONE/.worktrees/feature-add-the-foo_bar-thing" "uppercase, space and '!' became a slug"
LONG="this description is far too long for forty characters indeed it is"
run_bar "$CLONE" rad_topic fix "$LONG"
check "$RC" "1" "a name over 40 characters is refused"
check "$OUT" "" "nothing is printed on stdout"
contains "$ERR" "at most 40" "the limit is named"
check "$(ls "$CLONE/.worktrees" | wc -l)" "2" "no third tree was made"

echo "--- AC9 the class vocabulary comes from the git module ---"
run_bar "$CLONE" rad_topic ftx "not a class"
check "$RC" "2" "an unknown class is a usage error"
contains "$ERR" "unknown class 'ftx'" "the class is named"
for class in bugfix- feature- fix- hotfix- improvement- doc- wip- experiment- release- devel-; do
    contains "$ERR" "$class" "the class '$class' is offered"
done

echo "--- AC10 collisions are refused, nothing half-made ---"
run_bar "$CLONE" rad_topic fix "crash on empty config"
check "$RC" "1" "an existing tree is refused"
contains "$ERR" "already exists" "the refusal names the tree"
git -C "$CLONE" branch fix-orphan-branch
run_bar "$CLONE" rad_topic fix "orphan branch" --no-fetch
check "$RC" "1" "an existing branch is refused"
contains "$ERR" "the branch already exists" "the refusal names the branch"
assert_absent "$CLONE/.worktrees" "fix-orphan-branch" "no tree was made for it"

echo "--- AC11 --dry-run and --json answer without creating anything ---"
run_bar "$CLONE" rad_topic improvement "make the pruner cheap" --dry-run
check "$RC" "0" "exit 0 in dry-run"
check "$(first "$OUT")" "$CLONE/.worktrees/improvement-make-the-pruner-cheap" "dry-run names the tree"
assert_absent "$CLONE/.worktrees" "improvement-make-the-pruner-cheap" "dry-run created no tree"
run_bar "$CLONE" rad_topic improvement "make the pruner cheap" --json
check "$RC" "0" "exit 0 in the machine form"
check "$(printf '%s' "$OUT" | jq -r '.action')" "topic" "the object names the action"
check "$(printf '%s' "$OUT" | jq -r '.name')" "improvement-make-the-pruner-cheap" "the object carries the name"
check "$(printf '%s' "$OUT" | jq -r '.path')" "$CLONE/.worktrees/improvement-make-the-pruner-cheap" "the object carries the path"
check "$(printf '%s' "$OUT" | jq -r '.branch')" "improvement-make-the-pruner-cheap" "the object carries the branch"

echo "--- AC12 the clone is found from inside a topic and with --root ---"
run_bar "$CLONE/.worktrees/fix-crash-on-empty-config" rad_topic fix "second attempt"
check "$RC" "0" "exit 0 when called from inside a topic tree"
check "$(first "$OUT")" "$CLONE/.worktrees/fix-second-attempt" "the tree lands in the clone, not in the topic"
run_bar "$TRUST" rad_topic doc "explain the class rule" --root "$CLONE"
check "$RC" "0" "exit 0 with --root"
check "$(first "$OUT")" "$CLONE/.worktrees/doc-explain-the-class-rule" "the tree lands in the named clone"
mkbucket "$WORK/bucket"
run_bar "$WORK/bucket" rad_topic doc "elsewhere"
check "$RC" "2" "outside a repository it is a usage error"
contains "$ERR" "not inside a git repository" "the reason is named"

echo "--- AC13 the base is the trunk, a trunk behind upstream is refused ---"
mkclone_with_rad "$WORK/rad-src"
RCLONE="$WORK/rad-src/proj"
check "$(git -C "$RCLONE" log --format=%s refs/remotes/rad/main | head -1)" "first" "the remote ref is stale"
run_bar "$RCLONE" rad_topic fix "refused while the trunk is behind"
check "$RC" "1" "a trunk behind upstream is refused"
contains "$ERR" "behind rad/main" "the refusal names the remote tip"
check "$(ls "$RCLONE/.worktrees" 2>/dev/null | wc -l)" "0" "nothing was created for the refusal"
run_bar "$RCLONE" rad_topic fix "explicit stale base" --base "$(git -C "$RCLONE" rev-parse --short HEAD)"
check "$RC" "0" "--base overrides the refusal"
check "$(field "$OUT" base)" "$(git -C "$RCLONE" rev-parse --short HEAD)" "the named base is used"
run_bar "$RCLONE" rad_topic fix "unseen relation" --no-fetch
check "$RC" "0" "--no-fetch does not claim to know the relation"
check "$(field "$OUT" base)" "main" "--no-fetch branches off the trunk"
git -C "$RCLONE" merge -q --ff-only rad/main
printf 'local\n' >"$RCLONE/local-file"
git -C "$RCLONE" add local-file
git -C "$RCLONE" commit -qm "local only work"
run_bar "$RCLONE" rad_topic feature "based on the trunk"
check "$RC" "0" "exit 0 once the trunk is current"
check "$(field "$OUT" base)" "main" "the base is the trunk, not the remote tip"
check "$(git -C "$RCLONE/.worktrees/feature-based-on-the-trunk" log --format=%s | head -1)" \
    "local only work" "the tree starts at the trunk tip"
check "$(git -C "$RCLONE/.worktrees/feature-based-on-the-trunk" log --format=%s | grep -c 'upstream moves on')" \
    "1" "the trunk carries the upstream commit the tree inherited"
run_bar "$RCLONE" rad_topic fix "reports the fetch" --json --dry-run
check "$(printf '%s' "$OUT" | jq -r '.fetched')" "true" "the machine form reports the fetch"

# -------------------------------------------------------------------------------------------------
# AC14/AC15 - registration and the output contract
# -------------------------------------------------------------------------------------------------

echo "--- AC14 the repertoire knows both helpers ---"
run_bar "$CLONE" helpers
check "$RC" "0" "'bar helpers' answers"
contains "$OUT" "rad_trust" "the trust helper is registered"
contains "$OUT" "rad_topic" "the topic helper is registered"
contains "$OUT" "whether the author of an incoming" "the purpose of the trust helper is spelled out"
run_bar "$CLONE" check helpers_check
check "$OUT" "OK helpers_check" "the registration guard is clean"
run_bar "$CLONE" helpers --json
check "$(printf '%s' "$OUT" | jq -r '[.helpers[].name] | map(select(. == "rad_trust" or . == "rad_topic")) | join(",")')" \
    "rad_topic,rad_trust" "both are in the machine index"
run_bar "$REPO_ROOT" help
contains "$OUT" "rad - The radicle domain of bar" "the module documentation reaches 'bar help'"

echo "--- AC15 deterministic, ANSI-free, stdout is the answer ---"
run_bar "$CLONE" rad_topic fix "determinism" --dry-run
FIRST="$OUT"
run_bar "$CLONE" rad_topic fix "determinism" --dry-run
check "$OUT" "$FIRST" "the same question answers the same way"
absent "$FIRST" "$(printf '\033')" "no ANSI in the answer"

echo
if (( failures )); then
    echo "FAIL: $failures check(s) failed"
    exit 1
fi
echo "OK: all checks passed"
