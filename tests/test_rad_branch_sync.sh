#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the branch sync (Bar.d/rad).
#
# No node, no network: a throw-away project whose 'rad' remote is a local bare repository, and a
# fake 'rad' ('RAD_BIN') which answers only the two reads the helper needs -- the node's home and
# the repository id.  The clone is shaped like a radicle one: its 'rad' remote maps tags only, so
# there is no 'refs/remotes/rad/<branch>' to read, which is exactly why the tip is asked of the
# remote and why a tracking ref is refreshed only where the clone already carries one.
#
#   AC1  '-h' answers the usage on stdout, exit 0; a refused argument exits 2
#   AC2  not a git repository: the module's exit code for 'no data'
#   AC3  a branch which is already at the tip: 'current', nothing written
#   AC4  '--dry-run' says what it would do and writes nothing
#   AC5  the fast-forward lands in the tree which holds the branch -- the work tree really moves,
#        and no tracking ref is invented in a tags-only clone
#   AC6  a tracking ref the clone does carry is moved with the branch
#   AC7  uncommitted work in that tree refuses the update, and nothing moves
#   AC8  a branch carrying unpublished commits is reported 'ahead' and left alone
#   AC9  a divergent branch is refused, and nothing moves
#   AC10 a branch no tree holds is moved as a ref, and no checkout is switched
#   AC11 '--branch' moves the branch it names
#   AC12 '--json' is one object with the state, both tips and whether it wrote
#   AC13 a branch the remote does not have is 'no data'
#   AC14 the helper is registered ('bar helpers', 'bar helpers --check')
#
# usage: tests/test_rad_branch_sync.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar and the helper
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules helpers_rules radicle_lib rad rad_rules usage help"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }

echo "=== Testing the branch sync (Bar.d/rad) ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

RID="rad:zTestBranchSync0000000000000000000"
OURS="z6MkOurIdentity00000000000000000000000000"
RADHOME="$WORK/radhome"
STORE="$RADHOME/storage/${RID#rad:}"
FAKERAD="$WORK/rad"
UPSTREAM="$WORK/upstream.git"
SRC="$WORK/source"
PROJ="$WORK/project"

git init -q "$SRC"
git -C "$SRC" config user.name fixture
git -C "$SRC" config user.email fixture@example.com
git init -q --bare "$UPSTREAM"
printf 'base\n' >"$SRC/f"
git -C "$SRC" add f
git -C "$SRC" commit -qm base
git -C "$SRC" push -q "$UPSTREAM" HEAD:refs/heads/main
UP0="$(git -C "$SRC" rev-parse HEAD)"

cat >"$FAKERAD" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
path) printf '%s\n' "$FAKE_RADHOME" ;;
'inspect --rid') printf '%s\n' "$FAKE_RID" ;;
*)
    printf 'unexpected: %s\n' "$*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$FAKERAD"
export FAKE_RID="$RID" FAKE_RADHOME="$RADHOME"

# the node's storage: its HEAD names the canonical branch, which is what the helper defaults to
mkdir -p "$RADHOME/storage"
git init -q --bare "$STORE"
git --git-dir="$STORE" symbolic-ref HEAD refs/heads/main

# <dir> - a throw-away project carrying bar's rules; the git repository is the caller's
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
    printf 'rule MAIN: -- true\n' >"$1/Barf"
}

# a project which carries bar's rules but is no git repository
NOPROJ="$WORK/not-a-repository"
mkdir -p "$NOPROJ"
mkproject "$NOPROJ"

git clone -q "$UPSTREAM" "$PROJ"
git -C "$PROJ" config user.name fixture
git -C "$PROJ" config user.email fixture@example.com
git -C "$PROJ" remote rename origin rad
# a radicle clone maps tags only: no 'refs/remotes/rad/<branch>' exists, and none is invented
git -C "$PROJ" config remote.rad.fetch '+refs/tags/*:refs/remotes/rad/tags/*'
git -C "$PROJ" update-ref -d refs/remotes/rad/main 2>/dev/null || true
mkproject "$PROJ"

# <name> <content> - one commit published to the upstream branch, its sha printed
upstream_commit() {
    printf '%s\n' "$2" >"$SRC/$1"
    git -C "$SRC" add "$1"
    git -C "$SRC" commit -qm "$1"
    git -C "$SRC" push -q "$UPSTREAM" HEAD:refs/heads/main
    git -C "$SRC" rev-parse HEAD
}

main_sha() { git -C "$PROJ" rev-parse refs/heads/main; }
run() { ( cd "${1:-$PROJ}" && RAD_BIN="$FAKERAD" "$BAR" rad_branch_sync "${@:2}" ); }

