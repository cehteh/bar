#!/usr/bin/env bash
# -*- mode: sh; sh-shell: bash -*-
# vim: set ft=bash:
#
# Acceptance tests for the source-tree digest helper (Bar.d/sourcetree).
#
# Everything runs against throw-away repositories in throw-away source-work roots, so nothing here
# depends on this repository's own worktrees or on the state of a real source-work root.  Covered:
#
#   AC1  the digest of a source-work root: one line per tree, then the counts, exit 0
#   AC2  the state counts a changed and an untracked file apart
#   AC3  'unmerged' is what a merge would bring in, 'behind' how far the trunk moved on
#   AC4  the walk is one level deep, and the root may be a repository itself
#   AC5  the root is named -- the argument or '$BAR_SOURCE_ROOT' -- and the digest is cwd independent
#   AC6  how '.worktrees/' is kept out: 'local', a tracked '.gitignore' -- or neither
#   AC7  an externally registered and a locked worktree
#   AC8  a bare repository and a repository without a usable git
#   AC9  --json is one object with the same counts, 'bar --json sourcetree_state' too
#   AC10 a root without a clone answers with zero counts, exit 0 -- an answer, not an error
#   AC11 usage errors are exit 2, a root which is not a directory is exit 3, stdout stays empty
#   AC12 the helper is registered (index, guard) and the module is documented by 'bar help'
#   AC13 the digest is deterministic, ANSI-free and one line per tree
#   AC14 the runtime and the size of the digest (a fixture root, best of 5)
#   AC15 the module names no place of this host (a directory outside the project only when standard)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BAR="$REPO_ROOT/bar"

# the modules a throw-away project needs to run bar, the helper and the repertoire guard
# (agent_rules supplies the '--json' rule of 'bar --json <rule>')
FIXTURE_MODULES="std_lib rule_lib tty_lib std_rules git_lib json_lib agent_rules helpers_rules sourcetree usage help"

