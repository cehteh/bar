#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for 'git_search' (Bar.d/git_lib).
#
#   AC1  the default is presence: every commit whose tree holds a blob with that object id,
#        whatever its path, newest commit first
#   AC2  the state options are the edges of the presence runs -- '--added' and '--last' the two
#        present ends, '--removed' and '--absent' the absent commits beside them, which are the
#        only two that widen the set
#   AC3  the destination filters narrow by path: '--exact' at that path, '--name' at that name
#        anywhere, '--dir' in that directory, '--match' by glob; the path is the caller-side
#        prefix of the project which holds <file> plus its name
#   AC4  '--head', '--tail' and '--filter' slice the result, '--head' alone stopping the walk early
#   AC5  '--format' is git's own format with '%H ' prepended and cut off again, '--json' an array
#        of commit, date, committer and subject, and the default one line per commit
#   AC6  '--check' prints nothing and answers only whether a commit is left
#   AC7  a bad argument is a usage error (exit 2); a blob which is not in the object store at all
#        is an error (exit 1), not an empty list
#
# usage: tests/test_git_search.sh

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
# run in <dir>: bar git_search ... , stdout only (bar's own verdict goes to stderr)
run() {
    local dir=$1
    shift
    RC=0
    OUT="$(cd "$dir" && "$BAR" git_search "$@" 2>"$WORKDIR/err")" || RC=$?
}
# the default output of a commit: id, committer date and committer, one per line
def() { local c; for c in "$@"; do git -C "$FIX" log -1 --format='%H %ci %cn' "$c"; done; }

# <dir> - a throw-away project: bar's modules and an empty Barf, so bar runs there
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git git_lib json_lib agent_rules helpers_rules usage help"
mkproject() {
    local dir=$1 module
    mkdir -p "$dir/Bar.d"
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$dir/Bar.d/$module"
    done
    printf 'fixture: -- true\n' >"$dir/Barf"
}

# --- fixture: a file which is added, kept, removed, re-added at another path, then changed
FIX="$WORKDIR/cycle"
mkdir -p "$FIX"
mkproject "$FIX"
(
    cd "$FIX"
    git init -q
    git config user.name Test; git config user.email test@example.com
    export GIT_AUTHOR_DATE='2026-01-01T00:00:00+0000' GIT_COMMITTER_DATE='2026-01-01T00:00:00+0000'
    mkdir -p a
    printf 'SAME\n' > a/x.txt
    git add -A; git commit -qm 'c1 add a/x.txt'
    printf 'other\n' > o.txt
    git add -A; git commit -qm 'c2 touch only o.txt'
    git rm -q a/x.txt; git commit -qm 'c3 remove a/x.txt'
    mkdir -p b; printf 'SAME\n' > b/y.txt
    git add -A; git commit -qm 'c4 re-add as b/y.txt'
    printf 'changed\n' > b/y.txt
    git add -A; git commit -qm 'c5 touch again' -m 'the b/y blob is gone now'
)
c1=$(git -C "$FIX" rev-parse HEAD~4)
c2=$(git -C "$FIX" rev-parse HEAD~3)
c3=$(git -C "$FIX" rev-parse HEAD~2)
c4=$(git -C "$FIX" rev-parse HEAD~1)
c5=$(git -C "$FIX" rev-parse HEAD)
# needles: the content c1 added is gone from the worktree, so lay copies down (untracked, so the
# history is untouched) -- inside the project for the prefix, outside it for the no-project case
mkdir -p "$FIX/a" "$FIX/b"
printf 'SAME\n' >"$FIX/a/x.txt"
printf 'SAME\n' >"$FIX/b/y.txt"
printf 'SAME\n' >"$FIX/x.txt"
printf 'SAME\n' >"$WORKDIR/needle.txt"
NEEDLE="$FIX/a/x.txt"

echo "AC1 presence is the object id, not the path"
run "$FIX" "$NEEDLE"
check "$RC" 0 "'git_search <file>' succeeds"
check "$OUT" "$(def "$c4" "$c2" "$c1")" "the three commits holding the blob, newest first"
echo

echo "AC2 the state options are the run edges"
run "$FIX" "$NEEDLE" --added
check "$OUT" "$(def "$c4" "$c1")" "'--added' is the start of each run"
run "$FIX" "$NEEDLE" --last
check "$OUT" "$(def "$c4" "$c2")" "'--last' is the end of each run"
run "$FIX" "$NEEDLE" --removed
check "$OUT" "$(def "$c5" "$c3")" "'--removed' is the commit after a run"
run "$FIX" "$NEEDLE" --absent
check "$OUT" "$(def "$c3")" "'--absent' is the commit before a run"
echo

echo "AC3 the destination filters narrow by path"
run "$FIX" "$FIX/a/x.txt" --exact
check "$OUT" "$(def "$c2" "$c1")" "'--exact' finds the blob at that path"
run "$FIX" "$FIX/b/y.txt" --exact
check "$OUT" "$(def "$c4")" "'--exact' follows the path, not the content"
run "$FIX" "$WORKDIR/needle.txt" --exact
check "$OUT" "" "'--exact' outside any project matches no path"
run "$FIX" "$FIX/x.txt" --name
check "$OUT" "$(def "$c2" "$c1")" "'--name' finds the name at any depth"
run "$FIX" "$FIX/a/x.txt" --dir
check "$OUT" "$(def "$c2" "$c1")" "'--dir' finds it anywhere in that directory"
run "$FIX" "$FIX/a/x.txt" --match 'b/*'
check "$OUT" "$(def "$c4")" "'--match' takes a glob over the whole path"
# the caller-side prefix: from inside a/, the bare name is prefixed with 'a/'
run "$FIX/a" x.txt --exact
check "$OUT" "$(def "$c2" "$c1")" "the path is prefixed from the caller's project root"
echo