# --------------------------------------------------------------------------------------------
# AC1 -- the usage
# --------------------------------------------------------------------------------------------

echo "AC1 the usage"
out="$(run "$PROJ" -h 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC1: -h exits 0"
contains "$out" "rad_branch_sync" "AC1: and prints the usage"
contains "$out" "--dry-run" "AC1: naming every mode"
out="$(run "$PROJ" --nonsense 2>&1)" && rc=0 || rc=$?
check "$rc" 2 "AC1: an unknown argument is a usage error"
contains "$out" "bar usage rad_branch_sync" "AC1: and says how to call it"
out="$(run "$PROJ" --branch 2>&1)" && rc=0 || rc=$?
check "$rc" 2 "AC1: '--branch' without a value is a usage error"

# --------------------------------------------------------------------------------------------
# AC2 -- no data
# --------------------------------------------------------------------------------------------

echo "AC2 no data"
out="$(run "$NOPROJ" 2>&1)" && rc=0 || rc=$?
check "$rc" 3 "AC2: a directory which is no git repository is 'no data'"
contains "$out" "not a git repository" "AC2: and says so"

# --------------------------------------------------------------------------------------------
# AC3 -- already at the tip
# --------------------------------------------------------------------------------------------

echo "AC3 the branch is current"
out="$(run "$PROJ" 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC3: 'current' is an answer, exit 0"
contains "$out" "current branch=main at=${UP0:0:7}" "AC3: and names the branch and the tip"
check "$(main_sha)" "$UP0" "AC3: nothing moved"

# --------------------------------------------------------------------------------------------
# AC4 -- '--dry-run'
# --------------------------------------------------------------------------------------------

echo "AC4 --dry-run"
UP1="$(upstream_commit g one)"
out="$(run "$PROJ" --dry-run 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC4: a dry run exits 0"
contains "$out" "would-update branch=main from=${UP0:0:7} to=${UP1:0:7}" "AC4: and says what it would do"
check "$(main_sha)" "$UP0" "AC4: and moves no ref"
check "$(git -C "$PROJ" rev-parse --verify --quiet refs/remotes/rad/main || echo none)" none \
    "AC4: and invents no tracking ref"

# --------------------------------------------------------------------------------------------
# AC5 -- the fast-forward lands in the tree which holds the branch
# --------------------------------------------------------------------------------------------

echo "AC5 the fast-forward"
out="$(run "$PROJ" 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC5: the update exits 0"
contains "$out" "updated branch=main from=${UP0:0:7} to=${UP1:0:7}" "AC5: and names both tips"
check "$(main_sha)" "$UP1" "AC5: the branch moved"
check "$(cat "$PROJ/g")" one "AC5: and the work tree carries the new file"
check "$(git -C "$PROJ" status --porcelain --untracked-files=no | wc -l)" 0 "AC5: with nothing left dirty"
check "$(git -C "$PROJ" rev-parse --verify --quiet refs/remotes/rad/main || echo none)" none \
    "AC5: no tracking ref is invented in a tags-only clone"

# --------------------------------------------------------------------------------------------
# AC6 -- a tracking ref the clone does carry moves with the branch
# --------------------------------------------------------------------------------------------

echo "AC6 an existing tracking ref is refreshed"
git -C "$PROJ" update-ref refs/remotes/rad/main "$UP1"
UP2="$(upstream_commit h two)"
out="$(run "$PROJ" 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC6: the update exits 0"
check "$(main_sha)" "$UP2" "AC6: the branch moved"
check "$(git -C "$PROJ" rev-parse refs/remotes/rad/main)" "$UP2" "AC6: and so did the tracking ref"

# --------------------------------------------------------------------------------------------
# AC7 -- uncommitted work refuses the update
# --------------------------------------------------------------------------------------------

echo "AC7 uncommitted work"
UP3="$(upstream_commit i three)"
printf 'mine\n' >>"$PROJ/f"
out="$(run "$PROJ" 2>&1)" && rc=0 || rc=$?
check "$rc" 1 "AC7: a dirty tree refuses, exit 1"
contains "$out" "uncommitted branch=main at=${UP2:0:7}" "AC7: and says why, naming the branch"
check "$(main_sha)" "$UP2" "AC7: the branch did not move"
contains "$(cat "$PROJ/f")" "mine" "AC7: and the uncommitted work is untouched"
git -C "$PROJ" checkout -q -- f

# --------------------------------------------------------------------------------------------
# AC8 -- a branch ahead of its remote
# --------------------------------------------------------------------------------------------