failures=0
pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; failures=$((failures + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (got [$1], want [$2])"; fi; }
contains() { if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (no [$2] in [$1])"; fi; }
absent() { if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 ([$2] found in [$1])"; fi; }
bytes_of() { printf '%s' "$1" | wc -c; }
flat() { printf '%s' "$1" | LC_ALL=C sed -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//'; }
line_of() { printf '%s\n' "$OUT" | LC_ALL=C awk -v p="$1" 'index($0, p " ") == 1 { print; exit }'; }
state_of() { printf '%s' "$1" | LC_ALL=C grep -oE 'dirty [0-9?]+/[0-9?]+|clean|\?' | head -1; }
relation_of() { printf '%s' "$1" | LC_ALL=C grep -oE 'unmerged [^ ]+ behind [^ ]+|wtexclude [^ ]+'; }
tree_of() { printf '%s' "$1" | awk '{ print $3 }'; }
counts_of() { tail -1 <<<"$1"; }

echo "=== Testing the source-tree digest (Bar.d/sourcetree) ==="
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
run_bar_env() { # <dir> <VAR=value> <args..> - stdout, with one extra environment assignment
    local dir="$1" assignment="$2"
    shift 2
    OUT=""
    RC=0
    OUT="$(cd "$dir" && env "$assignment" "$BAR" "$@" 2>/dev/null)" || RC=$?
}
run_bar_env_err() { # <dir> <VAR=value> <args..> - stderr, with one extra assignment
    local dir="$1" assignment="$2"
    shift 2
    OUT=""
    RC=0
    OUT="$(cd "$dir" && env "$assignment" "$BAR" "$@" 2>&1 >/dev/null)" || RC=$?
}

# --------------------------------------------------------------------------------------------
# fixtures
# --------------------------------------------------------------------------------------------

# <dir> - a throw-away project: bar, the modules it needs, the helper module symlinked in
mkproject() {
    mkdir -p "$1/Bar.d"
    local module
    for module in $FIXTURE_MODULES; do
        ln -s "$REPO_ROOT/Bar.d/$module" "$1/Bar.d/$module"
    done
    cat >"$1/Barf" <<'BARF'
rule MAIN: -- true
BARF
}

mkcommit() { # <worktree> <message> - commit everything which is staged there
    git -C "$1" commit -qm "$2"
}

# <root> - a source-work root with one clone 'proj': two worktrees, one commit only in the topic,
# a changed and an untracked file in the topic tree, and the trunk moved on after they branched
mksource() {
    local root="$1" clone="$1/proj"
    mkdir -p "$clone"
    git -C "$clone" init -q -b main
    git -C "$clone" config user.name "Bar Test"
    git -C "$clone" config user.email "bar-test@example.com"
    printf 'ignoreme\n' >"$clone/.gitignore"
    printf 'one\n' >"$clone/file"
    git -C "$clone" add .gitignore file
    git -C "$clone" commit -qm first
    # the convention: the worktrees are kept out by a line in '.git/info/exclude', never by the
    # tracked '.gitignore' -- so the main checkout stays clean while the trees are there
    printf '.worktrees/\n' >>"$clone/.git/info/exclude"
    git -C "$clone" worktree add -q "$clone/.worktrees/merged" -b wt/merged
    git -C "$clone" worktree add -q "$clone/.worktrees/topic" -b wt/topic
    printf 'two\n' >"$clone/.worktrees/topic/topicfile"
    git -C "$clone/.worktrees/topic" add topicfile
    git -C "$clone/.worktrees/topic" commit -qm second
    printf 'trunk\n' >"$clone/trunk"
    git -C "$clone" add trunk
    git -C "$clone" commit -qm trunk-moved
    printf 'changed\n' >>"$clone/.worktrees/topic/file"
    printf 'scratch\n' >"$clone/.worktrees/topic/untracked"
}

PROJ="$WORK/proj"
mkproject "$PROJ"

# --------------------------------------------------------------------------------------------
# AC1  the digest of a source-work root
# --------------------------------------------------------------------------------------------
ROOT="$WORK/root"
mksource "$ROOT"
CLONE="$ROOT/proj"

sha_main="$(git -C "$CLONE" rev-parse --short HEAD)"
sha_merged="$(git -C "$CLONE/.worktrees/merged" rev-parse --short HEAD)"
sha_topic="$(git -C "$CLONE/.worktrees/topic" rev-parse --short HEAD)"

run_bar "$PROJ" sourcetree_state "$ROOT"
check "$RC" "0" "AC1: the digest of a source-work root exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "4" "AC1: one line per tree plus the counts are four lines"
check "$(flat "$(line_of proj)")" "proj main main@$sha_main clean wtexclude local" \
    "AC1: the main checkout line is '<path> <kind> <branch>@<head> <state> <relation>'"
check "$(flat "$(line_of proj/.worktrees/merged)")" \
    "proj/.worktrees/merged worktree wt/merged@$sha_merged clean unmerged 0 behind 1" \
    "AC1: a worktree line carries its tree and what is not merged"
check "$(flat "$(line_of proj/.worktrees/topic)")" \
    "proj/.worktrees/topic worktree wt/topic@$sha_topic dirty 1/1 unmerged 1 behind 1" \
    "AC1: the trees are named by their path below the root"
check "$(counts_of "$OUT")" "(1 clone, 2 worktrees, 1 unmerged, 1 dirty)" \
    "AC1: the counts are the last line"
check "$(sed -n 1p <<<"$OUT" | awk '{ print $2 }')" "main" \
    "AC1: the main checkout of the clone comes first"
run_bar_err "$PROJ" sourcetree_state "$ROOT"
absent "$OUT" "WARN" "AC1: a complete digest produces no warning"
contains "$OUT" "OK: sourcetree_state" "AC1: only bar's own stderr record accompanies it"

# --------------------------------------------------------------------------------------------
# AC2  the state: a changed file and an untracked file are counted apart
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$(printf '%s\n' "$OUT" | grep -v '^(' | grep -c 'dirty')" "1" "AC2: exactly one of the trees is dirty"
check "$(state_of "$(line_of proj/.worktrees/topic)")" "dirty 1/1" \
    "AC2: one changed and one untracked file are counted apart"
check "$(state_of "$(line_of proj)")" "clean" \
    "AC2: the worktrees of a clone do not dirty its main checkout"
printf 'more\n' >>"$CLONE/.worktrees/topic/topicfile"
printf 'second\n' >"$CLONE/.worktrees/topic/scratch2"
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$(state_of "$(line_of proj/.worktrees/topic)")" "dirty 2/2" \
    "AC2: a second changed and a second untracked file are counted"
check "$(counts_of "$OUT")" "(1 clone, 2 worktrees, 1 unmerged, 1 dirty)" \
    "AC2: 'dirty' counts trees, not files"
rm "$CLONE/.worktrees/topic/scratch2"
git -C "$CLONE/.worktrees/topic" checkout -q -- topicfile
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$(state_of "$(line_of proj/.worktrees/topic)")" "dirty 1/1" \
    "AC2: the topic is back to one changed and one untracked file"

# --------------------------------------------------------------------------------------------
# AC3  unmerged and behind: the two halves of the merge base
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$(relation_of "$(line_of proj/.worktrees/merged)")" "unmerged 0 behind 1" \
    "AC3: a tree with nothing of its own is 0 unmerged and counts how far the trunk moved on"
check "$(relation_of "$(line_of proj/.worktrees/topic)")" "unmerged 1 behind 1" \
    "AC3: one commit of the topic is not merged into the main checkout"
git -C "$CLONE" merge -q --no-ff "$(git -C "$CLONE" rev-parse wt/topic)" -m "merge wt/topic"
sha_main="$(git -C "$CLONE" rev-parse --short HEAD)"
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$(relation_of "$(line_of proj/.worktrees/topic)")" "unmerged 0 behind 2" \
    "AC3: after the merge nothing is unmerged and 'behind' counts the merge commit"
check "$(counts_of "$OUT")" "(1 clone, 2 worktrees, 0 unmerged, 1 dirty)" \
    "AC3: the merged commit is gone from the totals"
check "$(relation_of "$(line_of proj/.worktrees/merged)")" "unmerged 0 behind 3" \
    "AC3: the untouched tree is three commits behind the trunk"
check "$(flat "$(line_of proj)")" "proj main main@$sha_main clean wtexclude local" \
    "AC3: the main checkout line follows the new trunk commit"

# --------------------------------------------------------------------------------------------
# AC4  one level deep, and a root which is a repository itself
# --------------------------------------------------------------------------------------------
DEEPROOT="$WORK/deeproot"
mkdir -p "$DEEPROOT/level/level2"
mksource "$DEEPROOT/level/level2"
run_bar "$PROJ" sourcetree_state "$DEEPROOT"
check "$RC" "0" "AC4: a root whose clones are one level down still answers"
check "$OUT" "(0 clones, 0 worktrees, 0 unmerged, 0 dirty)" \
    "AC4: a clone below a clone is not part of the layout (the walk is one level deep)"
run_bar "$PROJ" sourcetree_state "$CLONE"
check "$RC" "0" "AC4: the root may be a repository itself"
check "$(printf '%s\n' "$OUT" | wc -l)" "4" "AC4: it reports that repository's own trees"
check "$(tree_of "$(line_of .)")" "main@$sha_main" \
    "AC4: and prints it as '.', the main checkout of the single clone"
check "$(flat "$(line_of .worktrees/topic)")" \
    ".worktrees/topic worktree wt/topic@$sha_topic dirty 1/1 unmerged 0 behind 2" \
    "AC4: the trees of that clone are the same as under the source-work root"

# --------------------------------------------------------------------------------------------
# AC5  the root is named -- the argument or '$BAR_SOURCE_ROOT' -- and the cwd does not matter
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" sourcetree_state "$ROOT"
DIGEST="$OUT"
run_bar_env "$PROJ" "BAR_SOURCE_ROOT=" sourcetree_state
check "$RC" "2" "AC5: with neither the argument nor '\$BAR_SOURCE_ROOT' it is a usage error"
check "$OUT" "" "AC5: and nothing is printed on stdout"
run_bar_env_err "$PROJ" "BAR_SOURCE_ROOT=" sourcetree_state
contains "$OUT" "try 'bar usage sourcetree_state'" "AC5: and where its help is"
contains "$OUT" "BAR_SOURCE_ROOT" "AC5: and the reason names the environment variable"
run_bar_env "$PROJ" "BAR_SOURCE_ROOT=$ROOT" sourcetree_state
check "$RC" "0" "AC5: the root may come from '\$BAR_SOURCE_ROOT' instead"
check "$OUT" "$DIGEST" "AC5: and the digest is the one the root argument answers with"
mkdir -p "$WORK/otherroot"
run_bar_env "$PROJ" "BAR_SOURCE_ROOT=$ROOT" sourcetree_state "$WORK/otherroot"
check "$(counts_of "$OUT")" "(0 clones, 0 worktrees, 0 unmerged, 0 dirty)" \
    "AC5: the argument wins over '\$BAR_SOURCE_ROOT'"
mkdir -p "$PROJ/sub/dir"
run_bar "$PROJ/sub/dir" sourcetree_state "$ROOT"
check "$OUT" "$DIGEST" "AC5: the digest does not depend on the working directory"
mkproject "$WORK/proj2"
run_bar "$WORK/proj2" sourcetree_state "$ROOT"
check "$OUT" "$DIGEST" "AC5: nor on the project bar was invoked from"
FLATROOT="$WORK/flatroot"
mkdir -p "$FLATROOT/proj"
git -C "$FLATROOT/proj" init -q -b main
run_bar_err "$PROJ" sourcetree_state "$FLATROOT"
contains "$OUT" "'$FLATROOT' is not a source-work root" \
    "AC5: a root which is not a source-work root is named on stderr"
run_bar "$PROJ" sourcetree_state "$FLATROOT"
check "$RC" "0" "AC5: and the answer is still printed (auditing a flat index is a legitimate question)"
check "$(counts_of "$OUT")" "(1 clone, 0 worktrees, 0 unmerged, 0 dirty)" \
    "AC5: the flat index names its clones and no worktree"

# --------------------------------------------------------------------------------------------
# AC6  how '.worktrees/' is kept out of a checkout
# --------------------------------------------------------------------------------------------
GITIGNORE_ROOT="$WORK/gitignoreroot"
CLONE2="$GITIGNORE_ROOT/proj"
mkdir -p "$CLONE2"
git -C "$CLONE2" init -q -b main
git -C "$CLONE2" config user.name "Bar Test"
git -C "$CLONE2" config user.email "bar-test@example.com"
printf 'one\n' >"$CLONE2/file"
printf 'ignoreme\n' >"$CLONE2/.gitignore"
git -C "$CLONE2" add file .gitignore
git -C "$CLONE2" commit -qm first
git -C "$CLONE2" worktree add -q "$CLONE2/.worktrees/t1" -b wt/t1
printf 'plain\n' >"$GITIGNORE_ROOT/plain"
run_bar "$PROJ" sourcetree_state "$GITIGNORE_ROOT"
check "$(counts_of "$OUT")" "(1 clone, 1 worktree, 0 unmerged, 1 dirty)" \
    "AC6: a plain file in the root is not a clone, and its untracked '.worktrees/' dir dirties it"
check "$(relation_of "$(line_of proj)")" "wtexclude none" \
    "AC6: a clone which hides nothing is reported as 'none'"
printf '.worktrees/\n' >>"$CLONE2/.gitignore"
git -C "$CLONE2" add .gitignore
mkcommit "$CLONE2" "track a .gitignore"
printf '.worktrees/\n' >>"$CLONE2/.gitignore"
run_bar "$PROJ" sourcetree_state "$GITIGNORE_ROOT"
check "$(state_of "$(line_of proj)")" "dirty 1/0" \
    "AC6: the tracked '.gitignore' which carries it is what dirties the main checkout"
check "$(relation_of "$(line_of proj)")" "wtexclude gitignore" \
    "AC6: and the exclusion is reported as 'gitignore' (project pollution, not repaired)"
printf '.worktrees/\n' >>"$CLONE2/.git/info/exclude"
run_bar "$PROJ" sourcetree_state "$GITIGNORE_ROOT"
check "$(relation_of "$(line_of proj)")" "wtexclude local+gitignore" \
    "AC6: a clone which keeps it out both ways names both sources"

# --------------------------------------------------------------------------------------------
# AC7  externally registered and locked worktrees
# --------------------------------------------------------------------------------------------
mkdir -p "$WORK/elsewhere"
git -C "$CLONE" worktree add -q "$WORK/elsewhere/tree" -b wt/outside
git -C "$CLONE" worktree lock --reason "under test" "$WORK/elsewhere/tree"
sha_outside="$(git -C "$WORK/elsewhere/tree" rev-parse --short HEAD)"
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$(printf '%s\n' "$OUT" | wc -l)" "5" "AC7: the extra tree is one more line"
check "$(flat "$(line_of "$WORK/elsewhere/tree")")" \
    "$WORK/elsewhere/tree external wt/outside@$sha_outside clean unmerged 0 behind 0 locked(under test)" \
    "AC7: a tree outside '<clone>/.worktrees/' is 'external' (and keeps its absolute path)"
check "$(counts_of "$OUT")" "(1 clone, 3 worktrees, 0 unmerged, 1 dirty)" \
    "AC7: an external tree counts as a worktree"
check "$(sed -n 4p <<<"$OUT" | awk '{ print $2 }')" "external" \
    "AC7: and it is listed after the clone's own worktrees"

# --------------------------------------------------------------------------------------------
# AC8  a bare repository and a repository without a usable git
# --------------------------------------------------------------------------------------------
STALE_ROOT="$WORK/staleroot"
mkdir -p "$STALE_ROOT/stale"
printf 'gitdir: %s\n' "$WORK/no-such-gitdir" >"$STALE_ROOT/stale/.git"
run_bar "$PROJ" sourcetree_state "$STALE_ROOT"
check "$RC" "0" "AC8: an unusable repository does not stop the digest"
check "$(flat "$(line_of stale)")" "stale broken - - -" \
    "AC8: it is reported as 'broken' instead of being dropped"
check "$(counts_of "$OUT")" "(1 clone, 0 worktrees, 0 unmerged, 0 dirty)" \
    "AC8: and it still counts as a clone"
run_bar_err "$PROJ" sourcetree_state "$STALE_ROOT"
contains "$OUT" "no usable git repository" "AC8: with a warning on stderr"

BARE_ROOT="$WORK/bareroot"
mkdir -p "$BARE_ROOT"
git init -q --bare --initial-branch=main "$BARE_ROOT/bare.git"
run_bar "$PROJ" sourcetree_state "$BARE_ROOT"
check "$RC" "0" "AC8: a bare repository is answered"
check "$(flat "$(line_of bare.git)")" "bare.git bare - - -" \
    "AC8: a bare repository has no working tree and says so"

# --------------------------------------------------------------------------------------------
# AC9  --json
# --------------------------------------------------------------------------------------------
TREE_TOPIC='.trees[] | select(.path | endswith(".worktrees/topic"))'
TREE_EXTERNAL='.trees[] | select(.kind == "external")'
run_bar "$PROJ" sourcetree_state --json "$ROOT"
check "$RC" "0" "AC9: '--json' exits 0"
check "$(printf '%s\n' "$OUT" | wc -l)" "1" "AC9: '--json' is one line"
if command -v jq >/dev/null; then
    check "$(printf '%s' "$OUT" | jq -r '.bar_sourcetree')" "1" "AC9: the object identifies itself"
    check "$(printf '%s' "$OUT" | jq -r '.root')" "$ROOT" "AC9: it names the resolved root"
    check "$(printf '%s' "$OUT" | jq -r '.clones')" "1" "AC9: the clone count matches the text form"
    check "$(printf '%s' "$OUT" | jq -r '.worktrees')" "3" "AC9: the worktree count matches"
    check "$(printf '%s' "$OUT" | jq -r '.unmerged')" "0" "AC9: the unmerged total matches"
    check "$(printf '%s' "$OUT" | jq -r '.dirty')" "1" "AC9: the dirty total matches"
    check "$(printf '%s' "$OUT" | jq -r '.trees | length')" "4" "AC9: one tree object per line"
    check "$(printf '%s' "$OUT" | jq -r '.trees[0] | [.kind, .branch, .state, .detached, (.exclude | join("+"))] | join(" ")')" \
        "main main clean false local" "AC9: the main checkout carries kind, branch, state and exclusion"
    check "$(printf '%s' "$OUT" | jq -r "$TREE_TOPIC | [.kind, .branch, .changed, .untracked, .unmerged, .behind, .locked] | join(\" \")")" \
        "worktree wt/topic 1 1 0 2 false" "AC9: a worktree carries its numbers and its relation"
    check "$(printf '%s' "$OUT" | jq -r "$TREE_EXTERNAL | [.kind, .locked, .lock_reason, .prunable, .detached, .bare] | join(\" \")")" \
        "external true under test false false false" "AC9: an external and locked tree says so"
    check "$(printf '%s' "$OUT" | jq -r ".trees[] | select(.kind == \"main\") | .merge_base == .commit")" "true" \
        "AC9: the merge base of the main checkout is its own commit"
else
    pass "AC9: jq is not installed, the JSON is only checked for its shape"
    contains "$OUT" '"bar_sourcetree":1' "AC9: the object identifies itself"
fi
JSON="$OUT"
run_bar "$PROJ" --json sourcetree_state "$ROOT"
check "$OUT" "$JSON" "AC9: 'bar --json sourcetree_state' prints the same object (BAR_AGENT_JSON)"
run_bar "$PROJ" sourcetree_state --json "$ROOT"
check "$OUT" "$JSON" "AC9: two runs print the same object"

# --------------------------------------------------------------------------------------------
# AC10 a root without a clone is an empty answer
# --------------------------------------------------------------------------------------------
mkdir -p "$WORK/emptyroot/somedir/somewhere/deeper"
run_bar "$PROJ" sourcetree_state "$WORK/emptyroot"
check "$RC" "0" "AC10: a root without a clone exits 0"
check "$OUT" "(0 clones, 0 worktrees, 0 unmerged, 0 dirty)" \
    "AC10: and answers with zero counts (an empty result is an answer, not a failure)"
run_bar "$PROJ" sourcetree_state --json "$WORK/emptyroot"
check "$OUT" '{"bar_sourcetree":1,"root":"'"$WORK"'/emptyroot","clones":0,"worktrees":0,"unmerged":0,"dirty":0,"trees":[]}' \
    "AC10: the empty answer is a valid object"

# --------------------------------------------------------------------------------------------
# AC11 usage and a root which cannot be asked
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" sourcetree_state --nonsense
check "$RC" "2" "AC11: an unknown argument exits 2"
check "$OUT" "" "AC11: an unknown argument prints nothing on stdout"
run_bar_err "$PROJ" sourcetree_state --nonsense
contains "$OUT" "sourcetree_state: unknown option '--nonsense'" "AC11: what was wrong goes to stderr"
run_bar "$PROJ" sourcetree_state "$ROOT" "$ROOT"
check "$RC" "2" "AC11: a second root is a usage error"
check "$OUT" "" "AC11: and prints nothing on stdout"
run_bar "$PROJ" sourcetree_state "$WORK/no-such-root"
check "$RC" "3" "AC11: a root which is not a directory exits 3"
check "$OUT" "" "AC11: and prints nothing on stdout"
run_bar_err "$PROJ" sourcetree_state "$WORK/no-such-root"
contains "$OUT" "not a directory" "AC11: the reason goes to stderr"

# --------------------------------------------------------------------------------------------
# AC12 the helper is registered
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" helpers
check "$RC" "0" "AC12: the repertoire answers with the helper module in place"
contains "$OUT" "sourcetree_state" "AC12: the helper is in the index"
# The row carries the personality of the invocation as a prefix (the accepted repertoire change):
# every listed invocation reads '<personality> <invocation>'.
contains "$OUT" "what is not merged yet  | bar sourcetree_state [--json] [<root>]  | one line per tree, then the counts" \
    "AC12: with the purpose, the invocation and the output shape it declares"
run_bar "$PROJ" helpers --check
check "$RC" "0" "AC12: the registration guard passes"
check "$OUT" "" "AC12: and has nothing to report"
run_bar "$PROJ" check helpers_check
check "$OUT" "OK helpers_check" "AC12: the guard is an agent contract target"
run_bar "$REPO_ROOT" help
contains "$OUT" "sourcetree - The source trees below a source-work root" \
    "AC12: the module documentation reaches 'bar help'"

# --------------------------------------------------------------------------------------------
# AC13 the digest is deterministic, ANSI-free and one line per tree
# --------------------------------------------------------------------------------------------
run_bar "$PROJ" sourcetree_state "$ROOT"
SECOND="$OUT"
run_bar "$PROJ" sourcetree_state "$ROOT"
check "$OUT" "$SECOND" "AC13: two runs print the same digest (order, alignment and counts)"
absent "$OUT" "$(printf '\033')" "AC13: stdout carries no ANSI escapes"
check "$(printf '%s\n' "$OUT" | grep -c .)" "5" "AC13: exactly one line per tree plus the counts"
check "$(printf '%s\n' "$OUT" | awk '!/^[(]/ { print $1 }' | wc -l)" "4" \
    "AC13: every tree is named by exactly one line"
check "$(printf '%s\n' "$OUT" | grep -v '^(' | grep -v external | LC_ALL=C sort -c 2>/dev/null && echo sorted)" "sorted" \
    "AC13: the trees of the clone are ordered by their path"

# --------------------------------------------------------------------------------------------
# AC14 the digest stays bounded (best of 5, against a bare bar call) — a last-resort net
# --------------------------------------------------------------------------------------------
time_run() { # <cmd..>
    local start end
    start="$(date +%s%N)"
    (cd "$1" && shift && "$@" >/dev/null 2>&1) || true
    end="$(date +%s%N)"
    echo $(( (end - start) / 1000000 ))
}
best=1000000
for _ in 1 2 3 4 5; do
    t="$(time_run "$PROJ" "$BAR" sourcetree_state "$ROOT")"
    (( t < best )) && best="$t"
done
base=1000000
for _ in 1 2 3 4 5; do
    t="$(time_run "$PROJ" "$BAR" rule_exists foo)"
    (( t < base )) && base="$t"
done
if (( best < 5000 )); then
    pass "AC14: the fixture digest takes ${best} ms (best of 5, net 5000 ms; a bare bar call is ${base} ms)"
else
    fail "AC14: the fixture digest takes ${best} ms (over the 5000 ms net; a bare bar call is ${base} ms)"
fi
size="$(bytes_of "$JSON")"
if (( size <= 8192 )); then
    pass "AC14: the fixture object is ${size} B for 4 trees"
else
    fail "AC14: the fixture object is ${size} B for 4 trees"
fi

# --------------------------------------------------------------------------------------------
# AC15 the module names no place of this host
# --------------------------------------------------------------------------------------------
# The module ships to other users and runs in their trees: a directory outside the project is
# named by the symbol which already exists for it ('<root>', '<clone>/.worktrees/<topic>', the
# environment variable), and only a standard directory may be named outright.
MODULE="$REPO_ROOT/Bar.d/sourcetree"
named="$(LC_ALL=C grep -oE '(\$HOME|~)/[A-Za-z0-9_.-]+' "$MODULE" | LC_ALL=C sort -u |
    LC_ALL=C grep -vE '^(\$HOME|~)/(\.config|\.cache|\.local|\.ssh)$' || true)"
check "$named" "" "AC15: the module names a home directory only when it is a standard one"
absolute="$(LC_ALL=C grep -E '/(home|Users)/[A-Za-z0-9_.-]+' "$MODULE" || true)"
check "$absolute" "" "AC15: and no user's absolute home directory"

echo
if (( failures == 0 )); then
    echo "=== All source-tree digest tests passed ==="
else
    echo "=== $failures source-tree digest assertion(s) FAILED ==="
    exit 1
fi