echo "AC4 head, tail and the message filter"
run "$FIX" "$NEEDLE" --head 2
check "$OUT" "$(def "$c4" "$c2")" "'--head 2' is the first two of the walk"
run "$FIX" "$NEEDLE" --tail 2
check "$OUT" "$(def "$c2" "$c1")" "'--tail 2' is the last two"
run "$FIX" "$NEEDLE" --head 3 --tail 2
check "$OUT" "$(def "$c2" "$c1")" "both: the last <tail> of the first <head>"
run "$FIX" "$NEEDLE" --filter 're-add'
check "$OUT" "$(def "$c4")" "'--filter' matches the message header"
run "$FIX" "$NEEDLE" --filter 'b/y'
check "$OUT" "$(def "$c4")" "'--filter' finds the header which names it"
run "$FIX" "$NEEDLE" --filter 'blob is gone'
check "$OUT" "" "and not a commit which names it only in the body"
echo

echo "AC5 format, json and the default"
run "$FIX" "$NEEDLE" --head 1 --format '%h %s'
check "$OUT" "${c4:0:7} c4 re-add as b/y.txt" "'--format' cuts the hash it prepends off again"
run "$FIX" "$NEEDLE" --head 1 --json
contains "$OUT" "\"commit\":\"$c4\"" "'--json' carries the full commit id"
contains "$OUT" '"committer":"Test"' "the committer"
contains "$OUT" '"subject":"c4 re-add as b/y.txt"' "and the subject"
contains "$OUT" '"date":"2026-01-01' "and the date"
check "${OUT:0:1}${OUT: -1}" "[]" "one JSON array"
run "$FIX" "$NEEDLE" --head 1
check "$OUT" "$c4 2026-01-01 00:00:00 +0000 Test" "the default is id, date and committer"
echo

echo "AC6 --check answers only whether a commit is left"
run "$FIX" "$NEEDLE" --check
check "$RC" 0 "'--check' succeeds when a commit is left"
check "$OUT" "" "and prints nothing"
run "$FIX" "$NEEDLE" --check --filter 'no such commit'
check "$RC" 1 "'--check' fails when the filters leave none"
check "$OUT" "" "and still prints nothing"
echo

echo "AC7 bad arguments and a blob outside the store"
# a usage error is a message, not only a status: 'git_search: <why>' and the way to the help
usage() { contains "$(cat "$WORKDIR/err")" "git_search: $1" "$2"; contains "$(cat "$WORKDIR/err")" "usage git_search" "$2, and points at it"; }

run "$FIX" "$NEEDLE" --exact --nonsense
check "$RC" 2 "an unknown option is a usage error"
usage "no such option: --nonsense" "and names the option"
run "$FIX" "$NEEDLE" --head
check "$RC" 2 "a missing option value is a usage error"
usage "--head needs a value" "and names the option"
run "$FIX" "$NEEDLE" --head two
check "$RC" 2 "a count which is not a number is a usage error"
run "$FIX" "$NEEDLE" --filter '('
check "$RC" 2 "a malformed --filter regex is a usage error"
usage "invalid --filter regex: (" "and quotes the regex"
run "$FIX"
check "$RC" 2 "no file at all is a usage error"
usage "a file is required" "and says a file is required"
run "$FIX" "$WORKDIR/nope.txt"
check "$RC" 2 "a file which cannot be hashed is a usage error"
run "$FIX" "$NEEDLE" "$WORKDIR"
check "$RC" 2 "a directory which is not a project is a usage error"
contains "$(cat "$WORKDIR/err")" "git_search: '$WORKDIR' is not inside a git project" "and names the directory"
contains "$(cat "$WORKDIR/err")" "usage git_search" "and points at the usage"
run "$FIX" "$NEEDLE" nomain
check "$RC" 2 "an unknown branch is a usage error"
usage "no such branch" "and names the branch"
printf 'a blob this repository never held\n' > "$WORKDIR/stranger.txt"
run "$FIX" "$WORKDIR/stranger.txt"
check "$RC" 1 "a blob outside the object store is an error"
contains "$(cat "$WORKDIR/err")" "object store" "and says so"
run "$FIX" "$WORKDIR/stranger.txt" --check
check "$RC" 1 "'--check' answers the same, silently"
echo

echo "AC8 -h and --help answer the usage block, they are not a usage error"
run "$FIX" -h
check "$RC" 0 "'-h' succeeds"
contains "$OUT" '<file> [[directory] branch] [--options..]' "and prints the prototype"
run "$FIX" --help
check "$RC" 0 "'--help' succeeds"
contains "$OUT" 'Lists the commits whose tree holds a file' "and its summary"
absent "$(cat "$WORKDIR/err")" "usage error" "neither is a usage error"
echo

echo "AC9 an empty answer is still the output mode's own"
run "$FIX" "$NEEDLE" --json --filter 'no such commit'
check "$RC" 0 "'--json' with nothing to say succeeds"
check "$OUT" "[]" "and answers one empty JSON array"
run "$FIX" "$NEEDLE" --format '%s' --filter 'no such commit'
check "$OUT" "" "'--format' with nothing to say prints nothing"
run "$FIX" "$NEEDLE" --filter 'no such commit'
check "$RC" 0 "the default with nothing to say succeeds"
check "$OUT" "" "and prints nothing"
echo

echo "=== $( (( failures == 0 )) && echo "all git_search checks passed" || echo "$failures check(s) failed") ==="
(( failures == 0 ))