echo "AC8 a branch ahead of its remote"
git -C "$PROJ" reset -q --hard "$UP3"
printf 'local\n' >"$PROJ/own"
git -C "$PROJ" add own
git -C "$PROJ" commit -qm 'local work'
AHEAD_SHA="$(git -C "$PROJ" rev-parse HEAD)"
out="$(run "$PROJ" 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC8: 'ahead' is an answer, exit 0"
contains "$out" "ahead branch=main at=${AHEAD_SHA:0:7} by=1" "AC8: and counts the commits the remote lacks"
check "$(main_sha)" "$AHEAD_SHA" "AC8: nothing was rebased or reset"

# --------------------------------------------------------------------------------------------
# AC9 -- a divergent branch
# --------------------------------------------------------------------------------------------

echo "AC9 a divergent branch"
UP5="$(upstream_commit k five)"
out="$(run "$PROJ" 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 1 "AC9: a branch which diverged is refused, exit 1"
contains "$out" "diverged branch=main local=${AHEAD_SHA:0:7} upstream=${UP5:0:7}" "AC9: naming both sides"
check "$(main_sha)" "$AHEAD_SHA" "AC9: nothing moved"
git -C "$PROJ" reset -q --hard "$UP5"

# --------------------------------------------------------------------------------------------
# AC10 -- a branch no tree holds is moved as a ref
# --------------------------------------------------------------------------------------------

echo "AC10 a branch no tree holds"
git -C "$PROJ" checkout -q -b other
UP4="$(upstream_commit j four)"
out="$(run "$PROJ" 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC10: the update exits 0"
check "$(main_sha)" "$UP4" "AC10: the branch moved"
check "$(git -C "$PROJ" symbolic-ref --short HEAD)" other "AC10: and no checkout was switched"

# --------------------------------------------------------------------------------------------
# AC11 -- '--branch'
# --------------------------------------------------------------------------------------------

echo "AC11 --branch"
git -C "$PROJ" branch next "$UP0"
printf 'next\n' >"$SRC/n"
git -C "$SRC" add n
git -C "$SRC" commit -qm n
git -C "$SRC" push -q "$UPSTREAM" HEAD:refs/heads/next
NEXT_SHA="$(git -C "$SRC" rev-parse HEAD)"
out="$(run "$PROJ" --branch next 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC11: the named branch is synced, exit 0"
contains "$out" "updated branch=next from=${UP0:0:7} to=${NEXT_SHA:0:7}" "AC11: and the report says which"
check "$(git -C "$PROJ" rev-parse refs/heads/next)" "$NEXT_SHA" "AC11: 'next' moved"
check "$(main_sha)" "$UP4" "AC11: and 'main' did not"

# --------------------------------------------------------------------------------------------
# AC12 -- '--json'
# --------------------------------------------------------------------------------------------

echo "AC12 --json"
out="$(run "$PROJ" --json 2>/dev/null)" && rc=0 || rc=$?
check "$rc" 0 "AC12: the json form exits 0"
check "$(jq -r '.bar_rad' <<<"$out")" 1 "AC12: it carries the module marker"
check "$(jq -r '.action' <<<"$out")" branch_sync "AC12: and names the action"
check "$(jq -r '.state' <<<"$out")" current "AC12: with the state"
check "$(jq -r '.branch' <<<"$out")" main "AC12: the branch"
check "$(jq -r '.local' <<<"$out")" "$UP4" "AC12: the local tip"
check "$(jq -r '.upstream' <<<"$out")" "$UP4" "AC12: the remote tip"
check "$(jq -r '.updated' <<<"$out")" false "AC12: and that it wrote nothing"

# --------------------------------------------------------------------------------------------
# AC13 -- a branch the remote does not have
# --------------------------------------------------------------------------------------------

echo "AC13 a branch the remote does not have"
git -C "$PROJ" branch local-only "$UP0"
out="$(run "$PROJ" --branch local-only 2>&1)" && rc=0 || rc=$?
check "$rc" 3 "AC13: 'no data', exit 3"
contains "$out" "names no branch" "AC13: and says the remote has nothing to sync against"

# --------------------------------------------------------------------------------------------
# AC14 -- the registration
# --------------------------------------------------------------------------------------------

echo "AC14 the registration"
out="$( cd "$REPO_ROOT" && ./bar helpers --check 2>&1 )" && rc=0 || rc=$?
check "$rc" 0 "AC14: 'bar helpers --check' passes"
contains "$( cd "$REPO_ROOT" && ./bar helpers 2>&1 )" "rad_branch_sync" "AC14: and the helper is listed"

# --------------------------------------------------------------------------------------------

echo
if (( failures )); then
    echo "FAILED: $failures assertion(s)"
    exit 1
fi
echo "OK"
