#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# The environment bar runs its rules in: git's own repository context must not reach it.
#
# 'bar' is installed as a git hook ('pre-commit -> ../../bar'), so git runs it with the context it
# is committing in: 'GIT_DIR', an 'GIT_INDEX_FILE' relative to *git's* working directory and
# 'GIT_PREFIX' for a commit made below the toplevel.  That context is about git's invocation, not
# about the tree bar was started in -- so a rule body which runs git in another repository (a test
# fixture, a testdir, 'rad_topic') resolves it against the wrong tree.  Measured: under a hook's
# 'GIT_DIR' a rule body's 'git -C <fixture> commit' lands in the repository the hook belongs to,
# and a relative 'GIT_INDEX_FILE' makes 'git worktree add' fail with "index file open failed".
#
#   AC1  a rule body sees none of git's repository context, whatever bar was started with
#   AC2  a commit a rule body makes in another repository stays in that repository
#   AC3  a relative 'GIT_INDEX_FILE' does not break git in another tree
#   AC4  the invoking repository is untouched, and a commit through the hook still passes
#   AC5  a plain run answers the same (nothing is exported to begin with, nothing is missed)
#
# usage: tests/test_git_hook_env.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git git_lib json_lib agent_rules helpers_rules usage help"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }

echo "=== Testing that git's hook context does not reach bar's rule bodies ==="
echo

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# <dir> - a throw-away project: bar's modules and the Barf with the probe rules this test drives.
# 'BAR_TEST_OTHER' names the second repository the rule bodies are pointed at; it is an ordinary
# environment variable, and bar does not touch it.
mkproject() {
    local dir="$1" module
    mkdir -p "$dir/Bar.d"
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$dir/Bar.d/$module"
    done
    cat >"$dir/Barf" <<'BARF'
# what the body was started with
rule_git_context: -- 'printf "GIT_DIR=[%s] GIT_INDEX_FILE=[%s] GIT_PREFIX=[%s]\n" "${GIT_DIR-}" "${GIT_INDEX_FILE-}" "${GIT_PREFIX-}"'
# a commit in the *other* repository, the way a fixture makes its own history
probe_commit: -- 'git -C "$BAR_TEST_OTHER" commit -q --allow-empty -m fixture'
# a fixture which makes a repository of its own
probe_init: -- 'git init -q "$BAR_TEST_NEW"'
# git in the other repository, the operation a relative index breaks
probe_worktree: -- 'git -C "$BAR_TEST_OTHER" worktree add -q "$BAR_TEST_OTHER/.worktrees/wt" -b wt'
pre-commit: -- true
BARF
}

# <dir> - a repository with an identity and one commit
mkrepo() {
    git -C "$1" init -q -b main
    git -C "$1" config user.name "Bar Test"
    git -C "$1" config user.email "bar-test@example.com"
    printf '.bar.*\n' >"$1/.gitignore"
    git -C "$1" add -A
    git -C "$1" commit -qm first
}

PROJECT="$WORK/project"
OTHER="$WORK/other"
mkproject "$PROJECT"
mkdir -p "$OTHER"
mkrepo "$PROJECT"
mkrepo "$OTHER"
PROJECT_HEAD="$(git -C "$PROJECT" rev-parse HEAD)"

export BAR_TEST_OTHER="$OTHER"
export BAR_TEST_NEW="$WORK/new"

run() { # <dir> <argv..> - stdout, stderr and rc in OUT/ERR/RC, with git's hook context exported
    local dir="$1"
    shift
    OUT=""
    ERR=""
    RC=0
    OUT="$(cd "$dir" && GIT_DIR="$PROJECT/.git" GIT_INDEX_FILE='.git/index' GIT_PREFIX='' \
        "$@" 2>"$WORK/stderr")" || RC=$?
    ERR="$(cat "$WORK/stderr")"
}

# --------------------------------------------------------------------------------------------
# AC1  the context is not inherited by the rule body
# --------------------------------------------------------------------------------------------
echo "--- AC1 the rule body sees no repository context of the invoking git ---"
run "$PROJECT" "$BAR" rule_git_context
check "$RC" "0" "AC1: the body runs"
check "$OUT" "GIT_DIR=[] GIT_INDEX_FILE=[] GIT_PREFIX=[]" \
    "AC1: 'GIT_DIR', 'GIT_INDEX_FILE' and 'GIT_PREFIX' are gone from the body"

# --------------------------------------------------------------------------------------------
# AC2  a commit made in another repository stays there
# --------------------------------------------------------------------------------------------
echo "--- AC2 a fixture's commit stays in the fixture ---"
run "$PROJECT" "$BAR" probe_commit
check "$RC" "0" "AC2: the body commits"
check "$(git -C "$OTHER" rev-list --count HEAD)" "2" "AC2: the other repository got the commit"
check "$(git -C "$PROJECT" rev-list --count HEAD)" "1" "AC2: the invoking repository did not"
check "$(git -C "$PROJECT" rev-parse HEAD)" "$PROJECT_HEAD" "AC2: and its HEAD did not move"

# --------------------------------------------------------------------------------------------
# AC2b  a repository a rule body creates is the one it named, and the checkout stays a work tree
# --------------------------------------------------------------------------------------------
echo "--- AC2b a fixture's 'git init' does not re-init the invoking repository ---"
run "$PROJECT" "$BAR" probe_init
check "$RC" "0" "AC2b: the body initialises a repository"
if [[ -f "$BAR_TEST_NEW/.git/HEAD" ]]; then pass "AC2b: the repository is the one it named";
else fail "AC2b: no repository at '$BAR_TEST_NEW'"; fi
check "$(git -C "$PROJECT" config --get core.bare || printf 'none')" "false" \
    "AC2b: the checkout is still a work tree ('core.bare' was not set on it)"

# --------------------------------------------------------------------------------------------
# AC3  a relative index does not break git in another tree
# --------------------------------------------------------------------------------------------
echo "--- AC3 'git worktree add' in another tree still works ---"
run "$PROJECT" "$BAR" probe_worktree
check "$RC" "0" "AC3: the tree is created"
if [[ -f "$OTHER/.worktrees/wt/.git" ]]; then pass "AC3: and it is the other repository's tree";
else fail "AC3: no worktree in the other repository"; fi

# --------------------------------------------------------------------------------------------
# AC4  the invoking repository is untouched, and the hook still passes
# --------------------------------------------------------------------------------------------
echo "--- AC4 the checkout still commits through the hook ---"
run "$PROJECT" git status --porcelain
check "$OUT" "" "AC4: the checkout is clean"
ln -s "$BAR" "$PROJECT/.git/hooks/pre-commit"
run "$PROJECT" git commit --allow-empty -m "through the hook"
check "$RC" "0" "AC4: the commit passes its pre-commit hook"
check "$(git -C "$PROJECT" rev-list --count HEAD)" "2" "AC4: exactly one commit was added here"

# --------------------------------------------------------------------------------------------
# AC5  a plain run is unchanged
# --------------------------------------------------------------------------------------------
echo "--- AC5 a plain run answers the same ---"
RC=0
OUT="$(cd "$PROJECT" && "$BAR" rule_git_context 2>&1)" || RC=$?
check "$RC" "0" "AC5: the body runs without the context too"
contains "$OUT" "GIT_DIR=[] GIT_INDEX_FILE=[] GIT_PREFIX=[]" \
    "AC5: nothing is exported to begin with, and nothing is missed"

echo
if (( failures )); then
    echo "==== $failures FAILURE(S) ===="
    exit 1
fi
echo "==== all git hook env tests passed ===="
